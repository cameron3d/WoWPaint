local ADDON_NAME, PP = ...

local Canvas = {}
PP.Canvas = Canvas

-- Canvases are square and come in a fixed set of sizes. 64 is the original
-- and the only size the built-in Shared canvas ever takes, which is what
-- keeps it wire-compatible with every version of the addon.
Canvas.DEFAULT_SIZE = 64
Canvas.SIZES = { 64, 128 }
Canvas.MAX_SIZE = 128
-- 64 colors: one alphabet character on the wire, in ops and snapshots alike.
-- This is the ceiling — a 65th color would change the wire format.
Canvas.NUM_COLORS = 64
-- Indices below this are the classic 16 shown on the palette row; the rest
-- are the color wheel's. Clients before 0.7 only accept colors below it.
Canvas.EXTENDED_BASE = 16
Canvas.WHEEL_HUES = 12   -- spokes, 30 degrees apart, red first
Canvas.WHEEL_SHADES = 4  -- rings per spoke, pale to dark

-- Size is the first argument of every function here, and it is required.
-- A call site that forgets it raises rather than quietly treating a 128
-- canvas as a 64 one, which would corrupt coordinates instead of erroring.

-- Palette indices are wire format and SavedVariables format: once a version
-- ships, the color an index names must never change, only new indices may
-- be added (and 64 is full).
--
-- 0-15: classic r/place (2017) palette. Index 0 is the background and
-- doubles as the eraser color.
Canvas.PALETTE = {
    [0]  = { 1.000, 1.000, 1.000 }, -- white
    [1]  = { 0.894, 0.894, 0.894 }, -- light gray
    [2]  = { 0.533, 0.533, 0.533 }, -- gray
    [3]  = { 0.133, 0.133, 0.133 }, -- black
    [4]  = { 1.000, 0.655, 0.820 }, -- pink
    [5]  = { 0.898, 0.000, 0.000 }, -- red
    [6]  = { 0.898, 0.584, 0.000 }, -- orange
    [7]  = { 0.627, 0.416, 0.259 }, -- brown
    [8]  = { 0.898, 0.851, 0.000 }, -- yellow
    [9]  = { 0.580, 0.878, 0.267 }, -- light green
    [10] = { 0.008, 0.745, 0.004 }, -- green
    [11] = { 0.000, 0.827, 0.867 }, -- cyan
    [12] = { 0.000, 0.514, 0.780 }, -- light blue
    [13] = { 0.000, 0.000, 0.918 }, -- blue
    [14] = { 0.812, 0.431, 0.894 }, -- magenta
    [15] = { 0.510, 0.000, 0.502 }, -- purple
}

-- Standard HSV -> RGB. h in degrees (any value, wrapped), s and v in 0..1.
function Canvas.HSVToRGB(h, s, v)
    local c = v * s
    local hp = (h % 360) / 60
    local x = c * (1 - math.abs(hp % 2 - 1))
    local r, g, b
    if hp < 1 then
        r, g, b = c, x, 0
    elseif hp < 2 then
        r, g, b = x, c, 0
    elseif hp < 3 then
        r, g, b = 0, c, x
    elseif hp < 4 then
        r, g, b = 0, x, c
    elseif hp < 5 then
        r, g, b = x, 0, c
    else
        r, g, b = c, 0, x
    end
    local m = v - c
    return r + m, g + m, b + m
end

-- The wheel's shade rings, innermost first: pale, vivid, deep, dark.
Canvas.WHEEL_SHADE_SV = {
    { 0.38, 1.00 },
    { 1.00, 1.00 },
    { 1.00, 0.68 },
    { 1.00, 0.40 },
}

-- 16-63: the color wheel, generated so the palette and the wheel layout can
-- never disagree. Index = EXTENDED_BASE + hue * WHEEL_SHADES + shade, with
-- hue 0-11 stepping 30 degrees from red and shade 0-3 pale to dark. The
-- desktop suite pins spot values: changing the generator reshuffles published
-- indices and breaks every existing canvas, so it must never happen.
for hue = 0, Canvas.WHEEL_HUES - 1 do
    for shade = 0, Canvas.WHEEL_SHADES - 1 do
        local sv = Canvas.WHEEL_SHADE_SV[shade + 1]
        local r, g, b = Canvas.HSVToRGB(hue * 30, sv[1], sv[2])
        Canvas.PALETTE[Canvas.EXTENDED_BASE + hue * Canvas.WHEEL_SHADES + shade] = { r, g, b }
    end
end

-- True if any cell uses a wheel color. Pre-0.7 clients cannot decode a
-- snapshot of such a canvas; Comm uses this to warn rather than let them
-- silently fail to sync.
function Canvas.HasExtendedColors(size, cells)
    for i = 1, Canvas.Cells(size) do
        local v = cells[i]
        if v and v >= Canvas.EXTENDED_BASE then
            return true
        end
    end
    return false
end

function Canvas.ValidSize(size)
    for _, s in ipairs(Canvas.SIZES) do
        if size == s then
            return true
        end
    end
    return false
end

function Canvas.Cells(size)
    return size * size
end

function Canvas.New(size)
    local cells = {}
    for i = 1, Canvas.Cells(size) do
        cells[i] = 0
    end
    return cells
end

-- Flat-array index for a 1-based (x, y) cell coordinate.
function Canvas.Index(size, x, y)
    return (y - 1) * size + x
end

-- Inverse of Index: flat array position back to 1-based (x, y).
function Canvas.Coords(size, i)
    return (i - 1) % size + 1, math.floor((i - 1) / size) + 1
end

-- Set one pixel. Returns true if the cell actually changed.
function Canvas.SetPixel(size, cells, x, y, color)
    if x < 1 or x > size or y < 1 or y > size then
        return false
    end
    if color < 0 or color >= Canvas.NUM_COLORS then
        return false
    end
    local i = Canvas.Index(size, x, y)
    if cells[i] == color then
        return false
    end
    cells[i] = color
    return true
end

function Canvas.GetPixel(size, cells, x, y)
    return cells[Canvas.Index(size, x, y)]
end

function Canvas.Clear(size, cells)
    for i = 1, Canvas.Cells(size) do
        cells[i] = 0
    end
end

-- Run-length encode the whole canvas as pairs of characters:
-- (run length - 1, color), each drawn from the 64-char alphabet. Runs are
-- capped at 64 cells so both values fit in one character.
function Canvas.Serialize(size, cells)
    local out = {}
    local n = Canvas.Cells(size)
    local i = 1
    while i <= n do
        local c = cells[i]
        local run = 1
        while run < 64 and i + run <= n and cells[i + run] == c do
            run = run + 1
        end
        out[#out + 1] = PP.EncodeChar(run - 1)
        out[#out + 1] = PP.EncodeChar(c)
        i = i + run
    end
    return table.concat(out)
end

-- Decode an RLE snapshot back into a fresh cells array. Returns nil if the
-- payload is malformed (wrong length, unknown characters, bad color index,
-- or a cell count that does not match the canvas). Input is untrusted, and
-- the expected size is the caller's, not the sender's.
function Canvas.Deserialize(size, data)
    if type(data) ~= "string" or #data == 0 or #data % 2 ~= 0 then
        return nil
    end
    local total = Canvas.Cells(size)
    local cells = {}
    local pos = 0
    for i = 1, #data, 2 do
        local run = PP.DecodeChar(data:sub(i, i))
        local color = PP.DecodeChar(data:sub(i + 1, i + 1))
        if not run or not color or color >= Canvas.NUM_COLORS then
            return nil
        end
        if pos + run + 1 > total then
            return nil
        end
        for _ = 1, run + 1 do
            pos = pos + 1
            cells[pos] = color
        end
    end
    if pos ~= total then
        return nil
    end
    return cells
end

-- 4-connected flood fill of the region matching the colour under (x, y).
-- Calls fn(x, y) for each cell of the region and returns how many there
-- were. Purely a read: the caller decides what to paint, so filling cannot
-- disturb the traversal.
function Canvas.FloodFill(size, cells, x, y, fn)
    if x < 1 or x > size or y < 1 or y > size then
        return 0
    end
    local target = cells[Canvas.Index(size, x, y)]
    local seen, stack, n = {}, { x, y }, 0
    while #stack > 0 do
        local cy = table.remove(stack)
        local cx = table.remove(stack)
        local i = Canvas.Index(size, cx, cy)
        if not seen[i] and cells[i] == target then
            seen[i] = true
            n = n + 1
            fn(cx, cy)
            if cx > 1 then stack[#stack + 1] = cx - 1; stack[#stack + 1] = cy end
            if cx < size then stack[#stack + 1] = cx + 1; stack[#stack + 1] = cy end
            if cy > 1 then stack[#stack + 1] = cx; stack[#stack + 1] = cy - 1 end
            if cy < size then stack[#stack + 1] = cx; stack[#stack + 1] = cy + 1 end
        end
    end
    return n
end
