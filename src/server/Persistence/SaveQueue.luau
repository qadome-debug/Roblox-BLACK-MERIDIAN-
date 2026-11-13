--!strict
-- Bounded save queue with coalescing and backoff (BM-029).
--
-- Services do not call the DataStore directly. They enqueue mutations
-- (pure transforms over the profile) per key; the queue applies them in
-- order inside one UpdateAsync per flush, guarded by the lease, and
-- retries with exponential backoff when the store fails. Rules:
--   * ordering per key is preserved: a later mutation never lands before
--     an earlier one, and a failed flush keeps every mutation queued,
--   * coalescing: all queued mutations for a key are applied in a single
--     UpdateAsync, so bursts cost one write,
--   * bounded: a key may hold at most MAX_PENDING mutations; beyond that
--     enqueue is refused (the caller gets false) rather than dropping an
--     older mutation silently,
--   * no write is attempted without a valid lease handle, and a transform
--     that produces an invalid or oversized profile cancels the whole
--     flush (nothing partial is ever stored),
--   * an UpdateAsync that throws leaves the batch queued and marks the key
--     uncertain; the next flush re-applies the same mutations, which must
--     therefore be idempotent on the stored state (receipts make reward
--     grants so; BM-031 handles the reconciliation).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Clock = require(ReplicatedStorage.Shared.Sim.Clock)
local Lease = require(script.Parent.Lease)
local Logger = require(script.Parent.Parent.Logging.Logger)
local Profile = require(ReplicatedStorage.Shared.Types.Profile)
local ProfileSchema = require(script.Parent.ProfileSchema)
local ProfileSize = require(script.Parent.ProfileSize)

export type PlayerProfile = Profile.PlayerProfile

-- A mutation receives the stored profile (already lease-guarded) and
-- returns the next profile, or nil to make no change. It must be pure and
-- idempotent with respect to the stored state.
export type Mutation = {
	id: string,
	apply: (profile: PlayerProfile) -> PlayerProfile?,
	-- Marks a mutation whose effect must never be dropped on size overflow
	-- (receipts, quest consequences). Informational for logs; all mutations
	-- are kept queued on failure regardless.
	irreversible: boolean?,
}

export type FlushOutcome =
	"committed"
	| "nothingToDo"
	| "noLease"
	| "rejected"
	| "uncertain"
	| "backoff"

export type KeyState = {
	handle: Lease.Handle,
	pending: { Mutation },
	failures: number,
	nextAttemptAt: number,
	uncertain: boolean,
	lastCommittedRevision: number?,
}

export type Deps = {
	clock: Clock.Clock,
	logger: Logger.Logger,
	leases: Lease.Manager,
	store: Lease.Store,
	maxPending: number?,
	backoff: { number }?,
	-- Size budgets; default to Limits.PROFILE. Tests pass small ones.
	softBytes: number?,
	hardBytes: number?,
}

export type Queue = {
	-- Registers a key with the lease handle that authorizes its writes.
	track: (self: Queue, key: string, handle: Lease.Handle) -> (),
	untrack: (self: Queue, key: string) -> (),
	-- Returns false if the key is not tracked or its queue is full.
	enqueue: (self: Queue, key: string, mutation: Mutation) -> boolean,
	-- Applies every pending mutation for the key in one write.
	flush: (self: Queue, key: string) -> (FlushOutcome, string?),
	-- Flushes every tracked key whose backoff has elapsed.
	flushAll: (self: Queue) -> (),
	pendingCount: (self: Queue, key: string) -> number,
	state: (self: Queue, key: string) -> KeyState?,
}

local SaveQueue = {}

SaveQueue.MAX_PENDING = 64
SaveQueue.DEFAULT_BACKOFF = table.freeze({ 1, 2, 4, 8, 16, 30 })

function SaveQueue.new(deps: Deps): Queue
	local maxPending = deps.maxPending or SaveQueue.MAX_PENDING
	local backoff = deps.backoff or SaveQueue.DEFAULT_BACKOFF
	local softBytes = deps.softBytes or ProfileSize.SOFT_BYTES
	local hardBytes = deps.hardBytes or ProfileSize.HARD_BYTES
	local keys: { [string]: KeyState } = {}

	local queue = {} :: Queue

	local function log(level: Logger.Level, event: string, key: string, fields: Logger.RawFields?)
		local merged: Logger.RawFields = if fields ~= nil then table.clone(fields) else {}
		merged.key = key
		deps.logger:log(level, "persistence", event, merged)
	end

	function queue:track(key: string, handle: Lease.Handle)
		keys[key] = {
			handle = handle,
			pending = {},
			failures = 0,
			nextAttemptAt = 0,
			uncertain = false,
			lastCommittedRevision = nil,
		}
	end

	function queue:untrack(key: string)
		local state = keys[key]
		if state ~= nil and #state.pending > 0 then
			log("warn", "save_queue_untracked_with_pending", key, { pending = #state.pending })
		end
		keys[key] = nil
	end

	function queue:enqueue(key: string, mutation: Mutation): boolean
		local state = keys[key]
		if state == nil then
			log("warn", "save_queue_enqueue_untracked", key, { mutation = mutation.id })
			return false
		end
		if #state.pending >= maxPending then
			log(
				"error",
				"save_queue_full",
				key,
				{ mutation = mutation.id, pending = #state.pending }
			)
			return false
		end
		table.insert(state.pending, mutation)
		return true
	end

	function queue:flush(key: string): (FlushOutcome, string?)
		local state = keys[key]
		if state == nil or #state.pending == 0 then
			return "nothingToDo", nil
		end
		local now = deps.clock:wallTime()
		if now < state.nextAttemptAt then
			return "backoff", string.format("next attempt at %d", state.nextAttemptAt)
		end
		if not deps.leases:isValid(state.handle) then
			log("error", "save_queue_no_lease", key, { pending = #state.pending })
			return "noLease", "lease not valid"
		end

		local batch = table.clone(state.pending)
		local rejection: string? = nil
		local committedRevision: number? = nil

		local ok, err = pcall(function()
			deps.store:UpdateAsync(key, function(old)
				if not Lease.guard(old, state.handle.lease, now) then
					rejection = "lease guard failed inside UpdateAsync"
					return nil
				end
				local profile: PlayerProfile = old
				for _, mutation in batch do
					local next = mutation.apply(profile)
					if next ~= nil then
						profile = next
					end
				end
				-- Carry the lease through unchanged; mutations never touch it.
				profile.lease = old.lease
				profile.revision = (old.revision or 0) + 1
				local problems = ProfileSchema.validate(profile)
				if #problems > 0 then
					rejection = "mutation produced an invalid profile: "
						.. table.concat(problems, "; ")
					return nil
				end
				local bytes = ProfileSize.encodedBytes(profile)
				local verdict = ProfileSize.classifyWith(bytes, softBytes, hardBytes)
				if verdict == "hard" then
					rejection = string.format(
						"mutation would make the profile %d bytes, over the hard limit",
						bytes
					)
					return nil
				elseif verdict == "soft" then
					log("warn", "profile_size_soft_limit", key, { bytes = bytes })
				end
				committedRevision = profile.revision
				return profile
			end)
		end)

		if not ok then
			state.failures += 1
			state.uncertain = true
			state.nextAttemptAt = now
				+ (backoff[math.min(state.failures, #backoff)] or backoff[#backoff])
			log("warn", "save_queue_write_uncertain", key, {
				error = tostring(err),
				failures = state.failures,
				pending = #state.pending,
			})
			return "uncertain", tostring(err)
		end

		if rejection ~= nil then
			if string.find(rejection :: string, "lease guard", 1, true) then
				state.handle.lost = true
				log("error", "save_queue_fenced_out", key, { pending = #state.pending })
				return "noLease", rejection
			end
			-- The batch can never succeed as written: drop it and report,
			-- keeping the stored profile exactly as it was.
			log(
				"error",
				"save_queue_rejected",
				key,
				{ detail = rejection :: string, dropped = #batch }
			)
			for i = #batch, 1, -1 do
				table.remove(state.pending, i)
			end
			state.failures = 0
			return "rejected", rejection
		end

		-- Committed: drop exactly the mutations that were in the batch.
		for _ = 1, #batch do
			table.remove(state.pending, 1)
		end
		state.failures = 0
		state.uncertain = false
		state.nextAttemptAt = 0
		state.lastCommittedRevision = committedRevision
		log(
			"debug",
			"save_queue_committed",
			key,
			{ mutations = #batch, revision = committedRevision or -1 }
		)
		return "committed", nil
	end

	function queue:flushAll()
		local names = {}
		for key in keys do
			table.insert(names, key)
		end
		table.sort(names)
		for _, key in names do
			queue:flush(key)
		end
	end

	function queue:pendingCount(key: string): number
		local state = keys[key]
		return if state ~= nil then #state.pending else 0
	end

	function queue:state(key: string): KeyState?
		return keys[key]
	end

	return table.freeze(queue)
end

return table.freeze(SaveQueue)
