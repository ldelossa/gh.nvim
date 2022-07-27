local lib_notify = require('litee.lib.notify')
local lib_path      = require('litee.lib.util.path')

local ghcli         = require('litee.gh.ghcli')
local commit_buffer  = require('litee.gh.commits.commit_buffer')
local config        = require('litee.gh.config')

local M = {}

function M.open_commit_by_sha(sha, cur_win)
    -- if we are already displaying this commit, just open that win, don't spam
    -- neovim with multiple issue buffers of the same issue.
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        local buf = vim.api.nvim_win_get_buf(win)
        local buf_name = vim.api.nvim_buf_get_name(buf)
        if buf_name == sha then
            vim.api.nvim_set_current_win(win)
            return
        end
    end
    commit_buffer.load_commit(sha, vim.schedule_wrap(function()
        local buf = commit_buffer.render_commit(sha)
        if cur_win then
            vim.api.nvim_win_set_buf(0, buf)
        else
            vim.cmd("tabnew")
            vim.api.nvim_win_set_buf(0, buf)
        end
        local commit_state = commit_buffer.state_by_sha[sha]
        commit_state.win = vim.api.nvim_get_current_win()
    end))
end

function M.on_refresh()
    commit_buffer.on_refresh()
end

return M
