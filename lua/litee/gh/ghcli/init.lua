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

local function get_extra_args(command)
  if c.config.ghcli_extra_args == nil then
    return {}
  end
  for key, value in pairs(c.config.ghcli_extra_args) do
    -- in case we have an array we always use all the extra params
    if (type(key) == 'number') then
      return c.config.ghcli_extra_args
    end

    if command ~= nil then
      if string.match(key, command) then
        return value
      end
    end
  end
  -- nothing found, so we use the global flags, if provided
  local universal_flags = c.config.ghcli_extra_args['*']
  if universal_flags ~= nil then
    return universal_flags
  end
  -- make sure we return a table in any case.
  return {}
end

local function get_global_extra_args(command)
  if c.config.ghcli_extra_args == nil or #c.config.ghcli_extra_args == 0 then
    return {}
  end
  for key, value in ipairs(c.config.ghcli_extra_args) do
    -- in case we have an array we will not have global params
    if (type(key) == 'number') then
      return {}
    end

    if string.match(key, command) then
      return value
    end
  end
  -- make sure we return a table in any case.
  return {}
end

-- gh_exec executs the (assumed) gh command which returns json.
--
-- if nil is returned the second returned argument is the error output.
--
-- if successful the json is decoded into a lua dictionary and returned.
local function gh_exec(args, no_json_decode)
    local extra_args = get_extra_args(args[1])
    for i = #extra_args, 1, -1 do
      table.insert(args, 2, extra_args[i])
    end

    local global_extra_args = get_global_extra_args()
    for i = #global_extra_args, 1, -1 do
      table.insert(args, 1, global_extra_args[i])
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
    local errbuf = ""
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

    local original_args = vim.deepcopy(args)

    local extra_args = get_extra_args(args[1])
    for i = #extra_args, 1, -1 do
      table.insert(args, 2, extra_args[i])
    end

    local global_extra_args = get_global_extra_args('gh')
    for i = #global_extra_args, 1, -1 do
      table.insert(args, 1, global_extra_args[i])
    end

    -- Finish only once gh has exited *and* both pipes hit EOF: the exit callback
    -- can run before the last stdout chunk is read, and closing the pipes there
    -- dropped it, so on_read was never called and PR loading stalled silently.
    local pending, exit_code = 3, 0
    local function finish()
        pending = pending - 1
        if pending > 0 then
            return
        end
        if handle ~= nil and not handle:is_closing() then handle:close() end
        if not stdout:is_closing() then stdout:close() end
        if not stderr:is_closing() then stderr:close() end

        local data = json_decode_safe(buffer)
        local err = check_error(data)
        if err == "json decode error" and vim.trim(errbuf) ~= "" then
            err = vim.trim(errbuf)
        elseif err == false and exit_code ~= 0 then
            err = vim.trim(errbuf) ~= "" and vim.trim(errbuf) or ("gh exited with code " .. exit_code)
        end
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
        if paginate and #data > 0 then
            debug.log("[gh] cmd: " .. debug_fmt_args(args) .. " out:\n" .. vim.inspect(data), "info")
            async_request(original_args, on_read, paginate, page+1, paged_data)
            return
        end
        debug.log("[gh] cmd: " .. debug_fmt_args(args) .. " out:\n" .. vim.inspect(data), "info")
        vim.schedule(function() on_read(false, paged_data) end)
    end

    local spawn_err
    handle, spawn_err = vim.loop.spawn('gh', {
        args = args,
        stdio = {nil, stdout, stderr},
        },
        function(code)
            exit_code = code
            finish()
        end
    )
    if handle == nil then
        stdout:close()
        stderr:close()
        local err = "failed to run gh: " .. tostring(spawn_err)
        debug.log("[gh] cmd: " .. debug_fmt_args(args) .. " out:\n" .. err, "error")
        vim.schedule(function() on_read(err, nil) end)
        return
    end
    local function reader(pipe, append)
        return function(err, data)
            if err then
                debug.log("[gh] cmd: " .. debug_fmt_args(args) .. " out:\n" .. vim.inspect(err), "error")
            elseif data then
                append(data)
                return
            end
            pipe:read_stop()
            finish()
        end
    end
    vim.loop.read_start(stdout, reader(stdout, function(d) buffer = buffer .. d end))
    vim.loop.read_start(stderr, reader(stderr, function(d) errbuf = errbuf .. d end))
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
    local args = {"api", "--method", "GET", "-F", "per_page=100", string.format("/repos/{owner}/{repo}/pulls/%d/files", pull_number)}
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
      string.format("side=%s", side),
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
      string.format("start_side=%s", side),
      "-F",
      string.format("side=%s", side),
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
      string.format("reply=%s", reply_id),
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
  local protocol, e = gh_exec(cmd, true);
  if protocol == nil then
    return nil, e
  end

  return protocol:gsub("[\r\n]", "")
end

function M.get_token()
  local cmd = {"auth", "token"}
  local token, e = gh_exec(cmd, true);
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

-- gh_api_json runs `gh api` with an optional JSON body sent via --input (keeps
-- large payloads off argv). Unlike gh_exec, a "message" key is not treated as
-- an error since git commit objects carry one.
local function gh_api_json(host, method, path, body)
    local args = { "api", "--hostname", host, "--method", method, path }
    local tmp
    if body ~= nil then
        tmp = vim.fn.tempname()
        local f = io.open(tmp, "wb")
        if f == nil then
            return nil
        end
        f:write(vim.json.encode(body))
        f:close()
        table.insert(args, "--input")
        table.insert(args, tmp)
    end
    local out = gh_exec(args, true)
    if tmp ~= nil then
        os.remove(tmp)
    end
    if out == nil then
        return nil
    end
    local ok, decoded = pcall(vim.json.decode, out)
    if not ok or type(decoded) ~= "table" then
        return nil
    end
    return decoded
end

-- upload_file commits a local file to `branch` of `repo` ("owner/name") on
-- `host` using the Git Data API, creating the branch on first use. GitHub has
-- no public API for comment attachments, so the returned blob URL (pinned to
-- the new commit) is what gets embedded in markdown.
--
-- returns the URL, or nil and an error message.
function M.upload_file(host, repo, html_url, branch, file_path, dest_path)
    local f = io.open(file_path, "rb")
    if f == nil then
        return nil, "cannot read " .. file_path
    end
    local data = f:read("*a")
    f:close()

    local git = "/repos/" .. repo .. "/git/"
    local blob = gh_api_json(host, "POST", git .. "blobs", {
        content = vim.base64.encode(data),
        encoding = "base64",
    })
    if blob == nil then
        return nil, "failed to create blob in " .. repo .. " (push access required)"
    end

    -- retry if another upload moves the branch between read and update.
    for _ = 1, 3 do
        local ref = gh_api_json(host, "GET", git .. "ref/heads/" .. branch)
        local parent = ref ~= nil and ref.object ~= nil and ref.object.sha or nil
        local base_tree
        if parent ~= nil then
            local parent_commit = gh_api_json(host, "GET", git .. "commits/" .. parent)
            if parent_commit == nil then
                return nil, "failed to read branch " .. branch
            end
            base_tree = parent_commit.tree.sha
        end

        local tree = gh_api_json(host, "POST", git .. "trees", {
            base_tree = base_tree,
            tree = { { path = dest_path, mode = "100644", type = "blob", sha = blob.sha } },
        })
        if tree == nil then
            return nil, "failed to create tree"
        end

        local commit = gh_api_json(host, "POST", git .. "commits", {
            message = "gh.nvim: add " .. dest_path,
            tree = tree.sha,
            parents = { parent },
        })
        if commit == nil then
            return nil, "failed to create commit"
        end

        local updated
        if parent ~= nil then
            updated = gh_api_json(host, "PATCH", git .. "refs/heads/" .. branch, { sha = commit.sha })
        else
            updated = gh_api_json(host, "POST", git .. "refs", { ref = "refs/heads/" .. branch, sha = commit.sha })
        end
        if updated ~= nil then
            return string.format("%s/blob/%s/%s?raw=true", html_url, commit.sha, dest_path)
        end
    end
    return nil, "failed to update branch " .. branch
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
