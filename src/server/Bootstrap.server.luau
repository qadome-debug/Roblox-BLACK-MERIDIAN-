--!strict
-- Black Meridian server entry point.
--
-- The composition root: the only place that detects the environment and
-- constructs services, in the order given in docs/architecture.md.

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CantEquip = require(script.Parent.Network.Adapters.CantEquip)
local CharacterService = require(script.Parent.Services.CharacterService)
local ClientHello = require(script.Parent.Network.Adapters.ClientHello)
local Clock = require(ReplicatedStorage.Shared.Sim.Clock)
local CombatInput = require(script.Parent.Network.Adapters.CombatInput)
local CombatService = require(script.Parent.Services.CombatService)
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
local UnavailableStore = require(script.Parent.Persistence.UnavailableStore)
local Vec3 = require(ReplicatedStorage.Shared.Sim.Vec3)
local VerseCast = require(script.Parent.Network.Adapters.VerseCast)

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
-- Opens the scoped DataStores. Production refuses to start without them;
-- Studio and development degrade to stores whose every call fails, so the
-- server stays up and players remain non-mutating (plan 2.3).
local function openStores(): ProfileService.Stores
	local names: { [string]: string } = {
		profiles = ProfileService.STORE_NAME,
		runs = "DescentRuns",
		archives = "ProfileReceiptArchive",
	}
	local stores: { [string]: any } = {}
	for field, name in names do
		local ok, result = pcall(function()
			return DataStoreService:GetDataStore(name, config.dataStoreScope)
		end)
		if ok then
			stores[field] = result
		else
			logger:error(
				"persistence",
				"datastore_unavailable",
				{ store = name, error = tostring(result) }
			)
			if config.environment == "production" then
				error("DataStore " .. name .. " unavailable in production; refusing to start")
			end
			stores[field] = UnavailableStore.new(name, tostring(result))
		end
	end
	return stores :: any
end

local profiles = ProfileService.new({
	config = config,
	clock = clock,
	rng = serverRng,
	logger = logger,
	telemetry = telemetry,
	markProfileLoaded = function(player, loaded)
		sessions:markProfileLoaded(player, loaded)
	end,
	stores = openStores(),
	jobId = if game.JobId ~= "" then game.JobId else "studio",
	wait = function(seconds)
		task.wait(seconds)
	end,
})

-- Stage 3: gameplay services.
-- Characters: the server reads positions from the character rig it owns
-- and never from anything a client sends.
local characters = CharacterService.new({ clock = clock, logger = logger, telemetry = telemetry })
local rootParts: { [number]: BasePart } = {}

local function rigFor(character: Model): CharacterService.Rig
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	return {
		position = function()
			local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
			if root == nil then
				return nil
			end
			local p = root.Position
			return Vec3.new(p.X, p.Y, p.Z)
		end,
		moveState = function()
			if humanoid == nil then
				return "Unknown"
			end
			local state = humanoid:GetState()
			if
				state == Enum.HumanoidStateType.Running
				or state == Enum.HumanoidStateType.RunningNoPhysics
			then
				local speed = humanoid.MoveDirection.Magnitude
				return if speed > 0 then "Walking" else "Idle"
			elseif
				state == Enum.HumanoidStateType.Freefall
				or state == Enum.HumanoidStateType.Jumping
			then
				return "Airborne"
			elseif state == Enum.HumanoidStateType.Swimming then
				return "Swimming"
			elseif state == Enum.HumanoidStateType.Climbing then
				return "Climbing"
			elseif state == Enum.HumanoidStateType.Seated then
				return "Seated"
			end
			return "Unknown"
		end,
		teleport = function(to)
			character:PivotTo(CFrame.new(to.x, to.y, to.z))
		end,
	}
end

local combat = CombatService.new({
	clock = clock,
	rng = serverRng,
	logger = logger,
	telemetry = telemetry,
	send = function(userId, remote, payload)
		local player = Players:GetPlayerByUserId(userId)
		if player ~= nil then
			(remotes[remote] :: any):FireClient(player, payload)
		end
	end,
	poseOf = function(userId)
		local snapshot = characters:sample(userId)
		local root: BasePart? = rootParts[userId]
		if snapshot == nil or root == nil then
			return nil
		end
		local look = root.CFrame.LookVector
		return { position = snapshot.position, facing = Vec3.new(look.X, look.Y, look.Z) }
	end,
})

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
dispatcher:register(CombatInput.new({ combat = combat }))
dispatcher:register(CantEquip.new({ profiles = profiles, combat = combat }))
dispatcher:register(VerseCast.new({ profiles = profiles, combat = combat }))
dispatcher:attach(remotes[Protocol.REMOTES.ACTION_REQUEST], remotes[Protocol.REMOTES.ACTION_RESULT])

-- Stage 5: player sessions and profiles.
local function onCharacterAdded(player: Player, character: Model)
	rootParts[player.UserId] = character:WaitForChild("HumanoidRootPart", 10) :: BasePart
	characters:onCharacterAdded(player.UserId, rigFor(character))
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid ~= nil then
		humanoid.Died:Connect(function()
			characters:onDied(player.UserId)
		end)
	end
	if not combat:hasPlayer(player.UserId) then
		combat:addPlayer(player.UserId)
	end
end

local function onPlayerAdded(player: Player)
	sessions:onPlayerAdded(player :: any)
	player.CharacterAdded:Connect(function(character)
		onCharacterAdded(player, character)
	end)
	player.CharacterRemoving:Connect(function()
		characters:onCharacterRemoving(player.UserId)
		rootParts[player.UserId] = nil
	end)
	if player.Character ~= nil then
		onCharacterAdded(player, player.Character :: Model)
	end
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
	combat:removePlayer((player :: any).UserId)
	characters:onCharacterRemoving((player :: any).UserId)
	rootParts[(player :: any).UserId] = nil
	sessions:onPlayerRemoving(player :: any)
	limiter:forget((player :: any).UserId)
end)
for _, player in Players:GetPlayers() do
	onPlayerAdded(player)
end

-- Maintenance tick: about once a second, never faster.
local accumulator = 0
RunService.Heartbeat:Connect(function(dt)
	combat:tick(dt)
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
