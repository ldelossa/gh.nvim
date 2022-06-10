local M = {}

local lib_tree      = require('litee.lib.tree')
local lib_notify    = require('litee.lib.notify')
local lib_panel     = require('litee.lib.panel')
local lib_util_win  = require('litee.lib.util.window')

local commands          = require('litee.gh.commands')
local c                 = require('litee.gh.config')
local pr_buffer         = require('litee.gh.pr.buffer')
local pr_marshallers    = require('litee.gh.pr.marshal')
local pr                = require('litee.gh.pr')
local pr_state          = require('litee.gh.pr.state')
local pr_handlers       = require('litee.gh.pr.handlers')
local issues            = require('litee.gh.issues')
local noti              = require('litee.gh.notifications')
-- unused, but must init the global completion function.
local completion    = require('litee.gh.completion')

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
        if not c.config.disable_keymaps then
            vim.api.nvim_buf_set_keymap(state["pr"].buf, "n", c.config.keymaps.expand, "",{
                silent = true,
                callback = pr.expand_pr,
            })
            vim.api.nvim_buf_set_keymap(state["pr"].buf, "n", c.config.keymaps.collapse, "",{
                silent = true,
                callback = pr.collapse_pr,
            })
            vim.api.nvim_buf_set_keymap(state["pr"].buf, "n", c.config.keymaps.goto_web, "",{
                silent = true,
                callback = pr.open_node_url,
            })
        end

        lib_tree.write_tree_no_guide_leaf(
            state["pr"].buf,
            state["pr"].tree,
            pr_marshallers.marshal_pr_node
        )
        return true
    end

    local function post_window_create()
        if not c.config.no_hls then
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
        if not c.config.disable_keymaps then
            vim.api.nvim_buf_set_keymap(state["pr_files"].buf, "n", c.config.keymaps.expand, "",{
                silent = true,
                callback = pr.expand_pr_commits,
            })
            vim.api.nvim_buf_set_keymap(state["pr_files"].buf, "n", c.config.keymaps.collapse, "",{
                silent = true,
                callback = pr.collapse_pr_commits,
            })
            vim.api.nvim_buf_set_keymap(state["pr_files"].buf, "n", c.config.keymaps.goto_web, "",{
                silent = true,
                callback = pr.open_node_url,
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
        if not c.config.no_hls then
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

        if not c.config.disable_keymaps then
            vim.api.nvim_buf_set_keymap(state["pr_review"].buf, "n", c.config.keymaps.expand, "",{
                silent = true,
                callback = pr.expand_pr_review,
            })
            vim.api.nvim_buf_set_keymap(state["pr_review"].buf, "n", c.config.keymaps.collapse, "",{
                silent = true,
                callback = pr.collapse_pr_review,
            })
            vim.api.nvim_buf_set_keymap(state["pr_review"].buf, "n", c.config.keymaps.goto_web, "",{
                silent = true,
                callback = pr.open_node_url,
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
        if not c.config.no_hls then
            lib_util_win.set_tree_highlights()
        end
        -- set scrolloff so contents stays centered
        vim.api.nvim_win_set_option(vim.api.nvim_get_current_win(), "scrolloff", 9999)
    end

    lib_panel.register_component("pr_review", pre_window_create, post_window_create)
end

local function merge_configs(user_config)
    -- merge keymaps
    if user_config.keymaps ~= nil then
        for k, v in pairs(user_config.keymaps) do
            c.config.keymaps[k] = v
        end
    end

    -- merge top levels
    for k, v in pairs(user_config) do
        if k == "keymaps" then
            goto continue
        end
        c.config[k] = v
        ::continue::
    end
end

local function register_git_buffer_completion()
    vim.api.nvim_create_autocmd({"CursorHold"}, {
        pattern = {"*.git/*"},
        callback = function(args) 
            vim.api.nvim_buf_set_option(args.buf, 'ofu', 'v:lua.GH_completion')
        end
    })
    vim.api.nvim_create_autocmd({"CursorHold"}, {
        pattern = {"*.git/*"},
        callback = issues.preview_issue_under_cursor
    })
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

    -- merge in config
    if user_config ~= nil then
        merge_configs(user_config)
    end

    c.set_icon_set()

    -- register gh.nvim completion for .git/ buffers
    if c.config.git_buffer_completion then
        register_git_buffer_completion()
    end

    register_pr_component()
    register_pr_files_component()
    register_pr_review_component()
    commands.setup()
end

function M.refresh()
    if pr_state.pull_state ~= nil then
        -- will refresh any open issues too
        pr_handlers.on_refresh()
    else
        issues.on_refresh()
    end
    noti.on_refresh()
end

-- refresh all data
vim.api.nvim_create_user_command("GHRefresh", M.refresh, {})

M.refresh_timer = nil

function M.start_refresh_timer(now)
    if M.refresh_timer == nil then
        M.refresh_timer = vim.loop.new_timer()
    end
    if now then
        M.refresh()
    end
    M.refresh_timer:start(180000, 180000, function()
        M.refresh()
    end)
end

function M.stop_refresh_timer()
    if M.refresh_timer == nil then
        return
    end
    vim.loop.timer_stop(M.refresh_timer)
end

M.start_refresh_timer()

return M
