--!strict
-- Module loader for running src/ code under Lune.
--
-- Each ModuleScript node in the virtual tree is compiled once with an
-- environment that provides `script`, `game`, and a `require` that accepts
-- virtual instances. Results are cached per node like Roblox does. Cyclic
-- requires are reported with the chain that caused them.

local fs = require("@lune/fs")
local luau = require("@lune/luau")

local VirtualTree = require("./VirtualTree")

type Node = VirtualTree.Node
type Tree = VirtualTree.Tree

export type Loader = {
	tree: Tree,
	require: (target: any) -> any,
	-- Extra globals injected into every module environment (fakes for engine
	-- globals, for example). Set before the first require.
	globals: { [string]: any },
}

local Loader = {}

function Loader.new(tree: Tree): Loader
	local cache: { [any]: { value: any } } = {}
	local loading: { [any]: boolean } = {}
	local stack: { string } = {}

	local loader = {} :: Loader
	loader.tree = tree
	loader.globals = {}

	local function hostRequire(target: any): any
		if type(target) == "string" then
			error(
				string.format(
					"require(%q): string requires are not allowed in src/; use an instance path",
					target
				),
				2
			)
		end
		if type(target) ~= "table" or rawget(target, "_children") == nil then
			error("require: argument is not a virtual instance", 2)
		end
		local node = target :: Node
		if node.ClassName ~= "ModuleScript" or node._file == nil then
			error(
				string.format(
					"require: %s is a %s, not a ModuleScript",
					node:GetFullName(),
					node.ClassName
				),
				2
			)
		end

		local hit = cache[node]
		if hit ~= nil then
			return hit.value
		end
		if loading[node] then
			error(
				string.format(
					"cyclic require: %s -> %s",
					table.concat(stack, " -> "),
					node:GetFullName()
				),
				2
			)
		end

		loading[node] = true
		table.insert(stack, node:GetFullName())

		local source = fs.readFile(node._file :: string)
		local env: { [string]: any } = table.clone(loader.globals)
		env.script = node
		env.game = tree.game
		env.require = hostRequire

		local chunk = luau.load(source, {
			debugName = node._rel,
			environment = env,
			injectGlobals = true,
		})

		local ok, result = pcall(chunk)

		table.remove(stack)
		loading[node] = nil

		if not ok then
			error(
				string.format("error while loading %s: %s", node:GetFullName(), tostring(result)),
				0
			)
		end
		if result == nil then
			error(string.format("%s did not return a value", node:GetFullName()), 0)
		end

		cache[node] = { value = result }
		return result
	end

	loader.require = hostRequire
	return loader
end

-- The standard mounts for this repository.
Loader.MOUNTS = {
	["ReplicatedStorage/Shared"] = "shared",
	["ServerScriptService/Server"] = "server",
	["StarterPlayer/StarterPlayerScripts/Client"] = "client",
	["ServerStorage/Tests"] = "tests",
}

function Loader.forProject(root: string): Loader
	local tree = VirtualTree.build(root .. "/src", Loader.MOUNTS)
	return Loader.new(tree)
end

return Loader
