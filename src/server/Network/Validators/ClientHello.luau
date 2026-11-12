--!strict
-- ClientHello payload validator (BM-017 owns the adapter). The client
-- states its protocol version; the server decides whether to accept it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Payloads = require(ReplicatedStorage.Shared.Contracts.Payloads)
local Schema = require(script.Parent.Schema)

local validate = Schema.object({
	protocolVersion = { kind = "integer", min = 1, max = 1000 },
})

local function parseClientHello(raw: unknown): (Payloads.ClientHelloPayload?, string?)
	local value, reason = validate(raw)
	if value == nil then
		return nil, reason
	end
	return value :: Payloads.ClientHelloPayload, nil
end

return parseClientHello
