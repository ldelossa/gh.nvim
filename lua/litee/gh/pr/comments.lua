local lib_tree_node = require('litee.lib.tree.node')

local M = {}

function M.build_conversation_tree(depth)
    local root = lib_tree_node.new_node(
        "Conversations:",
        "Conversations:",
        depth -- we a subtree of root
    )
    root.expanded = true
    root.details = {
        name = root.name,
        detail = "",
        icon = ""
    }
end

function M.build_issue_comment_nodes(comments, depth)
    local nodes = {}
    local comments_by_id = {}

    comments = comments["data"]["repository"]["pullRequest"]["comments"]["edges"]

    for _, c in ipairs(comments) do
        c = c["node"]
        local comment = lib_tree_node.new_node(
            c["id"],
            c["id"],
            depth
        )
        comment.expanded = true
        comment.issue_comment = c
        table.insert(nodes, comment)
        comments_by_id[c["id"]] = comment
    end
    return nodes, comments_by_id
end

-- incoming threads will be graphql structure.
function M.build_review_thread_trees(threads, depth)
    local thread_nodes = {}
    local threads_by_id = {}
    local threads_by_filename = {}
    local thread_comments_by_id = {}

    threads = threads["data"]["repository"]["pullRequest"]["reviewThreads"]["edges"]

    for _, t in ipairs(threads) do
        t = t["node"]
        -- use the original line that the thread was placed on when building
        -- the thread tree. 
        --
        -- if a commit is checked out where this thread is not reachable a 
        -- warning is presented to the user, they can always get to all comments
        -- by checking out head. see: gh/pr/diff_view.lua:408 for warning.
        if t["line"] ~= t["originalLine"] then
            t["line"] = t["originalLine"]
        end

        -- get the root comment, it will tell us if this thread is part of a
        -- review.
        local root_comment_raw = t["comments"]["edges"][1]["node"]

        local effective_depth = depth
        -- create our thread
        local thread = lib_tree_node.new_node(
            t["id"],
            t["id"],
            effective_depth
        )
        thread.thread = t

        if thread.thread["isResolved"] then
            thread.expanded = false
        else
            thread.expanded = true
        end

        if root_comment_raw["pullRequestReview"] ~= nil then
            thread.thread["review_id"] = root_comment_raw["pullRequestReview"]["id"]
        end

        -- add thread to book keeping maps
        threads_by_id[t["id"]] = thread
        if threads_by_filename[t["path"]] == nil then
            threads_by_filename[t["path"]] = {}
        end
        table.insert(threads_by_filename[t["path"]], thread)

        -- parse out comments
        local comments = {}
        for _, c in ipairs(t["comments"]["edges"]) do
            c = c["node"]
            local comment = lib_tree_node.new_node(
                c["id"],
                c["id"],
                effective_depth+1
            )
            comment.comment = c
            comment.comment["thread_id"] = t["id"]
            comment.url = c["url"]
            comment.expanded = true
            table.insert(comments, comment)
            thread_comments_by_id[c["id"]] = comment
        end

        for _, c in ipairs(comments) do
            table.insert(thread.children, c)
        end

        table.insert(thread_nodes, thread)
    end
    return threads_by_id, threads_by_filename, thread_nodes, thread_comments_by_id
end

return M
