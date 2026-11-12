--!strict
-- Fixture: a deliberately failing test. The runner must exit non-zero.
return {
	{ name = "passes", run = function() end },
	{
		name = "fails on purpose",
		run = function()
			error("intentional failure")
		end,
	},
}
