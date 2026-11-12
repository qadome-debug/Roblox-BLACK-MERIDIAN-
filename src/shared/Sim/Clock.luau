--!strict
-- Time abstraction (BM-007).
--
-- Every service that needs time receives a Clock through its constructor.
-- Production code uses Clock.real(); tests use Clock.manual() and advance it
-- by hand, so timeouts, cooldowns, lease expiry and rate limits are exact
-- and repeatable.
--
-- Two kinds of time:
--   now()      monotonic seconds, for durations, cooldowns, and simulation.
--              Never compared across servers and never persisted.
--   wallTime() seconds since the Unix epoch, for lease expiry and receipts
--              that other servers must agree on.
--
-- A timestamp inside a client payload is data about the client, never a
-- clock. No validator or service may use one for ordering, expiry,
-- cooldowns, or any other authoritative decision.

export type Clock = {
	now: (self: Clock) -> number,
	wallTime: (self: Clock) -> number,
}

-- Structurally a Clock, so it can be injected wherever a Clock is expected.
export type ManualClock = {
	now: (self: ManualClock) -> number,
	wallTime: (self: ManualClock) -> number,
	-- Moves both monotonic and wall time forward by `seconds` (>= 0).
	advance: (self: ManualClock, seconds: number) -> (),
	-- Sets wall time directly, for example to simulate a server that
	-- started at a particular date. Monotonic time is unaffected.
	setWallTime: (self: ManualClock, wallTime: number) -> (),
}

local Clock = {}

-- Monotonic time from os.clock (high resolution, never goes backwards
-- within a process); wall time from os.time.
function Clock.real(): Clock
	local clock = {} :: Clock
	function clock:now(): number
		return os.clock()
	end
	function clock:wallTime(): number
		return os.time()
	end
	return table.freeze(clock)
end

-- A clock that only moves when told to.
function Clock.manual(startNow: number?, startWallTime: number?): ManualClock
	local monotonic = startNow or 0
	local wall = startWallTime or 1_700_000_000

	local clock = {} :: ManualClock
	function clock:now(): number
		return monotonic
	end
	function clock:wallTime(): number
		return wall
	end
	function clock:advance(seconds: number)
		if type(seconds) ~= "number" or seconds ~= seconds or seconds < 0 then
			error("ManualClock:advance expects a nonnegative number", 2)
		end
		monotonic += seconds
		wall += seconds
	end
	function clock:setWallTime(wallTime: number)
		if type(wallTime) ~= "number" or wallTime ~= wallTime then
			error("ManualClock:setWallTime expects a number", 2)
		end
		wall = wallTime
	end
	return table.freeze(clock)
end

return table.freeze(Clock)
