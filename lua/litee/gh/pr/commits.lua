local M = {}

local lib_tree_node = require('litee.lib.tree.node')

-- build_commits_tree builds a sub-tree of commit objects.
--
-- the root of the tree is a solely information.
--
-- each child is a commit node which holds a "commit" field with the GitHub
-- API schema for a commit.
function M.build_commits_tree(commits, depth, prev_tree)
    local prev_root = nil
    if prev_tree ~= nil and prev_tree.depth_table[depth] ~= nil then
        for _, prev_node in ipairs(prev_tree.depth_table[depth]) do
            if prev_node.key == "Commits:" then
                prev_root = prev_node
            end
        end
    end
    local root = lib_tree_node.new_node(
        "Commits:",
        "Commits:",
        depth
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

    local children = {}
    for _, commit in ipairs(commits) do
        local child_node = lib_tree_node.new_node(
            commit["sha"],
            commit["sha"],
            depth+1 -- we really just have a list of commits, so all depths are 1
        )
        child_node.commit = commit
        child_node.expanded = true
        table.insert(children, child_node)
    end

    root.children = children
    return root
end

return M
