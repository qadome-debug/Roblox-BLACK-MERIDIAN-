--!strict
-- CombatInput adapter (BM-061).
--
-- The only path from a client into the combat simulation. By the time
-- `handle` runs, the dispatcher has checked the envelope, session, epoch,
-- replay, rate class (combat: Limits.RATE.combat) and payload shape. This
-- adapter maps the player to its combatant and forwards the intent or
-- lock request to CombatService, which applies every combat rule. The
-- result says only whether the request was queued or refused and why;
-- outcomes arrive later through replication and cues.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Auth = require(script.Parent.Parent.Auth)
local CombatService = require(script.Parent.Parent.Parent.Services.CombatService)
local Dispatcher = require(script.Parent.Parent.Dispatcher)
local Envelope = require(script.Parent.Parent.Envelope)
local Payloads = require(ReplicatedStorage.Shared.Contracts.Payloads)
local Protocol = require(ReplicatedStorage.Shared.Contracts.Protocol)

export type Deps = { combat: CombatService.Service }

local CombatInput = {}

-- Reasons the simulation returns are short, fixed strings with no hidden
-- thresholds in them, so they may be shown to the client as-is.
local function rejected(ctx: Auth.Context, reason: string?): Protocol.ActionResult
	return Envelope.reject(ctx.requestId, ctx.action, "REJECTED", reason)
end

function CombatInput.new(deps: Deps): Dispatcher.Adapter
	return {
		action = "CombatInput",
		requiresProfile = true,
		requiresReady = true,
		handle = function(
			ctx: Auth.Context,
			payload: Payloads.CombatInputPayload
		): Protocol.ActionResult
			local combat = deps.combat
			if not combat:hasPlayer(ctx.userId) then
				return Envelope.reject(ctx.requestId, ctx.action, "NOT_READY", "no combatant")
			end
			local kind: Payloads.CombatInputKind = payload.kind :: any
			local outcome
			if kind == "Lock" then
				outcome = combat:requestTarget(ctx.userId, payload.target)
			elseif kind == "Unlock" then
				outcome = combat:requestTarget(ctx.userId, nil)
			elseif kind == "CycleTarget" then
				outcome = combat:cycleTarget(ctx.userId)
			else
				outcome = combat:submit(ctx.userId, {
					kind = kind :: any,
					sequence = payload.sequence,
					target = payload.target,
				})
			end
			if not outcome.ok then
				return rejected(ctx, (outcome :: any).reason)
			end
			local data: Payloads.CombatInputResultData = {
				kind = payload.kind,
				sequence = payload.sequence,
				queued = kind ~= "Lock" and kind ~= "Unlock" and kind ~= "CycleTarget",
				target = if kind == "Lock" or kind == "CycleTarget"
					then (combat:ownView(ctx.userId) :: any).target
					else nil,
			}
			return Envelope.ok(ctx.requestId, ctx.action, combat.sim:stepNumber(), data :: any)
		end,
	}
end

return table.freeze(CombatInput)
