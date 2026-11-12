--!strict
-- Structured server logger (BM-008).
--
-- Every log line is a typed event: timestamp, level, category, a snake_case
-- event name, optional correlation and player IDs, and flat sanitized
-- fields. Sinks receive the event table; the default sink prints one line.
-- A logger never throws: bad input is sanitized and noted, and a failing
-- sink is isolated so logging can never take the server down.
--
-- Categories are the error taxonomy used for triage. `security` and
-- `persistence` events are what incident response searches for first.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Redact = require(script.Parent.Redact)
local Rng = require(ReplicatedStorage.Shared.Sim.Rng)

export type Level = "debug" | "info" | "warn" | "error"

export type Category =
	"lifecycle" -- server start, stage completion, shutdown
	| "config" -- configuration and flags
	| "network" -- remotes, dispatcher, validation rejections
	| "security" -- authorization failures, replay, rate limits, abuse
	| "persistence" -- DataStore, leases, migrations, save queue
	| "reward" -- grants, receipts, reconciliation
	| "gameplay" -- services acting on legal requests
	| "telemetry" -- analytics events (BM-127)

export type Fields = Redact.Fields

-- What callers pass in: any table, because it is sanitized by Redact before
-- anything reads it. Sinks only ever see `Fields`.
export type RawFields = { [string]: any }

export type Event = {
	ts: number,
	level: Level,
	category: Category,
	event: string,
	correlationId: string?,
	playerId: number?,
	fields: Fields,
}

export type Sink = (event: Event) -> ()

export type Context = { correlationId: string?, playerId: number? }

export type Logger = {
	log: (
		self: Logger,
		level: Level,
		category: Category,
		event: string,
		fields: RawFields?
	) -> (),
	debug: (self: Logger, category: Category, event: string, fields: RawFields?) -> (),
	info: (self: Logger, category: Category, event: string, fields: RawFields?) -> (),
	warn: (self: Logger, category: Category, event: string, fields: RawFields?) -> (),
	error: (self: Logger, category: Category, event: string, fields: RawFields?) -> (),
	-- A logger that stamps every event with the given context.
	with: (self: Logger, context: Context) -> Logger,
	-- Registers an additional sink (telemetry, test capture, ...).
	addSink: (self: Logger, sink: Sink) -> (),
	context: Context,
}

export type Options = {
	-- Supplies `ts`; injected so tests get exact timestamps.
	now: () -> number,
	-- Events below this level are dropped. Defaults to "info".
	minLevel: Level?,
	-- Initial sinks. Defaults to the console sink.
	sinks: { Sink }?,
}

local LEVEL_RANK: { [Level]: number } = { debug = 1, info = 2, warn = 3, error = 4 }

local CATEGORIES: { [Category]: boolean } = {
	lifecycle = true,
	config = true,
	network = true,
	security = true,
	persistence = true,
	reward = true,
	gameplay = true,
	telemetry = true,
}

local EVENT_PATTERN = "^[a-z][a-z0-9_]*$"
local MAX_EVENT_LENGTH = 64

local Logger = {}

Logger.LEVELS = table.freeze({ "debug", "info", "warn", "error" })

local function formatValue(value: Redact.Scalar): string
	if type(value) == "string" then
		if string.find(value, '[%s="]') then
			return string.format("%q", value)
		end
		return value
	end
	return tostring(value)
end

-- One line per event, stable key order, safe for the Roblox Output window.
function Logger.formatLine(event: Event): string
	local parts = {
		"[BlackMeridian]",
		string.upper(event.level),
		event.category,
		event.event,
	}
	if event.correlationId ~= nil then
		table.insert(parts, "correlationId=" .. event.correlationId)
	end
	if event.playerId ~= nil then
		table.insert(parts, "playerId=" .. tostring(event.playerId))
	end
	local keys = {}
	for key in event.fields do
		table.insert(keys, key)
	end
	table.sort(keys)
	for _, key in keys do
		table.insert(parts, key .. "=" .. formatValue(event.fields[key]))
	end
	return table.concat(parts, " ")
end

function Logger.consoleSink(event: Event)
	local line = Logger.formatLine(event)
	if event.level == "warn" or event.level == "error" then
		warn(line)
	else
		print(line)
	end
end

-- 16 hex characters from the given generator. Correlation IDs tie together
-- the log lines of one request or one operation; they are not secrets.
function Logger.correlationId(rng: Rng.Rng): string
	return string.format("%08x%08x", rng:nextInteger(0, 0xFFFFFFFF), rng:nextInteger(0, 0xFFFFFFFF))
end

local function sanitizeEventName(name: unknown): (string, boolean)
	if
		type(name) == "string"
		and #name <= MAX_EVENT_LENGTH
		and string.match(name, EVENT_PATTERN)
	then
		return name, false
	end
	return "invalid_event_name", true
end

function Logger.new(options: Options): Logger
	local minLevel: Level = options.minLevel or "info"
	local minRank = LEVEL_RANK[minLevel]
	local sinks: { Sink } = if options.sinks ~= nil
		then table.clone(options.sinks)
		else { Logger.consoleSink }
	local now = options.now

	local function emit(event: Event)
		for _, sink in sinks do
			local ok, err = pcall(sink :: (Event) -> ...any, event)
			if not ok then
				-- A sink must never break logging. Report through the
				-- console directly so the failure is still visible.
				warn("[BlackMeridian] WARN lifecycle log_sink_failed error=" .. tostring(err))
			end
		end
	end

	local function make(context: Context): Logger
		local logger = {} :: Logger
		logger.context =
			table.freeze({ correlationId = context.correlationId, playerId = context.playerId })

		function logger:log(
			level: Level,
			category: Category,
			eventName: string,
			rawFields: RawFields?
		)
			local rank = LEVEL_RANK[level]
			if rank == nil then
				level = "warn"
				rank = LEVEL_RANK["warn" :: Level]
			end
			if rank < minRank then
				return
			end
			if CATEGORIES[category] == nil then
				category = "lifecycle"
			end

			local name, badName = sanitizeEventName(eventName)
			local fields, altered = Redact.fields(rawFields)
			if badName then
				fields.originalEvent = Redact.scalar(eventName)
			end
			if altered > 0 then
				fields.redacted = altered
			end

			emit({
				ts = now(),
				level = level,
				category = category,
				event = name,
				correlationId = self.context.correlationId,
				playerId = self.context.playerId,
				fields = fields,
			})
		end

		function logger:debug(category: Category, eventName: string, rawFields: RawFields?)
			self:log("debug", category, eventName, rawFields)
		end
		function logger:info(category: Category, eventName: string, rawFields: RawFields?)
			self:log("info", category, eventName, rawFields)
		end
		function logger:warn(category: Category, eventName: string, rawFields: RawFields?)
			self:log("warn", category, eventName, rawFields)
		end
		function logger:error(category: Category, eventName: string, rawFields: RawFields?)
			self:log("error", category, eventName, rawFields)
		end

		function logger:with(extra: Context): Logger
			return make({
				correlationId = extra.correlationId or self.context.correlationId,
				playerId = extra.playerId or self.context.playerId,
			})
		end

		function logger:addSink(sink: Sink)
			table.insert(sinks, sink)
		end

		return table.freeze(logger)
	end

	return make({})
end

-- A sink that records events into the given array, for tests and for
-- in-memory telemetry buffers.
function Logger.captureSink(into: { Event }): Sink
	return function(event: Event)
		table.insert(into, event)
	end
end

return table.freeze(Logger)
