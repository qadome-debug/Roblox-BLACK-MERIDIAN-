--!strict
-- Operator recovery workflow (BM-049).
--
-- The only way support staff change player data. Every action:
--   * requires an operator context with a role that the action allows,
--   * is idempotent (repeating an action with the same case changes
--     nothing more),
--   * is logged as a security event with operator, role, case and target,
--   * goes through the same persistence layer as gameplay (lease, schema,
--     receipts). There is no "edit any field" action.
--
-- Actions:
--   inspect       read-only summary of a profile: validity, pending
--                 intents, receipt capacity
--   retryIntent   re-issue the grant for a pending intent (support)
--   clearIntent   drop an intent that will never be fulfilled (admin)
--   compensate    grant a catalog reward under a case ID (admin)
--   repair        apply Repair.attempt and write it back only when the
--                 result validates (admin)

local ServerScriptService = game:GetService("ServerScriptService")

local Lease = require(ServerScriptService.Server.Persistence.Lease)
local Logger = require(script.Parent.Parent.Logging.Logger)
local ProfileSchema = require(script.Parent.Parent.Persistence.ProfileSchema)
local ProfileStore = require(script.Parent.Parent.Persistence.ProfileStore)
local ReceiptCapacity = require(script.Parent.Parent.Persistence.ReceiptCapacity)
local Receipts = require(script.Parent.Parent.Persistence.Receipts)
local Repair = require(script.Parent.Parent.Persistence.Repair)
local RewardService = require(script.Parent.Parent.Services.RewardService)
local SaveQueue = require(script.Parent.Parent.Persistence.SaveQueue)
local Telemetry = require(script.Parent.Parent.Logging.Telemetry)

export type Role = "support" | "admin"

export type Operator = { operatorId: string, role: Role, caseId: string }

export type Outcome = "ok" | "noop" | "unauthorized" | "notFound" | "refused" | "failed"

export type Result = { outcome: Outcome, detail: string?, data: { [string]: any }? }

export type Deps = {
	logger: Logger.Logger,
	telemetry: Telemetry.Telemetry,
	rewards: RewardService.Service,
	profiles: ProfileStore.Store,
	queue: SaveQueue.Queue,
	leases: Lease.Manager,
}

export type Workflow = {
	inspect: (self: Workflow, operator: Operator, target: RewardService.Target) -> Result,
	retryIntent: (
		self: Workflow,
		operator: Operator,
		target: RewardService.Target,
		grantId: string
	) -> Result,
	clearIntent: (
		self: Workflow,
		operator: Operator,
		target: RewardService.Target,
		grantId: string,
		reason: string
	) -> Result,
	compensate: (
		self: Workflow,
		operator: Operator,
		target: RewardService.Target,
		rewardId: string,
		reason: string
	) -> Result,
	repair: (self: Workflow, operator: Operator, target: RewardService.Target) -> Result,
}

local RANK: { [Role]: number } = { support = 1, admin = 2 }

local REQUIRED: { [string]: Role } = {
	inspect = "support",
	retryIntent = "support",
	clearIntent = "admin",
	compensate = "admin",
	repair = "admin",
}

local Recovery = {}

function Recovery.new(deps: Deps): Workflow
	local workflow = {} :: Workflow

	local function audit(
		level: Logger.Level,
		action: string,
		operator: Operator,
		target: RewardService.Target,
		fields: Logger.RawFields?
	)
		local merged: Logger.RawFields = if fields ~= nil then table.clone(fields) else {}
		merged.action = action
		merged.operator = operator.operatorId
		merged.role = operator.role
		merged.caseId = operator.caseId
		merged.key = target.key
		deps.logger
			:with({ playerId = target.userId })
			:log(level, "security", "operator_action", merged)
		deps.telemetry:track("operator_action", { action = action, outcome = merged.outcome or "" })
	end

	local function authorize(
		action: string,
		operator: Operator,
		target: RewardService.Target
	): Result?
		local required = REQUIRED[action]
		local have = RANK[operator.role]
		if
			type(operator.operatorId) ~= "string"
			or #operator.operatorId == 0
			or #operator.caseId == 0
		then
			audit(
				"warn",
				action,
				operator,
				target,
				{ outcome = "unauthorized", detail = "missing operator or case" }
			)
			return { outcome = "unauthorized", detail = "operator and case are required" }
		end
		if have == nil or have < RANK[(required :: any) :: Role] then
			audit(
				"warn",
				action,
				operator,
				target,
				{ outcome = "unauthorized", detail = "role " .. tostring(operator.role) }
			)
			return { outcome = "unauthorized", detail = "requires " .. required }
		end
		return nil
	end

	-- Takes the lease briefly for an offline write. Returns the handle or
	-- nil with a reason; the caller releases it.
	local function borrow(target: RewardService.Target): (Lease.Handle?, string?)
		local outcome, handle, heldUntil = deps.leases:acquire(target.key)
		if outcome ~= "acquired" then
			return nil,
				string.format(
					"lease %s (held until %s): the player must be offline",
					outcome,
					tostring(heldUntil)
				)
		end
		deps.queue:track(target.key, handle :: Lease.Handle)
		return handle, nil
	end

	local function giveBack(target: RewardService.Target, handle: Lease.Handle)
		deps.queue:untrack(target.key)
		deps.leases:release(handle)
	end

	function workflow:inspect(operator: Operator, target: RewardService.Target): Result
		local denied = authorize("inspect", operator, target)
		if denied then
			return denied
		end
		local stored, err = deps.profiles:read(target.key)
		if err ~= nil then
			audit("warn", "inspect", operator, target, { outcome = "failed", detail = err })
			return { outcome = "failed", detail = err }
		end
		if stored == nil then
			audit("info", "inspect", operator, target, { outcome = "notFound" })
			return { outcome = "notFound" }
		end
		local problems = ProfileSchema.validate(stored)
		local pending = {}
		if
			type(stored) == "table"
			and type(stored.receipts) == "table"
			and type(stored.receipts.pending) == "table"
		then
			for grantId, intent in stored.receipts.pending do
				table.insert(pending, {
					grantId = grantId,
					rewardId = intent.rewardCatalogId,
					createdAt = intent.createdAt,
				})
			end
			table.sort(pending, function(a, b)
				return a.grantId < b.grantId
			end)
		end
		local report = if #problems == 0 then ReceiptCapacity.report(stored) else nil
		audit(
			"info",
			"inspect",
			operator,
			target,
			{ outcome = "ok", problems = #problems, pending = #pending }
		)
		return {
			outcome = "ok",
			data = {
				valid = #problems == 0,
				problems = problems,
				pending = pending,
				capacity = report,
				schemaVersion = stored.schemaVersion,
				revision = stored.revision,
			},
		}
	end

	function workflow:retryIntent(
		operator: Operator,
		target: RewardService.Target,
		grantId: string
	): Result
		local denied = authorize("retryIntent", operator, target)
		if denied then
			return denied
		end
		local handle, reason = borrow(target)
		if handle == nil then
			audit(
				"warn",
				"retryIntent",
				operator,
				target,
				{ outcome = "refused", detail = reason or "", grantId = grantId }
			)
			return { outcome = "refused", detail = reason }
		end
		local stored = deps.profiles:read(target.key)
		local result: Result
		if type(stored) ~= "table" or stored.receipts.pending[grantId] == nil then
			result = { outcome = "notFound", detail = "no pending intent " .. grantId }
		else
			local recovered = deps.rewards:recoverPending(target, stored)
			local after = deps.profiles:read(target.key)
			local fulfilled = type(after) == "table" and after.receipts.pending[grantId] == nil
			result = {
				outcome = if fulfilled then "ok" else "failed",
				detail = string.format(
					"%d grant(s) re-issued; %s",
					recovered,
					if fulfilled then "fulfilled" else "still pending"
				),
			}
		end
		giveBack(target, handle)
		audit(
			if result.outcome == "ok" then "info" else "warn",
			"retryIntent",
			operator,
			target,
			{ outcome = result.outcome, grantId = grantId, detail = result.detail or "" }
		)
		return result
	end

	function workflow:clearIntent(
		operator: Operator,
		target: RewardService.Target,
		grantId: string,
		reason: string
	): Result
		local denied = authorize("clearIntent", operator, target)
		if denied then
			return denied
		end
		if #reason == 0 then
			return { outcome = "refused", detail = "a reason is required" }
		end
		local handle, why = borrow(target)
		if handle == nil then
			audit(
				"warn",
				"clearIntent",
				operator,
				target,
				{ outcome = "refused", detail = why or "", grantId = grantId }
			)
			return { outcome = "refused", detail = why }
		end
		local stored = deps.profiles:read(target.key)
		local result: Result
		if type(stored) ~= "table" or stored.receipts.pending[grantId] == nil then
			result = { outcome = "noop", detail = "no pending intent " .. grantId }
		else
			deps.queue:enqueue(target.key, Receipts.clearIntent(grantId))
			local outcome, detail = deps.queue:flush(target.key)
			result =
				{ outcome = if outcome == "committed" then "ok" else "failed", detail = detail }
		end
		giveBack(target, handle)
		audit(
			"warn",
			"clearIntent",
			operator,
			target,
			{ outcome = result.outcome, grantId = grantId, reason = reason }
		)
		return result
	end

	function workflow:compensate(
		operator: Operator,
		target: RewardService.Target,
		rewardId: string,
		reason: string
	): Result
		local denied = authorize("compensate", operator, target)
		if denied then
			return denied
		end
		local handle, why = borrow(target)
		if handle == nil then
			audit(
				"warn",
				"compensate",
				operator,
				target,
				{ outcome = "refused", detail = why or "", rewardId = rewardId }
			)
			return { outcome = "refused", detail = why }
		end
		local grant = deps.rewards:compensate(
			target,
			{ operatorId = operator.operatorId, caseId = operator.caseId, reason = reason },
			rewardId
		)
		giveBack(target, handle)
		local outcome: Outcome = if grant.outcome == "granted"
			then "ok"
			elseif grant.outcome == "duplicate" then "noop"
			elseif grant.outcome == "refused" then "refused"
			else "failed"
		audit("warn", "compensate", operator, target, {
			outcome = outcome,
			rewardId = rewardId,
			receiptId = grant.receiptId or "",
			reason = reason,
		})
		return { outcome = outcome, detail = grant.reason, data = { receiptId = grant.receiptId } }
	end

	function workflow:repair(operator: Operator, target: RewardService.Target): Result
		local denied = authorize("repair", operator, target)
		if denied then
			return denied
		end
		local raw, err = deps.profiles:read(target.key)
		if err ~= nil or raw == nil then
			return {
				outcome = if raw == nil and err == nil then "notFound" else "failed",
				detail = err,
			}
		end
		if #ProfileSchema.validate(raw) == 0 then
			audit("info", "repair", operator, target, { outcome = "noop" })
			return { outcome = "noop", detail = "profile already valid" }
		end
		local report = Repair.attempt(raw)
		if not report.repaired then
			audit(
				"warn",
				"repair",
				operator,
				target,
				{ outcome = "refused", remaining = #report.remaining }
			)
			return {
				outcome = "refused",
				detail = table.concat(report.remaining, "; "),
				data = { changes = report.changes },
			}
		end
		local handle, why = borrow(target)
		if handle == nil then
			return { outcome = "refused", detail = why }
		end
		local repaired = report.profile :: any
		local write = deps.profiles:mutate(target.key, handle, {
			{
				id = "repair:" .. operator.caseId,
				apply = function(stored)
					-- Replace the whole record with the repaired copy, keeping
					-- the lease the store holds now.
					local next = table.clone(repaired)
					next.lease = stored.lease
					next.revision = stored.revision
					return next :: any
				end,
			},
		})
		giveBack(target, handle)
		local outcome: Outcome = if write.outcome == "committed" then "ok" else "failed"
		audit(
			"warn",
			"repair",
			operator,
			target,
			{ outcome = outcome, changes = #report.changes, detail = write.detail or "" }
		)
		return { outcome = outcome, detail = write.detail, data = { changes = report.changes } }
	end

	return table.freeze(workflow)
end

return table.freeze(Recovery)
