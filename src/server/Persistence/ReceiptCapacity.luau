--!strict
-- Receipt capacity monitoring and archive migration (BM-047).
--
-- Permanent receipts are never deleted. When a profile's permanent ledger
-- approaches its budget, the oldest half (by sorted ID; IDs are stable and
-- the order is deterministic) is moved into an archive record under a
-- separate DataStore key, and the profile keeps the archive key in
-- `receipts.archives`. Order of operations makes this safe:
--
--   1. the archive record is written and confirmed (never rewritten),
--   2. only then are those receipts removed from the profile in a
--      lease-guarded mutation that also appends the archive key,
--   3. duplicate checks consult the profile AND its archives: the service
--      loads every archive for a key once per session (`ArchivedSet`) and
--      hands it to the grant mutations, which refuse archived receipts.
--
-- A crash between 1 and 2 leaves an orphan archive record (harmless: the
-- receipts are still in the profile). Capacity exhaustion with no
-- archivable receipts fails closed, as before.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Limits = require(ReplicatedStorage.Shared.Constants.Limits)
local Logger = require(script.Parent.Parent.Logging.Logger)
local Profile = require(ReplicatedStorage.Shared.Types.Profile)
local ProfileStore = require(script.Parent.ProfileStore)
local Telemetry = require(script.Parent.Parent.Logging.Telemetry)

type PlayerProfile = Profile.PlayerProfile

export type Level = "ok" | "warn" | "critical"

export type Gauge = { count: number, max: number, fraction: number, level: Level }

export type Report = { permanent: Gauge, seasonal: Gauge, pending: Gauge, archives: number }

export type ArchivedSet = { [string]: boolean }

export type Deps = {
	logger: Logger.Logger,
	telemetry: Telemetry.Telemetry,
	profiles: ProfileStore.Store,
	archiveStore: ProfileStore.RawStore,
}

local P = Limits.PROFILE

local ReceiptCapacity = {}

ReceiptCapacity.WARN_FRACTION = 0.8
ReceiptCapacity.CRITICAL_FRACTION = 0.95
-- Archive when permanent receipts reach this fraction of the budget.
ReceiptCapacity.ARCHIVE_FRACTION = 0.9
ReceiptCapacity.MAX_ARCHIVES = 16
ReceiptCapacity.ARCHIVE_STORE_NAME = "ProfileReceiptArchive"

local function countKeys(t: { [any]: any }): number
	local n = 0
	for _ in t do
		n += 1
	end
	return n
end

local function gauge(count: number, max: number): Gauge
	local fraction = count / max
	local level: Level = "ok"
	if fraction >= ReceiptCapacity.CRITICAL_FRACTION then
		level = "critical"
	elseif fraction >= ReceiptCapacity.WARN_FRACTION then
		level = "warn"
	end
	return { count = count, max = max, fraction = fraction, level = level }
end

function ReceiptCapacity.report(profile: PlayerProfile): Report
	return {
		permanent = gauge(countKeys(profile.receipts.permanent), P.MAX_PERMANENT_RECEIPTS),
		seasonal = gauge(countKeys(profile.receipts.seasonal), P.MAX_SEASONAL_RECEIPTS),
		pending = gauge(countKeys(profile.receipts.pending), P.MAX_PENDING_INTENTS),
		archives = #profile.receipts.archives,
	}
end

function ReceiptCapacity.needsArchive(profile: PlayerProfile): boolean
	return countKeys(profile.receipts.permanent)
		>= math.floor(P.MAX_PERMANENT_RECEIPTS * ReceiptCapacity.ARCHIVE_FRACTION)
end

-- Deterministic archive key for a profile's n-th archive.
function ReceiptCapacity.archiveKey(profileKey: string, index: number): string
	return string.format("%s:archive:%d", profileKey, index)
end

function ReceiptCapacity.new(deps: Deps)
	local monitor = {}

	-- Emits telemetry for gauges at warn or critical.
	function monitor.observe(profileKey: string, userId: number, profile: PlayerProfile): Report
		local report = ReceiptCapacity.report(profile)
		local gauges: { [string]: Gauge } =
			{ permanent = report.permanent, seasonal = report.seasonal, pending = report.pending }
		for name, g in gauges do
			if g.level ~= "ok" then
				deps.logger
					:with({ playerId = userId })
					:warn("persistence", "receipt_capacity_" .. g.level, {
						key = profileKey,
						ledger = name,
						count = g.count,
						max = g.max,
					})
				deps.telemetry:track(
					"receipt_capacity",
					{ ledger = name, level = g.level, userId = userId }
				)
			end
		end
		return report
	end

	-- Loads every archive for a key into one set. Returns nil on a store
	-- failure, in which case the caller must not grant (it cannot prove a
	-- receipt is new).
	function monitor.loadArchived(profile: PlayerProfile): ArchivedSet?
		local set: ArchivedSet = {}
		for _, archiveKey in profile.receipts.archives do
			local okRead, record = pcall(function()
				return deps.archiveStore:GetAsync(archiveKey)
			end)
			if not okRead or type(record) ~= "table" or type(record.receipts) ~= "table" then
				deps.logger:error(
					"persistence",
					"receipt_archive_unreadable",
					{ archiveKey = archiveKey }
				)
				return nil
			end
			for id in record.receipts do
				set[id] = true
			end
		end
		return set
	end

	-- Moves the oldest half of the permanent receipts into a new archive
	-- record. Returns a mutation to enqueue (which removes them from the
	-- profile and appends the archive key) or nil with a reason. The archive
	-- record is written durably before this returns.
	function monitor.buildArchive(
		profileKey: string,
		profile: PlayerProfile
	): (ProfileStore.Mutation?, string?)
		if #profile.receipts.archives >= ReceiptCapacity.MAX_ARCHIVES then
			return nil, "archive limit reached"
		end
		local ids = {}
		for id in profile.receipts.permanent do
			table.insert(ids, id)
		end
		if #ids < 2 then
			return nil, "nothing to archive"
		end
		table.sort(ids)
		local moving: { [string]: boolean } = {}
		local movingList: { string } = {}
		for i = 1, math.floor(#ids / 2) do
			moving[ids[i]] = true
			table.insert(movingList, ids[i])
		end
		local index = #profile.receipts.archives + 1
		local archiveKey = ReceiptCapacity.archiveKey(profileKey, index)

		local outcome = deps.profiles:writeRecord(deps.archiveStore, archiveKey, function(old)
			if old ~= nil then
				-- An earlier attempt wrote it; keep the first copy.
				return nil
			end
			return { profileKey = profileKey, index = index, receipts = moving, count = #movingList }
		end)
		if outcome == "uncertain" then
			return nil, "archive write uncertain"
		end
		-- Confirm by reading before touching the profile.
		local okRead, record = pcall(function()
			return deps.archiveStore:GetAsync(archiveKey)
		end)
		if not okRead or type(record) ~= "table" or record.count ~= #movingList then
			return nil, "archive not confirmed"
		end
		for _, id in movingList do
			if record.receipts[id] ~= true then
				return nil, "archive incomplete"
			end
		end

		deps.logger:info(
			"persistence",
			"receipts_archived",
			{ key = profileKey, archiveKey = archiveKey, count = #movingList }
		)
		deps.telemetry:track("receipts_archived", { count = #movingList })

		return {
			id = "archive:" .. archiveKey,
			irreversible = true,
			apply = function(stored: PlayerProfile): PlayerProfile?
				if table.find(stored.receipts.archives, archiveKey) ~= nil then
					return nil
				end
				local next = table.clone(stored)
				next.receipts = table.clone(stored.receipts)
				next.receipts.permanent = table.clone(stored.receipts.permanent)
				next.receipts.archives = table.clone(stored.receipts.archives)
				for _, id in movingList do
					next.receipts.permanent[id] = nil
				end
				table.insert(next.receipts.archives, archiveKey)
				return next
			end,
			isApplied = function(stored: PlayerProfile): boolean
				return table.find(stored.receipts.archives, archiveKey) ~= nil
			end,
		},
			nil
	end

	return table.freeze(monitor)
end

export type Monitor = typeof(ReceiptCapacity.new({} :: any))

return table.freeze(ReceiptCapacity)
