--!strict
-- Black Meridian server entry point.
--
-- The composition root: the only place that detects the environment and
-- constructs services, in the order given in docs/architecture.md. Nothing
-- here may create remotes, touch DataStores, or grant anything until the
-- task that owns that behaviour lands.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Clock = require(ReplicatedStorage.Shared.Sim.Clock)
local Config = require(script.Parent.Config)
local Logger = require(script.Parent.Logging.Logger)
local Rng = require(ReplicatedStorage.Shared.Sim.Rng)

-- Stage 1: configuration, clock, logging.
local function detectEnvironment(): Config.Environment
	if RunService:IsStudio() then
		return "studio"
	end
	-- Development and production places are told apart by a server-owned
	-- attribute set on the place itself, never by anything a client sends.
	-- Until deployment controls (BM-135) define that attribute, every
	-- non-Studio server is treated as production: the safest default.
	return "production"
end

local config = Config.build(detectEnvironment())
local clock = Clock.real()
local serverRng = Rng.new(clock:wallTime() + clock:now())

local logger = Logger.new({
	now = function()
		return clock:wallTime()
	end,
	minLevel = if config.environment == "production" then "info" else "debug",
}):with({ correlationId = Logger.correlationId(serverRng:fork("server")) })

logger:info("lifecycle", "server_bootstrap_loaded", {
	environment = config.environment,
	readOnly = config.readOnly,
	scope = config.dataStoreScope,
})
