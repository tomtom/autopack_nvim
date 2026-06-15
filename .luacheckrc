return {
	-- Neovim provides vim at runtime; declare as read-only global.
	read_globals = { "vim" },

	-- Per-path overrides.
	files = {
		-- Suppress unused-argument warnings (212) in test mock stubs.
		-- Several mocks intentionally declare params they don't use,
		-- e.g. vim.schedule = function(fn) end (line 55).
		["tests/*.lua"] = { ignore = { "212" } },
	},
}
