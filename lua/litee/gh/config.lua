local M = {}

M.config = {
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
    -- background refresh timer interval in milliseconds. defaults to five
    -- minutes.
    refresh_interval = 300000,
    -- list of highlights to be used within the UI.
    highlights = {
        -- the following highlights will highlight threaded messages in conversation
        -- buffers. 
        -- you can alternate between two highlights if desired by setting these
        -- to different highlights.
        thread_separator = "GHThreadSep",
        thread_separator_alt = "GHThreadSepAlt"
    },
    -- log all git and gh cli actions to a buffer.
    -- the buffer can be opened with "GHOpenDebugBuffer".
    debug_logging = false,
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
        goto_web = "gx",
        -- if selectable, select the object under the cursor for additional operations.
        select = "<leader>",
        -- if selectable, clear all selected items.
        clear_selection = "<leader><leader>",
        -- toggle unread items
        toggle_unread = "u"
    },
}

M.icon_set = nil

function M.set_icon_set()
    M.icon_set = require('litee.lib').icon_set_update(M.config.icon_set_custom, M.config.icon_set)
end

return M
