--!strict
-- CantEquip adapter (BM-064).
--
-- Equips or unequips a Cant. Equipment is server-owned state on the
-- profile (`cants.equipped`), saved through the profile save queue, and
-- mirrored into the combat layer so activation uses the same answer.
--
-- Checks, in order, all from server state:
--   * the Cant is in the Cant catalog (the validator already proved it is
--     canonical; the catalog proves it is defined for play);
--   * the player owns it (`cants.unlocked`), never a client claim;
--   * the slot is legal for that Cant and is backed by saved state;
--   * it is not already equipped (duplicate equip is refused);
--   * the combatant is not mid-action.
--
-- The profile stores one equipped Cant, so only the primary slot is backed
-- today; the secondary slot is refused until a profile migration adds it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Auth = require(script.Parent.Parent.Auth)
local CantCatalog = require(script.Parent.Parent.Parent.Content.CantCatalog)
local CombatService = require(script.Parent.Parent.Parent.Services.CombatService)
local Dispatcher = require(script.Parent.Parent.Dispatcher)
local Envelope = require(script.Parent.Parent.Envelope)
local Payloads = require(ReplicatedStorage.Shared.Contracts.Payloads)
local Profile = require(ReplicatedStorage.Shared.Types.Profile)
local Protocol = require(ReplicatedStorage.Shared.Contracts.Protocol)
local SaveQueue = require(script.Parent.Parent.Parent.Persistence.SaveQueue)

-- The parts of ProfileService this adapter uses.
export type Profiles = {
	profileFor: (self: any, userId: number) -> Profile.PlayerProfile?,
	mutate: (self: any, userId: number, mutation: SaveQueue.Mutation) -> (boolean, string?),
}

export type Deps = {
	profiles: Profiles,
	combat: CombatService.Service?,
	catalog: CantCatalog.Catalog?,
}

local BACKED_SLOTS: { [string]: boolean } = { primary = true }

local CantEquip = {}

local function equipMutation(cantId: string?): SaveQueue.Mutation
	return {
		id = "cant-equip:" .. (cantId or "none"),
		apply = function(profile: Profile.PlayerProfile): Profile.PlayerProfile?
			if profile.cants.equipped == cantId then
				return nil
			end
			local nextProfile = table.clone(profile)
			nextProfile.cants = table.clone(profile.cants)
			nextProfile.cants.equipped = cantId
			return nextProfile
		end,
		isApplied = function(profile: Profile.PlayerProfile): boolean
			return profile.cants.equipped == cantId
		end,
	}
end

function CantEquip.new(deps: Deps): Dispatcher.Adapter
	local catalog = deps.catalog or CantCatalog.production()
	return {
		action = "CantEquip",
		requiresProfile = true,
		requiresReady = true,
		handle = function(
			ctx: Auth.Context,
			payload: Payloads.CantEquipPayload
		): Protocol.ActionResult
			local function reject(reason: string): Protocol.ActionResult
				return Envelope.reject(ctx.requestId, ctx.action, "REJECTED", reason)
			end
			local profile = deps.profiles:profileFor(ctx.userId)
			if profile == nil then
				return Envelope.reject(ctx.requestId, ctx.action, "NOT_READY", "profile not ready")
			end
			local slot = payload.slot
			if not BACKED_SLOTS[slot] then
				return reject("slot unavailable")
			end
			local cantId = payload.cantId
			local previous = profile.cants.equipped
			if cantId ~= nil then
				if catalog:resolve(cantId) == nil then
					return reject("unknown cant")
				end
				if profile.cants.unlocked[cantId] ~= true then
					return Envelope.reject(
						ctx.requestId,
						ctx.action,
						"UNAUTHORIZED",
						"cant not owned"
					)
				end
				if not catalog:canSlot(cantId, slot :: any) then
					return reject("cant not allowed in slot")
				end
			end
			if previous == cantId then
				return reject(if cantId == nil then "nothing equipped" else "already equipped")
			end

			-- Mirror into combat first: it refuses mid-action, and it is the
			-- cheap step to undo if saving is refused.
			local combat = deps.combat
			local combatantId = nil
			if combat ~= nil and combat:hasPlayer(ctx.userId) then
				combatantId = combat:combatantId(ctx.userId)
				local outcome = combat.cants:equip(combatantId, cantId)
				if not outcome.ok then
					return reject((outcome :: any).reason or "cannot equip now")
				end
			end
			local saved, reason = deps.profiles:mutate(ctx.userId, equipMutation(cantId))
			if not saved then
				if combat ~= nil and combatantId ~= nil then
					combat.cants:equip(combatantId, previous)
				end
				return Envelope.reject(ctx.requestId, ctx.action, "INTERNAL", reason)
			end
			ctx.logger:info("gameplay", "cant_equipped", { slot = slot, cantId = cantId or "none" })
			local data: Payloads.CantEquipResultData =
				{ slot = slot :: any, cantId = cantId, changed = true }
			return Envelope.ok(ctx.requestId, ctx.action, nil, data :: any)
		end,
	}
end

return table.freeze(CantEquip)
