--!strict
-- Receipt capacity monitoring and archive migration (BM-047).
--
-- Permanent receipts are never deleted. When a profile's permanent ledger
-- approaches its budget, the oldest half (by sorted ID; IDs are stable and
-- the order is deterministic) is moved into an archive record under a
-- separate DataStore key, and the profile keeps the archive key in
-- `receipts.archives`. Order of operations makes this safe:
--
--   1. the archive record is written and confirmed (never rewritten),
--   2. only then are those receipts removed from the profile in a
--      lease-guarded mutation that also appends the archive key,
--   3. duplicate checks consult the profile AND its archives: the service
--      loads every archive a profile lists into an `ArchivedView` and hands
--      it to the grant mutations, which refuse to pay unless the view
--      covers every archive the stored profile lists at write time.
--
-- Failure cases:
--   * Crash, lost response or a dropped profile write between 1 and 2
--     leaves an orphan archive record. The receipts are still in the
--     profile, so nothing is lost and nothing can be paid twice. The next
--     attempt finds the record under the same key and ADOPTS it (it moves
--     exactly the receipts the record holds) instead of writing a new one,
--     so an orphan never blocks archiving.
--   * An archive record that cannot be read makes `loadArchived` return
--     nil. Callers must not pay a permanent grant then; the grant stays
--     owed (pending intent) until the record can be read again.
--   * A record under the expected key that does not belong to the profile,
--     or holds receipts the profile does not have, is a conflict: nothing
--     is archived and the error is logged for an operator.
--   * Capacity exhaustion with nothing archivable fails closed, as before.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LegacyIds = require(script.Parent.LegacyIds)
local Limits = require(ReplicatedStorage.Shared.Constants.Limits)
local Logger = require(script.Parent.Parent.Logging.Logger)
local Profile = require(ReplicatedStorage.Shared.Types.Profile)
local ProfileStore = require(script.Parent.ProfileStore)
local Receipts = require(script.Parent.Receipts)
local Telemetry = require(script.Parent.Parent.Logging.Telemetry)

type PlayerProfile = Profile.PlayerProfile

export type Level = "ok" | "warn" | "critical"

export type Gauge = { count: number, max: number, fraction: number, level: Level }

export type Report = { permanent: Gauge, seasonal: Gauge, pending: Gauge, archives: number }

export type ArchivedView = Receipts.ArchivedView

-- What an archive attempt moved: the record key and the receipt IDs in it.
export type Moved = { archiveKey: string, receipts: { string } }

export type Deps = {
	logger: Logger.Logger,
	telemetry: Telemetry.Telemetry,
	profiles: ProfileStore.Store,
	archiveStore: ProfileStore.RawStore,
}

local P = Limits.PROFILE

local ReceiptCapacity = {}

ReceiptCapacity.WARN_FRACTION = 0.8
ReceiptCapacity.CRITICAL_FRACTION = 0.95
-- Archive when permanent receipts reach this fraction of the budget.
ReceiptCapacity.ARCHIVE_FRACTION = 0.9
ReceiptCapacity.MAX_ARCHIVES = 16
ReceiptCapacity.ARCHIVE_STORE_NAME = "ProfileReceiptArchive"

local function countKeys(t: { [any]: any }): number
	local n = 0
	for _ in t do
		n += 1
	end
	return n
end

local function gauge(count: number, max: number): Gauge
	local fraction = count / max
	local level: Level = "ok"
	if fraction >= ReceiptCapacity.CRITICAL_FRACTION then
		level = "critical"
	elseif fraction >= ReceiptCapacity.WARN_FRACTION then
		level = "warn"
	end
	return { count = count, max = max, fraction = fraction, level = level }
end

function ReceiptCapacity.report(profile: PlayerProfile): Report
	return {
		permanent = gauge(countKeys(profile.receipts.permanent), P.MAX_PERMANENT_RECEIPTS),
		seasonal = gauge(countKeys(profile.receipts.seasonal), P.MAX_SEASONAL_RECEIPTS),
		pending = gauge(countKeys(profile.receipts.pending), P.MAX_PENDING_INTENTS),
		archives = #profile.receipts.archives,
	}
end

function ReceiptCapacity.needsArchive(profile: PlayerProfile): boolean
	return countKeys(profile.receipts.permanent)
		>= math.floor(P.MAX_PERMANENT_RECEIPTS * ReceiptCapacity.ARCHIVE_FRACTION)
end

-- Deterministic archive key for a profile's n-th archive.
function ReceiptCapacity.archiveKey(profileKey: string, index: number): string
	return string.format("%s:archive:%d", profileKey, index)
end

function ReceiptCapacity.new(deps: Deps)
	local monitor = {}

	-- Emits telemetry for gauges at warn or critical.
	function monitor.observe(profileKey: string, userId: number, profile: PlayerProfile): Report
		local report = ReceiptCapacity.report(profile)
		local gauges: { [string]: Gauge } =
			{ permanent = report.permanent, seasonal = report.seasonal, pending = report.pending }
		for name, g in gauges do
			if g.level ~= "ok" then
				deps.logger
					:with({ playerId = userId })
					:warn("persistence", "receipt_capacity_" .. g.level, {
						key = profileKey,
						ledger = name,
						count = g.count,
						max = g.max,
					})
				deps.telemetry:track(
					"receipt_capacity",
					{ ledger = name, level = g.level, userId = userId }
				)
			end
		end
		return report
	end

	-- Loads every archive a profile lists into one view. Returns nil on a
	-- store failure or a damaged record, in which case the caller must not
	-- pay a permanent grant (it cannot prove a receipt is new).
	function monitor.loadArchived(profile: PlayerProfile): ArchivedView?
		local view: ArchivedView = { receipts = {}, covers = {} }
		for _, archiveKey in profile.receipts.archives do
			local okRead, record = pcall(function()
				return deps.archiveStore:GetAsync(archiveKey)
			end)
			if not okRead or type(record) ~= "table" or type(record.receipts) ~= "table" then
				deps.logger:error(
					"persistence",
					"receipt_archive_unreadable",
					{ archiveKey = archiveKey }
				)
				return nil
			end
			for id in record.receipts do
				-- Records are never rewritten, so a receipt archived under a
				-- renamed ID is recognised under the new one here.
				view.receipts[if type(id) == "string" then LegacyIds.receipt(id) else id] = true
			end
			view.covers[archiveKey] = true
		end
		return view
	end

	-- Reads the record under `archiveKey`. Returns (true, record or nil) or
	-- (false, nil) when the store cannot be read.
	local function readRecord(archiveKey: string): (boolean, any)
		local okRead, record = pcall(function()
			return deps.archiveStore:GetAsync(archiveKey)
		end)
		if not okRead then
			return false, nil
		end
		return true, record
	end

	-- The receipt IDs of an existing record, when it can safely be adopted
	-- for this profile: it names this profile and every receipt in it is
	-- still in the profile's permanent ledger.
	local function adoptable(profileKey: string, profile: PlayerProfile, record: any): { string }?
		if
			type(record) ~= "table"
			or record.profileKey ~= profileKey
			or type(record.receipts) ~= "table"
		then
			return nil
		end
		local list: { string } = {}
		for id, flag in record.receipts do
			if type(id) ~= "string" or flag ~= true then
				return nil
			end
			-- The profile may have been migrated since the record was written.
			local current = LegacyIds.receipt(id)
			if profile.receipts.permanent[current] ~= true then
				return nil
			end
			table.insert(list, current)
		end
		if #list == 0 or record.count ~= #list then
			return nil
		end
		table.sort(list)
		return list
	end

	-- Moves the oldest half of the permanent receipts into a new archive
	-- record. Returns a mutation to enqueue (which removes them from the
	-- profile and appends the archive key) or nil with a reason. The archive
	-- record is durable and confirmed before this returns; the third value
	-- says what it holds.
	function monitor.buildArchive(
		profileKey: string,
		profile: PlayerProfile
	): (ProfileStore.Mutation?, string?, Moved?)
		if #profile.receipts.archives >= ReceiptCapacity.MAX_ARCHIVES then
			return nil, "archive limit reached", nil
		end
		local index = #profile.receipts.archives + 1
		local archiveKey = ReceiptCapacity.archiveKey(profileKey, index)

		local okExisting, existing = readRecord(archiveKey)
		if not okExisting then
			return nil, "archive store unreadable", nil
		end

		local movingList: { string }
		if existing ~= nil then
			-- An earlier attempt wrote this record but the profile was never
			-- updated. Records are never rewritten, so move exactly what it
			-- holds.
			local adopted = adoptable(profileKey, profile, existing)
			if adopted == nil then
				deps.logger:error(
					"persistence",
					"receipt_archive_conflict",
					{ key = profileKey, archiveKey = archiveKey }
				)
				deps.telemetry:track("receipt_archive_conflict", {})
				return nil, "archive record conflict", nil
			end
			movingList = adopted
			deps.logger:warn(
				"persistence",
				"receipt_archive_adopted",
				{ key = profileKey, archiveKey = archiveKey, count = #movingList }
			)
		else
			local ids = {}
			for id in profile.receipts.permanent do
				table.insert(ids, id)
			end
			if #ids < 2 then
				return nil, "nothing to archive", nil
			end
			table.sort(ids)
			local moving: { [string]: boolean } = {}
			movingList = {}
			for i = 1, math.floor(#ids / 2) do
				moving[ids[i]] = true
				table.insert(movingList, ids[i])
			end
			local count = #movingList
			local outcome = deps.profiles:writeRecord(deps.archiveStore, archiveKey, function(old)
				if old ~= nil then
					-- Never rewrite a record.
					return nil
				end
				return { profileKey = profileKey, index = index, receipts = moving, count = count }
			end)
			if outcome == "uncertain" then
				return nil, "archive write uncertain", nil
			end
			-- Confirm by reading before touching the profile.
			local okRead, record = readRecord(archiveKey)
			if not okRead or type(record) ~= "table" or record.count ~= count then
				return nil, "archive not confirmed", nil
			end
			for _, id in movingList do
				if type(record.receipts) ~= "table" or record.receipts[id] ~= true then
					return nil, "archive incomplete", nil
				end
			end
		end

		deps.logger:info(
			"persistence",
			"receipts_archived",
			{ key = profileKey, archiveKey = archiveKey, count = #movingList }
		)
		deps.telemetry:track("receipts_archived", { count = #movingList })

		local mutation: ProfileStore.Mutation = {
			id = "archive:" .. archiveKey,
			irreversible = true,
			apply = function(stored: PlayerProfile): PlayerProfile?
				if table.find(stored.receipts.archives, archiveKey) ~= nil then
					return nil
				end
				local next = table.clone(stored)
				next.receipts = table.clone(stored.receipts)
				next.receipts.permanent = table.clone(stored.receipts.permanent)
				next.receipts.archives = table.clone(stored.receipts.archives)
				for _, id in movingList do
					next.receipts.permanent[id] = nil
				end
				table.insert(next.receipts.archives, archiveKey)
				return next
			end,
			isApplied = function(stored: PlayerProfile): boolean
				return table.find(stored.receipts.archives, archiveKey) ~= nil
			end,
		}
		return mutation, nil, { archiveKey = archiveKey, receipts = movingList }
	end

	return table.freeze(monitor)
end

export type Monitor = typeof(ReceiptCapacity.new({} :: any))

return table.freeze(ReceiptCapacity)
