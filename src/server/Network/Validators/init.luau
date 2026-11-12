--!strict
-- Payload validator registry (BM-013).
--
-- Maps an action to the validator that turns its untrusted payload into a
-- typed value. An action without a validator cannot be dispatched: the
-- dispatcher treats it as unavailable (default deny). Each owning task adds
-- its validator here in the same change that adds the adapter.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Actions = require(ReplicatedStorage.Shared.Contracts.Actions)

export type Validator = (raw: unknown) -> (unknown?, string?)

local REGISTRY: { [Actions.ActionName]: Validator } = {
	ClientHello = require(script.ClientHello) :: Validator,
	QuestChoice = require(script.QuestChoice) :: Validator,
	TravelReady = require(script.TravelReady) :: Validator,
}

local Validators = {}

function Validators.forAction(action: Actions.ActionName): Validator?
	return REGISTRY[action]
end

function Validators.registered(): { Actions.ActionName }
	local names: { Actions.ActionName } = {}
	for name in REGISTRY do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

return table.freeze(Validators)
