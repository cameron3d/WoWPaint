local ADDON_NAME, WP = ...

WP.VERSION = "0.4.1"

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

-- Rectangle spanning two opposite corners, outline unless `filled`.
function WP.ForRect(x0, y0, x1, y1, filled, fn)
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
function WP.ForEllipse(x0, y0, x1, y1, filled, fn)
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
-- Viewport: which slice of a canvas the fixed grid of textures shows
--
-- Screen textures are allocated per *visible* cell, never per canvas cell,
-- so a bigger canvas costs nothing extra to render until you zoom out far
-- enough to see more of it at once. All of this is pure arithmetic and is
-- covered by the desktop suite; the UI only feeds it numbers.
----------------------------------------------------------------------

WP.ZOOMS = { 4, 8, 16, 32 } -- screen pixels per cell, ascending
WP.VIEW_PX = 512            -- edge of the square canvas widget

-- How many cells fit across the viewport at this zoom, never more than the
-- canvas has.
function WP.VisibleCells(size, zoom, viewPx)
    local fit = math.floor((viewPx or WP.VIEW_PX) / zoom)
    return math.min(size, math.max(1, fit))
end

-- The most zoomed-out level worth offering: the largest zoom at which the
-- whole canvas still fits. Zooming out past that only shrinks the picture
-- inside a fixed widget, so there is nothing to gain.
function WP.FitZoom(size, viewPx)
    viewPx = viewPx or WP.VIEW_PX
    local best = WP.ZOOMS[1]
    for _, z in ipairs(WP.ZOOMS) do
        if size * z <= viewPx then
            best = z
        end
    end
    return best
end

-- Zoom levels offered for a canvas of this size: fit level and inwards.
function WP.ZoomList(size, viewPx)
    local fit = WP.FitZoom(size, viewPx)
    local list = {}
    for _, z in ipairs(WP.ZOOMS) do
        if z >= fit then
            list[#list + 1] = z
        end
    end
    return list
end

-- Keep the top-left visible cell inside the canvas.
function WP.ClampPan(size, visible, pan)
    local maxPan = math.max(1, size - visible + 1)
    return math.min(math.max(1, math.floor(pan or 1)), maxPan)
end

-- Viewport slot (1-based col,row) -> canvas cell.
function WP.ViewToCanvas(panX, panY, col, row)
    return panX + col - 1, panY + row - 1
end

-- Canvas cell -> viewport slot, or nil when it is scrolled out of sight.
function WP.CanvasToView(panX, panY, visible, x, y)
    local col, row = x - panX + 1, y - panY + 1
    if col < 1 or col > visible or row < 1 or row > visible then
        return nil
    end
    return col, row
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

-- Names on the wire and in rosters are always Name-Realm. Senders and typed
-- names may arrive bare (same realm); normalize by appending our own realm.
function WP.NormalizeName(name)
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
