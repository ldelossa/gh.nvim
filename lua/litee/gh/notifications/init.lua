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
    vim.cmd("tabnew") 
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
        ghcli.list_repo_notifications(function(err, data)
            if err then
                lib_notify.notify_popup_with_timeout("Failed to list notifications: " .. err, 7500, "error")
                return
            end
            -- just render into the current buffer, do not try to set it to a win
            noti_buffer.render_notifications(data)
        end)
    end)
end

return M
