local lib_path = require('litee.lib.util.path')
local config   = require('litee.gh.config')

local lib_tree_node = require('litee.lib.tree.node')

local M = {}

function M.build_files_changed_tree(files, depth, prev_tree)
    local prev_root = nil
    if prev_tree ~= nil and prev_tree.depth_table[depth] ~= nil then
        for _, prev_node in ipairs(prev_tree.depth_table[depth]) do
            if prev_node.key == "Details:" then
                prev_root = prev_node
            end
        end
    end

    local root = lib_tree_node.new_node(
        "Files changed:",
        "Files changed:",
        depth -- we a subtree of root
    )
    root.details = {
        name = root.name,
        detail = "",
        icon = ""
    }

    root.expanded = true
    if prev_root ~= nil then
        root.expanded = prev_root.expanded
    end

    local function recursive_search(path, r)
        if r.key == path then
            return r
        else
            for _, c in ipairs(r.children) do
                local n = recursive_search(path, c)
                if n ~= nil then
                    return n
                end
            end
        end
        return nil
    end

    local function recursive_mkdir(path)
        if path == "" or path == "/" then
            return root
        end

        local n = recursive_mkdir(lib_path.parent_dir(path))

        local nn = recursive_search(path, root)

        -- directory node for path exists, return it
        if nn ~= nil then
            return nn
        end

        -- create directory node, add it to parent's children, and return it
        local dir = lib_tree_node.new_node(
            path,
            path,
            n.depth + 1
        )
        dir.details = {
            name = lib_path.basename(path),
            detail = "",
            icon = config.icon_set["Folder"]
        }
        if dir.depth == 2 then
            dir.expanded = false
        else
            dir.expanded = true
        end
        if prev_tree.depth_table[n.depth+1] ~= nil then
            for _, prev in ipairs(prev_tree.depth_table[n.depth+1]) do
                if prev.key == dir.key then
                    dir.expanded = prev.expanded
                end
            end
        end

        table.insert(n.children, dir)

        return dir
    end

    for p, file in pairs(files) do
        local dir = lib_path.parent_dir(file["filename"])
        local dir_node = recursive_mkdir(dir)

        local child_node = lib_tree_node.new_node(
            file["filename"],
            file["filename"],
            dir_node.depth+1
        )
        child_node.file = file
        child_node.expanded = true
        child_node.url = file["blob_url"]
        table.insert(dir_node.children, child_node)
    end

    return root
end

return M
