local s    = require('litee.gh.pr.state')
local lib_tree_node = require('litee.lib.tree.node')

local M = {}

function M.build_reviews_subtree(depth, prev_tree)
    local prev_root = nil
    if prev_tree ~= nil and prev_tree.depth_table[depth] ~= nil then
        for _, prev_node in ipairs(prev_tree.depth_table[depth]) do
            if prev_node.key == "Reviews:" then
                prev_root = prev_node
            end
        end
    end
    local root = lib_tree_node.new_node(
        "Reviews:",
        "Reviews:",
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

    for _, review in pairs(s.pull_state.reviews_by_node_id) do
        if
            -- ignore commented reviews, they show up in the "conversations"
            -- sections.
            review["state"] == "COMMENTED"
        then
            goto continue
        end

        local r = lib_tree_node.new_node(
            review["node_id"],
            review["node_id"],
            depth+1 -- we a subtree of root
        )
        r.expanded = true
        r.review =  review
        table.insert(root.children, r)
        ::continue::
    end
    -- sort by submitted date
    table.sort(root.children, function(a,b)
        if a.review["submitted_at"] == nil then
            return true
        end
        if b.review["submitted_at"] == nil then
            return false
        end
        return a.review["submitted_at"] < b.review["submitted_at"]
    end)

    -- add requested reviews
    for _, rr in ipairs(s.pull_state.pr_raw["requested_reviewers"]) do
        local rr_node = lib_tree_node.new_node(
            rr["login"],
            "requested_reviewers:" .. rr["login"],
            depth+1 -- we are a child to the root details node created above, selfsame for all following.
        )
        rr_node.requested_review = rr
        rr_node.expanded = true
        table.insert(root.children, rr_node)
    end
    for _, rr in ipairs(s.pull_state.pr_raw["requested_teams"]) do
        local rr_node = lib_tree_node.new_node(
            rr["slug"],
            "requested_reviewers:" .. rr["slug"],
            depth+1 -- we are a child to the root details node created above, selfsame for all following.
        )
        rr_node.requested_review = rr
        rr_node.expanded = true
        table.insert(root.children, rr_node)
    end

    return root
end


return M
