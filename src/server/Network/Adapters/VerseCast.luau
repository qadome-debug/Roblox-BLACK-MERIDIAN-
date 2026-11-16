--!strict
-- VerseCast adapter (BM-067).
--
-- The only path from a client to a Verse. After the dispatcher's checks
-- (envelope, session, epoch, replay, the `cant` rate class, payload
-- shape) this adapter verifies, from server state:
--
--   * the Verse is defined in the combat service's Verse catalog;
--   * the player has unlocked it (`cants.verses[cantId][verseId]` on the
--     profile), otherwise UNAUTHORIZED, logged as a security event;
--   * the player has a combatant.
--
-- The cast pipeline then judges the equipped Cant, cooldown, costs, combat
-- state and the target hint. A refused cast changes nothing.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Auth = require(script.Parent.Parent.Auth)
local CombatService = require(script.Parent.Parent.Parent.Services.CombatService)
local Dispatcher = require(script.Parent.Parent.Dispatcher)
local Envelope = require(script.Parent.Parent.Envelope)
local Payloads = require(ReplicatedStorage.Shared.Contracts.Payloads)
local Profile = require(ReplicatedStorage.Shared.Types.Profile)
local Protocol = require(ReplicatedStorage.Shared.Contracts.Protocol)

export type Profiles = {
	profileFor: (self: any, userId: number) -> Profile.PlayerProfile?,
}

export type Deps = {
	profiles: Profiles,
	combat: CombatService.Service,
}

local VerseCast = {}

function VerseCast.new(deps: Deps): Dispatcher.Adapter
	return {
		action = "VerseCast",
		requiresProfile = true,
		requiresReady = true,
		handle = function(
			ctx: Auth.Context,
			payload: Payloads.VerseCastPayload
		): Protocol.ActionResult
			local combat = deps.combat
			local profile = deps.profiles:profileFor(ctx.userId)
			if profile == nil then
				return Envelope.reject(ctx.requestId, ctx.action, "NOT_READY", "profile not ready")
			end
			local def = combat.verseCatalog:get(payload.verseId)
			if def == nil then
				return Envelope.reject(ctx.requestId, ctx.action, "REJECTED", "unknown verse")
			end
			local unlocked = profile.cants.verses[def.cantId]
			if
				profile.cants.unlocked[def.cantId] ~= true
				or unlocked == nil
				or unlocked[payload.verseId] ~= true
			then
				return Envelope.reject(
					ctx.requestId,
					ctx.action,
					"UNAUTHORIZED",
					"verse not unlocked"
				)
			end
			if not combat:hasPlayer(ctx.userId) then
				return Envelope.reject(ctx.requestId, ctx.action, "NOT_READY", "no combatant")
			end
			local id = combat:combatantId(ctx.userId)
			local aim = if payload.aimX ~= nil
				then { x = payload.aimX, y = payload.aimY :: number, z = payload.aimZ :: number }
				else nil
			local outcome = combat.verses:cast(
				id,
				payload.verseId,
				payload.target,
				{ targetB = payload.targetB, aim = aim }
			)
			if not outcome.ok then
				return Envelope.reject(
					ctx.requestId,
					ctx.action,
					"REJECTED",
					(outcome :: any).reason
				)
			end
			local cast = combat.verses:casting(id)
			local data: Payloads.VerseCastResultData = {
				verseId = payload.verseId,
				target = payload.target,
				resolveStep = if cast ~= nil then cast.resolveStep else combat.sim:stepNumber(),
			}
			return Envelope.ok(ctx.requestId, ctx.action, combat.sim:stepNumber(), data :: any)
		end,
	}
end

return table.freeze(VerseCast)
