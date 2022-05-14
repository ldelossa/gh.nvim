local lib_icons = require('litee.lib.icons')
local config = require('litee.gh.config').config
local s = require('litee.gh.pr.state')
local lib_path = require('litee.lib.util.path')

local M = {}

function M.marshal_pr_review_node(node)
    local icon_set = "default"
    if config.icon_set ~= nil then
        icon_set = lib_icons[config.icon_set]
    end

    local name, detail, icon = "", "", ""

    if node.review ~= nil then
        name = string.format("%s", node.review["user"]["login"])
        if node.review["state"] == 'APPROVED' then
            name  = name .. " (approved)"
            icon = icon_set["PassFilled"]
        elseif node.review["state"] == 'PENDING' then
            name  = name .. " (pending)"
            icon = icon_set["Pencil"]
        else
            name  = name .. " (changes required)"
            icon = icon_set["RequestChanges"]
        end
    end

    if node.requested_review ~= nil then
        local n = node.requested_review["login"]
        if n == nil then
            n = node.requested_review["slug"]
        end
        name = string.format("%s (requested)", n)
        icon = icon_set["CircleFilled"]
    end

    if node.thread ~= nil then
        local line = nil
        if node.thread["originalLine"] ~= vim.NIL then
            line = node.thread["originalLine"]
        end
        if node.thread["line"] ~= vim.NIL then
            line = node.thread["line"]
        end

        name = string.format("%s:%d", node.thread["path"], line)

        if node.thread["isResolved"] then
            icon = icon_set["CheckAll"]
        else
            icon = icon_set["MultiComment"]
        end

        local count = #node["children"]
        detail = string.format("%d", count)
    end

    if node.comment ~= nil then
        if node.comment["replyTo"] ~= vim.NIL then
            name = "reply by " .. node.comment["author"]["login"]
        else
            name = "comment by " .. node.comment["author"]["login"]
        end
        if node.comment["state"] == "PENDING" then
            icon = icon_set["Pencil"]
        else
            icon = icon_set["Comment"]
        end
    end

    return name, detail, icon
end

function M.marshal_pr_commit_node(node)
    local icon_set = "default"
    if config.icon_set ~= nil then
        icon_set = lib_icons[config.icon_set]
    end

    local name, detail, icon = "", "", ""
    if node.pr ~= nil then
        name = string.format("#%d %s", node.pr["number"], node.pr["title"])
        icon = icon_set["GitPullRequest"]
    end

    if node.commit ~= nil then
        name = vim.fn.strcharpart(node.commit["sha"], 0, 8)

        local commit_title = node.commit["commit"]["message"]
        local new_line_idx = vim.fn.stridx(node.commit["commit"]["message"], '\n')
        if new_line_idx ~= -1 then
            commit_title = vim.fn.strcharpart(commit_title, 0, new_line_idx)
        end

        detail = commit_title
        icon = icon_set["GitCommit"]
    end

    if node.thread ~= nil then
        local count = #node["children"]

        local line = nil
        if node.thread["originalLine"] ~= vim.NIL then
            line = node.thread["originalLine"]
        end
        if node.thread["line"] ~= vim.NIL then
            line = node.thread["line"]
        end

        if node.thread["isResolved"] then
            icon = icon_set["CheckAll"]
        else
            icon = icon_set["MultiComment"]
        end

        name = string.format("%s:%d", node.thread["path"], line)
        detail = string.format("%d", count)
    end

    if node.comment ~= nil then
        if node.comment["replyTo"] ~= vim.NIL then
            name = "reply by " .. node.comment["author"]["login"]
        else
            name = "comment by " .. node.comment["author"]["login"]
        end
        if node.comment["state"] == "PENDING" then
            icon = icon_set["Pencil"]
        else
            icon = icon_set["Comment"]
        end
    end

    if node.issue_comment ~= nil then
        name = "pr comment by " .. node.issue_comment["user"]["login"]
        icon = icon_set["Comment"]
    end

    -- if a node has a generic "details" field, its just an informative element
    -- with no further functionality.
    if node.details ~= nil then
        name = node.details["name"]
        detail = node.details["detail"]
        icon = node.details["icon"]
    end

    if node.review ~= nil then
        name = string.format("%s", node.review["user"]["login"])
        if node.review["state"] == 'APPROVED' then
            name  = name .. " (approved)"
            icon = icon_set["PassFilled"]
        elseif node.review["state"] == 'PENDING' then
            name  = name .. " (pending)"
            icon = icon_set["Pencil"]
        else
            name  = name .. " (changes required)"
            icon = icon_set["RequestChanges"]
        end
    end

    if node.requested_review ~= nil then
        local n = node.requested_review["login"]
        if n == nil or n == vim.NIL then
            n = node.requested_review["slug"]
        end
        name = string.format("%s (requested)", n)
        icon = icon_set["CircleFilled"]
    end

    -- action_required, cancelled, failure, neutral, success, skipped, stale, timed_out
    if node.check ~= nil then
        name = node.check["name"]
        if node.check["conclusion"] ~= vim.NIL then
            detail = node.check["conclusion"]
        end
        if node.check["conclusion"] == "success" then
            icon = icon_set["PassFilled"]
        elseif node.check["conclusion"] == "failure" then
            icon = icon_set["CircleStop"]
        else
            icon = icon_set["Info"]
        end
    end

    if node.file ~= nil then
        name = lib_path.basename(node.file["filename"])
        if node.file["state"] ~= vim.NIL then
            detail = node.file["status"]
        end
        icon = icon_set["File"]
    end

    -- if there's a notification for this id, swap the icon out with notification
    -- icons.
    if s.pull_state.notifications_by_id[node.name] ~= nil then
        icon = icon_set["Notification"]
    end

    return name, detail, icon
end

function M.marshal_pr_file_node(node)
    local icon_set = "default"
    if config.icon_set ~= nil then
        icon_set = lib_icons[config.icon_set]
    end

    local name, detail, icon = "", "", ""
    if node.commit ~= nil then
        return M.marshal_pr_commit_node(node)
    end

    if node.file ~= nil then
        name = node.file["filename"]
        detail = node.file["status"]
        icon = icon_set["File"]
    end

    if node.thread ~= nil then
        local count = #node["children"]

        local line = nil
        if node.thread["originalLine"] ~= vim.NIL then
            line = node.thread["originalLine"]
        end
        if node.thread["line"] ~= vim.NIL then
            line = node.thread["line"]
        end

        if node.thread["isResolved"] then
            icon = icon_set["CheckAll"]
        else
            icon = icon_set["MultiComment"]
        end

        name = string.format("%s:%d", node.thread["path"], line)
        detail = string.format("%d", count)
    end

    if node.comment ~= nil then
        if node.comment["in_reply_to_id"] ~= nil then
            name = "reply by " .. node.comment["author"]["login"]
        else
            name = "comment by " .. node.comment["author"]["login"]
        end
        if node.comment["state"] == "PENDING" then
            icon = icon_set["Pencil"]
        else
            icon = icon_set["Comment"]
        end
    end

    if node.review ~= nil then
        name = string.format("%s", node.review["user"]["login"])
        if node.review["state"] == 'APPROVED' then
            name  = name .. " (approved)"
            icon = icon_set["PassFilled"]
        elseif node.review["state"] == 'PENDING' then
            name  = name .. " (pending)"
            icon = icon_set["Pencil"]
        else
            name  = name .. " (changes required)"
            icon = icon_set["RequestChanges"]
        end
    end

    -- if there's a notification for this id, swap the icon out with notification
    -- icons.
    if s.pull_state.notifications_by_id[node.name] ~= nil then
        icon = icon_set["Notification"]
    end

    return name, detail, icon
end

return M
