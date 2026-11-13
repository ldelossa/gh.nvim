             ██████╗ ██╗  ██╗   ███╗   ██╗██╗   ██╗██╗███╗   ███╗
            ██╔════╝ ██║  ██║   ████╗  ██║██║   ██║██║████╗ ████║
            ██║  ███╗███████║   ██╔██╗ ██║██║   ██║██║██╔████╔██║
            ██║   ██║██╔══██║   ██║╚██╗██║╚██╗ ██╔╝██║██║╚██╔╝██║ Powered by
            ╚██████╔╝██║  ██║██╗██║ ╚████║ ╚████╔╝ ██║██║ ╚═╝ ██║ litee.nvim
             ╚═════╝ ╚═╝  ╚═╝╚═╝╚═╝  ╚═══╝  ╚═══╝  ╚═╝╚═╝     ╚═╝


`gh.nvim`, initially, is a plugin for interactive code reviews which take place
on the GitHub platform.

If you want to go straight to setup and configuration click [here](#setup--configuration)

If you're a visual learner you can check out the official [gh.nvim guide](https://who.ldelossa.is/posts/gh-nvim/). 
This is a work in progress as ``gh.nvim`` changes and matures.

This plugin was created due to the repeat frustration of performing code reviews
of complex changes in the GitHub web UI.

The mentioned frustration seemed to boil down to a few major drawbacks which `gh.nvim`
sets out to fix. These are:

1) Lack of context during code review
    When viewing a pull request in a large code base its very likely that you're
    not sure of the full context of the change. The patch may change the way a
    function works, but you are not aware all the places this function may be
    called. Its difficult to safely say that the patch is OK and approve it.

    To alleviate this, `gh.nvim` will make the pull request code locally available
    on your file system.

2) Lack of sufficient editor tools like LSP
    Because the pull request's code is made locally available all your LSP tools
    work as normal.

    In my previous point, this means performing a LSP call to understand all the
    usages of the editing function is now possible.

3) Lack of automation when attempting to view the full context of a pull request.
    `gh.nvim` automates the process of making the pull request's code locally available.
    To do this, `gh.nvim` embeds a `git` CLI wrapper.

    When a pull request is opened in `gh.nvim` the remote is added locally, the
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

see doc/gh-nvm.txt for complete usage and more details.

Checkout my [rational and demo video](https://youtu.be/hhrWwYfMK1I) to get an initial idea
of how `gh.nvim` works, why it works the way it does, and its look and feel.

### Setup & Configuration

Before getting started with this plugin, make sure you have installed and configured both
the [`git`](https://git-scm.com/) and [`gh`](https://github.com/cli/cli) CLI tools which
are required for this plugin to work.


`gh.nvim` relies on [Litee.nvim](https://github.com/ldelossa/litee.nvim). To setup `gh.nvim`
with the default configuration add the following:

Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
    "ldelossa/gh.nvim",
    dependencies = {
        {
        "ldelossa/litee.nvim",
        config = function()
            require("litee.lib").setup()
        end,
        },
    },
    config = function()
        require("litee.gh").setup()
    end,
}

```

Using [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
    'ldelossa/gh.nvim',
    requires = { { 'ldelossa/litee.nvim' } }
  }
```

Then call the setup function for both Litee.nvim and `gh.nvim`. Make sure you setup
Litee.nvim before `gh.nvim`! The default configuration for `gh.nvim` is shown below (the
default configuration for Litee.nvim can be found on it's Github page).

```lua
require('litee.lib').setup()
require('litee.gh').setup({
  -- deprecated, around for compatability for now.
  jump_mode   = "invoking",
  -- remap the arrow keys to resize any litee.nvim windows.
  map_resize_keys = false,
  -- do not map any keys inside any gh.nvim buffers.
  disable_keymaps = false,
  -- the icon set to use.
  icon_set = "default",
  -- any custom icons to use.
  icon_set_custom = nil,
  -- whether to register the @username and #issue_number omnifunc completion
  -- in buffers which start with .git/
  git_buffer_completion = true,
  -- when true, gh.nvim pickers use a telescope dropdown and review threads /
  -- new comments open in floating windows. when false, threads open in the
  -- diff's other pane. see "Telescope and floating threads" below.
  use_telescope = false,
  -- when true, opening a pull request refuses to run if the repository has
  -- uncommitted changes. default false: review work in progress, the diff's
  -- right side is then your working tree, changes and all. see "Dirty
  -- worktrees" below.
  require_clean_repo = false,
  -- defines keymaps in gh.nvim buffers.
  keymaps = {
      -- when inside a gh.nvim panel, this key will open a node if it has
      -- any futher functionality. for example, hitting <CR> on a commit node
      -- will open the commit's changed files in a new gh.nvim panel.
      open = "<CR>",
      -- when inside a gh.nvim panel, expand a collapsed node
      expand = "zo",
      -- when inside a gh.nvim panel, collpased and expanded node
      collapse = "zc",
      -- when cursor is over a "#1234" formatted issue or PR, open its details
      -- and comments in a new tab.
      goto_issue = "gd",
      -- show any details about a node, typically, this reveals commit messages
      -- and submitted review bodys.
      details = "d",
      -- inside a convo buffer, submit a comment
      submit_comment = "<C-s>",
      -- inside a convo buffer, when your cursor is ontop of a comment, open
      -- up a set of actions that can be performed.
      actions = "<C-a>",
      -- inside a thread convo buffer, resolve the thread.
      resolve_thread = "<C-r>",
      -- inside a gh.nvim panel, if possible, open the node's web URL in your
      -- browser. useful particularily for digging into external failed CI
      -- checks.
      goto_web = "gx"
  }
})
```

It's highly recommended to use `gh.nvim` with either fzf.lua or telescope to override
`vim.ui.select`. If you use telescope, it will work out of the box. If you want to use
fzf.lua, add the following snippet to your config:

```lua
vim.cmd("FzfLua register_ui_select")
```

#### Telescope and floating threads

Set `use_telescope = true` to switch gh.nvim to a telescope-based UI:

- gh.nvim's pickers (open PR, search issues, review actions, labels, reactions, ...)
  open in a telescope dropdown. Only gh.nvim's `vim.ui.select` calls are routed to
  telescope; other plugins keep their own `vim.ui.select`.
- `GHToggleThreads` and `GHCreateThread` open the thread / new comment in a
  floating window at the cursor, so both diff panes stay visible. Toggle again, or
  close the float, to dismiss it.

This requires [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim)
and [telescope-ui-select.nvim](https://github.com/nvim-telescope/telescope-ui-select.nvim):

```lua
{
    "ldelossa/gh.nvim",
    dependencies = { "ldelossa/litee.nvim", "nvim-telescope/telescope-ui-select.nvim" },
    config = function()
        require("litee.gh").setup({ use_telescope = true })
    end,
}
```

With the default `use_telescope = false`, pickers use whatever `vim.ui.select` is
configured and threads replace the diff buffer in the opposite pane.

#### Dirty worktrees

gh.nvim does not require a clean repository. When `git status --porcelain` is not
empty you get a warning and the pull request opens anyway: the diff's right side is
your working tree, so a work in progress shows up in the diff. Any checkout that
would overwrite those changes is still refused by git.

Set

```lua
require("litee.gh").setup({ require_clean_repo = true })
```

to make an unclean repository a hard error instead, so `GHOpenPR` refuses to run
until the changes are stashed or committed.

Additionally, you may want to set up some [which
key](https://github.com/folke/which-key.nvim) bindings to help navigate all of the
commands. Below you can find an example which key configuration that binds most of the
commands. It also includes a keybinding for `LTPanel` which comes from Litee.nvim and
allows you to toggle the panel so you can focus on the diff.Feel free to tweak to your
liking.

```lua
local wk = require("which-key")
wk.add {
  { '<leader>g', group = 'Git' },
  { '<leader>gh', group = 'Github' },
  { '<leader>ghc', group = 'Commits' },
  { '<leader>ghcc', '<cmd>GHCloseCommit<cr>', desc = 'Close' },
  { '<leader>ghce', '<cmd>GHExpandCommit<cr>', desc = 'Expand' },
  { '<leader>ghco', '<cmd>GHOpenToCommit<cr>', desc = 'Open To' },
  { '<leader>ghcp', '<cmd>GHPopOutCommit<cr>', desc = 'Pop Out' },
  { '<leader>ghcz', '<cmd>GHCollapseCommit<cr>', desc = 'Collapse' },
  { '<leader>ghi', group = 'Issues' },
  { '<leader>ghip', '<cmd>GHPreviewIssue<cr>', desc = 'Preview' },
  { '<leader>ghl', group = 'Litee' },
  { '<leader>ghlt', '<cmd>LTPanel<cr>', desc = 'Toggle Panel' },
  { '<leader>ghp', group = 'Pull Request' },
  { '<leader>ghpc', '<cmd>GHClosePR<cr>', desc = 'Close' },
  { '<leader>ghpd', '<cmd>GHPRDetails<cr>', desc = 'Details' },
  { '<leader>ghpe', '<cmd>GHExpandPR<cr>', desc = 'Expand' },
  { '<leader>ghpo', '<cmd>GHOpenPR<cr>', desc = 'Open' },
  { '<leader>ghpp', '<cmd>GHPopOutPR<cr>', desc = 'PopOut' },
  { '<leader>ghpr', '<cmd>GHRefreshPR<cr>', desc = 'Refresh' },
  { '<leader>ghpt', '<cmd>GHOpenToPR<cr>', desc = 'Open To' },
  { '<leader>ghpz', '<cmd>GHCollapsePR<cr>', desc = 'Collapse' },
  { '<leader>ghr', group = 'Review' },
  { '<leader>ghrb', '<cmd>GHStartReview<cr>', desc = 'Begin' },
  { '<leader>ghrc', '<cmd>GHCloseReview<cr>', desc = 'Close' },
  { '<leader>ghrd', '<cmd>GHDeleteReview<cr>', desc = 'Delete' },
  { '<leader>ghre', '<cmd>GHExpandReview<cr>', desc = 'Expand' },
  { '<leader>ghrs', '<cmd>GHSubmitReview<cr>', desc = 'Submit' },
  { '<leader>ghrz', '<cmd>GHCollapseReview<cr>', desc = 'Collapse' },
  { '<leader>ght', group = 'Threads' },
  { '<leader>ghtc', '<cmd>GHCreateThread<cr>', desc = 'Create' },
  { '<leader>ghtn', '<cmd>GHNextThread<cr>', desc = 'Next' },
  { '<leader>ghtt', '<cmd>GHToggleThread<cr>', desc = 'Toggle' },
}
```
