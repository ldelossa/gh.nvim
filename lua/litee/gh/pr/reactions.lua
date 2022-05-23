local M = {}

M.reaction_map = {
  ["THUMBS_UP"] = "👍",
  ["THUMBS_DOWN"] = "👎",
  ["LAUGH"] = "😀",
  ["HOORAY"] = "🎉",
  ["CONFUSED"] = "😕",
  ["HEART"] = "😍",
  ["ROCKET"] = "🚀",
  ["EYES"] = "👀",
}

function M.reaction_lookup(text)
    if text == "+1" then
        return M.reaction_map["THUMBS_UP"]
    end
    if text == "-1" then
        return M.reaction_map["THUMBS_DOWN"]
    end
    return M.reaction_map[string.upper(text)]
end

M.reaction_names = {
  "THUMBS_UP" ,
  "THUMBS_DOWN",
  "LAUGH" ,
  "HOORAY" ,
  "CONFUSED" ,
  "HEART",
  "ROCKET",
  "EYES" ,
}

return M
