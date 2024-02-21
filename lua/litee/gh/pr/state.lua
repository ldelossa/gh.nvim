local lib_notify    = require('litee.lib.notify')

local ghcli         = require('litee.gh.ghcli')
local gitcli        = require('litee.gh.gitcli')
local comments      = require('litee.gh.pr.comments')
local config        = require('litee.gh.config').config

local M = {}

-- fence map is used by state writing functions to ensure they do not write
-- stale data into state.
--
-- stale data can happen during async `gh` cli calls.
M.fence_map = {}

-- pull_state_proto is the prototype for a singleton pull request state.
-- see M.pull_state for more details.
local pull_state_proto = {
    -- the owning tab of the pull request. only a single pull request can be
    -- opened at a time and it owns a particular tab.
    tab             = nil,
    -- pull request number of the last valid pull request.
    number          = nil,
    -- the PR object as returned by the Github API.
    pr_raw = nil,
    -- issue comments are comment nodes which live on the front page of a pull
    -- request. they are not affiliated with any unified diff.
    issue_comments = nil,
    -- issue comments by id groups the above by their API id.
    issue_comments_by_id = nil,
    -- maps review comment threads by their ids. the actual trees are ready
    -- to be attached to files in the "pr_files" component.
    review_threads_by_id = nil,
    review_thread_comments_by_id = nil,
    -- maps review comment threads by the file they were created on.
    -- the actual trees are ready to be attached to files in the "pr_files"
    -- component
    review_threads_by_filename = nil,
    -- a list of review threads for this PR as returned by Github API.
    review_threads_raw = nil,
    -- commits are the commit nodes in the pull request.
    commits = nil,
    -- holds commit nodes mapped by their sha
    commits_by_sha = nil,
    -- top commit of PR, useful when making review comments or other api calls
    -- which expect HEAD as commit_id.
    head = nil,
    -- if not nil, a pending review the user created. all comments will be created
    -- in the context of the review while this is non-nil.
    review = nil,
    -- db of reviews by their graphql node ids. useful for grouping threads and
    -- comments to reviews.
    reviews_by_node_id = nil,
    -- user data as returned by ghcli.get_user()
    user = nil,
    -- file objects in this pr indexed by their file paths.
    files_by_name = nil,
    -- when the state gather functions write new state they will record any objects
    -- which are not currently in state and write their ids here. this serves
    -- as a way to indicate new items and paint a notification icon.
    notifications_by_id = nil,
    -- any checks to run for the current HEAD.
    check_runs = {}
}

-- pull_state holds the state of our singleton pull request.
--
-- since litee-gh pull requests manipulate the git repository, only a single
-- pull request and review session can take place at once.
--
-- this state will be used for reconciling the UI, ensuring its in a good state
-- before issuing opertations such as opening a commit or modified file.
M.pull_state = nil

-- last opened commit in by commits_handler
M.last_opened_commit = nil

function M.pull_is_valid()
    return vim.api.nvim_tabpage_is_valid(M.pull_state.tab)
end

function M.reset_pull_state()
    M.pull_state = {
        -- the owning tab of the pull request. only a single pull request can be
        -- opened at a time and it owns a particular tab.
        tab             = nil,
        -- pull request number of the last valid pull request.
        number          = nil,
        -- the PR object as returned by the Github API.
        pr_raw = nil,
        -- issue comments are comment nodes which live on the front page of a pull
        -- request. they are not affiliated with any unified diff.
        issue_comments = nil,
        -- issue comments by id groups the above by their API id.
        issue_comments_by_id = nil,
        -- maps review comment threads by their ids. the actual trees are ready
        -- to be attached to files in the "pr_files" component.
        review_threads_by_id = nil,
        review_thread_comments_by_id = nil,
        -- maps review comment threads by the file they were created on.
        -- the actual trees are ready to be attached to files in the "pr_files"
        -- component
        review_threads_by_filename = nil,
        -- a list of review threads for this PR as returned by Github API.
        review_threads_raw = nil,
        -- commits are the commit nodes in the pull request.
        commits = nil,
        -- holds commit nodes mapped by their sha
        commits_by_sha = nil,
        -- top commit of PR, useful when making review comments or other api calls
        -- which expect HEAD as commit_id.
        head = nil,
        -- if not nil, a pending review the user created. all comments will be created
        -- in the context of the review while this is non-nil.
        review = nil,
        -- db of reviews by their graphql node ids. useful for grouping threads and
        -- comments to reviews.
        reviews_by_node_id = nil,
        -- user data as returned by ghcli.get_user()
        user = nil,
        -- file objects in this pr indexed by their file paths.
        files_by_name = nil,
        -- when the state gather functions write new state they will record any objects
        -- which are not currently in state and write their ids here. this serves
        -- as a way to indicate new items and paint a notification icon.
        notifications_by_id = nil,
        -- any checks to run for the current HEAD.
        check_runs = {}
    }
end

local function add_fence(name)
    local n = 1
    if M.fence_map[name] == nil then
        M.fence_map[name] = n
        return n
    end
    M.fence_map[name] = M.fence_map[name] + 1
    return M.fence_map[name]
end

-- check fence checks if the same function updated state after the provided
-- fence_id was created.
local function check_fence(name, fence_id)
    if M.fence_map[name] == nil then
        return false
    end
    if M.fence_map[name] == fence_id then
        return true
    else
        return false
    end
end

function M.remove_notification(id, cb)
    M.pull_state.notifications_by_id[id] = nil
    if cb ~= nil then
        cb()
    end
end

local spinner_state = -1
local function spinner()
    local spinners = {[0] = "⣾", [1] = "⣽", [2] = "⣻", [3] = "⢿", [4] = "⡿", [5] = "⣟", [6] = "⣯", [7] = "⣷"}
    spinner_state = spinner_state + 1
    return spinners[spinner_state%8]
end

function M.get_check_runs(cb)
    vim.schedule(function() vim.api.nvim_echo({{spinner() .. " fetching checks", "LTInfo"}}, false, {}) end)
    local fence_id = add_fence("get_check_runs")
    ghcli.get_check_suites_async(M.pull_state.head, function(err, data)
        if err then
            vim.schedule(function () lib_notify.notify_popup_with_timeout("Failed to fetch check suites: " .. err, 7500, "error") end)
        end
        if not check_fence("get_check_runs", fence_id) then
            cb()
            return
        end
        local suite_counter = 0
        local check_runs = {}
        if M.pull_state.check_runs == nil then
            M.pull_state.check_runs = {}
        end
        if #data["check_suites"] > 0 then -- if we need to, go get the check runs for the suites we found.
            for _, suite in ipairs(data["check_suites"]) do
                ghcli.get_check_runs_by_suite(suite["id"], function(err1, runs)
                    if err1 then
                        vim.schedule(function () lib_notify.notify_popup_with_timeout("Failed to fetch check runs: " .. err, 7500, "error") end)
                        return
                    end
                    for _, run in ipairs(runs["check_runs"]) do
                        table.insert(check_runs, run)
                    end
                    suite_counter = suite_counter + 1
                    if suite_counter == #data["check_suites"] then
                        -- last suite was handled, swap our checks dict and call
                        -- cb()
                        M.pull_state.check_runs = check_runs
                        cb()
                    end
                end)
            end
        end
        cb()
    end)
end

local function should_reset(old_commits, new_commits)
    -- history squashed or changed.
    if #old_commits > #new_commits then
        return true
    end
    -- at least one commit in the history has been rebased.
    for i, oc in ipairs(old_commits) do
        local nc = new_commits[i]
        if oc["sha"] ~= nc["sha"] then
            return true
        end
    end
    return false
end

local function should_fetch(old_commits, new_commits)
    if #old_commits < #new_commits then
        return true
    end
    return false
end

local function git_fetch()
    local remote_url = M.get_pr_remote_url()
    local ok, remote = gitcli.remote_exists(remote_url)
    if not ok then
        -- really shouldn't happen
        lib_notify.notify_popup_with_timeout("New commits added, wanted to fetch but couldn't determine remote", 7500, "error")
        return false
    end
    -- fetch the remote branch so the commits under review are locally accessible.
    local head_branch = M.pull_state.pr_raw["head"]["ref"]
    local out = gitcli.fetch(remote, head_branch)
    if out == nil then
        lib_notify.notify_popup_with_timeout("Failed to fetch remote branch.", 7500, "error")
        return
    end
    local head_sha = M.pull_state.pr_raw["head"]["sha"]
    local out_head_sha = gitcli.fetch(remote, head_sha)
    if out_head_sha == nil then
        lib_notify.notify_popup_with_timeout("Failed to fetch remote base commit.", 7500, "error")
        return
    end
    return true
end

local function git_reset()
    if gitcli.repo_dirty() then
        lib_notify.notify_popup_with_timeout("Git history has changed, want to reset to remote but repo is dirty. Please stash changes and run GHRefreshPR", 7500, "error")
        return false
    end
    local remote_url = M.get_pr_remote_url()
    local ok, remote = gitcli.remote_exists(remote_url)
    if not ok then
        -- really shouldn't happen
        lib_notify.notify_popup_with_timeout("Git history has changed, want to reset but couldn't identify remote", 7500, "error")
        return false
    end
    local head_branch = M.pull_state.pr_raw["head"]["ref"]
    local out = gitcli.git_reset_hard(remote, head_branch)
    if out == nil then
        lib_notify.notify_popup_with_timeout("Git history changed but failed to reset", 7500, "error")
        return false
    end
    return true
end

function M.get_commits_async(pull_number, cb)
    vim.schedule(function() vim.api.nvim_echo({{spinner() .. " fetching commits", "LTInfo"}}, false, {}) end)
    local fence_id = add_fence("get_commits_async")
    ghcli.get_pull_commits_async(pull_number, function(err, data)
        if err then
            vim.schedule(function () lib_notify.notify_popup_with_timeout("Failed to fetch commits: " .. err, 7500, "error") end)
            return
        end
        if not check_fence("get_commits_async", fence_id) then
            cb()
            return
        end

        if
            M.pull_state.commits ~= nil and
            #M.pull_state.commits ~= 0
        then
            if should_reset(M.pull_state.commits, data) then
                if not git_reset() then
                    return
                end
                vim.schedule(function () lib_notify.notify_popup_with_timeout("Git history has changed and repository reset to remote", 7500, "info") end)
            elseif should_fetch(M.pull_state.commits, data) then
                if not git_fetch() then
                    return
                end
                vim.schedule(function () lib_notify.notify_popup_with_timeout("New commits added to pull request and fetched locally.", 7500, "info") end)
            end
        end

        M.pull_state.commits_by_sha = {}
        M.pull_state.commits = data
        -- add commits to pull_state by their SHAs
        for i, commit in ipairs(data) do
            -- final commit in array will be the HEAD.
            if i == #data then
                M.pull_state.head = commit["sha"]
            end
            M.pull_state.commits_by_sha[commit["sha"]] = commit
        end
        cb()

    end)
end

function M.get_review_threads_async(pull_number, cb)
    vim.schedule(function() vim.api.nvim_echo({{spinner() .. " fetching review threads", "LTInfo"}}, false, {}) end)
    ghcli.get_review_threads_async_paginated(pull_number, function(err, data)
        if err then
            vim.schedule(function () lib_notify.notify_popup_with_timeout("Failed to fetch review threads: " .. err, 7500, "error") end)
            return
        end

        M.pull_state.review_threads_raw = data

        local review_threads_by_id, review_threads_by_filename, _, review_thread_comments_by_id = comments.build_review_thread_trees(data, 2)

        if M.pull_state.notifications_by_id == nil then
            M.pull_state.notifications_by_id = {}
        end

        if M.pull_state.review_thread_comments_by_id == nil then
            M.pull_state.review_thread_comments_by_id = {}
        else
            for id, c in pairs(review_thread_comments_by_id) do
                if M.pull_state.review_thread_comments_by_id[id] == nil then
                    M.pull_state.notifications_by_id[id] = c
                end
            end
        end

        if M.pull_state.review_threads_by_id == nil then
            M.pull_state.review_threads_by_id = {}
        else
            for id, t in pairs(review_threads_by_id) do
                if M.pull_state.review_threads_by_id[id] == nil then
                    M.pull_state.notifications_by_id[id] = t
                end
                -- if a child is new add notification for the thread
                for _, child in ipairs(t.children) do
                    if M.pull_state.notifications_by_id[child.key] then
                        M.pull_state.notifications_by_id[id] = t
                        t.expanded = true
                    end
                end
            end
        end

        M.pull_state.review_threads_by_id,
            M.pull_state.review_threads_by_filename,
                M.pull_state.review_thread_comments_by_id =
                    review_threads_by_id, review_threads_by_filename, review_thread_comments_by_id
        cb()
    end)
end

function M.get_reviews_async(pull_number, username, cb)
    vim.schedule(function() vim.api.nvim_echo({{spinner() .. " fetching reviews", "LTInfo"}}, false, {}) end)
    ghcli.list_reviews_async(pull_number, function(err, data)
        if err then
            vim.schedule(function () lib_notify.notify_popup_with_timeout("Failed to fetch reviews: " .. err, 7500, "error") end)
            return
        end

        M.pull_state.reviews_by_node_id = {}
        for _, r in ipairs(data) do
            if
                r["user"]["login"] == username and
                r["state"] == "PENDING"
            then
                M.pull_state.review = r
            end
            -- reviews of state commented show up in "Conversations" subtree,
            -- we don't need them here.
            if r["state"] ~= "COMMENTED" then
                M.pull_state.reviews_by_node_id[r["node_id"]] = r
            end
        end
        cb()
    end)
end

function M.get_pull_issue_comments_async(pull_number, cb)
    vim.schedule(function() vim.api.nvim_echo({{spinner() .. " fetching issue comments", "LTInfo"}}, false, {}) end)
    local fence_id = add_fence("get_pull_issue_comments_async")
    ghcli.get_pull_issue_comments_async_paginated(pull_number, function(err, data)
        if err then
            vim.schedule(function () lib_notify.notify_popup_with_timeout("Failed to fetch issue comments: " .. err, 7500, "error") end)
            return
        end

        if not check_fence("get_pull_issue_comments_async", fence_id) then
            cb()
            return
        end

        local comms, comments_by_id = comments.build_issue_comment_nodes(data)

        if M.pull_state.notifications_by_id == nil then
            M.pull_state.notifications_by_id = {}
        end
        if M.pull_state.issue_comments_by_id == nil then
            M.pull_state.issue_comments_by_id = {}
        else
            for id, c in pairs(comments_by_id) do
                if M.pull_state.issue_comments_by_id[id] == nil then
                    M.pull_state.notifications_by_id[id] = c
                    M.pull_state.notifications_by_id[pull_number] = true
                end
            end
        end

        M.pull_state.issue_comments = comms
        M.pull_state.issue_comments_by_id = comments_by_id
        cb()
    end)
end

function M.get_pull_files_async(pull_number, cb)
    vim.schedule(function() vim.api.nvim_echo({{spinner() .. " fetching pull request files", "LTInfo"}}, false, {}) end)
    local fence_id = add_fence("get_pull_files_async")
    ghcli.get_pull_files_async(pull_number, function(err, data)
        if err then
            vim.schedule(function () lib_notify.notify_popup_with_timeout("Failed to fetch pull request files: " .. err, 7500, "error") end)
            return
        end

        if not check_fence("get_pull_files_async", fence_id) then
            cb()
            return
        end

        M.pull_state.files_by_name = {}
        for _, f in ipairs(data) do
            M.pull_state.files_by_name[f["filename"]] = f
        end
        cb()
    end)
end

function M.get_pull_files_viewed_state_async(pull_number, cb)
    vim.schedule(function()
        vim.api.nvim_echo({{spinner() .. " fetching pull request files viewed state", "LTInfo"}}, false, {})
    end)

    local fence_id = add_fence("get_pull_files_viewed_state_async")
    ghcli.get_pull_files_viewed_state_async(pull_number, function(err, data)
        if err then
            vim.schedule(function ()
                lib_notify.notify_popup_with_timeout("Failed to fetch pull request files viewed state: " .. err, 7500, "error")
            end)
            return
        end

        if not check_fence("get_pull_files_async", fence_id) then
            cb()
            return
        end

        local files = data.data.repository.pullRequest.files.edges;
        for _, f in ipairs(files) do
            M.pull_state.files_by_name[f.node["path"]].viewed_state = f.node["viewerViewedState"]
        end
        cb()
    end)
end

function M.get_user_data_async(cb)
    vim.schedule(function() vim.api.nvim_echo({{spinner() .. " fetching pull request files", "LTInfo"}}, false, {}) end)
    local fence_id = add_fence("get_user_data_async")
    ghcli.get_user_async(function(err, data)
        if err then
            vim.schedule(function () lib_notify.notify_popup_with_timeout("Failed to fetch GitHub user: " .. err, 7500, "error") end)
            return
        end

        if not check_fence("get_user_data_async", fence_id) then
            cb()
            return
        end

        M.pull_state.user = data
        cb()
    end)
end

function M.get_pr_data_async(pull_number, cb)
    vim.schedule(function() vim.api.nvim_echo({{spinner() .. " fetching pull request", "LTInfo"}}, false, {}) end)
    local fence_id = add_fence("get_pr_data_async")
    ghcli.get_pull_async(pull_number, function(err, data)
        if err then
            vim.schedule(function () lib_notify.notify_popup_with_timeout("Failed to fetch pull request: " .. err, 7500, "error") end)
            return
        end

        if not check_fence("get_pr_data_async", fence_id) then
            cb()
            return
        end

        if M.pull_state == nil then
            M.pull_state = {}
        end
        M.pull_state.number = pull_number
        M.pull_state.pr_raw = data
        cb()
    end)
end

function M.get_pr_remote_url()
  local remote_url = ''

  local protocol = ghcli.get_git_protocol()
  if protocol == 'https' then
    remote_url = M.pull_state.pr_raw['head']['repo']['clone_url']
  else
    remote_url = M.pull_state.pr_raw['head']['repo']['ssh_url']
  end

  return remote_url
end

-- WELCOME TO CALLBACK HELL.
--
-- load all the data we need to open a PR and all its components in a giant
-- callback chain.
function M.load_state_async(pull_number, on_load)
    if M.pull_state == nil then
        M.pull_state = {}
    end
    M.get_pr_data_async(pull_number, function()
        M.get_user_data_async(function()
            M.get_pull_files_async(pull_number, function()
                M.get_pull_files_viewed_state_async(pull_number, function()
                    M.get_pull_issue_comments_async(pull_number, function()
                        M.get_reviews_async(pull_number, M.pull_state.user["login"], function()
                            M.get_review_threads_async(pull_number, function()
                                M.get_commits_async(pull_number, function()
                                    M.get_check_runs(
                                        function ()
                                            vim.schedule(function() vim.api.nvim_echo({{spinner() .. " successfully fetched all PR state.", "LTSuccess"}}, false, {}) end)
                                            vim.schedule(on_load)
                                        end
                                    )
                                end)
                            end)
                        end)
                    end)
                end)
            end)
        end)
    end)
end

return M
