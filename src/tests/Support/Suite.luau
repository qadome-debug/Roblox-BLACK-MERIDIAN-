--!strict
-- Test suite builder (BM-009).
--
-- A test module returns `Suite.new(...)` cases. Each case gets a fresh
-- environment: manual clock, seeded RNG, capturing logger, and a fake
-- DataStore service with fault injection. Nothing is shared between cases,
-- and nothing can reach a real DataStore.
--
--   local Suite = require(ServerStorage.Tests.Support.Suite)
--   local suite = Suite.new("ProfileService")
--   suite:case("loads a profile", function(env)
--       env.clock:advance(1)
--       ...
--   end)
--   return suite:cases()

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Clock = require(ReplicatedStorage.Shared.Sim.Clock)
local FakeDataStoreService = require(script.Parent.FakeDataStoreService)
local Logger = require(ServerScriptService.Server.Logging.Logger)
local Rng = require(ReplicatedStorage.Shared.Sim.Rng)

export type Env = {
	clock: Clock.ManualClock,
	rng: Rng.Rng,
	logger: Logger.Logger,
	-- Every event the logger emitted during the case, in order.
	events: { Logger.Event },
	dataStores: FakeDataStoreService.Service,
	-- Returns the events with the given category (and optionally event name).
	logged: (category: Logger.Category, event: string?) -> { Logger.Event },
}

export type Case = { name: string, run: () -> () }

export type Suite = {
	name: string,
	case: (self: Suite, name: string, run: (env: Env) -> ()) -> (),
	-- Registers the same body once per seed, for determinism checks.
	caseWithSeeds: (
		self: Suite,
		name: string,
		seeds: { number },
		run: (env: Env, seed: number) -> ()
	) -> (),
	cases: (self: Suite) -> { Case },
}

local Suite = {}

function Suite.makeEnv(seed: number?): Env
	local clock = Clock.manual(0, 1_700_000_000)
	local events: { Logger.Event } = {}
	local logger = Logger.new({
		now = function()
			return clock:wallTime()
		end,
		minLevel = "debug",
		sinks = { Logger.captureSink(events) },
	})
	local rng = Rng.new(seed or 1)
	local env = {} :: Env
	env.clock = clock
	env.rng = rng
	env.logger = logger
	env.events = events
	env.dataStores = FakeDataStoreService.new({ clock = clock, rng = rng:fork("datastore") })
	env.logged = function(category: Logger.Category, event: string?): { Logger.Event }
		local out = {}
		for _, entry in events do
			if entry.category == category and (event == nil or entry.event == event) then
				table.insert(out, entry)
			end
		end
		return out
	end
	return env
end

function Suite.new(name: string): Suite
	local registered: { Case } = {}

	local suite = {} :: Suite
	suite.name = name

	function suite:case(caseName: string, run: (env: Env) -> ())
		table.insert(registered, {
			name = caseName,
			run = function()
				run(Suite.makeEnv())
			end,
		})
	end

	function suite:caseWithSeeds(
		caseName: string,
		seeds: { number },
		run: (env: Env, seed: number) -> ()
	)
		for _, seed in seeds do
			table.insert(registered, {
				name = string.format("%s [seed %s]", caseName, tostring(seed)),
				run = function()
					run(Suite.makeEnv(seed), seed)
				end,
			})
		end
	end

	function suite:cases(): { Case }
		return registered
	end

	return suite
end

return table.freeze(Suite)
