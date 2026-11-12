--!strict
-- Remote allowlist (BM-011).
--
-- The game has exactly one client-to-server remote, ActionRequest, and a
-- fixed set of one-way server-to-client remotes. This module is the only
-- place that creates them, and `audit` reports any other remote found in
-- the place so a stray RemoteEvent or RemoteFunction cannot slip in.
--
-- Instance creation is injected so the module runs under Lune with fake
-- instances; `robloxFactory()` is the real thing and is only called from
-- Bootstrap.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Protocol = require(ReplicatedStorage.Shared.Contracts.Protocol)

export type Direction = "clientToServer" | "serverToClient"

export type RemoteSpec = { name: string, direction: Direction }

-- Minimal instance surface the module needs, satisfied by real Instances and
-- by tests/Support/FakeInstance.
export type InstanceLike = {
	Name: string,
	ClassName: string,
	Parent: InstanceLike?,
	GetDescendants: (self: InstanceLike) -> { InstanceLike },
	FindFirstChild: (self: InstanceLike, name: string) -> InstanceLike?,
	IsA: (self: InstanceLike, className: string) -> boolean,
	[string]: any,
}

export type Factory = {
	createFolder: (name: string, parent: InstanceLike) -> InstanceLike,
	createRemoteEvent: (name: string, parent: InstanceLike) -> InstanceLike,
}

export type RemoteSet = { [string]: InstanceLike }

local FOLDER_NAME = "BlackMeridian"

local SPEC: { RemoteSpec } = {
	{ name = Protocol.REMOTES.ACTION_REQUEST, direction = "clientToServer" },
	{ name = Protocol.REMOTES.ACTION_RESULT, direction = "serverToClient" },
	{ name = Protocol.REMOTES.STATE_DELTA, direction = "serverToClient" },
	{ name = Protocol.REMOTES.COMBAT_CUE, direction = "serverToClient" },
	{ name = Protocol.REMOTES.PARTY_STATE, direction = "serverToClient" },
	{ name = Protocol.REMOTES.TRAVEL_STATE, direction = "serverToClient" },
}

local ALLOWED: { [string]: RemoteSpec } = {}
for _, spec in SPEC do
	ALLOWED[spec.name] = spec
end

-- Classes that carry client/server traffic. Anything of these classes that
-- is not in the allowlist, or not under our folder, is a finding.
local REMOTE_CLASSES = { "RemoteEvent", "RemoteFunction", "UnreliableRemoteEvent" }

local Remotes = {}

Remotes.FOLDER_NAME = FOLDER_NAME
Remotes.SPEC = table.freeze(SPEC)

function Remotes.isAllowed(name: string): boolean
	return ALLOWED[name] ~= nil
end

-- Creates the folder and every allowed remote under `parent`. Errors if the
-- folder already exists: remotes are created exactly once, by Bootstrap.
function Remotes.create(parent: InstanceLike, factory: Factory): RemoteSet
	if parent:FindFirstChild(FOLDER_NAME) ~= nil then
		error("Remotes.create: " .. FOLDER_NAME .. " already exists under " .. parent.Name, 2)
	end
	local folder = factory.createFolder(FOLDER_NAME, parent)
	local set: RemoteSet = {}
	for _, spec in SPEC do
		set[spec.name] = factory.createRemoteEvent(spec.name, folder)
	end
	return table.freeze(set)
end

local function isRemoteClass(instance: InstanceLike): boolean
	for _, className in REMOTE_CLASSES do
		if instance:IsA(className) then
			return true
		end
	end
	return false
end

local function fullName(instance: InstanceLike): string
	local parts = {}
	local node: InstanceLike? = instance
	while node ~= nil do
		table.insert(parts, 1, node.Name)
		node = node.Parent
	end
	return table.concat(parts, ".")
end

-- Returns one finding per remote that should not exist. An empty list means
-- only the allowlisted remotes exist under `root`, each exactly once, each
-- inside the BlackMeridian folder, and each a RemoteEvent.
function Remotes.audit(root: InstanceLike): { string }
	local findings: { string } = {}
	local seen: { [string]: number } = {}

	for _, instance in root:GetDescendants() do
		if not isRemoteClass(instance) then
			continue
		end
		local name = instance.Name
		local parent = instance.Parent
		local inFolder = parent ~= nil and parent.Name == FOLDER_NAME
		if not Remotes.isAllowed(name) then
			table.insert(
				findings,
				"unexpected remote " .. fullName(instance) .. " (" .. instance.ClassName .. ")"
			)
		elseif not inFolder then
			table.insert(
				findings,
				"remote outside the " .. FOLDER_NAME .. " folder: " .. fullName(instance)
			)
		elseif instance.ClassName ~= "RemoteEvent" then
			table.insert(
				findings,
				"remote with wrong class: " .. fullName(instance) .. " is " .. instance.ClassName
			)
		else
			seen[name] = (seen[name] or 0) + 1
			if seen[name] > 1 then
				table.insert(findings, "duplicate remote " .. fullName(instance))
			end
		end
	end

	return findings
end

-- The production factory. Only Bootstrap calls this; tests use fakes.
function Remotes.robloxFactory(): Factory
	return {
		createFolder = function(name: string, parent: InstanceLike): InstanceLike
			local folder = Instance.new("Folder")
			folder.Name = name
			folder.Parent = parent :: any
			return folder :: any
		end,
		createRemoteEvent = function(name: string, parent: InstanceLike): InstanceLike
			local remote = Instance.new("RemoteEvent")
			remote.Name = name
			remote.Parent = parent :: any
			return remote :: any
		end,
	}
end

return table.freeze(Remotes)
