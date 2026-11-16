--!strict
-- Loadout restore (integration of BM-063/BM-064).
--
-- The equipped Cant is saved on the profile; the combat layer keeps its
-- own mirror for activation and Verse compatibility. `CantEquip` writes
-- both, but a player who rejoins (or whose profile finishes loading after
-- the character spawned) has the saved value only on the profile. `restore`
-- copies profile -> combat. It is called whenever either side becomes
-- available: profile ready, or combatant added. It never writes the
-- profile and never reads anything a client sent.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatService = require(script.Parent.CombatService)
local Logger = require(script.Parent.Parent.Logging.Logger)
local Profile = require(ReplicatedStorage.Shared.Types.Profile)

export type Deps = {
	profiles: { profileFor: (self: any, userId: number) -> Profile.PlayerProfile? },
	combat: CombatService.Service,
	logger: Logger.Logger,
}

export type Outcome = "restored" | "nothingEquipped" | "notReady" | "refused"

local Loadout = {}

function Loadout.restore(deps: Deps, userId: number): Outcome
	local profile = deps.profiles:profileFor(userId)
	if profile == nil or not deps.combat:hasPlayer(userId) then
		return "notReady"
	end
	local id = deps.combat:combatantId(userId)
	local saved = profile.cants.equipped
	if deps.combat.cants:equipped(id) == saved then
		return if saved == nil then "nothingEquipped" else "restored"
	end
	local outcome = deps.combat.cants:equip(id, saved)
	if not outcome.ok then
		-- The profile stays as saved; the player can equip again later.
		deps.logger:with({ playerId = userId }):warn("gameplay", "loadout_restore_refused", {
			cantId = saved or "none",
			reason = (outcome :: any).reason,
		})
		return "refused"
	end
	if saved == nil then
		return "nothingEquipped"
	end
	deps.logger:with({ playerId = userId }):info("gameplay", "loadout_restored", { cantId = saved })
	return "restored"
end

return table.freeze(Loadout)
