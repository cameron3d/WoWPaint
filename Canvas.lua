local ADDON_NAME, WP = ...

local Canvas = {}
WP.Canvas = Canvas

Canvas.SIZE = 64
Canvas.NUM_CELLS = Canvas.SIZE * Canvas.SIZE
Canvas.NUM_COLORS = 16

-- Classic r/place (2017) palette. Index 0 is the background and doubles as
-- the eraser color.
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

-- Flat-array index for a 1-based (x, y) cell coordinate.
function Canvas.Index(x, y)
    return (y - 1) * Canvas.SIZE + x
end

-- Set one pixel. Returns true if the cell actually changed.
function Canvas.SetPixel(cells, x, y, color)
    if x < 1 or x > Canvas.SIZE or y < 1 or y > Canvas.SIZE then
        return false
    end
    if color < 0 or color >= Canvas.NUM_COLORS then
        return false
    end
    local i = Canvas.Index(x, y)
    if cells[i] == color then
        return false
    end
    cells[i] = color
    return true
end

function Canvas.GetPixel(cells, x, y)
    return cells[Canvas.Index(x, y)]
end

-- Inverse of Index: flat array position back to 1-based (x, y).
function Canvas.Coords(i)
    return (i - 1) % Canvas.SIZE + 1, math.floor((i - 1) / Canvas.SIZE) + 1
end

-- 4-connected flood fill of the region matching the colour under (x, y).
-- Calls fn(x, y) for each cell of the region and returns how many there
-- were. Purely a read: the caller decides what to paint, so filling cannot
-- disturb the traversal.
function Canvas.FloodFill(cells, x, y, fn)
    if x < 1 or x > Canvas.SIZE or y < 1 or y > Canvas.SIZE then
        return 0
    end
    local target = cells[Canvas.Index(x, y)]
    local seen, stack, n = {}, { x, y }, 0
    while #stack > 0 do
        local cy = table.remove(stack)
        local cx = table.remove(stack)
        local i = Canvas.Index(cx, cy)
        if not seen[i] and cells[i] == target then
            seen[i] = true
            n = n + 1
            fn(cx, cy)
            if cx > 1 then stack[#stack + 1] = cx - 1; stack[#stack + 1] = cy end
            if cx < Canvas.SIZE then stack[#stack + 1] = cx + 1; stack[#stack + 1] = cy end
            if cy > 1 then stack[#stack + 1] = cx; stack[#stack + 1] = cy - 1 end
            if cy < Canvas.SIZE then stack[#stack + 1] = cx; stack[#stack + 1] = cy + 1 end
        end
    end
    return n
end

function Canvas.Clear(cells)
    for i = 1, Canvas.NUM_CELLS do
        cells[i] = 0
    end
end

-- Run-length encode the whole canvas as pairs of characters:
-- (run length - 1, color), each drawn from the 64-char alphabet. Runs are
-- capped at 64 cells so both values fit in one character.
function Canvas.Serialize(cells)
    local out = {}
    local n = Canvas.NUM_CELLS
    local i = 1
    while i <= n do
        local c = cells[i]
        local run = 1
        while run < 64 and i + run <= n and cells[i + run] == c do
            run = run + 1
        end
        out[#out + 1] = WP.EncodeChar(run - 1)
        out[#out + 1] = WP.EncodeChar(c)
        i = i + run
    end
    return table.concat(out)
end

-- Decode an RLE snapshot back into a fresh cells array. Returns nil if the
-- payload is malformed (wrong length, unknown characters, bad color index,
-- or a cell count that does not match the canvas). Input is untrusted.
function Canvas.Deserialize(data)
    if type(data) ~= "string" or #data == 0 or #data % 2 ~= 0 then
        return nil
    end
    local cells = {}
    local pos = 0
    for i = 1, #data, 2 do
        local run = WP.DecodeChar(data:sub(i, i))
        local color = WP.DecodeChar(data:sub(i + 1, i + 1))
        if not run or not color or color >= Canvas.NUM_COLORS then
            return nil
        end
        if pos + run + 1 > Canvas.NUM_CELLS then
            return nil
        end
        for _ = 1, run + 1 do
            pos = pos + 1
            cells[pos] = color
        end
    end
    if pos ~= Canvas.NUM_CELLS then
        return nil
    end
    return cells
end
