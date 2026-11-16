--!strict
-- RewardService (BM-040, BM-041, BM-042, BM-043, BM-045, BM-046).
--
-- The single facade every gameplay system uses to grant rewards. It owns
-- grant decisions, receipts, pending intents, run records, compensation
-- and reconciliation; no other module touches `profile.receipts`.
--
-- Grant flow (per key, through SaveQueue):
--   1. record the intent (durable: "this grant is owed"), flush
--   2. apply the grant + receipt, clearing the intent, flush
-- A crash between the two leaves an intent the next owner recovers. A
-- deterministic failure in step 2 (capacity, grant rule) leaves the
-- intent for the reconciliation worker to retry or escalate; nothing is
-- ever paid twice and nothing certified is silently lost.
--
-- Archived receipts (BM-047): a permanent receipt may have been moved to an
-- archive record. Duplicate checks read the profile and every archive it
-- lists. When that cannot be done (store or archive unreadable) the intent
-- is still recorded, so the reward stays owed, but the grant itself is
-- refused inside the write until the archives can be read.
--
-- Compensation (BM-040) is a grant whose receipt is derived from an
-- operator case ID, so repeating a case is a no-op, and every one is
-- logged with the operator and reason.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Clock = require(ReplicatedStorage.Shared.Sim.Clock)
local Logger = require(script.Parent.Parent.Logging.Logger)
local Profile = require(ReplicatedStorage.Shared.Types.Profile)
local ProfileStore = require(script.Parent.Parent.Persistence.ProfileStore)
local ReceiptCapacity = require(script.Parent.Parent.Persistence.ReceiptCapacity)
local Receipts = require(script.Parent.Parent.Persistence.Receipts)
local RewardCatalog = require(script.Parent.Parent.Content.RewardCatalog)
local SaveQueue = require(script.Parent.Parent.Persistence.SaveQueue)
local Telemetry = require(script.Parent.Parent.Logging.Telemetry)

export type Source = { kind: RewardCatalog.SourceKind, id: string }

export type GrantOutcome = "granted" | "duplicate" | "pending" | "refused"

export type GrantResult = { outcome: GrantOutcome, receiptId: string?, reason: string? }

-- A player's persistence context as the service sees it.
export type Target = { userId: number, key: string }

export type RunResult = {
	runId: string,
	descentId: string,
	season: number,
	completedAt: number,
	-- Eligible players and the reward slots each earned.
	players: { { target: Target, slots: { { slot: number, rewardId: string } } } },
}

export type Operator = { operatorId: string, caseId: string, reason: string }

export type Deps = {
	clock: Clock.Clock,
	logger: Logger.Logger,
	telemetry: Telemetry.Telemetry,
	catalog: RewardCatalog.Catalog,
	queue: SaveQueue.Queue,
	profiles: ProfileStore.Store,
	capacity: ReceiptCapacity.Monitor,
	-- The DataStore for run records (BM-042); injected like the profile store.
	runStore: ProfileStore.RawStore,
	seasons: Receipts.SeasonPolicy,
	-- Intents older than this are retried by the worker; older than
	-- escalateAfterSeconds are reported for operator recovery.
	retryAfterSeconds: number?,
	escalateAfterSeconds: number?,
}

export type Service = {
	grantPermanent: (
		self: Service,
		target: Target,
		source: Source,
		rewardId: string
	) -> GrantResult,
	grantSeasonal: (
		self: Service,
		target: Target,
		runId: string,
		slot: number,
		rewardId: string,
		season: number
	) -> GrantResult,
	compensate: (
		self: Service,
		target: Target,
		operator: Operator,
		rewardId: string
	) -> GrantResult,
	recordRunResult: (self: Service, run: RunResult) -> { [string]: GrantResult },
	-- Re-issues the grant for every pending intent in a loaded profile.
	recoverPending: (self: Service, target: Target, profile: Profile.PlayerProfile) -> number,
	-- Reconciliation worker step for one key: settles uncertain writes and
	-- retries or escalates stale intents.
	reconcile: (
		self: Service,
		target: Target
	) -> { settled: boolean, retried: number, escalated: number },
	-- Capacity monitoring and archive migration for a loaded profile.
	maintain: (
		self: Service,
		target: Target,
		profile: Profile.PlayerProfile
	) -> ReceiptCapacity.Report,
	start: (self: Service) -> (),
}

local RewardService = {}

RewardService.RUN_STORE_NAME = "DescentRuns"

function RewardService.new(deps: Deps): Service
	local retryAfter = deps.retryAfterSeconds or 30
	local escalateAfter = deps.escalateAfterSeconds or 3600

	local service = {} :: Service

	local function log(
		level: Logger.Level,
		event: string,
		target: Target?,
		fields: Logger.RawFields?
	)
		local merged: Logger.RawFields = if fields ~= nil then table.clone(fields) else {}
		local logger = if target ~= nil
			then deps.logger:with({ playerId = target.userId })
			else deps.logger
		logger:log(level, "reward", event, merged)
	end

	local function track(event: string, target: Target?, fields: Logger.RawFields)
		local merged = table.clone(fields)
		if target ~= nil then
			merged.userId = target.userId
		end
		deps.telemetry:track(event, merged)
	end

	-- Flushes the key and reports what happened to ONE mutation. The queue
	-- drops a mutation that raises and still writes the others, so a
	-- "rejected" flush only concerns this mutation when it is in the list
	-- of dropped IDs (or when the whole batch was dropped).
	local function flushFor(key: string, mutationId: string): (SaveQueue.FlushOutcome, string?)
		local outcome: SaveQueue.FlushOutcome, detail: string?, dropped: { string }? =
			deps.queue:flush(key)
		if outcome == "rejected" and dropped ~= nil and table.find(dropped, mutationId) == nil then
			local committed: SaveQueue.FlushOutcome = "committed"
			return committed, nil
		end
		return outcome, detail
	end

	-- Runs the two-step flow. `build` makes the grant mutation.
	local function execute(
		target: Target,
		receiptId: string,
		sourceId: string,
		definition: RewardCatalog.Definition,
		build: () -> (Receipts.Mutation?, Receipts.Refusal?)
	): GrantResult
		local intent, refusal =
			Receipts.recordIntent(receiptId, sourceId, definition.id, deps.clock:wallTime())
		if intent == nil then
			track(
				"reward_refused",
				target,
				{ rewardId = definition.id, reason = refusal :: string }
			)
			return { outcome = "refused", reason = refusal :: string }
		end
		local grant, grantRefusal = build()
		if grant == nil then
			track(
				"reward_refused",
				target,
				{ rewardId = definition.id, reason = grantRefusal :: string }
			)
			return { outcome = "refused", reason = grantRefusal :: string }
		end

		if not deps.queue:enqueue(target.key, intent) then
			return { outcome = "pending", receiptId = receiptId, reason = "queue full" }
		end
		local intentOutcome = flushFor(target.key, intent.id)
		if intentOutcome ~= "committed" then
			-- Intent not durably recorded yet; the queue keeps it and the
			-- worker will finish. The reward is owed, not lost.
			log(
				"warn",
				"reward_intent_deferred",
				target,
				{ receiptId = receiptId, outcome = intentOutcome }
			)
			return { outcome = "pending", receiptId = receiptId, reason = intentOutcome }
		end

		if not deps.queue:enqueue(target.key, grant) then
			return { outcome = "pending", receiptId = receiptId, reason = "queue full" }
		end
		local outcome, detail = flushFor(target.key, grant.id)
		if outcome == "committed" then
			-- "committed" covers both "written now" and "already applied".
			log(
				"info",
				"reward_granted",
				target,
				{ receiptId = receiptId, rewardId = definition.id, source = sourceId }
			)
			track(
				"reward_granted",
				target,
				{ rewardId = definition.id, receiptId = receiptId, source = sourceId }
			)
			return { outcome = "granted", receiptId = receiptId }
		elseif outcome == "rejected" then
			-- Deterministic failure: the intent stays on disk for recovery.
			log(
				"error",
				"reward_grant_rejected",
				target,
				{ receiptId = receiptId, detail = detail or "" }
			)
			track(
				"reward_grant_rejected",
				target,
				{ rewardId = definition.id, receiptId = receiptId }
			)
			return { outcome = "pending", receiptId = receiptId, reason = detail }
		end
		log("warn", "reward_grant_deferred", target, { receiptId = receiptId, outcome = outcome })
		return { outcome = "pending", receiptId = receiptId, reason = detail or outcome }
	end

	local function lookup(
		rewardId: string,
		sourceKind: RewardCatalog.SourceKind?
	): (RewardCatalog.Definition?, string?)
		local definition = deps.catalog:get(rewardId)
		if definition == nil then
			return nil, "unknown reward " .. tostring(rewardId)
		end
		if sourceKind ~= nil and table.find(definition.sources, sourceKind) == nil then
			return nil, "reward " .. rewardId .. " cannot come from " .. sourceKind
		end
		return definition, nil
	end

	-- Archived permanent receipts per key. The view is checked against the
	-- archive list of the profile every time: when the profile lists an
	-- archive the view has not read (this server archived, or another server
	-- did while the player was away), the archives are read again. The table
	-- is updated in place so grant mutations already holding it see the
	-- newer view.
	local archivedCache: { [string]: ReceiptCapacity.ArchivedView } = {}

	local function covers(view: ReceiptCapacity.ArchivedView, archives: { string }): boolean
		for _, archiveKey in archives do
			if view.covers[archiveKey] ~= true then
				return false
			end
		end
		return true
	end

	-- nil means the archives could not be read: the caller must not pay.
	local function archivedFor(target: Target, profile: any?): ReceiptCapacity.ArchivedView?
		local stored = profile
		if stored == nil then
			stored = deps.profiles:read(target.key)
		end
		if
			type(stored) ~= "table"
			or type(stored.receipts) ~= "table"
			or type(stored.receipts.archives) ~= "table"
		then
			return nil
		end
		local cached = archivedCache[target.key]
		if cached ~= nil and covers(cached, stored.receipts.archives) then
			return cached
		end
		local view = deps.capacity.loadArchived(stored)
		if view == nil then
			return nil
		end
		if cached == nil then
			archivedCache[target.key] = view
			return view
		end
		for id in view.receipts do
			cached.receipts[id] = true
		end
		for archiveKey in view.covers do
			cached.covers[archiveKey] = true
		end
		return cached
	end

	-- First value: true when the receipt is already paid, false when it is
	-- not, nil when that cannot be told (store or archive unreadable).
	-- Second value: the archived view to build a permanent grant with.
	local function alreadyGranted(
		target: Target,
		receiptId: string
	): (boolean?, ReceiptCapacity.ArchivedView?)
		local stored = deps.profiles:read(target.key)
		if type(stored) ~= "table" then
			return nil, nil
		end
		local receipts = (stored :: any).receipts
		if receipts == nil then
			return nil, nil
		end
		if receipts.permanent[receiptId] == true or receipts.seasonal[receiptId] ~= nil then
			return true, nil
		end
		local archived = archivedFor(target, stored)
		if archived == nil then
			log("warn", "reward_receipts_unverifiable", target, { receiptId = receiptId })
			return nil, nil
		end
		return archived.receipts[receiptId] == true, archived
	end

	function service:grantPermanent(target: Target, source: Source, rewardId: string): GrantResult
		local definition, problem = lookup(rewardId, source.kind)
		if definition == nil then
			track("reward_refused", target, { rewardId = rewardId, reason = problem :: string })
			return { outcome = "refused", reason = problem }
		end
		if definition.kind ~= "permanent" then
			return { outcome = "refused", reason = "reward " .. rewardId .. " is not permanent" }
		end
		local receiptId = RewardCatalog.permanentReceiptId(source.kind, source.id, rewardId)
		if receiptId == nil then
			return { outcome = "refused", reason = "invalid source id" }
		end
		local paid, archived = alreadyGranted(target, receiptId)
		if paid then
			track("reward_duplicate", target, { rewardId = rewardId, receiptId = receiptId })
			return { outcome = "duplicate", receiptId = receiptId }
		end
		-- When `paid` is nil the archives could not be read: `archived` is
		-- nil and the grant mutation refuses to pay if the stored profile
		-- has archives. The intent is still recorded, so the reward is owed.
		return execute(target, receiptId, source.id, definition, function()
			return Receipts.permanentGrant(receiptId, definition, archived)
		end)
	end

	function service:grantSeasonal(
		target: Target,
		runId: string,
		slot: number,
		rewardId: string,
		season: number
	): GrantResult
		local definition, problem = lookup(rewardId, "descent")
		if definition == nil then
			track("reward_refused", target, { rewardId = rewardId, reason = problem :: string })
			return { outcome = "refused", reason = problem }
		end
		if definition.kind ~= "repeatable" then
			return { outcome = "refused", reason = "reward " .. rewardId .. " is not repeatable" }
		end
		local receiptId = RewardCatalog.seasonalReceiptId(season, runId, slot, rewardId)
		if receiptId == nil then
			return { outcome = "refused", reason = "invalid run id or slot" }
		end
		if not Receipts.isSeasonOpen(deps.seasons, season) then
			track("reward_refused", target, { rewardId = rewardId, reason = "seasonClosed" })
			return { outcome = "refused", receiptId = receiptId, reason = "seasonClosed" }
		end
		if alreadyGranted(target, receiptId) then
			track("reward_duplicate", target, { rewardId = rewardId, receiptId = receiptId })
			return { outcome = "duplicate", receiptId = receiptId }
		end
		return execute(target, receiptId, runId, definition, function()
			return Receipts.seasonalGrant(receiptId, season, definition, deps.seasons)
		end)
	end

	function service:compensate(target: Target, operator: Operator, rewardId: string): GrantResult
		if
			type(operator.operatorId) ~= "string"
			or #operator.operatorId == 0
			or #operator.reason == 0
		then
			return { outcome = "refused", reason = "compensation requires an operator and a reason" }
		end
		local definition, problem = lookup(rewardId, nil)
		if definition == nil then
			return { outcome = "refused", reason = problem }
		end
		local receiptId =
			RewardCatalog.permanentReceiptId("event", "comp-" .. operator.caseId, rewardId)
		if receiptId == nil then
			return { outcome = "refused", reason = "invalid case id" }
		end
		log("warn", "reward_compensation", target, {
			operator = operator.operatorId,
			caseId = operator.caseId,
			reason = operator.reason,
			rewardId = rewardId,
			receiptId = receiptId,
		})
		local paid, archived = alreadyGranted(target, receiptId)
		if paid then
			track(
				"reward_compensation_duplicate",
				target,
				{ caseId = operator.caseId, rewardId = rewardId }
			)
			return { outcome = "duplicate", receiptId = receiptId }
		end
		local result = execute(target, receiptId, "comp-" .. operator.caseId, definition, function()
			return Receipts.permanentGrant(receiptId, definition, archived)
		end)
		track(
			"reward_compensation",
			target,
			{ caseId = operator.caseId, rewardId = rewardId, outcome = result.outcome }
		)
		return result
	end

	function service:recordRunResult(run: RunResult): { [string]: GrantResult }
		-- Durable record first, so a crash mid-way leaves a reference every
		-- grant can be traced to.
		local record = {
			runId = run.runId,
			descentId = run.descentId,
			season = run.season,
			completedAt = run.completedAt,
			players = {},
		}
		for _, entry in run.players do
			local slots = {}
			for _, slot in entry.slots do
				table.insert(slots, {
					slot = slot.slot,
					rewardId = slot.rewardId,
					receiptId = RewardCatalog.seasonalReceiptId(
						run.season,
						run.runId,
						slot.slot,
						slot.rewardId
					) or "",
				})
			end
			table.insert(
				record.players,
				{ userId = entry.target.userId, key = entry.target.key, slots = slots }
			)
		end
		local written = deps.profiles:writeRecord(deps.runStore, run.runId, function(old)
			if old ~= nil then
				return nil -- already recorded; never rewrite a certified result
			end
			return record
		end)
		if written == "uncertain" then
			log("warn", "run_record_uncertain", nil, { runId = run.runId })
		end
		track(
			"descent_run_recorded",
			nil,
			{ runId = run.runId, descentId = run.descentId, players = #run.players }
		)

		local results: { [string]: GrantResult } = {}
		for _, entry in run.players do
			for _, slot in entry.slots do
				local result = service:grantSeasonal(
					entry.target,
					run.runId,
					slot.slot,
					slot.rewardId,
					run.season
				)
				results[entry.target.key .. "|" .. (result.receiptId or tostring(slot.slot))] =
					result
			end
		end
		return results
	end

	function service:recoverPending(target: Target, profile: Profile.PlayerProfile): number
		local recovered = 0
		-- Permanent grants need the archived view; without it they wait.
		local archived = archivedFor(target, profile)
		local ids = {}
		for grantId in profile.receipts.pending do
			table.insert(ids, grantId)
		end
		table.sort(ids)
		for _, grantId in ids do
			local intent = profile.receipts.pending[grantId]
			local definition = deps.catalog:get(intent.rewardCatalogId)
			if definition == nil then
				log("error", "reward_recovery_escalated", target, {
					receiptId = grantId,
					rewardId = intent.rewardCatalogId,
					detail = "reward no longer in catalog",
				})
				track("reward_recovery_escalated", target, { receiptId = grantId })
				continue
			end
			local mutation: Receipts.Mutation?
			if string.sub(grantId, 1, 2) == "s:" then
				local season = tonumber(string.match(grantId, "^s:(%d+):"))
				mutation = Receipts.seasonalGrant(grantId, season or 0, definition, deps.seasons)
				if mutation == nil then
					log("error", "reward_recovery_escalated", target, {
						receiptId = grantId,
						rewardId = definition.id,
						detail = "season closed",
					})
					track("reward_recovery_escalated", target, { receiptId = grantId })
					continue
				end
			else
				if archived == nil then
					log("warn", "reward_recovery_deferred", target, {
						receiptId = grantId,
						rewardId = definition.id,
						detail = "archived receipts unreadable",
					})
					continue
				end
				mutation = Receipts.permanentGrant(grantId, definition, archived)
			end
			if mutation ~= nil and deps.queue:enqueue(target.key, mutation) then
				recovered += 1
				log(
					"info",
					"reward_recovery_queued",
					target,
					{ receiptId = grantId, rewardId = definition.id }
				)
				track("reward_recovered", target, { receiptId = grantId, rewardId = definition.id })
			end
		end
		if recovered > 0 then
			deps.queue:flush(target.key)
		end
		return recovered
	end

	function service:reconcile(
		target: Target
	): { settled: boolean, retried: number, escalated: number }
		local settledVerdict = deps.queue:reconcile(target.key)
		if settledVerdict == "retry" then
			-- The queued operation did not land; re-apply it now.
			deps.queue:flush(target.key)
		end
		local result = { settled = settledVerdict == "settled", retried = 0, escalated = 0 }
		local stored = deps.profiles:read(target.key)
		if type(stored) ~= "table" then
			return result
		end
		local profile = stored :: any
		local now = deps.clock:wallTime()
		local stale = Receipts.stalePending(profile, now, retryAfter)
		if #stale == 0 then
			return result
		end
		for _, intent in stale do
			if now - intent.createdAt >= escalateAfter then
				result.escalated += 1
				log("error", "reward_recovery_escalated", target, {
					receiptId = intent.grantId,
					rewardId = intent.rewardCatalogId,
					ageSeconds = now - intent.createdAt,
					detail = "retry window exceeded",
				})
			end
		end
		result.retried = service:recoverPending(target, profile)
		return result
	end

	function service:maintain(
		target: Target,
		profile: Profile.PlayerProfile
	): ReceiptCapacity.Report
		local report = deps.capacity.observe(target.key, target.userId, profile)
		if not ReceiptCapacity.needsArchive(profile) then
			return report
		end
		-- Archive only when the existing archives can be read: the view must
		-- be complete before more receipts leave the profile.
		local view = archivedFor(target, profile)
		if view == nil then
			log("error", "receipt_archive_failed", target, { detail = "archives unreadable" })
			return report
		end
		local mutation, reason, moved = deps.capacity.buildArchive(target.key, profile)
		if mutation == nil or moved == nil then
			log("error", "receipt_archive_failed", target, { detail = reason or "unknown" })
			return report
		end
		-- The record is durable. Count its receipts as archived from now on,
		-- before the profile write lands: they are paid either way.
		for _, id in moved.receipts do
			view.receipts[id] = true
		end
		view.covers[moved.archiveKey] = true
		if not deps.queue:enqueue(target.key, mutation) then
			-- The record stays as an orphan; the next attempt adopts it.
			log("error", "receipt_archive_failed", target, { detail = "queue full" })
			return report
		end
		local outcome = flushFor(target.key, mutation.id)
		log("info", "receipt_archive_applied", target, { outcome = outcome })
		return report
	end

	function service:start() end

	return table.freeze(service)
end

return table.freeze(RewardService)
