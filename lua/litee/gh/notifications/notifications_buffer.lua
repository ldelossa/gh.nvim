local lib_notify    = require('litee.lib.notify')
local lib_util      = require('litee.lib.util')
local lib_util_path = require('litee.lib.util.path')

local ghcli        = require('litee.gh.ghcli')
local issues       = require('litee.gh.issues')
local pr           = require('litee.gh.pr')
local issues_preview = require('litee.gh.issues.preview')
local config       = require('litee.gh.config')

local M = {}

local state = {
    -- the buffer id where the thread is rendered
    buf = nil,
    -- a mapping between extmarks and their notification objects.
    marks_to_notifications = {}
}

local function reset_state()
    state.buf = nil
    state.notifications_to_marks = nil
end

local symbols = {
    top =    "╭",
    left =   "│",
    bottom = "╰",
    tab = "  ",
}

local ns = vim.api.nvim_create_namespace("notification_buffer")

local function _win_settings_on()
    vim.api.nvim_win_set_option(0, 'wrap', false)
    vim.api.nvim_win_set_option(0, 'number', false)
end

local function extract_issue_number(notification)
    local url = notification["subject"]["url"]
    if url == nil then
        return nil
    end
    return lib_util_path.basename(url)
end

-- comment_under_cursor uses the mapped extmarks to extract the comment under
-- the user's cursor.
local function notification_under_cursor()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local marks  = vim.api.nvim_buf_get_extmarks(0, ns, {cursor[1]-1, 0}, {-1, 0}, {
        limit = 1
    })
    if #marks == 0 then
        return
    end
    local mark = marks[1][1]
    local comment = state.marks_to_notifications[mark]
    return comment
end

local function preview_issue()
    local noti = notification_under_cursor()
    if noti == nil then
        return
    end
    local issue_number = extract_issue_number(noti)
    if issue_number == nil then
        return
    end
    issues_preview.preview_issue(issue_number)
end

local function setup_buffer()
    -- see if we can reuse a buffer that currently exists.
    if state.buf ~= nil and vim.api.nvim_buf_is_valid(state.buf) then
        return state.buf
    else
        state.buf = vim.api.nvim_create_buf(false, false)
        if state.buf == 0 then
            vim.api.nvim_err_writeln("notification_buffer: buffer create failed")
            return
        end
    end

    -- set buf options
    vim.api.nvim_buf_set_name(state.buf, "github notifications")
    vim.api.nvim_buf_set_option(state.buf, 'bufhidden', 'hide')
    vim.api.nvim_buf_set_option(state.buf, 'filetype', 'notifications')
    vim.api.nvim_buf_set_option(state.buf, 'buftype', 'nofile')
    vim.api.nvim_buf_set_option(state.buf, 'modifiable', false)
    vim.api.nvim_buf_set_option(state.buf, 'swapfile', false)
    vim.api.nvim_buf_set_option(state.buf, 'textwidth', 0)
    vim.api.nvim_buf_set_option(state.buf, 'wrapmargin', 0)
    vim.api.nvim_buf_set_option(state.buf, 'ofu', 'v:lua.GH_completion')

    vim.api.nvim_buf_set_keymap(state.buf, 'n', config.config.keymaps.open, "", {callback=M.open_notification})
    vim.api.nvim_buf_set_keymap(state.buf, 'n', config.config.keymaps.actions, "", {callback=M.notification_actions})
    vim.api.nvim_buf_set_keymap(state.buf, 'n', config.config.keymaps.details, "", {callback=preview_issue})

    vim.api.nvim_create_autocmd({"BufEnter"}, {
        buffer = state.buf,
        callback = require('litee.lib.util.window').set_tree_highlights,
    })
    vim.api.nvim_create_autocmd({"BufEnter"}, {
        buffer = state.buf,
        callback = _win_settings_on,
    })
end

function M.render_notifications(notifications)
    if state.buf == nil or not vim.api.nvim_buf_is_valid(state.buf) then
        setup_buffer()
    end
    table.sort(notifications, function(a,b)
        return a["updated_at"] > b["updated_at"]
    end)

    local marks_to_create = {}
    local buffer_lines = {}

    local repo = ghcli.get_repo_name_owner()

    -- render notification buffer header
    table.insert(buffer_lines, string.format("%s %s  Notifications", symbols.top, config.icon_set["Notification"]))
    table.insert(buffer_lines, string.format("%s %s  Owner: %s", symbols.left, config.icon_set["Account"], repo["owner"]["login"]))
    table.insert(buffer_lines, string.format("%s %s  Repo: %s", symbols.left, config.icon_set["GitRepo"], repo["name"]))
    table.insert(buffer_lines, string.format("%s %s  Count: %s", symbols.left, config.icon_set["Number"], #notifications))
    table.insert(buffer_lines, string.format("%s (open: %s)(notification actions: %s)(preview issue: %s)", symbols.bottom, config.config.keymaps.open, config.config.keymaps.actions, config.config.keymaps.details))
    -- add an extmark here associated with nil so we don't try to preview when
    -- cursor is in header.
    table.insert(marks_to_create, {#buffer_lines-1, nil})

    for _, noti in ipairs(notifications) do
        local type_ico = config.icon_set["GitIssue"]
        if noti["subject"]["type"] == "PullRequest" then
            type_ico = config.icon_set["GitPullRequest"]
        end
        local read_ico = config.icon_set["CircleFilled"]
        if noti["unread"] == false then
            read_ico = config.icon_set["Circle"]
        end
        local issue_number = extract_issue_number(noti)
        table.insert(buffer_lines, symbols.top)
        table.insert(buffer_lines, string.format("%s %s  %s  %s %s   %s", symbols.left, read_ico, type_ico, "#"..issue_number, noti["subject"]["title"], noti["reason"]))
        table.insert(buffer_lines, symbols.bottom)
        table.insert(marks_to_create, {#buffer_lines-1, noti})
    end

    -- write all buffer lines to the buffer
    M.set_modifiable(true)
    vim.api.nvim_buf_set_lines(state.buf, 0, #buffer_lines, false, buffer_lines)
    M.set_modifiable(false)

    -- write out all our marks and associate marks with noti objects.
    for _, m in ipairs(marks_to_create) do
        local id = vim.api.nvim_buf_set_extmark(
            state.buf,
            ns,
            m[1],
            0,
            {}
        )
        state.marks_to_notifications[id] = m[2]
    end

    return state.buf
end

function M.set_modifiable(bool)
    if state.buf ~= nil and vim.api.nvim_buf_is_valid(state.buf) then
        vim.api.nvim_buf_set_option(state.buf, 'modifiable', bool)
    end
end

function M.open_notification()
    local notification = notification_under_cursor()
    if notification == nil then
        return
    end
    local issue_number = extract_issue_number(notification)
    if issue_number == nil then
        return
    end
    if notification["subject"]["type"] == "Issue" then
        issues.open_issue_by_number(issue_number)
        return
    end
    if notification["subject"]["type"] == "PullRequest" then
        pr.open_pull_by_number(issue_number)
        return
    end
end

local function set_read(notification)
    local out = ghcli.set_notification_read(notification["id"])
    if out == nil then
        lib_notify.notify_popup_with_timeout("Failed to set notification as read.", 7500, "error")
        return
    end
end

local function set_unsubscribed(notification)
    local out = ghcli.set_notification_ignored(notification["id"])
    if out == nil then
        lib_notify.notify_popup_with_timeout("Failed to set unsubscribe from notification.", 7500, "error")
        return
    end
end

function M.notification_actions()
    local notification = notification_under_cursor()
    if notification == nil then
        return
    end
    vim.ui.select(
        {"read", "unsubscribe"},
        {prompt="Pick a action to perform on this comment: "},
        function(item, _)
            if item == nil then
                return
            end
            if item == "read" then
                set_read(notification)
            end
            if item == "unsubscribe" then
                set_unsubscribed(notification)
                set_read(notification)
            end
            vim.cmd("GHRefreshNotifications")
        end
    )
end

return M
