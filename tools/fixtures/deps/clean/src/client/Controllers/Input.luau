--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Ids = require(ReplicatedStorage.Shared:WaitForChild("Types"):WaitForChild("Ids"))
return { Ids = Ids }
