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

-- Derive a plugin name from a vim.pack.add() spec src URL.
--   "https://github.com/user/gitsigns.nvim" -> "gitsigns.nvim"
--   "https://github.com/user/repo.git"       -> "repo"
--   "git@github.com:user/repo.git"           -> "repo"
local function derive_name(src)
	-- Strip query strings, fragments, and trailing slashes before pattern matching.
	src = src:gsub("[?#].*$", ""):gsub("/+$", "")
	-- SSH URLs: git@host:user/repo.git  -> user/repo.git
	-- Standard URLs: https://host/path   -> /path
	local path = src:match("@[^:]+:(.+)$") or src:match("/([^/]+)$") or src
	-- Get the last path component (for SSH paths like user/repo.git -> repo.git)
	local name = path:match("([^/]+)$") or path
	-- Strip trailing .git. Keep any .nvim/.vim/nvim-/vim- affix: vim.pack.add()
	-- installs under the literal repo name, so :packadd must match it exactly.
	return (name:gsub("%.git$", ""))
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

-- Print a trace line to :messages when the plugin's `debug` field is set.
local function trace(debug_enabled, label, msg)
	if debug_enabled then
		vim.notify(("autopack[%s]: %s"):format(label, msg), vim.log.levels.INFO)
	end
end

-- Maps a spec's mode-keyed fields to the nvim_set_keymap mode chars they
-- stub. `maps` implicitly covers normal, insert, and visual-only modes;
-- the per-mode fields (nmaps, imaps, ...) restrict a mapping to one mode.
local MAP_FIELDS = {
	{ field = "maps", modes = { "n", "i", "x" } },
	{ field = "nmaps", modes = { "n" } },
	{ field = "imaps", modes = { "i" } },
	{ field = "xmaps", modes = { "x" } },
	{ field = "vmaps", modes = { "v" } },
	{ field = "smaps", modes = { "s" } },
	{ field = "omaps", modes = { "o" } },
	{ field = "cmaps", modes = { "c" } },
}

-- ---------------------------------------------------------------------------
-- loaders
--   pack loader:   one-shot :packadd, shared by every module of a plugin.
--   module loader: one-shot setup, one per module (or one for the
--                   whole plugin when it has no `submodules` table).
-- ---------------------------------------------------------------------------

-- :packadd + `init` hook, run at most once no matter which module triggers it.
local function make_pack_loader(name, init)
	local loaded = false
	return function()
		if loaded then
			return
		end
		loaded = true

		-- Optional pre-load hook: runs BEFORE packadd. This is where
		-- Vimscript plugins want their vim.g.* options (read at source time).
		if type(init) == "function" then
			init()
		end

		-- Sources the plugin's plugin/ files; enough for an old Vimscript
		-- plugin to define its commands/maps. No require() here.
		vim.cmd("packadd " .. name)
	end
end

-- Resolve the Lua module name to require() for a given module entry.
-- `module_key` is the key the entry was registered under in `submodules`
-- (already the require() path); falls back to `mod.module` or a name
-- derived from the plugin name for the single-module (no `submodules`) case.
local function resolve_module(name, module_key, mod)
	if module_key then
		return module_key
	end
	return mod.module or default_module(name)
end

local function make_module_loader(name, module_key, mod, ensure_pack_loaded, debug_enabled)
	local loaded = false
	local label = module_key or name

	-- Called with a `replay` callback that re-triggers the original key/command.
	local function load(replay)
		if loaded then
			return
		end
		loaded = true

		-- (1) Remove our stub mappings so they no longer intercept the key.
		for _, km in ipairs(mod._keymaps) do
			pcall(vim.keymap.del, km.mode, km.lhs)
		end

		-- (2) Remove our stub user-commands.
		for _, cmd_name in ipairs(mod._commands) do
			pcall(vim.api.nvim_del_user_command, cmd_name)
		end

		-- (3) Remove our BufRead autocmds (patterns trigger).
		for _, id in ipairs(mod._autocmds) do
			pcall(vim.api.nvim_del_autocmd, id)
		end

		-- (4)+(5) Ensure the plugin itself is installed (shared across modules).
		trace(debug_enabled, label, "ensuring plugin '" .. name .. "' is loaded (:packadd)")
		ensure_pack_loaded()

		-- (6) Optional post-load setup:
		--       setup = function -> called with the required module (or nil if
		--                           require() failed, e.g. no Lua module exists)
		--       setup = table    -> require(module).setup(table)
		--       setup = true     -> require(module).setup()
		local s = mod.setup
		if type(s) == "function" then
			trace(debug_enabled, label, "running function setup")
			local module = resolve_module(name, module_key, mod)
			local ok, m = pcall(require, module)
			s(ok and m or nil)
		elseif s == true or type(s) == "table" then
			trace(debug_enabled, label, "running setup()")
			local module = resolve_module(name, module_key, mod)
			local ok, m = pcall(require, module)
			if not ok then
				error(string.format(
					"autopack: require('%s') failed for plugin '%s'.\n"
						.. "If this is a Vimscript plugin it has no Lua module: drop "
						.. "`setup`/`module` and use `init` for vim.g.* settings.\n%s",
					module, name, m
				))
			end
			if type(m) == "table" and type(m.setup) == "function" then
				m.setup(type(s) == "table" and s or nil)
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

M.derive_name = derive_name

-- Internal: register a single plugin. Called by M.setup() for each spec.
-- Normalize opts: accept string URL as shorthand for { spec = { src = url } }.
local function normalize_opts(opts)
	if type(opts) == "string" then
		opts = { spec = { src = opts } }
	end
	assert(type(opts) == "table", "autopack.setup: opts must be a table or URL string")
	-- Normalize spec: string -> { src = string }
	if type(opts.spec) == "string" then
		opts.spec = { src = opts.spec }
	end
	return opts
end

local function register(opts)
	opts = normalize_opts(opts)

	if not opts.name and opts.spec and opts.spec.src then
		opts.name = derive_name(opts.spec.src)
	end

	assert(type(opts.name) == "string",
		"autopack.setup: `name` is required (or provide `spec.src` to derive it)")

	if opts.spec then
		-- `dependencies` is declared as a sibling of `spec` in a plugin's
		-- top-level opts (see autopack-spec-dependencies), but resolve_deps()
		-- reads it off the registry entry, so it must travel with the spec.
		opts.spec.dependencies = opts.dependencies
		M._registry[opts.name] = opts.spec
	end

	-- Shared by every module of this plugin: :packadd only runs once, no
	-- matter which module's trigger fires first.
	local ensure_pack_loaded = make_pack_loader(opts.name, opts.init)

	-- Wire one module's keys/commands/patterns to its own one-shot loader.
	-- `module_key` is nil for the single-module (no `submodules` table) case.
	local function wire_module(module_key, mod)
		mod._keymaps = {}
		mod._commands = {}
		mod._autocmds = {}

		local loader, is_loaded = make_module_loader(opts.name, module_key, mod, ensure_pack_loaded, opts.debug)
		local label = module_key or opts.name

		-- Key stubs.
		for _, map_field in ipairs(MAP_FIELDS) do
			for _, raw_lhs in ipairs(mod[map_field.field] or {}) do
				local modes = map_field.modes
				table.insert(mod._keymaps, { lhs = raw_lhs, mode = modes })
				vim.keymap.set(modes, raw_lhs, function()
					trace(opts.debug, label, "key '" .. raw_lhs .. "' triggered load")
					loader(function()
						local lhs = expand_leader(raw_lhs)
						-- Defer the replay: feeding the key synchronously while we're
						-- still executing the stub mapping causes the re-sent key not to
						-- resolve to the freshly-loaded mapping. vim.schedule runs it on
						-- the next tick, after this mapping fully unwinds.
						vim.schedule(function()
							local has_mapping = false
							for _, m in ipairs(modes) do
								if not vim.tbl_isempty(vim.fn.maparg(lhs, m, false, true)) then
									has_mapping = true
									break
								end
							end
							if not has_mapping then
								vim.notify(
									("autopack: '%s' loaded but found no mapping for %s; "
										.. "replaying anyway. If nothing happens, the plugin likely "
										.. "exposes a <Plug> mapping you must bind yourself.")
										:format(label, raw_lhs),
									vim.log.levels.WARN
								)
							end
							trace(opts.debug, label, "replaying key '" .. lhs .. "'")
							feed(lhs, "m") -- "m" = remap, so the plugin's mapping fires
						end)
					end)
				end, { desc = "autopack stub -> " .. label })
			end
		end

		-- Command stubs.
		for _, cmd in ipairs(mod.commands or {}) do
			table.insert(mod._commands, cmd)
			vim.api.nvim_create_user_command(cmd, function(a)
				trace(opts.debug, label, "command '" .. cmd .. "' triggered load")
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
					trace(opts.debug, label, "replaying command ':" .. line .. "'")
					feed(":" .. line .. "\r", "n")
				end)
			end, {
				nargs = "*",
				bang = true,
				range = true,
				desc = "autopack stub -> " .. label,
			})
		end

		-- BufRead stubs: one-shot autocmds keyed on file glob patterns.
		-- During startup, defer loading to VimEnter (UI not ready yet).
		-- After startup, load synchronously on BufRead.
		local bufread_fired = false

		local function bufread_loader()
			loader(function() end)
		end

		for _, pattern in ipairs(mod.patterns or {}) do
			local id = vim.api.nvim_create_autocmd("BufRead", {
				pattern = pattern,
				once = true,
				callback = function()
					bufread_fired = true
					trace(opts.debug, label, "BufRead pattern '" .. pattern .. "' triggered load")
					if vim.v.vim_did_enter == 0 then
						-- Still in startup: defer to VimEnter.
						vim.schedule(bufread_loader)
					else
						bufread_loader()
					end
				end,
				desc = "autopack stub BufRead -> " .. label,
			})
			table.insert(mod._autocmds, id)
		end

		-- Fallback: if a matching buffer is already open at VimEnter, load now.
		-- Only needed when BufRead patterns are registered.
		if mod.patterns and #mod.patterns > 0 then
			local vimenter_id = vim.api.nvim_create_autocmd("VimEnter", {
				once = true,
				callback = function()
					if bufread_fired and not is_loaded() then
						trace(opts.debug, label, "VimEnter fallback triggered load")
						bufread_loader()
					end
				end,
				desc = "autopack fallback VimEnter -> " .. label,
			})
			table.insert(mod._autocmds, vimenter_id)
		end

		-- Startup trigger: load right away instead of waiting for a key,
		-- command, or buffer event. Runs last so it removes the stubs
		-- created above instead of leaving them dangling.
		if mod.startup then
			trace(opts.debug, label, "startup option triggered immediate load")
			loader(function() end)
		end
	end

	if opts.submodules then
		assert(type(opts.submodules) == "table" and not vim.tbl_isempty(opts.submodules),
			"autopack.setup: `submodules` must be a non-empty table of { [module_name] = { ... } }")
		for module_key, mod in pairs(opts.submodules) do
			wire_module(module_key, mod)
		end
	else
		wire_module(nil, opts)
	end

	return opts
end

-- Register one or more plugins. {specs} is a list of plugin specs.
function M.setup(specs)
	local results = {}
	for _, opts in ipairs(specs) do
		table.insert(results, register(opts))
	end
	return results
end

-- ---------------------------------------------------------------------------
-- :Autopackupdate  –  install/update all (or named) registered packs
-- ---------------------------------------------------------------------------

-- Resolve dependency order for a plugin name.
-- Returns an ordered list of specs (dependencies first, then the plugin itself).
-- Errors on unregistered deps or circular dependency chains.
--   name: plugin name to resolve
--   registry: { name -> spec } table
--   added: set of names already scheduled for addition (dedup across batch)
--   visiting: set of names in current call chain (cycle detection)
local function resolve_deps(name, registry, added, visiting)
	if added[name] then
		return {}  -- already scheduled; skip duplicate
	end
	local spec = registry[name]
	if spec == nil then
		error("autopack: dependency '" .. name .. "' is not registered")
	end
	if visiting[name] then
		error("autopack: circular dependency detected involving '" .. name .. "'")
	end
	visiting[name] = true
	local result = {}
	for _, dep in ipairs(spec.dependencies or {}) do
		for _, s in ipairs(resolve_deps(dep, registry, added, visiting)) do
			table.insert(result, s)
		end
	end
	if not added[name] then
		added[name] = true
		table.insert(result, spec)
	end
	visiting[name] = nil
	return result
end

-- Handler shared by M.update() and the :Autopackupdate command.
-- names: list of plugin-name strings (empty = all registered).
-- Uses vim.pack.add() which both installs new packs and updates existing ones.
local function update_handler(names)
	if vim.tbl_isempty(names) then
		if vim.tbl_isempty(M._registry) then
			vim.notify("Call setup() first. Nothing to do.")
			return
		end
		local added = {}
		local all_specs = {}
		for name, _ in pairs(M._registry) do
			for _, s in ipairs(resolve_deps(name, M._registry, added, {})) do
				table.insert(all_specs, s)
			end
		end
		for _, spec in ipairs(all_specs) do
			vim.pack.add({ spec })
		end
	else
		local added = {}
		local all_specs = {}
		for _, name in ipairs(names) do
			if M._registry[name] == nil then
				error("autopack: unknown plugin '" .. name .. "'")
			end
			for _, s in ipairs(resolve_deps(name, M._registry, added, {})) do
				table.insert(all_specs, s)
			end
		end
		for _, spec in ipairs(all_specs) do
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

