local issues = require('litee.gh.issues')
local issue_buffer = require('litee.gh.issues.issue_buffer')

local M = {}

function M.open_issue_under_cursor()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local line = vim.api.nvim_buf_get_lines(0, cursor[1]-1, cursor[1], true)
    local issue_number = ""
    line = line[1]

    local start_idx = vim.fn.strridx(line, "#", cursor[2])
    if start_idx == -1 then
        return
    end
    issue_number = vim.fn.matchstr(line, "#[0-9]*", start_idx-1)
    if issue_number == -1 then
        return
    end

    local format = vim.fn.substitute(issue_number, "#", "", "")
    issues.open_issue_by_number(format)
end

function M.preview_issue_under_cursor()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local line = vim.api.nvim_buf_get_lines(0, cursor[1]-1, cursor[1], true)
    local issue_number = ""
    line = line[1]

    local start_idx = vim.fn.strridx(line, "#", cursor[2])
    if start_idx == -1 then
        return
    end
    issue_number = vim.fn.matchstr(line, "#[0-9]*", start_idx-1)
    if issue_number == -1 then
        return
    end

    local format = vim.fn.substitute(issue_number, "#", "", "")
    issue_buffer.load_issue(format, vim.schedule_wrap(function ()
            local buf = issue_buffer.render_issue(true)
            local width = 20
            local line_count = 0
            for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
                local line_width = vim.fn.strdisplaywidth(line)
                if line_width > width then
                    width = line_width
                end
                line_count = i
            end

            local popup_conf = vim.lsp.util.make_floating_popup_options(
                    width,
                    line_count,
                    {
                        border= "rounded",
                        focusable= false,
                        zindex = 99,
                        relative = "cursor"
                    }
            )
            local cur_win = vim.api.nvim_get_current_win()
            local win = vim.api.nvim_open_win(buf, false, popup_conf)
            local id = vim.api.nvim_create_autocmd({"CursorMoved"}, {
                buffer = vim.api.nvim_win_get_buf(cur_win),
                callback = function()
                    if vim.api.nvim_win_is_valid(win) then
                        vim.api.nvim_win_close(win, true)
                    end
                end,
            })
        end, true)
    )
end

return M
