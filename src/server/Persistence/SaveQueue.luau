--!strict
-- Bounded save queue with coalescing, backoff and reconciliation
-- (BM-029, BM-031).
--
-- Services do not call the DataStore directly. They enqueue mutations
-- (pure transforms over the profile) per key; the queue applies them in
-- order through ProfileStore.mutate, one lease-guarded UpdateAsync per
-- flush, and retries with exponential backoff when the store fails.
-- Rules:
--   * ordering per key is preserved: a later mutation never lands before
--     an earlier one, and a failed flush keeps every mutation queued,
--   * coalescing: all queued mutations for a key go in a single write,
--   * bounded: a key may hold at most MAX_PENDING mutations; beyond that
--     enqueue is refused (the caller gets false) rather than dropping an
--     older mutation silently,
--   * uncertain writes (the store threw) keep the batch queued under the
--     same operation ID. `reconcile` reads the stored profile and, when
--     every mutation can report whether it is applied, settles the
--     operation without another write; otherwise the next flush re-applies
--     the same mutations, which must therefore be idempotent,
--   * a batch that can never succeed (schema or size) is dropped and
--     reported; the stored profile is untouched.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Clock = require(ReplicatedStorage.Shared.Sim.Clock)
local Lease = require(script.Parent.Lease)
local Logger = require(script.Parent.Parent.Logging.Logger)
local ProfileStore = require(script.Parent.ProfileStore)
local Rng = require(ReplicatedStorage.Shared.Sim.Rng)

export type Mutation = ProfileStore.Mutation

export type FlushOutcome =
	"committed"
	| "nothingToDo"
	| "noLease"
	| "rejected"
	| "uncertain"
	| "backoff"

export type Operation = { id: string, size: number, attempts: number }

export type KeyState = {
	handle: Lease.Handle,
	pending: { Mutation },
	failures: number,
	nextAttemptAt: number,
	-- The operation currently being retried: the batch it covers and its
	-- stable ID. Nil when the queue is settled.
	operation: Operation?,
	lastCommittedRevision: number?,
}

export type Deps = {
	clock: Clock.Clock,
	rng: Rng.Rng,
	logger: Logger.Logger,
	leases: Lease.Manager,
	profiles: ProfileStore.Store,
	maxPending: number?,
	backoff: { number }?,
	softBytes: number?,
	hardBytes: number?,
}

export type Queue = {
	track: (self: Queue, key: string, handle: Lease.Handle) -> (),
	untrack: (self: Queue, key: string) -> (),
	enqueue: (self: Queue, key: string, mutation: Mutation) -> boolean,
	flush: (self: Queue, key: string) -> (FlushOutcome, string?),
	flushAll: (self: Queue) -> (),
	-- Tries to settle an uncertain operation by reading. "settled" means
	-- the batch was found applied and drained; "retry" means the next
	-- flush should re-apply it.
	reconcile: (self: Queue, key: string) -> ("settled" | "retry" | "nothingToDo", string?),
	pendingCount: (self: Queue, key: string) -> number,
	state: (self: Queue, key: string) -> KeyState?,
}

local SaveQueue = {}

SaveQueue.MAX_PENDING = 64
SaveQueue.DEFAULT_BACKOFF = table.freeze({ 1, 2, 4, 8, 16, 30 })

function SaveQueue.new(deps: Deps): Queue
	local maxPending = deps.maxPending or SaveQueue.MAX_PENDING
	local backoff = deps.backoff or SaveQueue.DEFAULT_BACKOFF
	local opRng = deps.rng:fork("save-ops")
	local keys: { [string]: KeyState } = {}

	local queue = {} :: Queue

	local function log(level: Logger.Level, event: string, key: string, fields: Logger.RawFields?)
		local merged: Logger.RawFields = if fields ~= nil then table.clone(fields) else {}
		merged.key = key
		deps.logger:log(level, "persistence", event, merged)
	end

	local function newOperationId(): string
		return string.format(
			"op-%08x%08x",
			opRng:nextInteger(0, 0xFFFFFFFF),
			opRng:nextInteger(0, 0xFFFFFFFF)
		)
	end

	local function drain(state: KeyState, count: number)
		for _ = 1, count do
			table.remove(state.pending, 1)
		end
		state.operation = nil
		state.failures = 0
		state.nextAttemptAt = 0
	end

	function queue:track(key: string, handle: Lease.Handle)
		keys[key] = {
			handle = handle,
			pending = {},
			failures = 0,
			nextAttemptAt = 0,
			operation = nil,
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

		-- An operation in flight keeps its batch and ID across retries; a
		-- fresh flush takes everything queued.
		local operation: Operation
		if state.operation == nil then
			operation = { id = newOperationId(), size = #state.pending, attempts = 0 }
			state.operation = operation
		else
			operation = state.operation :: Operation
		end
		operation.attempts += 1
		local batch = table.move(state.pending, 1, operation.size, 1, {})

		local result = deps.profiles:mutate(key, state.handle, batch, {
			softBytes = deps.softBytes,
			hardBytes = deps.hardBytes,
		})

		if result.outcome == "uncertain" then
			state.failures += 1
			state.nextAttemptAt = now
				+ (backoff[math.min(state.failures, #backoff)] or backoff[#backoff])
			log("warn", "save_queue_write_uncertain", key, {
				operation = operation.id,
				attempts = operation.attempts,
				failures = state.failures,
				pending = #state.pending,
				error = result.detail or "",
			})
			return "uncertain", result.detail
		end

		if result.outcome == "rejected" then
			if result.reason == "lease" then
				state.handle.lost = true
				log(
					"error",
					"save_queue_fenced_out",
					key,
					{ operation = operation.id, pending = #state.pending }
				)
				return "noLease", result.detail
			end
			if result.reason == "noop" then
				-- Everything in the batch was already applied (for example a
				-- retry after a lost response). That is a success.
				drain(state, #batch)
				log(
					"debug",
					"save_queue_already_applied",
					key,
					{ operation = operation.id, mutations = #batch }
				)
				return "committed", nil
			end
			log("error", "save_queue_rejected", key, {
				operation = operation.id,
				reason = (result.reason :: any) :: string,
				detail = result.detail or "",
				dropped = #batch,
			})
			drain(state, #batch)
			return "rejected", result.detail
		end

		drain(state, #batch)
		state.lastCommittedRevision = result.revision
		log("debug", "save_queue_committed", key, {
			operation = operation.id,
			mutations = #batch,
			revision = result.revision or -1,
		})
		return "committed", nil
	end

	function queue:reconcile(key: string): ("settled" | "retry" | "nothingToDo", string?)
		local state = keys[key]
		if state == nil or state.operation == nil then
			return "nothingToDo", nil
		end
		local operation = state.operation :: Operation
		local batch = table.move(state.pending, 1, operation.size, 1, {})
		local verdict, detail = deps.profiles:inspect(key, batch)
		if verdict == "applied" then
			drain(state, #batch)
			log(
				"info",
				"save_queue_reconciled",
				key,
				{ operation = operation.id, mutations = #batch }
			)
			return "settled", nil
		end
		-- "notApplied" or "unknown": the next flush re-applies idempotently.
		state.nextAttemptAt = 0
		return "retry", detail
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
