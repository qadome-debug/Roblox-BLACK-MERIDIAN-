--!strict
-- DissonanceAction adapter (BM-068).
--
-- Forwards a named Dissonance action to the combat service's Dissonance
-- layer, which judges the action id, level, cooldown and cost from server
-- state. The client can never set or adjust the meter.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Auth = require(script.Parent.Parent.Auth)
local CombatService = require(script.Parent.Parent.Parent.Services.CombatService)
local Dispatcher = require(script.Parent.Parent.Dispatcher)
local Envelope = require(script.Parent.Parent.Envelope)
local Payloads = require(ReplicatedStorage.Shared.Contracts.Payloads)
local Protocol = require(ReplicatedStorage.Shared.Contracts.Protocol)

export type Deps = { combat: CombatService.Service }

local DissonanceAction = {}

function DissonanceAction.new(deps: Deps): Dispatcher.Adapter
	return {
		action = "DissonanceAction",
		requiresProfile = true,
		requiresReady = true,
		handle = function(
			ctx: Auth.Context,
			payload: Payloads.DissonanceActionPayload
		): Protocol.ActionResult
			local combat = deps.combat
			if not combat:hasPlayer(ctx.userId) then
				return Envelope.reject(ctx.requestId, ctx.action, "NOT_READY", "no combatant")
			end
			local id = combat:combatantId(ctx.userId)
			local level = combat.dissonance:level(id)
			local outcome = combat.dissonance:perform(id, payload.actionId)
			if not outcome.ok then
				return Envelope.reject(
					ctx.requestId,
					ctx.action,
					"REJECTED",
					(outcome :: any).reason
				)
			end
			local data: Payloads.DissonanceActionResultData =
				{ actionId = payload.actionId, level = level }
			return Envelope.ok(ctx.requestId, ctx.action, combat.sim:stepNumber(), data :: any)
		end,
	}
end

return table.freeze(DissonanceAction)
