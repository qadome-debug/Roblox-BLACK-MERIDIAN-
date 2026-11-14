--!strict
-- The single place profile data is written (BM-030, BM-031).
--
-- Every durable profile mutation goes through `ProfileStore.mutate`, which
-- runs one atomic UpdateAsync that:
--   1. verifies the lease owner and fence inside the transform,
--   2. optionally verifies the expected revision (optimistic concurrency),
--   3. applies the batch of pure mutations in order,
--   4. validates the result against the schema and the size budgets,
--   5. bumps the revision and writes, or cancels with nothing changed.
--
-- Outcomes (BM-031 classification):
--   committed   the write happened; `revision` is the new revision
--   rejected    the transform cancelled: guard, revision, schema or size.
--               Nothing changed. `detail` says which.
--   uncertain   UpdateAsync threw. The write MAY have committed before the
--               error reached us. Callers keep the same operation and its
--               mutation IDs and either re-apply (mutations are idempotent)
--               or `inspect` the stored state to learn the truth. A timeout
--               is never treated as a rollback.
--
-- tools/check-persistence.luau enforces that no other module under src/
-- calls UpdateAsync, SetAsync or RemoveAsync on anything.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Lease = require(script.Parent.Lease)
local Logger = require(script.Parent.Parent.Logging.Logger)
local Profile = require(ReplicatedStorage.Shared.Types.Profile)
local ProfileSchema = require(script.Parent.ProfileSchema)
local ProfileSize = require(script.Parent.ProfileSize)

export type PlayerProfile = Profile.PlayerProfile

export type Mutation = {
	id: string,
	-- Pure; receives the stored profile and returns the next one, or nil
	-- for no change. Must be idempotent on already-mutated state.
	apply: (profile: PlayerProfile) -> PlayerProfile?,
	-- Optional: reports whether the stored profile already reflects this
	-- mutation, so an uncertain write can be settled by reading.
	isApplied: ((profile: PlayerProfile) -> boolean)?,
	irreversible: boolean?,
}

export type Outcome = "committed" | "rejected" | "uncertain"

export type RejectReason = "lease" | "revision" | "schema" | "size" | "noop"

export type Result = {
	outcome: Outcome,
	-- For "rejected".
	reason: RejectReason?,
	detail: string?,
	-- For "committed".
	revision: number?,
	bytes: number?,
	sizeVerdict: ProfileSize.Verdict?,
}

export type Options = {
	-- When set, the write happens only if the stored revision equals it.
	expectedRevision: number?,
	softBytes: number?,
	hardBytes: number?,
}

export type Deps = {
	store: Lease.Store,
	logger: Logger.Logger,
	now: () -> number,
}

export type Store = {
	mutate: (
		self: Store,
		key: string,
		handle: Lease.Handle,
		batch: { Mutation },
		options: Options?
	) -> Result,
	-- Reads the stored profile (raw) without taking ownership. Returns nil
	-- on store failure with the error text.
	read: (self: Store, key: string) -> (any, string?),
	-- Settles an uncertain batch by reading: "applied" when every mutation
	-- with isApplied reports true, "notApplied" when every one reports
	-- false, "unknown" otherwise (mixed, or a mutation lacks isApplied).
	inspect: (
		self: Store,
		key: string,
		batch: { Mutation }
	) -> ("applied" | "notApplied" | "unknown", string?),
}

local ProfileStore = {}

function ProfileStore.new(deps: Deps): Store
	local store = {} :: Store

	function store:mutate(
		key: string,
		handle: Lease.Handle,
		batch: { Mutation },
		options: Options?
	): Result
		local opts: Options = options or {}
		local softBytes = opts.softBytes or ProfileSize.SOFT_BYTES
		local hardBytes = opts.hardBytes or ProfileSize.HARD_BYTES
		local now = deps.now()

		local rejected: RejectReason? = nil
		local detail: string? = nil
		local committedRevision: number? = nil
		local committedBytes: number? = nil
		local verdictOut: ProfileSize.Verdict? = nil

		local ok, err = pcall(function()
			deps.store:UpdateAsync(key, function(old)
				if not Lease.guard(old, handle.lease, now) then
					rejected = "lease"
					detail = "lease guard failed inside UpdateAsync"
					return nil
				end
				if opts.expectedRevision ~= nil and old.revision ~= opts.expectedRevision then
					rejected = "revision"
					detail = string.format(
						"expected revision %d, stored %s",
						opts.expectedRevision,
						tostring(old.revision)
					)
					return nil
				end

				local profile: PlayerProfile = old
				local changed = false
				for _, mutation in batch do
					local next = mutation.apply(profile)
					if next ~= nil then
						profile = next
						changed = true
					end
				end
				if not changed then
					rejected = "noop"
					detail = "no mutation changed the profile"
					return nil
				end

				-- Mutations never touch the lease or the revision.
				profile.lease = old.lease
				profile.revision = (old.revision or 0) + 1

				local problems = ProfileSchema.validate(profile)
				if #problems > 0 then
					rejected = "schema"
					detail = table.concat(problems, "; ")
					return nil
				end
				local bytes = ProfileSize.encodedBytes(profile)
				local verdict = ProfileSize.classifyWith(bytes, softBytes, hardBytes)
				if verdict == "hard" then
					rejected = "size"
					detail =
						string.format("%d bytes exceeds the hard limit of %d", bytes, hardBytes)
					return nil
				end
				committedRevision = profile.revision
				committedBytes = bytes
				verdictOut = verdict :: any
				return profile
			end)
		end)

		if not ok then
			deps.logger:warn(
				"persistence",
				"profile_write_uncertain",
				{ key = key, error = tostring(err) }
			)
			return { outcome = "uncertain", detail = tostring(err) }
		end
		if rejected ~= nil then
			local level: Logger.Level = if rejected == "noop" then "debug" else "warn"
			deps.logger:log(level, "persistence", "profile_write_rejected", {
				key = key,
				reason = rejected :: string,
				detail = detail or "",
			})
			return { outcome = "rejected", reason = rejected, detail = detail }
		end
		if verdictOut == "soft" then
			deps.logger:warn(
				"persistence",
				"profile_size_soft_limit",
				{ key = key, bytes = committedBytes or 0 }
			)
		end
		return {
			outcome = "committed",
			revision = committedRevision,
			bytes = committedBytes,
			sizeVerdict = verdictOut :: any,
		}
	end

	function store:read(key: string): (any, string?)
		local ok, value = pcall(function()
			return deps.store:GetAsync(key)
		end)
		if not ok then
			return nil, tostring(value)
		end
		return value, nil
	end

	function store:inspect(
		key: string,
		batch: { Mutation }
	): ("applied" | "notApplied" | "unknown", string?)
		local stored, err = store:read(key)
		if err ~= nil then
			return "unknown", err
		end
		if type(stored) ~= "table" then
			return "unknown", "no stored profile"
		end
		local applied, notApplied = 0, 0
		for _, mutation in batch do
			if mutation.isApplied == nil then
				return "unknown", "mutation " .. mutation.id .. " cannot be inspected"
			end
			if (mutation.isApplied :: any)(stored) then
				applied += 1
			else
				notApplied += 1
			end
		end
		if applied == #batch then
			return "applied", nil
		elseif notApplied == #batch then
			return "notApplied", nil
		end
		return "unknown", string.format("%d applied, %d not applied", applied, notApplied)
	end

	return table.freeze(store)
end

return table.freeze(ProfileStore)
