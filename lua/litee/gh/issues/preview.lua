local lib_notify    = require('litee.lib.notify')

local ghcli         = require('litee.gh.ghcli')
local config        = require('litee.gh.config')

local M = {}

local symbols = {
    top =    "╭",
    left =   "│",
    bottom = "╰",
    tab = "  ",
}

function M.preview_issue(number)
    ghcli.get_issue_async(number, function(err, issue_data)
        if err then
            lib_notify.notify_popup_with_timeout("Failed to fetch issue: " .. err, 7500, "error")
            return
        end
        if issue_data == nil then
            lib_notify.notify_popup_with_timeout("Failed to fetch issue.", 7500, "error")
            return
        end
        local buf = M.render_issue(issue_data)
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
    end)
end

local function parse_comment_body(body, left_sign)
    local lines = {}
    body = vim.fn.split(body, '\n')
    for _, line in ipairs(body) do
        line = vim.fn.substitute(line, "\r", "", "g")
        line = vim.fn.substitute(line, "\n", "", "g")
        line = vim.fn.substitute(line, "\t", symbols.tab, "g")
        if left_sign then
            line = symbols.left .. line
        end
        table.insert(lines, line)
    end
    return lines
end

function M.render_issue(issue)
    local buf = vim.api.nvim_create_buf(true, true)

    local buffer_lines = {}

    local type = ""
    if vim.fn.match(issue["node_id"], "PR_") ~= -1 then
        type = "Pull Request"
    else
        type = "Issue"
    end
    table.insert(buffer_lines, string.format("%s %s  %s %s%s", symbols.top, config.icon_set["GitIssue"], type, config.icon_set["Number"], issue["number"]))
    table.insert(buffer_lines, string.format("%s %s  Author: %s", symbols.left, config.icon_set["Account"], issue["user"]["login"]))
    table.insert(buffer_lines, string.format("%s %s  Created: %s", symbols.left, config.icon_set["Calendar"], issue["created_at"]))
    table.insert(buffer_lines, string.format("%s %s  Last Updated: %s", symbols.left, config.icon_set["Calendar"], issue["updated_at"]))
    table.insert(buffer_lines, string.format("%s %s  Title: %s", symbols.left, config.icon_set["Pencil"], issue["title"]))
    table.insert(buffer_lines, symbols.left)
    local body_lines = parse_comment_body(issue["body"], true)
    for _, l in ipairs(body_lines) do
        table.insert(buffer_lines, l)
    end
    table.insert(buffer_lines, symbols.left)
    table.insert(buffer_lines, symbols.bottom)

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
    vim.api.nvim_buf_set_lines(buf, 0, #buffer_lines, false, buffer_lines)

    return buf
end

return M
