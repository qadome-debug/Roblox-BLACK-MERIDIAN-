--!strict
-- Black Meridian server entry point.
--
-- The composition root: the only place that detects the environment and
-- constructs services, in the order given in docs/architecture.md.

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local ClientHello = require(script.Parent.Network.Adapters.ClientHello)
local Clock = require(ReplicatedStorage.Shared.Sim.Clock)
local Config = require(script.Parent.Config)
local Dispatcher = require(script.Parent.Network.Dispatcher)
local Logger = require(script.Parent.Logging.Logger)
local ProfileService = require(script.Parent.Services.ProfileService)
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

-- Stage 4 is created before stage 2 only in the sense that sessions must
-- exist for ProfileService to mark them; no remote is live until attach.
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

-- Stage 2: persistence and rewards.
local profiles = ProfileService.new({
	config = config,
	clock = clock,
	rng = serverRng,
	logger = logger,
	telemetry = telemetry,
	markProfileLoaded = function(player, loaded)
		sessions:markProfileLoaded(player, loaded)
	end,
	stores = {
		profiles = DataStoreService:GetDataStore(ProfileService.STORE_NAME, config.dataStoreScope) :: any,
		runs = DataStoreService:GetDataStore("DescentRuns", config.dataStoreScope) :: any,
		archives = DataStoreService:GetDataStore("ProfileReceiptArchive", config.dataStoreScope) :: any,
	},
	jobId = if game.JobId ~= "" then game.JobId else "studio",
	wait = function(seconds)
		task.wait(seconds)
	end,
})

-- Stage 3: gameplay services are added by the tasks that own them.

-- Stage 4: dispatcher and adapters.
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

-- Stage 5: player sessions and profiles.
local function onPlayerAdded(player: Player)
	sessions:onPlayerAdded(player :: any)
	-- Loading yields on the DataStore; keep the join handler responsive.
	task.spawn(function()
		local ok, err = pcall(function()
			profiles:onPlayerAdded(player :: any)
		end)
		if not ok then
			logger
				:with({ playerId = player.UserId })
				:error("persistence", "player_profile_crashed", { error = tostring(err) })
		end
	end)
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(function(player)
	local ok, err = pcall(function()
		profiles:onPlayerRemoving(player :: any)
	end)
	if not ok then
		logger
			:with({ playerId = player.UserId })
			:error("persistence", "player_leave_crashed", { error = tostring(err) })
	end
	sessions:onPlayerRemoving(player :: any)
	limiter:forget((player :: any).UserId)
end)
for _, player in Players:GetPlayers() do
	onPlayerAdded(player)
end

-- Maintenance tick: about once a second, never faster.
local accumulator = 0
RunService.Heartbeat:Connect(function(dt)
	accumulator += dt
	if accumulator >= 1 then
		accumulator = 0
		local ok, err = pcall(function()
			profiles:tick()
		end)
		if not ok then
			logger:error("persistence", "tick_crashed", { error = tostring(err) })
		end
	end
end)

game:BindToClose(function()
	local ok, err = pcall(function()
		profiles:shutdown()
	end)
	if not ok then
		logger:error("persistence", "shutdown_crashed", { error = tostring(err) })
	end
end)

logger:info("lifecycle", "server_ready", { actions = #dispatcher:registeredActions() })
