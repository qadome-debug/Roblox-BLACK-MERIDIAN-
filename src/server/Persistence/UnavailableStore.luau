--!strict
-- A DataStore stand-in for when the real one cannot be opened (an
-- unpublished Studio place, or API access disabled). Every operation
-- fails with a clear error, so the loader reports "failed" and players stay
-- in the non-mutating state while the rest of the server (networking,
-- sessions, presentation) keeps working. Nothing is ever fabricated or
-- cached as if it were saved. Production refuses to start without real
-- stores; this exists for development only.

export type Store = {
	name: string,
	GetAsync: (self: Store, key: string) -> any,
	UpdateAsync: (self: Store, key: string, transform: (old: any) -> any) -> any,
}

local UnavailableStore = {}

function UnavailableStore.new(name: string, reason: string): Store
	local store = {} :: Store
	store.name = name
	local message = string.format("DataStore %q unavailable: %s", name, reason)
	function store:GetAsync(_key: string): any
		error(message, 2)
	end
	function store:UpdateAsync(_key: string, _transform: (old: any) -> any): any
		error(message, 2)
	end
	return table.freeze(store)
end

return table.freeze(UnavailableStore)
