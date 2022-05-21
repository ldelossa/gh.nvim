local lib_notify    = require('litee.lib.notify')
local lib_icons     = require('litee.lib.icons')
local lib_util      = require('litee.lib.util')

local config        = require('litee.gh.config').config
local ghcli         = require('litee.gh.ghcli')
local reactions     = require('litee.gh.pr.reactions')

local M = {}

local state = {
    -- the buffer id where the pr buffer is rendered
    buf = nil,
    -- the win id where the pr buffer is rendered
    win = nil,
    -- the last recorded end of the buffer
    buffer_end = nil,
    -- the offset to the "text" area where users can write text
    text_area_off = nil,
    -- a mapping of extmarks to the thread comments they represent.
    marks_to_comments = {},
    -- set when "edit_comment()" is issued, holds the comment thats being updated
    -- until submit() is called or a new thread is rendered.
    editing_comment = nil,
    editing_issue = nil,
    -- the issue object being rendered
    issue = nil,
    -- the comments associated with the issues
    comments = nil
}

local function reset_state()
    state.thread = nil
    state.buffer_end = nil
    state.text_area_off = nil
    state.marks_to_comments = {}
    state.editing_comment = nil
    state.creating_comment = nil
end

local symbols = {
    top =    "╭",
    left =   "│",
    bottom = "╰",
    tab = "  ",
}

-- extract_text will extract text from the text area, join the lines, and shell
-- escape the content.
local function extract_text()
    -- extract text from text area
    local lines = vim.api.nvim_buf_get_lines(state.buf, state.text_area_off, -1, false)

    -- join them into a single body
    local body = vim.fn.join(lines, "\n")
    body = vim.fn.shellescape(body)
    return body, lines
end

function M.on_refresh()
    M.load_issue(state.issue["number"], vim.schedule_wrap(
        M.render_issue
    ))
end

-- namespace we'll use for extmarks that help us track comments.
local ns = vim.api.nvim_create_namespace("pr_buffer")

local function _win_settings_on()
    vim.api.nvim_win_set_option(0, "showbreak", "│")
    vim.api.nvim_win_set_option(0, 'winhighlight', 'NonText:Normal')
    vim.api.nvim_win_set_option(0, 'wrap', true)
end
local function _win_settings_off()
    vim.api.nvim_win_set_option(0, "showbreak", "")
    vim.api.nvim_win_set_option(0, 'winhighlight', 'NonText:NonText')
    vim.api.nvim_win_set_option(0, 'wrap', true)
end

-- toggle_writable will toggle the thread_buffer as modifiable
local function in_editable_area()
    local cursor = vim.api.nvim_win_get_cursor(0)
    if state.text_area_off == nil then
        return
    end
    if cursor[1] >= state.text_area_off then
        _win_settings_off()
        M.set_modifiable(true)
    else
        _win_settings_on()
        M.set_modifiable(false)
    end
end

local function setup_buffer()
    -- see if we can reuse a buffer that currently exists.
    if state.buf ~= nil and vim.api.nvim_buf_is_valid(state.buf) then
        return state.buf
    else
        state.buf = vim.api.nvim_create_buf(false, false)
        if state.buf == 0 then
            vim.api.nvim_err_writeln("thread_convo: buffer create failed")
            return
        end
    end

    -- set buf options
    vim.api.nvim_buf_set_name(state.buf, "pull request issue")
    vim.api.nvim_buf_set_option(state.buf, 'bufhidden', 'hide')
    vim.api.nvim_buf_set_option(state.buf, 'filetype', 'pr')
    vim.api.nvim_buf_set_option(state.buf, 'buftype', 'nofile')
    vim.api.nvim_buf_set_option(state.buf, 'modifiable', false)
    vim.api.nvim_buf_set_option(state.buf, 'swapfile', false)
    vim.api.nvim_buf_set_option(state.buf, 'textwidth', 0)
    vim.api.nvim_buf_set_option(state.buf, 'wrapmargin', 0)
    vim.api.nvim_buf_set_option(state.buf, 'ofu', 'v:lua.GH_completion')

    vim.api.nvim_buf_set_keymap(state.buf, 'n', "<C-s>", "", {callback=M.submit})
    vim.api.nvim_buf_set_keymap(state.buf, 'n', "<C-a>", "", {callback=M.comment_actions})

    vim.api.nvim_create_autocmd({"CursorMoved", "CursorMovedI"}, {
        buffer = state.buf,
        callback = in_editable_area,
    })
    vim.api.nvim_create_autocmd({"BufEnter"}, {
        buffer = state.buf,
        callback = _win_settings_on,
    })
    vim.api.nvim_create_autocmd({"BufWinLeave"}, {
        buffer = state.buf,
        callback = _win_settings_off,
    })
end

local function parse_comment_body(body, left_sign)
    local lines = {}
    body = vim.fn.split(body, '\n')
    for _, line in ipairs(body) do
        line = vim.fn.substitute(line, "\r", "", "g")
        line = vim.fn.substitute(line, "\n", "", "g")
        line = vim.fn.substitute(line, "\t", symbols.tab, "g")
        if left_sign then
            line = symbols.left .. line
        end
        table.insert(lines, line)
    end
    return lines
end

local function render_comment(comment)
    local icon_set = "default"
    if config.icon_set ~= nil then
        icon_set = lib_icons[config.icon_set]
    end
    local lines = {}
    local reaction_string = ""
    local author = comment["user"]["login"]
    local title = string.format("%s %s  %s", symbols.top, icon_set["Account"], author)
    table.insert(lines, title)

    table.insert(lines, symbols.left)
    for _, line in ipairs(parse_comment_body(comment["body"], true)) do
        table.insert(lines, line)
    end
    table.insert(lines, symbols.left)
    if reaction_string ~= "" then
        table.insert(lines, symbols.left .. reaction_string)
    end
    table.insert(lines, symbols.bottom)

    return lines
end

local function find_win()
    if state.buf ~= nil then
        local wins = vim.api.nvim_list_wins()
        for _, w in ipairs(wins) do
            if state.buf == vim.api.nvim_win_get_buf(w) then
                return w
            end
        end
    end
end

function M.load_issue(number, on_load, preview)
    ghcli.get_issue_async(number, function(err, data)
        if err then
            lib_notify.notify_popup_with_timeout("Failed to fetch issue.", 7500, "error")
            return
        end
        if data == nil then
            lib_notify.notify_popup_with_timeout("Failed to fetch issue.", 7500, "error")
            return
        end

        state.issue = data
        -- we do not need to load comments if we are just creating a preview
        if not preview then
            ghcli.get_issue_comments_async(number, function(err, data)
                if err then
                    lib_notify.notify_popup_with_timeout("Failed to fetch issue comments.", 7500, "error")
                    return
                end
                if data == nil then
                    lib_notify.notify_popup_with_timeout("Failed to fetch issue.", 7500, "error")
                    return
                end
                state.comments = data
                on_load()
            end)
        else
            on_load()
        end
    end)
end

function M.render_issue(preview)
    local icon_set = "default"
    if config.icon_set ~= nil then
        icon_set = lib_icons[config.icon_set]
    end
    if state.buf == nil or not vim.api.nvim_buf_is_valid(state.buf) then
        setup_buffer()
    end

    local win = find_win()
    local displayed = nil
    if
        win ~= nil
    then
            local _, text_area_lines = extract_text()
            if text_area_lines ~= nil then
                local has_content = false
                for _, l in ipairs(text_area_lines) do
                    if l ~= "" then
                        has_content = true
                    end
                end
                if not has_content then
                    text_area_lines = nil
                end
            end
            displayed = {
                win = win,
                -- cursor so we can restore position on new thread load
                cursor = vim.api.nvim_win_get_cursor(win),
                -- any in the text area so we can restore it incase the user
                -- was writing a large message and a new message came into the
                -- thread buffer.
                text_area = text_area_lines
            }
    end

    reset_state()

    -- get latest thread from s.pull_state
    local comments = state.comments

    local buffer_lines = {}

    -- truncate current buffer
    M.set_modifiable(true)
    vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, {})

    -- bookkeep the extmarks we need to create
    local marks_to_create = {}

    -- render PR header
    local type = ""
    if vim.fn.match(state.issue["node_id"], "PR_") ~= -1 then
        type = "Pull Request"
    else
        type = "Issue"
    end
    table.insert(buffer_lines, string.format("%s %s  %s %s%s", symbols.top, icon_set["GitIssue"], type, icon_set["Number"], state.issue["number"]))
    table.insert(buffer_lines, string.format("%s %s  Author: %s", symbols.left, icon_set["Account"], state.issue["user"]["login"]))
    table.insert(buffer_lines, string.format("%s %s  Created: %s", symbols.left, icon_set["Calendar"], state.issue["created_at"]))
    table.insert(buffer_lines, string.format("%s %s  Last Updated: %s", symbols.left, icon_set["Calendar"], state.issue["updated_at"]))
    table.insert(buffer_lines, string.format("%s %s  Title: %s", symbols.left, icon_set["Pencil"], state.issue["title"]))
    table.insert(buffer_lines, symbols.left)
    local body_lines = parse_comment_body(state.issue["body"], true)
    for _, l in ipairs(body_lines) do
        table.insert(buffer_lines, l)
    end
    if not preview then
        table.insert(buffer_lines, symbols.left)
        table.insert(buffer_lines, string.format("%s (ctrl-s:submit)(ctrl-a:comment actions)", symbols.bottom))
        table.insert(marks_to_create, {#buffer_lines, state.issue})
    else
        table.insert(buffer_lines, symbols.left)
        table.insert(buffer_lines, symbols.bottom)
    end

    if not preview then
        table.insert(buffer_lines, "")
        for _, c in ipairs(comments) do
            local c_lines = render_comment(c)
            for _, line in ipairs(c_lines) do
                table.insert(buffer_lines, line)
            end
            table.insert(marks_to_create, {#buffer_lines, c})
        end

        -- leave room for the user to reply.
        table.insert(buffer_lines, "")
        table.insert(buffer_lines, string.format("%s  %s", icon_set["Account"], "Add a comment below..."))
        -- record the offset to our reply message, we'll allow editing here
        state.text_area_off = #buffer_lines
        table.insert(buffer_lines, "")
    else
        state.text_area_off = #buffer_lines
    end

    -- write all our rendered comments to the buffer.
    vim.api.nvim_buf_set_lines(state.buf, 0, #buffer_lines, false, buffer_lines)

    -- write all our marks
    for _, m in ipairs(marks_to_create) do
        local id = vim.api.nvim_buf_set_extmark(
            state.buf,
            ns,
            m[1],
            0,
            {}
        )
        state.marks_to_comments[id] = m[2]
    end

    -- set some additional book keeping state.
    state.buffer_end = #buffer_lines

    if displayed ~= nil then
        -- do we have text to restore, if so write it to text area and set cursor
        -- at end.
        if
            displayed.text_area ~= nil
        then
            local new_buf_end = #buffer_lines+#displayed.text_area
            vim.api.nvim_buf_set_lines(state.buf, state.text_area_off, new_buf_end, false, displayed.text_area)
            state.buffer_end = new_buf_end
            lib_util.safe_cursor_reset(displayed.win, {new_buf_end, vim.o.columns})
            goto done
        end
        -- we have no text to disply, reset cursor to original position if safe
        lib_util.safe_cursor_reset(displayed.win, displayed.cursor)
    end

    ::done::
    M.set_modifiable(false)

    return state.buf
end

-- comment_under_cursor uses the mapped extmarks to extract the comment under
-- the user's cursor.
local function comment_under_cursor()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local marks  = vim.api.nvim_buf_get_extmarks(0, ns, {cursor[1]-1, 0}, {-1, 0}, {
        limit = 1
    })
    if #marks == 0 then
        return
    end
    local mark = marks[1][1]
    local comment = state.marks_to_comments[mark]
    return comment
end

function M.edit_iss_body(iss)
    local icon_set = "default"
    if config.icon_set ~= nil then
        icon_set = lib_icons[config.icon_set]
    end
    if iss["author_association"] ~=  "OWNER" then
        lib_notify.notify_popup_with_timeout("Cannot edit an issue you did not author.", 7500, "error")
        return
    end

    local lines = {}

    table.insert(lines, string.format("%s  %s", icon_set["Account"], "Edit the issue's body below..."))
    for _, line in ipairs(parse_comment_body(iss["body"], false)) do
        table.insert(lines, line)
    end

    M.set_modifiable(true)

    -- replace buffer lines from reply section down
    vim.api.nvim_buf_set_lines(state.buf, state.text_area_off-1, -1, false, lines)

    -- setting this to not nil will have submit() perform an "update" instead of
    -- a "reply".
    state.editing_issue = iss

    vim.api.nvim_win_set_cursor(0, {state.text_area_off+#lines-1, 0})

    M.set_modifiable(false)
end

-- find the comment at the cursor, replace the "Reply" message with an "Edit"
-- message and
function M.edit_comment()
    local icon_set = "default"
    if config.icon_set ~= nil then
        icon_set = lib_icons[config.icon_set]
    end
    local comment = comment_under_cursor()
    if comment == nil then
        return
    end

    local lines = {}

    if comment["author_association"] ~=  "OWNER" then
        lib_notify.notify_popup_with_timeout("Cannot edit a comment you did not author.", 7500, "error")
        return
    end

    table.insert(lines, string.format("%s  %s", icon_set["Account"], "Edit the message below..."))
    for _, line in ipairs(parse_comment_body(comment["body"], false)) do
        table.insert(lines, line)
    end

    M.set_modifiable(true)

    -- replace buffer lines from reply section down
    vim.api.nvim_buf_set_lines(state.buf, state.text_area_off-1, -1, false, lines)

    -- setting this to not nil will have submit() perform an "update" instead of
    -- a "reply".
    state.editing_comment = comment

    vim.api.nvim_win_set_cursor(0, {state.text_area_off+#lines-1, 0})

    M.set_modifiable(false)
end


function M.set_modifiable(bool)
    if state.buf ~= nil and vim.api.nvim_buf_is_valid(state.buf) then
        vim.api.nvim_buf_set_option(state.buf, 'modifiable', bool)
    end
end

-- update will update the text of the comment present in state.editing_comment
-- and then reset that field to nil.
local function update(body)
    local out = ghcli.update_pull_issue_comment(state.editing_comment["id"], body)
    if out == nil then
        return nil
    end
    return out
end

local function update_iss_body(body)
    local out = ghcli.update_issue_body_async(state.issue["number"], body, function(err, _)
        if err then
            vim.schedule(function() lib_notify.notify_popup_with_timeout("Failed to update issue body: " .. err, 7500, "error") end)
            return
        end

        -- dump the current text before we refresh, or else itll be restored.
        vim.schedule(function ()
            M.set_modifiable(true)
            vim.api.nvim_buf_set_lines(state.buf, state.text_area_off, -1, false, {})
            M.set_modifiable(false)
        end)

        -- TODO rerender
        M.on_refresh()

        state.editing_issue = nil
    end)
    return out
end

local function create(body)
    local out = ghcli.create_pull_issue_comment(state.issue["number"], body)
    if out == nil then
        return nil
    end
    return out
end

function M.delete_comment()
    local comment = comment_under_cursor()
    if comment == nil then
        return
    end
    vim.ui.select(
        {"no", "yes"},
        {prompt="Are you use you want to delete this comment? "},
        function(_, idx)
            if
                idx == nil or
                idx == 1
            then
                return
            end

            local out = ghcli.delete_pull_issue_comment(comment["id"])
            if out == nil then
                lib_notify.notify_popup_with_timeout("Failed to delete comment.", 7500, "error")
                return
            end

            -- re-render thread buffer
            M.on_refresh()
        end
    )
end

-- submit submits the latest changes in the thread buffer to the Github API.
function M.submit()
    -- do not allow a submit unless we are literally in the thread_buffer.
    if vim.api.nvim_get_current_buf() ~= state.buf then
        return
    end

    local body = extract_text()
    if vim.fn.strlen(body) == 0 then
        return
    end

    if state.editing_comment ~= nil then
       local out = update(body)
       if out == nil then
          lib_notify.notify_popup_with_timeout("Failed to update issue comment.", 7500, "error")
       end
       state.editing_comment = nil
    elseif state.editing_issue ~= nil then
       -- TODO
       -- update_pr_body is async, so any follow up work is done in a callback.
       local out = update_iss_body(body)
       return
    else
       local out = create(body)
       if out == nil then
          lib_notify.notify_popup_with_timeout("Failed to create issue comment.", 7500, "error")
          return
       end
    end

    -- refresh
    M.on_refresh()

    M.set_modifiable(true)
    vim.api.nvim_buf_set_lines(state.buf, state.text_area_off, -1, false, {})
    M.set_modifiable(false)
end

function M.comment_actions()
    comment = comment_under_cursor()
    if comment == nil then
        return
    end
    vim.ui.select(
        {"edit", "delete", "react"},
        {prompt="Pick a action to perform on this comment: "},
        function(item, _)
            if item == nil then
                return
            end
            -- if it has a number field, its the comment is actuall the pr
            if item == "edit" and comment["number"] ~= nil then
                M.edit_iss_body(comment)
                return
            end
            if item == "edit" then
                M.edit_comment()
                return
            end
            if item == "delete" then
                M.delete_comment()
                return
            end
            if item == "react" then
                M.reaction()
                return
            end
        end
    )
end

return M
