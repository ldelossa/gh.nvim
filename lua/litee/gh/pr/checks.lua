local lib_tree_node = require('litee.lib.tree.node')

local M = {}

function M.build_checks_tree(checks, depth, prev_tree)
    local prev_root = nil
    if prev_tree ~= nil and prev_tree.depth_table[depth] ~= nil then
        for _, prev_node in ipairs(prev_tree.depth_table[depth]) do
            if prev_node.key == "Checks:" then
                prev_root = prev_node
            end
        end
    end
    local root = lib_tree_node.new_node(
        "Checks:",
        "Checks:",
        depth -- we a subtree of root
    )
    root.expanded = true
    if prev_root ~= nil then
        root.expanded = prev_root.expanded
    end
    -- function M.marshal_pr_commit_node(node) will look for generic detail
    -- fields and pass the name, details, icon fields as is.
    root.details = {
        name = root.name,
        detail = "",
        icon = ""
    }

    for _, check in ipairs(checks) do
        local c_node = lib_tree_node.new_node(
            check["name"],
            check["id"],
            depth+1 -- we are a child to the root details node created above, selfsame for all following.
        )
        c_node.check = check
        c_node.expanded = true
        table.insert(root.children, c_node)
    end

    table.sort(root.children, function(a,b)
        return a.name < b.name
    end)

    return root
end

return M

