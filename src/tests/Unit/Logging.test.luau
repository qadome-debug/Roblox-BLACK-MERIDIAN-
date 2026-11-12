--!strict
-- BM-008: event schema, redaction, and sink isolation.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Logger = require(ServerScriptService.Server.Logging.Logger)
local Redact = require(ServerScriptService.Server.Logging.Redact)
local Rng = require(ReplicatedStorage.Shared.Sim.Rng)
local Telemetry = require(ServerScriptService.Server.Logging.Telemetry)

local cases = {}
local function case(name: string, run: () -> ())
	table.insert(cases, { name = name, run = run })
end

local function capture(minLevel: Logger.Level?): (Logger.Logger, { Logger.Event })
	local events: { Logger.Event } = {}
	local t = 100
	local logger = Logger.new({
		now = function()
			t += 1
			return t
		end,
		minLevel = minLevel,
		sinks = { Logger.captureSink(events) },
	})
	return logger, events
end

case("events carry the schema and sanitized fields", function()
	local logger, events = capture()
	logger:info("persistence", "profile_loaded", { userId = 42, bytes = 1024, cached = false })
	assert(#events == 1, "one event")
	local event = events[1]
	assert(event.ts == 101, "timestamp from injected clock")
	assert(event.level == "info" and event.category == "persistence", "level/category")
	assert(event.event == "profile_loaded", "event name")
	assert(
		event.fields.userId == 42 and event.fields.bytes == 1024 and event.fields.cached == false,
		"fields"
	)
	assert(event.fields.redacted == nil, "nothing altered")
	assert(event.correlationId == nil and event.playerId == nil, "no context by default")
end)

case("secrets are redacted by key", function()
	local logger, events = capture()
	logger:warn("security", "auth_failed", {
		token = "abc",
		apiKey = "xyz",
		sessionSecret = "s",
		Authorization = "Bearer q",
		userPassword = "p",
		reason = "expired",
	})
	local fields = events[1].fields
	for _, key in { "token", "apiKey", "sessionSecret", "Authorization", "userPassword" } do
		assert(fields[key] == Redact.REDACTED, key .. " must be redacted")
	end
	assert(fields.reason == "expired", "non-secret kept")
	assert(fields.redacted == 5, "altered count")
end)

case("tables, functions and other non-scalars never reach a sink", function()
	local logger, events = capture()
	local profile = { balances = { gold = 10 }, receipts = { permanent = { a = true } } }
	logger:error("persistence", "save_failed", {
		profile = profile,
		callback = function() end,
		payload = { questId = "q" },
		message = "timeout",
	})
	local fields = events[1].fields
	assert(fields.profile == "[dropped:table]", "profile dump dropped")
	assert(fields.callback == "[dropped:function]", "function dropped")
	assert(fields.payload == "[dropped:table]", "payload dropped")
	assert(fields.message == "timeout", "scalar kept")
	for _, value in fields do
		assert(type(value) ~= "table", "no nested tables in fields")
	end
end)

case("strings are truncated and non-finite numbers stringified", function()
	local logger, events = capture()
	logger:info(
		"gameplay",
		"long_values",
		{ text = string.rep("x", 1000), nan = 0 / 0, inf = math.huge }
	)
	local fields = events[1].fields
	assert(#(fields.text :: string) == Redact.MAX_STRING_BYTES + #"[truncated]", "truncated length")
	assert(string.sub(fields.text :: string, -11) == "[truncated]", "truncation marker")
	assert(fields.nan == "[nan]" and fields.inf == "[inf]", "non-finite numbers")
end)

case("field keys and counts are bounded; reserved keys are dropped", function()
	local logger, events = capture()
	local many: { [string]: unknown } = {}
	for i = 1, 40 do
		many["f" .. string.format("%02d", i)] = i
	end
	many["bad key"] = 1
	many["1leading"] = 1
	many.ts = 999
	many.level = "error"
	many.event = "forged"
	logger:info("network", "request", many)
	local event = events[1]
	local count = 0
	for key in event.fields do
		if key ~= "redacted" then
			count += 1
		end
	end
	assert(count == Redact.MAX_FIELDS, "field cap, got " .. count)
	assert(event.fields["bad key"] == nil and event.fields["1leading"] == nil, "bad keys dropped")
	assert(
		event.ts == 101 and event.level == "info" and event.event == "request",
		"envelope not forged"
	)
	assert(
		event.fields.ts == nil and event.fields.level == nil and event.fields.event == nil,
		"reserved dropped"
	)
end)

case("invalid event names and categories are normalized, never thrown", function()
	local logger, events = capture()
	logger:info("gameplay", "Bad Name!", { a = 1 })
	logger:log("info", "nonsense" :: any, "x", nil)
	logger:log("loud" :: any, "gameplay", "y", nil)
	assert(events[1].event == "invalid_event_name", "bad name replaced")
	assert(events[1].fields.originalEvent == "Bad Name!", "original kept as a field")
	assert(events[2].category == "lifecycle", "unknown category normalized")
	assert(events[3].level == "warn", "unknown level normalized")
end)

case("levels below the minimum are dropped", function()
	local logger, events = capture("warn")
	logger:debug("gameplay", "a")
	logger:info("gameplay", "b")
	logger:warn("gameplay", "c")
	logger:error("gameplay", "d")
	assert(
		#events == 2 and events[1].event == "c" and events[2].event == "d",
		"only warn and error"
	)
end)

case("with() binds correlation and player context", function()
	local logger, events = capture()
	local request = logger:with({ correlationId = "abc123", playerId = 7 })
	request:info("network", "request_received")
	local inner = request:with({ correlationId = "def456" })
	inner:info("network", "request_dispatched")
	logger:info("network", "unrelated")
	assert(events[1].correlationId == "abc123" and events[1].playerId == 7, "bound context")
	assert(events[2].correlationId == "def456" and events[2].playerId == 7, "override keeps player")
	assert(events[3].correlationId == nil and events[3].playerId == nil, "parent unaffected")
	assert(table.isfrozen(request.context), "context frozen")
end)

case("a failing sink does not stop other sinks or throw", function()
	local events: { Logger.Event } = {}
	local logger = Logger.new({
		now = function()
			return 0
		end,
		sinks = {
			function(_event: Logger.Event)
				error("sink exploded")
			end,
			Logger.captureSink(events),
		},
	})
	logger:info("lifecycle", "still_logged")
	assert(#events == 1 and events[1].event == "still_logged", "second sink ran")
end)

case("addSink receives later events", function()
	local logger, events = capture()
	local extra: { Logger.Event } = {}
	logger:addSink(Logger.captureSink(extra))
	logger:info("gameplay", "after")
	assert(#events == 1 and #extra == 1, "both sinks")
end)

case("formatLine is one line with stable key order and quoting", function()
	local line = Logger.formatLine({
		ts = 1,
		level = "error",
		category = "security",
		event = "replay_detected",
		correlationId = "c1",
		playerId = 9,
		fields = { zeta = "has space", alpha = 2, mid = true },
	})
	assert(
		line
			== '[BlackMeridian] ERROR security replay_detected correlationId=c1 playerId=9 alpha=2 mid=true zeta="has space"',
		"got: " .. line
	)
	assert(not string.find(line, "\n"), "single line")
end)

case("correlation ids are 16 hex chars and deterministic per seed", function()
	local a = Logger.correlationId(Rng.new(1))
	local b = Logger.correlationId(Rng.new(1))
	local c = Logger.correlationId(Rng.new(2))
	assert(a == b, "deterministic")
	assert(a ~= c, "distinct")
	assert(#a == 16 and string.match(a, "^[0-9a-f]+$"), "format: " .. a)
end)

case("telemetry events go through the logger with counts", function()
	local logger, events = capture()
	local telemetry = Telemetry.new(logger)
	telemetry:count("descent_abandoned")
	telemetry:count("descent_abandoned", 2)
	telemetry:track("descent_abandoned", { tier = "t1", profile = { secret = 1 } })
	telemetry:count("verse_cast")
	telemetry:flush()
	assert(#events == 2, "two events")
	assert(events[1].category == "telemetry" and events[1].event == "descent_abandoned", "first")
	assert(events[1].fields.count == 3 and events[1].fields.tier == "t1", "merged count")
	assert(events[1].fields.profile == "[dropped:table]", "sanitized")
	assert(events[2].event == "verse_cast" and events[2].fields.count == 1, "flushed counter")
end)

return cases
