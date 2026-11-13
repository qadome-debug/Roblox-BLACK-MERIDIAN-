--!strict
-- Black Meridian client entry point.
--
-- The client owns presentation only: input, camera, animation, UI, and
-- visual prediction. It submits intentions through the Net controller and
-- never decides rewards, quest state, damage, or progression.

local Net = require(script.Parent.Controllers.Net)

print("[BlackMeridian] Client bootstrap loaded")

local net = Net.new()
net:whenReady(function()
	print("[BlackMeridian] Client handshake complete")
end)
