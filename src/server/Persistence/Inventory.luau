--!strict
-- Bounded inventory operations (BM-033).
--
-- Pure functions over a profile's inventory array. Each returns a new
-- profile (the input is never mutated) or nil with a reason, so services
-- can wrap them as SaveQueue mutations and tests can check invariants.
--
-- Invariants kept by every operation:
--   * quantities are positive integers,
--   * stackable items merge into one stack per itemId,
--   * instanced items have quantity 1 and a unique instanceId,
--   * the stack count never exceeds Limits.PROFILE.MAX_INVENTORY_STACKS,
--   * a stack's quantity never exceeds MAX_STACK.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ContentRegistry = require(ReplicatedStorage.Shared.Catalogs.ContentRegistry)
local Limits = require(ReplicatedStorage.Shared.Constants.Limits)
local Migrations = require(script.Parent.Migrations)
local Profile = require(ReplicatedStorage.Shared.Types.Profile)

type PlayerProfile = Profile.PlayerProfile
type Stack = Profile.InventoryStack

export type Reason =
	"badItem"
	| "badQuantity"
	| "badInstance"
	| "duplicateInstance"
	| "full"
	| "stackLimit"
	| "missing"

local Inventory = {}

Inventory.MAX_STACK = 999
Inventory.MAX_STACKS = Limits.PROFILE.MAX_INVENTORY_STACKS

local function isPositiveInt(value: unknown): boolean
	return type(value) == "number"
		and value == value
		and value >= 1
		and value % 1 == 0
		and value <= Inventory.MAX_STACK
end

local function isOpaque(value: unknown): boolean
	return type(value) == "string"
		and #value >= 1
		and #value <= Limits.MAX_OPAQUE_ID_BYTES
		and string.match(value, "^[%w%-_:.]+$") ~= nil
end

local function copy(profile: PlayerProfile): PlayerProfile
	local next = table.clone(profile)
	next.inventory = Migrations.deepCopy(profile.inventory)
	return next
end

function Inventory.count(profile: PlayerProfile, itemId: string): number
	local total = 0
	for _, stack in profile.inventory do
		if stack.itemId == itemId then
			total += stack.quantity
		end
	end
	return total
end

function Inventory.findInstance(profile: PlayerProfile, instanceId: string): Stack?
	for _, stack in profile.inventory do
		if stack.instanceId == instanceId then
			return stack
		end
	end
	return nil
end

-- Adds `quantity` of a stackable item, merging into an existing stack.
function Inventory.addStackable(
	profile: PlayerProfile,
	itemId: string,
	quantity: number
): (PlayerProfile?, Reason?)
	if not ContentRegistry.isValidId(itemId) then
		return nil, "badItem"
	end
	if not isPositiveInt(quantity) then
		return nil, "badQuantity"
	end
	local next = copy(profile)
	for _, stack in next.inventory do
		if stack.itemId == itemId and stack.instanceId == nil then
			if stack.quantity + quantity > Inventory.MAX_STACK then
				return nil, "stackLimit"
			end
			stack.quantity += quantity
			return next, nil
		end
	end
	if #next.inventory >= Inventory.MAX_STACKS then
		return nil, "full"
	end
	table.insert(next.inventory, { itemId = itemId, quantity = quantity })
	return next, nil
end

-- Adds one instanced item (equipment) with a server-issued instanceId.
function Inventory.addInstance(
	profile: PlayerProfile,
	itemId: string,
	instanceId: string
): (PlayerProfile?, Reason?)
	if not ContentRegistry.isValidId(itemId) then
		return nil, "badItem"
	end
	if not isOpaque(instanceId) then
		return nil, "badInstance"
	end
	if Inventory.findInstance(profile, instanceId) ~= nil then
		return nil, "duplicateInstance"
	end
	if #profile.inventory >= Inventory.MAX_STACKS then
		return nil, "full"
	end
	local next = copy(profile)
	table.insert(next.inventory, { itemId = itemId, quantity = 1, instanceId = instanceId })
	return next, nil
end

-- Removes `quantity` of a stackable item; fails if there is not enough.
function Inventory.removeStackable(
	profile: PlayerProfile,
	itemId: string,
	quantity: number
): (PlayerProfile?, Reason?)
	if not isPositiveInt(quantity) then
		return nil, "badQuantity"
	end
	if Inventory.count(profile, itemId) < quantity then
		return nil, "missing"
	end
	local next = copy(profile)
	local remaining = quantity
	for index = #next.inventory, 1, -1 do
		local stack = next.inventory[index]
		if stack.itemId == itemId and stack.instanceId == nil then
			local take = math.min(stack.quantity, remaining)
			stack.quantity -= take
			remaining -= take
			if stack.quantity == 0 then
				table.remove(next.inventory, index)
			end
			if remaining == 0 then
				break
			end
		end
	end
	if remaining > 0 then
		return nil, "missing"
	end
	return next, nil
end

function Inventory.removeInstance(
	profile: PlayerProfile,
	instanceId: string
): (PlayerProfile?, Reason?)
	local next = copy(profile)
	for index, stack in next.inventory do
		if stack.instanceId == instanceId then
			table.remove(next.inventory, index)
			return next, nil
		end
	end
	return nil, "missing"
end

-- Checks the invariants directly (the schema validator does too; this is
-- the fast in-memory version services use before enqueueing).
function Inventory.check(profile: PlayerProfile): { string }
	local problems = {}
	if #profile.inventory > Inventory.MAX_STACKS then
		table.insert(problems, "too many stacks")
	end
	local instances: { [string]: boolean } = {}
	local stackables: { [string]: boolean } = {}
	for index, stack in profile.inventory do
		if not ContentRegistry.isValidId(stack.itemId) then
			table.insert(problems, string.format("stack %d has a bad itemId", index))
		end
		if not isPositiveInt(stack.quantity) then
			table.insert(problems, string.format("stack %d has a bad quantity", index))
		end
		if stack.instanceId ~= nil then
			if instances[stack.instanceId] then
				table.insert(
					problems,
					string.format("stack %d duplicates instance %s", index, stack.instanceId)
				)
			end
			instances[stack.instanceId] = true
			if stack.quantity ~= 1 then
				table.insert(
					problems,
					string.format("stack %d is an instance with quantity %d", index, stack.quantity)
				)
			end
		else
			if stackables[stack.itemId] then
				table.insert(
					problems,
					string.format("stack %d splits stackable %s", index, stack.itemId)
				)
			end
			stackables[stack.itemId] = true
		end
	end
	return problems
end

return table.freeze(Inventory)
