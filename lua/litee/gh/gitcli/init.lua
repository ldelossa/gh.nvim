local debug = require('litee.gh.debug')

local function git_exec(cmd)
    local out = vim.fn.system(cmd)
    if vim.v.shell_error ~= 0 then
        debug.log("[git] cmd: " .. vim.inspect(cmd) .. " out:\n" .. vim.inspect(out), "error")
        return nil
    end
    debug.log("[git] cmd: " .. vim.inspect(cmd) .. " out:\n" .. vim.inspect(out), "info")
    return out
end

local M = {}

local function git_trim(args)
    local out = vim.fn.system(args)
    if vim.v.shell_error ~= 0 then
        return nil
    end
    return vim.trim(out)
end

function M.toplevel()
    return git_trim({ "git", "rev-parse", "--show-toplevel" })
end

local function head_desc()
    return git_trim({ "git", "symbolic-ref", "--quiet", "--short", "HEAD" })
        or ("detached at " .. (git_trim({ "git", "rev-parse", "--short", "HEAD" }) or "?"))
end

local function head_is(target)
    local head = git_trim({ "git", "rev-parse", "HEAD" })
    local want = git_trim({ "git", "rev-parse", "--verify", "--quiet", target .. "^{commit}" })
    return head ~= nil and head == want
end

-- targets the user already declined to check out in this session, so they
-- are not asked again every time a node is opened.
local declined = {}

-- approved asks the user before running a command that moves HEAD or the
-- current branch. The branch must never change without explicit approval.
local function approved(cmd)
    local msg = string.format("gh.nvim wants to run:\n  %s\n(current: %s)\nAllow?", cmd, head_desc())
    return vim.fn.confirm(msg, "&No\n&Yes", 1) == 2
end

local function skipped(cmd)
    vim.notify("gh.nvim: skipped `" .. cmd .. "`; diff right side shows your working tree.", vim.log.levels.WARN)
end

function M.checkout(remote, commitish)
    local target = commitish
    if remote ~= nil then
        target = remote .. "/" .. commitish
    end
    if head_is(target) then
        return ""
    end
    local cmd = string.format([[git checkout %s]], target)
    if declined[target] then
        return ""
    end
    if not approved(cmd) then
        declined[target] = true
        skipped(cmd)
        return ""
    end
    local out = git_exec(cmd)
    if out == nil then
        return nil
    end
    return out
end

function M.pull(remote, branch)
    local cmd = string.format([[git pull %s %s]], remote, branch)
    local out = git_exec(cmd)
    if out == nil then
        return nil
    end
    return out
end

function M.fetch(remote, branch)
    local cmd = string.format([[git fetch %s %s]], remote, branch)
    local out = git_exec(cmd)
    if out == nil then
        return nil
    end
    return out
end

function M.add_remote(name, remote_url)
    local cmd = string.format([[git remote add %s %s]], name, remote_url)
    local out = git_exec(cmd)
    if out == nil then
        return nil
    end
    return out
end

function M.remove_remote(name)
    local cmd = string.format([[git remote remove %s]], name)
    local out = git_exec(cmd)
    if out == nil then
        return nil
    end
    return out
end

function M.list_remotes()
    local cmd = string.format([[git remote]])
    local out = git_exec(cmd)
    if out == nil then
        return nil
    end
    return vim.fn.split(out, "\n")
end

function M.repo_dirty()
    local cmd = [[git status --porcelain]]
    local out = git_exec(cmd)
    if out == nil then
        return nil
    end
    if vim.fn.strlen(out) > 0 then
        return true
    end
    return false
end

function M.remote_exists(remote_url)
    local cmd = [[git remote -v]]
    local out = git_exec(cmd)
    if out == nil then
        return nil
    end
    local bool = vim.fn.match(out, remote_url)
    if bool == -1 then
        return false
    end
    local lines = vim.fn.split(out, "\n")
    local remote = ""
    for _, line in ipairs(lines) do
        bool = vim.fn.match(line, remote_url)
        if bool ~= -1 then
            local idx = vim.fn.stridx(line, "\t", 0)
            remote = vim.fn.strpart(line, 0, idx)
            break
        end
    end
    return true, remote
end

function M.remote_branch_exists(remote_url, branch)
    local cmd = [[git ls-remote --heads ]] .. remote_url .. " " .. branch
    local out = git_exec(cmd)
    if out == nil then
        return nil
    end

    if #out == 0 then
        return false
    else
        return true
    end
end

-- object_exists reports whether the given revision is present in the local
-- repository.
function M.object_exists(commit)
    if commit == nil then
        return false
    end
    return git_trim({ "git", "cat-file", "-e", tostring(commit) .. "^{commit}" }) ~= nil
end

-- merge_base returns the best common ancestor of two revisions, or nil when it
-- cannot be computed (for example when one side is not in our object store).
function M.merge_base(a, b)
    if a == nil or b == nil then
        return nil
    end
    return git_trim({ "git", "merge-base", tostring(a), tostring(b) })
end

function M.git_show_and_write(commit, file, write_to)
    -- remember whether the commit is known at all: the file may simply not exist
    -- at that commit (an added file, which legitimately diffs an empty buffer),
    -- but an unknown commit means the diff pane would be empty for the wrong
    -- reason. `git show ... > file` hides both behind the same empty file.
    local commit_known = M.object_exists(commit)
    local cmd = string.format([[git show %s > %s]],
        vim.fn.shellescape(commit .. ":" .. file), vim.fn.shellescape(write_to))
    local out = git_exec(cmd)
    if out == nil or not commit_known then
        -- keep the redirect's contract: the target exists and is empty.
        vim.fn.writefile({}, write_to)
        return nil
    end
    return out
end

function M.git_reset_hard(remote, branch)
    local cmd = string.format([[git reset --hard %s/%s]], remote, branch)
    if not approved(cmd) then
        vim.notify("gh.nvim: skipped `" .. cmd .. "`.", vim.log.levels.WARN)
        return ""
    end
    local out = git_exec(cmd)
    if out == nil then
        return nil
    end
    return out
end

return M
