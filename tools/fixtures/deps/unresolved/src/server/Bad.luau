--!strict
local a = require("./Missing")
local b = require(script.Parent.Nope)
local c = require(game:GetService("ServerStorage").Secret)
return { a, b, c }
