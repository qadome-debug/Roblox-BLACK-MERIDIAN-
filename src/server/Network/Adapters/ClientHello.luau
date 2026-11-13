--!strict
-- ClientHello adapter (BM-017). Completes the handshake: the validated
-- protocol version is checked by the session service, which rotates the
-- epoch. The result carries the new epoch and the server's wall time so
-- the client can display server-relative timers (never to assert anything).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Auth = require(script.Parent.Parent.Auth)
local Clock = require(ReplicatedStorage.Shared.Sim.Clock)
local Dispatcher = require(script.Parent.Parent.Dispatcher)
local Envelope = require(script.Parent.Parent.Envelope)
local Payloads = require(ReplicatedStorage.Shared.Contracts.Payloads)
local Protocol = require(ReplicatedStorage.Shared.Contracts.Protocol)
local Session = require(script.Parent.Parent.Session)

export type Deps = { sessions: Session.Service, clock: Clock.Clock }

local ClientHello = {}

function ClientHello.new(deps: Deps): Dispatcher.Adapter
	return {
		action = "ClientHello",
		requiresProfile = false,
		requiresReady = false,
		handle = function(
			ctx: Auth.Context,
			payload: Payloads.ClientHelloPayload
		): Protocol.ActionResult
			local epoch, status, reason =
				deps.sessions:helloSession(ctx.session, payload.protocolVersion)
			if epoch == nil then
				return Envelope.reject(ctx.requestId, ctx.action, status :: Protocol.Status, reason)
			end
			local data: Payloads.ClientHelloResultData =
				{ sessionEpoch = epoch, serverTime = deps.clock:wallTime() }
			return Envelope.ok(ctx.requestId, ctx.action, nil, data)
		end,
	}
end

return table.freeze(ClientHello)
