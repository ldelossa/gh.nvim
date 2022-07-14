local lib_notify  = require('litee.lib.notify')

local ghcli       = require('litee.gh.ghcli')
local noti_buffer = require('litee.gh.notifications.notifications_buffer')

local M = {}

M.state = nil

function M.reset_state()
    M.state = {
        tab = nil,
        win = nil,
        buf = nil,
    }
end

-- a bit of a heuristic, but determine if we can open notifications in the 
-- current tab and current win but checking if there is only one tab with unlisted
-- buffers.
local function determine_new_tab()
     local tabs = vim.api.nvim_list_tabpages()
     if #tabs > 1 then
         vim.cmd("tabnew")
         return
     end
     local only_noname_buffer = true
     for _, buf in ipairs(vim.api.nvim_list_bufs()) do
         if
             vim.api.nvim_buf_get_option(buf, "buflisted")
             and vim.api.nvim_buf_get_name(buf) ~= ""
         then
             only_noname_buffer = false
         end
     end
     if not only_noname_buffer then
         vim.cmd("tabnew")
     end
end

function M.open_notifications()
    if
        M.state == nil or
        not vim.api.nvim_win_is_valid(M.state.win) or
        not vim.api.nvim_buf_is_valid(M.state.buf)
    then
        M.reset_state()
        M.state.tab = vim.api.nvim_get_current_tabpage()
        M.state.win = vim.api.nvim_get_current_win()
    end
    determine_new_tab()
    ghcli.list_repo_notifications(function(err, data)
        if err then
            lib_notify.notify_popup_with_timeout("Failed to list notifications: " .. err, 7500, "error")
            return
        end
        M.state.buf = noti_buffer.render_notifications(data)
        M.state.tab = vim.api.nvim_get_current_tabpage()
        M.state.win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(M.state.win, M.state.buf)
        vim.api.nvim_set_current_win(M.state.win)
    end)
end

function M.on_refresh()
    vim.schedule(function()
        if
            M.state == nil or
            not vim.api.nvim_win_is_valid(M.state.win) or
            not vim.api.nvim_buf_is_valid(M.state.buf)
        then
            return
        end
        noti_buffer.refresh()
    end)
end

return M
