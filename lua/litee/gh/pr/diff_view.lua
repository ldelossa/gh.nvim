local M = {}

local lib_util_path = require('litee.lib.util.path')
local lib_util_win  = require('litee.lib.util.window')
local lib_notify    = require('litee.lib.notify')
local config        = require('litee.gh.config')

local s             = require('litee.gh.pr.state')
local thread_buffer = require('litee.gh.pr.thread_buffer')
local gitcli        = require('litee.gh.gitcli')

-- works as a "once" flag to lazy init signs.
local init_done = false

-- setup the signs used within our diffsplit view.
local function init()
    if init_done then
        return
    end

    vim.fn.sign_define("gh-comment", {text=config.icon_set["Comment"], texthl = "LTComment"})
    vim.fn.sign_define("gh-comment-multi", {text=config.icon_set["MultiComment"], texthl = "LTMultiComment"})
    vim.fn.sign_define("gh-comment-outdated", {text=config.icon_set["Comment"], texthl = "LTFailure"})
    vim.fn.sign_define("gh-comment-resolved", {text=config.icon_set["Comment"], texthl = "LTSuccess"})
    vim.fn.sign_define("gh-comment-pending", {text=config.icon_set["Comment"], texthl = "LTWarning"})
    vim.fn.sign_define("gh-can-comment", {text=config.icon_set["DiffAdded"], texthl = "LTDiffAdd"})
    init_done = true
end

local state = nil

function reset_state() 
    state = {
        -- the file that is currently being diffed
        file = nil,
        commit = nil,
        -- the left window id of the split
        lwin = nil,
        -- the right window id of the split
        rwin = nil,
        -- the left buffer id of the split
        lbuf = nil,
        -- the right buffer id of the split
        rbuf = nil,
        -- the threads which belong to this file
        threads = nil,
        -- a map between line numbers in the diff and one or more threads.
        --
        -- map has the following structure
        -- {
        --   "RIGHT" = {
        --      linenr = {threads},
        --      linenr = {threads}...
        --   },
        --   "LEFT" = {
        --      ...
        --   }
        -- }
        threads_by_line = nil,
        -- displayed thread table {
        --   side,
        --   win,
        --   buf,
        --   linenr,
        --   index,
        --   thread_id,
        -- }
        displayed_thread = nil,
        lines_to_diff_pos = nil,
        n_of = nil
    }
end

function M.close()
    if vim.api.nvim_win_is_valid(state.lwin) then
        vim.api.nvim_win_close(state.lwin, true)
    end
    if vim.api.nvim_win_is_valid(state.rwin) then
        vim.api.nvim_win_close(state.rwin, true)
    end
end

-- setup_diff_ui will reset the current tab to an configuration of windows to
-- idempotently implement our diffsplit
local function setup_diff_ui()
    -- find any non litee-panel window
    local wins = {}
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if
            not lib_util_win.is_component_win(vim.api.nvim_get_current_tabpage(), win)
            and cur_win ~= win
        then
            table.insert(wins, win)
        end
    end

    -- if we have no wins vsplit to create one, else set ourselves in one of the
    -- existing windows.
    if #wins == 0 then
        vim.cmd("vsplit")
        -- stupid hack, if we vsplit from a litee component, the split window will
        -- inherit the Normal:NormalSB remap which sets the panel to the NormalSB
        -- highlight. Set this back to Normal:Normal.
        vim.api.nvim_win_set_option(cur_win, 'winhighlight', 'Normal:Normal')
    else
        vim.api.nvim_set_current_win(wins[1])
    end

    -- close all other wins
    for _, win in ipairs(wins) do
        if
            win ~= wins[1] and
            vim.api.nvim_win_is_valid(win)
        then
            vim.api.nvim_win_close(win, true)
        end
    end
end

-- places signs on the currently active diffsplit.
--
-- this should only be called when the caller knows a valid diffsplit has been
-- setup.
local function diffsplit_sign_place()
    init()
    vim.fn.sign_unplace("gh-can-comment")
    -- paint signs where you can create a comment
    for line, _ in pairs(state.lines_to_diff_pos['LEFT']) do
            local buf = state.lbuf
            vim.fn.sign_place(0, "gh-can-comment", "gh-can-comment", buf, {
                lnum = line,
                priority = 98
            })
    end
    for line, _ in pairs(state.lines_to_diff_pos['RIGHT']) do
            local buf = state.rbuf
            vim.fn.sign_place(0, "gh-can-comment", "gh-can-comment", buf, {
                lnum = line,
                priority = 98
            })
    end
    if state.threads == nil then
        vim.fn.sign_unplace("gh-comments")
        return
    end
    if #state.threads == 0 then
        vim.fn.sign_unplace("gh-comments")
        return
    end
    vim.fn.sign_unplace("gh-comments")
    local comment_placed = {}
    for _, thread in ipairs(state.threads) do
        local buf = nil
        if thread.thread["diffSide"] == "RIGHT" then
            buf = state.rbuf
        else
            buf = state.lbuf
        end

        local line = nil
        if thread.thread["originalLine"] ~= vim.NIL then
            line = thread.thread["originalLine"]
        end
        if thread.thread["line"] ~= vim.NIL then
            line = thread.thread["line"]
        end

        if comment_placed[line] then
            vim.fn.sign_place(0, "gh-comments", "gh-comment-multi", buf, {
                lnum = line,
                priority = 99
            })
        elseif thread.thread["isOutdated"] then
            vim.fn.sign_place(0, "gh-comments", "gh-comment-outdated", buf, {
                lnum = line,
                priority = 99
            })
        elseif thread.thread["isResolved"] then
            vim.fn.sign_place(0, "gh-comments", "gh-comment-resolved", buf, {
                lnum = line,
                priority = 99
            })
        else
            vim.fn.sign_place(0, "gh-comments", "gh-comment", buf, {
                lnum = line,
                priority = 99
            })
        end
        comment_placed[line] = true
    end
end

local function organize_threads(threads)
    state.threads_by_line = {
        RIGHT = {},
        LEFT = {}
    }

    if threads == nil then
        return
    end

    for _, thread in ipairs(threads) do
        local line = nil
        if thread.thread["originalLine"] ~= vim.NIL then
            line = thread.thread["originalLine"]
        end
        if thread.thread["line"] ~= vim.NIL then
            line = thread.thread["line"]
        end
        local side = thread.thread["diffSide"]

        if state.threads_by_line[side][line] == nil then
            state.threads_by_line[side][line] = {thread}
        else
            table.insert(state.threads_by_line[side][line], thread)
        end
    end
end

function M.on_refresh()
    -- if our left and right windows are not valid, just bail, they will be
    -- fixed when user opens any new message notification.
    if
        state == nil or
        state.lwin == nil or
        not vim.api.nvim_win_is_valid(state.lwin) or
        state.rwin == nil or
        not vim.api.nvim_win_is_valid(state.rwin)
    then
        return
    end

    -- if the commit we are displaying no longer exists due to rebase or squash, render this
    -- message out to diff buffers and return.
    if s.pull_state.commits_by_sha[state.commit["sha"]] == nil then
            vim.api.nvim_buf_set_lines(state.lbuf, 0, -1, false, {"Commit no longer exists"})
            vim.api.nvim_buf_set_lines(state.rbuf, 0, -1, false, {"Commit no longer exists"})
            return
    end

    -- get latest threads
    state.threads = s.pull_state.review_threads_by_filename[state.file["filename"]]

    -- organize our threads by left,right and line number, fills in
    -- state.threads_by_line
    if state.threads ~= nil then
        organize_threads(state.threads)
    end

    -- paint the necessary signs
    diffsplit_sign_place()

    -- if a thread was being displayed, refresh it
    if
        state.displayed_thread ~= nil
    then
        local t_buf = thread_buffer.render_thread(state.displayed_thread.thread_id, state.displayed_thread.n_of, state.displayed_thread)

        if state.displayed_thread.popup then
            return
        end

        if state.displayed_thread.side == 'LEFT' then
            vim.api.nvim_win_set_buf(state.rwin, t_buf)
        else
            vim.api.nvim_win_set_buf(state.lwin, t_buf)
        end
    end
end

local function map_chunks_to_lines(file)
    if file["patch"] == nil then
        return
    end
    local patch_lines = vim.fn.split(file["patch"], "\n")
    local diff_lines = {
        RIGHT = 0,
        LEFT = 0
    }
    for i, line in ipairs(patch_lines) do
        if vim.fn.match(line, "^@@") ~= -1 then

            local function parse(side, diff_stat)
                if i > 1 then
                    -- chunk header counts in diff position counts
                    diff_lines[side] = diff_lines[side] + 1
                end

                local diff_stat_split = vim.fn.split(diff_stat, ",")
                local start_line = tonumber(diff_stat_split[1])
                -- stupid but the left side of a diff stat *looks* like a
                -- negative number, make it positive.
                if start_line < 0 then
                    start_line = start_line*-1
                end
                -- subtract one to make loop below cleaner.
                start_line = start_line - 1

                -- right side of diff stat can be empty like +1, handle this.
                local n = nil
                if diff_stat_split[2] == nil then
                    n = 0
                else
                    -- subtract one to make loop below cleaner.
                    n = tonumber(diff_stat_split[2])-1
                end

                for ii = 0, n, 1 do
                    diff_lines[side] = diff_lines[side] + 1
                    start_line = start_line + 1
                    state.lines_to_diff_pos[side][start_line] = diff_lines[side]
                end
            end
            local hunk_parts = vim.fn.split(line)
            local left_diff_stat = hunk_parts[2]
            local right_diff_stat = hunk_parts[3]
            parse("LEFT", left_diff_stat)
            parse("RIGHT", right_diff_stat)
        end
    end
end

-- the commmit object passed in is one which is returned by ghcli.get_commit().
function M.open_diffsplit(commit, file, thread, compare_base)
    reset_state()
    -- setup the current tabpage for a diff,
    -- when we return from this we'll be inside a right hand diff window
    setup_diff_ui()

    state.rwin = vim.api.nvim_get_current_win()
    state.file = file
    state.commit = commit
    state.threads = s.pull_state.review_threads_by_filename[state.file["filename"]]
    state.lines_to_diff_pos = {
        RIGHT = {},
        LEFT = {}
    }

    -- organize our threads by left,right and line number, fills in
    -- state.threads_by_line
    organize_threads(state.threads)

    -- map the file's hunk headers to buffer lines
    map_chunks_to_lines(file)

    -- this will be the left side of our diff, we'll create this as a tmp file
    -- with the gitcli command
    local diff_file = string.format("/tmp/%s", lib_util_path.basename(file["filename"]))

    vim.fn.delete("/tmp/gh-nvim-empty")
    -- if the file is added, open our local file and diff an empty buffer
    if file["status"] == "added" then
        vim.cmd("edit " .. file["filename"])
        diff_file = "/tmp/gh-nvim-empty"
    -- if the file is removed, open an empty buffer first and diff the old
    -- old version
    elseif file["status"] == "removed" then
        vim.cmd("edit /tmp/gh-nvim-empty")
    -- in all other cases open our local file and diff the old version.
    else
        vim.cmd("edit " .. file["filename"])
    end

    -- write the old version of the file to /tmp/ and diff it
    local parent_commit = nil
    if compare_base then
        parent_commit = s.pull_state.commits[1]["parents"][1]["sha"]
    else
        parent_commit = commit["parents"][1]["sha"]
    end

    gitcli.git_show_and_write(parent_commit, file["filename"], diff_file)
    vim.cmd("vert diffsplit " .. diff_file)

    -- we are now in left diff window, bookkeep this and our diff buffers
    state.lwin = vim.api.nvim_get_current_win()
    state.lbuf = vim.api.nvim_win_get_buf(state.lwin)
    state.rbuf = vim.api.nvim_win_get_buf(state.rwin)

    -- switch back to right side
    vim.api.nvim_set_current_win(state.rwin)

    -- paint the necessary signs
    diffsplit_sign_place()

    vim.cmd("wincmd =")

    -- if a thread is provided, open directly to it
    if thread ~= nil then
        local win = nil
        if thread["diffSide"] == "RIGHT" then
            win = state.rwin
        else
            win = state.lwin
        end
        local line = nil
        if thread["originalLine"] ~= vim.NIL then
            line = thread["originalLine"]
        end
        if thread["line"] ~= vim.NIL then
            line = thread["line"]
        end
        if vim.api.nvim_buf_line_count(
            vim.api.nvim_win_get_buf(win)
        ) < line then
            lib_notify.notify_popup_with_timeout("The comment is not reachable from this commit.", 7500, "warning")
            return
        end

        vim.api.nvim_set_current_win(win)
        vim.api.nvim_win_set_cursor(win, {line, 0})
        M.toggle_threads(thread["id"])
        return
    end
    -- always open diffs at start of file
    vim.api.nvim_win_set_cursor(state.rwin, {1, 0})
    vim.api.nvim_win_set_cursor(state.lwin, {1, 0})
end

function M.toggle_thread_popup()
    -- are we being asked to toggle while in our popup? if so close it.
    local cur_win = vim.api.nvim_get_current_win()
    if
        state.displayed_thread ~= nil and
        state.displayed_thread.popup
    then
        local should_return = (cur_win == state.displayed_thread.win)
        vim.api.nvim_win_close(state.displayed_thread.win, true)
        state.displayed_thread = nil
        if should_return then
            return
        end
    end

    local side = nil
    if cur_win == state.lwin then side = "LEFT" end
    if cur_win == state.rwin then side = "RIGHT" end
    local cursor = vim.api.nvim_win_get_cursor(cur_win)
    local threads = state.threads_by_line[side][cursor[1]]

    -- are we being asked to toggle on a line with no threads?
    -- if so, if our popup window is valid close it
    if threads == nil then
        return
    end

    local thread = threads[1]

    local buf = thread_buffer.render_thread(thread.thread["id"], {1, #threads})
    if buf == nil then
        return
    end

    local width = 20
    local line_count = 0
    for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
        local line_width = vim.fn.strdisplaywidth(line)
        if line_width > width then
            width = line_width
        end
        line_count = i
    end

    local popup_conf = vim.lsp.util.make_floating_popup_options(
            width,
            line_count,
            {
                border= "rounded",
                focusable= true,
                zindex = 99,
                relative = "cursor"
            }
    )
    local win = vim.api.nvim_open_win(buf, true, popup_conf)

    -- set displayed_thread with details on the currently displayed threads
    state.displayed_thread = {
        side = side,
        linenr = cursor[1],
        win = win,
        buffer = buf,
        index = 1,
        thread_id = thread.thread["id"],
        popup = true,
        n_of = {1, #threads},
    }
end

function M.next_thread()
    if state.displayed_thread == nil then
        return
    end

    local side = state.displayed_thread["side"]
    local line = state.displayed_thread["linenr"]

    local threads = state.threads_by_line[side][line]
    if threads == nil then
        return
    end

    local cur_thread_idx = state.displayed_thread["index"]
    cur_thread_idx = cur_thread_idx + 1
    if cur_thread_idx > #threads then
        cur_thread_idx = 1
    end
    local thread = threads[cur_thread_idx]

    thread_buffer.render_thread(thread.thread["id"], {cur_thread_idx, #threads})
    state.displayed_thread["index"] = cur_thread_idx
    state.displayed_thread["thread_id"] = thread.thread["id"]
end

function M.toggle_threads(thread_id)
    local cur_win = vim.api.nvim_get_current_win()
    local side = nil
    if cur_win == state.lwin then side = "LEFT" end
    if cur_win == state.rwin then side = "RIGHT" end
    if side == nil then
        -- we are not in our diffsplit
        return
    end
    local cursor = vim.api.nvim_win_get_cursor(cur_win)
    local threads = state.threads_by_line[side][cursor[1]]

    -- we are being asked to toggle on a line with no threads. if a thread is
    -- displayed restore the diff view.
    if threads == nil then
        -- toggle off the thread_buffer if its currently displayed
        if
            state.displayed_thread ~= nil
        then
            if state.displayed_thread.popup == true then
                vim.api.nvim_win_close(state.displayed_thread.win, true)
            end
            local win = nil
            local buf = nil
            if state.displayed_thread["side"] == "RIGHT" then
                win = state.lwin
                buf = state.lbuf
            else
                win = state.rwin
                buf = state.rbuf
            end
            if
                not vim.api.nvim_win_is_valid(win) or
                not vim.api.nvim_buf_is_valid(buf)
            then
                -- uh oh, our diff view is messed up. lets render the entire thing again
                M.open_diffsplit(state.commit, state.file)
                return
            end
            vim.api.nvim_win_set_buf(win, buf)
        end
        state.displayed_thread = nil
        return
    end

    -- we are being asked to toggle on a line with threads.
    -- if the thread on the line is one currently displayed, restore the diff view.
    -- else, open it for display.
    if state.displayed_thread ~= nil then
        if
            state.displayed_thread.side == side and
            state.displayed_thread.linenr == cursor[1]
        then
            if state.displayed_thread.popup == true then
                vim.api.nvim_win_close(state.displayed_thread.win, true)
            end
            -- if we are being asked to toggle on a line with threads, but the
            -- requested thread_id to this function is different the whats displayed
            -- render it.
            if thread_id ~= nil then
                if state.displayed_thread.thread_id ~= thread_id then
                    goto display
                end
            end

            local win = nil
            local buf = nil
            if state.displayed_thread["side"] == "RIGHT" then
                win = state.lwin
                buf = state.lbuf
            else
                win = state.rwin
                buf = state.rbuf
            end
            if
                not vim.api.nvim_win_is_valid(win) or
                not vim.api.nvim_buf_is_valid(buf)
            then
                -- uh oh, our diff view is messed up. lets render the entire thing again
                M.open_diffsplit(state.commit, state.file)
                return
            end
            vim.api.nvim_win_set_buf(win, buf)
            state.displayed_thread = nil
            return
        end
        -- its a different thread, display it by fall thru
    end

    ::display::
    -- if thread_id is provided, ensure we render this thread.
    local n = 1
    if thread_id ~= nil then
        for i, t in ipairs(threads) do
            if t.thread["id"] == thread_id then
                n = i
            end
        end
    end
    local thread = threads[n]

    local buf = thread_buffer.render_thread(thread.thread["id"], {n, #threads})
    if buf == nil then
        return
    end

    local win = nil
    if side == "RIGHT" then
        win = state.lwin
    else
        win = state.rwin
    end

    if not vim.api.nvim_win_is_valid(win) then
        -- uh oh, our diff view is messed up. lets render the entire thing again
        M.open_diffsplit(state.commit, state.file, thread.thread)
        return
    end

    vim.api.nvim_win_set_buf(win, buf)

    -- set displayed_thread with details on the currently displayed threads
    state.displayed_thread = {
        side = side,
        linenr = cursor[1],
        win = win,
        buffer = buf,
        index = 1,
        thread_id = thread.thread["id"],
        popup = false,
        n_of = {n, #threads}
    }
end

function M.create_comment(args)
    -- determine which side we are in
    local cur_win = vim.api.nvim_get_current_win()
    local side = nil
    if cur_win == state.lwin then
        side = "LEFT"
    elseif cur_win == state.rwin then
        side = "RIGHT"
    else
        return
    end

    -- determine current line number
    local line = args["line1"]
    local end_line = args["line2"]

    -- do we have a diff mapping for this line?
    local pos = state.lines_to_diff_pos[side][line]
    if pos == nil then
        lib_notify.notify_popup_with_timeout("Cannot create a comment on line outside of GitHub diff.", 7500, "error")
        return
    end
    local end_pos = state.lines_to_diff_pos[side][end_line]
    if end_pos == nil then
        lib_notify.notify_popup_with_timeout("Cannot create a comment on line outside of GitHub diff.", 7500, "error")
        return
    end

    local original_buf = nil
    if side == "RIGHT" then
        original_buf = state.lbuf
    else
        original_buf = state.rbuf
    end

    -- create a thread_buffer in the "creating_comment" state.
    local details = {
        pull_number = s.pull_state["number"],
        commit_sha = state.commit["sha"],
        path = state.file["filename"],
        position = pos,
        side = side,
        line = line,
        end_line = end_line,
        original_buf = original_buf,
        -- after creation set state.displayed_thread to nil so we don't render
        -- a nil thread on refresh.
        on_create = function() state.displayed_thread = nil end
    }
    local buf = thread_buffer.create_thread(details)

    local win = nil
    if side == "RIGHT" then
        vim.api.nvim_win_set_buf(state.lwin, buf)
        win = state.lwin
    else
        vim.api.nvim_win_set_buf(state.rwin, buf)
        win = state.rwin
    end

    -- put user's cursor in create buffer
    vim.api.nvim_set_current_win(win)

    -- display a nil thread to keep "creating comment" window alive over refreshes.
    state.displayed_thread = {
        side = side,
        linenr = line,
        win = win,
        buffer = buf,
        index = nil,
        thread_id = nil,
    }
end

return M
