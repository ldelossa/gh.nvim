local lib_notify = require('litee.lib.notify')
local lib_icons     = require('litee.lib.icons')

local config        = require('litee.gh.config').config
local ghcli = require('litee.gh.ghcli')
local issue_buffer = require('litee.gh.issues.issue_buffer')

local M = {}

local function extract_issue_cur_line()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local line = vim.api.nvim_buf_get_lines(0, cursor[1]-1, cursor[1], true)
    local issue_number = ""
    line = line[1]

    local start_idx = vim.fn.strridx(line, "#", cursor[2])
    if start_idx == -1 then
        return nil
    end
    issue_number = vim.fn.matchstr(line, "#[0-9]*", start_idx-1)
    if issue_number == -1 then
        return nil
    end

    local format = vim.fn.substitute(issue_number, "#", "", "")
    return format
end

function M.open_issue_by_number(number)
    issue_buffer.load_issue(number, vim.schedule_wrap(function()
        local buf = issue_buffer.render_issue(number)
        vim.cmd("tabnew")
        vim.api.nvim_win_set_buf(0, buf)
        local iss_state = issue_buffer.state_by_number[number]
        iss_state.win = vim.api.nvim_get_current_win()
    end))
end

function M.open_issue_under_cursor()
    local issue = extract_issue_cur_line()
    if issue == nil then
        return
    end
    local iss_state = issue_buffer.state_by_number[issue]


    if
        iss_state ~= nil and
        iss_state.win ~= nil and
        vim.api.nvim_win_is_valid(iss_state.win)
    then
        vim.api.nvim_set_current_win(iss_state.win)
        return
    end

    M.open_issue_by_number(issue)
end

function M.preview_issue_under_cursor()
    local issue = extract_issue_cur_line()
    if issue == nil then
        return
    end
    issue_buffer.load_issue(issue, vim.schedule_wrap(function ()
            local buf = issue_buffer.render_issue(issue, true)
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

function M.open_issue(args)
    local icon_set = "default"
    if config.icon_set ~= nil then
        icon_set = lib_icons[config.icon_set]
    end

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
                    return string.format([[%s%d | %s  "%s" | %s  %s]], icon_set["Number"], issue["number"], icon_set["GitPullRequest"], issue["title"], icon_set["Account"], issue["user"]["login"])
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

-- set the issue buffer's calls backs.
issue_buffer.set_callbacks({
    preview_cb = M.preview_issue_under_cursor,
    goto_cb = M.open_issue_under_cursor
})

return M
