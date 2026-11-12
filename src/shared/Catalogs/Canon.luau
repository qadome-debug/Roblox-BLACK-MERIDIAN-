--!strict
-- The built, frozen registry over Content.luau. Require this to look up or
-- validate canonical IDs; never require Content.luau directly from gameplay
-- code, because the raw data has not been checked.

local Content = require(script.Parent.Content)
local ContentRegistry = require(script.Parent.ContentRegistry)

return ContentRegistry.build(Content)
