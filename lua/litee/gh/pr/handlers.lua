local lib_state     = require('litee.lib.state')
local lib_tree      = require('litee.lib.tree')
local lib_notify    = require('litee.lib.notify')
local lib_tree_node = require('litee.lib.tree.node')
local lib_panel     = require('litee.lib.panel')
local lib_util      = require('litee.lib.util')

local s             = require('litee.gh.pr.state')
local pr_state      = require('litee.gh.pr.state')
local details       = require('litee.gh.pr.details')
local commits       = require('litee.gh.pr.commits')
local conversations = require('litee.gh.pr.conversations')
local comments      = require('litee.gh.pr.comments')
local config        = require('litee.gh.config').config
local ghcli         = require('litee.gh.ghcli')
local gitcli        = require('litee.gh.gitcli')
local marshaller    = require('litee.gh.pr.marshal')
local diff_view     = require('litee.gh.pr.diff_view')
local thread_buffer = require('litee.gh.pr.thread_buffer')
local pr_buffer     = require('litee.gh.pr.pr_buffer')
local reviews       = require('litee.gh.pr.reviews')
local checks        = require('litee.gh.pr.checks')

local M = {}

-- ui_handler is a blocking operation which (re)loads the ui elements with the
-- latest state,
--
-- refresh will simply reload the current data in state and paint the ui, skipping
-- any git operations to setup the underlying repository or other side effects.
--
-- on_load_ui can be provided as a blocking or async callback ran once the UI
-- is loaded.
function M.ui_handler(refresh, on_load_ui)
    local cur_win = vim.api.nvim_get_current_win()
    local cur_tabpage = vim.api.nvim_win_get_tabpage(cur_win)
    local state_was_nil = false

    -- refresh var from closure.
    if not refresh then
        local remote_url = ""
        if config.prefer_https_remote then
            remote_url = s.pull_state.pr_raw["head"]["repo"]["clone_url"]
        else
            remote_url = s.pull_state.pr_raw["head"]["repo"]["ssh_url"]
        end
        local remote_name = "litee-gh_" .. s.pull_state.pr_raw["head"]["repo"]["full_name"]
        local head_branch = s.pull_state.pr_raw["head"]["ref"]

        -- if the current repo is dirty we can't continue, since we will eventually
        -- checkout commits of the pull request.
        if gitcli.repo_dirty() then
            lib_notify.notify_popup_with_timeout("Cannot open pull request because repository has changes. Stash changes and try again.", 7500, "error")
            return
        end
        -- if we don't have the remote HEAD then add it and fetch the branch by ref
        -- name.
        --
        -- if it exists the remote name is returned turned.
        local ok, remote = gitcli.remote_exists(remote_url)
        if not ok then
            local out = gitcli.add_remote(remote_name, remote_url)
            if out == nil then
                lib_notify.notify_popup_with_timeout("Failed to add remote git repository.", 7500, "error")
                return
            end
        else
            remote_name = remote
        end
        -- fetch the remote branch so the commits under review are locally accessible.
        local out = gitcli.fetch(remote_name, head_branch)
        if out == nil then
            lib_notify.notify_popup_with_timeout("Failed to fetch remote branch.", 7500, "error")
            return
        end
    end

    -- setup state for the pr component
    local state = lib_state.get_component_state(cur_tabpage, "pr")
    if state == nil then
        state = {}
        -- if state.tree ~= nil then
        --     lib_tree.remove_tree(state.tree)
        -- end
        state.tree = lib_tree.new_tree("pr")
        state.invoking_win = vim.api.nvim_get_current_win()
        state.tab = cur_tabpage
    end
    s.pull_state.tab = state.tab

    local prev_tree = lib_tree.get_tree(state.tree)

    -- dynamic set of subtrees to create
    local subtrees = {}

    -- create our root node for the "pr" component, the root holds a
    -- reference to the github API's pull request structure.
    local pr_root = lib_tree_node.new_node(
        s.pull_state.number,
        s.pull_state.number,
        0
    )
    pr_root.pr = s.pull_state.pr_raw
    pr_root.children = subtrees

    -- build root's details sub-tree
    local details_subtree = details.build_details_tree(s.pull_state.pr_raw, 1, prev_tree)
    table.insert(subtrees, details_subtree)

    -- build commits subtree
    local commits_subtree = commits.build_commits_tree(s.pull_state.commits, 1, prev_tree)
    table.insert(subtrees, commits_subtree)

    -- build reviews subtree
    local reviews_subtree = reviews.build_reviews_subtree(1, prev_tree)
    if #reviews_subtree.children > 0 then
        table.insert(subtrees, reviews_subtree)
    end

    -- build converstation subtree
    local conversations_subtree = conversations.build_conversations_tree(s.pull_state.review_threads_raw, 1, prev_tree)
    if #conversations_subtree.children > 0 then
        table.insert(subtrees, conversations_subtree)
    end

    -- build checks subtree
    local checks_subtree = checks.build_checks_tree(s.pull_state.check_runs, 1, prev_tree)
    if #checks_subtree.children > 0 then
        table.insert(subtrees, checks_subtree)
    end

    -- register our pr_root as the root of our new tree.
    lib_tree.add_node(state.tree, pr_root, "", true)

    -- update component state and grab the global since we need it to toggle
    -- the panel open.
    local global_state = lib_state.put_component_state(cur_tabpage, "pr", state)

    -- state was not nil, can we reuse the existing win
    -- and buffer?
    if
        (not state_was_nil
        and state.win ~= nil
        and vim.api.nvim_win_is_valid(state.win)
        and state.buf ~= nil
        and vim.api.nvim_buf_is_valid(state.buf))
        or refresh
    then
        lib_tree.write_tree_no_guide_leaf(
            state.buf,
            state.tree,
            marshaller.marshal_pr_commit_node
        )
    else
        -- we have no state, so open up the panel or popout to create
        -- a window and buffer.
        if config.on_open == "popout" then
            lib_panel.popout_to("pr", global_state)
        else
            lib_panel.toggle_panel(global_state, true, false)
        end
    end
    if not refresh then
        local buf = pr_buffer.render_comments()
        vim.api.nvim_win_set_buf(0, buf)
    end

    if on_load_ui ~= nil then
        on_load_ui()
    end
end

function M.pr_handler(pull_number, refresh, on_load_ui)
    pr_state.load_state_async(pull_number, vim.schedule_wrap(
        function() M.ui_handler(refresh, on_load_ui) end
    ))
end

local function shallow_copy(thread)
    -- do a shallow clone of threads, only updating the depth scaler but
    -- not copying larger data structures.
    local t_copy = {}
    for k, v in pairs(thread) do
        t_copy[k] = v
    end
    t_copy["depth"] = 1
    local t_copy_children = {}
    for _, child in ipairs(t_copy.children) do
        local function scopy(c)
            local c_copy = {}
            for k, v in pairs(c) do
                c_copy[k] = v
            end
            c_copy["depth"] = 2
            return c_copy
        end
        local c_copy = scopy(child)
        table.insert(t_copy_children, c_copy)
    end
    t_copy.children = t_copy_children
    return t_copy
end

function M.review_handler(review_id, refresh)
    local cur_win = vim.api.nvim_get_current_win()
    local cur_tabpage = vim.api.nvim_win_get_tabpage(cur_win)
    local state_was_nil = false

    -- setup state for the pr_review component
    local state = lib_state.get_component_state(cur_tabpage, "pr_review")
    if state == nil then
        state = {}
        -- create new tree, throwing old one out if exists
        if state.tree ~= nil then
            lib_tree.remove_tree(state.tree)
        end
        state.tree = lib_tree.new_tree("pr_review")
        -- store the window invoking the filetree, jumps will
        -- occur here.
        state.invoking_win = vim.api.nvim_get_current_win()
        -- store the tab which invoked the filetree.
        state.tab = cur_tabpage
    end

    local review = s.pull_state.reviews_by_node_id[review_id]
    if review == nil then
        return
    end

    -- root is a pr_review is the commit
    local root = lib_tree_node.new_node(
        review["id"],
        review["id"],
        0
    )
    root.review = review
    root.expanded = true

    -- find all threads we know of with this review id
    local children = {}
    for _, t in pairs(s.pull_state.review_threads_by_id) do
        if
            t.thread["review_id"] ~= nil and
            t.thread["review_id"] == review_id
        then
            -- do a shallow clone of threads, only updating the depth scaler but
            -- not copying larger data structures.
            local t_copy = shallow_copy(t)
            table.insert(children, t_copy)
        end
    end
    for _, child in ipairs(children) do
        table.insert(root.children, child)
    end

    lib_tree.add_node(state.tree, root, "", true)

    -- update component state and grab the global since we need it to toggle
    -- the panel open.
    local global_state = lib_state.put_component_state(cur_tabpage, "pr_review", state)

    -- state was not nil, can we reuse the existing win
    -- and buffer?
    local cursor = nil
    if
        (not state_was_nil
        and state.win ~= nil
        and vim.api.nvim_win_is_valid(state.win)
        and state.buf ~= nil
        and vim.api.nvim_buf_is_valid(state.buf))
        or (refresh
            and state.win ~= nil
            and vim.api.nvim_win_is_valid(state.win)
            and state.buf ~= nil
            and vim.api.nvim_buf_is_valid(state.buf))
    then
        cursor = vim.api.nvim_win_get_cursor(state.win)
        lib_tree.write_tree_no_guide_leaf(
            state.buf,
            state.tree,
            marshaller.marshal_pr_commit_node
        )
    else
        -- we have no state, so open up the panel or popout to create
        -- a window and buffer.
        if config.on_open == "popout" then
            lib_panel.popout_to("pr_review", global_state)
        else
            lib_panel.toggle_panel(global_state, true, false)
        end
    end

    if cursor ~= nil then
        lib_util.safe_cursor_reset(state.win, cursor)
    end
end

-- commits_handler handles the request for viewing a pull request commit.
function M.commits_handler(sha, refresh)
    local cur_win = vim.api.nvim_get_current_win()
    local cur_tabpage = vim.api.nvim_win_get_tabpage(cur_win)
    local state_was_nil = false

    if not refresh then
        -- won't check out commit unless repo is clean.
        if gitcli.repo_dirty() then
            lib_notify.notify_popup_with_timeout("Cannot checkout selected commit because repository has changes. Stash changes and try again.", 7500, "error")
            return
        end
    end

    -- setup state for the pr_files component
    local state = lib_state.get_component_state(cur_tabpage, "pr_files")
    if state == nil then
        state = {}
        -- create new tree, throwing old one out if exists
        if state.tree ~= nil then
            lib_tree.remove_tree(state.tree)
        end
        state.tree = lib_tree.new_tree("pr_files")
        -- store the window invoking the filetree, jumps will
        -- occur here.
        state.invoking_win = vim.api.nvim_get_current_win()
        -- store the tab which invoked the filetree.
        state.tab = cur_tabpage
    end

    local pull_commit = s.pull_state.commits_by_sha[sha]
    if pull_commit == nil then
        return
    end

    local commit = ghcli.get_commit(pull_commit["sha"])
    if commit == nil then
        lib_notify.notify_popup_with_timeout("Failed to retrieve commit.", 7500, "error")
        return
    end

    -- root is a pr_files is the commit
    local root = lib_tree_node.new_node(
        commit["sha"],
        commit["sha"],
        0
    )
    root.commit = commit
    root.location = nil

    -- edited files in this commit are the children
    local children = {}
    local first_file = nil
    for i, file in ipairs(commit["files"]) do
        local child_node = lib_tree_node.new_node(
            file["filename"],
            file["filename"],
            1
        )
        child_node.file = file
        child_node.expanded = true
        table.insert(children, child_node)
        -- if threads exist for this file add them as children
        if s.pull_state.review_threads_by_filename[file["filename"]] ~= nil then
            child_node.children = s.pull_state.review_threads_by_filename[file["filename"]]
        end
        if i == 1 then
            first_file = file
        end
    end

    lib_tree.add_node(state.tree, root, children)

    -- update component state and grab the global since we need it to toggle
    -- the panel open.
    local global_state = lib_state.put_component_state(cur_tabpage, "pr_files", state)

    -- state was not nil, can we reuse the existing win
    -- and buffer?
    local cursor = nil
    if
        (not state_was_nil
        and state.win ~= nil
        and vim.api.nvim_win_is_valid(state.win)
        and state.buf ~= nil
        and vim.api.nvim_buf_is_valid(state.buf))
        or (refresh
            and state.win ~= nil
            and vim.api.nvim_win_is_valid(state.win)
            and state.buf ~= nil
            and vim.api.nvim_buf_is_valid(state.buf))
    then
        cursor = vim.api.nvim_win_get_cursor(state.win)
        lib_tree.write_tree_no_guide_leaf(
            state.buf,
            state.tree,
            marshaller.marshal_pr_file_node
        )
    else
        -- we have no state, so open up the panel or popout to create
        -- a window and buffer.
        if config.on_open == "popout" then
            lib_panel.popout_to("pr_files", global_state)
        else
            lib_panel.toggle_panel(global_state, true, false)
        end
    end

    -- checkout the commit locally, we already did a fetch for the branch when
    -- opening the pull request
    local out = gitcli.checkout(nil, commit["sha"])
    if out == nil then
       lib_notify.notify_popup_with_timeout("Failed to checkout commit.", 7500, "error")
    end

     -- if we recorded a cursor restore it
    if cursor ~= nil then
       lib_util.safe_cursor_reset(state.win, cursor)
    else
       -- put cursor on first file in the window, we are about to open it.
       lib_util.safe_cursor_reset(state.win, {2,0})
    end

    if not refresh then
         -- open first child in split
        diff_view.open_diffsplit(commit, first_file)
    end

    state.last_opened_commit = commit
end

local function on_refresh()
        M.ui_handler(true)

        -- refresh the "pr_files" component if we have a valid tree, commit is on tree's root.
        local comp_state = lib_state.get_component_state(s.pull_state.tab, "pr_files")
        if
            comp_state ~= nil and
            comp_state.tree ~= nil
        then
            local tree = lib_tree.get_tree(comp_state.tree)
            local commit = tree["root"].commit
            M.commits_handler(commit["sha"], true)
        end

        -- refresh the "review" component if we have a valid tree, review is on tree's root.
        comp_state = lib_state.get_component_state(s.pull_state.tab, "review")
        if
            comp_state ~= nil and
            comp_state.tree ~= nil
        then
            local tree = lib_tree.get_tree(comp_state.tree)
            local review = tree["root"].commit
            M.review_handler(review["id"], true)
        end

        -- refresh auxiliary UI components.
        diff_view.on_refresh()
        -- thread_buffer.on_refresh()
        pr_buffer.render_comments()
end

-- global refresh will reload all aspects of a PR and handle discrepencies from
-- our local state and the new state.
function M.global_refresh()
    M.pr_handler(s.pull_state.number, true, vim.schedule_wrap(on_refresh))
end

-- refresh pull request comments only and reload the UI components to reflect
-- any new messages.
function M.refresh_comments()
    s.get_pull_issue_comments_async(s.pull_state["number"], function()
        s.get_reviews_async(s.pull_state["number"], s.pull_state.user["login"], function()
            s.get_review_threads_async(s.pull_state["number"], vim.schedule_wrap(on_refresh))
        end)
    end)
end

return M
