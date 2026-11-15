--!strict
-- A server without DataStore access stays up and keeps every player
-- non-mutating.

local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local Assert = require(ServerStorage.Tests.Support.Assert)
local Config = require(ServerScriptService.Server.Config)
local ProfileService = require(ServerScriptService.Server.Services.ProfileService)
local Suite = require(ServerStorage.Tests.Support.Suite)
local Telemetry = require(ServerScriptService.Server.Logging.Telemetry)
local UnavailableStore = require(ServerScriptService.Server.Persistence.UnavailableStore)

local suite = Suite.new("UnavailableStore")

suite:case("every operation fails with the reason and nothing is fabricated", function(env)
	local store = UnavailableStore.new("BMProfiles", "place not published")
	Assert.throws(function()
		store:GetAsync("k")
	end, "place not published")
	Assert.throws(function()
		store:UpdateAsync("k", function()
			return {}
		end)
	end, "unavailable")

	local loaded = { value = false }
	local service = ProfileService.new({
		config = Config.build("studio"),
		clock = env.clock,
		rng = env.rng,
		logger = env.logger,
		telemetry = Telemetry.new(env.logger),
		markProfileLoaded = function(_player, value)
			loaded.value = value
		end,
		stores = { profiles = store :: any, runs = store :: any, archives = store :: any },
		jobId = "studio",
		wait = function(seconds)
			env.clock:advance(seconds)
		end,
	})
	local entry = service:onPlayerAdded({ UserId = 1, Name = "p1" })
	Assert.equal(entry.state, "failed", "failed, not default")
	Assert.isNil(entry.profile, "no profile")
	Assert.isFalse(loaded.value, "session never marked loaded")
	service:onPlayerRemoving({ UserId = 1, Name = "p1" }) -- must not throw
	service:tick()
	service:shutdown()
end)

return suite:cases()
