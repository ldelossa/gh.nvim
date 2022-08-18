local M = {}

-- return the owner and repo as two arguments given a issue object returned
-- from the gh api.
function M.gh_api_issue_repo_owner(issue)
    -- repository_url = "https://api.github.com/repos/cilium/cilium"

    if issue["repository_url"] == nil then
        return nil
    end

    local parts = vim.fn.split(issue["repository_url"], "/")
    return parts[5], parts[6]
end

return M
