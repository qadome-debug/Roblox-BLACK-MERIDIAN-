--!strict
-- Studio play-test driver, client side (development only).
--
-- Mounted beside the client Bootstrap only by playtest.project.json. It
-- runs a scripted scenario through the real Net controller, so every
-- request crosses the real remotes, dispatcher, validators and adapters.
-- Server-side setup and state reads go through the harness control
-- RemoteFunction (see Server.luau). Results are printed with a [PT] prefix
-- and shown on screen.
--
-- A passing run proves the wiring works in the engine. It does not prove a
-- gameplay feature is finished: the Nearness Verses are registered but not
-- castable until their values are approved, and Dissonance has its bands
-- but no approved rates or band effects (see docs/task-log.md).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local passed, failed = 0, 0
local lines: { string } = {}
local label: TextLabel? = nil

local function render()
	if label ~= nil then
		local shown = {}
		for i = math.max(1, #lines - 44), #lines do
			table.insert(shown, lines[i])
		end
		label.Text = table.concat(shown, "\n")
	end
end

local function log(line: string)
	print("[PT] " .. line)
	table.insert(lines, line)
	render()
end

local function check(name: string, condition: boolean, detail: any?)
	if condition then
		passed += 1
		log("ok   " .. name)
	else
		failed += 1
		log("FAIL " .. name .. (if detail ~= nil then "  <" .. tostring(detail) .. ">" else ""))
	end
end

local function makeGui()
	local player = Players.LocalPlayer
	local gui = Instance.new("ScreenGui")
	gui.Name = "PlaytestResults"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	local text = Instance.new("TextLabel")
	text.Size = UDim2.fromScale(0.62, 1)
	text.Position = UDim2.fromScale(0, 0)
	text.BackgroundColor3 = Color3.new(0, 0, 0)
	text.BackgroundTransparency = 0.15
	text.TextColor3 = Color3.new(1, 1, 1)
	text.Font = Enum.Font.Code
	text.TextSize = 13
	text.TextXAlignment = Enum.TextXAlignment.Left
	text.TextYAlignment = Enum.TextYAlignment.Top
	text.Text = ""
	text.Parent = gui
	gui.Parent = player:WaitForChild("PlayerGui")
	label = text
end

return function(net: any, combatState: any)
	makeGui()
	log("play-test driver started")
	local control = Workspace:WaitForChild("PlaytestControl", 10) :: RemoteFunction?
	if control == nil then
		check("harness control present", false)
		return
	end
	local function server(command: string, arg: any?): any
		return (control :: RemoteFunction):InvokeServer(command, arg)
	end

	local cues: { [string]: number } = {}
	net:onCombatCue(function(batch: any)
		for _, cue in batch.cues do
			cues[cue.kind] = (cues[cue.kind] or 0) + 1
		end
	end)

	local function request(action: string, payload: any): any
		local result: any = nil
		net:send(action, payload, function(r)
			result = r
		end)
		local started = time()
		while result == nil and time() - started < 5 do
			task.wait()
		end
		-- Stay well inside every rate class.
		task.wait(0.3)
		return result or { status = "TIMEOUT" }
	end

	local function waitFor(seconds: number, predicate: () -> boolean): boolean
		local started = time()
		while time() - started < seconds do
			if predicate() then
				return true
			end
			task.wait(0.1)
		end
		return predicate()
	end

	local function expect(name: string, action: string, payload: any, status: string): any
		local result = request(action, payload)
		check(
			name,
			result.status == status,
			tostring(result.status) .. " " .. tostring(result.message)
		)
		return result
	end

	-- 1. Start, handshake, spawn, profile.
	local ready = false
	net:whenReady(function()
		ready = true
	end)
	check(
		"client handshake completes",
		waitFor(10, function()
			return ready
		end)
	)
	local player = Players.LocalPlayer
	check(
		"player character spawns",
		waitFor(10, function()
			local character = player.Character
			return character ~= nil and character:FindFirstChild("HumanoidRootPart") ~= nil
		end)
	)
	if Workspace:GetAttribute("PlaytestDegraded") == true then
		-- Degraded mode: no DataStore is reachable (an unpublished place).
		-- The server must stay up and refuse every gameplay request.
		check(
			"profile load finishes as failed",
			waitFor(90, function()
				return server("state").profileState == "failed"
			end),
			server("state").profileState
		)
		check("profile is not ready", server("state").profileReady == false)
		expect(
			"CantEquip is NOT_READY",
			"CantEquip",
			{ slot = "primary", cantId = "cant.nearness" },
			"NOT_READY"
		)
		expect(
			"CombatInput is NOT_READY",
			"CombatInput",
			{ kind = "Attack", sequence = 1 },
			"NOT_READY"
		)
		expect("VerseCast is NOT_READY", "VerseCast", { verseId = "none.undefined" }, "NOT_READY")
		expect(
			"DissonanceAction is NOT_READY",
			"DissonanceAction",
			{ actionId = "anything" },
			"NOT_READY"
		)
		check("grant through the profile is refused", server("grantNearness").ok == false)
		check("the server still simulates the player", server("state").inCombat == true)
		log(string.format("DONE (degraded) passed=%d failed=%d", passed, failed))
		server("done", { passed = passed, failed = failed })
		return
	end
	check(
		"profile loads (in-memory store)",
		waitFor(15, function()
			return server("state").profileReady == true
		end)
	)
	check(
		"server has a combatant for the player",
		waitFor(5, function()
			return server("state").inCombat == true
		end)
	)
	check(
		"own combat view replicates to the client",
		waitFor(5, function()
			local own = combatState:own()
			return own ~= nil and own.maxHealth > 0 and own.maxStamina > 0
		end)
	)
	local fresh = server("state")
	check("new profile has nothing equipped", fresh.equippedProfile == nil, fresh.equippedProfile)
	check("new profile is written to the store on load", fresh.stored == true)

	-- 2. Cant equipping: ownership and invalid requests.
	local nearness = { slot = "primary", cantId = "cant.nearness" }
	expect("equip an unowned Cant is UNAUTHORIZED", "CantEquip", nearness, "UNAUTHORIZED")
	check("harness grants Nearness ownership", server("grantNearness").ok == true)
	expect(
		"fabricated Cant id is BAD_PAYLOAD",
		"CantEquip",
		{ slot = "primary", cantId = "cant.invented" },
		"BAD_PAYLOAD"
	)
	expect(
		"unknown slot is BAD_PAYLOAD",
		"CantEquip",
		{ slot = "tertiary", cantId = "cant.nearness" },
		"BAD_PAYLOAD"
	)
	expect(
		"extra payload field is BAD_PAYLOAD",
		"CantEquip",
		{ slot = "primary", cantId = "cant.nearness", force = true },
		"BAD_PAYLOAD"
	)
	expect(
		"unbacked secondary slot is REJECTED",
		"CantEquip",
		{ slot = "secondary", cantId = "cant.nearness" },
		"REJECTED"
	)
	local afterBad = server("state")
	check(
		"invalid requests changed nothing",
		afterBad.equippedProfile == nil and afterBad.equippedCombat == nil
	)
	expect("equip an owned Cant is OK", "CantEquip", nearness, "OK")
	local equipped = server("state")
	check(
		"profile records the equipped Cant",
		equipped.equippedProfile == "cant.nearness",
		equipped.equippedProfile
	)
	check(
		"combat layer mirrors the equipped Cant",
		equipped.equippedCombat == "cant.nearness",
		equipped.equippedCombat
	)
	expect("duplicate equip is REJECTED", "CantEquip", nearness, "REJECTED")
	server("save")
	local saved = server("state")
	check(
		"equipped Cant is saved to the store",
		saved.storedEquipped == "cant.nearness",
		saved.storedEquipped
	)

	-- 3. The Nearness Verses. A Cant has no ability of its own; its Verses
	-- are the techniques. They are registered with their confirmed
	-- cooldowns but cannot be cast until costs, cast times and effects are
	-- approved, so every cast must be refused and change nothing.
	expect(
		"a Verse the player has not unlocked is UNAUTHORIZED",
		"VerseCast",
		{ verseId = "near.close_step" },
		"UNAUTHORIZED"
	)
	check("harness unlocks the four Nearness Verses", server("grantNearnessVerses").ok == true)
	local before = server("state")
	for _, verseId in { "near.close_step", "near.draw_near", "near.between_us", "near.no_farther" } do
		expect(
			verseId .. " is registered but not castable yet",
			"VerseCast",
			{ verseId = verseId },
			"REJECTED"
		)
	end
	local after = server("state")
	check("refused casts spend nothing", after.stamina == before.stamina, after.stamina)
	check("refused casts start no cooldown", after.closeStepCooldown == 0, after.closeStepCooldown)
	check("refused casts add no Dissonance", after.dissonance == 0, after.dissonance)
	check("no activation or cast cue exists", (cues.cant_activated or 0) == 0)

	-- 4. Combat input through the dispatcher.
	expect(
		"unknown combat kind is BAD_PAYLOAD",
		"CombatInput",
		{ kind = "Fireball", sequence = 1 },
		"BAD_PAYLOAD"
	)
	check("harness spawns a passive enemy in front", server("spawnEnemy").ok == true)
	local enemyBefore = server("state")
	expect("attack is queued", "CombatInput", { kind = "Attack", sequence = 1 }, "OK")
	expect(
		"stale combat sequence is REJECTED",
		"CombatInput",
		{ kind = "Attack", sequence = 1 },
		"REJECTED"
	)
	check(
		"the server resolves the hit on the enemy",
		waitFor(3, function()
			local s = server("state")
			return s.enemyHealth ~= nil and s.enemyHealth < enemyBefore.enemyHealth
		end)
	)
	check("combat cues reach the client", (cues.action_started or 0) > 0 and (cues.damage or 0) > 0)
	check(
		"client acknowledges the server sequence",
		waitFor(2, function()
			local own = combatState:own()
			return own ~= nil and own.ackSequence == 1
		end)
	)

	-- 5. Malformed Verse requests. The positive path is covered headless
	-- with fixture Verses until the Nearness Verses are approved.
	expect("undefined Verse is REJECTED", "VerseCast", { verseId = "none.undefined" }, "REJECTED")
	expect("non-verse id is BAD_PAYLOAD", "VerseCast", { verseId = "cant.nearness" }, "BAD_PAYLOAD")
	expect(
		"empty target is BAD_PAYLOAD",
		"VerseCast",
		{ verseId = "none.undefined", target = "" },
		"BAD_PAYLOAD"
	)
	check("no verse cue was produced", (cues.verse_cast_started or 0) == 0)

	-- 6. Dissonance: the design's five bands; no player-triggered actions.
	expect(
		"undefined Dissonance action is REJECTED",
		"DissonanceAction",
		{ actionId = "anything" },
		"REJECTED"
	)
	expect(
		"client-supplied meter value is BAD_PAYLOAD",
		"DissonanceAction",
		{ actionId = "anything", value = 100 },
		"BAD_PAYLOAD"
	)
	check("client requests did not move the meter", server("state").dissonance == 0)
	server("addDissonance", 39)
	check("39 is still Stable", server("state").dissonanceBand == "Stable")
	server("addDissonance", 1)
	local raised = server("state")
	check(
		"40 is Noticeable instability",
		raised.dissonanceBand == "Noticeable instability",
		raised.dissonanceBand
	)
	check(
		"band change cue reaches the client",
		waitFor(2, function()
			return (cues.dissonance_band_changed or 0) >= 1
		end)
	)
	task.wait(1)
	check(
		"the meter does not decay by itself",
		server("state").dissonance == 40,
		server("state").dissonance
	)
	server("recoverDissonance", 40)
	check("recovery returns it to Stable", server("state").dissonanceBand == "Stable")

	-- 7. Simulated rejoin: release and reload the profile, respawn.
	local rejoin = server("rejoin")
	check("profile reloads from the store", rejoin.ok == true, rejoin.state)
	check(
		"saved Cant is restored into combat after reload",
		waitFor(10, function()
			local s = server("state")
			return s.profileReady and s.inCombat and s.equippedCombat == "cant.nearness"
		end),
		server("state").equippedCombat
	)
	expect("equip after reload is still a duplicate", "CantEquip", nearness, "REJECTED")
	expect("unequip is OK", "CantEquip", { slot = "primary" }, "OK")
	local cleared = server("state")
	check(
		"unequip clears profile and combat",
		cleared.equippedProfile == nil and cleared.equippedCombat == nil
	)

	-- 8. Forged envelope straight on the remote, then a normal request.
	local folder = ReplicatedStorage:WaitForChild("BlackMeridian")
	local actionRequest = folder:WaitForChild("ActionRequest") :: RemoteEvent
	local actionResult = folder:WaitForChild("ActionResult") :: RemoteEvent
	local forgedId = "pt-forged-request-1"
	local forgedStatus: string? = nil
	local connection = actionResult.OnClientEvent:Connect(function(result: any)
		if type(result) == "table" and result.requestId == forgedId then
			forgedStatus = result.status
		end
	end)
	actionRequest:FireServer({
		v = 1,
		requestId = forgedId,
		sessionEpoch = "forged-epoch",
		seq = 999999,
		action = "CantEquip",
		payload = nearness,
	})
	actionRequest:FireServer("garbage")
	actionRequest:FireServer({ action = "GrantReward", payload = { gold = 1e9 } })
	waitFor(3, function()
		return forgedStatus ~= nil
	end)
	connection:Disconnect()
	check("forged session epoch is refused", forgedStatus == "STALE_EPOCH", forgedStatus)
	check("forged requests changed nothing", server("state").equippedProfile == nil)
	expect("a normal request still works afterwards", "CantEquip", nearness, "OK")

	log(string.format("DONE passed=%d failed=%d", passed, failed))
	server("done", { passed = passed, failed = failed })
end
