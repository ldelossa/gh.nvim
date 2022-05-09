local lib_notify    = require('litee.lib.notify')

local ghcli         = require('litee.gh.ghcli')
local comments      = require('litee.gh.pr.comments')

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
    -- a simple list of login names of collaborators for the repo associated with
    -- this pull.
    collaborators = nil,
    -- first 100 repo issues, mostly for caching of completion.
    repo_issues = nil,
    -- any checks to run for the current HEAD.
    check_runs = {}
}

-- a global flag which informs others that state is being refreshed.
M.refreshing = false

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

-- last opened file in the diff_view handler
M.last_file_diff = nil

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
function spinner()
    local spinners = {[0] = "⣾", [1] = "⣽", [2] = "⣻", [3] = "⢿", [4] = "⡿", [5] = "⣟", [6] = "⣯", [7] = "⣷"}
    spinner_state = spinner_state + 1
    return spinners[spinner_state%8]
end

-- -- do this on module load so we start with an empty pull_state
-- M.reset_pull_state()

function M.get_check_runs(cb)
    vim.schedule(function() vim.api.nvim_echo({{spinner() .. " fetching checks", "LTInfo"}}, false, {}) end)
    local fence_id = add_fence("get_check_runs")
    ghcli.get_check_suites_async(M.pull_state.head, function(err, data)
        if err then
            vim.schedule(function () lib_notify.notify_popup_with_timeout("Failed to fetch check suites: " .. err, 7500, "error") end)
            return
        end
        if not check_fence("get_check_runs", fence_id) then
            cb()
            return
        end
        local suite_counter = 0
        M.pull_state.check_runs = {}
        if #data["check_suites"] > 0 then -- if we need to, go get the check runs for the suites we found.
            for _, suite in ipairs(data["check_suites"]) do
                local fence_name = "get_check_runs_by_suite_" .. suite["id"]
                local sub_fence_id = add_fence(fence_name)
                ghcli.get_check_runs_by_suite(suite["id"], function(err1, runs)
                    if err1 then
                        vim.schedule(function () lib_notify.notify_popup_with_timeout("Failed to fetch check runs: " .. err, 7500, "error") end)
                        return
                    end
                    if not check_fence(fence_name, sub_fence_id) then
                        return
                    end
                    for _, run in ipairs(runs["check_runs"]) do
                        table.insert(M.pull_state.check_runs, run)
                    end
                    suite_counter = suite_counter + 1
                    if suite_counter == #data["check_suites"] then
                        cb()
                    end
                end)
            end
        else
            cb()
        end
    end)
end

function M.get_repo_issues_async(cb)
    vim.schedule(function() vim.api.nvim_echo({{spinner() .. " fetching repo issues", "LTInfo"}}, false, {}) end)
    local fence_id = add_fence("get_repo_issues_async")
    ghcli.list_repo_issues_async(function(err, data)
        if err then
            vim.schedule(function () lib_notify.notify_popup_with_timeout("Failed to fetch repo issues: " .. err, 7500, "error") end)
            return
        end
        if not check_fence("get_repo_issues_async", fence_id) then
            cb()
            return
        end
        M.pull_state.repo_issues = data
        cb()
    end)
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
    ghcli.get_review_threads_async(pull_number, function(err, data)
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
                    if M.pull_state.notifications_by_id[child.name] then
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
    ghcli.get_pull_issue_comments_async(pull_number, function(err, data)
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

function M.get_collaborators_async(cb)
    vim.schedule(function() vim.api.nvim_echo({{spinner() .. " fetching repository contributors", "LTInfo"}}, false, {}) end)
    local fence_id = add_fence("get_collaborators_async")
    ghcli.list_collaborators_async(function(err, data)
        if err then
            vim.schedule(function () lib_notify.notify_popup_with_timeout("Failed to fetch repository collaborators: " .. err, 7500, "error") end)
            -- we will continue processing here, since gathering collaborators may require push access.
            cb() 
            return
        end

        if not check_fence("get_collaborators_async", fence_id) then
            cb()
            return
        end
        M.pull_state.collaborators = {}
        M.pull_state.collaborators = data
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

M.reset_pull_state()

-- WELCOME TO CALLBACK HELL.
--
-- load all the data we need to open a PR and all its components in a giant
-- callback chain.
function M.load_state_async(pull_number, on_load)
    M.get_pr_data_async(pull_number, function()
        M.get_user_data_async(function()
            M.get_pull_files_async(pull_number, function()
                M.get_pull_issue_comments_async(pull_number, function()
                    M.get_reviews_async(pull_number, M.pull_state.user["login"], function()
                        M.get_review_threads_async(pull_number, function()
                            M.get_commits_async(pull_number, function()
                                M.get_collaborators_async(function ()
                                    M.get_repo_issues_async(function ()
                                        M.get_check_runs(
                                            function () vim.schedule(on_load) end
                                        )
                                    end)
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
