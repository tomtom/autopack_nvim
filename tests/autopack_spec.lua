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
-- Test 2: register() with spec stores in registry
-- ---------------------------------------------------------------------------

reset_mocks()
autopack._registry = {} -- ensure clean state

autopack.register({
	name = "gitsigns",
	spec = { src = "https://github.com/lewis6991/gitsigns.nvim" },
	config = { signcolumn = true },
})

tap.ok(autopack._registry["gitsigns"] ~= nil,
	"register() with spec stores entry in _registry")

tap.ok(
	autopack._registry["gitsigns"].src == "https://github.com/lewis6991/gitsigns.nvim",
	"registry entry contains the spec table"
)

-- ---------------------------------------------------------------------------
-- Test 3: register() without spec does not store in registry
-- ---------------------------------------------------------------------------

reset_mocks()
autopack._registry = {}

autopack.register({
	name = "no-spec-plugin",
	config = {},
})

tap.ok(autopack._registry["no-spec-plugin"] == nil,
	"register() without spec does not store in _registry")

-- ---------------------------------------------------------------------------
-- Test 4: register_all() propagates spec to registry
-- ---------------------------------------------------------------------------

reset_mocks()
autopack._registry = {}

autopack.register_all({
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
	"register_all() stores spec for plugin-a")
tap.ok(autopack._registry["plugin-b"] ~= nil,
	"register_all() stores spec for plugin-b")
tap.ok(autopack._registry["plugin-c"] == nil,
	"register_all() does not store entry without spec")

-- ---------------------------------------------------------------------------
-- Test 5: :Autopackupdate with no registered plugins shows message
-- ---------------------------------------------------------------------------

reset_mocks()
autopack._registry = {}
autopack.update(nil) -- simulates no-args

tap.ok(#notify_calls == 1,
	"update() with empty registry calls vim.notify once")
tap.ok(notify_calls[1] == "Call register() first. Nothing to do.",
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
-- Done
-- ---------------------------------------------------------------------------

tap.done()
