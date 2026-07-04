----------------------------------------------------------------------
-- util.lua
-- Generic, stateless helpers with no game/engine state of their own.
-- Required by nearly every other module.
----------------------------------------------------------------------
local M = {}

-- Safe GUI messenger: never throws if the target url is nil/dead.
function M.notify_gui(target_url, message_id, message_data)
    if target_url then
        pcall(function() msg.post(target_url, message_id, message_data) end)
    end
end

function M.log(text)
    print("Whot Game: " .. tostring(text))
end

function M.rand_range(a, b)
    return a + math.random() * (b - a)
end

function M.index_of(list, rec)
    for i, c in ipairs(list) do if c == rec then return i end end
    return nil
end

function M.remove_from_hand(hand, rec)
    local i = M.index_of(hand, rec)
    if i then table.remove(hand, i) end
end

return M
