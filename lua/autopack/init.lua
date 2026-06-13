-- require("autopack").register({
-- 	name = "gitsigns",                       -- (1) packadd + require target
-- 	config = {                               -- (2) passed to require("gitsigns").setup(config)
-- 		signcolumn = true,
-- 		numhl = false,
-- 	},
-- 	keys = {                                 -- (3) key combinations
-- 		"<leader>gs",
-- 		{ "<C-g>", mode = { "n", "i" } },
-- 	},
-- 	commands = { "Gitsigns" },               -- (4) commands
-- })
-- 
-- require("autoload").register_all({
-- 	{
-- 		name = "gitsigns",
-- 		config = { signcolumn = true },
-- 		keys = { "<leader>gs" },
-- 		commands = { "Gitsigns" },
-- 	},
-- 	{
-- 		name = "fugitive",
-- 		keys = { "<leader>gg" },
-- 		commands = { "Git", "Gdiffsplit" },
-- 	},
-- 	{
-- 		name = "telescope",
-- 		config = { defaults = { layout_strategy = "flex" } },
-- 		keys = { "<leader>ff", "<leader>fg" },
-- 		commands = { "Telescope" },
-- 	},
-- })

local M = {}

-- Builds the shared loader for one registration.
-- `spec` carries the plugin name, the config table, and the lists of
-- stub keymaps / commands so the loader can tear them down again.
local function make_loader(spec)
	local loaded = false

	-- `replay` re-triggers whatever invoked the stub (a key or a command).
	return function(replay)
		if not loaded then
			loaded = true

			-- (step 3a) Remove every stub keymap we created in step 2.
			for _, km in ipairs(spec._keymaps) do
				pcall(vim.keymap.del, km.mode, km.lhs)
			end

			-- (step 3a) Remove every stub user-command we created in step 2.
			for _, name in ipairs(spec._commands) do
				pcall(vim.api.nvim_del_user_command, name)
			end

			-- (step 3b) Load the real plugin from an optional package.
			vim.cmd("packadd " .. spec.name)

			-- (step 3c) Initialize via require(name).setup(config).
			-- Pass the config table when present; otherwise call setup()
			-- with no argument.
			local plugin = require(spec.name)
			if spec.config ~= nil then
				plugin.setup(spec.config)
			else
				plugin.setup()
			end
		end

		-- (step 3d) Invoke the exact shortcut/command that hit the stub.
		replay()
	end
end

-- Re-runs the original command line as faithfully as possible.
local function replay_command(cmd, a)
	local line = ""

	-- Preserve a range (e.g. `:'<,'>Foo` or `:10Foo`).
	if a.range == 2 then
		line = a.line1 .. "," .. a.line2
	elseif a.range == 1 then
		line = tostring(a.line1)
	end

	-- Preserve modifiers like `:vertical`, `:silent`, ... when available.
	if a.mods and a.mods ~= "" then
		line = (line == "" and "" or line) .. a.mods .. " "
	end

	line = line .. cmd .. (a.bang and "!" or "")

	-- Preserve the raw argument string (keeps quoting/spacing intact).
	if a.args and a.args ~= "" then
		line = line .. " " .. a.args
	end

	vim.cmd(line)
end

--- Register a lazily-loaded plugin.
--- @param opts table
---   opts.name      string            -- (1) plugin name (used by `packadd` and `require`)
---   opts.config    table|nil         -- (2) dict passed to require(name).setup(config)
---   opts.keys      table|nil         -- (3) list of key combinations
---   opts.commands  table|nil         -- (4) list of commands
---
--- `keys` entries may be a plain lhs string (normal mode) or a table:
---   { "<leader>gg", mode = "n" }  /  { "<C-x>", mode = { "n", "i" } }
function M.register(opts)
	opts = opts or {}
	assert(opts.name, "autopack: `name` (plugin name) is required")

	local spec = {
		name = opts.name,
		config = opts.config,
		_keymaps = {},
		_commands = {},
	}

	local load = make_loader(spec)

	-- (step 2) Map every key combination to the stub.
	for _, key in ipairs(opts.keys or {}) do
		local lhs, mode
		if type(key) == "table" then
			lhs = key[1] or key.lhs
			mode = key.mode or "n"
		else
			lhs, mode = key, "n"
		end

		-- Remember it so the loader can delete it later.
		table.insert(spec._keymaps, { mode = mode, lhs = lhs })

		vim.keymap.set(mode, lhs, function()
			load(function()
				-- Feed the *same* keys with remapping enabled ("m"),
				-- so the real plugin's freshly-installed mapping fires.
				local keys = vim.api.nvim_replace_termcodes(lhs, true, false, true)
				vim.api.nvim_feedkeys(keys, "m", false)
			end)
		end, { desc = "autopack stub → " .. opts.name })
	end

	-- (step 2) Map every command to the stub.
	for _, cmd in ipairs(opts.commands or {}) do
		table.insert(spec._commands, cmd)

		vim.api.nvim_create_user_command(cmd, function(a)
			load(function()
				-- The real command now exists; re-run the original invocation.
				replay_command(cmd, a)
			end)
		end, {
			nargs = "*",
			bang = true,
			range = true,
			desc = "autopack stub → " .. opts.name,
		})
	end
end

--- Register many plugins at once.
--- @param specs table  -- a list of opts tables (same shape as M.register)
function M.register_all(specs)
	for _, opts in ipairs(specs or {}) do
		M.register(opts)
	end
end

return M

