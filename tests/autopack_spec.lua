-- Test suite for autopack.nvim (run with: lua tests/autopack_spec.lua)

local tap = { plan = 0, passed = 0, failed = 0 }

function tap.ok(cond, msg)
	tap.plan = tap.plan + 1
	if cond then
		tap.passed = tap.passed + 1
		io.write("ok " .. tap.plan .. " - " .. msg .. "\n")
	else
		tap.failed = tap.failed + 1
		io.write("not ok " .. tap.plan .. " - " .. msg .. "\n")
	end
end

function tap.done()
	io.write(string.format("1..%d\n", tap.plan))
	io.write(string.format("# pass %d fail %d\n", tap.passed, tap.failed))
	if tap.failed > 0 then
		os.exit(1)
	end
end

-- ---------------------------------------------------------------------------
-- Mock Neovim globals (set up BEFORE require("autopack"))
-- ---------------------------------------------------------------------------

-- Track calls to Neovim APIs
local pack_add_calls = {}   -- vim.pack.add() invocations
local notify_calls = {}     -- vim.notify() invocations
local user_commands = {}    -- nvim_create_user_command invocations
local autocmds = {}         -- nvim_create_autocmd invocations
local autocmd_callbacks = {} -- nvim_create_autocmd callbacks for simulation

local function reset_mocks()
	pack_add_calls = {}
	notify_calls = {}
	user_commands = {}
	autocmds = {}
	autocmd_callbacks = {}
end

-- Patch one field of a mock table (e.g. the global `vim` or one of its
-- subtables) for the duration of a single test. Indirection through a
-- local parameter avoids luacheck's read-only-global-field check, which
-- would otherwise flag intentional `vim.x = ...` mock overrides.
local function mock_set(tbl, key, value)
	tbl[key] = value
end

_G.vim = {
	pack = {
		add = function(specs)
			table.insert(pack_add_calls, specs)
		end,
	},
	notify = function(msg)
		table.insert(notify_calls, msg)
	end,
	tbl_isempty = function(t)
		return next(t) == nil
	end,
	schedule = function(fn)
		-- Do not execute deferred callbacks during tests.
	end,
	log = {
		levels = {
			WARN = "WARN",
		},
	},
	g = {
		mapleader = "\\",
		maplocalleader = "\\",
	},
	v = {
		vim_did_enter = 1,
	},
	fn = {
		maparg = function()
			return {}
		end,
	},
	cmd = function() end,
	keymap = {
		set = function() end,
		del = function() end,
	},
	api = {
		nvim_create_user_command = function(name, handler, opts)
			table.insert(user_commands, { name = name, handler = handler, opts = opts })
		end,
		nvim_create_autocmd = function(event, opts)
			table.insert(autocmds, { event = event, opts = opts })
			if opts and opts.callback then
				table.insert(autocmd_callbacks, { event = event, callback = opts.callback })
			end
			return #autocmds
		end,
		nvim_del_user_command = function() end,
		nvim_del_autocmd = function() end,
		nvim_feedkeys = function() end,
		nvim_replace_termcodes = function(s) return s end,
	},
}

-- ---------------------------------------------------------------------------
-- Load the module (registers Autopackupdate immediately since vim_did_enter == 1)
-- ---------------------------------------------------------------------------

local autopack = require("autopack")

-- ---------------------------------------------------------------------------
-- Test 1: Autopackupdate command is registered immediately when loaded
--         after VimEnter (vim_did_enter == 1)
-- ---------------------------------------------------------------------------

tap.ok(#user_commands >= 1,
	"vim.api.nvim_create_user_command was called during module load")

local found = false
for _, cmd in ipairs(user_commands) do
	if cmd.name == "Autopackupdate" then
		found = true
		tap.ok(cmd.opts.nargs == "*",
			"Autopackupdate command has nargs = '*'")
		break
	end
end
tap.ok(found, "Autopackupdate user command was created immediately (no VimEnter needed)")

-- ---------------------------------------------------------------------------
-- Test 2: setup() with spec stores in registry
-- ---------------------------------------------------------------------------

reset_mocks()
autopack._registry = {} -- ensure clean state

autopack.setup({
	{
		name = "gitsigns",
		spec = { src = "https://github.com/lewis6991/gitsigns.nvim" },
		setup = { signcolumn = true },
	},
})

tap.ok(autopack._registry["gitsigns"] ~= nil,
	"setup() with spec stores entry in _registry")

tap.ok(
	autopack._registry["gitsigns"].src == "https://github.com/lewis6991/gitsigns.nvim",
	"registry entry contains the spec table"
)

-- ---------------------------------------------------------------------------
-- Test 3: setup() without spec does not store in registry
-- ---------------------------------------------------------------------------

reset_mocks()
autopack._registry = {}

autopack.setup({
	{
		name = "no-spec-plugin",
		setup = {},
	},
})

tap.ok(autopack._registry["no-spec-plugin"] == nil,
	"setup() without spec does not store in _registry")

-- ---------------------------------------------------------------------------
-- Test 4: setup() propagates spec to registry
-- ---------------------------------------------------------------------------

reset_mocks()
autopack._registry = {}

autopack.setup({
	{
		name = "plugin-a",
		spec = { src = "https://github.com/a/a.nvim" },
	},
	{
		name = "plugin-b",
		spec = { src = "https://github.com/b/b.nvim" },
	},
	{
		name = "plugin-c",
		-- no spec
	},
})

tap.ok(autopack._registry["plugin-a"] ~= nil,
	"setup() stores spec for plugin-a")
tap.ok(autopack._registry["plugin-b"] ~= nil,
	"setup() stores spec for plugin-b")
tap.ok(autopack._registry["plugin-c"] == nil,
	"setup() does not store entry without spec")

-- ---------------------------------------------------------------------------
-- Test 5: :Autopackupdate with no registered plugins shows message
-- ---------------------------------------------------------------------------

reset_mocks()
autopack._registry = {}
autopack.update(nil) -- simulates no-args

tap.ok(#notify_calls == 1,
	"update() with empty registry calls vim.notify once")
tap.ok(notify_calls[1] == "Call setup() first. Nothing to do.",
	"notify message is correct")

-- ---------------------------------------------------------------------------
-- Test 6: :Autopackupdate with no args updates all registered
-- ---------------------------------------------------------------------------

reset_mocks()
autopack._registry = {
	["gitsigns"] = { src = "https://github.com/lewis6991/gitsigns.nvim" },
	["telescope"] = { src = "https://github.com/nvim-telescope/telescope.nvim" },
}
autopack.update(nil)

tap.ok(#pack_add_calls == 2,
	"update() without args calls vim.pack.add() for all registered")

-- Each call receives { spec } (wrapped in a list)
local specs_seen = {}
for _, call in ipairs(pack_add_calls) do
	for _, spec in ipairs(call) do
		specs_seen[spec.src] = true
	end
end
tap.ok(specs_seen["https://github.com/lewis6991/gitsigns.nvim"],
	"gitsigns spec passed to vim.pack.add()")
tap.ok(specs_seen["https://github.com/nvim-telescope/telescope.nvim"],
	"telescope spec passed to vim.pack.add()")

-- ---------------------------------------------------------------------------
-- Test 7: :Autopackupdate with names updates only those
-- ---------------------------------------------------------------------------

reset_mocks()
autopack._registry = {
	["gitsigns"] = { src = "https://github.com/lewis6991/gitsigns.nvim" },
	["telescope"] = { src = "https://github.com/nvim-telescope/telescope.nvim" },
	["fugitive"] = { src = "https://github.com/tpope/vim-fugitive" },
}
autopack.update({ "gitsigns", "fugitive" })

tap.ok(#pack_add_calls == 2,
	"update() with names calls vim.pack.add() only for those plugins")

local call_srcs = {}
for _, call in ipairs(pack_add_calls) do
	for _, spec in ipairs(call) do
		table.insert(call_srcs, spec.src)
	end
end
tap.ok(#call_srcs == 2,
	"total specs passed is 2 (gitsigns + fugitive)")
tap.ok(call_srcs[1] == "https://github.com/lewis6991/gitsigns.nvim"
	or call_srcs[2] == "https://github.com/lewis6991/gitsigns.nvim",
	"gitsigns spec included")
tap.ok(call_srcs[1] == "https://github.com/tpope/vim-fugitive"
	or call_srcs[2] == "https://github.com/tpope/vim-fugitive",
	"fugitive spec included")

-- ---------------------------------------------------------------------------
-- Test 8: :Autopackupdate with unknown name errors
-- ---------------------------------------------------------------------------

reset_mocks()
autopack._registry = {
	["gitsigns"] = { src = "https://github.com/lewis6991/gitsigns.nvim" },
}

local ok, err = pcall(autopack.update, { "gitsigns", "unknown_name" })
tap.ok(not ok,
	"update() with unknown plugin name raises an error")
tap.ok(err ~= nil and err:find("unknown plugin"),
	"error message mentions 'unknown plugin'")
tap.ok(err ~= nil and err:find("unknown_name"),
	"error message includes the unknown name")

-- ---------------------------------------------------------------------------
-- Test 9: M.update accepts single string
-- ---------------------------------------------------------------------------

reset_mocks()
autopack._registry = {
	["gitsigns"] = { src = "https://github.com/lewis6991/gitsigns.nvim" },
}
autopack.update("gitsigns")

tap.ok(#pack_add_calls == 1,
	"update('gitsigns') with single string works")

-- ---------------------------------------------------------------------------
-- Test 10: derive_name with HTTPS URL
-- ---------------------------------------------------------------------------

local dn = autopack.derive_name

tap.ok(dn("https://github.com/lewis6991/gitsigns.nvim") == "gitsigns.nvim",
	"derive_name keeps .nvim suffix from HTTPS URL")

-- ---------------------------------------------------------------------------
-- Test 11: derive_name strips .git suffix
-- ---------------------------------------------------------------------------

tap.ok(dn("https://github.com/user/repo.git") == "repo",
	"derive_name strips trailing .git")

-- ---------------------------------------------------------------------------
-- Test 12: derive_name handles SSH URLs
-- ---------------------------------------------------------------------------

tap.ok(dn("git@github.com:user/repo.git") == "repo",
	"derive_name handles SSH URL and strips .git")

-- ---------------------------------------------------------------------------
-- Test 13: derive_name strips trailing slash
-- ---------------------------------------------------------------------------

tap.ok(dn("https://github.com/user/repo/") == "repo",
	"derive_name strips trailing slash")

-- ---------------------------------------------------------------------------
-- Test 14: derive_name strips query parameters
-- ---------------------------------------------------------------------------

tap.ok(dn("https://github.com/user/repo?branch=main") == "repo",
	"derive_name strips query parameters")

-- ---------------------------------------------------------------------------
-- Test 15: derive_name keeps .vim suffix
-- ---------------------------------------------------------------------------

tap.ok(dn("https://github.com/user/foo.vim") == "foo.vim",
	"derive_name keeps .vim suffix")

-- ---------------------------------------------------------------------------
-- Test 16: derive_name keeps _nvim suffix
-- ---------------------------------------------------------------------------

tap.ok(dn("https://github.com/user/foo_nvim") == "foo_nvim",
	"derive_name keeps _nvim suffix")

-- ---------------------------------------------------------------------------
-- Test 17: derive_name keeps _vim suffix
-- ---------------------------------------------------------------------------

tap.ok(dn("https://github.com/user/foo_vim") == "foo_vim",
	"derive_name keeps _vim suffix")

-- ---------------------------------------------------------------------------
-- Test 18: derive_name keeps .nvim suffix with hyphenated name
-- ---------------------------------------------------------------------------

tap.ok(dn("https://github.com/user/foo-bar.nvim") == "foo-bar.nvim",
	"derive_name keeps .nvim suffix on hyphenated name")

-- ---------------------------------------------------------------------------
-- Test 19: derive_name with no suffix leaves name unchanged
-- ---------------------------------------------------------------------------

tap.ok(dn("https://github.com/user/foo") == "foo",
	"derive_name leaves name unchanged when no suffix")

-- ---------------------------------------------------------------------------
-- Test 20: derive_name keeps the repo name as-is regardless of the org name
-- ---------------------------------------------------------------------------

tap.ok(dn("https://github.com/nvim-telescope/telescope.nvim") == "telescope.nvim",
	"derive_name keeps .nvim suffix, ignoring the org's nvim- prefix")

-- ---------------------------------------------------------------------------
-- Test 21: derive_name keeps vim- prefix
-- ---------------------------------------------------------------------------

tap.ok(dn("https://github.com/tpope/vim-fugitive") == "vim-fugitive",
	"derive_name keeps vim- prefix")

-- ---------------------------------------------------------------------------
-- Test 22: setup() with spec.src but no name derives the name
-- ---------------------------------------------------------------------------

reset_mocks()
autopack._registry = {}

local derived = autopack.setup({
	{
		spec = { src = "https://github.com/lewis6991/gitsigns.nvim" },
		setup = { signcolumn = true },
	},
})

tap.ok(derived[1].name == "gitsigns.nvim",
	"setup() derives name from spec.src when name is absent")

-- ---------------------------------------------------------------------------
-- Test 16: setup() with both name and spec.src preserves name
-- ---------------------------------------------------------------------------

reset_mocks()
autopack._registry = {}

local preserved = autopack.setup({
	{
		name = "my-gitsigns",
		spec = { src = "https://github.com/lewis6991/gitsigns.nvim" },
	},
})

tap.ok(preserved[1].name == "my-gitsigns",
	"setup() preserves explicit name when spec.src is also given")

-- ---------------------------------------------------------------------------
-- Test 17: setup() with neither name nor spec.src errors
-- ---------------------------------------------------------------------------

reset_mocks()
autopack._registry = {}

local ok15, err15 = pcall(autopack.setup, {
	{ setup = { signcolumn = true } },
})

tap.ok(not ok15,
	"setup() without name or spec.src raises an error")

tap.ok(err15 ~= nil and err15:find("name"),
	"error message mentions 'name'")
tap.ok(err15 ~= nil and err15:find("spec%.src"),
	"error message mentions 'spec.src'")


-- ---------------------------------------------------------------------------
-- Test 18: update() respects dependencies - deps added before dependents
-- ---------------------------------------------------------------------------

reset_mocks()
autopack._registry = {
	["lib-a"] = { src = "https://github.com/user/lib-a" },
	["lib-b"] = { src = "https://github.com/user/lib-b", dependencies = { "lib-a" } },
	["main"] = { src = "https://github.com/user/main", dependencies = { "lib-b" } },
}
autopack.update(nil)

tap.ok(#pack_add_calls == 3,
	"update() with deps calls vim.pack.add() 3 times")

-- Extract ordered src list
local dep_order = {}
for _, call in ipairs(pack_add_calls) do
	for _, spec in ipairs(call) do
		table.insert(dep_order, spec.src)
	end
end

-- lib-a must come before lib-b, lib-b before main
local function find_idx(list, val)
	for i, v in ipairs(list) do
		if v == val then return i end
	end
	return nil
end

local idx_a = find_idx(dep_order, "https://github.com/user/lib-a")
local idx_b = find_idx(dep_order, "https://github.com/user/lib-b")
local idx_m = find_idx(dep_order, "https://github.com/user/main")

tap.ok(idx_a ~= nil and idx_b ~= nil and idx_a < idx_b,
	"lib-a added before lib-b")
tap.ok(idx_b ~= nil and idx_m ~= nil and idx_b < idx_m,
	"lib-b added before main")

-- ---------------------------------------------------------------------------
-- Test 19: update() with unregistered dependency errors
-- ---------------------------------------------------------------------------

reset_mocks()
autopack._registry = {
	["main"] = { src = "https://github.com/user/main", dependencies = { "missing-lib" } },
}

local ok18, err18 = pcall(autopack.update, nil)
tap.ok(not ok18,
	"update() with unregistered dependency raises an error")
tap.ok(err18 ~= nil and err18:find("missing%-lib"),
	"error message mentions the missing dependency name")

-- ---------------------------------------------------------------------------
-- Test 20: update() with circular dependency errors
-- ---------------------------------------------------------------------------

reset_mocks()
autopack._registry = {
	["a"] = { src = "https://github.com/user/a", dependencies = { "b" } },
	["b"] = { src = "https://github.com/user/b", dependencies = { "a" } },
}

local ok19, err19 = pcall(autopack.update, nil)
tap.ok(not ok19,
	"update() with circular dependency raises an error")
tap.ok(err19 ~= nil and err19:find("circular"),
	"error message mentions 'circular'")

-- ---------------------------------------------------------------------------
-- Test 21: update() skips already-added dependencies
-- ---------------------------------------------------------------------------

reset_mocks()
autopack._registry = {
	["lib-a"] = { src = "https://github.com/user/lib-a" },
	["lib-b"] = { src = "https://github.com/user/lib-b", dependencies = { "lib-a" } },
}
-- Update only lib-b; lib-a should be auto-added as dependency
autopack.update("lib-b")

-- lib-a must be added (as dep), lib-b must be added
local dep_srcs = {}
for _, call in ipairs(pack_add_calls) do
	for _, spec in ipairs(call) do
		table.insert(dep_srcs, spec.src)
	end
end

tap.ok(find_idx(dep_srcs, "https://github.com/user/lib-a") ~= nil,
	"dependency lib-a was auto-added when updating lib-b")
local dep_a_idx = find_idx(dep_srcs, "https://github.com/user/lib-a")
local dep_b_idx = find_idx(dep_srcs, "https://github.com/user/lib-b")
tap.ok(dep_a_idx ~= nil and dep_b_idx ~= nil and dep_a_idx < dep_b_idx,
	"dependency lib-a added before lib-b")

-- ---------------------------------------------------------------------------
-- Test 22: setup() accepts a plain string argument (URL shorthand)
-- ---------------------------------------------------------------------------

reset_mocks()
autopack._registry = {}

local result = autopack.setup({ "https://github.com/user/cool-plugin" })

tap.ok(type(result) == "table",
	"setup({\"https://...\"}) returns a table")
tap.ok(result[1].name == "cool-plugin",
	"setup({\"https://...\"}) derives name from URL")
tap.ok(result[1].spec ~= nil and result[1].spec.src == "https://github.com/user/cool-plugin",
	"setup({\"https://...\"}) sets spec.src to the URL")
tap.ok(autopack._registry["cool-plugin"] ~= nil,
	"setup({\"https://...\"}) stores entry in _registry")

-- ---------------------------------------------------------------------------
-- Test 23: setup() accepts spec as string in opts table
-- ---------------------------------------------------------------------------

reset_mocks()
autopack._registry = {}

local result2 = autopack.setup({ { spec = "https://github.com/user/another-plugin.git" } })

tap.ok(type(result2) == "table",
	"setup({{spec=string}}) returns a table")
tap.ok(result2[1].spec ~= nil and result2[1].spec.src == "https://github.com/user/another-plugin.git",
	"setup({{spec=string}}) normalizes spec to {src=...}")
tap.ok(result2[1].name == "another-plugin",
	"setup({{spec=string}}) derives name from URL")
tap.ok(autopack._registry["another-plugin"] ~= nil,
	"setup({{spec=string}}) stores in registry")

-- ---------------------------------------------------------------------------
-- Test 24: setup() with string spec creates no stubs
-- ---------------------------------------------------------------------------

reset_mocks()
autopack._registry = {}

autopack.setup({ "https://github.com/user/no-stubs-plugin" })

tap.ok(#user_commands == 0,
	"setup({\"https://...\"}) creates no user command stubs")
tap.ok(#autocmds == 0,
	"setup({\"https://...\"}) creates no autocmd stubs")

-- ---------------------------------------------------------------------------
-- Test 25: setup() with `submodules` creates stubs per module
-- ---------------------------------------------------------------------------

reset_mocks()
autopack._registry = {}

autopack.setup({
	{
		name = "mini.nvim",
		spec = { src = "https://github.com/nvim-mini/mini.nvim" },
		submodules = {
			["mini.git"] = { commands = { "MiniGit" } },
			["mini.surround"] = { keys = { "sa" } },
		},
	},
})

local found_minigit = false
for _, cmd in ipairs(user_commands) do
	if cmd.name == "MiniGit" then found_minigit = true end
end
tap.ok(found_minigit, "submodules: command stub created for mini.git module")

-- ---------------------------------------------------------------------------
-- Test 26: setup() with `submodules` shares one :packadd across submodules
-- ---------------------------------------------------------------------------

reset_mocks()
autopack._registry = {}

local packadd_calls = {}
local real_cmd = vim.cmd
mock_set(vim, "cmd", function(c)
	table.insert(packadd_calls, c)
end)

local minigit_cmd_handler, minisurround_key_handler

mock_set(vim.api, "nvim_create_user_command", function(name, handler, opts)
	table.insert(user_commands, { name = name, handler = handler, opts = opts })
	if name == "MiniGit" then minigit_cmd_handler = handler end
end)
mock_set(vim.keymap, "set", function(mode, lhs, handler)
	if lhs == "sa" then minisurround_key_handler = handler end
end)

autopack.setup({
	{
		name = "mini.nvim",
		spec = { src = "https://github.com/nvim-mini/mini.nvim" },
		submodules = {
			["mini.git"] = { commands = { "MiniGit" } },
			["mini.surround"] = { keys = { "sa" } },
		},
	},
})

minigit_cmd_handler({ args = "", range = 0, bang = false, mods = "" })
minisurround_key_handler()

tap.ok(#packadd_calls == 1,
	"submodules: :packadd runs once total, shared across both module triggers")
tap.ok(packadd_calls[1] == "packadd mini.nvim",
	"submodules: :packadd uses the shared plugin name")

mock_set(vim, "cmd", real_cmd)
mock_set(vim.api, "nvim_create_user_command", function(name, handler, opts)
	table.insert(user_commands, { name = name, handler = handler, opts = opts })
end)
mock_set(vim.keymap, "set", function() end)

-- ---------------------------------------------------------------------------
-- Test 27: setup() with `submodules` calls require() on each module's own name
-- ---------------------------------------------------------------------------

reset_mocks()
autopack._registry = {}

local required_modules = {}
local real_require = require
_G.require = function(name)
	table.insert(required_modules, name)
	return { setup = function() end }
end

local mod_cmd_handlers = {}
mock_set(vim.api, "nvim_create_user_command", function(name, handler, opts)
	table.insert(user_commands, { name = name, handler = handler, opts = opts })
	mod_cmd_handlers[name] = handler
end)

autopack.setup({
	{
		name = "mini.nvim",
		spec = { src = "https://github.com/nvim-mini/mini.nvim" },
		submodules = {
			["mini.git"] = { commands = { "MiniGit" }, setup = true },
			["mini.surround"] = { commands = { "MiniSurround" }, setup = true },
		},
	},
})

mod_cmd_handlers["MiniGit"]({ args = "", range = 0, bang = false, mods = "" })
mod_cmd_handlers["MiniSurround"]({ args = "", range = 0, bang = false, mods = "" })

tap.ok(required_modules[1] == "mini.git" and required_modules[2] == "mini.surround"
	or required_modules[1] == "mini.surround" and required_modules[2] == "mini.git",
	"submodules: each module's setup requires its own module name")

mock_set(vim.api, "nvim_create_user_command", function(name, handler, opts)
	table.insert(user_commands, { name = name, handler = handler, opts = opts })
end)
_G.require = real_require

-- ---------------------------------------------------------------------------
-- Test 28: setup() rejects an empty `submodules` table
-- ---------------------------------------------------------------------------

reset_mocks()
autopack._registry = {}

local ok28, err28 = pcall(autopack.setup, {
	{
		name = "mini.nvim",
		spec = { src = "https://github.com/nvim-mini/mini.nvim" },
		submodules = {},
	},
})

tap.ok(not ok28, "submodules: empty `submodules` table raises an error")
tap.ok(err28 ~= nil and err28:find("submodules"),
	"submodules: error message mentions 'submodules'")

-- ---------------------------------------------------------------------------
-- Test 29: register() with `startup` loads immediately (no trigger needed)
-- ---------------------------------------------------------------------------

reset_mocks()
autopack._registry = {}

local startup_packadd_calls = {}
local real_cmd29 = vim.cmd
mock_set(vim, "cmd", function(c)
	table.insert(startup_packadd_calls, c)
end)

local required29 = {}
local real_require29 = require
_G.require = function(name)
	table.insert(required29, name)
	return { setup = function() end }
end

autopack.setup({
	{
		name = "gitsigns.nvim",
		spec = { src = "https://github.com/lewis6991/gitsigns.nvim" },
		startup = true,
		setup = { signcolumn = true },
	},
})

tap.ok(#startup_packadd_calls == 1 and startup_packadd_calls[1] == "packadd gitsigns.nvim",
	"startup: :packadd runs immediately without any trigger")
tap.ok(required29[1] == "gitsigns",
	"startup: require() runs immediately with the derived module name")

mock_set(vim, "cmd", real_cmd29)
_G.require = real_require29

-- ---------------------------------------------------------------------------
-- Test 30: `startup` on one submodule does not eager-load its siblings
-- ---------------------------------------------------------------------------

reset_mocks()
autopack._registry = {}

local required30 = {}
local real_require30 = require
_G.require = function(name)
	table.insert(required30, name)
	return { setup = function() end }
end

local minisurround_handler
mock_set(vim.api, "nvim_create_user_command", function(name, handler, opts)
	table.insert(user_commands, { name = name, handler = handler, opts = opts })
	if name == "MiniSurround" then minisurround_handler = handler end
end)

autopack.setup({
	{
		name = "mini.nvim",
		spec = { src = "https://github.com/nvim-mini/mini.nvim" },
		submodules = {
			["mini.git"] = { startup = true, setup = true },
			["mini.surround"] = { commands = { "MiniSurround" }, setup = true },
		},
	},
})

tap.ok(required30[1] == "mini.git" and #required30 == 1,
	"startup: only the submodule with `startup = true` loads eagerly")

minisurround_handler({ args = "", range = 0, bang = false, mods = "" })
tap.ok(required30[#required30] == "mini.surround",
	"startup: sibling submodule still loads lazily on its own trigger")

mock_set(vim.api, "nvim_create_user_command", function(name, handler, opts)
	table.insert(user_commands, { name = name, handler = handler, opts = opts })
end)
_G.require = real_require30

-- ---------------------------------------------------------------------------
-- Test 31: function `setup` receives the required module table
-- ---------------------------------------------------------------------------

reset_mocks()
autopack._registry = {}

local fake_module31 = { setup = function() end, gen_highlighter = {} }
local real_require31 = require
_G.require = function() return fake_module31 end

local received31
autopack.setup({
	{
		name = "mini.hipatterns",
		startup = true,
		setup = function(m)
			received31 = m
		end,
	},
})

tap.ok(received31 == fake_module31,
	"function setup: receives the require()'d module as its argument")

_G.require = real_require31

-- ---------------------------------------------------------------------------
-- Test 32: function `setup` receives nil when require() fails
-- ---------------------------------------------------------------------------

reset_mocks()
autopack._registry = {}

local real_require32 = require
_G.require = function() error("module not found") end

local received32, call_count32 = "unset", 0
autopack.setup({
	{
		name = "vim-fugitive",
		startup = true,
		setup = function(m)
			received32 = m
			call_count32 = call_count32 + 1
		end,
	},
})

tap.ok(received32 == nil,
	"function setup: receives nil when require() fails")
tap.ok(call_count32 == 1,
	"function setup: still runs once even when require() fails")

_G.require = real_require32

-- ---------------------------------------------------------------------------
-- Done
-- ---------------------------------------------------------------------------

tap.done()
