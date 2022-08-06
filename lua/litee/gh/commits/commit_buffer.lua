local lib_util      = require('litee.lib.util')

local ghcli         = require('litee.gh.ghcli')
local lib_notify    = require('litee.lib.notify')
local reactions     = require('litee.gh.pr.reactions')
local config        = require('litee.gh.config')
local issues        = require('litee.gh.issues')

local M = {}

local symbols = {
    tab = "  ",
}

M.state_by_sha = {}
M.state_by_buf = {}

function M.on_refresh()
    for sha, _ in pairs(M.state_by_sha) do
        M.load_commit(sha,
           function() M.render_commit(sha) end
        )
    end
end

local function new_commit_state()
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
        -- the commit object being rendered
        commit = nil,
        -- the comments associated with the commit
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

-- load_commit will asynchronously load the commit identified by its sha with
-- on_load() once done.
function M.load_commit(sha, on_load)
    ghcli.get_commit_async(sha, function(err, commit_data)
        if err then
            lib_notify.notify_popup_with_timeout("Failed to fetch commit.", 7500, "error")
            return
        end
        if commit_data == nil then
            lib_notify.notify_popup_with_timeout("Failed to fetch commit.", 7500, "error")
            return
        end

        local state = M.state_by_sha[sha]
        if state == nil then
            state = new_commit_state()
        end

        ghcli.get_commit_comments_async(sha, function(err, comments_data)
            if err then
                lib_notify.notify_popup_with_timeout("Failed to fetch commit comments.", 7500, "error")
                return
            end
            if comments_data == nil then
                lib_notify.notify_popup_with_timeout("Failed to fetch commit.", 7500, "error")
                return
            end
            state.comments = comments_data
            state.commit = commit_data
            M.state_by_sha[sha] = state
            on_load()
        end)
    end)
end

local function _win_settings_on()
    vim.api.nvim_win_set_option(0, 'winhighlight', 'NonText:Normal')
    vim.api.nvim_win_set_option(0, 'wrap', true)
    vim.api.nvim_win_set_option(0, 'colorcolumn', "0")
    vim.api.nvim_win_set_option(0, 'cursorline', false)
end
local function _win_settings_off()
    vim.api.nvim_win_set_option(0, 'winhighlight', 'NonText:NonText')
    vim.api.nvim_win_set_option(0, 'wrap', true)
    vim.api.nvim_win_set_option(0, 'colorcolumn', "0")
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

-- load_commit must be called before a buffer can be setup for the commit.
local function setup_buffer(sha)
    if M.state_by_sha[sha] == nil then
        return nil
    end

    -- if we have a buffer for this sha just return it.
    local buf_name = "commit://" .. sha
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_get_name(b) == buf_name then
            return b
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

    vim.api.nvim_buf_set_keymap(buf, 'n', config.config.keymaps.submit_comment, "", {callback=M.submit})
    vim.api.nvim_buf_set_keymap(buf, 'n', config.config.keymaps.actions, "", {callback=M.comment_actions})
    if not config.disable_keymaps then
        vim.api.nvim_buf_set_keymap(buf, 'n', config.config.keymaps.goto_issue, "", {callback=issues.open_issue_under_cursor})
    end

    vim.api.nvim_create_autocmd({"CursorMoved", "CursorMovedI"}, {
        buffer = buf,
        callback = function () in_editable_area(M.state_by_sha[sha]) end,
    })
    vim.api.nvim_create_autocmd({"CursorHold"}, {
        buffer = buf,
        callback = issues.preview_issue_under_cursor
    })
    vim.api.nvim_create_autocmd({"BufEnter"}, {
        buffer = buf,
        callback = require('litee.lib.util.window').set_tree_highlights,
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

local function map_reactions(comment)
    local reaction_string = ""
    for text, count in pairs(comment.reactions) do
        -- do this lookup first, since not all keys in the comment.reactions map
        -- are emojis (such as url, and total_count).
        local emoji = reactions.reaction_lookup(text)
        if emoji ~= nil then
            if tonumber(count) > 0 then
                reaction_string = reaction_string .. emoji .. count .. " "
            end
        end
    end
    return reaction_string
end

local function render_comment(comment)
    local lines = {}
    local reaction_string = map_reactions(comment)
    local author = comment["user"]["login"]
    local title = string.format("%s %s commented on %s ", config.icon_set["Account"], author, comment["updated_at"])
    table.insert(lines, title)

    table.insert(lines, "")
    for _, line in ipairs(parse_comment_body(comment["body"], false)) do
        table.insert(lines, line)
    end
    if reaction_string ~= "" then
        table.insert(lines, "")
        table.insert(lines, reaction_string)
    end

    return lines
end

local function restore_draft(state)
    -- get cursor to restore if possible
    local cursor = nil
    if
        state.win ~= nil and
        vim.api.nvim_win_is_valid(state.win)
    then
        cursor = vim.api.nvim_win_get_cursor(state.win)
    end

    -- extract any text which may be in the commit's states text field
    if state.buf == nil or state.text_area_off == nil then
        return function(_)
            -- reset the cursor if we can.
            if cursor ~= nil then
                lib_util.safe_cursor_reset(state.win, cursor)
            end
        end
    end
    local lines = vim.api.nvim_buf_get_lines(state.buf, state.text_area_off, -1, false)
    local body = vim.fn.join(lines, "\n")
    body = vim.fn.shellescape(body)

    -- determine if text lines have content
    local has_content = false
    for _, l in ipairs(lines) do
        if l ~= "" then
            has_content = true
        end
    end

    -- if has no content, nothing to restore return just a cursor reset
    if not has_content then
        return function(_)
            if cursor ~= nil then
                lib_util.safe_cursor_reset(state.win, cursor)
            end
        end
    end

    -- if there is content, return a function which, given the new state,
    -- restores text and cursor
    return function(s)
        local buffer_lines = vim.api.nvim_buf_line_count(s.buf)
        local new_buf_end = buffer_lines+#lines
        M.set_modifiable(true, s.buf)
        vim.api.nvim_buf_set_lines(s.buf, s.text_area_off, new_buf_end, false, lines)
        M.set_modifiable(false, s.buf)
        s.buffer_end = new_buf_end
        lib_util.safe_cursor_reset(s.win, {new_buf_end, vim.o.columns})
    end
end

-- render_commit will return a buffer of the commit and set the commit state's
-- buffer field
function M.render_commit(sha)
    local state = M.state_by_sha[sha]
    if state == nil then
        return
    end

    local buf = setup_buffer(sha)
    state.buf = buf

    local restore = restore_draft(state)

    local comments = state.comments
    local buffer_lines = {}

    -- bookkeep the extmarks we need to create
    local marks_to_create = {}
    local lines_to_highlight = {}

    -- render PR header
    local hi = config.config.highlights["thread_separator"]
    table.insert(buffer_lines, string.format("%s  %s",  config.icon_set["GitCommit"], state.commit["sha"]))
    table.insert(lines_to_highlight, {#buffer_lines, hi})
    table.insert(buffer_lines, string.format("%s  Author: %s",  config.icon_set["Account"], state.commit["author"]["login"]))
    table.insert(lines_to_highlight, {#buffer_lines, hi})
    table.insert(buffer_lines, string.format("%s  Commiter: %s",  config.icon_set["Account"], state.commit["committer"]["login"]))
    table.insert(lines_to_highlight, {#buffer_lines, hi})
    table.insert(buffer_lines, string.format("%s  Created: %s",  config.icon_set["Calendar"], state.commit["commit"]["committer"]["date"]))
    table.insert(lines_to_highlight, {#buffer_lines, hi})
    table.insert(buffer_lines, "")
    table.insert(lines_to_highlight, {#buffer_lines, hi})
    local body_lines = parse_comment_body(state.commit["commit"]["message"], false)
    for _, l in ipairs(body_lines) do
        table.insert(buffer_lines, l)
        table.insert(lines_to_highlight, {#buffer_lines, hi})
    end
    table.insert(buffer_lines, "")
    table.insert(lines_to_highlight, {#buffer_lines, hi})
    table.insert(buffer_lines, string.format("(submit: %s)(comment actions: %s)",  config.config.keymaps.submit_comment, config.config.keymaps.actions))
    table.insert(lines_to_highlight, {#buffer_lines, hi})
    table.insert(marks_to_create, {#buffer_lines, state.commit})

    table.insert(buffer_lines, "")
    for i, c in ipairs(comments) do
        if i % 2 == 0 then
            hi = config.config.highlights["thread_separator"]
        else
            hi = config.config.highlights["thread_separator_alt"]
        end
        local c_lines = render_comment(c)
        for _, line in ipairs(c_lines) do
            table.insert(buffer_lines, line)
            table.insert(lines_to_highlight, {#buffer_lines, hi})
        end
        table.insert(marks_to_create, {#buffer_lines, c})
        table.insert(buffer_lines, "")
    end

    -- leave room for the user to reply.
    table.insert(buffer_lines, "")
    table.insert(buffer_lines, string.format("%s  %s", config.icon_set["Account"], "Add a comment below..."))

    -- record the offset to our reply message, we'll allow editing here
    state.text_area_off = #buffer_lines
    table.insert(buffer_lines, "")

    M.set_modifiable(true, buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
    vim.api.nvim_buf_set_lines(buf, 0, #buffer_lines, false, buffer_lines)
    M.set_modifiable(false, buf)

    state.ns = vim.api.nvim_create_namespace("commit-" .. sha)
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

    -- marks to create highlighted separators
    state.hi_ns = vim.api.nvim_create_namespace("commit-highlights-" .. sha)
    for _, l in ipairs(lines_to_highlight) do
        vim.api.nvim_buf_set_extmark(
            state.buf,
            state.hi_ns,
            l[1]-1,
            0,
            {
                line_hl_group = l[2]
            }
        )
    end

    M.state_by_buf[buf] = state

    restore(state)

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
    local out = ghcli.create_commit_comment(state.commit["sha"], body)
    if out == nil then
        return nil
    end
    return out
end

-- update will update the text of the comment present in state.editing_comment
-- and then reset that field to nil.
local function update(state, body)
    local out = ghcli.update_commit_comment(state.editing_comment["id"], body)
    if out == nil then
        return nil
    end
    return out
end

function M.edit_comment()
    local state = M.state_by_buf[vim.api.nvim_get_current_buf()]
    if state == nil then
        return
    end

    local comment = comment_under_cursor()
    if comment == nil then
        return
    end

    local lines = {}

    local user = ghcli.get_cached_user()
    if user == nil then
        lib_notify.notify_popup_with_timeout("Could not retrieve gh user.", 7500, "error")
        return
    end
    local user_comment = comment["user"]["login"]

    if user["login"] ~= user_comment then
        lib_notify.notify_popup_with_timeout("Cannot edit a comment you did not author.", 7500, "error")
        return
    end

    table.insert(lines, string.format("%s  %s", config.icon_set["Account"], "Edit the message below..."))
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
            local out = ghcli.delete_commit_comment(comment["id"])
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
          lib_notify.notify_popup_with_timeout("Failed to update commit comment.", 7500, "error")
       end
       state.editing_comment = nil
    else
       local out = create(state, body)
       if out == nil then
          lib_notify.notify_popup_with_timeout("Failed to create commit comment.", 7500, "error")
          return
       end
    end

    M.set_modifiable(true)
    vim.api.nvim_buf_set_lines(state.buf, state.text_area_off, -1, false, {})
    M.set_modifiable(false)

    M.on_refresh()
end

function M.reaction()
    local comment = comment_under_cursor()
    if comment == nil then
        return
    end
    vim.ui.select(
        reactions.reaction_names,
        {
            prompt = "Select a reaction: ",
            format_item = function(item)
                return reactions.reaction_map[item] .. " " .. item
            end
        },
        function(item, idx)
            local user = ghcli.get_cached_user()
            if user == nil then
                 lib_notify.notify_popup_with_timeout("Failed to get user.", 7500, "error")
                 return
            end
            -- get the reactions for this comment, search for our user name, if
            -- the reaction exists, delete it, otherwise, create it.
            local emoji_to_set = reactions.reaction_map[item]
            ghcli.get_commit_reactions_async(comment["id"], function (err, data)
                if err then
                     if err then
                         lib_notify.notify_popup_with_timeout("Failed to get comment reactions.", 7500, "error")
                         return
                     end
                end
                local reaction_exists = false
                for _, reaction in ipairs(data) do
                    if reaction["user"]["login"] == user["login"] then
                        local emoji = reactions.reaction_lookup(reaction["content"])
                        if emoji == emoji_to_set then
                            reaction_exists = true
                        end
                    end
                end
                if reaction_exists then
                     ghcli.remove_reaction_async(comment["node_id"], reactions.reaction_names[idx], vim.schedule_wrap(function(err, data)
                         if err then
                             lib_notify.notify_popup_with_timeout("Failed to add reaction.", 7500, "error")
                             return
                         end
                         if data == nil then
                             lib_notify.notify_popup_with_timeout("Failed to add reaction.", 7500, "error")
                             return
                         end
                         M.on_refresh()
                     end))
                else
                     ghcli.add_reaction(comment["node_id"], reactions.reaction_names[idx], vim.schedule_wrap(function(err, data)
                         if err then
                             lib_notify.notify_popup_with_timeout("Failed to add reaction.", 7500, "error")
                             return
                         end
                         if data == nil then
                             lib_notify.notify_popup_with_timeout("Failed to add reaction.", 7500, "error")
                             return
                         end
                         M.on_refresh()
                     end))
                end
            end)
        end
    )
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

function M.set_modifiable(bool, buf)
    if buf ~= nil and vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_set_option(buf, 'modifiable', bool)
    end
end

return M
