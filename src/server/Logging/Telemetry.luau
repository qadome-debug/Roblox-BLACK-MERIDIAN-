--!strict
-- Telemetry hook (BM-008).
--
-- Gameplay and persistence code report measurable events here rather than
-- to an analytics backend directly. Each event is a sanitized log event in
-- the `telemetry` category, so the same redaction rules apply and the same
-- sinks can forward it. BM-127 attaches the real analytics sink; until then
-- events reach whatever sinks the logger has.
--
-- Telemetry never includes more player data than the event needs, and the
-- only player identifier is the numeric UserId carried by the logger
-- context.

local Logger = require(script.Parent.Logger)

export type Telemetry = {
	track: (self: Telemetry, event: string, fields: Logger.RawFields?) -> (),
	-- Counts occurrences of `event`; emitted as a field on the next track of
	-- that event or on flush.
	count: (self: Telemetry, event: string, by: number?) -> (),
	flush: (self: Telemetry) -> (),
}

local Telemetry = {}

function Telemetry.new(logger: Logger.Logger): Telemetry
	local counters: { [string]: number } = {}

	local telemetry = {} :: Telemetry

	function telemetry:track(event: string, fields: Logger.RawFields?)
		local merged: Logger.RawFields = if fields ~= nil then table.clone(fields) else {}
		local pending = counters[event]
		if pending ~= nil then
			merged.count = pending
			counters[event] = nil
		end
		logger:info("telemetry", event, merged)
	end

	function telemetry:count(event: string, by: number?)
		counters[event] = (counters[event] or 0) + (by or 1)
	end

	function telemetry:flush()
		local names = {}
		for name in counters do
			table.insert(names, name)
		end
		table.sort(names)
		for _, name in names do
			local total = counters[name]
			counters[name] = nil
			logger:info("telemetry", name, { count = total })
		end
	end

	return table.freeze(telemetry)
end

return table.freeze(Telemetry)
