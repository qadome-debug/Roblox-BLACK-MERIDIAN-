--!strict
-- Fenced session leases on profile keys (BM-025, BM-026, BM-027).
--
-- A profile may be mutated only by the server that holds its lease. The
-- lease lives inside the stored profile, so ownership is decided by the
-- same atomic UpdateAsync that writes data, not by an in-memory lock:
--
--   acquire   atomic: succeeds if there is no lease, the lease expired, or
--             the lease is ours; a takeover gets a higher fence
--   renew     atomic: succeeds only if owner and fence still match
--   release   atomic: only the owner may expire its lease (fence is kept)
--   guard     the check every mutation transform runs before writing
--
-- A server that loses its lease (renewal rejected) must stop writing even
-- though it still has the profile in memory. Teleport handoff is a
-- conditional release by the departing server followed by a normal acquire
-- on the arriving one; the arriving server never assumes the release
-- happened and simply retries after the old lease's expiry if it must.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Clock = require(ReplicatedStorage.Shared.Sim.Clock)
local Limits = require(ReplicatedStorage.Shared.Constants.Limits)
local Logger = require(script.Parent.Parent.Logging.Logger)
local Profile = require(ReplicatedStorage.Shared.Types.Profile)
local ProfileSchema = require(script.Parent.ProfileSchema)
local Rng = require(ReplicatedStorage.Shared.Sim.Rng)

export type SessionLease = Profile.SessionLease

-- The DataStore surface the lease code needs; satisfied by the real
-- GlobalDataStore and by tests/Support/FakeDataStoreService.
export type Store = {
	UpdateAsync: (self: Store, key: string, transform: (old: any) -> any) -> any,
	GetAsync: (self: Store, key: string) -> any,
}

-- What a server holds for a profile it owns.
export type Handle = {
	key: string,
	lease: SessionLease,
	-- Set when a renewal was rejected: no more writes.
	lost: boolean,
	-- Set when a renewal threw without a definitive answer. Writes may
	-- continue until expiresAt; the next renewal settles it.
	uncertain: boolean,
}

export type Outcome = "acquired" | "held" | "renewed" | "lost" | "released" | "uncertain" | "error"

export type Deps = {
	clock: Clock.Clock,
	rng: Rng.Rng,
	logger: Logger.Logger,
	store: Store,
	jobId: string,
	lifetimeSeconds: number?,
}

export type Manager = {
	sessionId: string,
	-- Tries once. "held" means another live owner has it; `until` says when
	-- that lease expires so the caller can retry.
	acquire: (self: Manager, key: string) -> (Outcome, Handle?, number?),
	renew: (self: Manager, handle: Handle) -> Outcome,
	release: (self: Manager, handle: Handle) -> Outcome,
	-- True while the handle may be used for writes.
	isValid: (self: Manager, handle: Handle) -> boolean,
	-- Renews every held handle that is due. Call on a timer.
	tick: (self: Manager) -> (),
	-- Handles due for renewal at or before `now`.
	dueForRenewal: (self: Manager, now: number) -> { Handle },
	held: (self: Manager) -> { Handle },
}

local Lease = {}

Lease.LIFETIME_SECONDS = Limits.LEASE.LIFETIME_SECONDS
Lease.RENEWAL_INTERVAL_SECONDS = Limits.LEASE.RENEWAL_INTERVAL_SECONDS

-- The check every mutation transform runs: the stored lease must be ours,
-- with our fence, and unexpired at `now`.
function Lease.guard(stored: any, lease: SessionLease, now: number): boolean
	if type(stored) ~= "table" then
		return false
	end
	local current = stored.lease
	return type(current) == "table"
		and current.sessionId == lease.sessionId
		and current.fence == lease.fence
		and type(current.expiresAt) == "number"
		and current.expiresAt > now
end

local function isLiveLease(value: any, now: number): boolean
	return type(value) == "table" and type(value.expiresAt) == "number" and value.expiresAt > now
end

function Lease.new(deps: Deps): Manager
	local lifetime = deps.lifetimeSeconds or Lease.LIFETIME_SECONDS
	local sessionId = string.format(
		"%s-%08x%08x",
		string.sub(deps.jobId, 1, 8),
		deps.rng:nextInteger(0, 0xFFFFFFFF),
		deps.rng:nextInteger(0, 0xFFFFFFFF)
	)
	local handles: { [string]: Handle } = {}

	local manager = {} :: Manager
	manager.sessionId = sessionId

	local function log(level: Logger.Level, event: string, key: string, fields: Logger.RawFields?)
		local merged: Logger.RawFields = if fields ~= nil then table.clone(fields) else {}
		merged.key = key
		merged.sessionId = sessionId
		deps.logger:log(level, "persistence", event, merged)
	end

	function manager:acquire(key: string): (Outcome, Handle?, number?)
		local now = deps.clock:wallTime()
		local heldUntil: number? = nil
		local granted: SessionLease? = nil

		local ok, err = pcall(function()
			deps.store:UpdateAsync(key, function(old)
				local profile: any
				if old == nil then
					profile = ProfileSchema.default()
				elseif type(old) == "table" then
					profile = old
				else
					-- Not a profile at all: never overwrite it.
					heldUntil = math.huge
					return nil
				end
				local current = profile.lease
				if isLiveLease(current, now) and current.sessionId ~= sessionId then
					heldUntil = current.expiresAt
					return nil
				end
				local previousFence = if type(current) == "table"
						and type(current.fence) == "number"
					then current.fence
					else 0
				local lease: SessionLease = {
					sessionId = sessionId,
					jobId = deps.jobId,
					fence = previousFence + 1,
					expiresAt = now + lifetime,
				}
				profile.lease = lease
				granted = lease
				return profile
			end)
		end)

		if not ok then
			log("warn", "lease_acquire_error", key, { error = tostring(err) })
			return "error", nil, nil
		end
		if granted == nil then
			log("info", "lease_held_elsewhere", key, { heldUntil = heldUntil or -1 })
			return "held", nil, heldUntil
		end
		local handle: Handle =
			{ key = key, lease = granted :: SessionLease, lost = false, uncertain = false }
		handles[key] = handle
		log("info", "lease_acquired", key, { fence = (granted :: SessionLease).fence })
		return "acquired", handle, nil
	end

	function manager:renew(handle: Handle): Outcome
		if handle.lost then
			return "lost"
		end
		local now = deps.clock:wallTime()
		local renewed: SessionLease? = nil

		local ok, err = pcall(function()
			deps.store:UpdateAsync(handle.key, function(old)
				if not Lease.guard(old, handle.lease, now) then
					return nil
				end
				local lease: SessionLease = {
					sessionId = sessionId,
					jobId = deps.jobId,
					fence = handle.lease.fence,
					expiresAt = now + lifetime,
				}
				old.lease = lease
				renewed = lease
				return old
			end)
		end)

		if not ok then
			-- The renewal may have committed. Keep the old expiry as the
			-- truth and try again soon.
			handle.uncertain = true
			log("warn", "lease_renew_uncertain", handle.key, { error = tostring(err) })
			return "uncertain"
		end
		if renewed == nil then
			handle.lost = true
			handles[handle.key] = nil
			log("error", "lease_lost", handle.key, { fence = handle.lease.fence })
			return "lost"
		end
		handle.lease = renewed :: SessionLease
		handle.uncertain = false
		return "renewed"
	end

	function manager:release(handle: Handle): Outcome
		handles[handle.key] = nil
		if handle.lost then
			return "lost"
		end
		local now = deps.clock:wallTime()
		local released = false
		local ok, err = pcall(function()
			deps.store:UpdateAsync(handle.key, function(old)
				if type(old) ~= "table" then
					return nil
				end
				local current = old.lease
				if
					type(current) ~= "table"
					or current.sessionId ~= sessionId
					or current.fence ~= handle.lease.fence
				then
					return nil
				end
				-- Expire in place rather than delete, so the fence keeps counting
				-- up across releases and a stale holder can never match it.
				current.expiresAt = 0
				released = true
				return old
			end)
		end)
		handle.lost = true
		if not ok then
			log("warn", "lease_release_uncertain", handle.key, { error = tostring(err), now = now })
			return "uncertain"
		end
		if not released then
			log("warn", "lease_release_not_owner", handle.key)
			return "lost"
		end
		log("info", "lease_released", handle.key)
		return "released"
	end

	function manager:isValid(handle: Handle): boolean
		return not handle.lost and handle.lease.expiresAt > deps.clock:wallTime()
	end

	function manager:dueForRenewal(now: number): { Handle }
		local due = {}
		for _, handle in handles do
			if
				handle.uncertain
				or handle.lease.expiresAt - now <= lifetime - Lease.RENEWAL_INTERVAL_SECONDS
			then
				table.insert(due, handle)
			end
		end
		table.sort(due, function(a, b)
			return a.key < b.key
		end)
		return due
	end

	function manager:tick()
		for _, handle in manager:dueForRenewal(deps.clock:wallTime()) do
			manager:renew(handle)
		end
	end

	function manager:held(): { Handle }
		local out = {}
		for _, handle in handles do
			table.insert(out, handle)
		end
		table.sort(out, function(a, b)
			return a.key < b.key
		end)
		return out
	end

	return table.freeze(manager)
end

return table.freeze(Lease)
