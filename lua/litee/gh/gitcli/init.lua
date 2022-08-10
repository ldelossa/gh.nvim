local debug = require('litee.gh.debug')

local function git_exec(cmd)
    local out = vim.fn.system(cmd)
    if vim.v.shell_error ~= 0 then
        debug.log("[git] cmd: " .. cmd .. " out:\n" .. vim.inspect(out), "error")
        return nil
    end
    debug.log("[git] cmd: " .. cmd .. " out:\n" .. vim.inspect(out), "info")
    return out
end

local M = {}

function M.checkout(remote, commitish)
    local cmd
    if remote == nil then
        cmd = string.format([[git checkout %s]], commitish)
    else
        cmd = string.format([[git checkout %s/%s]], remote, commitish)
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

function M.git_show_and_write(commit, file, write_to)
    local cmd = string.format([[git show %s:%s > %s]], commit, file, write_to)
    local out = git_exec(cmd)
    if out == nil then
        return nil
    end
    return out
end

function M.git_reset_hard(remote, branch)
    local cmd = string.format([[git reset --hard %s/%s]], remote, branch)
    local out = git_exec(cmd)
    if out == nil then
        return nil
    end
    return out
end

return M
