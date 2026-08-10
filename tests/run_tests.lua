-- Desktop-only test harness for WoWPaint's pure logic (never loaded by the
-- game client). Run from the repo root:  lua tests/run_tests.lua

local WP = {}

-- Minimal WoW-global stubs so pure-logic modules load on desktop Lua.
time = time or os.time
GetNormalizedRealmName = GetNormalizedRealmName or function()
    return "Testrealm"
end

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
loadModule("Portraits.lua")

local Canvas = WP.Canvas
local Portraits = WP.Portraits
WP.db = { portraits = {}, gallery = {}, activeId = Portraits.SHARED_ID }
WP.Comm = { FlushPaintOps = function() end } -- SetActive flushes via Comm

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
check(1 + 6 + 76 * 3 <= 240, "max batch message (kind + id + ops) stays under 240 chars")

-- Portrait ids and names -----------------------------------------------------

math.randomseed(7)
ok = true
for _ = 1, 50 do
    local id = Portraits.GenerateId()
    if not Portraits.ValidId(id) or id == Portraits.SHARED_ID then
        ok = false
    end
end
check(ok, "GenerateId produces valid non-reserved 6-char ids")
check(Portraits.ValidId("000000"), "reserved Shared id is valid on the wire")
check(not Portraits.ValidId("00000"), "ValidId rejects short ids")
check(not Portraits.ValidId("0000000"), "ValidId rejects long ids")
check(not Portraits.ValidId("00:000"), "ValidId rejects delimiter characters")
check(not Portraits.ValidId(nil), "ValidId rejects nil")

check(Portraits.SanitizeName("  My|Art,Work  ") == "MyArtWork", "SanitizeName strips pipes, commas, padding")
check(#Portraits.SanitizeName(string.rep("x", 60)) == Portraits.MAX_NAME, "SanitizeName caps length")

-- Name normalization ---------------------------------------------------------

check(WP.NormalizeName("Bob") == "Bob-Testrealm", "NormalizeName appends our realm to bare names")
check(WP.NormalizeName("Bob-Other") == "Bob-Other", "NormalizeName keeps existing realm")
check(WP.NormalizeName("") == nil and WP.NormalizeName(nil) == nil, "NormalizeName rejects empty input")

-- Roster union-merge ---------------------------------------------------------

local p = Portraits.Create("Test", "MEMBERS", nil, "Owner-Testrealm")
check(Portraits.IsMember(p, "Owner-Testrealm"), "creator starts as a member")
check(Portraits.AddMembers(p, { "A-Realm", "B-Realm" }) == true, "AddMembers adds new names")
check(Portraits.AddMembers(p, { "A-Realm", "B-Realm" }) == false, "AddMembers is idempotent (union)")
check(#p.members == 3, "roster has exactly the union")
Portraits.AddMembers(p, { "", 42 })
check(#p.members == 3, "AddMembers rejects empty and non-string names")
local big = {}
for i = 1, 50 do
    big[i] = "Extra" .. i .. "-Realm"
end
Portraits.AddMembers(p, big)
check(#p.members <= Portraits.MAX_MEMBERS, "roster respects MAX_MEMBERS cap")

-- Snapshot header with lock flag ---------------------------------------------

local header = "S" .. p.id .. ":3:41:1234:L:" .. "0A0B"
local hid = header:sub(2, 7)
local hi, hn, hrev, hflag, hdata = header:sub(8):match("^:(%d+):(%d+):(%d+):([LU]):(.*)$")
check(hid == p.id and tonumber(hi) == 3 and tonumber(hn) == 41 and tonumber(hrev) == 1234
    and hflag == "L" and hdata == "0A0B", "S chunk header parses with lock flag")
check(("S" .. p.id .. ":1:1:0:X:aa"):sub(8):match("^:(%d+):(%d+):(%d+):([LU]):(.*)$") == nil,
    "S chunk header rejects unknown lock flags")

-- Gallery copies are independent ---------------------------------------------

p.cells[1] = 7
local entry = Portraits.SaveToGallery(p, "Snapshot")
p.cells[1] = 12
check(entry.cells[1] == 7, "gallery entry is a deep copy, not a reference")
check(entry.name == "Snapshot", "gallery entry keeps its given name")
p.cells[1] = 0

-- Invite wire format ---------------------------------------------------------

local invite = "I" .. p.id .. ":Owner-Testrealm:Fan: Art"
local iowner, iname = invite:sub(8):match("^:(.-):(.*)$")
check(iowner == "Owner-Testrealm" and iname == "Fan: Art",
    "invite parsing splits owner and keeps colons in the trailing name")

--------------------------------------------------------------------------

if failures > 0 then
    print(("\n%d test(s) FAILED"):format(failures))
    os.exit(1)
end
print("\nAll tests passed.")
