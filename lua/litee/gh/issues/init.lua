local issue_buffer = require('litee.gh.issues.issue_buffer')
local lib_notify    = require('litee.lib.notify')
local ghcli         = require('litee.gh.ghcli')

local M = {}

function M.open_issue_by_number(number)
    issue_buffer.load_issue(number, vim.schedule_wrap(function()
        local buf = issue_buffer.render_issue()
        vim.cmd("tabnew")
        vim.api.nvim_win_set_buf(0, buf)
    end))
end

function M.open_issue(args)
    if args["args"] ~= "" then
        M.open_issue_by_number(args["args"])
    end

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
                    return string.format([[%d |  "%s" |  %s]], issue["number"], issue["title"], issue["user"]["login"])
                end,
            },
            function(_, idx)
                if idx == nil then
                    return
                end
                issue_buffer.load_issue(data[idx]["number"], vim.schedule_wrap(function()
                    local buf = issue_buffer.render_issue()
                    vim.cmd("tabnew")
                    vim.api.nvim_win_set_buf(0, buf)
                end))
            end
        )
    end)
end

return M
