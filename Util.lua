local ADDON_NAME, PP = ...

PP.VERSION = "0.7.0"

-- True when a peer's announced version string is at least major.minor.
-- Absent or malformed versions read as older: peers that never say their
-- version are the oldest of all.
function PP.VersionAtLeast(v, major, minor)
    if type(v) ~= "string" then
        return false
    end
    local maj, min = v:match("^(%d+)%.(%d+)")
    if not maj then
        return false
    end
    maj, min = tonumber(maj), tonumber(min)
    return maj > major or (maj == major and min >= minor)
end

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
function PP.EncodeChar(n)
    return VAL_TO_CHAR[n]
end

-- Decode a single character back to 0..63. Returns nil for unknown chars.
function PP.DecodeChar(c)
    return CHAR_TO_VAL[c]
end

-- Bresenham line walk from (x0, y0) to (x1, y1) inclusive, calling fn(x, y)
-- for every cell. Used to fill the gaps a fast mouse drag leaves between
-- consecutive OnUpdate samples.
function PP.ForLine(x0, y0, x1, y1, fn)
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

-- Rectangle spanning two opposite corners, outline unless `filled`.
function PP.ForRect(x0, y0, x1, y1, filled, fn)
    local xa, xb = math.min(x0, x1), math.max(x0, x1)
    local ya, yb = math.min(y0, y1), math.max(y0, y1)
    for y = ya, yb do
        for x = xa, xb do
            if filled or x == xa or x == xb or y == ya or y == yb then
                fn(x, y)
            end
        end
    end
end

-- Ellipse inscribed in the box spanning two corners. Cell-centre membership
-- test rather than a midpoint walk: at 64x64 the box is small enough that
-- scanning it is free, and testing 4-neighbours for the outline gives a
-- closed, 4-connected edge at every aspect ratio (midpoint variants leak at
-- shallow slopes).
function PP.ForEllipse(x0, y0, x1, y1, filled, fn)
    local xa, xb = math.min(x0, x1), math.max(x0, x1)
    local ya, yb = math.min(y0, y1), math.max(y0, y1)
    local cx, cy = (xa + xb) / 2, (ya + yb) / 2
    local rx, ry = (xb - xa) / 2 + 0.5, (yb - ya) / 2 + 0.5
    local function inside(x, y)
        local dx, dy = (x - cx) / rx, (y - cy) / ry
        return dx * dx + dy * dy <= 1
    end
    for y = ya, yb do
        for x = xa, xb do
            if inside(x, y) then
                if filled or not (inside(x - 1, y) and inside(x + 1, y)
                    and inside(x, y - 1) and inside(x, y + 1)) then
                    fn(x, y)
                end
            end
        end
    end
end

----------------------------------------------------------------------
-- Paint op codec
--
-- A coordinate fits in one alphabet character up to 64, which is why the
-- original canvas is that size. Larger canvases spend two characters per
-- axis (12 bits, up to 4096), so ops are 5 characters instead of 3. Small
-- canvases keep the original 3-char encoding byte for byte, which is what
-- lets the Shared canvas stay readable by every version of the addon.
----------------------------------------------------------------------

function PP.OpWidth(size)
    return size <= 64 and 3 or 5
end

function PP.EncodeOp(size, x, y, color)
    if size <= 64 then
        return PP.EncodeChar(x - 1) .. PP.EncodeChar(y - 1) .. PP.EncodeChar(color)
    end
    local px, py = x - 1, y - 1
    return PP.EncodeChar(math.floor(px / 64)) .. PP.EncodeChar(px % 64)
        .. PP.EncodeChar(math.floor(py / 64)) .. PP.EncodeChar(py % 64)
        .. PP.EncodeChar(color)
end

-- Decode the op starting at position i. Returns 1-based x, y and the colour,
-- or nil for anything malformed. Input is untrusted.
function PP.DecodeOp(size, ops, i)
    if size <= 64 then
        local x = PP.DecodeChar(ops:sub(i, i))
        local y = PP.DecodeChar(ops:sub(i + 1, i + 1))
        local c = PP.DecodeChar(ops:sub(i + 2, i + 2))
        if not x or not y or not c then
            return nil
        end
        return x + 1, y + 1, c
    end
    local xh = PP.DecodeChar(ops:sub(i, i))
    local xl = PP.DecodeChar(ops:sub(i + 1, i + 1))
    local yh = PP.DecodeChar(ops:sub(i + 2, i + 2))
    local yl = PP.DecodeChar(ops:sub(i + 3, i + 3))
    local c = PP.DecodeChar(ops:sub(i + 4, i + 4))
    if not xh or not xl or not yh or not yl or not c then
        return nil
    end
    return xh * 64 + xl + 1, yh * 64 + yl + 1, c
end

----------------------------------------------------------------------
-- Viewport: which slice of a canvas the fixed grid of textures shows
--
-- Screen textures are allocated per *visible* cell, never per canvas cell,
-- so a bigger canvas costs nothing extra to render until you zoom out far
-- enough to see more of it at once. All of this is pure arithmetic and is
-- covered by the desktop suite; the UI only feeds it numbers.
----------------------------------------------------------------------

PP.ZOOMS = { 4, 8, 16, 32 } -- screen pixels per cell, ascending
PP.VIEW_PX = 512            -- edge of the square canvas widget

-- How many cells fit across the viewport at this zoom, never more than the
-- canvas has.
function PP.VisibleCells(size, zoom, viewPx)
    local fit = math.floor((viewPx or PP.VIEW_PX) / zoom)
    return math.min(size, math.max(1, fit))
end

-- The most zoomed-out level worth offering: the largest zoom at which the
-- whole canvas still fits. Zooming out past that only shrinks the picture
-- inside a fixed widget, so there is nothing to gain.
function PP.FitZoom(size, viewPx)
    viewPx = viewPx or PP.VIEW_PX
    local best = PP.ZOOMS[1]
    for _, z in ipairs(PP.ZOOMS) do
        if size * z <= viewPx then
            best = z
        end
    end
    return best
end

-- Zoom levels offered for a canvas of this size: fit level and inwards.
function PP.ZoomList(size, viewPx)
    local fit = PP.FitZoom(size, viewPx)
    local list = {}
    for _, z in ipairs(PP.ZOOMS) do
        if z >= fit then
            list[#list + 1] = z
        end
    end
    return list
end

-- Keep the top-left visible cell inside the canvas.
function PP.ClampPan(size, visible, pan)
    local maxPan = math.max(1, size - visible + 1)
    return math.min(math.max(1, math.floor(pan or 1)), maxPan)
end

-- Viewport slot (1-based col,row) -> canvas cell.
function PP.ViewToCanvas(panX, panY, col, row)
    return panX + col - 1, panY + row - 1
end

-- Canvas cell -> viewport slot, or nil when it is scrolled out of sight.
function PP.CanvasToView(panX, panY, visible, x, y)
    local col, row = x - panX + 1, y - panY + 1
    if col < 1 or col > visible or row < 1 or row > visible then
        return nil
    end
    return col, row
end

function PP.PlayerFullName()
    if not PP.playerFullName then
        local name, realm = UnitFullName("player")
        if not realm or realm == "" then
            realm = GetNormalizedRealmName and GetNormalizedRealmName() or nil
        end
        if name then
            PP.playerFullName = realm and (name .. "-" .. realm) or name
        end
    end
    return PP.playerFullName
end

-- Names on the wire and in rosters are always Name-Realm. Senders and typed
-- names may arrive bare (same realm); normalize by appending our own realm.
function PP.NormalizeName(name)
    if type(name) ~= "string" or name == "" then
        return nil
    end
    if name:find("-", 1, true) then
        return name
    end
    local realm = GetNormalizedRealmName and GetNormalizedRealmName() or nil
    return realm and (name .. "-" .. realm) or name
end

-- True if an addon message sender is this player. CHAT_MSG_ADDON senders may
-- arrive with or without a realm suffix depending on realm configuration.
function PP.IsSelf(sender)
    if not sender or sender == "" then
        return false
    end
    if Ambiguate(sender, "short") ~= UnitName("player") then
        return false
    end
    if sender:find("-", 1, true) then
        local full = PP.PlayerFullName()
        return full ~= nil and sender == full
    end
    return true
end
