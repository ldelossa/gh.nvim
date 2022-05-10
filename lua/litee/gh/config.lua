local M = {}

M.config = {
    icon_set    = "codicons",
    jump_mode   = "invoking",
    map_resize_keys = false,
    disable_keymaps = false,
    keymaps = {
        open = "<CR>",
        expand = "zo",
        collapse = "zc",
        goto_issue = "gd",
        details = "d"
    },
}

return M
