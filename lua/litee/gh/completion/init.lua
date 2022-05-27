local ghcli = require('litee.gh.ghcli')

local M = {}

M.contributor_cache = {}

M.issue_cache = {}

local function fill_contributor_cache()
    ghcli.list_repo_contributors_async(function(err, data)
        if err then
            -- we may not be in a git repo, so just ignore this.
            return
        end
        M.contributor_cache = data
    end)    
end
fill_contributor_cache()

local function fill_issue_cache()
    ghcli.list_all_repo_issues_async(function(err, data)
        if err then
            -- we may not be in a git repo, so just ignore this.
            return
        end
        M.issue_cache = data
    end)    
end
fill_issue_cache()

-- global lua function which can be used as omnifunc like:
-- vim.api.nvim_buf_set_option(buf, 'ofu', 'v:lua.GH_completion')
function GH_completion(start, base)
    -- opportunistic async refresh, may not load the item we want this time, but
    -- will on a retry.
    fill_contributor_cache()
    fill_issue_cache()
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
        for _, contributor in ipairs(M.contributor_cache) do
            if vim.fn.match("@"..contributor["login"], base) ~= -1 then
                table.insert(matches, {
                    word = "@"..contributor["login"],
                    menu = contributor["type"]
                })
            end
        end
        return matches
    elseif vim.fn.match(base, "#") ~= -1 then
        local matches = {}
        for _, iss in ipairs(M.issue_cache) do
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

return M
