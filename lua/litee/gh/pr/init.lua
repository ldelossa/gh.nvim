local lib_state     = require('litee.lib.state')
local lib_tree      = require('litee.lib.tree')
local lib_notify    = require('litee.lib.notify')
local lib_panel     = require('litee.lib.panel')
local lib_details   = require('litee.lib.details')
local lib_icons     = require('litee.lib.icons')
local lib_util      = require('litee.lib.util')

local handlers      = require('litee.gh.pr.handlers')
local ghcli         = require('litee.gh.ghcli')
local gitcli        = require('litee.gh.gitcli')
local s             = require('litee.gh.pr.state')
local diff_view     = require('litee.gh.pr.diff_view')
local thread_buffer = require('litee.gh.pr.thread_buffer')
local pr_buffer     = require('litee.gh.pr.pr_buffer')
local pr_details    = require('litee.gh.pr.details')
local marshaler     = require('litee.gh.pr.marshal')
local config        = require('litee.gh.config').config
local helpers       = require('litee.gh.helpers')

function GH_completion(start, base)
    if start == 1 then
        local cursor = vim.api.nvim_win_get_cursor(0)
        local line = vim.api.nvim_buf_get_lines(0, cursor[1]-1, cursor[1], true)
        local at_idx = vim.fn.strridx(line[1], "@", cursor[2])
        if at_idx ~= -1 then
            return at_idx
        end
        local hash_idx = vim.fn.strridx(line[1], "#", cursor[2])
        if hash_idx ~= -1 then
            return hash_idx
        end
        return -3
    end
    if vim.fn.match(base, "@") ~= -1 then
        local matches = {}
        if s.pull_state["collaborators"] ~= nil then
            for _, collaber in ipairs(s.pull_state["collaborators"]) do
                if vim.fn.match("@"..collaber["login"], base) ~= -1 then
                    table.insert(matches, {
                        word = "@"..collaber["login"],
                        menu = collaber["type"]
                    })
                end
            end
        end
        return matches
    elseif vim.fn.match(base, "#") ~= -1 then
        local matches = {}
        for _, iss in ipairs(s.pull_state["repo_issues"]) do
            if vim.fn.match("#"..iss["number"], base) ~= -1 then
                table.insert(matches, {
                    word = "#"..iss["number"],
                    menu = iss["title"]
                })
            end
        end
        return matches
    end
end

local icon_set = {}
if config.icon_set ~= nil then
    icon_set = lib_icons[config.icon_set]
end

local M = {}

M.periodic_refresh = nil
M.autocmds = {}

local function ui_req_ctx()
    local buf    = vim.api.nvim_get_current_buf()
    local win    = vim.api.nvim_get_current_win()
    local tab    = vim.api.nvim_win_get_tabpage(win)
    local linenr = vim.api.nvim_win_get_cursor(win)
    local tree_type   = lib_state.get_type_from_buf(tab, buf)
    local tree_handle = lib_state.get_tree_from_buf(tab, buf)
    local state       = lib_state.get_state(tab)

    -- filled in if we find a valid litee-panel window.
    local pr_cursor = nil
    local pr_node = nil
    local files_cursor = nil
    local files_node = nil
    local review_cursor = nil
    local review_node = nil

    if state ~= nil then
        if state["pr"] ~= nil and state["pr"].win ~= nil and
            vim.api.nvim_win_is_valid(state["pr"].win) then
            pr_cursor = vim.api.nvim_win_get_cursor(state["pr"].win)
        end
        if pr_cursor ~= nil then
            pr_node = lib_tree.marshal_line(pr_cursor, state["pr"].tree)
        end
        if state["pr_files"] ~= nil and state["pr_files"].win ~= nil and
            vim.api.nvim_win_is_valid(state["pr_files"].win) then
            files_cursor = vim.api.nvim_win_get_cursor(state["pr_files"].win)
        end
        if files_cursor ~= nil then
            files_node = lib_tree.marshal_line(files_cursor, state["pr_files"].tree)
        end
        if state["pr_review"] ~= nil and state["pr_review"].win ~= nil and
            vim.api.nvim_win_is_valid(state["pr_review"].win) then
            review_cursor = vim.api.nvim_win_get_cursor(state["pr_review"].win)
        end
        if review_cursor ~= nil then
            review_node = lib_tree.marshal_line(review_cursor, state["pr_review"].tree)
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
        -- the type of tree if request is made in a lib_tree
        -- window.
        tree_type = tree_type,
        -- a hande to the tree if the request is made in a lib_panel
        -- window.
        tree_handle = tree_handle,
        pr_cursor = pr_cursor,
        pr_node = pr_node,
        files_cursor = files_cursor,
        files_node = files_node,
        review_cursor = review_cursor,
        review_node = review_node,
        -- the current state provided by lib_state
        state = state,
    }
end

function M.open_pull_by_number(number)
    if number ~= nil then
        handlers.pr_handler(number, function() M.open_pr_buffer() end)
        return
    end
end

local function start_refresh_timer(now)
    if M.periodic_refresh == nil then
        M.periodic_refresh = vim.loop.new_timer()
    end
    if now then
        vim.schedule(function () lib_notify.notify_popup_with_timeout("Refreshing Pull Request.", 7500, "info") end)
        handlers.global_refresh()
    end
    M.periodic_refresh:start(180000, 180000, function()
        vim.schedule(function () lib_notify.notify_popup_with_timeout("Refreshing Pull Request.", 7500, "info") end)
        handlers.global_refresh() end
    )
end

local function stop_refresh_timer()
    if M.periodic_refresh == nil then
        return
    end
    vim.loop.timer_stop(M.periodic_refresh)
end

local function setup_refresh_timer_focus()
    table.insert(M.autocmds, vim.api.nvim_create_autocmd({"FocusGained"}, {
        callback = function() start_refresh_timer(true) end,
    }))
    table.insert(M.autocmds, vim.api.nvim_create_autocmd({"FocusLost"}, {
        callback = stop_refresh_timer,
    }))
end

local function on_tab_close()
    table.insert(M.autocmds, vim.api.nvim_create_autocmd({"TabClosed", "QuitPre"}, {
        callback = function(args)
            if
                s.pull_state.tab ~= nil
                and s.pull_state.tab == tonumber(args.match)
            then
                M.clean()
            end
        end,
    }))
    table.insert(M.autocmds, vim.api.nvim_create_autocmd({"VimLeave"}, {
        callback = M.clean}))
end

-- open_pull is the entry point for a new pull request and review session.
--
-- a `vim.ui.select` menu is presented to the user to pick a PR to open,
-- once picked a new tab is created and the the pr details and commits are
-- populated in a tree for this tab.
function M.open_pull()
    local prs = ghcli.list_pulls()
    if prs == nil then
        lib_notify.notify_popup_with_timeout("Failed to list PRs", 7500, "error")
        return
    end

    vim.ui.select(
        prs,
        {
            prompt = 'Select a pull request to open:',
            format_item = function(pull)
                return string.format([[%d |  "%s" |  %s]], pull["number"], pull["title"], pull["author"]["login"])
            end,
        },
        function(_, idx)
            if idx == nil then
                return
            end
            if s.pull_state.number ~= nil then
                vim.ui.select(
                    {"no", "yes"},
                    {prompt = string.format('A pull request is already opened, close it and open pull #%s? ', prs[idx]["number"])},
                    function(choice)
                        if choice == "yes" then
                            M.close_pull()
                            handlers.pr_handler(prs[idx]["number"], false, vim.schedule_wrap(function () setup_refresh_timer_focus() on_tab_close() end ))
                        end
                    end
                )
            else
                handlers.pr_handler(prs[idx]["number"], false, vim.schedule_wrap(function () setup_refresh_timer_focus() on_tab_close() end ))
            end
        end
    )
end

function M.open_to_pr()
    local ctx = ui_req_ctx()
    if
        ctx.state == nil or
        ctx.state["pr"] == nil
    then
        lib_notify.notify_popup_with_timeout("Open a pull request first with LTOpenPR.", 7500, "error")
        return
    end
    lib_panel.open_to("pr", ctx.state)
end

function M.popout_to_pr()
    local ctx = ui_req_ctx()
    if
        ctx.state == nil or
        ctx.state["pr"] == nil
    then
        lib_notify.notify_popup_with_timeout("Open a pull request first with LTOpenPR.", 7500, "error")
    end
    lib_panel.popout_to("pr", ctx.state)
end

function M.open_to_pr_files()
    local ctx = ui_req_ctx()
    if
        ctx.state == nil or
        ctx.state["pr_files"] == nil
    then
        lib_notify.notify_popup_with_timeout("Open a pull request commit first.", 7500, "error")
        return
    end
    lib_panel.open_to("pr_files", ctx.state)
end

function M.popout_to_pr_files()
    local ctx = ui_req_ctx()
    if
        ctx.state == nil or
        ctx.state["pr_files"] == nil
    then
        lib_notify.notify_popup_with_timeout("Open a pull request commit first.", 7500, "error")
    end
    lib_panel.popout_to("pr_files", ctx.state)
end

function M.clean()
    -- kill background refresh
    stop_refresh_timer()
    M.periodic_refresh = nil

    -- cleanup litee remotes
    local remotes = gitcli.list_remotes()
    for _, remote in ipairs(remotes) do
        if vim.fn.match(remote, "litee-gh_") ~= -1 then
            gitcli.remove_remote(remote)
        end
    end

    -- delete all autocmds
    for _, id in ipairs(M.autocmds) do
        vim.api.nvim_del_autocmd(id)
    end
    M.autocmds = {}
end

-- TODO add other stuff that needs to be done on pr commits
function M.close_pr_commits(ctx)
    if ctx == nil then
         ctx = ui_req_ctx()
    end
    if ctx.state["pr_files"] == nil then
        return
    end
    if ctx.state["pr_files"].win ~= nil then
        if vim.api.nvim_win_is_valid(ctx.state["pr_files"].win) then
            vim.api.nvim_win_close(ctx.state["pr_files"].win, true)
        end
    end
    if ctx.state["pr_files"].buf ~= nil then
        if vim.api.nvim_buf_is_valid(ctx.state["pr_files"].buf) then
            vim.api.nvim_buf_delete(ctx.state["pr_files"].buf, {force = true})
        end
    end
    if ctx.state["pr_files"].tree ~= nil then
        lib_tree.remove_tree(ctx.state["pr_files"].tree)
    end
    lib_state.put_component_state(ctx.tab, "pr_files", nil)
    M.clean()
end

-- TODO add other stuff that needs to be done on pr reviews
function M.close_pr_review(ctx)
    if ctx == nil then
         ctx = ui_req_ctx()
    end
    if ctx.state["pr_files"] == nil then
        return
    end
    if ctx.state["pr_review"].win ~= nil then
        if vim.api.nvim_win_is_valid(ctx.state["pr_review"].win) then
            vim.api.nvim_win_close(ctx.state["pr_review"].win, true)
        end
    end
    if ctx.state["pr_review"].buf ~= nil then
        if vim.api.nvim_buf_is_valid(ctx.state["pr_review"].buf) then
            vim.api.nvim_buf_delete(ctx.state["pr_review"].buf, {force = true})
        end
    end
    if ctx.state["pr_review"].tree ~= nil then
        lib_tree.remove_tree(ctx.state["pr_review"].tree)
    end
    lib_state.put_component_state(ctx.tab, "pr_review", nil)
end

-- TODO add other stuff that needs to be done on pr close
function M.close_pull()
    local ctx = ui_req_ctx()
    if s.pull_state == nil then
        return
    end

    -- put us in a new tab so we can close windows if we don't have one to change
    -- to.
    local other_tab = nil
    local tabs = vim.api.nvim_list_tabpages()
    for _, t in ipairs(tabs) do
        if t ~= s.pull_state.tab then
            other_tab = t
            vim.api.nvim_set_current_tabpage(other_tab)
        end
    end
    if other_tab == nil then
        vim.cmd("tabnew")
    end

    -- dump all our state
    if ctx.state["pr"].win ~= nil then
        if vim.api.nvim_win_is_valid(ctx.state["pr"].win) then
            vim.api.nvim_win_close(ctx.state["pr"].win, true)
        end
    end
    if ctx.state["pr"].buf ~= nil then
        if vim.api.nvim_buf_is_valid(ctx.state["pr"].buf) then
            vim.api.nvim_buf_delete(ctx.state["pr"].buf, {force = true})
        end
    end
    if ctx.state["pr"].tree ~= nil then
        lib_tree.remove_tree(ctx.state["pr"].tree)
    end

    -- pass in our ctx, since we changed tab pages, current tab from ctx wont
    -- work.
    M.close_pr_commits(ctx)
    M.close_pr_review(ctx)

    -- rip down our pull request tab
    vim.api.nvim_set_current_tabpage(s.pull_state.tab)
    vim.cmd("tabclose")

    -- nil out the pull state
    s.pull_state = nil

    lib_state.put_component_state(ctx.tab, "pr", nil)
end


function M.hide_pr()
    local ctx = ui_req_ctx()
    if ctx.tree_type ~= "pr" then
        return
    end
    if ctx.state["pr"].win ~= nil then
        if vim.api.nvim_win_is_valid(ctx.state["pr"].win) then
            vim.api.nvim_win_close(ctx.state["pr"].win, true)
        end
    end
    if vim.api.nvim_win_is_valid(ctx.state["pr"].invoking_win) then
        vim.api.nvim_set_current_win(ctx.state["pr"].invoking_win)
    end
end

function M.hide_pr_commit()
    local ctx = ui_req_ctx()
    if ctx.tree_type ~= "pr_files" then
        return
    end
    if ctx.state["pr_files"].win ~= nil then
        if vim.api.nvim_win_is_valid(ctx.state["pr_files"].win) then
            vim.api.nvim_win_close(ctx.state["pr_files"].win, true)
        end
    end
    if vim.api.nvim_win_is_valid(ctx.state["pr_files"].invoking_win) then
        vim.api.nvim_set_current_win(ctx.state["pr_files"].invoking_win)
    end
end

function M.hide_pr_review()
    local ctx = ui_req_ctx()
    if ctx.tree_type ~= "pr_review" then
        return
    end
    if ctx.state["pr_review"].win ~= nil then
        if vim.api.nvim_win_is_valid(ctx.state["pr_review"].win) then
            vim.api.nvim_win_close(ctx.state["pr_review"].win, true)
        end
    end
    if vim.api.nvim_win_is_valid(ctx.state["pr_review"].invoking_win) then
        vim.api.nvim_set_current_win(ctx.state["pr_review"].invoking_win)
    end
end

function M.collapse_pr()
    local ctx = ui_req_ctx()
    if
        ctx.state == nil or
        ctx.pr_cursor == nil or
        ctx.state["pr"].tree == nil
    then
        lib_notify.notify_popup_with_timeout("Must open a pull request before starting a review.", 7500, "error")
        return
    end
    local node = ctx.pr_node
    node.expanded = false
    lib_tree.write_tree_no_guide_leaf(
        ctx.state["pr"].buf,
        ctx.state["pr"].tree,
        marshaler.marshal_pr_commit_node
    )
    vim.api.nvim_win_set_cursor(ctx.state["pr"].win, ctx.pr_cursor)
end

function M.expand_pr()
    local ctx = ui_req_ctx()
    if
        ctx.state == nil or
        ctx.pr_cursor == nil or
        ctx.state["pr"].tree == nil
    then
        lib_notify.notify_popup_with_timeout("Must open a pull request before starting a review.", 7500, "error")
        return
    end
    local node = ctx.pr_node
    node.expanded = true
    lib_tree.write_tree_no_guide_leaf(
        ctx.state["pr"].buf,
        ctx.state["pr"].tree,
        marshaler.marshal_pr_commit_node
    )
    vim.api.nvim_win_set_cursor(ctx.state["pr"].win, ctx.pr_cursor)
end

function M.collapse_pr_commits()
    local ctx = ui_req_ctx()
    if
        ctx.state == nil or
        ctx.files_cursor == nil or
        ctx.state["pr_files"].tree == nil
    then
        lib_notify.notify_popup_with_timeout("Must open a pull request commit before starting a review.", 7500, "error")
        return
    end
    local node = ctx.files_node
    node.expanded = false
    lib_tree.write_tree_no_guide_leaf(
        ctx.state["pr_files"].buf,
        ctx.state["pr_files"].tree,
        marshaler.marshal_pr_file_node
    )
    vim.api.nvim_win_set_cursor(ctx.state["pr_files"].win, ctx.files_cursor)
end

function M.expand_pr_commits()
    local ctx = ui_req_ctx()
    if
        ctx.state == nil or
        ctx.file_cursor == nil or
        ctx.state["pr_files"].tree == nil
    then
        lib_notify.notify_popup_with_timeout("Must open a pull request commit before starting a review.", 7500, "error")
        return
    end
    local node = ctx.files_node
    node.expanded = true
    lib_tree.write_tree_no_guide_leaf(
        ctx.state["pr_files"].buf,
        ctx.state["pr_files"].tree,
        marshaler.marshal_pr_file_node
    )
    vim.api.nvim_win_set_cursor(ctx.state["pr_files"].win, ctx.files_cursor)
end

function M.collapse_pr_review()
    local ctx = ui_req_ctx()
    if
        ctx.state == nil or
        ctx.review_cursor == nil or
        ctx.state["pr_review"].tree == nil
    then
        lib_notify.notify_popup_with_timeout("Must open a pull request commit before starting a review.", 7500, "error")
        return
    end
    local node = ctx.review_node
    node.expanded = false
    lib_tree.write_tree_no_guide_leaf(
        ctx.state["pr_review"].buf,
        ctx.state["pr_review"].tree,
        marshaler.marshal_pr_file_node
    )
    vim.api.nvim_win_set_cursor(ctx.state["pr_review"].win, ctx.review_cursor)
end

function M.expand_pr_review()
    local ctx = ui_req_ctx()
    if
        ctx.state == nil or
        ctx.review_cursor == nil or
        ctx.state["pr_review"].tree == nil
    then
        lib_notify.notify_popup_with_timeout("Must open a pull request commit before starting a review.", 7500, "error")
        return
    end
    local node = ctx.review_node
    node.expanded = true
    lib_tree.write_tree_no_guide_leaf(
        ctx.state["pr_review"].buf,
        ctx.state["pr_review"].tree,
        marshaler.marshal_pr_file_node
    )
    vim.api.nvim_win_set_cursor(ctx.state["pr_review"].win, ctx.review_cursor)
end

-- open_commit will open a commit inside the "pull request commits" litee panel.
--
-- opening a commit will load the "edited files" litee panel showing the files
-- edited in the opened commit.
function M.open_commit()
    local ctx = ui_req_ctx()
    if
        ctx.state == nil or
        ctx.state["pr"] == nil or
        ctx.state["pr"].tree == nil or
        ctx.commits_node == nil or
        ctx.commits_node.commit == nil
    then
        return
    end

    -- root of pr is the pr object holding the commits.
    local commit = ctx.commits_node.commit
    handlers.commits_handler(commit["sha"])
end

-- open_file will open a particular edited file from an opened commit.
--
-- when the file is opened the pull request tab page will be split into a
-- diff between version at the commit's HEAD and the version at the commit's
-- parent.
function M.open_file()
    local ctx = ui_req_ctx()
    if
        ctx.state == nil or
        ctx.state["pr_files"] == nil or
        ctx.state["pr_files"].tree == nil or
        ctx.files_node == nil
    then
        return
    end

    -- root of pr_files tree is the commit object holding the edited files.
    local commit = lib_tree.get_tree(ctx.state["pr_files"].tree).root.commit
    local file = ctx.files_node.file
    diff_view.open_diffsplit(commit,file)
    if ctx.files_cursor ~= nil then
        vim.api.nvim_win_set_cursor(ctx.state["pr_files"].win, ctx.files_cursor)
    end
end

function M.start_review()
    if s.pull_state == nil then
        lib_notify.notify_popup_with_timeout("Must open a pull request before starting a review.", 7500, "error")
        return
    end
    local review = ghcli.create_review(s.pull_state.number, s.pull_state.head)
    s.pull_state.review = review
    vim.cmd("GHRefreshPR")
end

function M.delete_review()
    if
        s.pull_state == nil or
        s.pull_state.review == nil
    then
        return
    end
    local out = ghcli.delete_review(s.pull_state.number, s.pull_state.review["id"])
    if out == nil then
        lib_notify.notify_popup_with_timeout("Failed to delete pending review.", 7500, "error")
        return
    end
    s.pull_state.review = nil
    -- refresh pr, any pending comments in the review will be removed.
    vim.cmd("GHRefreshPR")
end

function M.submit_review()
    if s.pull_state == nil then
        return
    end
    if s.pull_state.review == nil then
        lib_notify.notify_popup_with_timeout("No review in progress.", 7500, "error")
        return
    end

    local action = nil

    function cb(action, body)
        local actions = {
            'APPROVE',
            'REQUEST_CHANGES',
            'COMMENT'
        }
        if body ~= nil then
            body = vim.fn.shellescape(body)
        end
        local out = ghcli.submit_review(s.pull_state["number"], s.pull_state.review["id"], body, actions[action])
        if out == nil then
            lib_notify.notify_popup_with_timeout("Failed to submit review", 7500, "error")
            return
        end
        vim.cmd("GHRefreshPR")
    end

    vim.ui.select(
        {"approve", "request changes", "comment"},
        {prompt="Select a submit action: "},
        function(_, idx)
            action = idx
            vim.ui.select(
                {"yes", "no"},
                {prompt="Include a comment with this review?"},
                function(_, comment)
                    if comment == 1 then
                        vim.ui.input(
                            {prompt = "Enter review submit comment: "},
                            function(input)
                                cb(action, input)
                            end
                        )
                    else
                        cb(action, nil)
                    end
                end
            )
        end)
end

function M.test_thread()
    local id = nil
    for idd, _ in pairs(s.pull_state.review_threads_by_id) do
        id = idd
        break
    end

    local buf = thread_buffer.render_thread(id)
    vim.api.nvim_win_set_buf(0, buf)
end

local function open_pr_node(ctx, node)
    if node.pr ~= nil then
        local buf = pr_buffer.render_comments()
        local invoking_win = ctx.state["pr"].invoking_win
        if
            invoking_win ~= nil and
            vim.api.nvim_win_is_valid(invoking_win)
        then
            vim.api.nvim_win_set_buf(invoking_win, buf)
        else
            local cur_win = vim.api.nvim_get_current_win()
            vim.cmd("wincmd h")
            if vim.api.nvim_get_current_win() == cur_win then
                vim.cmd("vsplit")
                vim.cmd("wincmd H")
            end
            vim.api.nvim_win_set_buf(0, buf)
        end
    end
    if node.commit ~= nil then
        handlers.commits_handler(node.commit["sha"])
    end
    if node.thread ~= nil then
         -- checkout head if we are opening a thread from "Conversations:" tree.
         local out = gitcli.checkout(nil, s.pull_state.head)
         if out == nil then
            lib_notify.notify_popup_with_timeout("Failed to checkout head.", 7500, "error")
         end

        local commit = s.pull_state.commits_by_sha[s.pull_state.head]
        local file = s.pull_state.files_by_name[node.thread["path"]]
        if file == nil then
            return
        end
        diff_view.open_diffsplit(commit, file, node.thread)
    end
    if node.comment ~= nil then
         -- checkout head if we are opening a thread from "Conversations:" tree.
        local out = gitcli.checkout(nil, s.pull_state.head)
        if out == nil then
            lib_notify.notify_popup_with_timeout("Failed to checkout head.", 7500, "error")
        end

        local thread = s.pull_state.review_threads_by_id[node.comment["thread_id"]]
        local commit = s.pull_state.commits_by_sha[s.pull_state.head]
        local file = s.pull_state.files_by_name[thread.thread["path"]]
        if file == nil then
            return
        end
        diff_view.open_diffsplit(commit, file, thread.thread)
    end
    if node.review ~= nil then
        handlers.review_handler(node.review["node_id"])
        return
    end
end

function M.open_pr_buffer()
    local buf = pr_buffer.render_comments()
    vim.api.nvim_win_set_buf(0, buf)
end

local function open_pr_files_node(ctx, node)
    if node.file ~= nil then
        local tree = lib_tree.get_tree(ctx.state["pr_files"].tree)
        local commit = tree.root.commit
        diff_view.open_diffsplit(commit, node.file)
    end
    if node.thread ~= nil then
        local tree = lib_tree.get_tree(ctx.state["pr_files"].tree)
        local commit = tree.root.commit
        -- try to use the file object directly from the commit we have opened.
        local file = nil
        for _, f in ipairs(commit["files"]) do
            if f.filename == node.thread["path"] then
                file = f
            end
        end
        if file == nil then
            file = s.pull_state.files_by_name[node.thread["path"]]
        end
        diff_view.open_diffsplit(commit, file, node.thread)
    end
    if node.comment ~= nil then
        local thread = s.pull_state.review_threads_by_id[node.comment["thread_id"]]
        local tree = lib_tree.get_tree(ctx.state["pr_files"].tree)
        local commit = tree.root.commit
        -- try to use the file object directly from the commit we have opened.
        local file = nil
        for _, f in ipairs(commit["files"]) do
            if f.filename == thread.thread["path"] then
                file = f
            end
        end
        if file == nil then
            file = s.pull_state.files_by_name[thread.thread["path"]]
        end
        diff_view.open_diffsplit(commit, file, thread.thread)
    end
end

local function open_pr_review_node(ctx, node)
    if node.thread ~= nil then
         -- checkout head if we are opening a thread from "Conversations:" tree.
         local out = gitcli.checkout(nil, s.pull_state.head)
         if out == nil then
            lib_notify.notify_popup_with_timeout("Failed to checkout head.", 7500, "error")
         end

        local commit = s.pull_state.commits_by_sha[s.pull_state.head]
        local file = s.pull_state.files_by_name[node.thread["path"]]
        if file == nil then
            return
        end
        diff_view.open_diffsplit(commit, file, node.thread)
    end
    if node.comment ~= nil then
         -- checkout head if we are opening a thread from "Conversations:" tree.
        local out = gitcli.checkout(nil, s.pull_state.head)
        if out == nil then
            lib_notify.notify_popup_with_timeout("Failed to checkout head.", 7500, "error")
        end

        local thread = s.pull_state.review_threads_by_id[node.comment["thread_id"]]
        local commit = s.pull_state.commits_by_sha[s.pull_state.head]
        local file = s.pull_state.files_by_name[thread.thread["path"]]
        if file == nil then
            return
        end
        diff_view.open_diffsplit(commit, file, thread.thread)
    end
end

function M.details_pr()
    local ctx = ui_req_ctx()
    if ctx.pr_node ~= nil then
        lib_details.details_popup(ctx.state, ctx.pr_node, pr_details.details_func)
        return
    end
end

function M.details_pr_files()
    local ctx = ui_req_ctx()
    if ctx.files_node ~= nil then
        lib_details.details_popup(ctx.state, ctx.files_node, pr_details.details_func)
        return
    end
end

function M.details_pr_review()
    local ctx = ui_req_ctx()
    if ctx.review_node ~= nil then
        lib_details.details_popup(ctx.state, ctx.review_node, pr_details.details_func)
        return
    end
end

-- convenience function to re-marshal all the trees, useful as a callback for
-- removing notifications.
local function write_trees(ctx)
    local args = {
        {"pr", marshaler.marshal_pr_commit_node},
        {"pr_files", marshaler.marshal_pr_file_node},
        {"pr_review", marshaler.marshal_pr_commit_node},
    }
    for _, arg in ipairs(args) do
        if
            ctx.state[arg[1]] ~= nil and
            ctx.state[arg[1]].tree ~= nil
        then
            local old_cursor = nil
            if
                ctx.state[arg[1]].win ~= nil and
                not vim.api.nvim_win_is_valid(ctx.state[arg[1]].win)
            then
                old_cursor = vim.api.nvim_win_get_cursor(ctx.state[arg[1]].win)
            end
            lib_tree.write_tree_no_guide_leaf(
                ctx.state[arg[1]].buf,
                ctx.state[arg[1]].tree,
                arg[2]
            )
            if old_cursor ~= nil then
                lib_util.safe_cursor_reset(ctx.state[arg[1]].win, old_cursor)
            end
        end
    end
end

-- convenience function to remove notifications on an object and potentially
-- its children.
local function remove_notifications(ctx, node)
    if node.thread ~= nil then
        for _, c in ipairs(node.children) do
            s.remove_notification(c.name)
        end
    end
    s.remove_notification(node.name)
    write_trees(ctx)
end

function M.open_node_pr()
    local ctx = ui_req_ctx()
    if ctx.pr_node ~= nil then
        open_pr_node(ctx, ctx.pr_node)
        remove_notifications(ctx, ctx.pr_node)
    end
    lib_util.safe_cursor_reset(ctx.state["pr"].win, ctx.pr_cursor)
end

function M.open_node_files()
    local ctx = ui_req_ctx()
    if ctx.files_node ~= nil then
        open_pr_files_node(ctx, ctx.files_node)
        remove_notifications(ctx, ctx.files_node)
    end
    lib_util.safe_cursor_reset(ctx.state["pr_files"].win, ctx.files_cursor)
end

function M.open_node_review()
    local ctx = ui_req_ctx()
    if ctx.review_node ~= nil then
        open_pr_review_node(ctx, ctx.review_node)
        remove_notifications(ctx, ctx.review_node)
    end
    lib_util.safe_cursor_reset(ctx.state["pr_review"].win, ctx.review_cursor)
end

function M.add_label()
    if s.pull_state == nil then
        return
    end
    ghcli.list_labels_async(function(err, data) 
        if err then
            vim.schedule(function () lib_notify.notify_popup_with_timeout("Failed to list labels: " .. err, 7500, "error") end)
            return
        end
        vim.schedule(function() vim.ui.select(
            data,
            {
                prompt = "Select a label to add ",
                format_item = function(item)
                    return item["name"]
                end
            },
            function(choice) 
                ghcli.add_label_async(s.pull_state["number"], choice["name"], function(err, data)
                    if err then
                        vim.schedule(function () lib_notify.notify_popup_with_timeout("Failed to add label: " .. err, 7500, "error") end)
                        return
                    end
                    handlers.global_refresh()
                end)
            end
        )end)
    end)
end

return M
