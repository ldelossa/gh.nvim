local lib_notify    = require('litee.lib.notify')
local lib_icons     = require('litee.lib.icons')
local lib_util      = require('litee.lib.util')

local config        = require('litee.gh.config').config
local ghcli         = require('litee.gh.ghcli')
local s             = require('litee.gh.pr.state')
local reactions     = require('litee.gh.pr.reactions')
local helpers       = require('litee.gh.helpers')

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
}

local function reset_state()
    state.thread = nil
    state.buffer_end = nil
    state.text_area_off = nil
    state.marks_to_comments = {}
    state.editing_comment = nil
    state.creating_comment = nil
end

local icon_set = {}
if config.icon_set ~= nil then
    icon_set = lib_icons[config.icon_set]
end

local symbols = {
    top =    "╭",
    left =   "│",
    bottom = "╰",
    tab = "  ",
    author =  icon_set["Account"]
}

local function comment_rest_id(comment)
    -- extract rest_id from comment, you can get this from the last portion
    -- of url.
    local rest_id = ""
    local sep = "-"
    for i in string.gmatch(comment.issue_comment["url"], "([^"..sep.."]+)") do
       rest_id = i
    end
    return rest_id
end

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
    M.render_comments()
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
    vim.api.nvim_buf_set_name(state.buf, "pull request comments")
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
    if not config.disable_keymaps then
        vim.api.nvim_buf_set_keymap(state.buf, 'n', config.keymaps.goto_issue, "", {callback=helpers.open_issue_under_cursor})
    end

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
    vim.api.nvim_create_autocmd({"CursorHold"}, {
        buffer = state.buf,
        callback = helpers.preview_issue_under_cursor,
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

local function count_reactions(comment)
    local counts = {}
    local user_reactions = {}
    for _, r in ipairs(comment.issue_comment["reactions"]["edges"]) do
        r = r["node"]

        if r["user"]["login"] == s.pull_state.user["login"] then
            user_reactions[r["content"]] = true
        end

        if counts[r["content"]] == nil then
            counts[r["content"]] = 1
        else
            counts[r["content"]] = counts[r["content"]] + 1
        end
    end
    return counts, user_reactions
end

local function render_comment(comment)
    local lines = {}
    local reaction_lines = count_reactions(comment)
    local reaction_string = ""
    for r, count in pairs(reaction_lines) do
        reaction_string = reaction_string .. reactions.reaction_map[r] .. count .. " "
    end

    local author = comment.issue_comment["author"]["login"]
    local title = string.format("%s %s  %s", symbols.top, symbols.author, author)
    table.insert(lines, title)

    table.insert(lines, symbols.left)
    for _, line in ipairs(parse_comment_body(comment.issue_comment["body"], true)) do
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

function M.render_comments()
    if state.buf == nil or not vim.api.nvim_buf_is_valid(state.buf) then
        setup_buffer()
    end

    local win = find_win()
    local displayed = nil
    if
        win ~= nil
        and vim.api.nvim_win_is_valid(win)
        and state.buf ~= nil
        and vim.api.nvim_buf_is_valid(state.buf)
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
    local comments = s.pull_state.issue_comments

    local buffer_lines = {}

    -- truncate current buffer
    M.set_modifiable(true)
    vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, {})

    -- bookkeep the extmarks we need to create
    local marks_to_create = {}

    -- render PR header
    table.insert(buffer_lines, string.format("%s %s  Pull Request %s%s", symbols.top, icon_set["GitPullRequest"], icon_set["Number"], s.pull_state["number"]))
    table.insert(buffer_lines, string.format("%s %s  Author: %s", symbols.left, icon_set["Account"], s.pull_state.pr_raw["user"]["login"]))
    table.insert(buffer_lines, string.format("%s %s  Created: %s", symbols.left, icon_set["Calendar"], s.pull_state.pr_raw["created_at"]))
    table.insert(buffer_lines, string.format("%s %s  Last Updated: %s", symbols.left, icon_set["Calendar"], s.pull_state.pr_raw["updated_at"]))
    table.insert(buffer_lines, string.format("%s %s  Title: %s", symbols.left, icon_set["Pencil"], s.pull_state.pr_raw["title"]))
    table.insert(buffer_lines, symbols.left)
    local body_lines = parse_comment_body(s.pull_state.pr_raw["body"], true)
    for _, l in ipairs(body_lines) do
        table.insert(buffer_lines, l)
    end
    table.insert(buffer_lines, symbols.left)
    table.insert(buffer_lines, string.format("%s (ctrl-s:submit)(ctrl-a:comment actions)", symbols.bottom))
    table.insert(marks_to_create, {#buffer_lines, s.pull_state.pr_raw})
    table.insert(buffer_lines, "")

    -- local reply_comments = root_comment["children"]
    for _, c in ipairs(comments) do
        local c_lines = render_comment(c)
        for _, line in ipairs(c_lines) do
            table.insert(buffer_lines, line)
        end
        table.insert(marks_to_create, {#buffer_lines, c})
    end

    -- leave room for the user to reply.
    table.insert(buffer_lines, "")
    table.insert(buffer_lines, string.format("%s  %s", symbols.author, "Add a comment below..."))
    -- record the offset to our reply message, we'll allow editing here
    state.text_area_off = #buffer_lines
    table.insert(buffer_lines, "")

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

function M.edit_pr_body(pr)
    if pr["author_association"] ~=  "OWNER" then
        lib_notify.notify_popup_with_timeout("Cannot edit a pull request you did not author.", 7500, "error")
        return
    end

    local lines = {}

    table.insert(lines, string.format("%s  %s", symbols.author, "Edit the pull request's body below..."))
    for _, line in ipairs(parse_comment_body(pr["body"], false)) do
        table.insert(lines, line)
    end

    M.set_modifiable(true)

    -- replace buffer lines from reply section down
    vim.api.nvim_buf_set_lines(state.buf, state.text_area_off-1, -1, false, lines)

    -- setting this to not nil will have submit() perform an "update" instead of
    -- a "reply".
    state.editing_pr = pr

    vim.api.nvim_win_set_cursor(0, {state.text_area_off+#lines-1, 0})

    M.set_modifiable(false)
end

-- find the comment at the cursor, replace the "Reply" message with an "Edit"
-- message and
function M.edit_comment()
    local comment = comment_under_cursor()
    if comment == nil then
        return
    end

    local lines = {}

    if not comment.issue_comment["viewerDidAuthor"] then
        lib_notify.notify_popup_with_timeout("Cannot edit a comment you did not author.", 7500, "error")
        return
    end

    table.insert(lines, string.format("%s  %s", symbols.author, "Edit the message below..."))
    for _, line in ipairs(parse_comment_body(comment.issue_comment["body"], false)) do
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
    local comment_id = comment_rest_id(state.editing_comment)
    local out = ghcli.update_pull_issue_comment(comment_id, body)
    if out == nil then
        return nil
    end
    return out
end

local function update_pr_body(body)
    local out = ghcli.update_pull_body_async(s.pull_state.number, body, function(err, _)
        if err ~= nil then
            vim.schedule(function() lib_notify.notify_popup_with_timeout("Failed to update pull request body.", 7500, "error") end)
            return
        end

        -- dump the current text before we refresh, or else itll be restored.
        vim.schedule(function ()
            M.set_modifiable(true)
            vim.api.nvim_buf_set_lines(state.buf, state.text_area_off, -1, false, {})
            M.set_modifiable(false)
        end)

        vim.schedule(function() vim.cmd("GHRefreshPR") end)
        vim.schedule(function() vim.cmd("GHRefreshComments") end)
        state.editing_pr = nil
    end)
    return out
end

-- reply will creates a new reply comment to the root comment in a threaded
-- conversation
local function create(body)
    local out = ghcli.create_pull_issue_comment(s.pull_state["number"], body)
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
    local comment_id = comment_rest_id(comment)

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

            local out = ghcli.delete_pull_issue_comment(comment_id)
            if out == nil then
                lib_notify.notify_popup_with_timeout("Failed to delete comment.", 7500, "error")
                return
            end

            -- perform global refresh of our pr state to update comments
            vim.cmd("GHRefreshComments")

            -- re-render thread buffer
            M.render_comments()
        end
    )
end

function M.reaction()
    local comment = comment_under_cursor()
    if comment == nil then
        return
    end
    local items = {}
    local _, user_reactions = count_reactions(comment)
    for name, icon in pairs(reactions.reaction_map) do
        table.insert(items, icon .. " " .. name)
    end
    vim.ui.select(
        reactions.reaction_names,
        {
            prompt = "Select a reaction: ",
            format_item = function(item)
                return reactions.reaction_map[item] .. " " .. item
            end
        },
        function(_, idx)
            if user_reactions[reactions.reaction_names[idx]] == true then
                ghcli.remove_reaction_async(comment.issue_comment["id"], reactions.reaction_names[idx], vim.schedule_wrap(function(err, data)
                    if err then
                        lib_notify.notify_popup_with_timeout("Failed to add reaction.", 7500, "error")
                        return
                    end
                    if data == nil then
                        lib_notify.notify_popup_with_timeout("Failed to add reaction.", 7500, "error")
                        return
                    end
                    vim.cmd("GHRefreshComments")
                end))
            else
                ghcli.add_reaction(comment.issue_comment["id"], reactions.reaction_names[idx], vim.schedule_wrap(function(err, data)
                    if err then
                        lib_notify.notify_popup_with_timeout("Failed to add reaction.", 7500, "error")
                        return
                    end
                    if data == nil then
                        lib_notify.notify_popup_with_timeout("Failed to add reaction.", 7500, "error")
                        return
                    end
                    vim.cmd("GHRefreshComments")
                end))
            end
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
          lib_notify.notify_popup_with_timeout("Failed to update pull request comment.", 7500, "error")
       end
       state.editing_comment = nil
       return
    elseif state.editing_pr ~= nil then
       -- update_pr_body is async, so any follow up work is done in a callback.
       local out = update_pr_body(body)
       return
    else
       local out = create(body)
       if out == nil then
          lib_notify.notify_popup_with_timeout("Failed to create pull request comment.", 7500, "error")
          return
       end
    end

    M.set_modifiable(true)
    vim.api.nvim_buf_set_lines(state.buf, state.text_area_off, -1, false, {})
    M.set_modifiable(false)
    -- reset all pr state to grab in new comments
    vim.cmd("GHRefreshComments")
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
                M.edit_pr_body(comment)
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
