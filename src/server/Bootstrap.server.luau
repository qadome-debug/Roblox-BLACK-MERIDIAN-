--!strict
-- Black Meridian server entry point.
--
-- The composition root: the only place that detects the environment and
-- constructs services, in the order given in docs/architecture.md. Nothing
-- here may create remotes, touch DataStores, or grant anything until the
-- task that owns that behaviour lands.

local RunService = game:GetService("RunService")

local Config = require(script.Parent.Config)

-- Stage 1: configuration.
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

print(
	string.format(
		"[BlackMeridian] Server bootstrap loaded (environment=%s, readOnly=%s, scope=%s)",
		config.environment,
		tostring(config.readOnly),
		config.dataStoreScope
	)
)
