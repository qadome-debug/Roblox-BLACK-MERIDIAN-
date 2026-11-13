--!strict
-- Safe profile loading (BM-028).
--
-- Turns a profile key into one of exactly three states, and never a
-- fabricated default for a player who has data:
--
--   "ready"      lease acquired, stored profile migrated and validated
--   "readOnly"   we have a profile to show but may not write it: the lease
--                is held elsewhere, the data failed validation (quarantine),
--                or the store kept failing. Gameplay stays non-mutating.
--   "failed"     nothing usable could be read within the budget
--
-- Loading retries with bounded backoff; a timeout or budget error never
-- becomes "create a fresh profile". A brand-new player (no record) is the
-- only case that starts from ProfileSchema.default(), and that happens
-- inside the lease acquisition so two servers cannot both create it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Clock = require(ReplicatedStorage.Shared.Sim.Clock)
local Lease = require(script.Parent.Lease)
local Logger = require(script.Parent.Parent.Logging.Logger)
local Migrations = require(script.Parent.Migrations)
local Profile = require(ReplicatedStorage.Shared.Types.Profile)
local ProfileSchema = require(script.Parent.ProfileSchema)

export type State = "ready" | "readOnly" | "failed"

export type Reason =
	"ok"
	| "leaseHeld"
	| "invalidProfile"
	| "unsupportedSchema"
	| "storeError"
	| "corruptRecord"

export type Loaded = {
	state: State,
	reason: Reason,
	-- Present for "ready" and, when something readable existed, "readOnly".
	profile: Profile.PlayerProfile?,
	-- Present only for "ready".
	handle: Lease.Handle?,
	-- Server-side detail for logs.
	detail: string?,
	attempts: number,
}

export type Deps = {
	clock: Clock.Clock,
	logger: Logger.Logger,
	leases: Lease.Manager,
	store: Lease.Store,
	migrator: Migrations.Migrator,
	-- Injected so tests can advance the manual clock instead of sleeping.
	wait: (seconds: number) -> (),
	maxAttempts: number?,
	-- Backoff schedule in seconds between attempts.
	backoff: { number }?,
	-- True in the `test` environment and read-only recovery: never acquire.
	readOnly: boolean?,
}

export type Loader = {
	load: (self: Loader, key: string) -> Loaded,
}

local ProfileLoader = {}

ProfileLoader.DEFAULT_BACKOFF = table.freeze({ 1, 2, 4, 8 })

local function isStoreFailure(err: any): boolean
	local text = string.lower(tostring(err))
	return string.find(text, "timed out", 1, true) ~= nil
		or string.find(text, "budget", 1, true) ~= nil
		or string.find(text, "injected error", 1, true) ~= nil
		or string.find(text, "response lost", 1, true) ~= nil
		or string.find(text, "502", 1, true) ~= nil
		or string.find(text, "503", 1, true) ~= nil
end

function ProfileLoader.new(deps: Deps): Loader
	local maxAttempts = deps.maxAttempts or (#ProfileLoader.DEFAULT_BACKOFF + 1)
	local backoff = deps.backoff or ProfileLoader.DEFAULT_BACKOFF

	local loader = {} :: Loader

	local function log(level: Logger.Level, event: string, key: string, fields: Logger.RawFields?)
		local merged: Logger.RawFields = if fields ~= nil then table.clone(fields) else {}
		merged.key = key
		deps.logger:log(level, "persistence", event, merged)
	end

	-- Reads whatever is stored and migrates + validates it without taking
	-- ownership. Used for the read-only states.
	local function peek(key: string): (Profile.PlayerProfile?, Reason, string?)
		local ok, raw = pcall(function()
			return deps.store:GetAsync(key)
		end)
		if not ok then
			return nil, "storeError", tostring(raw)
		end
		if raw == nil then
			return nil, "ok", nil
		end
		local migrated = deps.migrator:migrate(raw)
		if migrated.profile == nil then
			local reason: Reason = if string.find(migrated.error or "", "supports up to", 1, true)
				then "unsupportedSchema"
				else "corruptRecord"
			return nil, reason, migrated.error
		end
		local problems = ProfileSchema.validate(migrated.profile)
		if #problems > 0 then
			return nil, "invalidProfile", table.concat(problems, "; ")
		end
		return migrated.profile :: any, "ok", nil
	end

	function loader:load(key: string): Loaded
		if deps.readOnly then
			local profile, reason, detail = peek(key)
			log("info", "profile_load_readonly_mode", key, { reason = reason })
			return {
				state = "readOnly",
				reason = (reason :: any) :: Reason,
				profile = profile,
				detail = detail,
				attempts = 1,
			}
		end

		local attempts = 0
		local lastDetail: string? = nil
		local heldUntil: number? = nil

		while attempts < maxAttempts do
			attempts += 1
			local outcome, handle, until_ = deps.leases:acquire(key)

			if outcome == "acquired" then
				local h = handle :: Lease.Handle
				-- The acquire wrote the lease; read back the full record,
				-- migrate and validate it under our ownership.
				local okRead, raw = pcall(function()
					return deps.store:GetAsync(key)
				end)
				if not okRead then
					lastDetail = tostring(raw)
					deps.leases:release(h)
				else
					local migrated = deps.migrator:migrate(raw)
					if migrated.profile == nil then
						deps.leases:release(h)
						local reason: Reason = if string.find(
								migrated.error or "",
								"supports up to",
								1,
								true
							)
							then "unsupportedSchema"
							else "corruptRecord"
						log(
							"error",
							"profile_quarantined",
							key,
							{ reason = reason, detail = migrated.error or "" }
						)
						return {
							state = "readOnly",
							reason = (reason :: any) :: Reason,
							profile = nil,
							detail = migrated.error,
							attempts = attempts,
						}
					end
					local profile = migrated.profile :: any
					local problems = ProfileSchema.validate(profile)
					if #problems > 0 then
						deps.leases:release(h)
						local detail = table.concat(problems, "; ")
						log(
							"error",
							"profile_quarantined",
							key,
							{ reason = "invalidProfile", detail = detail }
						)
						return {
							state = "readOnly",
							reason = "invalidProfile",
							profile = nil,
							detail = detail,
							attempts = attempts,
						}
					end
					log(
						"info",
						"profile_loaded",
						key,
						{ attempts = attempts, migrated = #migrated.applied }
					)
					return {
						state = "ready",
						reason = "ok",
						profile = profile,
						handle = h,
						detail = nil,
						attempts = attempts,
					}
				end
			elseif outcome == "held" then
				heldUntil = until_
				lastDetail = "lease held until " .. tostring(until_)
				-- A live lease elsewhere is not a transient failure; one
				-- short wait covers a teleport handoff, then we read only.
				if
					until_ ~= nil
					and until_ ~= math.huge
					and until_ - deps.clock:wallTime() <= (backoff[1] or 1) * 2
				then
					deps.wait(math.max(0, until_ - deps.clock:wallTime()) + 0.1)
					continue
				end
				break
			else
				lastDetail = "acquire error"
			end

			if attempts < maxAttempts then
				deps.wait(backoff[math.min(attempts, #backoff)] or backoff[#backoff])
			end
		end

		-- Could not take ownership. Offer whatever is readable, read-only.
		local profile, reason, detail = peek(key)
		if heldUntil ~= nil then
			log("warn", "profile_load_readonly", key, { reason = "leaseHeld", attempts = attempts })
			return {
				state = "readOnly",
				reason = "leaseHeld",
				profile = profile,
				detail = lastDetail,
				attempts = attempts,
			}
		end
		if profile ~= nil or reason ~= "storeError" then
			log("warn", "profile_load_readonly", key, { reason = reason, attempts = attempts })
			return {
				state = "readOnly",
				reason = (if reason == "ok" then "storeError" else reason) :: any,
				profile = profile,
				detail = detail or lastDetail,
				attempts = attempts,
			}
		end
		log(
			"error",
			"profile_load_failed",
			key,
			{ attempts = attempts, detail = detail or lastDetail or "" }
		)
		return {
			state = "failed",
			reason = "storeError",
			profile = nil,
			detail = detail or lastDetail,
			attempts = attempts,
		}
	end

	return table.freeze(loader)
end

ProfileLoader.isStoreFailure = isStoreFailure

return table.freeze(ProfileLoader)
