--!strict
-- Optional Studio runner plugin for the play-test build (development only).
--
-- Copy this file into the local Studio plugins folder as a .lua file to
-- have Studio start play mode by itself when the play-test place opens
-- (useful when nobody can click Play). It does nothing in any other place:
-- it requires the play-test harness, the control RemoteFunction and the
-- PlaytestAutoRun attribute that only playtest.project.json sets. Remove
-- the copy from the plugins folder when it is not needed.

local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

if RunService:IsRunning() then
	return nil
end

task.wait(5)
local tests = ServerStorage:FindFirstChild("Tests")
if
	tests == nil
	or tests:FindFirstChild("Playtest") == nil
	or Workspace:FindFirstChild("PlaytestControl") == nil
	or Workspace:GetAttribute("PlaytestAutoRun") ~= true
then
	return nil
end

print("[PT-RUNNER] starting play mode")
local ok, result = pcall(function()
	return (game:GetService("StudioTestService") :: any):ExecutePlayModeAsync({})
end)
print("[PT-RUNNER] play mode finished ok=" .. tostring(ok) .. " result=" .. tostring(result))
return nil
