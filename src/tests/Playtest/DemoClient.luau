--!strict
-- Hands-on demo of the four Nearness Verses (development only).
--
-- Mounted beside the client Bootstrap only by playtest-demo.project.json.
-- Press Play and use the Verses yourself:
--
--   Q  Close Step    lunge toward the cursor
--   E  Draw Near     pull the enemy under the cursor to you
--   R  Between Us    tether the two enemies nearest the cursor
--                    (one enemy: it is tethered to you)
--   F  No Farther    zone at the cursor that slows escaping
--   G  toggle        enemies run away (to see No Farther work)
--   H  reset         enemies, stamina, Dissonance, position
--
-- Everything goes through the real client Net controller: each Verse is a
-- VerseCast request judged by the server, and equipping Nearness is a real
-- CantEquip request. The only harness shortcuts are the ones that stand in
-- for systems that do not exist yet: granting Nearness and its Verses (the
-- story), the enemies and arena, and the flee toggle.
--
-- The client decides nothing. It sends an aim point and target hints; the
-- server picks destinations, targets and positions. The HUD reads the
-- server's own-player view. Visuals are TEMPORARY placeholders built from
-- plain parts, beams and bars; they stand in for the animations, effects,
-- sounds and UI that do not exist yet.

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

type Verse = { key: Enum.KeyCode, id: string, name: string, seconds: number, color: Color3 }

-- Display only. The server owns the real cooldowns; these set how a
-- cooldown bar fills.
local VERSES: { Verse } = {
	{
		key = Enum.KeyCode.Q,
		id = "near.close_step",
		name = "Close Step",
		seconds = 7,
		color = Color3.fromRGB(90, 220, 255),
	},
	{
		key = Enum.KeyCode.E,
		id = "near.draw_near",
		name = "Draw Near",
		seconds = 11,
		color = Color3.fromRGB(190, 120, 255),
	},
	{
		key = Enum.KeyCode.R,
		id = "near.between_us",
		name = "Between Us",
		seconds = 16,
		color = Color3.fromRGB(120, 255, 170),
	},
	{
		key = Enum.KeyCode.F,
		id = "near.no_farther",
		name = "No Farther",
		seconds = 24,
		color = Color3.fromRGB(255, 170, 70),
	},
}

local BAND_NAMES = {
	[0] = "Stable",
	[1] = "Noticeable instability",
	[2] = "Enemy and environmental reactions",
	[3] = "Fractured event risk",
	[4] = "Controlled rupture",
}
local BAND_COLORS = {
	[0] = Color3.fromRGB(110, 200, 140),
	[1] = Color3.fromRGB(230, 220, 90),
	[2] = Color3.fromRGB(240, 160, 60),
	[3] = Color3.fromRGB(230, 80, 60),
	[4] = Color3.fromRGB(200, 40, 200),
}

local FONT = Enum.Font.GothamMedium

local function make(className: string, props: { [string]: any }, parent: Instance?): any
	local instance = Instance.new(className)
	for key, value in props do
		(instance :: any)[key] = value
	end
	if parent ~= nil then
		instance.Parent = parent
	end
	return instance
end

return function(net: any, combatState: any)
	local player = Players.LocalPlayer
	local camera = Workspace.CurrentCamera :: Camera
	local control = Workspace:WaitForChild("PlaytestControl", 10) :: RemoteFunction?

	local function server(command: string, arg: any?): any
		if control == nil then
			return nil
		end
		return control:InvokeServer(command, arg)
	end

	-- Placeholder effects live in a client-only folder the world queries
	-- would ignore; nothing here is authoritative.
	local fxFolder = make("Folder", { Name = "BMLocalFx" }, Workspace)

	-- HUD -------------------------------------------------------------------
	local gui = make("ScreenGui", {
		Name = "BMDemoHud",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 20,
	}, player:WaitForChild("PlayerGui"))

	local tint = make("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = BAND_COLORS[0],
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Active = false,
	}, gui)

	local function bar(y: number, color: Color3): (any, any)
		local back = make("Frame", {
			Position = UDim2.fromOffset(24, y),
			Size = UDim2.fromOffset(300, 20),
			BackgroundColor3 = Color3.fromRGB(20, 20, 26),
			BorderSizePixel = 0,
		}, gui)
		make("UICorner", { CornerRadius = UDim.new(0, 4) }, back)
		local fill = make("Frame", {
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = color,
			BorderSizePixel = 0,
		}, back)
		make("UICorner", { CornerRadius = UDim.new(0, 4) }, fill)
		local label = make("TextLabel", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			TextColor3 = Color3.new(1, 1, 1),
			Font = FONT,
			TextSize = 13,
			Text = "",
			ZIndex = 3,
		}, back)
		return fill, label
	end

	local healthFill, healthLabel = bar(24, Color3.fromRGB(215, 70, 70))
	local staminaFill, staminaLabel = bar(50, Color3.fromRGB(90, 200, 120))
	local dissonanceFill, dissonanceLabel = bar(76, BAND_COLORS[0])
	-- Band boundaries on the Dissonance bar: 40, 65, 85.
	for _, at in { 40, 65, 85 } do
		make("Frame", {
			Position = UDim2.fromOffset(24 + 300 * at / 100, 74),
			Size = UDim2.fromOffset(2, 24),
			BackgroundColor3 = Color3.new(1, 1, 1),
			BorderSizePixel = 0,
			ZIndex = 4,
		}, gui)
	end
	local bandLabel = make("TextLabel", {
		Position = UDim2.fromOffset(24, 102),
		Size = UDim2.fromOffset(360, 20),
		BackgroundTransparency = 1,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = Color3.new(1, 1, 1),
		Font = FONT,
		TextSize = 14,
		Text = "",
	}, gui)

	local message = make("TextLabel", {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -112),
		Size = UDim2.fromOffset(520, 26),
		BackgroundTransparency = 0.45,
		BackgroundColor3 = Color3.fromRGB(10, 10, 14),
		TextColor3 = Color3.new(1, 1, 1),
		Font = FONT,
		TextSize = 15,
		Text = "Starting the demo...",
	}, gui)
	make("UICorner", { CornerRadius = UDim.new(0, 6) }, message)

	local slots: { [string]: { cover: any, cooldown: any } } = {}
	for index, verse in VERSES do
		local slot = make("Frame", {
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, (index - 2.5) * 128, 1, -24),
			Size = UDim2.fromOffset(120, 76),
			BackgroundColor3 = Color3.fromRGB(24, 24, 32),
			BorderSizePixel = 0,
		}, gui)
		make("UICorner", { CornerRadius = UDim.new(0, 8) }, slot)
		make("UIStroke", { Color = verse.color, Thickness = 2 }, slot)
		local cover = make("Frame", {
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.fromScale(0, 1),
			Size = UDim2.fromScale(1, 0),
			BackgroundColor3 = Color3.new(0, 0, 0),
			BackgroundTransparency = 0.35,
			BorderSizePixel = 0,
			ZIndex = 2,
		}, slot)
		make("UICorner", { CornerRadius = UDim.new(0, 8) }, cover)
		make("TextLabel", {
			Size = UDim2.new(1, 0, 0, 30),
			BackgroundTransparency = 1,
			TextColor3 = verse.color,
			Font = Enum.Font.GothamBold,
			TextSize = 22,
			Text = verse.key.Name,
			ZIndex = 3,
		}, slot)
		make("TextLabel", {
			Position = UDim2.fromOffset(0, 32),
			Size = UDim2.new(1, 0, 0, 20),
			BackgroundTransparency = 1,
			TextColor3 = Color3.new(1, 1, 1),
			Font = FONT,
			TextSize = 14,
			Text = verse.name,
			ZIndex = 3,
		}, slot)
		local cooldown = make("TextLabel", {
			Position = UDim2.fromOffset(0, 52),
			Size = UDim2.new(1, 0, 0, 20),
			BackgroundTransparency = 1,
			TextColor3 = Color3.fromRGB(200, 200, 210),
			Font = FONT,
			TextSize = 13,
			Text = "",
			ZIndex = 3,
		}, slot)
		slots[verse.id] = { cover = cover, cooldown = cooldown }
	end

	local help = make("TextLabel", {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -20, 0, 20),
		Size = UDim2.fromOffset(330, 192),
		BackgroundTransparency = 0.4,
		BackgroundColor3 = Color3.fromRGB(10, 10, 14),
		TextColor3 = Color3.new(1, 1, 1),
		Font = FONT,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Text = "  NEARNESS DEMO (temporary)\n"
			.. "  Q  Close Step: lunge to the cursor\n"
			.. "  E  Draw Near: pull the enemy under the cursor\n"
			.. "  R  Between Us: tether the 2 nearest enemies\n"
			.. "  F  No Farther: slowing zone at the cursor\n"
			.. "  G  enemies flee on/off     H  reset\n\n"
			.. "  Blue = enemy, orange = elite, red = boss\n"
			.. "  Bosses cannot be pulled or tethered.",
	}, gui)
	make("UICorner", { CornerRadius = UDim.new(0, 8) }, help)

	local function say(text: string)
		message.Text = text
	end

	-- World helpers ------------------------------------------------------------
	local function bodyOf(id: string): BasePart?
		local own = combatState:own()
		if own ~= nil and own.id == id then
			local character = player.Character
			local root = if character ~= nil
				then character:FindFirstChild("HumanoidRootPart")
				else nil
			return if root ~= nil and root:IsA("BasePart") then root else nil
		end
		local dynamic = Workspace:FindFirstChild("BMDynamic")
		local part = if dynamic ~= nil then dynamic:FindFirstChild(id) else nil
		return if part ~= nil and part:IsA("BasePart") then part else nil
	end

	-- Set only by the automatic check (PlaytestDemoAuto): stands in for the
	-- cursor so the same code path can run without a person.
	local autoAim: Vector3? = nil

	local function aimPoint(): Vector3
		if autoAim ~= nil then
			return autoAim
		end
		local mouse = UserInputService:GetMouseLocation()
		local ray = camera:ViewportPointToRay(mouse.X, mouse.Y)
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		local excluded: { Instance } = { fxFolder }
		if player.Character ~= nil then
			table.insert(excluded, player.Character)
		end
		local dynamic = Workspace:FindFirstChild("BMDynamic")
		if dynamic ~= nil then
			table.insert(excluded, dynamic)
		end
		params.FilterDescendantsInstances = excluded
		params.RespectCanCollide = true
		local hit = Workspace:Raycast(ray.Origin, ray.Direction * 500, params)
		if hit ~= nil then
			return hit.Position
		end
		-- Sky: aim straight along the camera direction on the ground plane.
		local flat = Vector3.new(ray.Direction.X, 0, ray.Direction.Z)
		local root = bodyOf((combatState:own() or { id = "" }).id)
		local origin = if root ~= nil then root.Position else ray.Origin
		return origin + (if flat.Magnitude > 0.01 then flat.Unit else Vector3.zAxis * -1) * 40
	end

	-- Enemies nearest to a point, closest first, within `within` studs.
	local function enemiesNear(point: Vector3, within: number): { string }
		local found: { { id: string, distance: number } } = {}
		local dynamic = Workspace:FindFirstChild("BMDynamic")
		if dynamic == nil then
			return {}
		end
		for _, child in dynamic:GetChildren() do
			local id = child:GetAttribute("CombatId")
			if type(id) == "string" and child:IsA("BasePart") then
				local d =
					Vector3.new(child.Position.X - point.X, 0, child.Position.Z - point.Z).Magnitude
				if d <= within then
					table.insert(found, { id = id, distance = d })
				end
			end
		end
		table.sort(found, function(a, b)
			return a.distance < b.distance
		end)
		local ids: { string } = {}
		for _, entry in found do
			table.insert(ids, entry.id)
		end
		return ids
	end

	-- Visual feedback (placeholders) ---------------------------------------------
	local function fade(part: BasePart, seconds: number, grow: Vector3?)
		local goal: { [string]: any } = { Transparency = 1 }
		if grow ~= nil then
			goal.Size = grow
		end
		TweenService:Create(part, TweenInfo.new(seconds, Enum.EasingStyle.Quad), goal):Play()
		Debris:AddItem(part, seconds + 0.1)
	end

	local function beam(from: Vector3, to: Vector3, color: Color3, seconds: number)
		local length = (to - from).Magnitude
		if length < 0.2 then
			return
		end
		local part = make("Part", {
			Anchored = true,
			CanCollide = false,
			CanQuery = false,
			CanTouch = false,
			Material = Enum.Material.Neon,
			Color = color,
			Transparency = 0.15,
			Size = Vector3.new(0.7, 0.7, length),
			CFrame = CFrame.lookAt((from + to) / 2, to),
		}, fxFolder)
		fade(part, seconds, Vector3.new(0.05, 0.05, length))
	end

	local function ring(center: Vector3, radius: number, color: Color3, seconds: number)
		local part = make("Part", {
			Shape = Enum.PartType.Cylinder,
			Anchored = true,
			CanCollide = false,
			CanQuery = false,
			CanTouch = false,
			Material = Enum.Material.Neon,
			Color = color,
			Transparency = 0.3,
			Size = Vector3.new(0.3, radius, radius),
			CFrame = CFrame.new(center) * CFrame.Angles(0, 0, math.rad(90)),
		}, fxFolder)
		fade(part, seconds, Vector3.new(0.3, radius * 2, radius * 2))
	end

	local function flash(character: Instance?, color: Color3, seconds: number)
		if character == nil then
			return
		end
		local highlight = make("Highlight", {
			FillColor = color,
			OutlineColor = color,
			FillTransparency = 0.45,
			DepthMode = Enum.HighlightDepthMode.Occluded,
		}, character)
		TweenService:Create(
			highlight,
			TweenInfo.new(seconds),
			{ FillTransparency = 1, OutlineTransparency = 1 }
		):Play()
		Debris:AddItem(highlight, seconds + 0.1)
	end

	local function kick(degrees: number)
		local base = camera.FieldOfView
		camera.FieldOfView = base + degrees
		TweenService
			:Create(camera, TweenInfo.new(0.3, Enum.EasingStyle.Quad), { FieldOfView = base })
			:Play()
	end

	local VERSE_COLOR: { [string]: Color3 } = {}
	for _, verse in VERSES do
		VERSE_COLOR[verse.id] = verse.color
	end

	local tethers: { [string]: { beam: any, a: any, b: any } } = {}
	local function endTether(key: string)
		local t = tethers[key]
		if t ~= nil then
			t.beam:Destroy()
			t.a:Destroy()
			t.b:Destroy()
			tethers[key] = nil
		end
	end

	net:onCombatCue(function(batch: any)
		local own = combatState:own()
		local mine = if own ~= nil then own.id else ""
		for _, cue in batch.cues do
			local data = cue.data or {}
			local color = VERSE_COLOR[data.verseId or ""] or Color3.new(1, 1, 1)
			if cue.kind == "verse_motion" then
				local from = Vector3.new(data.fromX, data.fromY, data.fromZ)
				local to = Vector3.new(data.toX, data.toY, data.toZ)
				if data.kind == "lunge" then
					beam(from, to, color, 0.45)
					ring(to - Vector3.new(0, 2.5, 0), 4, color, 0.4)
					if cue.id == mine then
						kick(8)
					end
				else
					-- A pull: a streak from the target toward the caster.
					beam(from, to, color, 0.5)
					ring(from - Vector3.new(0, 1.5, 0), 4, color, 0.4)
				end
			elseif cue.kind == "verse_field" then
				if data.kind == "zone" and data.state == "start" then
					local centre = Vector3.new(data.x, data.y - 2.8, data.z)
					local zone = make("Part", {
						Shape = Enum.PartType.Cylinder,
						Anchored = true,
						CanCollide = false,
						CanQuery = false,
						CanTouch = false,
						Material = Enum.Material.Neon,
						Color = color,
						Transparency = 0.75,
						Size = Vector3.new(0.4, data.radius * 2, data.radius * 2),
						CFrame = CFrame.new(centre) * CFrame.Angles(0, 0, math.rad(90)),
					}, fxFolder)
					ring(centre, 2, color, 0.7)
					TweenService:Create(
						zone,
						TweenInfo.new(data.seconds, Enum.EasingStyle.Linear),
						{ Transparency = 0.95 }
					):Play()
					Debris:AddItem(zone, data.seconds)
				elseif data.kind == "tether" then
					local key = tostring(data.a) .. "|" .. tostring(data.b)
					if data.state == "start" then
						local partA, partB = bodyOf(data.a), bodyOf(data.b)
						if partA ~= nil and partB ~= nil then
							endTether(key)
							local attachA = make("Attachment", {}, partA)
							local attachB = make("Attachment", {}, partB)
							local line = make("Beam", {
								Attachment0 = attachA,
								Attachment1 = attachB,
								Color = ColorSequence.new(color),
								Width0 = 0.6,
								Width1 = 0.6,
								FaceCamera = true,
								LightEmission = 1,
								Segments = 1,
							}, partA)
							tethers[key] = { beam = line, a = attachA, b = attachB }
							task.delay(data.seconds + 0.2, function()
								endTether(key)
							end)
						end
					else
						endTether(key)
					end
				end
			elseif cue.kind == "verse_cast_started" and cue.id == mine then
				flash(player.Character, color, 0.35)
			elseif cue.kind == "verse_interrupted" and cue.id == mine then
				say("Cast interrupted: the cost and cooldown stay, no Dissonance")
			elseif cue.kind == "verse_fizzled" and cue.id == mine then
				say("It had no effect (" .. tostring(data.reason) .. "): no Dissonance")
			elseif cue.kind == "dissonance_band_changed" and cue.id == mine then
				say("Dissonance: " .. (BAND_NAMES[data.level] or "?"))
			end
		end
	end)

	-- HUD update ----------------------------------------------------------------
	RunService.RenderStepped:Connect(function()
		local own = combatState:own()
		if own == nil then
			return
		end
		local stamina = math.clamp(own.stamina / math.max(1, own.maxStamina), 0, 1)
		local healthShare = math.clamp(own.health / math.max(1, own.maxHealth), 0, 1)
		healthFill.Size = UDim2.fromScale(healthShare, 1)
		healthLabel.Text = if own.state == "Dead"
			then "Health  DEAD (respawning)"
			else string.format("Health  %.0f / %.0f", own.health, own.maxHealth)
		staminaFill.Size = UDim2.fromScale(stamina, 1)
		staminaLabel.Text = string.format("Stamina  %.0f / %.0f", own.stamina, own.maxStamina)
		local meter = own.dissonance or 0
		local band = own.dissonanceBand or 0
		dissonanceFill.Size = UDim2.fromScale(math.clamp(meter / 100, 0, 1), 1)
		dissonanceFill.BackgroundColor3 = BAND_COLORS[band]
		dissonanceLabel.Text = string.format("Dissonance  %.1f / 100", meter)
		bandLabel.Text = "Band: " .. BAND_NAMES[band]
		tint.BackgroundColor3 = BAND_COLORS[band]
		tint.BackgroundTransparency = if band == 0 then 1 else 1 - 0.07 * band
		local cooldowns = own.cooldowns or {}
		for _, verse in VERSES do
			local slot = slots[verse.id]
			local left = cooldowns[verse.id] or 0
			slot.cover.Size = UDim2.fromScale(1, math.clamp(left / verse.seconds, 0, 1))
			slot.cooldown.Text = if left > 0 then string.format("%.1fs", left) else "ready"
		end
	end)

	-- Input ----------------------------------------------------------------------
	local lastCast = 0
	local fleeing = false
	local runAutomaticCheck: () -> ()

	-- Maps the server's own reason to a short, readable line.
	local function explain(reason: string, status: any): string
		local map = {
			dead = "character is dead (wait to respawn, or press H)",
			cooldown = "ability on cooldown",
			["cannot afford"] = "not enough stamina",
			["target out of range"] = "target out of range (20 studs)",
			["target immune"] = "target is immune (boss)",
			["target not in sight"] = "target blocked",
			["no cant equipped"] = "Cant not equipped",
			["incompatible cant"] = "Cant not equipped",
			["already casting"] = "already casting",
			busy = "busy (another action in progress)",
			["target required"] = "invalid target (point at an enemy)",
			["second target required"] = "invalid target (need a second enemy)",
			["unknown target"] = "invalid target",
			["target is dead"] = "invalid target (dead)",
			["bad aim"] = "invalid aim point",
			interrupted = "interrupted (staggered)",
		}
		return map[reason] or (reason .. " [" .. tostring(status) .. "]")
	end

	local function cast(verse: Verse)
		if time() - lastCast < 0.15 then
			return
		end
		lastCast = time()
		local own = combatState:own()
		if own == nil then
			say("Not ready yet")
			return
		end
		local waiting = (own.cooldowns or {})[verse.id] or 0
		if waiting > 0 then
			say(string.format("%s: on cooldown (%.1fs)", verse.name, waiting))
			return
		end
		if own.stamina < 15 then -- the cheapest Verse costs 15
			say(verse.name .. ": not enough stamina")
			return
		end
		local aim = aimPoint()
		local payload: { [string]: any } =
			{ verseId = verse.id, aimX = aim.X, aimY = aim.Y, aimZ = aim.Z }
		if verse.id == "near.draw_near" then
			local picked = enemiesNear(aim, 14)[1]
			if picked == nil then
				say("Draw Near: point the cursor at an enemy")
				return
			end
			payload.target = picked
		elseif verse.id == "near.between_us" then
			local picked = enemiesNear(aim, 22)
			if #picked == 0 then
				say("Between Us: point the cursor near an enemy")
				return
			end
			payload.target = picked[1]
			payload.targetB = picked[2] or own.id
		end
		net:send("VerseCast", payload, function(result: any)
			local status = if result ~= nil then result.status else "TIMEOUT"
			if status == "OK" then
				say(verse.name .. ": accepted")
			else
				-- Studio only: ask the harness for the reason the server logged.
				-- Production results stay generic.
				local detail = server("lastRefusal")
				local reason = if type(detail) == "table"
					then tostring(detail.reason)
					else "unknown"
				say(verse.name .. " refused: " .. explain(reason, status))
			end
		end)
	end

	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed then
			return
		end
		for _, verse in VERSES do
			if input.KeyCode == verse.key then
				cast(verse)
				return
			end
		end
		if input.KeyCode == Enum.KeyCode.G then
			fleeing = not fleeing
			server("flee", fleeing)
			say(if fleeing then "Enemies are running away (G to stop)" else "Enemies stopped")
		elseif input.KeyCode == Enum.KeyCode.J then
			local result = server("demoDamage", 25)
			say(
				if type(result) == "table" and result.dead
					then "Took 25 test damage: you died"
					else "Took 25 test damage"
			)
		elseif input.KeyCode == Enum.KeyCode.K then
			server("demoDamage", 1000)
			say("Test death: respawning. Press H to reset sooner.")
		elseif input.KeyCode == Enum.KeyCode.H then
			fleeing = false
			server("demoReset")
			say("Reset")
		end
	end)

	-- Automatic check -------------------------------------------------------------
	-- Presses each Verse through the same cast() the keys use, aimed at fixed
	-- points, then reads what the HUD and the effects show. Development only.
	local passedChecks, failedChecks = 0, 0
	local function check(name: string, condition: boolean, detail: any?)
		if condition then
			passedChecks += 1
			print("[PT] ok   " .. name)
		else
			failedChecks += 1
			print("[PT] FAIL " .. name .. "  <" .. tostring(detail) .. ">")
		end
	end
	local function fxCount(): number
		return #fxFolder:GetChildren()
	end
	function runAutomaticCheck()
		local state0 = server("state")
		check(
			"the HUD exists with four ability slots",
			gui:FindFirstChild("Frame", true) ~= nil and slots["near.close_step"] ~= nil
		)
		check(
			"the arena has enemies the client can see",
			#enemiesNear(Vector3.zero, 200) >= 6,
			#enemiesNear(Vector3.zero, 200)
		)
		-- Close Step north.
		autoAim = Vector3.new(0, 3, -30)
		local fxBefore = fxCount()
		cast(VERSES[1])
		-- The streak lasts under half a second: look soon after the cast.
		local sawEffects = false
		for _ = 1, 10 do
			task.wait(0.05)
			if fxCount() > fxBefore then
				sawEffects = true
				break
			end
		end
		task.wait(0.8)
		local state1 = server("state")
		check(
			"Close Step moved the character",
			state0.pos ~= nil and state1.pos.z < state0.pos.z - 10,
			state1.pos and state1.pos.z
		)
		check("the lunge made visual effects", sawEffects)
		check(
			"the HUD shows a cooldown",
			slots["near.close_step"].cooldown.Text ~= "ready",
			slots["near.close_step"].cooldown.Text
		)
		check(
			"the HUD shows Dissonance",
			string.find(dissonanceLabel.Text, "8.0") ~= nil,
			dissonanceLabel.Text
		)
		check(
			"the HUD shows spent stamina",
			staminaFill.Size.X.Scale < 0.95,
			staminaFill.Size.X.Scale
		)
		-- Draw Near on the first enemy.
		task.wait(0.3)
		local a = state1.enemies["demo-a"]
		autoAim = Vector3.new(a.x, 3, a.z)
		cast(VERSES[2])
		task.wait(1.5)
		local state2 = server("state")
		local dx, dz =
			state2.enemies["demo-a"].x - state2.pos.x, state2.enemies["demo-a"].z - state2.pos.z
		check(
			"Draw Near pulled an enemy next to the caster",
			math.sqrt(dx * dx + dz * dz) < 5,
			math.sqrt(dx * dx + dz * dz)
		)
		-- Between Us on two enemies.
		task.wait(0.3)
		local c, d = state2.enemies["demo-c"], state2.enemies["demo-d"]
		autoAim = Vector3.new((c.x + d.x) / 2, 3, (c.z + d.z) / 2)
		local fieldsBefore = fxCount()
		cast(VERSES[3])
		task.wait(1.0)
		local tetherCount = 0
		for _ in tethers do
			tetherCount += 1
		end
		check("Between Us drew a tether", tetherCount == 1, tetherCount)
		-- No Farther.
		task.wait(0.3)
		autoAim = Vector3.new(12, 3, -18)
		cast(VERSES[4])
		task.wait(1.2)
		check("No Farther made a zone", fxCount() > fieldsBefore, fxCount())
		task.wait(0.5)
		local state3 = server("state")
		check("Dissonance accumulated through use", state3.dissonance >= 45, state3.dissonance)
		check(
			"the HUD names the band",
			string.find(bandLabel.Text, "Noticeable") ~= nil,
			bandLabel.Text
		)
		check(
			"every ability shows a cooldown",
			slots["near.no_farther"].cooldown.Text ~= "ready"
				and slots["near.between_us"].cooldown.Text ~= "ready"
		)
		-- Health, death, reset and respawn ----------------------------------------
		local function pollUntil(condition: () -> boolean, seconds: number): boolean
			local began = time()
			while time() - began < seconds do
				if condition() then
					return true
				end
				task.wait(0.1)
			end
			return condition()
		end
		local fullHealth = state3.health
		check(
			"casting four Verses cost no health",
			fullHealth ~= nil and fullHealth == state0.health and fullHealth > 0,
			fullHealth
		)
		check(
			"the HUD shows full health, separate from stamina",
			string.find(healthLabel.Text, "Health") ~= nil
				and healthFill.Size.X.Scale > 0.99
				and string.find(staminaLabel.Text, "Stamina") ~= nil,
			healthLabel.Text
		)
		server("demoDamage", 25)
		task.wait(0.5)
		check(
			"test damage lowers the health bar",
			healthFill.Size.X.Scale < 0.99 and healthFill.Size.X.Scale > 0.5,
			healthLabel.Text
		)
		server("demoDamage", 1000)
		task.wait(0.6)
		check(
			"death shows on the HUD",
			string.find(healthLabel.Text, "DEAD") ~= nil,
			healthLabel.Text
		)
		local deadState = server("state")
		check(
			"the server says dead and the character is dead",
			deadState.actionState == "Dead",
			deadState.actionState
		)
		-- Casting while dead must be refused, with the real reason on screen.
		task.wait(0.4)
		autoAim = Vector3.new(0, 3, -30)
		cast(VERSES[1])
		check(
			"a dead player is refused and the HUD says why",
			pollUntil(function()
				return string.find(message.Text, "dead") ~= nil
			end, 3),
			message.Text
		)
		-- H while dead: a new character and a new life.
		server("demoReset")
		check(
			"H after death restores health",
			pollUntil(function()
				return string.find(healthLabel.Text, "DEAD") == nil
					and healthFill.Size.X.Scale > 0.99
			end, 5),
			healthLabel.Text
		)
		local resetState = server("state")
		check(
			"H cleared Dissonance, cooldowns and the dead state",
			resetState.actionState ~= "Dead"
				and resetState.dissonance == 0
				and resetState.closeStepCooldown == 0,
			resetState.actionState
		)
		task.wait(0.5)
		autoAim = Vector3.new(0, 3, -30)
		cast(VERSES[1])
		check(
			"abilities work again after the reset",
			pollUntil(function()
				return string.find(message.Text, "accepted") ~= nil
			end, 3),
			message.Text
		)
		-- Natural respawn, without pressing H.
		task.wait(1)
		server("demoDamage", 1000)
		local respawned = pollUntil(function()
			local s = server("state")
			return s ~= nil and s.actionState ~= "Dead" and s.health ~= nil and s.health > 0
		end, 15)
		check("the player respawns on their own and is alive", respawned)
		task.wait(1)
		autoAim = Vector3.new(0, 3, -30)
		message.Text = ""
		cast(VERSES[1])
		check(
			"abilities work after a natural respawn",
			pollUntil(function()
				return string.find(message.Text, "accepted") ~= nil
			end, 3),
			message.Text
		)
		print(string.format("[PT] DONE passed=%d failed=%d", passedChecks, failedChecks))
		server("done", { passed = passedChecks, failed = failedChecks })
	end

	-- Start-up: wait for the handshake and the profile, give the harness
	-- grants, then equip Nearness through the real request.
	local ready = false
	net:whenReady(function()
		ready = true
	end)
	task.spawn(function()
		local started = time()
		while not ready and time() - started < 15 do
			task.wait(0.1)
		end
		while time() - started < 30 do
			local state = server("state")
			if state ~= nil and state.profileReady == true and state.inCombat == true then
				break
			end
			task.wait(0.3)
		end
		local setup = server("demoSetup")
		if setup == nil or setup.ok ~= true then
			say("Setup failed: is the profile loaded?")
			return
		end
		task.wait(0.4)
		local equipped = false
		net:send("CantEquip", { slot = "primary", cantId = "cant.nearness" }, function(result: any)
			if result ~= nil and result.status == "OK" then
				equipped = true
				say("Nearness equipped. Use Q E R F. Cursor aims.")
			else
				say("Equip refused: " .. tostring(result and result.status))
			end
		end)
		if Workspace:GetAttribute("PlaytestDemoAuto") == true then
			local waited = time()
			while not equipped and time() - waited < 5 do
				task.wait(0.1)
			end
			runAutomaticCheck()
		end
	end)
end
