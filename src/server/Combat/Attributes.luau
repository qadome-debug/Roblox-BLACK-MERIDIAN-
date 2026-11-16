--!strict
-- Typed combat attributes and derived statistics (BM-052).
--
-- Four base attributes, owned by the server (set by progression, never by
-- a client), produce every derived statistic through fixed formulas plus
-- validated modifiers from Burdens and equipment. The derivation is pure
-- and deterministic: the same base and modifiers always give the same
-- numbers, and every result is clamped to its cap.
--
-- NOT CANON: the four attribute names, the derived statistics and every
-- formula and number here are engineering defaults chosen so the combat
-- core could be built and tested. The design has not supplied them. They
-- are to be confirmed or replaced (docs/design-requests.md, item 3).

export type BaseKey = "vigor" | "might" | "grace" | "will"

export type Base = { vigor: number, might: number, grace: number, will: number }

export type DerivedKey =
	"maxHealth"
	| "maxStamina"
	| "maxPosture"
	| "staminaRegen"
	| "postureRegen"
	| "attackPower"
	| "defense"
	| "moveSpeed"

export type Derived = {
	maxHealth: number,
	maxStamina: number,
	maxPosture: number,
	staminaRegen: number,
	postureRegen: number,
	attackPower: number,
	defense: number,
	moveSpeed: number,
}

-- A modifier adds to and/or multiplies one derived statistic. Modifiers
-- come from catalog definitions (Burdens, equipment), never from clients.
export type Modifier = { id: string, stat: DerivedKey, add: number?, mul: number? }

local MIN_BASE = 1
local MAX_BASE = 99

local Attributes = {}

Attributes.BASE_KEYS = table.freeze({ "vigor", "might", "grace", "will" } :: { BaseKey })
Attributes.DERIVED_KEYS = table.freeze({
	"maxHealth",
	"maxStamina",
	"maxPosture",
	"staminaRegen",
	"postureRegen",
	"attackPower",
	"defense",
	"moveSpeed",
} :: { DerivedKey })

Attributes.DEFAULT_BASE = table.freeze({ vigor = 10, might = 10, grace = 10, will = 10 } :: Base)

-- Hard caps after modifiers. Also the ceiling any catalog may reach.
local CAPS: { [DerivedKey]: { min: number, max: number } } = {
	maxHealth = { min = 1, max = 5000 },
	maxStamina = { min = 1, max = 1000 },
	maxPosture = { min = 1, max = 1000 },
	staminaRegen = { min = 0, max = 200 },
	postureRegen = { min = 0, max = 100 },
	attackPower = { min = 0, max = 1000 },
	defense = { min = 0, max = 500 },
	moveSpeed = { min = 4, max = 24 },
}

Attributes.CAPS = table.freeze(CAPS)
Attributes.MAX_MODIFIER_ADD = 1000
Attributes.MIN_MODIFIER_MUL = 0.1
Attributes.MAX_MODIFIER_MUL = 5

local function isInt(value: unknown, min: number, max: number): boolean
	return type(value) == "number"
		and value == value
		and value >= min
		and value <= max
		and value % 1 == 0
end

local function isFinite(value: unknown): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

function Attributes.validateBase(value: unknown): { string }
	local problems = {}
	if type(value) ~= "table" then
		return { "base attributes must be a table" }
	end
	local t = value :: { [any]: unknown }
	for key in t do
		if type(key) ~= "string" or table.find(Attributes.BASE_KEYS, key :: BaseKey) == nil then
			table.insert(problems, "unknown attribute " .. tostring(key))
		end
	end
	for _, key in Attributes.BASE_KEYS do
		if not isInt(t[key], MIN_BASE, MAX_BASE) then
			table.insert(
				problems,
				key .. " must be an integer in [" .. MIN_BASE .. ", " .. MAX_BASE .. "]"
			)
		end
	end
	return problems
end

function Attributes.validateModifier(value: unknown): { string }
	local problems = {}
	if type(value) ~= "table" then
		return { "modifier must be a table" }
	end
	local m = value :: { [any]: unknown }
	for key in m do
		if key ~= "id" and key ~= "stat" and key ~= "add" and key ~= "mul" then
			table.insert(problems, "unknown modifier field " .. tostring(key))
		end
	end
	if type(m.id) ~= "string" or #(m.id :: string) == 0 or #(m.id :: string) > 64 then
		table.insert(problems, "modifier id must be a short string")
	end
	if type(m.stat) ~= "string" or CAPS[m.stat :: DerivedKey] == nil then
		table.insert(problems, "modifier stat is not a derived statistic: " .. tostring(m.stat))
	end
	if m.add == nil and m.mul == nil then
		table.insert(problems, "modifier changes nothing")
	end
	if
		m.add ~= nil
		and (not isFinite(m.add) or math.abs(m.add :: number) > Attributes.MAX_MODIFIER_ADD)
	then
		table.insert(problems, "modifier add out of range")
	end
	if
		m.mul ~= nil
		and (
			not isFinite(m.mul)
			or (m.mul :: number) < Attributes.MIN_MODIFIER_MUL
			or (m.mul :: number) > Attributes.MAX_MODIFIER_MUL
		)
	then
		table.insert(problems, "modifier mul out of range")
	end
	return problems
end

-- The formulas. Base values are the four attributes; nothing else.
local function formulas(base: Base): Derived
	return {
		maxHealth = 100 + base.vigor * 10,
		maxStamina = 100 + base.grace * 4,
		maxPosture = 50 + base.will * 3,
		staminaRegen = 15 + base.grace * 0.5,
		postureRegen = 5 + base.will * 0.3,
		attackPower = 10 + base.might * 2,
		defense = base.might * 0.5 + base.vigor * 0.5,
		moveSpeed = 16 + base.grace * 0.05,
	}
end

local function clamp(key: DerivedKey, value: number): number
	local cap = CAPS[key]
	return math.clamp(value, cap.min, cap.max)
end

-- Derives every statistic: formula, then all additive modifiers, then all
-- multiplicative modifiers, then the cap. Modifier order never matters.
-- Errors on an invalid modifier: catalogs are validated before use, so a
-- bad one here is a programming error, not player input.
function Attributes.derive(base: Base, modifiers: { Modifier }?): Derived
	local problems = Attributes.validateBase(base)
	if #problems > 0 then
		error("Attributes.derive: " .. table.concat(problems, "; "), 2)
	end
	local raw = formulas(base) :: any
	local adds: { [string]: number } = {}
	local muls: { [string]: number } = {}
	local list: { Modifier } = if modifiers ~= nil then modifiers else {}
	for _, modifier: Modifier in list do
		local bad = Attributes.validateModifier(modifier)
		if #bad > 0 then
			error(
				"Attributes.derive: modifier "
					.. tostring(modifier.id)
					.. ": "
					.. table.concat(bad, "; "),
				2
			)
		end
		if modifier.add ~= nil then
			adds[modifier.stat] = (adds[modifier.stat] or 0) + modifier.add
		end
		if modifier.mul ~= nil then
			muls[modifier.stat] = (muls[modifier.stat] or 1) * modifier.mul
		end
	end
	local result: { [string]: number } = {}
	for _, key: DerivedKey in Attributes.DERIVED_KEYS do
		local value = raw[key] :: number
		value = (value + (adds[key] or 0)) * (muls[key] or 1)
		-- Round to 1/100 so float noise cannot make two servers disagree.
		value = math.floor(value * 100 + 0.5) / 100
		result[key] = clamp(key, value)
	end
	return result :: any
end

return table.freeze(Attributes)
