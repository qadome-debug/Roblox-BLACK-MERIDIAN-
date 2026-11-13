--!strict
-- Rejection codes, client-safe messages and abuse telemetry (BM-019).
--
-- Every non-OK result the dispatcher sends passes through here, so:
--   * the client gets a fixed, generic message per status that reveals no
--     hidden progression, no validation detail and no anti-cheat threshold,
--   * the server log gets the real reason, under the right category,
--   * telemetry counts rejections by status and action for abuse review.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Envelope = require(script.Parent.Envelope)
local Logger = require(script.Parent.Parent.Logging.Logger)
local Protocol = require(ReplicatedStorage.Shared.Contracts.Protocol)
local Telemetry = require(script.Parent.Parent.Logging.Telemetry)

local MESSAGES: { [Protocol.Status]: string } = {
	OK = "",
	BAD_ENVELOPE = "The request could not be read.",
	UNKNOWN_ACTION = "That action is not available.",
	NOT_READY = "Not ready yet. Please wait a moment.",
	STALE_EPOCH = "Your session has changed. Please reconnect.",
	REPLAY = "That request was already handled.",
	RATE_LIMITED = "Too many requests. Please slow down.",
	BAD_PAYLOAD = "The request was not valid.",
	UNAUTHORIZED = "You can't do that.",
	STALE_STATE = "Something changed. Please try again.",
	REJECTED = "That isn't possible right now.",
	INTERNAL = "Something went wrong on our side. Please try again.",
}

-- Statuses that indicate a malformed, forged, replayed or flooding client.
-- These are logged as security events and counted for abuse review.
local ABUSE: { [Protocol.Status]: boolean } = {
	BAD_ENVELOPE = true,
	UNKNOWN_ACTION = true,
	STALE_EPOCH = true,
	REPLAY = true,
	RATE_LIMITED = true,
	BAD_PAYLOAD = true,
	UNAUTHORIZED = true,
}

local Rejections = {}

Rejections.MESSAGES = table.freeze(MESSAGES)

function Rejections.isAbuse(status: Protocol.Status): boolean
	return ABUSE[status] == true
end

function Rejections.message(status: Protocol.Status): string
	return MESSAGES[status] or MESSAGES["INTERNAL" :: Protocol.Status]
end

export type Deps = { logger: Logger.Logger, telemetry: Telemetry.Telemetry }

-- Builds the client result for a rejection and records it server-side.
-- `reason` is the internal explanation; it goes to the log, never to the
-- client. `logger` should already carry the player and correlation IDs.
function Rejections.build(
	deps: Deps,
	requestId: string?,
	action: string?,
	status: Protocol.Status,
	reason: string?
): Protocol.ActionResult
	local fields = { action = action or "", reason = reason or "", status = status }
	if status == "INTERNAL" then
		deps.logger:error("network", "request_failed", fields)
	elseif ABUSE[status] then
		deps.logger:warn("security", "request_rejected", fields)
	else
		deps.logger:info("gameplay", "request_rejected", fields)
	end
	deps.telemetry:track("request_rejected", { action = action or "", status = status })
	return Envelope.reject(requestId, action, status, Rejections.message(status))
end

return table.freeze(Rejections)
