--!strict
-- ProfileService: per-player persistence lifecycle (BM-050 wiring of
-- BM-021..049).
--
-- Owns the DataStores, the lease manager, the write path and the reward
-- facade, and runs the player lifecycle:
--   join      load (lease, migrate, validate) -> ready | readOnly | failed;
--             on ready: track the save queue, recover pending grants,
--             run capacity maintenance, and tell the session the profile
--             is loaded so gameplay actions may proceed
--   tick      renew leases, flush queues, reconcile rewards
--   leave     flush, release the lease, forget the player
--   shutdown  flush everything and release every lease (BindToClose)
--
-- A player whose load is not "ready" stays in a non-mutating state: the
-- session never reports profileLoaded, so the dispatcher answers
-- NOT_READY to gameplay actions. Nothing is ever fabricated.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Clock = require(ReplicatedStorage.Shared.Sim.Clock)
local Config = require(script.Parent.Parent.Config)
local Lease = require(script.Parent.Parent.Persistence.Lease)
local Logger = require(script.Parent.Parent.Logging.Logger)
local Migrations = require(script.Parent.Parent.Persistence.Migrations)
local Profile = require(ReplicatedStorage.Shared.Types.Profile)
local ProfileLoader = require(script.Parent.Parent.Persistence.ProfileLoader)
local ProfileStore = require(script.Parent.Parent.Persistence.ProfileStore)
local ReceiptCapacity = require(script.Parent.Parent.Persistence.ReceiptCapacity)
local Receipts = require(script.Parent.Parent.Persistence.Receipts)
local RewardCatalog = require(script.Parent.Parent.Content.RewardCatalog)
local RewardService = require(script.Parent.Parent.Services.RewardService)
local Rng = require(ReplicatedStorage.Shared.Sim.Rng)
local SaveQueue = require(script.Parent.Parent.Persistence.SaveQueue)
local Telemetry = require(script.Parent.Parent.Logging.Telemetry)

-- The part of Player this service relies on; tests pass plain tables.
export type PlayerLike = { UserId: number, Name: string }

export type Entry = {
	target: RewardService.Target,
	state: ProfileLoader.State,
	reason: ProfileLoader.Reason,
	profile: Profile.PlayerProfile?,
	handle: Lease.Handle?,
}

-- DataStore handles, created by Bootstrap (the one place allowed to call
-- GetDataStore) or by tests from the fake service.
export type Stores = {
	profiles: ProfileStore.RawStore,
	runs: ProfileStore.RawStore,
	archives: ProfileStore.RawStore,
}

export type Deps = {
	config: Config.Config,
	clock: Clock.Clock,
	rng: Rng.Rng,
	logger: Logger.Logger,
	telemetry: Telemetry.Telemetry,
	-- Tells the networking layer whether gameplay may proceed for a player.
	markProfileLoaded: (player: PlayerLike, loaded: boolean) -> (),
	stores: Stores,
	jobId: string,
	catalog: RewardCatalog.Catalog?,
	seasons: Receipts.SeasonPolicy?,
	-- Injected so tests advance the manual clock; Bootstrap passes task.wait.
	wait: (seconds: number) -> (),
}

export type Service = {
	rewards: RewardService.Service,
	onPlayerAdded: (self: Service, player: PlayerLike) -> Entry,
	onPlayerRemoving: (self: Service, player: PlayerLike) -> (),
	get: (self: Service, player: PlayerLike) -> Entry?,
	-- Periodic maintenance; call about once a second.
	tick: (self: Service) -> (),
	shutdown: (self: Service) -> (),
	keyFor: (self: Service, userId: number) -> string,
}

local ProfileService = {}

ProfileService.STORE_NAME = "BMProfiles"
ProfileService.RECONCILE_INTERVAL_SECONDS = 30

function ProfileService.new(deps: Deps): Service
	local profileStore = deps.stores.profiles
	local runStore = deps.stores.runs
	local archiveStore = deps.stores.archives

	local leases = Lease.new({
		clock = deps.clock,
		rng = deps.rng:fork("leases"),
		logger = deps.logger,
		store = profileStore,
		jobId = deps.jobId,
	})
	local profiles = ProfileStore.new({
		store = profileStore,
		logger = deps.logger,
		now = function()
			return deps.clock:wallTime()
		end,
	})
	local queue = SaveQueue.new({
		clock = deps.clock,
		rng = deps.rng:fork("queue"),
		logger = deps.logger,
		leases = leases,
		profiles = profiles,
	})
	local loader = ProfileLoader.new({
		clock = deps.clock,
		logger = deps.logger,
		leases = leases,
		store = profileStore,
		migrator = Migrations.production(),
		wait = deps.wait,
		readOnly = deps.config.readOnly,
	})
	local capacity = ReceiptCapacity.new({
		logger = deps.logger,
		telemetry = deps.telemetry,
		profiles = profiles,
		archiveStore = archiveStore,
	})
	local rewards = RewardService.new({
		clock = deps.clock,
		logger = deps.logger,
		telemetry = deps.telemetry,
		catalog = deps.catalog or RewardCatalog.production(),
		queue = queue,
		profiles = profiles,
		capacity = capacity,
		runStore = runStore,
		seasons = deps.seasons or { currentSeason = 1, retainedSeasons = 1 },
	})

	local entries: { [PlayerLike]: Entry } = {}
	local lastReconcile = deps.clock:now()

	local service = {} :: Service
	service.rewards = rewards

	function service:keyFor(userId: number): string
		return "p:" .. userId
	end

	function service:onPlayerAdded(player: PlayerLike): Entry
		local existing = entries[player]
		if existing ~= nil then
			return existing
		end
		local target: RewardService.Target =
			{ userId = player.UserId, key = service:keyFor(player.UserId) }
		local logger = deps.logger:with({ playerId = player.UserId })
		local loaded = loader:load(target.key)
		local entry: Entry = {
			target = target,
			state = loaded.state,
			reason = loaded.reason,
			profile = loaded.profile,
			handle = loaded.handle,
		}
		entries[player] = entry

		if loaded.state == "ready" then
			queue:track(target.key, loaded.handle :: Lease.Handle)
			local recovered =
				rewards:recoverPending(target, loaded.profile :: Profile.PlayerProfile)
			rewards:maintain(target, loaded.profile :: Profile.PlayerProfile)
			deps.markProfileLoaded(player, true)
			logger:info(
				"persistence",
				"player_profile_ready",
				{ recovered = recovered, attempts = loaded.attempts }
			)
			deps.telemetry:track(
				"profile_ready",
				{ attempts = loaded.attempts, recovered = recovered }
			)
		else
			-- Non-mutating: the session stays not-profile-loaded.
			logger:warn("persistence", "player_profile_" .. string.lower(loaded.state), {
				reason = loaded.reason,
				detail = loaded.detail or "",
				attempts = loaded.attempts,
			})
			deps.telemetry:track(
				"profile_" .. string.lower(loaded.state),
				{ reason = loaded.reason }
			)
		end
		return entry
	end

	function service:onPlayerRemoving(player: PlayerLike)
		local entry = entries[player]
		if entry == nil then
			return
		end
		entries[player] = nil
		deps.markProfileLoaded(player, false)
		if entry.handle ~= nil then
			queue:flush(entry.target.key)
			local left = queue:pendingCount(entry.target.key)
			if left > 0 then
				deps.logger
					:with({ playerId = player.UserId })
					:error("persistence", "player_leave_with_pending", { pending = left })
			end
			queue:untrack(entry.target.key)
			leases:release(entry.handle)
		end
	end

	function service:get(player: PlayerLike): Entry?
		return entries[player]
	end

	function service:tick()
		leases:tick()
		queue:flushAll()
		if deps.clock:now() - lastReconcile >= ProfileService.RECONCILE_INTERVAL_SECONDS then
			lastReconcile = deps.clock:now()
			for _, entry in entries do
				if entry.state == "ready" then
					rewards:reconcile(entry.target)
				end
			end
		end
	end

	function service:shutdown()
		local players = {}
		for player in entries do
			table.insert(players, player)
		end
		table.sort(players, function(a, b)
			return a.UserId < b.UserId
		end)
		for _, player in players do
			service:onPlayerRemoving(player)
		end
		deps.logger:info("lifecycle", "profile_service_shutdown", { players = #players })
	end

	return table.freeze(service)
end

return table.freeze(ProfileService)
