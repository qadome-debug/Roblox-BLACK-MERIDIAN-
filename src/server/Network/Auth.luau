--!strict
-- Authorization contexts (BM-014).
--
-- An AuthContext is what adapters and services receive instead of a
-- Player and a raw request. Its identity fields come from the Player
-- object the engine delivered and from the server-owned session; nothing
-- in it can be influenced by payload contents. Ownership and permission
-- checks are expressed as helpers that return a rejection status, so every
-- adapter denies the same way.

local Logger = require(script.Parent.Parent.Logging.Logger)
local Protocol = require(game:GetService("ReplicatedStorage").Shared.Contracts.Protocol)
local Session = require(script.Parent.Session)

export type Context = {
	userId: number,
	playerName: string,
	session: Session.Session,
	action: string,
	requestId: string,
	correlationId: string,
	logger: Logger.Logger,
}

local Auth = {}

function Auth.contextFor(
	player: Session.PlayerLike,
	session: Session.Session,
	action: string,
	requestId: string,
	correlationId: string,
	logger: Logger.Logger
): Context
	return table.freeze({
		userId = player.UserId,
		playerName = player.Name,
		session = session,
		action = action,
		requestId = requestId,
		correlationId = correlationId,
		logger = logger:with({ correlationId = correlationId, playerId = player.UserId }),
	})
end

-- The player must be the owner of the thing being acted on.
function Auth.requireOwner(ctx: Context, ownerUserId: number?): Protocol.Status?
	if ownerUserId == nil or ownerUserId ~= ctx.userId then
		ctx.logger:warn(
			"security",
			"ownership_denied",
			{ action = ctx.action, owner = ownerUserId or -1 }
		)
		return "UNAUTHORIZED"
	end
	return nil
end

-- The session must carry a service-granted permission flag.
function Auth.requirePermission(ctx: Context, permission: string): Protocol.Status?
	if ctx.session.permissions[permission] ~= true then
		ctx.logger:warn(
			"security",
			"permission_denied",
			{ action = ctx.action, permission = permission }
		)
		return "UNAUTHORIZED"
	end
	return nil
end

-- The player must be a member of a roster (party, run) the service owns.
function Auth.requireMember(ctx: Context, members: { number }): Protocol.Status?
	if table.find(members, ctx.userId) == nil then
		ctx.logger:warn("security", "membership_denied", { action = ctx.action })
		return "UNAUTHORIZED"
	end
	return nil
end

return table.freeze(Auth)
