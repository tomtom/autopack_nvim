autopack is a Neovim plugin that lazy-loads optional ('opt') packages on first
key press, command invocation, or BufRead event. It is designed to reduce
startup time by deferring plugin loading until the moment it is actually
needed.

Installation                                *autopack-installation*

To install autopack using |vim.pack.add()| (Neovim 0.11+), add the following
to your |init.lua|:

```
vim.pack.add({
    { src = "https://github.com/tomtom/autopack_nvim" },
})
```

Alternatively, use git etc. to download plugins into your `pack/` directory.

Plugins must be installed in a `pack/*/opt/<name>/` directory (the `opt`
subdirectory, not `start`). autopack calls |:packadd| when a registered trigger
fires.

Plugins are then loaded via:

```
require("autopack").setup({
    {
        name = "gitsigns",
        setup = { signcolumn = true },
        keys = { "<leader>gs" },
        commands = { "Gitsigns" },
    },
    {
        name = "fugitive",
        keys = { "<leader>gg" },
        commands = { "Git", "Gdiffsplit" },
    },
    {
        name = "telescope",
        setup = { defaults = { layout_strategy = "flex" } },
        keys = { "<leader>ff", "<leader>fg" },
        commands = { "Telescope" },
    },
})
```

The plugin will be loaded when one of the named keys is pressed or one of the 
stub commands is called.

