-- Desktop-only test harness for WoWPaint's pure logic (never loaded by the
-- game client). Run from the repo root:  lua tests/run_tests.lua

local WP = {}

local function loadModule(file)
    local paths = { file, "../" .. file }
    for _, p in ipairs(paths) do
        local chunk = loadfile(p)
        if chunk then
            chunk("WoWPaint", WP)
            return
        end
    end
    error("could not locate " .. file .. " (run from the repo root)")
end

loadModule("Util.lua")
loadModule("Canvas.lua")

local Canvas = WP.Canvas
local failures = 0

local function check(cond, label)
    if cond then
        print("PASS  " .. label)
    else
        failures = failures + 1
        print("FAIL  " .. label)
    end
end

-- Char codec ---------------------------------------------------------------

local ok = true
for n = 0, 63 do
    local c = WP.EncodeChar(n)
    if type(c) ~= "string" or #c ~= 1 or WP.DecodeChar(c) ~= n then
        ok = false
    end
end
check(ok, "EncodeChar/DecodeChar round-trips 0..63")
check(WP.EncodeChar(64) == nil and WP.EncodeChar(-1) == nil, "EncodeChar rejects out-of-range")
check(WP.DecodeChar("|") == nil and WP.DecodeChar(":") == nil and WP.DecodeChar("") == nil,
    "DecodeChar rejects unknown characters")

-- Alphabet must avoid characters the chat layer treats specially, and the
-- protocol's own delimiter.
local unsafe = false
for n = 0, 63 do
    local c = WP.EncodeChar(n)
    if c == "|" or c == ":" or c:byte() < 33 or c:byte() > 126 then
        unsafe = true
    end
end
check(not unsafe, "alphabet contains only safe printable characters")

-- RLE codec ----------------------------------------------------------------

local blank = {}
for i = 1, Canvas.NUM_CELLS do
    blank[i] = 0
end
local data = Canvas.Serialize(blank)
check(#data == 128, "blank canvas serializes to 128 chars (64 max-runs)")
local back = Canvas.Deserialize(data)
ok = back ~= nil
if ok then
    for i = 1, Canvas.NUM_CELLS do
        if back[i] ~= blank[i] then
            ok = false
        end
    end
end
check(ok, "blank canvas round-trips")

math.randomseed(42)
local noisy = {}
for i = 1, Canvas.NUM_CELLS do
    noisy[i] = math.random(0, Canvas.NUM_COLORS - 1)
end
data = Canvas.Serialize(noisy)
back = Canvas.Deserialize(data)
ok = back ~= nil
if ok then
    for i = 1, Canvas.NUM_CELLS do
        if back[i] ~= noisy[i] then
            ok = false
        end
    end
end
check(ok, "noisy canvas round-trips")
check(#data % 2 == 0, "serialized form has even length")

check(Canvas.Deserialize(nil) == nil, "Deserialize rejects nil")
check(Canvas.Deserialize("abc") == nil, "Deserialize rejects odd length")
check(Canvas.Deserialize("!!") == nil, "Deserialize rejects unknown chars")
check(Canvas.Deserialize("0G") == nil, "Deserialize rejects color >= 16")
check(Canvas.Deserialize(data .. "00") == nil, "Deserialize rejects cell overflow")
check(Canvas.Deserialize(data:sub(1, #data - 2)) == nil, "Deserialize rejects short payloads")

-- SetPixel bounds ----------------------------------------------------------

local cells = {}
for i = 1, Canvas.NUM_CELLS do
    cells[i] = 0
end
check(Canvas.SetPixel(cells, 1, 1, 5) == true, "SetPixel changes a cell")
check(Canvas.SetPixel(cells, 1, 1, 5) == false, "SetPixel no-ops on same color")
check(Canvas.SetPixel(cells, 0, 1, 5) == false, "SetPixel rejects x < 1")
check(Canvas.SetPixel(cells, 65, 1, 5) == false, "SetPixel rejects x > 64")
check(Canvas.SetPixel(cells, 1, 0, 5) == false, "SetPixel rejects y < 1")
check(Canvas.SetPixel(cells, 1, 65, 5) == false, "SetPixel rejects y > 64")
check(Canvas.SetPixel(cells, 1, 2, 16) == false, "SetPixel rejects color >= 16")
check(Canvas.SetPixel(cells, 1, 2, -1) == false, "SetPixel rejects color < 0")
check(Canvas.GetPixel(cells, 1, 1) == 5, "GetPixel reads back the value")

-- Bresenham ----------------------------------------------------------------

local function walkLine(x0, y0, x1, y1)
    local pts = {}
    WP.ForLine(x0, y0, x1, y1, function(x, y)
        pts[#pts + 1] = { x, y }
    end)
    return pts
end

local pts = walkLine(1, 1, 1, 1)
check(#pts == 1 and pts[1][1] == 1 and pts[1][2] == 1, "ForLine handles a single point")

pts = walkLine(1, 1, 5, 1)
check(#pts == 5, "ForLine covers a horizontal line")

pts = walkLine(3, 7, 3, 2)
check(#pts == 6, "ForLine covers a vertical line upward")

pts = walkLine(10, 10, 1, 4)
ok = pts[1][1] == 10 and pts[1][2] == 10 and pts[#pts][1] == 1 and pts[#pts][2] == 4
for i = 2, #pts do
    local dx = math.abs(pts[i][1] - pts[i - 1][1])
    local dy = math.abs(pts[i][2] - pts[i - 1][2])
    if dx > 1 or dy > 1 or (dx == 0 and dy == 0) then
        ok = false
    end
end
check(ok, "ForLine is contiguous with correct endpoints on a diagonal")

-- Wire-format size assumptions ---------------------------------------------

local op = WP.EncodeChar(63) .. WP.EncodeChar(63) .. WP.EncodeChar(15)
check(#op == 3, "one paint op is exactly 3 chars")
check(1 + 78 * 3 <= 240, "max batch message stays under 240 chars")

--------------------------------------------------------------------------

if failures > 0 then
    print(("\n%d test(s) FAILED"):format(failures))
    os.exit(1)
end
print("\nAll tests passed.")
