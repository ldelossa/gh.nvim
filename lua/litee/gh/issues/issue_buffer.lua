local lib_icons     = require('litee.lib.icons')
local lib_path      = require('litee.lib.util.path')

local ghcli         = require('litee.gh.ghcli')
local lib_notify    = require('litee.lib.notify')
local config        = require('litee.gh.config').config

local M = {}

local symbols = {
    top =    "╭",
    left =   "│",
    bottom = "╰",
    tab = "  ",
}

M.state_by_number = {}
M.state_by_buf = {}

local callbacks = {}

function M.set_callbacks(cbs)
    callbacks = cbs
end

function M.on_refresh(state)
    for issue, _ in pairs(M.state_by_number) do
        M.load_issue(issue,
           function() M.render_issue(issue) end
        )
    end
end

local function new_issue_state()
    return {
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
        comments = nil,
        -- namespace for extmarks
        ns = nil
    }
end

-- comment_under_cursor uses the mapped extmarks to extract the comment under
-- the user's cursor.
local function comment_under_cursor()
    local state = M.state_by_buf[vim.api.nvim_get_current_buf()]
    if state == nil then
        return
    end
    local cursor = vim.api.nvim_win_get_cursor(0)
    local marks  = vim.api.nvim_buf_get_extmarks(0, state.ns, {cursor[1]-1, 0}, {-1, 0}, {
        limit = 1
    })
    if #marks == 0 then
        return
    end
    local mark = marks[1][1]
    local comment = state.marks_to_comments[mark]
    return comment
end

-- load issue will asynchronously load the issue identified by its number with
-- not hash sign and call on_load() once done.
function M.load_issue(number, on_load, preview)
    ghcli.get_issue_async(number, function(err, issue_data)
        if err then
            lib_notify.notify_popup_with_timeout("Failed to fetch issue.", 7500, "error")
            return
        end
        if issue_data == nil then
            lib_notify.notify_popup_with_timeout("Failed to fetch issue.", 7500, "error")
            return
        end

        local state = nil
        if M.state_by_number[number] ~= nil then
            state = M.state_by_number[number]
        else
            state = new_issue_state()
        end

        -- we do not need to load comments if we are just creating a preview
        if not preview then
            ghcli.get_issue_comments_async(number, function(err, comments_data)
                if err then
                    lib_notify.notify_popup_with_timeout("Failed to fetch issue comments.", 7500, "error")
                    return
                end
                if comments_data == nil then
                    lib_notify.notify_popup_with_timeout("Failed to fetch issue.", 7500, "error")
                    return
                end
                state.comments = comments_data
                state.issue = issue_data
                M.state_by_number[number] = state
                on_load()
            end)
        else
            state.issue = issue_data
            M.state_by_number[number] = state
            on_load()
        end
    end)
end

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

local function in_editable_area(state)
    local cursor = vim.api.nvim_win_get_cursor(0)
    if state.text_area_off == nil then
        return
    end
    if cursor[1] >= state.text_area_off then
        _win_settings_off()
        M.set_modifiable(true, state.buf)
    else
        _win_settings_on()
        M.set_modifiable(false, state.buf)
    end
end

-- load_issue must be called before a buffer can be setup for the issue number.
local function setup_buffer(number, preview)
    if M.state_by_number[number] == nil then
        return nil
    end


    local buf_name = ""
    if preview then
        buf_name = "issue #" .. number .. " preview"
    else
        buf_name = "issue #" .. number
    end

    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if lib_path.basename(vim.api.nvim_buf_get_name(b)) == buf_name then
            vim.api.nvim_buf_delete(b, {force=true})
        end
    end

    local buf = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_buf_set_name(buf, buf_name)
    vim.api.nvim_buf_set_option(buf, 'bufhidden', 'hide')
    vim.api.nvim_buf_set_option(buf, 'filetype', 'pr')
    vim.api.nvim_buf_set_option(buf, 'buftype', 'nofile')
    vim.api.nvim_buf_set_option(buf, 'modifiable', false)
    vim.api.nvim_buf_set_option(buf, 'swapfile', false)
    vim.api.nvim_buf_set_option(buf, 'textwidth', 0)
    vim.api.nvim_buf_set_option(buf, 'wrapmargin', 0)
    vim.api.nvim_buf_set_option(buf, 'ofu', 'v:lua.GH_completion')

    vim.api.nvim_buf_set_keymap(buf, 'n', config.keymaps.submit_comment, "", {callback=M.submit})
    vim.api.nvim_buf_set_keymap(buf, 'n', config.keymaps.actions, "", {callback=M.comment_actions})
    if not config.disable_keymaps then
        vim.api.nvim_buf_set_keymap(buf, 'n', config.keymaps.goto_issue, "", {callback=callbacks["goto_cb"]})
    end

    vim.api.nvim_create_autocmd({"CursorMoved", "CursorMovedI"}, {
        buffer = buf,
        callback = function () in_editable_area(M.state_by_number[number]) end,
    })
    vim.api.nvim_create_autocmd({"BufEnter"}, {
        buffer = buf,
        callback = _win_settings_on,
    })
    vim.api.nvim_create_autocmd({"BufWinLeave"}, {
        buffer = buf,
        callback = _win_settings_off,
    })
    vim.api.nvim_create_autocmd({"CursorHold"}, {
        buffer = buf,
        callback = callbacks["preview_cb"]
    })
    return buf
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

-- render_issue will return a buffer of the issue and set the issue state's
-- buffer field
function M.render_issue(number, preview)
    local icon_set = "default"
    if config.icon_set ~= nil then
        icon_set = lib_icons[config.icon_set]
    end

    local state = M.state_by_number[number]
    if state == nil then
        return
    end

    local buf = nil
    if preview then
        buf = setup_buffer(number, preview)
    else
        state.buf = setup_buffer(number)
        buf = state.buf
    end

    local comments = state.comments
    local buffer_lines = {}

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
        table.insert(buffer_lines, string.format("%s (submit: %s)(comment actions: %s)", symbols.bottom, config.keymaps.submit_comment, config.keymaps.actions))
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

    M.set_modifiable(true, buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
    vim.api.nvim_buf_set_lines(buf, 0, #buffer_lines, false, buffer_lines)
    M.set_modifiable(false, buf)

    state.ns = vim.api.nvim_create_namespace("issue-" .. number)
    if not preview then
        for _, m in ipairs(marks_to_create) do
            local id = vim.api.nvim_buf_set_extmark(
                buf,
                state.ns,
                m[1],
                0,
                {}
            )
            state.marks_to_comments[id] = m[2]
        end
        state.buffer_end = #buffer_lines
        M.state_by_buf[state.buf] = state
    end

    return buf
end

local function extract_text(state)
    -- extract text from text area
    local lines = vim.api.nvim_buf_get_lines(state.buf, state.text_area_off, -1, false)
    -- join them into a single body
    local body = vim.fn.join(lines, "\n")
    body = vim.fn.shellescape(body)
    return body, lines
end

local function create(state, body)
    local out = ghcli.create_pull_issue_comment(state.issue["number"], body)
    if out == nil then
        return nil
    end
    return out
end

-- update will update the text of the comment present in state.editing_comment
-- and then reset that field to nil.
local function update(state, body)
    local out = ghcli.update_pull_issue_comment(state.editing_comment["id"], body)
    if out == nil then
        return nil
    end
    return out
end

local function update_iss_body(state, body)
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

        M.on_refresh()

        state.editing_issue = nil
    end)
    return out
end

function M.edit_iss_body(iss)
    local icon_set = "default"
    if config.icon_set ~= nil then
        icon_set = lib_icons[config.icon_set]
    end

    local state = M.state_by_buf[vim.api.nvim_get_current_buf()]
    if state == nil then
        return
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

function M.edit_comment()
    local icon_set = "default"
    if config.icon_set ~= nil then
        icon_set = lib_icons[config.icon_set]
    end

    local state = M.state_by_buf[vim.api.nvim_get_current_buf()]
    if state == nil then
        return
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

    -- replace buffer lines from reply section down
    M.set_modifiable(true, state.buf)
    vim.api.nvim_buf_set_lines(state.buf, state.text_area_off-1, -1, false, lines)
    M.set_modifiable(false, state.buf)

    -- setting this to not nil will have submit() perform an "update" instead of
    -- a "reply".
    state.editing_comment = comment

    vim.api.nvim_win_set_cursor(0, {state.text_area_off+#lines-1, 0})

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
            M.on_refresh()
        end
    )
end

function M.submit()
    local state = M.state_by_buf[vim.api.nvim_get_current_buf()]
    if state == nil then
        return
    end

    local body = extract_text(state)
    if vim.fn.strlen(body) == 0 then
        return
    end

    if state.editing_comment ~= nil then
       local out = update(state, body)
       if out == nil then
          lib_notify.notify_popup_with_timeout("Failed to update issue comment.", 7500, "error")
       end
       state.editing_comment = nil
    elseif state.editing_issue ~= nil then
       local out = update_iss_body(body)
       return
    else
       local out = create(state, body)
       if out == nil then
          lib_notify.notify_popup_with_timeout("Failed to create issue comment.", 7500, "error")
          return
       end
    end

    M.on_refresh()

    M.set_modifiable(true)
    vim.api.nvim_buf_set_lines(state.buf, state.text_area_off, -1, false, {})
    M.set_modifiable(false)
end

function M.comment_actions()
    local state = M.state_by_buf[vim.api.nvim_get_current_buf()]
    if state == nil then
        return
    end

    local comment = comment_under_cursor()
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
        end
    )
end

function M.set_modifiable(bool, buf)
    if buf ~= nil and vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_set_option(buf, 'modifiable', bool)
    end
end

return M
