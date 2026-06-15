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


-- ~/.config/nvim/lua/autopack/init.lua   (Windows: ~/AppData/Local/nvim/lua/autopack/init.lua)
--
-- autopack: lazy-load optional ('opt') packages on first key/command use.
--
-- Register a plugin together with the keys and/or commands that should trigger
-- it. Until one of those fires, the plugin is NOT loaded. On first trigger,
-- autopack removes its stub mappings/commands, runs your optional pre-load
-- `init`, `packadd`s the real plugin, runs your optional post-load `config`,
-- and finally replays the exact key/command you used.
--
-- The plugin MUST live in a 'pack/*/opt/<name>/' directory (opt, not start).

local M = {}

-- Registry of { name → spec } for :Autopackupdate.
-- Populated when register() is called with an `opts.spec` field.
M._registry = {}

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------

-- Best-effort Lua module name from a packadd dir name (gitsigns.nvim -> gitsigns).
local function default_module(name)
	return (name:gsub("%.nvim$", ""):gsub("%.vim$", ""))
end

-- Expand <leader>/<localleader> the same way :map does. nvim_replace_termcodes
-- does NOT expand them, so replaying a raw "<leader>x" lhs would feed literal
-- text instead of the key the real mapping is registered under.
local function expand_leader(lhs)
	local leader = vim.g.mapleader
	if leader == nil then leader = "\\" end
	local localleader = vim.g.maplocalleader
	if localleader == nil then localleader = "\\" end
	return (lhs:gsub("<(%a+)>", function(word)
		local w = word:lower()
		if w == "leader" then return leader end
		if w == "localleader" then return localleader end
		-- returning nil keeps the original <...> for nvim_replace_termcodes
	end))
end

-- Feed keys through the typeahead buffer. `mode` follows nvim_feedkeys:
--   "m" = allow remapping (needed to trigger the plugin's real mapping)
--   "n" = no remapping    (used for replaying an Ex command line)
local function feed(keys, mode)
	vim.api.nvim_feedkeys(
		vim.api.nvim_replace_termcodes(keys, true, false, true),
		mode,
		false
	)
end

-- Normalize a `keys` entry into { lhs = <string>, mode = <string> }.
local function parse_key(k)
	if type(k) == "table" then
		return { lhs = k.lhs or k[1], mode = k.mode or "n" }
	end
	return { lhs = k, mode = "n" }
end

-- ---------------------------------------------------------------------------
-- loader (one-shot, shared by all of a plugin's stubs)
-- ---------------------------------------------------------------------------

local function make_loader(spec)
	local loaded = false

	-- Called with a `replay` callback that re-triggers the original key/command.
	local function load(replay)
		if loaded then
			return
		end
		loaded = true

		-- (1) Remove our stub mappings so they no longer intercept the key.
		for _, km in ipairs(spec._keymaps) do
			pcall(vim.keymap.del, km.mode, km.lhs)
		end

		-- (2) Remove our stub user-commands.
		for _, name in ipairs(spec._commands) do
			pcall(vim.api.nvim_del_user_command, name)
		end

		-- (3) Remove our BufRead autocmds (patterns trigger).
		for _, id in ipairs(spec._autocmds) do
			pcall(vim.api.nvim_del_autocmd, id)
		end

		-- (4) Optional pre-load hook: runs BEFORE packadd. This is where
		--     Vimscript plugins want their vim.g.* options (read at source time).
		if type(spec.init) == "function" then
			spec.init()
		end

		-- (5) Load the real plugin. Sources its plugin/ files; enough for an
		--     old Vimscript plugin to define its commands/maps. No require() here.
		vim.cmd("packadd " .. spec.name)

		-- (6) Optional post-load config:
		--       config = function -> called as-is (do your own require().setup{})
		--       config = table    -> require(module).setup(table)
		--       setup  = true     -> require(module).setup()
		--     `module` defaults to the plugin name minus a trailing .nvim/.vim.
		local c = spec.config
		if type(c) == "function" then
			c()
		elseif c ~= nil or spec.setup then
			local module = spec.module or default_module(spec.name)
			local ok, mod = pcall(require, module)
			if not ok then
				error(string.format(
					"autopack: require('%s') failed for plugin '%s'.\n"
						.. "If this is a Vimscript plugin it has no Lua module: drop "
						.. "`config`/`setup`/`module` and use `init` for vim.g.* settings.\n%s",
					module, spec.name, mod
				))
			end
			if type(mod) == "table" and type(mod.setup) == "function" then
				mod.setup(type(c) == "table" and c or nil)
			end
		end

		-- (7) Replay the trigger now that the real plugin is loaded.
		replay()
	end

	return load, function() return loaded end
end

-- ---------------------------------------------------------------------------
-- public API
-- ---------------------------------------------------------------------------

-- Register one plugin.
--   opts.name     (string, required)   dir under pack/*/opt/  = packadd target
--   opts.spec     (table,  opt)        vim.pack.add() spec, stored in _registry
--   opts.init     (function, opt)      runs BEFORE packadd (set vim.g.* here)
--   opts.config   (function|table,opt) runs AFTER  packadd (see make_loader)
--   opts.module   (string, opt)        Lua module for the table-config form
--   opts.setup    (boolean, opt)       force require(module).setup()
--   opts.keys     (list, opt)          "lhs" or { lhs=.., mode=.. } entries
--   opts.commands (list, opt)          command-name strings
--   opts.patterns (list, opt)          file glob patterns (BufRead trigger)
function M.register(opts)
	assert(type(opts) == "table" and type(opts.name) == "string",
		"autopack.register: `name` is required")

	if opts.spec then
		M._registry[opts.name] = opts.spec
	end

	opts._keymaps = {}
	opts._commands = {}
	opts._autocmds = {}

	local loader, is_loaded = make_loader(opts)

	-- Key stubs.
	for _, raw in ipairs(opts.keys or {}) do
		local k = parse_key(raw)
		table.insert(opts._keymaps, k)
		vim.keymap.set(k.mode, k.lhs, function()
			loader(function()
				local lhs = expand_leader(k.lhs)
				-- Defer the replay: feeding the key synchronously while we're
				-- still executing the stub mapping causes the re-sent key not to
				-- resolve to the freshly-loaded mapping. vim.schedule runs it on
				-- the next tick, after this mapping fully unwinds.
				vim.schedule(function()
					if vim.tbl_isempty(vim.fn.maparg(lhs, k.mode, false, true)) then
						vim.notify(
							("autopack: '%s' loaded but found no %s-mode mapping for %s; "
								.. "replaying anyway. If nothing happens, the plugin likely "
								.. "exposes a <Plug> mapping you must bind yourself.")
								:format(opts.name, k.mode, k.lhs),
							vim.log.levels.WARN
						)
					end
					feed(lhs, "m") -- "m" = remap, so the plugin's mapping fires
				end)
			end)
		end, { desc = "autopack stub -> " .. opts.name })
	end

	-- Command stubs.
	for _, cmd in ipairs(opts.commands or {}) do
		table.insert(opts._commands, cmd)
		vim.api.nvim_create_user_command(cmd, function(a)
			loader(function()
				-- Rebuild the exact command line: {mods} {range}{cmd}{bang} {args}
				local line = ""
				if a.range == 2 then
					line = a.line1 .. "," .. a.line2
				elseif a.range == 1 then
					line = tostring(a.line1)
				end
				if a.mods and a.mods ~= "" then
					line = a.mods .. " " .. line
				end
				line = line .. cmd
				if a.bang then
					line = line .. "!"
				end
				if a.args and a.args ~= "" then
					line = line .. " " .. a.args
				end
				feed(":" .. line .. "\r", "n")
			end)
		end, {
			nargs = "*",
			bang = true,
			range = true,
			desc = "autopack stub -> " .. opts.name,
		})
	end

	-- BufRead stubs: one-shot autocmds keyed on file glob patterns.
	-- During startup, defer loading to VimEnter (UI not ready yet).
	-- After startup, load synchronously on BufRead.
	local bufread_fired = false

	local function bufread_loader()
		loader(function() end)
	end

	for _, pattern in ipairs(opts.patterns or {}) do
		local id = vim.api.nvim_create_autocmd("BufRead", {
			pattern = pattern,
			once = true,
			callback = function()
				bufread_fired = true
				if vim.v.vim_did_enter == 0 then
					-- Still in startup: defer to VimEnter.
					vim.schedule(bufread_loader)
				else
					bufread_loader()
				end
			end,
			desc = "autopack stub BufRead -> " .. opts.name,
		})
		table.insert(opts._autocmds, id)
	end

	-- Fallback: if a matching buffer is already open at VimEnter, load now.
	local vimenter_id = vim.api.nvim_create_autocmd("VimEnter", {
		once = true,
		callback = function()
			if bufread_fired and not is_loaded() then
				bufread_loader()
			end
		end,
		desc = "autopack fallback VimEnter -> " .. opts.name,
	})
	table.insert(opts._autocmds, vimenter_id)

	return opts
end

-- Register many plugins at once.
function M.register_all(specs)
	for _, opts in ipairs(specs) do
		M.register(opts)
	end
end

-- ---------------------------------------------------------------------------
-- :Autopackupdate  –  install/update all (or named) registered packs
-- ---------------------------------------------------------------------------

-- Handler shared by M.update() and the :Autopackupdate command.
-- names: list of plugin-name strings (empty = all registered).
-- Uses vim.pack.add() which both installs new packs and updates existing ones.
local function update_handler(names)
	if vim.tbl_isempty(names) then
		if vim.tbl_isempty(M._registry) then
			vim.notify("Call register() first. Nothing to do.")
			return
		end
		for _, spec in pairs(M._registry) do
			vim.pack.add({ spec })
		end
	else
		local specs = {}
		for _, name in ipairs(names) do
			local spec = M._registry[name]
			if spec == nil then
				error("autopack: unknown plugin '" .. name .. "'")
			end
			table.insert(specs, spec)
		end
		for _, spec in ipairs(specs) do
			vim.pack.add({ spec })
		end
	end
end

--- Update one or more registered packs.
--- @param names string|string[]  plugin name or list of names, or empty for all.
function M.update(names)
	if type(names) == "string" then
		update_handler({ names })
	else
		update_handler(names or {})
	end
end

local function register_update_command()
	vim.api.nvim_create_user_command("Autopackupdate", function(a)
		update_handler(a.fargs)
	end, {
		nargs = "*",
		desc = "Install/update plugins registered with autopack",
	})
end

if vim.v.vim_did_enter == 1 then
	register_update_command()
else
	vim.api.nvim_create_autocmd("VimEnter", {
		once = true,
		callback = register_update_command,
	})
end

return M

