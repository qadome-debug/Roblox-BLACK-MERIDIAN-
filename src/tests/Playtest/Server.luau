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
-- "grantNearness" and "grantNearnessVerses" stand in for the introductory
-- story that grants Nearness, which does not exist yet; which Verses come
-- with Nearness is not yet established. "addDissonance" and
-- "recoverDissonance" stand in for the world sources (Verses, areas,
-- anchors, camps) that do not exist yet.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local ActionMachine = require(ServerScriptService.Server.Combat.ActionMachine)
local Clock = require(ReplicatedStorage.Shared.Sim.Clock)
local Config = require(ServerScriptService.Server.Config)
local FakeDataStoreService = require(script.Parent.Parent.Support.FakeDataStoreService)
local ProfileService = require(ServerScriptService.Server.Services.ProfileService)
local Rng = require(ReplicatedStorage.Shared.Sim.Rng)

local SCOPE = Config.build("studio").dataStoreScope
local ENEMY_ID = "pt-enemy"

-- Demo enemies: combatants in the simulation with a visible stand-in body.
-- The bodies live under Workspace.BMDynamic, which the world queries ignore,
-- and follow the simulation every frame. They are scaffolding: the game has
-- no enemy models yet.
local demoEnemies: { [string]: Part } = {}
local drifts: { [string]: { x: number, z: number } } = {}

-- The hands-on demo (playtest-demo.project.json): targets for the four
-- Nearness Verses. Passive stand-ins; the game has no enemy models yet.
local DEMO_ENEMIES = {
	{ id = "demo-a", x = 10, z = -14, kind = "normal" },
	{ id = "demo-b", x = 15, z = -20, kind = "normal" },
	{ id = "demo-c", x = -8, z = -16, kind = "normal" },
	{ id = "demo-d", x = -15, z = -12, kind = "normal" },
	{ id = "demo-elite", x = -18, z = -26, kind = "elite" },
	{ id = "demo-boss", x = 0, z = -30, kind = "boss" },
}

local dataStores = FakeDataStoreService.new({ clock = Clock.manual(), rng = Rng.new(20261115) })

local Playtest = {}

-- With the PlaytestDegraded attribute set on Workspace, no stores are
-- supplied: Bootstrap then takes its normal path (the real DataStoreService,
-- which is unavailable in an unpublished place), so the degraded mode can
-- be play-tested.
function Playtest.stores(): any?
	if not RunService:IsStudio() then
		error("the play-test harness only runs in Studio")
	end
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
	local characters = services.characters
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
			out.ownsNearness = profile.cants.unlocked["cant.nearness"] == true
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
			out.dissonance = combat.dissonance:value(id)
			out.dissonanceLevel = combat.dissonance:level(id)
			out.dissonanceBand = combat.dissonance:band(id).name
			out.closeStepCooldown = combat.verses:cooldownRemaining(id, "near.close_step")
			if me ~= nil then
				out.stamina = me.resources.stamina
				out.health = me.resources.health
				out.actionState = me.action.state
			end
		end
		-- Positions for the Verse effect checks.
		local pose = combat.sim:get(combat:combatantId(userId))
		if pose ~= nil then
			out.pos = { x = pose.position.x, y = pose.position.y, z = pose.position.z }
		end
		local character = player.Character
		local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
		if root ~= nil and root:IsA("BasePart") then
			out.rootPos = { x = root.Position.X, y = root.Position.Y, z = root.Position.Z }
		end
		local enemies: { [string]: any } = {}
		for id in demoEnemies do
			local c = combat.sim:get(id)
			if c ~= nil then
				enemies[id] = { x = c.position.x, z = c.position.z }
			end
		end
		out.enemies = enemies
		if profile ~= nil then
			local count = 0
			for _ in profile.cants.verses["cant.nearness"] or {} do
				count += 1
			end
			out.verseCount = count
		end
		if stored ~= nil then
			local storedCount = 0
			for _ in (stored.cants.verses["cant.nearness"] or {}) do
				storedCount += 1
			end
			out.storedVerseCount = storedCount
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
				if profile.cants.unlocked["cant.nearness"] == true then
					return nil
				end
				local nextProfile = table.clone(profile)
				nextProfile.cants = table.clone(profile.cants)
				nextProfile.cants.unlocked = table.clone(profile.cants.unlocked)
				nextProfile.cants.unlocked["cant.nearness"] = true
				nextProfile.cants.verses = table.clone(profile.cants.verses)
				nextProfile.cants.verses["cant.nearness"] = {}
				return nextProfile
			end,
		})
		return { ok = ok, reason = reason }
	end

	-- Unlocks the four Nearness Verses in the profile. Harness only: which
	-- Verses a player has when Nearness is acquired is not established.
	commands.grantNearnessVerses = function(player)
		local ok, reason = profiles:mutate(player.UserId, {
			id = "playtest-grant-nearness-verses",
			apply = function(profile: any): any
				local nextProfile = table.clone(profile)
				nextProfile.cants = table.clone(profile.cants)
				nextProfile.cants.verses = table.clone(profile.cants.verses)
				nextProfile.cants.verses["cant.nearness"] = {
					["near.close_step"] = true,
					["near.draw_near"] = true,
					["near.between_us"] = true,
					["near.no_farther"] = true,
				}
				return nextProfile
			end,
		})
		return { ok = ok, reason = reason }
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
			value = combat.dissonance:add(
				combat:combatantId(player.UserId),
				amount,
				"unstableArea"
			),
		}
	end

	commands.recoverDissonance = function(player, amount)
		return {
			value = combat.dissonance:recover(combat:combatantId(player.UserId), amount, "anchor"),
		}
	end

	local function dynamicFolder(): Folder
		local existing = Workspace:FindFirstChild("BMDynamic")
		if existing ~= nil then
			return existing :: Folder
		end
		local folder = Instance.new("Folder")
		folder.Name = "BMDynamic"
		folder.Parent = Workspace
		return folder
	end

	-- The arena: a solid wall to the east and an invisible, non-colliding
	-- boundary to the north, which only the tag makes a barrier.
	commands.arena = function()
		if Workspace:FindFirstChild("BMWall") == nil then
			local wall = Instance.new("Part")
			wall.Name = "BMWall"
			wall.Anchored = true
			wall.Size = Vector3.new(2, 20, 80)
			wall.Position = Vector3.new(24, 10, 0)
			wall.Color = Color3.fromRGB(70, 70, 80)
			wall.Parent = Workspace
			local boundary = Instance.new("Part")
			boundary.Name = "BMBoundary"
			boundary.Anchored = true
			boundary.CanCollide = false
			boundary.CanQuery = true
			boundary.Transparency = 0.85
			boundary.Color = Color3.fromRGB(200, 80, 80)
			boundary.Size = Vector3.new(80, 20, 2)
			boundary.Position = Vector3.new(0, 10, -40)
			boundary.Parent = Workspace
			CollectionService:AddTag(boundary, "BM_Boundary")
		end
		return { ok = true }
	end

	local function clearEnemies()
		for id, body in demoEnemies do
			combat:despawnEnemy(id)
			body:Destroy()
		end
		table.clear(demoEnemies)
		table.clear(drifts)
	end

	-- arg: { { id, x, z, kind }, ... } in world coordinates. kind is
	-- "normal", "elite" or "boss".
	commands.setupEnemies = function(_, arg)
		clearEnemies()
		for _, spec in arg do
			local kind = spec.kind or "normal"
			combat:spawnEnemy({
				id = spec.id,
				position = { x = spec.x, y = 3, z = spec.z },
				displacement = if kind == "boss"
					then "immune"
					elseif kind == "elite" then "elite"
					else "normal",
				profile = {
					aggroRange = 1,
					attackRange = 1,
					leashRange = 2000,
					maxPathFailures = 3,
					attackCooldownSteps = 30,
					attackJitterSteps = 10,
					repathSteps = 10,
				},
			})
			local body = Instance.new("Part")
			body.Name = spec.id
			body.Anchored = true
			body.CanCollide = false
			body.Shape = Enum.PartType.Cylinder
			body.Size = if kind == "boss" then Vector3.new(10, 8, 8) else Vector3.new(5, 3.5, 3.5)
			body.Orientation = Vector3.new(0, 0, 90)
			body.Material = Enum.Material.Neon
			body.Color = if kind == "boss"
				then Color3.fromRGB(200, 40, 40)
				elseif kind == "elite" then Color3.fromRGB(220, 150, 40)
				else Color3.fromRGB(90, 160, 220)
			body:SetAttribute("CombatId", spec.id)
			body.Parent = dynamicFolder()
			demoEnemies[spec.id] = body
		end
		return { ok = true }
	end

	commands.teleport = function(player, arg)
		return { ok = characters:teleport(player.UserId, { x = arg.x, y = 3, z = arg.z }) }
	end

	-- Refills stamina and clears Verse cooldowns so each effect can be
	-- checked on its own. Harness only.
	commands.refill = function(player)
		local id = combat:combatantId(player.UserId)
		local me = combat.sim:get(id)
		if me ~= nil then
			me.resources.stamina = me.derived.maxStamina
		end
		combat.verses:forget(id)
		return { ok = me ~= nil }
	end

	commands.resetDissonance = function(player)
		local id = combat:combatantId(player.UserId)
		combat.dissonance:recover(id, 1000, "anchor")
		return { ok = true }
	end

	-- A stagger, which interrupts a cast, or a plain hit, which does not.
	commands.interrupt = function(player, kind)
		local me = combat.sim:get(combat:combatantId(player.UserId))
		if me == nil then
			return { ok = false }
		end
		ActionMachine.interrupt(me.action, kind, 6, combat.sim:stepNumber())
		return { ok = true }
	end

	-- Starts a cast and interrupts it in the same step, so the interruption
	-- cannot lose a race with the cast time. Harness only.
	commands.castThenInterrupt = function(player, arg)
		local id = combat:combatantId(player.UserId)
		local outcome = combat.verses:cast(id, arg.verseId, arg.target)
		local me = combat.sim:get(id)
		if outcome.ok and me ~= nil then
			ActionMachine.interrupt(me.action, arg.kind, 6, combat.sim:stepNumber())
		end
		return { ok = outcome.ok }
	end

	-- Moves an enemy by a fixed velocity every step, standing in for an
	-- enemy that runs away. Applied after the Verse effects of that step.
	commands.drift = function(_, arg)
		drifts[arg.id] = { x = arg.vx, z = arg.vz }
		return { ok = true }
	end

	-- Pillars and labelled signs around the arena, for the hands-on demo.
	local function sign(text: string, position: Vector3)
		local part = Instance.new("Part")
		part.Name = "BMSign"
		part.Anchored = true
		part.CanCollide = false
		part.Transparency = 1
		part.Size = Vector3.new(1, 1, 1)
		part.Position = position
		local gui = Instance.new("BillboardGui")
		gui.Size = UDim2.fromOffset(240, 50)
		gui.AlwaysOnTop = true
		gui.StudsOffset = Vector3.new(0, 0, 0)
		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundTransparency = 0.4
		label.BackgroundColor3 = Color3.fromRGB(15, 15, 20)
		label.TextColor3 = Color3.new(1, 1, 1)
		label.Font = Enum.Font.GothamMedium
		label.TextSize = 14
		label.Text = text
		label.Parent = gui
		gui.Parent = part
		part.Parent = Workspace
	end

	commands.demoArena = function(player)
		commands.arena(player, nil)
		if Workspace:FindFirstChild("BMPillar1") == nil then
			for index, spot in
				{ Vector3.new(-6, 6, -6), Vector3.new(6, 6, -9), Vector3.new(0, 6, -20) }
			do
				local pillar = Instance.new("Part")
				pillar.Name = "BMPillar" .. index
				pillar.Anchored = true
				pillar.Size = Vector3.new(4, 12, 4)
				pillar.Position = spot
				pillar.Color = Color3.fromRGB(90, 90, 100)
				pillar.Parent = Workspace
			end
			sign("WALL: Close Step stops short of it", Vector3.new(22, 14, 0))
			sign("INVISIBLE BOUNDARY: nothing crosses it", Vector3.new(0, 14, -38))
			sign("PILLARS block line of sight", Vector3.new(0, 14, -12))
		end
		return { ok = true }
	end

	commands.demoSetup = function(player)
		local granted = commands.grantNearness(player, nil)
		local verses = commands.grantNearnessVerses(player, nil)
		commands.demoArena(player, nil)
		commands.setupEnemies(player, DEMO_ENEMIES)
		return { ok = granted.ok and verses.ok }
	end

	commands.demoReset = function(player)
		commands.refill(player, nil)
		commands.resetDissonance(player, nil)
		table.clear(drifts)
		commands.setupEnemies(player, DEMO_ENEMIES)
		commands.teleport(player, { x = 0, z = 0 })
		return { ok = true }
	end

	-- Makes every enemy run away from the player at 4 studs per second, so
	-- No Farther can be seen slowing them. Harness only.
	commands.flee = function(player, on)
		local me = combat.sim:get(combat:combatantId(player.UserId))
		for id in demoEnemies do
			local c = combat.sim:get(id)
			if on and me ~= nil and c ~= nil and c.extra.displacement ~= "immune" then
				local dx, dz = c.position.x - me.position.x, c.position.z - me.position.z
				local length = math.max(0.001, math.sqrt(dx * dx + dz * dz))
				drifts[id] = { x = dx / length * 4, z = dz / length * 4 }
			else
				drifts[id] = nil
			end
		end
		return { ok = true }
	end

	commands.clearEnemies = function()
		clearEnemies()
		return { ok = true }
	end

	combat.sim:onStep(function()
		for id, velocity in drifts do
			local c = combat.sim:get(id)
			if c ~= nil then
				c.position = {
					x = c.position.x + velocity.x * combat.sim.stepSeconds,
					y = c.position.y,
					z = c.position.z + velocity.z * combat.sim.stepSeconds,
				}
			end
		end
	end)

	RunService.Heartbeat:Connect(function()
		for id, body in demoEnemies do
			local c = combat.sim:get(id)
			if c ~= nil then
				body.Position = Vector3.new(c.position.x, c.position.y - 0.5, c.position.z)
			end
		end
	end)

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
		-- With the PlaytestStayOpen attribute set on Workspace, the session
		-- stays open after the scripted run, so the place can be looked at
		-- and walked around by hand.
		if Workspace:GetAttribute("PlaytestStayOpen") == true then
			return { ok = true }
		end
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
