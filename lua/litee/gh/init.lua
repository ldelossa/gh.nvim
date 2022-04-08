local M = {}

local lib_state     = require('litee.lib.state')
local lib_tree      = require('litee.lib.tree')
local lib_notify    = require('litee.lib.notify')
local lib_panel     = require('litee.lib.panel')
local lib_util_win  = require('litee.lib.util.window')

local commands          = require('litee.gh.commands')
local config            = require('litee.gh.config').config
local pr_buffer         = require('litee.gh.pr.buffer')
local pr_marshallers    = require('litee.gh.pr.marshal')
local pr                = require('litee.gh.pr')

-- ui_req_ctx creates a context table summarizing the
-- environment when a gh request is being
-- made.
--
-- see return type for details.
local function ui_req_ctx()
    local buf    = vim.api.nvim_get_current_buf()
    local win    = vim.api.nvim_get_current_win()
    local tab    = vim.api.nvim_win_get_tabpage(win)
    local linenr = vim.api.nvim_win_get_cursor(win)
    local tree_type   = lib_state.get_type_from_buf(tab, buf)
    local tree_handle = lib_state.get_tree_from_buf(tab, buf)
    local state       = lib_state.get_state(tab)

    local cursor = nil
    local node = nil
    if state ~= nil then
        if state["bookmarks"] ~= nil and state["bookmarks"].win ~= nil and
            vim.api.nvim_win_is_valid(state["bookmarks"].win) then
            cursor = vim.api.nvim_win_get_cursor(state["bookmarks"].win)
        end
        if cursor ~= nil then
            node = lib_tree.marshal_line(cursor, state["bookmarks"].tree)
        end
    end

    return {
        -- the current buffer when the request is made
        buf = buf,
        -- the current win when the request is made
        win = win,
        -- the current tab when the request is made
        tab = tab,
        -- the current cursor pos when the request is made
        linenr = linenr,
        -- the type of tree if request is made in a lib_panel
        -- window.
        tree_type = tree_type,
        -- a hande to the tree if the request is made in a lib_panel
        -- window.
        tree_handle = tree_handle,
        -- the pos of the bookmarks cursor if a valid caltree exists.
        cursor = cursor,
        -- the current state provided by lib_state
        state = state,
        -- the current marshalled node if there's a valid bookmarks
        -- window present.
        node = node
    }
end


-- register_pr_component registers the "pr" litee component.
--
-- this component renders a tree of pull request details including each commit
-- which makes up the pull request.
local function register_pr_component()
    local function pre_window_create(state)
        if state["pr"].tree == nil then
            return false
        end

        local buf_name = "PullRequest"

        state["pr"].buf =
            pr_buffer.setup_buffer(buf_name, state["pr"].buf, state["pr"].tab, pr.open_node_pr, pr.details_pr)
        if state["pr"].tree == nil then
            return false
        end

        -- setup other buffer keymaps
        if not config.disable_keymaps then
            vim.api.nvim_buf_set_keymap(state["pr"].buf, "n", config.keymaps.expand, "",{
                silent = true,
                callback = pr.expand_pr,
            })
            vim.api.nvim_buf_set_keymap(state["pr"].buf, "n", config.keymaps.collapse, "",{
                silent = true,
                callback = pr.collapse_pr,
            })
        end

        lib_tree.write_tree_no_guide_leaf(
            state["pr"].buf,
            state["pr"].tree,
            pr_marshallers.marshal_pr_commit_node
        )
        return true
    end

    local function post_window_create()
        if not config.no_hls then
            lib_util_win.set_tree_highlights()
        end
        -- set scrolloff so contents stays centered
        vim.api.nvim_win_set_option(vim.api.nvim_get_current_win(), "scrolloff", 9999)
    end

    lib_panel.register_component("pr", pre_window_create, post_window_create)
end

-- register_pr_files_component registers the "pr_files" litee component.
--
-- this component renders a tree of files modified by a particular commit and
-- one or more comments associated with a particular modified file.
local function register_pr_files_component()
    local function pre_window_create(state)
        if state["pr_files"].tree == nil then
            return false
        end

        local buf_name = "PullRequestCommit"

        state["pr_files"].buf =
            pr_buffer.setup_buffer(buf_name, state["pr_files"].buf, state["pr_files"].tab, pr.open_node_files, pr.details_pr_files)
        if state["pr_files"].tree == nil then
            return false
        end

        -- setup other buffer keymaps
        if not config.disable_keymaps then
            vim.api.nvim_buf_set_keymap(state["pr_files"].buf, "n", config.keymaps.expand, "",{
                silent = true,
                callback = pr.expand_pr_commits,
            })
            vim.api.nvim_buf_set_keymap(state["pr_files"].buf, "n", config.keymaps.collapse, "",{
                silent = true,
                callback = pr.collapse_pr_commits,
            })
        end

        lib_tree.write_tree_no_guide_leaf(
            state["pr_files"].buf,
            state["pr_files"].tree,
            pr_marshallers.marshal_pr_file_node
        )
        return true
    end

    local function post_window_create()
        if not config.no_hls then
            lib_util_win.set_tree_highlights()
        end
        -- set scrolloff so contents stays centered
        vim.api.nvim_win_set_option(vim.api.nvim_get_current_win(), "scrolloff", 9999)
    end

    lib_panel.register_component("pr_files", pre_window_create, post_window_create)
end

-- register_pr_review_component registers the "pr_review" litee component.
local function register_pr_review_component()
    local function pre_window_create(state)
        if state["pr_review"].tree == nil then
            return false
        end

        local buf_name = "PullRequestReview"

        state["pr_review"].buf =
            pr_buffer.setup_buffer(buf_name, state["pr_review"].buf, state["pr_review"].tab, pr.open_node_review, pr.details_pr_review)
        if state["pr_review"].tree == nil then
            return false
        end

        if not config.disable_keymaps then
            vim.api.nvim_buf_set_keymap(state["pr_review"].buf, "n", config.keymaps.expand, "",{
                silent = true,
                callback = pr.expand_pr_review,
            })
            vim.api.nvim_buf_set_keymap(state["pr_review"].buf, "n", config.keymaps.collapse, "",{
                silent = true,
                callback = pr.collapse_pr_review,
            })
        end

        lib_tree.write_tree_no_guide_leaf(
            state["pr_review"].buf,
            state["pr_review"].tree,
            pr_marshallers.marshal_pr_review_node
        )
        return true
    end

    local function post_window_create()
        if not config.no_hls then
            lib_util_win.set_tree_highlights()
        end
        -- set scrolloff so contents stays centered
        vim.api.nvim_win_set_option(vim.api.nvim_get_current_win(), "scrolloff", 9999)
    end

    lib_panel.register_component("pr_review", pre_window_create, post_window_create)
end

function M.setup(user_config)
    if not pcall(require, "litee.lib") then
        lib_notify.notify_popup_with_timeout("Cannot start litee-gh without the litee.lib library.", 1750, "error")
        return
    end

    if vim.fn.executable("gh") == 0 then
        lib_notify.notify_popup_with_timeout("The 'gh' CLI tool must be installed to use gh.nvim", 1750, "error")
        return
    end

    register_pr_component()
    register_pr_files_component()
    register_pr_review_component()
    commands.setup()
end

return M
