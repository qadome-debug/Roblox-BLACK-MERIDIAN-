--!strict
-- BM-011: only the allowlisted remotes exist.

local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local Assert = require(ServerStorage.Tests.Support.Assert)
local FakeInstance = require(ServerStorage.Tests.Support.FakeInstance)
local Remotes = require(ServerScriptService.Server.Network.Remotes)
local Suite = require(ServerStorage.Tests.Support.Suite)

local suite = Suite.new("Remotes")

local function replicatedStorage()
	return FakeInstance.new("ReplicatedStorage", "ReplicatedStorage")
end

suite:case("create builds exactly the allowlisted remotes and the audit passes", function()
	local root = replicatedStorage()
	local set = Remotes.create(root :: any, FakeInstance.remoteFactory())
	Assert.count(Remotes.audit(root :: any), 0, "clean audit")
	Assert.count(Remotes.SPEC, 6, "six remotes in the plan")
	for _, spec in Remotes.SPEC do
		Assert.notNil(set[spec.name], spec.name .. " created")
		Assert.equal(set[spec.name].ClassName, "RemoteEvent", spec.name .. " class")
		Assert.equal(
			(set[spec.name].Parent :: any).Name,
			Remotes.FOLDER_NAME,
			spec.name .. " parent"
		)
	end
	Assert.isTrue(table.isfrozen(set), "set frozen")
end)

suite:case("only one client-to-server remote exists", function()
	local ingress = 0
	for _, spec in Remotes.SPEC do
		if spec.direction == "clientToServer" then
			ingress += 1
			Assert.equal(spec.name, "ActionRequest", "the ingress is ActionRequest")
		end
	end
	Assert.equal(ingress, 1, "exactly one ingress")
	Assert.isFalse(Remotes.isAllowed("GrantReward"), "no reward remote")
	Assert.isFalse(Remotes.isAllowed("ApplyDamage"), "no damage remote")
	Assert.isFalse(Remotes.isAllowed("actionrequest"), "case sensitive")
end)

suite:case("create refuses to run twice", function()
	local root = replicatedStorage()
	Remotes.create(root :: any, FakeInstance.remoteFactory())
	Assert.throws(function()
		Remotes.create(root :: any, FakeInstance.remoteFactory())
	end, "already exists")
end)

suite:case("audit reports stray, misplaced, duplicate and wrong-class remotes", function()
	local root = replicatedStorage()
	Remotes.create(root :: any, FakeInstance.remoteFactory())
	local folder = root:FindFirstChild(Remotes.FOLDER_NAME) :: any

	FakeInstance.new("RemoteFunction", "GrantReward", root) -- stray at root
	local hidden = FakeInstance.new("Folder", "Assets", root)
	FakeInstance.new("UnreliableRemoteEvent", "ApplyDamage", hidden) -- stray, nested
	FakeInstance.new("RemoteEvent", "StateDelta", root) -- allowed name, wrong place
	FakeInstance.new("RemoteEvent", "CombatCue", folder) -- duplicate
	FakeInstance.new("RemoteFunction", "PartyState", folder) -- allowed name, wrong class (and duplicate name)

	local findings = Remotes.audit(root :: any)
	local joined = table.concat(findings, "\n")
	Assert.contains(joined, "unexpected remote ReplicatedStorage.GrantReward", "stray at root")
	Assert.contains(
		joined,
		"unexpected remote ReplicatedStorage.Assets.ApplyDamage",
		"stray nested"
	)
	Assert.contains(
		joined,
		"outside the BlackMeridian folder: ReplicatedStorage.StateDelta",
		"misplaced"
	)
	Assert.contains(
		joined,
		"duplicate remote ReplicatedStorage.BlackMeridian.CombatCue",
		"duplicate"
	)
	Assert.contains(
		joined,
		"wrong class: ReplicatedStorage.BlackMeridian.PartyState is RemoteFunction",
		"class"
	)
	Assert.count(findings, 5, "one finding per problem")
end)

suite:case("audit ignores non-remote instances", function()
	local root = replicatedStorage()
	Remotes.create(root :: any, FakeInstance.remoteFactory())
	FakeInstance.new("Folder", "Shared", root)
	FakeInstance.new("Folder", "GrantReward", root) -- a folder with a scary name is fine
	Assert.count(Remotes.audit(root :: any), 0, "no findings")
end)

return suite:cases()
