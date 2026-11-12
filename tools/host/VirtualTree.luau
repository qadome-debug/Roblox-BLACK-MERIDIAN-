--!strict
-- Virtual instance tree for running src/ modules under Lune.
--
-- Builds a tree of fake Instances that mirrors how Rojo mounts the source
-- folders into a Roblox place, so code written with instance paths such as
-- `require(script.Parent.Foo)` or
-- `require(game:GetService("ReplicatedStorage").Shared.Types.Ids)` resolves
-- the same way it would in Studio. Only the navigation surface is modelled:
-- Name, ClassName, Parent, child lookup, FindFirstChild, WaitForChild,
-- GetChildren, IsA, GetFullName. Anything else is an error, which is the
-- point: code that reaches for real engine behaviour does not belong in a
-- unit test.

local fs = require("@lune/fs")

export type Node = {
	Name: string,
	ClassName: string,
	Parent: Node?,
	_children: { [string]: Node },
	_order: { string },
	_file: string?,
	_rel: string?,
	[string]: any,
}

local VirtualTree = {}

local methods = {}

function methods.FindFirstChild(self: Node, name: string): Node?
	return self._children[name]
end

function methods.WaitForChild(self: Node, name: string, _timeout: number?): Node
	local child = self._children[name]
	if child == nil then
		error(
			string.format(
				"WaitForChild: %s has no child '%s' in the virtual tree",
				self:GetFullName(),
				name
			)
		)
	end
	return child
end

function methods.GetChildren(self: Node): { Node }
	local out = {}
	for _, name in self._order do
		table.insert(out, self._children[name])
	end
	return out
end

function methods.IsA(self: Node, className: string): boolean
	if self.ClassName == className then
		return true
	end
	if className == "Instance" then
		return true
	end
	if className == "LuaSourceContainer" then
		return self.ClassName == "ModuleScript"
			or self.ClassName == "Script"
			or self.ClassName == "LocalScript"
	end
	return false
end

function methods.GetFullName(self: Node): string
	local parts = {}
	local node: Node? = self
	while node ~= nil and node.Parent ~= nil do
		table.insert(parts, 1, node.Name)
		node = node.Parent
	end
	return table.concat(parts, ".")
end

-- Fields that legitimately hold nil, so a lookup must not fall through to
-- child resolution (which would error, and the error path reads Parent).
local NIL_FIELDS = { Parent = true, _file = true, _rel = true }

local nodeMeta = {
	__index = function(self: Node, key: any): any
		if NIL_FIELDS[key] then
			return nil
		end
		local method = methods[key]
		if method ~= nil then
			return method
		end
		if type(key) == "string" then
			local children = rawget(self, "_children") :: { [string]: Node }
			local child = children[key]
			if child ~= nil then
				return child
			end
		end
		error(
			string.format(
				'%s is not a valid member of %s "%s"',
				tostring(key),
				self.ClassName,
				methods.GetFullName(self)
			),
			2
		)
	end,
	__newindex = function(self: Node, key: any, value: any)
		if NIL_FIELDS[key] then
			rawset(self, key, value)
			return
		end
		error(
			string.format(
				"cannot set '%s' on virtual instance %s",
				tostring(key),
				methods.GetFullName(self)
			),
			2
		)
	end,
	__tostring = function(self: Node): string
		return self.Name
	end,
}

local function newNode(name: string, className: string, parent: Node?): Node
	local node = {
		Name = name,
		ClassName = className,
		Parent = parent,
		_children = {},
		_order = {},
		_file = nil,
		_rel = nil,
	}
	setmetatable(node, nodeMeta)
	if parent ~= nil then
		if parent._children[name] ~= nil then
			error(string.format("duplicate child '%s' under %s", name, parent:GetFullName()))
		end
		parent._children[name] = node :: any
		table.insert(parent._order, name)
	end
	return node :: any
end

local function classForFile(fileName: string): (string, string)
	local base = string.gsub(fileName, "%.luau$", "")
	if string.match(base, "%.server$") then
		return (string.gsub(base, "%.server$", "")), "Script"
	end
	if string.match(base, "%.client$") then
		return (string.gsub(base, "%.client$", "")), "LocalScript"
	end
	return base, "ModuleScript"
end

local function mountDir(dir: string, rel: string, parent: Node)
	local names = fs.readDir(dir)
	table.sort(names)
	for _, name in names do
		local full = dir .. "/" .. name
		local childRel = if rel == "" then name else rel .. "/" .. name
		if fs.isDir(full) then
			local initPath = full .. "/init.luau"
			local node: Node
			if fs.isFile(initPath) then
				node = newNode(name, "ModuleScript", parent)
				node._file = initPath
				node._rel = childRel .. "/init.luau"
			else
				node = newNode(name, "Folder", parent)
			end
			mountDir(full, childRel, node)
		elseif string.match(name, "%.luau$") and name ~= "init.luau" then
			local instanceName, className = classForFile(name)
			local node = newNode(instanceName, className, parent)
			node._file = full
			node._rel = childRel
		end
	end
end

export type Tree = {
	game: Node,
	services: { [string]: Node },
	byFile: { [string]: Node },
}

-- Mount a Rojo-style source directory. `mounts` maps a service path such as
-- "ReplicatedStorage/Shared" to a folder under srcDir such as "shared".
function VirtualTree.build(srcDir: string, mounts: { [string]: string }): Tree
	local game = newNode("game", "DataModel", nil)
	local services: { [string]: Node } = {}

	local function service(name: string): Node
		local existing = services[name]
		if existing then
			return existing
		end
		local node = newNode(name, name, game)
		services[name] = node
		return node
	end

	local sortedMounts = {}
	for target in mounts do
		table.insert(sortedMounts, target)
	end
	table.sort(sortedMounts)

	for _, target in sortedMounts do
		local folder = mounts[target]
		local parts = {}
		for part in string.gmatch(target, "[^/]+") do
			table.insert(parts, part)
		end
		local node = service(parts[1])
		for i = 2, #parts do
			local existing = node._children[parts[i]]
			node = existing or newNode(parts[i], "Folder", node)
		end
		local dir = srcDir .. "/" .. folder
		if fs.isDir(dir) then
			mountDir(dir, folder, node)
		end
	end

	local byFile: { [string]: Node } = {}
	local function collect(node: Node)
		if node._rel ~= nil then
			byFile[node._rel] = node
		end
		for _, name in node._order do
			collect(node._children[name])
		end
	end
	collect(game)

	-- game:GetService returns an existing service or an empty one, so code can
	-- ask for Players or RunService without the tree knowing about them.
	rawset(game :: any, "GetService", function(_self: Node, name: string): Node
		return service(name)
	end)

	return { game = game, services = services, byFile = byFile }
end

return VirtualTree
