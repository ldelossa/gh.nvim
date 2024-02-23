local graphql = require('litee.gh.ghcli.graphql')
local lib_notify = require('litee.lib.notify')
local debug = require('litee.gh.debug')
local c = require('litee.gh.config')

local M = {}

local function json_decode_safe(output)
    local success, decoded = pcall(function () return vim.json.decode(output) end)
    if success then
        -- a bit of a hack, but search API returns the items in a wrapper, we'll
        -- extract it out on json decode so pagination function works correctly.
        if decoded["items"] ~= nil then
            decoded = decoded["items"]
        end
        return decoded
    else
        return {message =  "json decode error"}
    end
end

local function debug_fmt_args(args)
    local cmd = table.concat(args, " ")
    return "gh " .. cmd
end

-- gh_exec executs the (assumed) gh command which returns json.
--
-- if nil is returned the second returned argument is the error output.
--
-- if successful the json is decoded into a lua dictionary and returned.
local function gh_exec(args, no_json_decode, no_additional_arguments)
    if not no_additional_arguments then
      if c.config.ghcli_extra_args ~= nil and #c.config.ghcli_extra_args > 0 then
        for i, v in pairs(c.config.ghcli_extra_args) do
          table.insert(args, i, v)
        end
      end
    end
    table.insert(args, 1, "gh")

    local output = vim.fn.system(args)

    if vim.v.shell_error ~= 0 then
        debug.log("[gh] cmd: " .. vim.inspect(args) .. " out:\n" .. vim.inspect(output), "error")
        return nil
    end
    debug.log("[gh] cmd: " .. vim.inspect(args) .. " out:\n" .. vim.inspect(output), "info")
    if no_json_decode then
        return output
    end
    local tbl = json_decode_safe(output)
    if tbl["message"] ~= nil then
        debug.log("[gh] cmd: " .. vim.inspect(args) .. " out:\n" .. vim.inspect(tbl), "error")
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

local function async_request(args, on_read, paginate, page, paged_data)
    local buffer = ""
    local stdout = vim.loop.new_pipe()
    local stderr = vim.loop.new_pipe()
    local handle = nil
    if paginate  then
        if page ~= nil then
            args[#args] = "page=" .. page
        else
            page = 1
            table.insert(args, "-F")
            table.insert(args, "page=" .. page)
        end
    end
    if c.config.ghcli_extra_args ~= nil and #c.config.ghcli_extra_args > 0 then
      for i, v in pairs(c.config.ghcli_extra_args) do
        table.insert(args, i, v)
      end
    end
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
            debug.log("[gh] cmd: " .. debug_fmt_args(args) .. " out:\n" .. vim.inspect(err), "error")
            return err, nil
        end
        if data then
            buffer = buffer .. data
        end
        if data == nil then
            data = json_decode_safe(buffer)
            err = check_error(data)
            if err ~= false then
                debug.log("[gh] cmd: " .. debug_fmt_args(args) .. " out:\n" .. vim.inspect(err), "error")
                vim.schedule(function() on_read(err, nil) end)
                return
            end
            if paged_data == nil then
                paged_data = data
            else
                for _, i in pairs(data) do
                    table.insert(paged_data, i)
                end
            end
            if paginate then
                if #data > 0 then
                    -- paginate
                    debug.log("[gh] cmd: " .. debug_fmt_args(args) .. " out:\n" .. vim.inspect(data), "info")
                    async_request(args, on_read, paginate, page+1, paged_data)
                    return
                end
            end
            debug.log("[gh] cmd: " .. debug_fmt_args(args) .. " out:\n" .. vim.inspect(data), "info")
            vim.schedule(function() on_read(false, paged_data) end)
        end
    end)
    vim.loop.read_start(stderr, function(err, data)
        vim.schedule(
            function()
                if err then
                    debug.log("[gh] cmd: " .. debug_fmt_args(args) .. " out:\n" .. vim.inspect(err), "error")
                    return err, nil
                end
                if data ~= nil then
                    data = json_decode_safe(buffer)
                    err = check_error(data)
                    if err ~= false then
                        debug.log("[gh] cmd: " .. debug_fmt_args(args) .. " out:\n" .. vim.inspect(err), "error")
                        vim.schedule(function() on_read(err, nil) end)
                        return
                    end
                    vim.schedule(function () on_read("UNKNOWN", data) end)
                end
            end)
    end)
end

function M.list_collaborators_async(on_read)
    local args = {"api", "--method", "GET", "-F", "per_page=100", "/repos/{owner}/{repo}/collaborators"}
    async_request(args, on_read, true)
end

function M.list_repo_issues_async(on_read)
    local args = {"api", "--method", "GET", "-F", "per_page=100", "/repos/{owner}/{repo}/issues"}
    async_request(args, on_read)
end

function M.list_all_repo_issues_async(on_read)
    local args = {"api", "--method", "GET", "-F", "per_page=100", "/repos/{owner}/{repo}/issues", "-q", '. | map(select(. | (has("pull_request") | not)))'}
    async_request(args, on_read, true)
end

function M.get_user()
    local args = {"api", "/user"}
    return gh_exec(args)
end

function M.get_user_async(on_read)
    local args = {"api", "/user"}
    async_request(args, on_read)
end

function M.get_pull_files_async(pull_number, on_read)
    local args = {
      "api",
      "--method",
      "GET",
      "-F",
      "per_page=100",
      string.format("/repos/{owner}/{repo}/pulls/%d/files", pull_number)
    }
    async_request(args, on_read, true)
end

-- lists all pull requests for the repo in `cwd`
--
-- return @table: https://docs.github.com/en/rest/reference/pulls#list-pull-requests
function M.list_pulls()
    local cmd = {
      "pr",
      "list",
      "--limit",
      "100",
      "--json",
      'number,title,author'}
    return gh_exec(cmd)
end

-- search_pulls accepts a query string which is appended to a hard coded query
-- string of "q=repo:{owner}/{name} type=pr".
function M.search_pulls(owner, name, qq, on_read)
    local q = string.format("q=repo:%s/%s type:pr ", owner, name)
    if qq ~= nil then
        q  = q .. qq
    end
    local args = {"api", "--method", "GET", "-F", "per_page=100", "search/issues", "-f", q}
    async_request(args, on_read, true)
end

-- like search_pulls but for issues.
function M.search_issues(owner, name, qq, on_read)
    local q = string.format("q=type:issue ", owner, name)
    if qq ~= nil then
        q  = q .. qq
    end
    local args = {"api", "--method", "GET", "-F", "per_page=100", "search/issues", "-f", q}
    async_request(args, on_read, true)
end

function M.get_pull_async(pull_number, on_read)
    local args = {"api", "/repos/{owner}/{repo}/pulls/" .. pull_number}
    async_request(args, on_read)
end

function M.list_pulls_async(on_read)
    local args = {"api", "--method", "GET", "-F", "per_page=100", "/repos/{owner}/{repo}/pulls"}
    async_request(args, on_read)
end

function M.list_all_pulls_async(on_read)
    local args = {"api", "--method", "GET", "-F", "per_page=100", "/repos/{owner}/{repo}/pulls"}
    async_request(args, on_read, true)
end

function M.list_requested_reviews(owner, repo, on_read)
    local q = string.format("q=repo:%s/%s is:pr is:open review-requested:@me", owner, repo)
    local args = {"api", "--method", "GET", "-F", "per_page=100", "search/issues", "-f", q}
    async_request(args, on_read, true)
end

function M.list_requested_reviews_user(owner, repo, on_read)
    local q = string.format("q=repo:%s/%s is:pr is:open user-review-requested:@me", owner, repo)
    local args = {"api", "--method", "GET", "-F", "per_page=100", "search/issues", "-f", q}
    async_request(args, on_read, true)
end

function M.list_pulls_reviewed_by_user(owner, repo, on_read)
    local q = string.format("q=repo:%s/%s is:pr is:open reviewed-by:@me", owner, repo)
    local args = {"api", "--method", "GET", "-F", "per_page=100", "search/issues", "-f", q}
    async_request(args, on_read, true)
end

function M.get_repo_name_owner()
    local cmd = {"repo", "view", "--json", "name,owner"}
    return gh_exec(cmd)
end

function M.update_issue_body_async(number, body, on_read)
    local args = {
        'api',
        "--method",
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
        "--method",
        "POST",
        string.format("/repos/{owner}/{repo}/pulls/%d", pull_number),
        '-f',
        string.format([[body=%s]], body)
    }
    async_request(args, on_read)
end

function M.get_pull_commits_async(pull_number, on_read)
    local args = {
      "api",
      "--method",
      "GET",
      "-F",
      "per_page=100",
       string.format("/repos/{owner}/{repo}/pulls/%d/commits", pull_number)
    }
    async_request(args, on_read)
end

-- get the details of a commit including the files changed.
--
-- return @table: https://docs.github.com/en/rest/reference/commits#get-a-commit
function M.get_commit(ref)
    local cmd = {
      "api",
      string.format("/repos/{owner}/{repo}/commits/%s", ref)
    }
    return gh_exec(cmd)
end

function M.get_commit_async(ref, on_read)
    local args = {
        "api",
        "--method",
        "GET",
        string.format([[/repos/{owner}/{repo}/commits/%s]], ref)
    }
    async_request(args, on_read)
end

function M.get_commit_comments_async(ref, on_read)
    local args = {
        "api",
        "--method",
        "GET",
        "-F",
        "per_page=100",
        string.format([[/repos/{owner}/{repo}/commits/%s/comments]], ref)
    }
    async_request(args, on_read, true)
end

function M.create_commit_comment(sha, body)
    local cmd = {
      "api",
      "--method",
      "POST",
      string.format([[/repos/{owner}/{repo}/commits/%s/comments]], sha),
      "-f",
      string.format("body=%s", body)
    }
    return gh_exec(cmd)
end

function M.update_commit_comment(id, body)
    local cmd = {
      "api",
      "--method",
      "PATCH",
      string.format([[/repos/{owner}/{repo}/comments/%d]], id),
      "-f",
      string.format("body=%s", body)
    }
    return gh_exec(cmd)
end

function M.delete_commit_comment(id)
    local cmd = {
      "api",
      "--method",
      "DELETE",
      string.format([[/repos/{owner}/{repo}/comments/%d]], id)
    }
    return gh_exec(cmd, true)
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

function M.get_pull_issue_comments_async_paginated(pull_number, on_read)
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

    local paginated_data = nil

    function paginate(err, data)
        if err then
            vim.schedule(function () lib_notify.notify_popup_with_timeout("Failed to fetch pull request issue comments: " .. err, 7500, "error") end)
            return
        end

        if paginated_data == nil then
            paginated_data = data
        else
            for _, edge in ipairs(data["data"]["repository"]["pullRequest"]["comments"]["edges"]) do
                table.insert(paginated_data["data"]["repository"]["pullRequest"]["comments"]["edges"], edge)
            end
        end

        local hasNextPage = data["data"]["repository"]["pullRequest"]["comments"]["pageInfo"]["hasNextPage"]
        local endCursor = data["data"]["repository"]["pullRequest"]["comments"]["pageInfo"]["endCursor"]
        if hasNextPage then
            local args = {
                'api',
                'graphql',
                '-F',
                'owner={owner}',
                '-F',
                'name={repo}',
                '-F',
                string.format('number=%d', pull_number),
                '-F',
                string.format('cursor=%s', endCursor),
                '-f',
                string.format('query=%s', graphql.issue_comments_query_cursor)
            }
            async_request(args, paginate)
        else
            on_read(err, paginated_data)
        end
    end
    async_request(args, paginate)
end

function M.create_pull_issue_comment(number, body)
    local cmd = {
      "api",
      "--method",
      "POST",
      string.format("/repos/{owner}/{repo}/issues/%s/comments", number),
      "-f",
      string.format("body=%s", body)
    }
    return gh_exec(cmd)
end

function M.update_pull_issue_comment(id, body)
    local cmd = {
      "api",
      "--method",
      "PATCH",
      string.format("/repos/{owner}/{repo}/issues/comments/%d", id),
      "-f",
      string.format("body=%s", body)
    }
    return gh_exec(cmd)
end

function M.delete_pull_issue_comment(id)
    local cmd = {
      "api",
      "--method",
      "DELETE",
      string.format("/repos/{owner}/{repo}/issues/comments/%d", id)
    }
    return gh_exec(cmd, true)
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
        '--method',
        'GET',
        '-F',
        'per_page=100',
        '/repos/{owner}/{repo}/issues/' .. number .. '/comments'
    }
    async_request(args, on_read, true)
end

function M.get_issue_comment_reactions_async(id, on_read)
    local args = {
        'api',
        '--method',
        'GET',
        '-F',
        'per_page=100',
        string.format('/repos/{owner}/{repo}/issues/comments/%s/reactions', id)
    }
    async_request(args, on_read, true)
end

function M.get_commit_reactions_async(id, on_read)
    local args = {
        'api',
        '--method',
        'GET',
        '-F',
        'per_page=100',
        string.format('/repos/{owner}/{repo}/comments/%s/reactions', id)
    }
    async_request(args, on_read, true)
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

function M.get_pull_files_viewed_state_async(pull_number, on_read)
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
        string.format('query=%s', graphql.pull_files_viewed_states_query)
    }

    local paginated_data = nil

    local function paginate(err, data)
        if err then
            vim.schedule(function () lib_notify.notify_popup_with_timeout("Failed to fetch pr files viewed state: " .. err, 7500, "error") end)
            return
        end

        if paginated_data == nil then
            paginated_data = data
        else
            for _, edge in ipairs(data["data"]["repository"]["pullRequest"]["files"]["edges"]) do
                table.insert(paginated_data["data"]["repository"]["pullRequest"]["files"]["edges"], edge)
            end
        end

        local hasNextPage = data["data"]["repository"]["pullRequest"]["files"]["pageInfo"]["hasNextPage"]
        local endCursor = data["data"]["repository"]["pullRequest"]["files"]["pageInfo"]["endCursor"]
        if hasNextPage then
            local args = {
                'api',
                'graphql',
                '-F',
                'owner={owner}',
                '-F',
                'name={repo}',
                '-F',
                string.format('pull_number=%d', pull_number),
                '-F',
                string.format('cursor=%s', endCursor),
                '-f',
                string.format('query=%s', graphql.pull_files_viewed_states_query_cursor)
            }
            async_request(args, paginate)
        else
            on_read(err, paginated_data)
        end
    end
    async_request(args, paginate)
end

function M.mark_file_as_viewed(pull_request_id, path, on_read)
    local args = {
        "api",
        "graphql",
        "-F",
        string.format("pull_request_id=%s", pull_request_id),
        "-F",
        string.format("path=%s", path),
        "-f",
        string.format("query=%s", graphql.mark_file_as_viewed),
    }

    async_request(args, on_read)
end

function M.mark_file_as_unviewed(pull_request_id, path, on_read)
    local args = {
        "api",
        "graphql",
        "-F",
        string.format("pull_request_id=%s", pull_request_id),
        "-F",
        string.format("path=%s", path),
        "-f",
        string.format("query=%s", graphql.mark_file_as_unviewed),
    }

    async_request(args, on_read)
end

-- because graphql really sucks, write a special paginated function for this.
function M.get_review_threads_async_paginated(pull_number, on_read)
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

    local paginated_data = nil

    local function paginate(err, data)
        if err then
            vim.schedule(function () lib_notify.notify_popup_with_timeout("Failed to fetch review threads: " .. err, 7500, "error") end)
            return
        end

        if paginated_data == nil then
            paginated_data = data
        else
            for _, edge in ipairs(data["data"]["repository"]["pullRequest"]["reviewThreads"]["edges"]) do
                table.insert(paginated_data["data"]["repository"]["pullRequest"]["reviewThreads"]["edges"], edge)
            end
        end

        local hasNextPage = data["data"]["repository"]["pullRequest"]["reviewThreads"]["pageInfo"]["hasNextPage"]
        local endCursor = data["data"]["repository"]["pullRequest"]["reviewThreads"]["pageInfo"]["endCursor"]
        if hasNextPage then
            local args = {
                'api',
                'graphql',
                '-F',
                'owner={owner}',
                '-F',
                'name={repo}',
                '-F',
                string.format('pull_number=%d', pull_number),
                '-F',
                string.format('cursor=%s', endCursor),
                '-f',
                string.format('query=%s', graphql.review_threads_query_cursor)
            }
            async_request(args, paginate)
        else
            on_read(err, paginated_data)
        end
    end
    async_request(args, paginate)
end

function M.resolve_thread(thread_id)
    local cmd = {
      "api",
      "graphql",
      "-F",
      string.format('thread_id="%s"', thread_id),
      "-f",
      string.format("query='%s'", graphql.resolve_thread)
    }
    local resp = gh_exec(cmd)
    if resp == nil then
        return nil
    end
    return resp
end

function M.unresolve_thread(thread_id)
    local cmd = {
      "api",
      "graphql",
      "-F",
      string.format('thread_id="%s"', thread_id),
      "-f",
      string.format("query='%s'", graphql.unresolve_thread)
    }
    local resp = gh_exec(cmd)
    if resp == nil then
        return nil
    end
    return resp
end

function M.create_comment(pull_number, commit_sha, path, position, side, line, body)
    local cmd = {
      "api",
      "--method",
      "POST",
      "-H",
      "Accept: application/vnd.github.v3+json",
      string.format("/repos/{owner}/{repo}/pulls/%d/comments", pull_number),
      "-f",
      string.format("commit_id=%s", commit_sha),
      "-f",
      string.format("path=%s", path),
      "-f",
      string.format("side=%s", side),
      "-F",
      string.format("position=%d", position),
      "-F",
      string.format("line=%d", line),
      "-F",
      string.format("body=%s", body)
    }
    local out = gh_exec(cmd)
    if out == nil then
        return nil
    end
    return out
end

function M.create_comment_multiline(pull_number, commit_sha, path, position, side, start_line, line, body)
    local cmd = {
      "api",
      "--method",
      "POST",
      "-H",
      "Accept: application/vnd.github.v3+json",
      string.format("/repos/{owner}/{repo}/pulls/%d/comments", pull_number),
      "-f",
      string.format("commit_id=%s", commit_sha),
      "-f",
      string.format("path=%s", path),
      "-f",
      string.format("start_side=%s", side),
      "-f",
      string.format("side=%s", side),
      "-F",
      string.format("position=%d", position),
      "-F",
      string.format("start_line=%d", start_line),
      "-F",
      string.format("line=%d", line),
      "-F",
      string.format("body=%s", body)
    }
    local out = gh_exec(cmd)
    if out == nil then
        return nil
    end
    return out
end

-- this is a graphql query so pass use the node_id for each argument that wants
-- and id.
function M.create_comment_review(pull_id, review_id, body, path, line, side)
    local cmd = {
      "api",
      "graphql",
      "-F",
      string.format("pull=%s", pull_id),
      "-F",
      string.format("review=%s", review_id),
      "-F",
      string.format("body=%s", body),
      "-F",
      string.format("path=%s", path),
      "-F",
      string.format("line=%d", line),
      "-F",
      string.format("side=%s", side)
      "-f",
      string.format("query=%s", graphql.create_comment_review)
    }
    local resp = gh_exec(cmd)
    if resp == nil then
        return nil
    end
    return resp
end

-- this is a graphql query so pass use the node_id for each argument that wants
-- and id.
function M.create_comment_review_multiline(pull_id, review_id, body, path, start_line, line, side)
    local cmd = {
      "api",
      "graphql",
      "-F",
      string.format("pull=%s", pull_id),
      "-F",
      string.format("review=%s", review_id),
      "-F",
      string.format("body=%s", body),
      "-F",
      string.format("path=%s", path),
      "-F",
      string.format("start_line=%d", start_line),
      "-F",
      string.format("line=%d", line),
      "-F",
      string.format("start_side=%s", side)
      "-F",
      string.format("side=%s", side)
      "-f",
      string.format("query=%s", graphql.create_comment_review_multiline)
    }
    local resp = gh_exec(cmd)
    if resp == nil then
        return nil
    end
    return resp
end

-- reply_comment replies to a comment outside of any review.
function M.reply_comment(pull_number, comment_rest_id, body)
    local cmd = {
      "api",
      "--method",
      "POST",
      "-H",
      "Accept: application/vnd.github.v3+json",
       string.format("/repos/{owner}/{repo}/pulls/%d/comments/%s/replies", pull_number, comment_rest_id),
       "-f",
       string.format("body=%s", body),
    }
    local out = gh_exec(cmd)
    if out == nil then
        return nil
    end
    return out
end

-- reply_comment_review replies to a comment inside a review.
-- this is a graphql query so use "node_id" for all ids.
function M.reply_comment_review(pull_id, review_id, commit_sha, body, reply_id)
    local cmd = {
      "api",
      "graphql",
      "-F",
      string.format("pull=%s", pull_id),
      "-F",
      string.format("review=%s", review_id),
      "-F",
      string.format("commit=%s", commit_sha),
      "-F",
      string.format("body=%s", body),
      "-F",
      string.format("reply=%d", reply_id),
      "-f",
      string.format("query=%s", graphql.reply_comment_review)
    }
    local resp = gh_exec(cmd)
    if resp == nil then
        return nil
    end
    return resp
end

function M.update_comment(comment_rest_id, body)
    local cmd = {
      "api",
      "--method",
      "PATCH",
      "-H",
      "Accept: application/vnd.github.v3+json",
      string.format("/repos/{owner}/{repo}/pulls/comments/%d", comment_rest_id),
      "-f",
      string.format("body=%s", body),
    }
    local out = gh_exec(cmd)
    if out == nil then
        return nil
    end
    return out
end

function M.delete_comment(comment_rest_id)
    local cmd = {
      "api",
      "--method",
      "DELETE",
      "-H",
      "Accept: application/vnd.github.v3+json",
      string.format([[/repos/{owner}/{repo}/pulls/comments/%d]], comment_rest_id),
    }
    local out = gh_exec(cmd, true)
    if out == nil then
        return nil
    end
    return out
end

function M.list_reviews_async(pull_number, on_read)
    local args = {
        "api",
        '--method',
        'GET',
        '-F',
        'per_page=100',
        string.format("/repos/{owner}/{repo}/pulls/%d/reviews", pull_number)
    }
    async_request(args, on_read, true)
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

function M.create_review(pull_number, commit_id)
    local cmd = {
      "api",
      "--method",
      "POST",
      "-H",
      "Accept: application/vnd.github.v3+json",
      string.format("/repos/{owner}/{repo}/pulls/%d/reviews", pull_number),
      "-f",
      string.format("commit_id=%s", commit_id),
    }
    local out = gh_exec(cmd)
    if out == nil then
        return nil
    end
    return out
end

function M.delete_review(pull_number, review_id)
    local cmd = {
      "api",
      "--method",
      "DELETE",
      "-H",
      "Accept: application/vnd.github.v3+json",
      string.format("/repos/{owner}/{repo}/pulls/%d/reviews/%s", pull_number, review_id),
    }
    local out = gh_exec(cmd)
    if out == nil then
        return nil
    end
    return out
end

function M.submit_review(pull_number, review_id, body, event)
    local cmd = {
      "api",
      "--method",
      "POST",
      "-H",
      "Accept: application/vnd.github.v3+json",
      string.format("/repos/{owner}/{repo}/pulls/%d/reviews/%s/events", pull_number, review_id),
      "-f",
      string.format("event=%s", event),
    }
    if body ~= nil then
        table.insert(cmd, "-f")
        table.insert(cmd, string.format("body=%s", body))
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
        '--method',
        'GET',
        '-F',
        'per_page=100',
        '/repos/{owner}/{repo}/labels'
    }
    async_request(args, on_read, true)
end

function M.add_label_async(number, label, on_read)
    local args = {
        "issue",
        "edit",
        number,
        "--add-label",
        label
    }
    -- eat the err code if its a json decode.
    -- TODO: refactor async_request to handle no-json decoding option
    local swallow = function(err, data)
        if err == "json decode error" then
            on_read(nil, data)
        else
            on_read(err, data)
        end
    end
    async_request(args, swallow)
end

function M.remove_label_async(number, label, on_read)
    local args = {
        "issue",
        "edit",
        number,
        "--remove-label",
        label
    }
    -- eat the err code if its a json decode.
    -- TODO: refactor async_request to handle no-json decoding option
    local swallow = function(err, data)
        if err == "json decode error" then
            on_read(nil, data)
        else
            on_read(err, data)
        end
    end
    async_request(args, swallow)
end

function M.get_check_suites_async(commit_sha, on_read)
    local args = {
        'api',
        '--method',
        'GET',
        '-F',
        'per_page=100',
        string.format("/repos/{owner}/{repo}/commits/%s/check-suites", commit_sha)
    }
    async_request(args, on_read, true)
end

function M.get_check_runs_by_suite(suite_id, on_read)
    local args = {
        'api',
        '--method',
        'GET',
        '-F',
        'per_page=100',
        string.format("/repos/{owner}/{repo}/check-suites/%s/check-runs", suite_id)
    }
    async_request(args, on_read, true)
end

function M.get_git_protocol()
  local cmd = {"config", "get", "git_protocol"}
  local protocol, e = gh_exec(cmd, true, true);
  if protocol == nil then
    return nil, e
  end

  return protocol:gsub("[\r\n]", "")
end

function M.get_token()
  local cmd = {"auth", "token"}
  local token, e = gh_exec(cmd, true, true);
  if token == nil then
    return nil, e
  end

  return token:gsub("[\r\n]", "")
end

function M.list_repo_contributors_async(on_read)
    local args = {
        'api',
        '--method',
        'GET',
        '-F',
        'per_page=100',
        "/repos/{owner}/{repo}/contributors"
    }
    async_request(args, on_read, true)
end

function M.list_repo_notifications(on_read)
    local args = {
        'api',
        '--method',
        'GET',
        '-F',
        'per_page=100',
        "/repos/{owner}/{repo}/notifications"
    }
    async_request(args, on_read, true)
end

function M.list_repo_notifications_all(on_read)
    local args = {
        'api',
        '--method',
        'GET',
        '-F',
        'per_page=100',
        '-F',
        'all=true',
        "/repos/{owner}/{repo}/notifications"
    }
    async_request(args, on_read, true)
end

function M.set_notification_read(thread_id)
    local cmd = {
      "api",
      "--method",
      "PATCH",
       string.format("/notifications/threads/%s", thread_id)
    }
    return gh_exec(cmd, true)
end

function M.set_notification_ignored(thread_id)
    local cmd = {
      "api",
      "--method",
      "PUT",
      "-F",
      "ignored=true",
       string.format("/notifications/threads/%s/subscription", thread_id)
    }
    return gh_exec(cmd, true)
end

M.user = nil

-- like get_user but caches the results on the first request and returns the
-- cached user on subsequent.
function M.get_cached_user()
    if M.user == nil then
        M.user = M.get_user()
    end
    return M.user
end

return M
