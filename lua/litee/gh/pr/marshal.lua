local lib_path = require('litee.lib.util.path')
local config   = require('litee.gh.config')

local s = require('litee.gh.pr.state')

local M = {}

local function marshal_review_node(node)
    local name, detail, icon = "", "", ""
    name = string.format("%s", node.review["user"]["login"])
    if node.review["state"] == 'APPROVED' then
        name  = name .. " (approved)"
        icon = config.icon_set["PassFilled"]
    elseif node.review["state"] == 'PENDING' then
        name  = name .. " (pending)"
        icon = config.icon_set["Pencil"]
    else
        name  = name .. " (changes required)"
        icon = config.icon_set["RequestChanges"]
    end

    return name, detail, icon
end

local function marshal_requested_review_node(node)
    local name, detail, icon = "", "", ""

    local n = node.requested_review["login"]
    if n == nil then
        n = node.requested_review["slug"]
    end
    name = string.format("%s (requested)", n)
    icon = config.icon_set["CircleFilled"]

    return name, detail, icon
end

local function marshal_thread_node(node)
    local name, detail, icon = "", "", ""

    local line = nil
    if node.thread["originalLine"] ~= vim.NIL then
        line = node.thread["originalLine"]
    end
    if node.thread["line"] ~= vim.NIL then
        line = node.thread["line"]
    end

    name = string.format("%s:%d", node.thread["path"], line)

    if node.thread["isResolved"] then
        icon = config.icon_set["CheckAll"]
    else
        icon = config.icon_set["MultiComment"]
    end

    local count = #node["children"]
    detail = string.format("%d", count)

    return name, detail, icon
end

local function marshal_issue_comment_node(node)
    local name, detail, icon = "", "", ""

    name = "pr comment by " .. node.issue_comment["user"]["login"]
    icon = config.icon_set["Comment"]

    return name, detail, icon
end

local function marshal_details_node(node)
    local name, detail, icon = "", "", ""

    name = node.details["name"]
    detail = node.details["detail"]
    icon = node.details["icon"]

    return name, detail, icon
end

local function marshal_check_node(node)
    local name, detail, icon = "", "", ""

    name = node.check["name"]
    if node.check["conclusion"] ~= vim.NIL then
        detail = node.check["conclusion"]
    end
    if node.check["conclusion"] == "success" then
        icon = config.icon_set["PassFilled"]
    elseif node.check["conclusion"] == "failure" then
        icon = config.icon_set["CircleStop"]
    elseif node.check["conclusion"] == "skipped" then
        icon = config.icon_set["CircleSlash"]
    elseif node.check["status"] == "in_progress" then
        icon = config.icon_set["Sync"]
        detail = "in progress"
    elseif node.check["status"] == "queued" then
        icon = config.icon_set["CirclePause"]
        detail = "queued"
    else
        icon = config.icon_set["Info"]
    end

    return name, detail, icon
end

local function marshal_file_node(node)
    local name, detail, icon = "", "", ""

    name = lib_path.basename(node.file["filename"])
    if node.file["state"] ~= vim.NIL then
        detail = node.file["status"]
    end
    icon = config.icon_set["File"]

    return name, detail, icon
end

local function marshal_commit_node(node)
    local name, detail, icon = "", "", ""

    name = vim.fn.strcharpart(node.commit["sha"], 0, 8)

    local commit_title = node.commit["commit"]["message"]
    local new_line_idx = vim.fn.stridx(node.commit["commit"]["message"], '\n')
    if new_line_idx ~= -1 then
        commit_title = vim.fn.strcharpart(commit_title, 0, new_line_idx)
    end

    detail = commit_title
    icon = config.icon_set["GitCommit"]

    return name, detail, icon
end

local function marshal_comment_node(node)
    local name, detail, icon = "", "", ""

    if node.comment["replyTo"] ~= vim.NIL then
        name = "reply by " .. node.comment["author"]["login"]
    else
        name = "comment by " .. node.comment["author"]["login"]
    end
    if node.comment["state"] == "PENDING" then
        icon = config.icon_set["Pencil"]
    else
        icon = config.icon_set["Comment"]
    end

    return name, detail, icon
end

local function marshal_pr_node(node)
    local name, detail, icon = "", "", ""

    name = string.format("#%d %s", node.pr["number"], node.pr["title"])
    icon = config.icon_set["GitPullRequest"]

    return name, detail, icon
end

local function check_notifications(node, name, detail, icon)
    if s.pull_state.notifications_by_id[node.key] ~= nil then
        return name, detail, config.icon_set["Notification"]
    else
        return name, detail, icon
    end
end

function M.marshal_pr_review_node(node)
    if node.review ~= nil then
        return marshal_review_node(node)
    end

    if node.requested_review ~= nil then
        return marshal_requested_review_node(node)
    end

    if node.thread ~= nil then
        return marshal_thread_node(node)
    end

    if node.comment ~= nil then
        return marshal_comment_node(node)
    end
end

function M.marshal_pr_node(node)
    if node.pr ~= nil then
        return check_notifications(node, marshal_pr_node(node))
    end

    if node.commit ~= nil then
        return check_notifications(node, marshal_commit_node(node))
    end

    if node.thread ~= nil then
        return check_notifications(node, marshal_thread_node(node))
    end

    if node.comment ~= nil then
        return check_notifications(node, marshal_comment_node(node))
    end

    if node.issue_comment ~= nil then
        return check_notifications(node, marshal_issue_comment_node(node))
    end

    -- if a node has a generic "details" field, its just an informative element
    -- with no further functionality.
    if node.details ~= nil then
        return check_notifications(node, marshal_details_node(node))
    end

    if node.review ~= nil then
        return check_notifications(node, marshal_review_node(node))
    end

    if node.requested_review ~= nil then
        return check_notifications(node, marshal_requested_review_node(node))
    end

    -- action_required, cancelled, failure, neutral, success, skipped, stale, timed_out
    if node.check ~= nil then
        return check_notifications(node, marshal_check_node(node))
    end

    if node.file ~= nil then
        return check_notifications(node, marshal_file_node(node))
    end
end

function M.marshal_pr_file_node(node)
    if node.commit ~= nil then
        return check_notifications(node, marshal_commit_node(node))
    end

    if node.file ~= nil then
        return check_notifications(node, marshal_file_node(node))
    end

    if node.thread ~= nil then
        return check_notifications(node, marshal_thread_node(node))
    end

    if node.comment ~= nil then
        return check_notifications(node, marshal_comment_node(node))
    end

    if node.review ~= nil then
        return check_notifications(node, marshal_review_node(node))
    end
end

return M
