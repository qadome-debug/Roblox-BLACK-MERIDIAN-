--!strict
-- Black Meridian server entry point.
--
-- The composition root: the only place that detects the environment and
-- constructs services, in the order given in docs/architecture.md. Nothing
-- here may touch DataStores or grant anything until the task that owns
-- that behaviour lands.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local ClientHello = require(script.Parent.Network.Adapters.ClientHello)
local Clock = require(ReplicatedStorage.Shared.Sim.Clock)
local Config = require(script.Parent.Config)
local Dispatcher = require(script.Parent.Network.Dispatcher)
local Logger = require(script.Parent.Logging.Logger)
local Protocol = require(ReplicatedStorage.Shared.Contracts.Protocol)
local RateLimiter = require(script.Parent.Network.RateLimiter)
local Remotes = require(script.Parent.Network.Remotes)
local Rng = require(ReplicatedStorage.Shared.Sim.Rng)
local Session = require(script.Parent.Network.Session)
local Telemetry = require(script.Parent.Logging.Telemetry)

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
local telemetry = Telemetry.new(logger)

logger:info("lifecycle", "server_bootstrap_loaded", {
	environment = config.environment,
	readOnly = config.readOnly,
	scope = config.dataStoreScope,
})

-- Stage 2 (persistence, rewards) and stage 3 (gameplay services) are added
-- by the tasks that own them.

-- Stage 4: remotes and the dispatcher.
local remotes = Remotes.create(ReplicatedStorage :: any, Remotes.robloxFactory())
local findings = Remotes.audit(ReplicatedStorage :: any)
if #findings > 0 then
	for _, finding in findings do
		logger:error("security", "remote_audit_failed", { finding = finding })
	end
	error("Remotes audit failed; refusing to start")
end

local sessions = Session.new({
	clock = clock,
	rng = serverRng,
	logger = logger,
	sendEpoch = function(player, epoch)
		(remotes[Protocol.REMOTES.STATE_DELTA] :: any):FireClient(
			player,
			{ kind = "session", sessionEpoch = epoch }
		)
	end,
})
local limiter = RateLimiter.new({ clock = clock })
local dispatcher = Dispatcher.new({
	clock = clock,
	rng = serverRng,
	logger = logger,
	telemetry = telemetry,
	sessions = sessions,
	limiter = limiter,
})
dispatcher:register(ClientHello.new({ sessions = sessions, clock = clock }))
dispatcher:attach(remotes[Protocol.REMOTES.ACTION_REQUEST], remotes[Protocol.REMOTES.ACTION_RESULT])

-- Stage 5: player sessions.
Players.PlayerAdded:Connect(function(player)
	sessions:onPlayerAdded(player)
end)
Players.PlayerRemoving:Connect(function(player)
	sessions:onPlayerRemoving(player)
	limiter:forget(player.UserId)
end)
for _, player in Players:GetPlayers() do
	sessions:onPlayerAdded(player)
end

logger:info("lifecycle", "server_ready", { actions = #dispatcher:registeredActions() })
