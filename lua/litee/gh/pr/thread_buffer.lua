local lib_notify    = require('litee.lib.notify')
local lib_util      = require('litee.lib.util')
local lib_path      = require('litee.lib.util.path')

local ghcli         = require('litee.gh.ghcli')
local s             = require('litee.gh.pr.state')
local reactions     = require('litee.gh.pr.reactions')
local reactions_map = require('litee.gh.pr.reactions').reaction_map
local issues       = require('litee.gh.issues')
local config       = require('litee.gh.config')

local M = {}

local state = {
    -- the buffer id where the thread is rendered
    buf = nil,
    -- the last thread that was rendered
    thread = nil,
    -- the last recorded end of the buffer
    buffer_end = nil,
    -- the offset to the "text" area where users can write text
    text_area_off = nil,
    -- a mapping of extmarks to the thread comments they represent.
    marks_to_comments = {},
    -- set when "edit_comment()" is issued, holds the comment thats being updated
    -- until submit() is called or a new thread is rendered.
    editing_comment = nil,
    -- set when "create_comment()" is issue, holds the details needed to submit
    -- a new thread to the GH API when submit() is called.
    creating_comment = nil
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

-- parse out the line range and whether its a multiline comment associated
-- with the provided thread.
local function extract_thread_lines(thread)
    local start_line = nil
    local end_line = nil
    local multiline = false
    if thread.thread["line"] ~= vim.NIL then
        start_line = thread.thread["startLine"]
        end_line = thread.thread["line"]
        if start_line == vim.NIL then
            start_line = end_line
        else
            multiline = true
            end_line = end_line
        end
        return {start_line-1, end_line, multiline}
    elseif thread.thread["originalLine"] ~= vim.NIL then
        start_line = thread.thread["originalStartLine"]
        end_line = thread.thread["originalLine"]
        if start_line == vim.NIL then
            start_line = end_line
        else
            multiline = true
            end_line = end_line
        end
        return {start_line-1, end_line, multiline}
    end
    return nil
end

-- extract rest_id from comment, you can get this from the last portion
-- of url.
local function comment_rest_id(comment)
    local rest_id = ""
    local sep = "_r"
    for i in string.gmatch(comment["comment"]["url"], "([^"..sep.."]+)") do
       rest_id = i
    end
    return rest_id
end

-- extract_text will extract text from the text area, join the lines, and shell
-- escape the content.
local function extract_text()
    if state.text_area_off == nil then
        return
    end
    local lines = vim.api.nvim_buf_get_lines(state.buf, state.text_area_off, -1, false)
    local body = vim.fn.join(lines, "\n")
    body = vim.fn.shellescape(body)
    return body, lines
end

-- namespace we'll use for extmarks that help us track comments.
local ns = vim.api.nvim_create_namespace("thread_buffer")

local function _win_settings_on()
    vim.api.nvim_win_set_option(0, "showbreak", "│")
    vim.api.nvim_win_set_option(0, 'winhighlight', 'NonText:Normal')
    vim.api.nvim_win_set_option(0, 'wrap', true)
    vim.api.nvim_win_set_option(0, 'colorcolumn', "0")
end
local function _win_settings_off()
    vim.api.nvim_win_set_option(0, "showbreak", "")
    vim.api.nvim_win_set_option(0, 'winhighlight', 'NonText:NonText')
    vim.api.nvim_win_set_option(0, 'wrap', true)
    vim.api.nvim_win_set_option(0, 'colorcolumn', "0")
end

-- in_editable_area is used as an auto command to flip the thread_buffer writable
-- when thec cursor is in the designated text area.
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
    vim.api.nvim_buf_set_name(state.buf, "pull request thread")
    vim.api.nvim_buf_set_option(state.buf, 'bufhidden', 'hide')
    vim.api.nvim_buf_set_option(state.buf, 'filetype', 'pr')
    vim.api.nvim_buf_set_option(state.buf, 'buftype', 'nofile')
    vim.api.nvim_buf_set_option(state.buf, 'modifiable', false)
    vim.api.nvim_buf_set_option(state.buf, 'swapfile', false)
    vim.api.nvim_buf_set_option(state.buf, 'textwidth', 0)
    vim.api.nvim_buf_set_option(state.buf, 'wrapmargin', 0)
    vim.api.nvim_buf_set_option(state.buf, 'ofu', 'v:lua.GH_completion')

    vim.api.nvim_buf_set_keymap(state.buf, 'n', config.config.keymaps.submit_comment, "", {callback=M.submit})
    vim.api.nvim_buf_set_keymap(state.buf, 'n', config.config.keymaps.resolve_thread, "", {callback=M.resolve_thread_toggle})
    vim.api.nvim_buf_set_keymap(state.buf, 'n', config.config.keymaps.actions, "", {callback=M.comment_actions})
    if not config.config.disable_keymaps then
        vim.api.nvim_buf_set_keymap(state.buf, 'n', config.config.keymaps.goto_issue, "", {callback=issues.open_issue_under_cursor})
    end

    vim.api.nvim_create_autocmd({"CursorMoved", "CursorMovedI"}, {
        buffer = state.buf,
        callback = in_editable_area,
    })
    vim.api.nvim_create_autocmd({"BufEnter"}, {
        buffer = state.buf,
        callback = require('litee.lib.util.window').set_tree_highlights,
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
    for _, r in ipairs(comment.comment["reactions"]["edges"]) do
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

-- render comment will render a comment object into buffer lines.
local function render_comment(comment, outdated)
    local lines = {}
    local reaction_lines = count_reactions(comment)
    local reaction_string = ""
    for r, count in pairs(reaction_lines) do
        reaction_string = reaction_string .. reactions_map[r] .. count .. " "
    end

    local author = comment.comment["author"]["login"]
    local title = string.format("%s %s  %s", symbols.top, config.icon_set["Account"], author)
    if outdated then
        title = title .. " [outdated]"
    elseif comment.comment["state"] == "PENDING" then
        title = title .. " [pending]"
    end
    table.insert(lines, title)

    table.insert(lines, symbols.left)
    for _, line in ipairs(parse_comment_body(comment.comment["body"], true)) do
        table.insert(lines, line)
    end
    table.insert(lines, symbols.left)
    if reaction_string ~= "" then
        table.insert(lines, symbols.left .. reaction_string)
    end
    table.insert(lines, symbols.bottom)

    return lines
end

-- create_thread places the thread buffer into "creating_comment" state and 
-- renders a user input area. 
--
-- when submit() is subsequently called thread will be created.
function M.create_thread(details)
    if state.buf == nil or not vim.api.nvim_buf_is_valid(state.buf) then
        setup_buffer()
    end

    reset_state()

    -- truncate current buffer
    M.set_modifiable(true)
    vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, {})

    local buffer_lines = {}
    table.insert(buffer_lines, string.format("%s  Create your new comment below... (submit: %s)", config.icon_set["Account"], config.config.keymaps.submit_comment))
    state.text_area_off = #buffer_lines
    table.insert(buffer_lines, "")
    vim.api.nvim_buf_set_lines(state.buf, 0, #buffer_lines, false, buffer_lines)

    -- set some additional book keeping state.
    state.buffer_end = #buffer_lines
    state.creating_comment = details

    M.set_modifiable(false)

    return state.buf
end

-- restore_comment_create will restore the "comment_creating" state and any text
-- which may have been in the buffer.
--
-- useful when refreshes occurs but the user was not finished writing a new thread
-- message.
function M.restore_comment_create(displayed)
    M.create_thread(state.creating_comment)
    local new_buf_end = #displayed.text_area
    M.set_modifiable(true)
    vim.api.nvim_buf_set_lines(state.buf, state.text_area_off, new_buf_end, false, displayed.text_area)
    M.set_modifiable(false)
    state.buffer_end = new_buf_end
    lib_util.safe_cursor_reset(displayed.win, {new_buf_end, vim.o.columns})
end

-- restore_thread takes a requested thread_id which diffview is requested to be
-- rendered, and a displayed thread which diffview last displayed.
--
-- if they reference the same thread, a restore function is returned which will
-- restore any old text into the newly rendered buffer.
--
-- the returned function expects the global state to be passed to it and will 
-- update the state's buffers accordingly.
function restore_thread(thread_id, displayed_thread)
    if 
        displayed_thread == nil or
        displayed_thread.buffer ~= state.buf or
        displayed_thread.thread_id ~= thread_id or
        not vim.api.nvim_win_is_valid(displayed_thread.win)
    then
        -- return a no-op
        return function(_) end
    end

    local cursor = vim.api.nvim_win_get_cursor(displayed_thread.win)
    
    local has_content
    local _, text_area_lines = extract_text()
    if text_area_lines == nil then
        return function(_) lib_util.safe_cursor_reset(displayed_thread.win, cursor) end
    end

    for _, line in ipairs(text_area_lines) do
        if line ~= "" then
            has_content = true
        end
    end
    if not has_content then
        return function(_) lib_util.safe_cursor_reset(displayed_thread.win, cursor) end
    end

    return function(state) 
        local new_buf_end = state.buffer_end + #text_area_lines
        vim.api.nvim_buf_set_lines(state.buf, state.text_area_off, new_buf_end, false, text_area_lines)
        state.buffer_end = new_buf_end
        lib_util.safe_cursor_reset(displayed_thread.win, {new_buf_end, vim.o.columns})
    end
end

-- write_preview grabs the buffer lines the thread refers to and writes a preview
-- of these threads into buffer_lines.
function write_preview(thread, buffer_lines, side)
    local thread_source_lines = extract_thread_lines(thread)
    -- grab source code buffer for preview
    local buf = nil
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        local path = ""
        if side == "LEFT" then
            path = string.format("%s/%s", "/tmp", lib_path.basename(thread.thread["path"]))
        else
            path = string.format("%s/%s", vim.fn.getcwd(), thread.thread["path"])
        end
        print("comparing " .. vim.api.nvim_buf_get_name(b) .. " and " .. path)
        if vim.api.nvim_buf_get_name(b) == path then
            print("found")
            buf = b
        end
    end
    if
        buf ~= nil
        and thread_source_lines ~= nil
    then
        local start_line = thread_source_lines[1]
        local end_line = thread_source_lines[2]
        local multiline = thread_source_lines[3]
        -- if not a multiline comment, and if we have space, give some context
        if
            (start_line - 3) >= 1 and
            not multiline
        then
            start_line = start_line - 3
        end
        table.insert(buffer_lines, symbols.left)
        local lines = vim.api.nvim_buf_get_lines(buf, start_line, end_line, true)
        for i, preview_line in ipairs(lines) do
            table.insert(buffer_lines, string.format("%s %s %s %s", symbols.left, (start_line + i), "▏", preview_line))
        end
    end
end

-- render_thread is the entrypoint function for displaying a thread buffer.
-- 
-- thread_id is the requested thread to display and this thread should be loaded
-- into s.pull_state before being requested.
--
-- n_of is the number of the thread on the thread's line, there can be multiple
-- threads on a single line, and this differentiates them.
--
-- displayed_thread is provided by diffview and indicates the previously displayed
-- thread, if it matches thread_id then render_thread will attempt to restore any
-- previously writen text.
--
-- this method is intended to work as a 'refresh' method as well.
function M.render_thread(thread_id, n_of, displayed_thread, side)
    if state.buf == nil or not vim.api.nvim_buf_is_valid(state.buf) then
        setup_buffer()
    end

    local restore = restore_thread(thread_id, displayed_thread)

    -- special case, if we are in "creating_comment" state, restore this incase
    -- this is a refresh and the user was writing a message.
    if
        state.creating_comment ~= nil
        and displayed_thread ~= nil
    then
        restore(state)
        return state.buf
    end

    reset_state()

    -- get latest thread from pull_state
    local thread = s.pull_state.review_threads_by_id[thread_id]

    local buffer_lines = {}

    -- requested thread to render doesn't exist, it could have been deleted.
    if thread == nil then
        M.set_modifiable(true)
        table.insert(buffer_lines, "Thread does not exist.")
        vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, buffer_lines)
        M.set_modifiable(false)
        return state.buf
    end

    -- truncate current buffer
    M.set_modifiable(true)
    vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, {})

    -- bookkeep the extmarks we need to create
    local marks_to_create = {}

    -- pull out root comment
    local root_comment = thread["children"][1]
    local line = nil
    if thread.thread["originalLine"] ~= vim.NIL then
        line = thread.thread["originalLine"]
    end
    if thread.thread["line"] ~= vim.NIL then
        line = thread.thread["line"]
    end

    -- render thread header
    table.insert(buffer_lines, string.format("%s %s  Thread [%d/%d]", symbols.top, config.icon_set["MultiComment"], n_of[1], n_of[2]))
    table.insert(buffer_lines, string.format("%s %s  Author: %s", symbols.left, config.icon_set["Account"], root_comment.comment["author"]["login"]))
    table.insert(buffer_lines, string.format("%s %s  Path: %s:%d", symbols.left, config.icon_set["File"], thread.thread["path"], line))
    table.insert(buffer_lines, string.format("%s %s  Resolved: %s", symbols.left, config.icon_set["CheckAll"], thread.thread["isResolved"]))
    table.insert(buffer_lines, string.format("%s %s  Outdated: %s", symbols.left, config.icon_set["History"], thread.thread["isOutdated"]))
    table.insert(buffer_lines, string.format("%s %s  Created: %s", symbols.left, config.icon_set["Calendar"], root_comment.comment["createdAt"]))
    table.insert(buffer_lines, string.format("%s %s  Last Updated: %s", symbols.left, config.icon_set["Calendar"], root_comment.comment["updatedAt"]))
    -- preview in header
    write_preview(thread, buffer_lines, side)
    table.insert(buffer_lines, symbols.left)
    table.insert(buffer_lines, string.format("%s (submit: %s)(comment actions: %s)(un/resolve: %s)", symbols.bottom, config.config.keymaps.submit_comment, config.config.keymaps.actions, config.config.keymaps.resolve_thread))
    table.insert(buffer_lines, "")

    -- render root comment
    local root_comment_lines = render_comment(root_comment, thread.thread["isOutdated"])
    for _, l in ipairs(root_comment_lines) do
        table.insert(buffer_lines, l)
    end
    -- mark end of root comment
    table.insert(marks_to_create, {#buffer_lines, root_comment})

    for i, reply in ipairs(thread.children) do
        if i == 1 then
           goto continue
        end
        local reply_lines = render_comment(reply)
        for _, l in ipairs(reply_lines) do
            table.insert(buffer_lines, l)
        end
        table.insert(marks_to_create, {#buffer_lines, reply})
        ::continue::
    end

    -- user text area
    table.insert(buffer_lines, "")
    table.insert(buffer_lines, string.format("%s  %s", config.icon_set["Account"], "Add a reply below..."))

    -- record the offset to our reply message, we'll allow editing here
    state.text_area_off = #buffer_lines
    table.insert(buffer_lines, "")

    -- write all buffer lines to the buffer
    vim.api.nvim_buf_set_lines(state.buf, 0, #buffer_lines, false, buffer_lines)

    -- write out all our marks.
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
    state.thread = thread

    -- if the requested thread_id to render was also the currently displayed 
    -- thread, restore the cursor and possible draft text which was left.
    restore(state)

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

-- edit the comment under the cursor. 
-- places the thread_buffer in "editing_comment" state and will submit the changes
-- on submit()
function M.edit_comment()
    local comment = comment_under_cursor()
    if comment == nil then
        return
    end

    local lines = {}

    if not comment.comment["viewerDidAuthor"] then
        lib_notify.notify_popup_with_timeout("Cannot edit a comment you did not author.", 7500, "error")
        return
    end

    table.insert(lines, string.format("%s  %s", config.icon_set["Account"], "Edit the message below..."))
    for _, line in ipairs(parse_comment_body(comment.comment["body"], false)) do
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

-- deletes a comment under the cursor
function M.delete_comment()
    local comment = comment_under_cursor()
    if comment == nil then
        return
    end
    local rest_id = comment_rest_id(comment)
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

            local out = ghcli.delete_comment(rest_id)
            if out == nil then
                lib_notify.notify_popup_with_timeout("Failed to delete comment.", 7500, "error")
                return
            end

            -- perform refresh of comments data
            vim.cmd("GHRefreshComments")
        end
    )
end

-- will toggle the current thread between resolved/unresolved
function M.resolve_thread_toggle()
    if state.thread.thread["isResolved"] then
        local out = ghcli.unresolve_thread(state.thread.thread["id"])
        if out == nil then
            lib_notify.notify_popup_with_timeout("Failed to resolve thread.", 7500, "error")
            return
        end
    else
        local out = ghcli.resolve_thread(state.thread.thread["id"])
        if out == nil then
            lib_notify.notify_popup_with_timeout("Failed to resolve thread.", 7500, "error")
            return
        end
    end
    -- perform refresh of comments data
    vim.cmd("GHRefreshComments")
end

function M.set_modifiable(bool)
    if state.buf ~= nil and vim.api.nvim_buf_is_valid(state.buf) then
        vim.api.nvim_buf_set_option(state.buf, 'modifiable', bool)
    end
end

-- reply handles submitting a reply comment via the github api
local function reply(body)
    -- if we are not in a review perform a regular reply, if we are
    -- perform a reply associated with the review.
    local root_comment = state.thread["children"][1]
    if s.pull_state.review == nil then
        local rest_id = comment_rest_id(root_comment)
        local out = ghcli.reply_comment(s.pull_state["number"], rest_id, body)
        if out == nil then
            return nil
        end
        return out
    else
        local id = root_comment["comment"]["id"]
        local out = ghcli.reply_comment_review(
            s.pull_state.pr_raw["node_id"],
            s.pull_state.review["node_id"],
            s.pull_state.head,
            body,
            id
        )
        if out == nil then
            return nil
        end
        return out
    end
end

-- update handles submitting an update to a comment via the github api
local function update(body)
    local rest_id = comment_rest_id(state.editing_comment)
    local out = ghcli.update_comment(rest_id, body)
    if out == nil then
        return nil
    end
    return out
end

-- create handles submitting a new threaded comment on a given diff line via
-- the github api.
local function create(body, details)
    -- create non-review related comment
    if s.pull_state.review == nil then
       if details.line == details.end_line then
           local out = ghcli.create_comment(
               details.pull_number,
               details.commit_sha,
               details.path,
               details.position,
               details.side,
               details.line,
               body
           )
           if out == nil then
               lib_notify.notify_popup_with_timeout("Failed to create new comment.", 7500, "error")
               return
           end
        else
           local out = ghcli.create_comment_multiline(
               details.pull_number,
               details.commit_sha,
               details.path,
               details.position,
               details.side,
               details.line,
               details.end_line,
               body
           )
           if out == nil then
               lib_notify.notify_popup_with_timeout("failed to create new comment.", 7500, "error")
               return
           end
       end
    else
    -- create comment within the review
       if details.line == details.end_line then
           local out = ghcli.create_comment_review(
               s.pull_state.pr_raw["node_id"],
               s.pull_state.review["node_id"],
               body,
               details.path,
               details.line,
               details.side
           )
           if out == nil then
               lib_notify.notify_popup_with_timeout("Failed to create new comment.", 7500, "error")
               return
           end
        else
           local out = ghcli.create_comment_review_multiline(
               s.pull_state.pr_raw["node_id"],
               s.pull_state.review["node_id"],
               body,
               details.path,
               details.line,
               details.end_line,
               details.side
           )
           if out == nil then
               lib_notify.notify_popup_with_timeout("Failed to create new comment.", 7500, "error")
               return
           end
       end
    end
    vim.api.nvim_win_set_buf(0, details.original_buf)
end

-- reactions handles submitting an addition or removal of a user reaction for
-- a given comment under the cursor.
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
                ghcli.remove_reaction_async(comment.comment["id"], reactions.reaction_names[idx], vim.schedule_wrap(function(err, data)
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
                ghcli.add_reaction(comment.comment["id"], reactions.reaction_names[idx], vim.schedule_wrap(function(err, data)
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

-- submit() determines the current state of the thread_buffer and performs the
-- necessary GH API calls.
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
       state.editing_comment = nil
       if out == nil then
          lib_notify.notify_popup_with_timeout("Failed to update comment.", 7500, "error")
          return
       end
    elseif state.creating_comment ~= nil then
       create(body, state.creating_comment)
       if state.creating_comment.on_create ~= nil then
         state.creating_comment.on_create()
       end
       state.creating_comment = nil
    else
       local out = reply(body)
       if out == nil then
          lib_notify.notify_popup_with_timeout("Failed to create reply.", 7500, "error")
          return
       end
    end
    M.set_modifiable(true)
    vim.api.nvim_buf_set_lines(state.buf, state.text_area_off, -1, false, {})
    M.set_modifiable(false)
    vim.cmd("GHRefreshComments")
end

-- comment_actions displays a list of actions for a given comment.
function M.comment_actions()
    notification = comment_under_cursor()
    if notification == nil then
        return
    end
    vim.ui.select(
        {"edit", "delete", "react"},
        {prompt="Pick a action to perform on this comment: "},
        function(item, _)
            if item == nil then
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
