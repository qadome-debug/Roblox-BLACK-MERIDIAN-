--!strict
-- Request dispatcher (BM-018).
--
-- The single ingress for every client action. `handle` runs the plan's
-- validation sequence (3.2) in order and stops at the first failure:
--
--   1 envelope      Envelope.parse
--   2 session       Session: exists, epoch current, ready, profile loaded
--   3 replay        Replay: duplicate -> cached result; conflict/stale -> REPLAY
--   4 rate limit    RateLimiter: class and envelope buckets
--   5 payload       the action's registered validator
--   6 authorization Auth context built from Player + session (adapters
--                   apply the ownership checks that need world state)
--   7-8 world/mutate the adapter
--   9 response      typed result; rejections via Rejections
--
-- Default deny: an action with no registered adapter or validator is
-- "unavailable" and answered exactly like an unknown action. Adapters are
-- registered once by Bootstrap and cannot be replaced at runtime.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Actions = require(ReplicatedStorage.Shared.Contracts.Actions)
local Auth = require(script.Parent.Auth)
local Clock = require(ReplicatedStorage.Shared.Sim.Clock)
local Envelope = require(script.Parent.Envelope)
local Logger = require(script.Parent.Parent.Logging.Logger)
local Protocol = require(ReplicatedStorage.Shared.Contracts.Protocol)
local RateLimiter = require(script.Parent.RateLimiter)
local Rejections = require(script.Parent.Rejections)
local Replay = require(script.Parent.Replay)
local Rng = require(ReplicatedStorage.Shared.Sim.Rng)
local Session = require(script.Parent.Session)
local Telemetry = require(script.Parent.Parent.Logging.Telemetry)
local Validators = require(script.Parent.Validators)

export type Adapter = {
	action: Actions.ActionName,
	-- Runs the world-state checks and the mutation for a validated payload.
	-- Returns the result to send. Must not yield across a DataStore call
	-- without going through the owning service.
	handle: (ctx: Auth.Context, payload: any) -> Protocol.ActionResult,
	-- False only for the handshake; everything else needs a loaded profile.
	requiresProfile: boolean,
	-- False only for the handshake; everything else needs a ready session.
	requiresReady: boolean,
}

export type Deps = {
	clock: Clock.Clock,
	rng: Rng.Rng,
	logger: Logger.Logger,
	telemetry: Telemetry.Telemetry,
	sessions: Session.Service,
	limiter: RateLimiter.Limiter,
}

export type Dispatcher = {
	register: (self: Dispatcher, adapter: Adapter) -> (),
	handle: (self: Dispatcher, player: Session.PlayerLike, raw: unknown) -> Protocol.ActionResult,
	registeredActions: (self: Dispatcher) -> { string },
	-- Connects the ingress remote and the result remote. Roblox only.
	attach: (self: Dispatcher, actionRequest: any, actionResult: any) -> (),
}

local Dispatcher = {}

-- Pulls a plausible request ID out of an unparsed envelope so the client
-- can correlate a BAD_ENVELOPE answer. Bounded; never trusted for more.
local function requestIdHint(raw: unknown): string?
	if type(raw) == "table" then
		local id = (raw :: { [any]: unknown }).requestId
		if type(id) == "string" and #id > 0 and #id <= 64 and string.match(id, "^[%w%-_]+$") then
			return id
		end
	end
	return nil
end

function Dispatcher.new(deps: Deps): Dispatcher
	local adapters: { [string]: Adapter } = {}
	local correlationRng = deps.rng:fork("correlation")
	local dispatcher = {} :: Dispatcher

	function dispatcher:register(adapter: Adapter)
		if Actions.resolve(adapter.action) == nil then
			error(
				"Dispatcher.register: " .. tostring(adapter.action) .. " is not a registered action",
				2
			)
		end
		if adapters[adapter.action] ~= nil then
			error("Dispatcher.register: adapter for " .. adapter.action .. " already registered", 2)
		end
		if Validators.forAction(adapter.action) == nil then
			error("Dispatcher.register: " .. adapter.action .. " has no payload validator", 2)
		end
		adapters[adapter.action] = adapter
	end

	function dispatcher:registeredActions(): { string }
		local names = {}
		for name in adapters do
			table.insert(names, name)
		end
		table.sort(names)
		return names
	end

	function dispatcher:handle(player: Session.PlayerLike, raw: unknown): Protocol.ActionResult
		local playerLogger = deps.logger:with({ playerId = player.UserId })
		local scoped: Rejections.Deps = { logger = playerLogger, telemetry = deps.telemetry }

		-- 1. Envelope.
		local request, status, reason = Envelope.parse(raw)
		if request == nil then
			return Rejections.build(
				scoped,
				requestIdHint(raw),
				nil,
				status :: Protocol.Status,
				reason
			)
		end
		-- See Envelope.parse: refinement widens singleton unions in this solver.
		local action: Actions.ActionName = request.action :: any

		-- 2. Session.
		local session = deps.sessions:get(player)
		if session == nil then
			return Rejections.build(scoped, request.requestId, action, "NOT_READY", "no session")
		end
		if not deps.sessions:checkEpoch(session, request.sessionEpoch) then
			return Rejections.build(
				scoped,
				request.requestId,
				action,
				"STALE_EPOCH",
				"epoch mismatch or expired"
			)
		end
		local adapter = adapters[action]
		local validator = Validators.forAction(action)
		if adapter == nil or validator == nil then
			-- Registered in the plan but not available on this server: the
			-- client learns nothing beyond "unknown".
			return Rejections.build(
				scoped,
				request.requestId,
				action,
				"UNKNOWN_ACTION",
				"no adapter registered"
			)
		end
		if adapter.requiresReady and not session.ready then
			return Rejections.build(
				scoped,
				request.requestId,
				action,
				"NOT_READY",
				"handshake not completed"
			)
		end
		if adapter.requiresProfile and not session.profileLoaded then
			return Rejections.build(
				scoped,
				request.requestId,
				action,
				"NOT_READY",
				"profile not loaded"
			)
		end

		-- 3. Replay.
		local now = deps.clock:now()
		local fingerprint = Replay.fingerprint(action, request.payload)
		local verdict, cached =
			Replay.check(session.replay, request.requestId, request.seq, fingerprint, now)
		if verdict == "duplicate" then
			playerLogger:debug(
				"network",
				"request_duplicate",
				{ action = action, requestId = request.requestId }
			)
			return cached :: Protocol.ActionResult
		elseif verdict ~= "accept" then
			return Rejections.build(
				scoped,
				request.requestId,
				action,
				"REPLAY",
				"replay verdict " .. verdict
			)
		end

		-- 4. Rate limit.
		local admitted, retryAfter = deps.limiter:tryConsume(player.UserId, request.rateClass)
		if not admitted then
			return Rejections.build(
				scoped,
				request.requestId,
				action,
				"RATE_LIMITED",
				string.format("class %s, retry in %.2fs", request.rateClass, retryAfter)
			)
		end

		-- 5. Payload.
		local payload, invalid = validator(request.payload)
		if payload == nil then
			return Rejections.build(scoped, request.requestId, action, "BAD_PAYLOAD", invalid)
		end

		-- 6. Authorization context.
		local correlationId = Logger.correlationId(correlationRng)
		local ctx =
			Auth.contextFor(player, session, action, request.requestId, correlationId, deps.logger)

		-- 7-8. World state and mutation, inside the replay reservation.
		Replay.begin(session.replay, request.requestId, request.seq, fingerprint, now)
		local ok, result = pcall(adapter.handle, ctx, payload)
		if not ok then
			Replay.abandon(session.replay, request.requestId)
			local failed: Rejections.Deps = { logger = ctx.logger, telemetry = deps.telemetry }
			return Rejections.build(failed, request.requestId, action, "INTERNAL", tostring(result))
		end
		local typed = result :: Protocol.ActionResult
		if typed.status ~= "OK" then
			-- The adapter decided the rejection; log and sanitize it the same
			-- way, then cache it so an exact retry gets the same answer.
			local scopedCtx: Rejections.Deps = { logger = ctx.logger, telemetry = deps.telemetry }
			typed =
				Rejections.build(scopedCtx, request.requestId, action, typed.status, typed.message)
		else
			ctx.logger:debug("gameplay", "request_ok", { action = action })
		end

		-- 9. Response.
		Replay.commit(session.replay, request.requestId, typed)
		return typed
	end

	function dispatcher:attach(actionRequest: any, actionResult: any)
		actionRequest.OnServerEvent:Connect(function(player: Session.PlayerLike, raw: unknown)
			local result = dispatcher:handle(player, raw)
			actionResult:FireClient(player, result)
		end)
	end

	return table.freeze(dispatcher)
end

return table.freeze(Dispatcher)
