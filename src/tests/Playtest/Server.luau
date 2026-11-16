--!strict
-- Studio play-test harness, server side (development only).
--
-- Mounted only by playtest.project.json and only used when Bootstrap runs
-- in Studio. It is NOT part of the game:
--
--   * `stores` gives Bootstrap in-memory DataStores, so profiles can load
--     and save in an unpublished place. Nothing here can reach a real
--     DataStore.
--   * `start` answers a control RemoteFunction (Workspace.PlaytestControl,
--     created by the play-test project file, never by the game) so the
--     client driver can ask for privileged setup steps and read server
--     state for assertions.
--
-- Shortcuts this harness takes are test scaffolding, not gameplay:
-- "grantNearness" stands in for the starter Cant selection flow that does
-- not exist yet, and "activateCant" calls the server activation directly
-- because no client request for activating a Cant has been specified.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Clock = require(ReplicatedStorage.Shared.Sim.Clock)
local Config = require(ServerScriptService.Server.Config)
local FakeDataStoreService = require(script.Parent.Parent.Support.FakeDataStoreService)
local ProfileService = require(ServerScriptService.Server.Services.ProfileService)
local Rng = require(ReplicatedStorage.Shared.Sim.Rng)

local SCOPE = Config.build("studio").dataStoreScope
local ENEMY_ID = "pt-enemy"

local dataStores = FakeDataStoreService.new({ clock = Clock.manual(), rng = Rng.new(20261115) })

local Playtest = {}

-- With the PlaytestDegraded attribute set on Workspace, no stores are
-- supplied: Bootstrap then takes its normal path (the real DataStoreService,
-- which is unavailable in an unpublished place), so the degraded mode can
-- be play-tested.
function Playtest.stores(): any?
	if Workspace:GetAttribute("PlaytestDegraded") == true then
		return nil
	end
	return {
		profiles = dataStores:GetDataStore(ProfileService.STORE_NAME, SCOPE),
		runs = dataStores:GetDataStore("DescentRuns", SCOPE),
		archives = dataStores:GetDataStore("ProfileReceiptArchive", SCOPE),
	}
end

function Playtest.start(services: { [string]: any })
	if not RunService:IsStudio() then
		error("the play-test harness only runs in Studio")
	end
	local combat = services.combat
	local profiles = services.profiles
	local control = Workspace:WaitForChild("PlaytestControl", 10) :: RemoteFunction?
	if control == nil then
		warn("[PT] Workspace.PlaytestControl is missing; build with playtest.project.json")
		return
	end

	local function state(player: Player): { [string]: any }
		local userId = player.UserId
		local profile = profiles:profileFor(userId)
		local out: { [string]: any } = {
			profileReady = profile ~= nil,
			profileState = (function(): string?
				local entry = profiles:get(player)
				return if entry ~= nil then entry.state else nil
			end)(),
			inCombat = combat:hasPlayer(userId),
			step = combat.sim:stepNumber(),
		}
		if profile ~= nil then
			out.equippedProfile = profile.cants.equipped
			out.ownsNearness = profile.cants.unlocked["cant-nearness"] == true
		end
		local stored =
			dataStores:peek(ProfileService.STORE_NAME .. "/" .. SCOPE, profiles:keyFor(userId))
		if stored ~= nil then
			out.stored = true
			out.storedEquipped = stored.cants.equipped
		end
		if out.inCombat then
			local id = combat:combatantId(userId)
			local me = combat.sim:get(id)
			out.equippedCombat = combat.cants:equipped(id)
			out.cantCooldown = combat.cants:cooldownRemaining(id)
			out.dissonance = combat.dissonance:value(id)
			out.dissonanceLevel = combat.dissonance:level(id)
			if me ~= nil then
				out.stamina = me.resources.stamina
				out.health = me.resources.health
				out.actionState = me.action.state
			end
		end
		local enemy = combat.sim:get(ENEMY_ID)
		if enemy ~= nil then
			out.enemyHealth = enemy.resources.health
			out.enemyMaxHealth = enemy.derived.maxHealth
		end
		return out
	end

	local commands: { [string]: (player: Player, arg: any) -> any } = {}

	commands.state = function(player)
		return state(player)
	end

	-- Stands in for the starter Cant selection flow (not built yet).
	commands.grantNearness = function(player)
		local ok, reason = profiles:mutate(player.UserId, {
			id = "playtest-grant-nearness",
			apply = function(profile: any): any
				if profile.cants.unlocked["cant-nearness"] == true then
					return nil
				end
				local nextProfile = table.clone(profile)
				nextProfile.cants = table.clone(profile.cants)
				nextProfile.cants.unlocked = table.clone(profile.cants.unlocked)
				nextProfile.cants.unlocked["cant-nearness"] = true
				nextProfile.cants.verses = table.clone(profile.cants.verses)
				nextProfile.cants.verses["cant-nearness"] = {}
				return nextProfile
			end,
		})
		return { ok = ok, reason = reason }
	end

	-- No client request for activating a Cant is specified; call the server
	-- activation directly.
	commands.activateCant = function(player)
		return combat.cants:activate(combat:combatantId(player.UserId))
	end

	commands.setStamina = function(player, amount)
		local me = combat.sim:get(combat:combatantId(player.UserId))
		if me ~= nil then
			me.resources.stamina = amount
		end
		return { ok = me ~= nil }
	end

	commands.addDissonance = function(player, amount)
		return {
			value = combat.dissonance:add(combat:combatantId(player.UserId), amount, "playtest"),
		}
	end

	commands.spawnEnemy = function(player)
		local character = player.Character
		local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
		if root == nil or not root:IsA("BasePart") then
			return { ok = false, reason = "no character" }
		end
		local at = root.Position + root.CFrame.LookVector * 4
		combat:despawnEnemy(ENEMY_ID)
		combat:spawnEnemy({
			id = ENEMY_ID,
			position = { x = at.X, y = at.Y, z = at.Z },
			-- Passive: never aggroes at this distance, so it only gets hit.
			profile = {
				aggroRange = 1,
				attackRange = 1,
				leashRange = 40,
				maxPathFailures = 3,
				attackCooldownSteps = 3000,
				attackJitterSteps = 0,
				repathSteps = 10,
			},
		})
		return { ok = true }
	end

	commands.save = function()
		profiles:tick()
		return { ok = true }
	end

	-- The persistence half of a reconnect on one server: release the
	-- profile (flush, lease), drop the combatant, load the profile again
	-- from the store and respawn. A real reconnect also gets a new session;
	-- that is covered by the headless suite.
	commands.rejoin = function(player)
		profiles:onPlayerRemoving(player)
		combat:removePlayer(player.UserId)
		local entry = profiles:onPlayerAdded(player)
		player:LoadCharacter()
		return { ok = entry.state == "ready", state = entry.state }
	end

	-- The driver reports its totals; when play mode was started by the
	-- runner plugin, this also ends the test session.
	commands.done = function(_, summary: any)
		local passed = if type(summary) == "table" then tonumber(summary.passed) else nil
		local failed = if type(summary) == "table" then tonumber(summary.failed) else nil
		print(
			string.format(
				"[PT] SERVER SUMMARY passed=%s failed=%s",
				tostring(passed),
				tostring(failed)
			)
		)
		task.delay(1, function()
			pcall(function()
				(game:GetService("StudioTestService") :: any):EndTest(
					string.format("passed=%s failed=%s", tostring(passed), tostring(failed))
				)
			end)
		end)
		return { ok = true }
	end

	control.OnServerInvoke = function(player: Player, command: unknown, arg: unknown): any
		local handler = if type(command) == "string" then commands[command] else nil
		if handler == nil then
			return { ok = false, reason = "unknown play-test command" }
		end
		local ok, result = pcall(handler, player, arg)
		if not ok then
			warn("[PT] command " .. tostring(command) .. " failed: " .. tostring(result))
			return { ok = false, reason = tostring(result) }
		end
		return result
	end
	print("[PT] server harness ready (Studio only)")
end

return Playtest
