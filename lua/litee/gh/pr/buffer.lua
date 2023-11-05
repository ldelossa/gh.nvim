local config = require('litee.gh.config').config
local panel_config = require('litee.lib.config').config["panel"]
local lib_util_buf = require('litee.lib.util.buffer')

local M = {}

function M.setup_buffer(name, buf, tab, node_handler, details_handler)
    -- see if we can reuse a buffer that currently exists.
    if buf == nil or not vim.api.nvim_buf_is_valid(buf) then
        buf = vim.api.nvim_create_buf(false, false)
        if buf == 0 then
            vim.api.nvim_err_writeln("commits.buffer: buffer create failed")
            return
        end
    else
        return buf
    end

    -- set buf options
    vim.api.nvim_buf_set_name(buf, name .. ":" .. tab)
    vim.api.nvim_set_option_value('bufhidden', 'hide', { buf = buf })
    vim.api.nvim_set_option_value('filetype', 'pr', { buf = buf })
    vim.api.nvim_set_option_value('buftype', 'nofile', { buf = buf })
    vim.api.nvim_set_option_value('modifiable', false, { buf = buf })
    vim.api.nvim_set_option_value('swapfile', false, { buf = buf })
    vim.api.nvim_set_option_value('textwidth', 0, { buf = buf })
    vim.api.nvim_set_option_value('wrapmargin', 0, { buf = buf })

    -- set buffer local keymaps
    if not config.disable_keymaps then
        local open_opts = {
            silent=true,
            callback=node_handler
        }
        vim.api.nvim_buf_set_keymap(buf, "n", config.keymaps.open, "", open_opts)
        local details_opts = {
            silent=true,
            callback=details_handler
        }
        vim.api.nvim_buf_set_keymap(buf, "n", config.keymaps.details, "", details_opts)
        if config.map_resize_keys then
               lib_util_buf.map_resize_keys(panel_config.orientation, buf, {silent=true})
        end
    end
    return buf
end

return M
