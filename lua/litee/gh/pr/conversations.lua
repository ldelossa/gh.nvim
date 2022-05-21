local lib_tree_node = require('litee.lib.tree.node')
local comments      = require('litee.gh.pr.comments')

local M = {}

function M.build_conversations_tree(threads, depth, prev_tree)
    local prev_root = nil
    if prev_tree ~= nil and prev_tree.depth_table[depth] ~= nil then
        for _, prev_node in ipairs(prev_tree.depth_table[depth]) do
            if prev_node.key == "Conversations:" then
                prev_root = prev_node
            end
        end
    end
    local root = lib_tree_node.new_node(
        "Conversations:",
        "Conversations:",
        depth -- we a subtree of root
    )
    root.expanded = true
    if prev_root ~= nil then
        root.expanded = prev_root.expanded
    end
    root.details = {
        name = root.name,
        detail = "",
        icon = ""
    }

    local _, _, thread_nodes = comments.build_review_thread_trees(threads, depth+1)
    for _, t in ipairs(thread_nodes) do
        table.insert(root.children, t)
    end
    return root
end

return M
