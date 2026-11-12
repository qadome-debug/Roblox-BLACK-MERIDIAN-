--!strict
-- A minimal fake Instance for tests that need a tree of named, classed
-- objects (remote audits, folder layout checks). Not a VirtualTree node:
-- these are mutable and never backed by files.

export type FakeInstance = {
	Name: string,
	ClassName: string,
	Parent: FakeInstance?,
	GetChildren: (self: FakeInstance) -> { FakeInstance },
	GetDescendants: (self: FakeInstance) -> { FakeInstance },
	FindFirstChild: (self: FakeInstance, name: string) -> FakeInstance?,
	IsA: (self: FakeInstance, className: string) -> boolean,
	Destroy: (self: FakeInstance) -> (),
	[string]: any,
}

local FakeInstance = {}

local SUPERCLASSES: { [string]: { string } } = {
	RemoteEvent = { "BaseRemoteEvent", "Instance" },
	UnreliableRemoteEvent = { "BaseRemoteEvent", "Instance" },
	RemoteFunction = { "Instance" },
	Folder = { "Instance" },
	ReplicatedStorage = { "ServiceProvider", "Instance" },
}

function FakeInstance.new(className: string, name: string, parent: FakeInstance?): FakeInstance
	local children: { FakeInstance } = {}
	local instance = {} :: FakeInstance
	instance.Name = name
	instance.ClassName = className
	instance.Parent = parent

	function instance:GetChildren(): { FakeInstance }
		return table.clone(children)
	end

	function instance:GetDescendants(): { FakeInstance }
		local out = {}
		for _, child in children do
			table.insert(out, child)
			for _, grandchild in child:GetDescendants() do
				table.insert(out, grandchild)
			end
		end
		return out
	end

	function instance:FindFirstChild(childName: string): FakeInstance?
		for _, child in children do
			if child.Name == childName then
				return child
			end
		end
		return nil
	end

	function instance:IsA(class: string): boolean
		if class == className then
			return true
		end
		local supers = SUPERCLASSES[className]
		return supers ~= nil and table.find(supers, class) ~= nil
	end

	function instance:Destroy()
		local p = self.Parent
		if p ~= nil then
			local siblings = (p :: any)._children :: { FakeInstance }
			local index = table.find(siblings, self)
			if index then
				table.remove(siblings, index)
			end
		end
		self.Parent = nil
	end

	instance._children = children

	if parent ~= nil then
		table.insert((parent :: any)._children :: { FakeInstance }, instance)
	end
	return instance
end

-- A factory for Remotes.create that builds fake instances.
function FakeInstance.remoteFactory()
	return {
		createFolder = function(name: string, parent: any): any
			return FakeInstance.new("Folder", name, parent)
		end,
		createRemoteEvent = function(name: string, parent: any): any
			return FakeInstance.new("RemoteEvent", name, parent)
		end,
	}
end

return table.freeze(FakeInstance)
