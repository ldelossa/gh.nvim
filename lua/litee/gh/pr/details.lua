local lib_tree_node = require('litee.lib.tree.node')
local lib_icons     = require('litee.lib.icons')

local config        = require('litee.gh.config').config

local M = {}

local icon_set = {}
if config.icon_set ~= nil then
    icon_set = lib_icons[config.icon_set]
end

local symbols = {
    top =    "╭",
    left =   "│",
    bottom = "╰",
    tab = "  ",
    author =  icon_set["Account"]
}

local function parse_comment(author, body, left_sign, bottom_sign)
    local lines = {}
    if author ~= nil then
        table.insert(lines, string.format("%s %s  %s", symbols.top, symbols.author, author))
    end
    body = vim.fn.split(body, '\n')
    for _, line in ipairs(body) do
        line = vim.fn.substitute(line, "\r", "", "g")
        line = vim.fn.substitute(line, "\n", "", "g")
        line = vim.fn.substitute(line, "\t", symbols.tab, "g")
        if left_sign then
            line = symbols.left .. line
        end
        table.insert(lines, line)
    end
    if bottom_sign then
        table.insert(lines, symbols.bottom)
    end
    return lines
end

function M.details_func(_, node)
    if node.pr ~= nil then
        local lines = {}
        local author = node.pr["user"]["login"]

        local title  = parse_comment(nil, node.pr["title"], true, false)
        for _, l in ipairs(title) do
            table.insert(lines, l)
        end

        table.insert(lines, "")
        table.insert(lines, string.format("%s #%d", symbols.left, node.pr["number"]))
        table.insert(lines, "")

        local body  = parse_comment(author, node.pr["body"], true, true)
        for _, l in ipairs(body) do
            table.insert(lines, l)
        end

        return lines
    end
    if node.commit ~= nil then
        local author = "unknown"
        if node.commit["author"] ~= vim.NIL then
             author = node.commit["author"]["login"]
        elseif
            node.commit["commit"] ~= nil and
            node.commit["commit"]["author"] ~= nil then
            if node.commit["commit"]["author"]["name"] ~= nil then
                author = node.commit["commit"]["author"]["name"]
            elseif node.commit["commit"]["author"]["email"] ~= nil then
                author = node.commit["commit"]["author"]["email"]
            end
        end

        local message = parse_comment(author, node.commit.commit["message"], true, true)
        return message
    end
    if node.review ~= nil then
        local author = node.review["user"]["login"]
        local body = parse_comment(author, node.review["body"], true, true)
        return body
    end
    if node.comment ~= nil then
        local author = node.comment["author"]["login"]
        local body = parse_comment(author, node.comment["body"], true, true)
        return body
    end
end

-- build_details_tree builds a sub-tree of pr details.
--
-- @return node (table) the root node of the details sub-tree with children
-- attached.
function M.build_details_tree(pull, depth, prev_tree)
    local prev_root = nil
    if prev_tree ~= nil and prev_tree.depth_table[depth] ~= nil then
        for _, prev_node in ipairs(prev_tree.depth_table[depth]) do
            if prev_node.key == "Details:" then
                prev_root = prev_node
            end
        end
    end

    local root = lib_tree_node.new_node(
        "Details:",
        "Details:",
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

    local number = lib_tree_node.new_node(
        "number:",
        "number:",
        depth+1 -- we are a child to the root details node created above, selfsame for all following.
    )
    number.details = {
        name = number.name,
        detail = string.format("%d", pull["number"]),
        icon = icon_set["Number"]
    }
    number.expanded = true

    local state = lib_tree_node.new_node(
        "state:",
        "state:",
        depth+1 -- we are a child to the root details node created above, selfsame for all following.
    )
    state.details = {
        name = state.name,
        detail = pull["state"],
        icon = icon_set["Info"]
    }
    state.expanded = true

    local author = lib_tree_node.new_node(
        "author:",
        "author:",
        depth+1 -- we are a child to the root details node created above, selfsame for all following.
    )
    author.details = {
        name = author.name,
        detail = pull["user"]["login"],
        icon = icon_set["Account"]
    }
    author.expanded = true

    local base = lib_tree_node.new_node(
        "base:",
        "base:",
        depth+1 -- we are a child to the root details node created above, selfsame for all following.
    )
    base.details = {
        name = base.name,
        detail = pull["base"]["label"],
        icon = icon_set["GitBranch"]
    }
    base.expanded = true

    local head = lib_tree_node.new_node(
        "head:",
        "head:",
        depth+1 -- we are a child to the root details node created above, selfsame for all following.
    )
    head.details = {
        name = head.name,
        detail = pull["head"]["label"],
        icon = icon_set["GitBranch"]
    }
    head.expanded = true

    local repo = lib_tree_node.new_node(
        "repo:",
        "repo:",
        depth+1 -- we are a child to the root details node created above, selfsame for all following.
    )
    repo.details = {
        name = repo.name,
        detail = pull["base"]["repo"]["full_name"],
        icon = icon_set["GitRepo"]
    }
    repo.expanded = true

    local labels = lib_tree_node.new_node(
        "labels:",
        "labels",
        depth+1 -- we are a child to the root details node created above, selfsame for all following.
    )
    labels.details = {
        name = labels.name,
        detail = "",
        icon = icon_set["Bookmark"]
    }
    labels.expanded = true
    for _, label in ipairs(pull["labels"]) do
        local l_node = lib_tree_node.new_node(
            label["name"],
            label["id"],
            depth+2 -- we are a child to the root details node created above, selfsame for all following.
        )
        l_node.label = label
        l_node.details = {
            name = l_node.name,
            detail = "",
            icon = icon_set["Bookmark"]
        }
        l_node.expanded = true
        table.insert(labels.children, l_node)
    end

    local assignees = lib_tree_node.new_node(
        "assignees:",
        "assignees",
        depth+1 -- we are a child to the root details node created above, selfsame for all following.
    )
    assignees.details = {
        name = assignees.name,
        detail = "",
        icon = ""
    }
    assignees.expanded = true
    for _, assignee in ipairs(pull["assignees"]) do
        local a_node = lib_tree_node.new_node(
            assignee["login"],
            "assignees:" .. assignee["login"],
            depth+2 -- we are a child to the root details node created above, selfsame for all following.
        )
        a_node.assignee = a_node
        a_node.details = {
            name = a_node.name,
            detail = "",
            icon = icon_set["Account"]
        }
        a_node.expanded = true
        table.insert(assignees.children, a_node)
    end

    -- add all our details children
    local children = {
        number,
        author,
        state,
        repo,
        base,
        head,
    }
    if #labels.children > 0 then
        table.insert(children, labels)
    end
    if #assignees.children > 0 then
        table.insert(children, assignees)
    end

    root.children = children
    return root
end

return M
