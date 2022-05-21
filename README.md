             ██████╗ ██╗  ██╗   ███╗   ██╗██╗   ██╗██╗███╗   ███╗
            ██╔════╝ ██║  ██║   ████╗  ██║██║   ██║██║████╗ ████║
            ██║  ███╗███████║   ██╔██╗ ██║██║   ██║██║██╔████╔██║
            ██║   ██║██╔══██║   ██║╚██╗██║╚██╗ ██╔╝██║██║╚██╔╝██║ Powered by
            ╚██████╔╝██║  ██║██╗██║ ╚████║ ╚████╔╝ ██║██║ ╚═╝ ██║ litee.nvim
             ╚═════╝ ╚═╝  ╚═╝╚═╝╚═╝  ╚═══╝  ╚═══╝  ╚═╝╚═╝     ╚═╝


GH.nvim, initially, is a plugin for interactive code reviews which take place
on the GitHub platform.

If you want to go straight to setup and configuration click [here](#setup--configuration)

This plugin was created due to the repeat frustration of performing code reviews
of complex changes in the GitHub web UI.

The mentioned frustration seemed to boil down to a few major drawbacks which GH.nvim
sets out to fix. These are:

1) Lack of context during code review
    When viewing a pull request in a large code base its very likely that you're
    not sure of the full context of the change. The patch may change the way a
    function works, but you are not aware all the places this function may be
    called. Its difficult to safely say that the patch is OK and approve it.

    To alleviate this, GH.nvim will make the pull request code locally available
    on your file system.

2) Lack of sufficient editor tools like LSP
    Because the pull request's code is made locally available all your LSP tools
    work as normal.

    In my previous point, this means performing a LSP call to understand all the
    usages of the editing function is now possible.

3) Lack of automation when attempting to view the full context of a pull request.
    GH.nvim automates the process of making the pull request's code locally available.
    To do this, GH.nvim embeds a `git` CLI wrapper.

    When a pull request is opened in GH.nvim the remote is added locally, the
    branch is fetched, and the repo is checked out to the pull request's HEAD.

4) Inability to edit and run the code in the pull request.
    Because the pull request's code is made available locally, its completely
    editable in your familiar `neovim` instance.

    This works for both for writing reviews and responding to reviews of your
    pull request.

    You can build up a diff while responding to review comments, stash them,
    check out your branch, and rebase those changes into your PR and push again.
    Much handier then jumping back and forth between `neovim` and a browser.

    Additionally, since the code is local and checked out on your file system,
    you can now run any local development environments that may exist. The
    environment will be running the pull request's code and you can perform sanity
    checks easily.

GH.nvim is a "commit-wise" review tool. This means you browse the changed files
by their commits. This will feel familiar to those who immediately click on the
"commits" tab on the GitHub UI to view the incremental changes of the pull request.

see doc/gh-nvm.txt for complete usage and more details.

Checkout my [rational and demo video](https://youtu.be/hhrWwYfMK1I) to get an initial idea
of how gh.nvim works, why it works the way it does, and its look and feel.

### Setup & Configuration

Before getting started with this plugin, make sure you have installed and configured both
the [`git`](https://git-scm.com/) and [`gh`](https://github.com/cli/cli) CLI tools which
are required for this plugin to work.


GH.nvim relies on [Litee.nvim](https://github.com/ldelossa/litee.nvim). To setup GH.nvim
with the default configuration add the following:

Using [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
    'ldelossa/gh.nvim'
    requires = { { 'ldelossa/litee.nvim' } }
  }
```

Then call the setup function for both Litee.nvim and GH.nvim. Make sure you setup
Litee.nvim before GH.nvim! The default configuration for GH.nvim is shown below (the
default configuration for Litee.nvim can be found on it's Github page).

```lua
require('litee.lib').setup()
require('litee.gh').setup({
    -- the icon set to use from litee.nvim.
    -- "nerd", "codicons", "default"
    icon_set    = "codicons",
    -- deprecated, around for compatability for now.
    jump_mode   = "invoking",
    -- remap the arrow keys to resize any litee.nvim windows.
    map_resize_keys = false,
    -- do not map any keys inside any gh.nvim buffers.
    disable_keymaps = false,
    -- defines keymaps in gh.nvim buffers.
    keymaps = {
        -- used to open a node in a gh.nvim tree
        open = "<CR>",
        -- expand a node in a gh.nvim tree
        expand = "zo",
        -- collapse the node in a gh.nvim tree
        collapse = "zc",
        -- when cursor is ontop of a '#123' formatted issue reference, open a
        -- new tab with the issue details and comments.
        goto_issue = "gd",
        -- show details associated with a node, for example the commit message
        -- for a commit node in the gh.nvim tree.
        details = "d"
    },
})
```

It's highly recommended to use GH.nvim with either fzf.lua or telescope to override
`vim.ui.select`. If you use telescope, it will work out of the box. If you want to use
fzf.lua, add the following snippet to your config:

```lua
vim.cmd("FzfLua register_ui_select")
```

Additionally, you may want to set up some [which
key](https://github.com/folke/which-key.nvim) bindings to help navigate all of the
commands. Below you can find an example which key configuration that binds most of the
commands. It also includes a keybinding for `LTPanel` which comes from Litee.nvim and
allows you to toggle the panel so you can focus on the diff.Feel free to tweak to your
liking.

```lua
local wk = require("which-key")
wk.register({
    g = {
        name = "+Git",
        h = {
            name = "+Github",
            c = {
                name = "+Commits",
                c = { "<cmd>GHCloseCommit<cr>", "Close" },
                e = { "<cmd>GHExpandCommit<cr>", "Expand" },
                o = { "<cmd>GHOpenToCommit<cr>", "Open To" },
                p = { "<cmd>GHPopOutCommit<cr>", "Pop Out" },
                z = { "<cmd>GHCollapseCommit<cr>", "Collapse" },
            },
            i = {
                name = "+Issues",
                p = { "<cmd>GHPreviewIssue<cr>", "Preview" },
            },
            l = {
                name = "+Litee",
                t = { "<cmd>LTPanel<cr>", "Toggle Panel" },
            },
            r = {
                name = "+Review",
                b = { "<cmd>GHStartReview<cr>", "Begin" },
                c = { "<cmd>GHCloseReview<cr>", "Close" },
                d = { "<cmd>GHDeleteReview<cr>", "Delete" },
                e = { "<cmd>GHExpandReview<cr>", "Expand" },
                s = { "<cmd>GHSubmitReview<cr>", "Submit" },
                z = { "<cmd>GHCollapseReview<cr>", "Collapse" },
            },
            p = {
                name = "+Pull Request",
                c = { "<cmd>GHClosePR<cr>", "Close" },
                d = { "<cmd>GHPRDetails<cr>", "Details" },
                e = { "<cmd>GHExpandPR<cr>", "Expand" },
                o = { "<cmd>GHOpenPR<cr>", "Open" },
                p = { "<cmd>GHPopOutPR<cr>", "PopOut" },
                r = { "<cmd>GHRefreshPR<cr>", "Refresh" },
                t = { "<cmd>GHOpenToPR<cr>", "Open To" },
                z = { "<cmd>GHCollapsePR<cr>", "Collapse" },
            },
            t = {
                name = "+Threads",
                c = { "<cmd>GHCreateThread<cr>", "Create" },
                n = { "<cmd>GHNextThread<cr>", "Next" },
                t = { "<cmd>GHToggleThread<cr>", "Toggle" },
            },
        },
    },
}, { prefix = "<leader>" })
```
