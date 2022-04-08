local issue_buffer = require('litee.gh.issues.issue_buffer')

local M = {}

function M.open_issue(number)
    issue_buffer.load_issue(number, vim.schedule_wrap(function()
        local buf = issue_buffer.render_issue()
        vim.cmd("tabnew")
        vim.api.nvim_win_set_buf(0, buf)
    end))
end

return M
