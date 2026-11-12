--!strict
-- Assertion helpers for tests (BM-009). Every failure message says what
-- was expected and what was found, so a red run is readable without a
-- debugger.

local Assert = {}

local function show(value: unknown): string
	local kind = typeof(value)
	if kind == "string" then
		return string.format("%q", value :: string)
	elseif kind == "table" then
		local parts = {}
		local keys = {}
		for key in value :: { [any]: any } do
			table.insert(keys, key)
		end
		table.sort(keys, function(a, b)
			return tostring(a) < tostring(b)
		end)
		for _, key in keys do
			table.insert(parts, tostring(key) .. "=" .. show((value :: { [any]: any })[key]))
			if #parts >= 12 then
				table.insert(parts, "...")
				break
			end
		end
		return "{" .. table.concat(parts, ", ") .. "}"
	end
	return tostring(value)
end

Assert.show = show

function Assert.equal(actual: unknown, expected: unknown, label: string?)
	if actual ~= expected then
		error(
			string.format(
				"%sexpected %s, got %s",
				if label then label .. ": " else "",
				show(expected),
				show(actual)
			),
			2
		)
	end
end

function Assert.notEqual(actual: unknown, unexpected: unknown, label: string?)
	if actual == unexpected then
		error(
			string.format(
				"%sexpected something other than %s",
				if label then label .. ": " else "",
				show(unexpected)
			),
			2
		)
	end
end

function Assert.isTrue(value: unknown, label: string?)
	if value ~= true then
		error(
			string.format(
				"%sexpected true, got %s",
				if label then label .. ": " else "",
				show(value)
			),
			2
		)
	end
end

function Assert.isFalse(value: unknown, label: string?)
	if value ~= false then
		error(
			string.format(
				"%sexpected false, got %s",
				if label then label .. ": " else "",
				show(value)
			),
			2
		)
	end
end

function Assert.isNil(value: unknown, label: string?)
	if value ~= nil then
		error(
			string.format(
				"%sexpected nil, got %s",
				if label then label .. ": " else "",
				show(value)
			),
			2
		)
	end
end

function Assert.notNil(value: unknown, label: string?)
	if value == nil then
		error(string.format("%sexpected a value, got nil", if label then label .. ": " else ""), 2)
	end
end

-- Deep structural equality for plain data tables.
local function deepEqual(a: unknown, b: unknown): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	local ta = a :: { [any]: any }
	local tb = b :: { [any]: any }
	for key, value in ta do
		if not deepEqual(value, tb[key]) then
			return false
		end
	end
	for key in tb do
		if ta[key] == nil then
			return false
		end
	end
	return true
end

Assert.deepEqual = function(actual: unknown, expected: unknown, label: string?)
	if not deepEqual(actual, expected) then
		error(
			string.format(
				"%sexpected %s, got %s",
				if label then label .. ": " else "",
				show(expected),
				show(actual)
			),
			2
		)
	end
end

-- Runs `fn` and asserts it errors; if `needle` is given the error message
-- must contain it. Returns the error message.
function Assert.throws(fn: () -> (), needle: string?, label: string?): string
	local ok, err = pcall(fn :: () -> ...any)
	if ok then
		error(
			string.format(
				"%sexpected an error, but the call succeeded",
				if label then label .. ": " else ""
			),
			2
		)
	end
	local message = tostring(err)
	if needle ~= nil and not string.find(message, needle, 1, true) then
		error(
			string.format(
				"%sexpected error containing %q, got %q",
				if label then label .. ": " else "",
				needle,
				message
			),
			2
		)
	end
	return message
end

function Assert.contains(haystack: string, needle: string, label: string?)
	if not string.find(haystack, needle, 1, true) then
		error(
			string.format(
				"%sexpected %q to contain %q",
				if label then label .. ": " else "",
				haystack,
				needle
			),
			2
		)
	end
end

function Assert.count(list: { unknown }, expected: number, label: string?)
	if #list ~= expected then
		error(
			string.format(
				"%sexpected %d items, got %d",
				if label then label .. ": " else "",
				expected,
				#list
			),
			2
		)
	end
end

return table.freeze(Assert)
