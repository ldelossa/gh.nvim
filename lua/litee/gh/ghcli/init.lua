local graphql = require('litee.gh.ghcli.graphql')

local M = {}

local function json_decode_safe(output)
    local success, decoded = pcall(function () return vim.json.decode(output) end)
    if success then
        return decoded
    else
        return {message =  "json decode error"}
    end
end

-- gh_exec executs the (assumed) gh command which returns json.
--
-- if nil is returned the second returned argument is the error output.
--
-- if successful the json is decoded into a lua dictionary and returned.
local function gh_exec(cmd, no_json_decode)
    local output = vim.fn.system(cmd)
    if vim.v.shell_error ~= 0 then
        return nil
    end
    if no_json_decode then
        return output
    end
    local tbl = json_decode_safe(output)
    if tbl["message"] ~= nil then
        return nil
    end
    return tbl, ""
end

local function check_error(data)
    if data["errors"] ~= nil then
        for _, e in ipairs(data["errors"]) do
            return e["type"]
        end
    end
    if data["message"] ~= nil then
        return data["message"]
    end
    return false
end

local function async_request(args, on_read)
    local buffer = ""
    local stdout = vim.loop.new_pipe()
    local stderr = vim.loop.new_pipe()
    local handle = nil
    handle = vim.loop.spawn('gh', {
        args = args,
        stdio = {nil, stdout, stderr},
        },
        function()
            stdout:read_stop()
            stderr:read_stop()
            stdout:close()
            stderr:close()
            handle:close()
        end
    )
    vim.loop.read_start(stdout, function(err, data)
        if err then
            return err, nil
        end
        if data then
            buffer = buffer .. data
        end
        if data == nil then
            data = json_decode_safe(buffer)
            err = check_error(data)
            if err ~= false then
                vim.schedule(function() on_read(err, nil) end)
                return
            end
            vim.schedule(function() on_read(false, data) end)
        end
    end)
    vim.loop.read_start(stderr, function(err, data)
        vim.schedule(
            function()
                if err then
                    return err, nil
                end
                if data ~= nil then
                    data = json_decode_safe(buffer)
                    err = check_error(data)
                    if err ~= false then
                        vim.schedule(function() on_read(err, nil) end)
                        return
                    end
                    vim.schedule( function () on_read("UNKNOWN", data) end)
                end
            end)
    end)
end

function M.get_user()
    local cmd = [[gh api "/user"]]
    return gh_exec(cmd)
end

function M.list_collaborators_async(on_read)
    local args = {"api", "-X", "GET", "-F", "per_page=100", "/repos/{owner}/{repo}/collaborators"}
    async_request(args, on_read)
end

function M.list_repo_issues_async(on_read)
    local args = {"api", "-X", "GET", "-F", "per_page=100", "/repos/{owner}/{repo}/issues"}
    async_request(args, on_read)
end

function M.get_user_async(on_read)
    local args = {"api", "/user"}
    async_request(args, on_read)
end


function M.get_pull_files(number)
    local cmd = string.format([[gh api -X get -F "per_page=100" /repos/{owner}/{repo}/pulls/%d/files]], number)
    return gh_exec(cmd)
end

function M.get_pull_files_async(pull_number, on_read)
    local args = {"api", "-X", "GET", "-F", "per_page=100", string.format("/repos/{owner}/{repo}/pulls/%d/files", pull_number)}
    async_request(args, on_read)
end

-- lists all pull requests for the repo in `cwd`
--
-- return @table: https://docs.github.com/en/rest/reference/pulls#list-pull-requests
function M.list_pulls()
    local cmd = [[gh pr list --limit 100 --json "number,title,author"]]
    return gh_exec(cmd)
end

-- get the details of a specific pull request by its number
--
-- return @table: https://docs.github.com/en/rest/reference/pulls#get-a-pull-request
function M.get_pull(number)
    local cmd = [[gh api /repos/{owner}/{repo}/pulls/]] .. number
    return gh_exec(cmd)
end

function M.get_pull_async(pull_number, on_read)
    local args = {"api", "/repos/{owner}/{repo}/pulls/" .. pull_number}
    async_request(args, on_read)
end

function M.list_pulls_async(on_read)
    local args = {"api", "-X", "GET", "-F", "per_page=100", "/repos/{owner}/{repo}/pulls/"}
    async_request(args, on_read)
end

function M.update_issue_body_async(number, body, on_read)
    local args = {
        'api',
        "-X",
        "POST",
        string.format("/repos/{owner}/{repo}/issues/%d", number),
        '-f',
        string.format([[body=%s]], body)
    }
    async_request(args, on_read)
end

function M.update_pull_body_async(pull_number, body, on_read)
    local args = {
        'api',
        "-X",
        "POST",
        string.format("/repos/{owner}/{repo}/pulls/%d", pull_number),
        '-f',
        string.format([[body=%s]], body)
    }
    async_request(args, on_read)
end

-- get a list of commits for the provided pull request.
--
-- return @table: https://docs.github.com/en/rest/reference/pulls#list-commits-on-a-pull-request
function M.get_pull_commits(number)
    local cmd = string.format([[gh api -X get -F "per_page=100" /repos/{owner}/{repo}/pulls/%d/commits]], number)
    return gh_exec(cmd)
end

function M.get_pull_commits_async(pull_number, on_read)
    local args = {"api", "-X", "GET", "-F", "per_page=100",  string.format([[/repos/{owner}/{repo}/pulls/%d/commits]], pull_number)}
    async_request(args, on_read)
end

-- get the details of a commit including the files changed.
--
-- return @table: https://docs.github.com/en/rest/reference/commits#get-a-commit
function M.get_commit(ref)
    local cmd = string.format([[gh api /repos/{owner}/{repo}/commits/%s]], ref)
    return gh_exec(cmd)
end

-- returns all comments associated with a unified diff
--
-- will return comments created outside of a review along with comments from
-- submitted reviews.
--
-- pending review comments are not displayed here.
--
-- return @table: https://docs.github.com/en/rest/reference/pulls#list-review-comments-on-a-pull-request
function M.get_pull_comments(number)
    local cmd = string.format([[gh api -X get -F "per_page=100" /repos/{owner}/{repo}/pulls/%d/comments]], number)
    return gh_exec(cmd)
end

-- issue comments are comments which appear directly on the pull request
-- front page.
--
-- they are not associated with a commit or a line in the pull request's unified
-- diff.
--
-- issue comments are not threaded.
--
-- an arbitrary issue number can be provided to obtain comments as well.
--
-- return @table: https://docs.github.com/en/rest/reference/issues#list-issue-comments
function M.get_pull_issue_comments(number)
    local cmd = string.format([[gh api /repos/{owner}/{repo}/issues/%d/comments]], number)
    return gh_exec(cmd)
end

function M.get_pull_issue_comments_async(pull_number, on_read)
    local args = {
        'api',
        'graphql',
        '-F',
        'owner={owner}',
        '-F',
        'name={repo}',
        '-F',
        string.format('number=%d', pull_number),
        '-f',
        string.format('query=%s', graphql.issue_comments_query)
    }
    async_request(args, on_read)
end

function M.create_pull_issue_comment(number, body)
    local cmd = string.format([[gh api -X POST /repos/{owner}/{repo}/issues/%d/comments -f body=%s]], number, body)
    return gh_exec(cmd)
end

function M.update_pull_issue_comment(id, body)
    local cmd = string.format([[gh api -X PATCH /repos/{owner}/{repo}/issues/comments/%d -f body=%s]], id, body)
    return gh_exec(cmd)
end

function M.delete_pull_issue_comment(id)
    local cmd = string.format([[gh api -X DELETE /repos/{owner}/{repo}/issues/comments/%d]], id)
    return gh_exec(cmd, true)
end

-- get individual reviews for a particular pull request.
--
-- return @table: https://docs.github.com/en/rest/reference/pulls#list-reviews-for-a-pull-request
function M.get_pull_reviews(number)
    local cmd = string.format([[gh api /repos/{owner}/{repo}/pulls/%d/reviews]], number)
    return gh_exec(cmd)
end

-- list comments grouped by the review they were created with.
--
-- `get_pull_comments` returns the superset of these comments.
--
-- return @table: https://docs.github.com/en/rest/reference/pulls#list-comments-for-a-pull-request-review
function M.get_pull_review_comments(pull_number, review_id)
    local cmd = string.format([[gh api /repos/{owner}/{repo}/pulls/%d/reviews/%d/comments]], pull_number, review_id)
    return gh_exec(cmd)
end

-- get_pr_review_threads returns a list of threads.
-- threads map to file diff locations for a modified file.
--
-- each thread contains a "comments" array with one or more review comments directed
-- at the source code location in the owning thread.
--
-- see graphql.review_threads_query for returned schema.
--
-- note, each comment gets an extracted "rest_id" field which maps them to the
-- GitHub HTTP api, you can use this id to create comments outside of reviews,
-- used by M.reply_comment()
function M.get_pull_review_threads(pull_number)
    local cmd = string.format([[gh api -X get -F "per_page=100" graphql -F owner='{owner}' -F name='{repo}' -F pull_number=%d -f query='%s']],
        pull_number,
        graphql.review_threads_query
    )
    local resp = gh_exec(cmd)
    if resp == nil then
        return nil
    end
    -- extract graphql syntax into something actually usable.
    local threads = {}
    local thread_edge = resp["data"]["repository"]["pullRequest"]["reviewThreads"]["edges"]
    for _, thread_node in ipairs(thread_edge) do
        local thread = nil
        local comments = {}
        thread = thread_node["node"]
        for _, comment_edge in ipairs(thread["comments"]["edges"]) do
            -- extract the rest API ID for the comment node to make replies
            -- outside of a review possible.
            local node = comment_edge["node"]
            local idx = vim.fn.stridx(node["url"], "_r", 0)
            local rest_id = vim.fn.strpart(node["url"], idx+2)
            node["rest_id"] = rest_id
            table.insert(comments, node)
        end
        thread.comments = comments
        table.insert(threads, thread)
    end
    return threads
end

function M.get_issue_async(number, on_read)
    local args = {
        'api',
        '/repos/{owner}/{repo}/issues/' .. number
    }
    async_request(args, on_read)
end

function M.get_issue_comments_async(number, on_read)
    local args = {
        'api',
        '/repos/{owner}/{repo}/issues/' .. number .. '/comments'
    }
    async_request(args, on_read)
end

function M.get_review_threads_async(pull_number, on_read)
    local args = {
        'api',
        'graphql',
        '-F',
        'owner={owner}',
        '-F',
        'name={repo}',
        '-F',
        string.format('pull_number=%d', pull_number),
        '-f',
        string.format('query=%s', graphql.review_threads_query)
    }
    async_request(args, on_read)
end

function M.resolve_thread(thread_id)
    local cmd = string.format([[gh api graphql -F thread_id="%s" -f query='%s']],
        thread_id,
        graphql.resolve_thread
    )
    local resp = gh_exec(cmd)
    if resp == nil then
        return nil
    end
    return resp
end

function M.unresolve_thread(thread_id)
    local cmd = string.format([[gh api graphql -F thread_id="%s" -f query='%s']],
        thread_id,
        graphql.unresolve_thread
    )
    local resp = gh_exec(cmd)
    if resp == nil then
        return nil
    end
    return resp
end

function M.create_comment(pull_number, commit_sha, path, position, side, line, body)
    local cmd = string.format([[gh api --method POST -H "Accept: application/vnd.github.v3+json" /repos/{owner}/{repo}/pulls/%d/comments -f commit_id=%s -f path=%s -f side=%s -F position=%d -F line=%d -f body=%s]],
        pull_number,
        commit_sha,
        path,
        side,
        position,
        line,
        body
    )
    local out = gh_exec(cmd)
    if out == nil then
        return nil
    end
    return out
end

function M.create_comment_multiline(pull_number, commit_sha, path, position, side, start_line, line, body)
    local cmd = string.format([[gh api --method POST -H "Accept: application/vnd.github.v3+json" /repos/{owner}/{repo}/pulls/%d/comments -f commit_id=%s -f path=%s -f start_side=%s -f side=%s -F position=%d -F start_line=%d -F line=%d -f body=%s]],
        pull_number,
        commit_sha,
        path,
        side,
        side,
        position,
        start_line,
        line,
        body
    )
    local out = gh_exec(cmd)
    if out == nil then
        return nil
    end
    return out
end

-- this is a graphql query so pass use the node_id for each argument that wants
-- and id.
function M.create_comment_review(pull_id, review_id, body, path, line, side)
    local cmd = string.format([[gh api graphql -F pull="%s" -F review="%s" -F body=%s -F path="%s" -F line=%d  -F side=%s -f query='%s']],
        pull_id,
        review_id,
        body,
        path,
        line,
        side,
        graphql.create_comment_review
    )
    local resp = gh_exec(cmd)
    if resp == nil then
        return nil
    end
    return resp
end

-- this is a graphql query so pass use the node_id for each argument that wants
-- and id.
function M.create_comment_review_multiline(pull_id, review_id, body, path, start_line, line, side)
    local cmd = string.format([[gh api graphql -F pull="%s" -F review="%s" -F body=%s -F path="%s" -F start_line=%d -F line=%d -F start_side=%s -F side=%s -f query='%s']],
        pull_id,
        review_id,
        body,
        path,
        start_line,
        line,
        side,
        side,
        graphql.create_comment_review_multiline
    )
    local resp = gh_exec(cmd)
    if resp == nil then
        return nil
    end
    return resp
end

-- reply_comment replies to a comment outside of any review.
function M.reply_comment(pull_number, comment_rest_id, body)
    local cmd = string.format([[gh api --method POST -H "Accept: application/vnd.github.v3+json" /repos/{owner}/{repo}/pulls/%d/comments/%s/replies -f body=%s]],
        pull_number,
        comment_rest_id,
        body
    )
    local out = gh_exec(cmd)
    if out == nil then
        return nil
    end
    return out
end

-- reply_comment_review replies to a comment inside a review.
-- this is a graphql query so use "node_id" for all ids.
function M.reply_comment_review(pull_id, review_id, commit_sha, body, reply_id)
    local cmd = string.format([[gh api graphql -F pull="%s" -F review="%s" -F commit="%s" -F body=%s -F reply="%s" -f query='%s']],
        pull_id,
        review_id,
        commit_sha,
        body,
        reply_id,
        graphql.reply_comment_review
    )
    local resp = gh_exec(cmd)
    if resp == nil then
        return nil
    end
    return resp
end

function M.update_comment(comment_rest_id, body)
    local cmd = string.format([[gh api --method PATCH -H "Accept: application/vnd.github.v3+json" /repos/{owner}/{repo}/pulls/comments/%d -f body=%s]],
        comment_rest_id,
        body
    )
    local out = gh_exec(cmd)
    if out == nil then
        return nil
    end
    return out
end

function M.delete_comment(comment_rest_id)
    local cmd = string.format([[gh api --method DELETE -H "Accept: application/vnd.github.v3+json" /repos/{owner}/{repo}/pulls/comments/%d]],
        comment_rest_id
    )
    local out = gh_exec(cmd, true)
    if out == nil then
        return nil
    end
    return out
end

function M.list_review(pull_number)
    local cmd = string.format([[gh api -H "Accept: application/vnd.github.v3+json" /repos/{owner}/{repo}/pulls/%d/reviews]],
        pull_number
    )
    local out = gh_exec(cmd)
    if out == nil then
        return nil
    end
    return out
end

function M.list_reviews_async(pull_number, on_read)
    local args = {"api", string.format("/repos/{owner}/{repo}/pulls/%d/reviews", pull_number)}
    async_request(args, on_read)
end

function M.add_reaction(id, reaction, on_read)
    local args = {
        'api',
        'graphql',
        '-F',
        string.format('id=%s', id),
        '-F',
        string.format('content=%s', reaction),
        '-f',
        string.format('query=%s', graphql.add_reaction)
    }
    async_request(args, on_read)
end

function M.remove_reaction_async(id, reaction, on_read)
    local args = {
        'api',
        'graphql',
        '-F',
        string.format('id=%s', id),
        '-F',
        string.format('content=%s', reaction),
        '-f',
        string.format('query=%s', graphql.remove_reaction)
    }
    async_request(args, on_read)
end

function M.get_pending_review(pull_number, username)
    local out = M.list_review(pull_number)
    if out == nil then
        return nil
    end

    local review = {}
    for _, r in ipairs(out) do
        if
            r["user"]["login"] == username and
            r["state"] == "PENDING"
        then
            review = r
        end
    end

    return review, out
end

function M.create_review(pull_number, commit_id)
    local cmd = string.format([[gh api --method POST -H "Accept: application/vnd.github.v3+json" /repos/{owner}/{repo}/pulls/%d/reviews -f commit_id=%s]],
        pull_number,
        commit_id
    )
    local out = gh_exec(cmd)
    if out == nil then
        return nil
    end
    return out
end

function M.delete_review(pull_number, review_id)
    local cmd = string.format([[gh api --method DELETE -H "Accept: application/vnd.github.v3+json" /repos/{owner}/{repo}/pulls/%d/reviews/%s]],
        pull_number,
        review_id
    )
    local out = gh_exec(cmd)
    if out == nil then
        return nil
    end
    return out
end

function M.submit_review(pull_number, review_id, body, event)
    local cmd = nil
    if body ~= nil then
        cmd = string.format([[gh api --method POST -H "Accept: application/vnd.github.v3+json" /repos/{owner}/{repo}/pulls/%d/reviews/%s/events -f event=%s -f body=%s]],
            pull_number,
            review_id,
            event,
            body
        )
    else
        cmd = string.format([[gh api --method POST -H "Accept: application/vnd.github.v3+json" /repos/{owner}/{repo}/pulls/%d/reviews/%s/events -f event=%s ]],
            pull_number,
            review_id,
            event
        )
    end
    local out = gh_exec(cmd, true)
    if out == nil then
        return nil
    end
    return out
end

function M.list_labels_async(on_read)
    local args = {
        'api',
        '/repos/{owner}/{repo}/labels'
    }
    async_request(args, on_read)
end

function M.add_label_async(number, label, on_read)
    local args = {
        "issue",
        "edit",
        number,
        "--add-label",
        label
    }
    async_request(args, on_read)
end

function M.remove_label_async(number, label, on_read)
    local args = {
        "issue",
        "edit",
        number,
        "--remove-label",
        label
    }
    async_request(args, on_read)
end

function M.get_check_suites_async(commit_sha, on_read)
    local args = {
        'api',
        string.format("/repos/{owner}/{repo}/commits/%s/check-suites", commit_sha)
    }
    async_request(args, on_read)
end

function M.get_check_runs_by_suite(suite_id, on_read)
    local args = {
        'api',
        string.format("/repos/{owner}/{repo}/check-suites/%s/check-runs", suite_id)
    }
    async_request(args, on_read)
end

return M
