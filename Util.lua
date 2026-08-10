local ADDON_NAME, WP = ...

WP.VERSION = "0.1.0"

-- 64-character alphabet used for compact wire encoding. Every character is
-- safe inside an addon message payload (printable ASCII, no "|", no ":",
-- no control characters).
local ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz+/"

local VAL_TO_CHAR = {}
local CHAR_TO_VAL = {}
for i = 1, #ALPHABET do
    local c = ALPHABET:sub(i, i)
    VAL_TO_CHAR[i - 1] = c
    CHAR_TO_VAL[c] = i - 1
end

-- Encode an integer 0..63 as a single character. Returns nil out of range.
function WP.EncodeChar(n)
    return VAL_TO_CHAR[n]
end

-- Decode a single character back to 0..63. Returns nil for unknown chars.
function WP.DecodeChar(c)
    return CHAR_TO_VAL[c]
end

-- Bresenham line walk from (x0, y0) to (x1, y1) inclusive, calling fn(x, y)
-- for every cell. Used to fill the gaps a fast mouse drag leaves between
-- consecutive OnUpdate samples.
function WP.ForLine(x0, y0, x1, y1, fn)
    local dx = math.abs(x1 - x0)
    local dy = -math.abs(y1 - y0)
    local sx = x0 < x1 and 1 or -1
    local sy = y0 < y1 and 1 or -1
    local err = dx + dy
    while true do
        fn(x0, y0)
        if x0 == x1 and y0 == y1 then
            break
        end
        local e2 = 2 * err
        if e2 >= dy then
            err = err + dy
            x0 = x0 + sx
        end
        if e2 <= dx then
            err = err + dx
            y0 = y0 + sy
        end
    end
end

function WP.PlayerFullName()
    if not WP.playerFullName then
        local name, realm = UnitFullName("player")
        if not realm or realm == "" then
            realm = GetNormalizedRealmName and GetNormalizedRealmName() or nil
        end
        if name then
            WP.playerFullName = realm and (name .. "-" .. realm) or name
        end
    end
    return WP.playerFullName
end

-- True if an addon message sender is this player. CHAT_MSG_ADDON senders may
-- arrive with or without a realm suffix depending on realm configuration.
function WP.IsSelf(sender)
    if not sender or sender == "" then
        return false
    end
    if Ambiguate(sender, "short") ~= UnitName("player") then
        return false
    end
    if sender:find("-", 1, true) then
        local full = WP.PlayerFullName()
        return full ~= nil and sender == full
    end
    return true
end
