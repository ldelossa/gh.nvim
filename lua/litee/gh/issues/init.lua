local lib_notify = require('litee.lib.notify')
local lib_path      = require('litee.lib.util.path')

local ghcli         = require('litee.gh.ghcli')
local issue_buffer  = require('litee.gh.issues.issue_buffer')
local preview       = require('litee.gh.issues.preview')
local config        = require('litee.gh.config')

local M = {}

local function extract_issue_under_cursor()
    local current_word = vim.fn.expand('<cWORD>')
    local issue_number = current_word:match('^#[0-9]+')

    if issue_number == nil then
      return nil
    end

    return issue_number:gsub('#', '')
end

function M.open_issue_by_number(number, cur_win)
    -- if we are already displaying this issue, just open that win, don't spam
    -- neovim with multiple issue buffers of the same issue.
    local buf_name = "issue #" .. number
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        local buf = vim.api.nvim_win_get_buf(win)
        local name = lib_path.basename(vim.api.nvim_buf_get_name(buf))
        if buf_name == name then
            vim.api.nvim_set_current_win(win)
            return
        end
    end
    issue_buffer.load_issue(number, vim.schedule_wrap(function()
        local buf = issue_buffer.render_issue(number)
        if cur_win then
            vim.api.nvim_win_set_buf(0, buf)
        else
            vim.cmd("tabnew")
            vim.api.nvim_win_set_buf(0, buf)
        end
        local iss_state = issue_buffer.state_by_number[number]
        iss_state.win = vim.api.nvim_get_current_win()
    end))
end

function M.open_issue_under_cursor()
    local issue = extract_issue_under_cursor()
    if issue == nil then
        return
    end
    M.open_issue_by_number(issue)
end

function M.preview_issue_under_cursor()
    local number = extract_issue_under_cursor()
    if number == nil then
        return
    end
    preview.preview_issue(number)
end

function M.open_issue(args)
    if args["args"] ~= "" then
            M.open_issue_by_number(args["args"])
            return
    end

    lib_notify.notify_popup_with_timeout("Fetching all repo issues this could take a bit...", 7500, "info")
    ghcli.list_all_repo_issues_async(function(err, data)
        if err then
            lib_notify.notify_popup_with_timeout("Failed to list issues: " .. err, 7500, "error")
            return
        end

        vim.ui.select(
            data,
            {
                prompt = 'Select an issue to open:',
                format_item = function(issue)
                    return string.format([[%s%d | %s  "%s" | %s  %s]], config.icon_set["Number"], issue["number"], config.icon_set["GitPullRequest"], issue["title"], config.icon_set["Account"], issue["user"]["login"])
                end,
            },
            function(_, idx)
                if idx == nil then
                    return
                end
                    M.open_issue_by_number(data[idx]["number"])
            end
        )
    end)
end

function M.search_issues()
    vim.ui.input(
        {prompt = 'Enter a query string or leave blank for all issues: '},
        function(input) 
            local repo = ghcli.get_repo_name_owner()
            lib_notify.notify_popup_with_timeout("Searching for issues, this may take a bit...", 7500, "info")
            ghcli.search_issues(repo["owner"]["login"], repo["name"], input, function(err, issues) 
                if err then
                    lib_notify.notify_popup_with_timeout("Failed to list issues: " .. err, 7500, "error")
                    return
                end
                table.sort(issues, function(a,b)
                    return a["updated_at"] > b["updated_at"]
                end)
                vim.ui.select(
                    issues,
                    {
                        prompt = 'Select an issue to open: ',
                        format_item = function(issue)
                            return string.format([[%s%d | %s "%s" | %s %s]], config.icon_set["Number"], issue["number"], config.icon_set["GitIssue"], issue["title"], config.icon_set["Account"], issue["user"]["login"])
                        end,
                    },
                    function(_, idx)
                        if idx == nil then
                            return
                        end
                        M.open_issue_by_number(issues[idx]["number"])
                    end
                )
            end)
        end
    )
end


function M.on_refresh()
    issue_buffer.on_refresh()
end

-- set the issue buffer's calls backs.
issue_buffer.set_callbacks({
    preview_cb = M.preview_issue_under_cursor,
    goto_cb = M.open_issue_under_cursor
})

return M
