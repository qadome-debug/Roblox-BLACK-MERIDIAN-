--!strict
-- Client network controller.
--
-- The client's only way to talk to the server: it waits for the session
-- epoch the server pushes on join, performs the ClientHello handshake, and
-- then sends ActionRequests with a fresh request ID and a monotonic
-- sequence number, routing each ActionResult back to its caller. It never
-- decides anything; every answer comes from the server.

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Protocol = require(ReplicatedStorage.Shared.Contracts.Protocol)

export type ResultHandler = (result: Protocol.ActionResult) -> ()

export type Controller = {
	-- Resolves once the handshake completed. Safe to call many times.
	whenReady: (self: Controller, callback: () -> ()) -> (),
	isReady: (self: Controller) -> boolean,
	-- Sends an action; the handler receives the server's result.
	send: (
		self: Controller,
		action: string,
		payload: { [string]: unknown }?,
		onResult: ResultHandler?
	) -> string,
}

local Net = {}

function Net.new(): Controller
	local folder = ReplicatedStorage:WaitForChild("BlackMeridian")
	local actionRequest = folder:WaitForChild(Protocol.REMOTES.ACTION_REQUEST) :: RemoteEvent
	local actionResult = folder:WaitForChild(Protocol.REMOTES.ACTION_RESULT) :: RemoteEvent
	local stateDelta = folder:WaitForChild(Protocol.REMOTES.STATE_DELTA) :: RemoteEvent

	local epoch: string? = nil
	local seq = 0
	local ready = false
	local readyCallbacks: { () -> () } = {}
	local pending: { [string]: ResultHandler } = {}

	local controller = {} :: Controller

	local function sendRaw(
		action: string,
		payload: { [string]: unknown }?,
		onResult: ResultHandler?
	): string
		if epoch == nil then
			error("Net: no session epoch yet", 2)
		end
		seq += 1
		local requestId = HttpService:GenerateGUID(false)
		if onResult ~= nil then
			pending[requestId] = onResult
		end
		local request: Protocol.ActionRequest = {
			v = Protocol.VERSION,
			requestId = requestId,
			sessionEpoch = epoch :: string,
			seq = seq,
			action = action,
			payload = payload,
		}
		actionRequest:FireServer(request)
		return requestId
	end

	local function hello()
		sendRaw("ClientHello", { protocolVersion = Protocol.VERSION }, function(result)
			if result.status ~= "OK" or result.data == nil then
				warn(
					"[BlackMeridian] Handshake failed: "
						.. tostring(result.status)
						.. " "
						.. tostring(result.message)
				)
				return
			end
			epoch = (result.data :: any).sessionEpoch
			ready = true
			print("[BlackMeridian] Client session ready")
			for _, callback in readyCallbacks do
				task.spawn(callback)
			end
			readyCallbacks = {}
		end)
	end

	actionResult.OnClientEvent:Connect(function(result: Protocol.ActionResult)
		if type(result) ~= "table" or type(result.requestId) ~= "string" then
			return
		end
		local handler = pending[result.requestId]
		if handler ~= nil then
			pending[result.requestId] = nil
			handler(result)
		end
	end)

	stateDelta.OnClientEvent:Connect(function(delta: { [string]: unknown })
		if
			type(delta) == "table"
			and delta.kind == "session"
			and type(delta.sessionEpoch) == "string"
		then
			epoch = delta.sessionEpoch :: string
			if not ready then
				hello()
			end
		end
	end)

	function controller:whenReady(callback: () -> ())
		if ready then
			task.spawn(callback)
		else
			table.insert(readyCallbacks, callback)
		end
	end

	function controller:isReady(): boolean
		return ready
	end

	function controller:send(
		action: string,
		payload: { [string]: unknown }?,
		onResult: ResultHandler?
	): string
		if not ready then
			error("Net: send called before the session is ready", 2)
		end
		return sendRaw(action, payload, onResult)
	end

	return table.freeze(controller)
end

return table.freeze(Net)
