--!strict
-- In-memory DataStore fake with fault injection (BM-009).
--
-- Implements the subset of DataStoreService the game uses (GetDataStore,
-- GetAsync, UpdateAsync, SetAsync, RemoveAsync) over plain tables, with
-- controls to make the next operations fail in the ways the plan's
-- failure-mode table (5.6) requires:
--
--   * "error"          the call throws, nothing is written
--   * "timeout"        the call throws, nothing is written (same as error,
--                      kept distinct so tests read clearly)
--   * "lostResponse"   the write COMMITS, then the call throws. This is the
--                      uncertain-write case: the caller cannot tell it
--                      succeeded.
--   * "budget"         the call throws with a budget-exhausted message
--   * "delay"          the call yields `seconds` of fake time before
--                      running (advances the manual clock)
--
-- Values are deep-copied on the way in and out, so a caller holding a
-- reference cannot mutate stored data, exactly like the real service.
-- Keys and values are size-checked against the real limits so a test
-- cannot pass with data production would reject.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Clock = require(ReplicatedStorage.Shared.Sim.Clock)
local Rng = require(ReplicatedStorage.Shared.Sim.Rng)

export type FaultKind = "error" | "timeout" | "lostResponse" | "budget" | "delay"

export type Fault = {
	kind: FaultKind,
	-- Only operations with this name are affected ("GetAsync", "UpdateAsync",
	-- "SetAsync", "RemoveAsync"); nil means any.
	operation: string?,
	-- Only this key; nil means any.
	key: string?,
	-- For "delay": fake seconds to advance.
	seconds: number?,
	-- How many times the fault fires before it is consumed. Default 1.
	times: number?,
}

export type Transform = (old: any, keyInfo: KeyInfo?) -> any

export type KeyInfo = { Version: string, CreatedTime: number, UpdatedTime: number }

export type DataStore = {
	name: string,
	GetAsync: (self: DataStore, key: string) -> (any, KeyInfo?),
	UpdateAsync: (self: DataStore, key: string, transform: Transform) -> (any, KeyInfo?),
	SetAsync: (self: DataStore, key: string, value: any) -> string,
	RemoveAsync: (self: DataStore, key: string) -> (any, KeyInfo?),
}

export type Call = { operation: string, store: string, key: string, outcome: string, time: number }

export type Service = {
	GetDataStore: (self: Service, name: string, scope: string?) -> DataStore,
	-- Fault injection.
	injectFault: (self: Service, fault: Fault) -> (),
	clearFaults: (self: Service) -> (),
	-- Inspection.
	peek: (self: Service, storeName: string, key: string) -> any,
	-- Writes directly, bypassing faults, for fixtures.
	seed: (self: Service, storeName: string, key: string, value: any) -> (),
	calls: (self: Service) -> { Call },
	callCount: (self: Service, operation: string?) -> number,
}

export type Options = { clock: Clock.ManualClock, rng: Rng.Rng }

-- Real-service limits the fake enforces.
local MAX_KEY_LENGTH = 50
local MAX_VALUE_BYTES = 4 * 1024 * 1024

local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, item in value do
		copy[deepCopy(key)] = deepCopy(item)
	end
	return copy
end

-- Rough encoded size; enough to catch oversized values in tests.
local function encodedSize(value: any): number
	local kind = type(value)
	if kind == "string" then
		return #value + 2
	elseif kind == "number" then
		return #tostring(value)
	elseif kind == "boolean" then
		return 5
	elseif kind == "table" then
		local total = 2
		for key, item in value do
			total += encodedSize(key) + encodedSize(item) + 2
		end
		return total
	elseif kind == "nil" then
		return 4
	end
	error("DataStore values may only contain strings, numbers, booleans and tables, got " .. kind)
end

local function checkKey(key: unknown)
	if type(key) ~= "string" or #key == 0 then
		error("DataStore key must be a non-empty string", 3)
	end
	if #key > MAX_KEY_LENGTH then
		error("DataStore key exceeds " .. MAX_KEY_LENGTH .. " characters", 3)
	end
end

local function checkValue(value: any)
	if encodedSize(value) > MAX_VALUE_BYTES then
		error("DataStore value exceeds the 4 MiB limit", 3)
	end
end

local FakeDataStoreService = {}

function FakeDataStoreService.new(options: Options): Service
	local clock = options.clock
	local rng = options.rng
	local stores: { [string]: { [string]: { value: any, info: KeyInfo } } } = {}
	local faults: { Fault } = {}
	local calls: { Call } = {}
	local versionCounter = 0

	local function storeFor(name: string): { [string]: { value: any, info: KeyInfo } }
		local existing = stores[name]
		if existing == nil then
			existing = {}
			stores[name] = existing
		end
		return existing
	end

	-- Finds and consumes the first matching fault.
	local function takeFault(operation: string, key: string): Fault?
		for index, fault in faults do
			if
				(fault.operation == nil or fault.operation == operation)
				and (fault.key == nil or fault.key == key)
			then
				local remaining = (fault.times or 1) - 1
				if remaining <= 0 then
					table.remove(faults, index)
				else
					faults[index] = {
						kind = fault.kind,
						operation = fault.operation,
						key = fault.key,
						seconds = fault.seconds,
						times = remaining,
					}
				end
				return fault
			end
		end
		return nil
	end

	local function record(operation: string, storeName: string, key: string, outcome: string)
		table.insert(calls, {
			operation = operation,
			store = storeName,
			key = key,
			outcome = outcome,
			time = clock:now(),
		})
	end

	local function nextVersion(): string
		versionCounter += 1
		return string.format("%08d.%08x", versionCounter, rng:nextInteger(0, 0xFFFFFFFF))
	end

	local function makeStore(name: string): DataStore
		local data = storeFor(name)
		local store = {} :: DataStore
		store.name = name

		-- Runs `body` under fault injection. `commit` is called when the
		-- operation should take effect; for lostResponse it runs and then
		-- the call still throws.
		local function perform(
			operation: string,
			key: string,
			body: () -> (any, KeyInfo?)
		): (any, KeyInfo?)
			checkKey(key)
			local fault = takeFault(operation, key)
			if fault ~= nil then
				if fault.kind == "delay" then
					clock:advance(fault.seconds or 1)
				elseif fault.kind == "error" then
					record(operation, name, key, "error")
					error(string.format("%s failed: injected error (%s)", operation, key), 2)
				elseif fault.kind == "timeout" then
					record(operation, name, key, "timeout")
					error(string.format("%s failed: request timed out (%s)", operation, key), 2)
				elseif fault.kind == "budget" then
					record(operation, name, key, "budget")
					error(
						string.format("%s failed: request budget exhausted (%s)", operation, key),
						2
					)
				elseif fault.kind == "lostResponse" then
					body()
					record(operation, name, key, "lostResponse")
					error(
						string.format("%s failed: response lost after commit (%s)", operation, key),
						2
					)
				end
			end
			local value, info = body()
			record(operation, name, key, "ok")
			return value, info
		end

		function store:GetAsync(key: string): (any, KeyInfo?)
			return perform("GetAsync", key, function()
				local entry = data[key]
				if entry == nil then
					return nil, nil
				end
				return deepCopy(entry.value), deepCopy(entry.info)
			end)
		end

		function store:UpdateAsync(key: string, transform: Transform): (any, KeyInfo?)
			return perform("UpdateAsync", key, function()
				local entry = data[key]
				local old = if entry ~= nil then deepCopy(entry.value) else nil
				local info = if entry ~= nil then deepCopy(entry.info) else nil
				local new = transform(old, info)
				if new == nil then
					-- Returning nil cancels the update, like the real service.
					return old, info
				end
				checkValue(new)
				local now = clock:wallTime() * 1000
				local newInfo: KeyInfo = {
					Version = nextVersion(),
					CreatedTime = if entry ~= nil then entry.info.CreatedTime else now,
					UpdatedTime = now,
				}
				data[key] = { value = deepCopy(new), info = newInfo }
				return deepCopy(new), deepCopy(newInfo)
			end)
		end

		function store:SetAsync(key: string, value: any): string
			local _, info = perform("SetAsync", key, function()
				checkValue(value)
				local now = clock:wallTime() * 1000
				local entry = data[key]
				local newInfo: KeyInfo = {
					Version = nextVersion(),
					CreatedTime = if entry ~= nil then entry.info.CreatedTime else now,
					UpdatedTime = now,
				}
				data[key] = { value = deepCopy(value), info = newInfo }
				return nil, deepCopy(newInfo)
			end)
			return (info :: KeyInfo).Version
		end

		function store:RemoveAsync(key: string): (any, KeyInfo?)
			return perform("RemoveAsync", key, function()
				local entry = data[key]
				data[key] = nil
				if entry == nil then
					return nil, nil
				end
				return deepCopy(entry.value), deepCopy(entry.info)
			end)
		end

		return table.freeze(store)
	end

	local storeObjects: { [string]: DataStore } = {}

	local service = {} :: Service

	function service:GetDataStore(name: string, scope: string?): DataStore
		local fullName = if scope ~= nil then name .. "/" .. scope else name
		local existing = storeObjects[fullName]
		if existing == nil then
			existing = makeStore(fullName)
			storeObjects[fullName] = existing
		end
		return existing
	end

	function service:injectFault(fault: Fault)
		table.insert(faults, fault)
	end

	function service:clearFaults()
		table.clear(faults)
	end

	function service:peek(storeName: string, key: string): any
		local entry = storeFor(storeName)[key]
		return if entry ~= nil then deepCopy(entry.value) else nil
	end

	function service:seed(storeName: string, key: string, value: any)
		checkKey(key)
		checkValue(value)
		local now = clock:wallTime() * 1000
		storeFor(storeName)[key] = {
			value = deepCopy(value),
			info = { Version = nextVersion(), CreatedTime = now, UpdatedTime = now },
		}
	end

	function service:calls(): { Call }
		return table.clone(calls)
	end

	function service:callCount(operation: string?): number
		if operation == nil then
			return #calls
		end
		local count = 0
		for _, call in calls do
			if call.operation == operation then
				count += 1
			end
		end
		return count
	end

	return table.freeze(service)
end

return table.freeze(FakeDataStoreService)
