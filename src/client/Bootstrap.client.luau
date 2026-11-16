--!strict
-- Black Meridian client entry point.
--
-- The client owns presentation only: input, camera, animation, UI, and
-- visual prediction. It submits intentions through the Net controller and
-- never decides rewards, quest state, damage, or progression.

local CombatState = require(script.Parent.Controllers.CombatState)
local Net = require(script.Parent.Controllers.Net)

print("[BlackMeridian] Client bootstrap loaded")

local net = Net.new()
local combat = CombatState.new()

net:onStateDelta(function(delta)
	if delta.kind == "combat" then
		combat:applyDelta(delta :: any)
	end
end)
net:onCombatCue(function(batch)
	combat:applyCues(batch :: any)
end)
combat:on(function(event, payload)
	if event == "corrected" then
		-- Presentation (BM-098) snaps the animation; until then, log it.
		local p = payload :: { predicted: string, actual: string, sequence: number }
		print("[BlackMeridian] Prediction corrected: " .. p.predicted .. " -> " .. p.actual)
	end
end)

net:whenReady(function()
	print("[BlackMeridian] Client handshake complete")
end)

-- Studio play-test hook (development only). The play-test build adds a
-- PlaytestClient module beside this script; the default build has none.
-- It drives requests through this same Net controller, so the server sees
-- exactly what it would see from a real client.
if game:GetService("RunService"):IsStudio() then
	local driver = script.Parent:FindFirstChild("PlaytestClient")
	if driver ~= nil and driver:IsA("ModuleScript") then
		task.spawn(function()
			local run = (require :: any)(driver) :: (net: Net.Controller, combat: any) -> ()
			run(net, combat)
		end)
	end
end
