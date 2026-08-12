-- Desktop-only test harness for Pixel Party's pure logic (never loaded by the
-- game client). Run from the repo root:  lua tests/run_tests.lua

local PP = {}

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
            chunk("PixelParty", PP)
            return
        end
    end
    error("could not locate " .. file .. " (run from the repo root)")
end

loadModule("Util.lua")
loadModule("Canvas.lua")
loadModule("Portraits.lua")

local Canvas = PP.Canvas
local Portraits = PP.Portraits
PP.db = { portraits = {}, gallery = {}, activeId = Portraits.SHARED_ID }
PP.Comm = { FlushPaintOps = function() end } -- SetActive flushes via Comm

local failures = 0

local function check(cond, label)
    if cond then
        print("PASS  " .. label)
    else
        failures = failures + 1
        print("FAIL  " .. label)
    end
end

check(PP.VERSION == "0.7.0", "runtime version matches the current release")

-- Version comparison --------------------------------------------------------

check(PP.VersionAtLeast("0.7.0", 0, 7), "VersionAtLeast accepts the exact version")
check(PP.VersionAtLeast("0.7", 0, 7), "VersionAtLeast accepts major.minor with no patch")
check(PP.VersionAtLeast("1.0.0", 0, 7), "VersionAtLeast accepts a later major")
check(PP.VersionAtLeast("10.2", 0, 7), "VersionAtLeast accepts a double-digit major")
check(PP.VersionAtLeast("0.10", 0, 7),
    "VersionAtLeast compares numerically, not as strings ('0.10' < '0.7' lexically)")
check(not PP.VersionAtLeast("0.6.1", 0, 7), "VersionAtLeast rejects an earlier version")
check(not PP.VersionAtLeast(nil, 0, 7), "VersionAtLeast reads an absent version as older")
check(not PP.VersionAtLeast("garbage", 0, 7), "VersionAtLeast reads a malformed version as older")
check(not PP.VersionAtLeast("0", 0, 7), "VersionAtLeast requires a minor component")

-- Palette -------------------------------------------------------------------
--
-- Palette indices are wire format: these pins exist so no refactor of the
-- generator can silently reshuffle published colors.

check(Canvas.NUM_COLORS == 64 and Canvas.EXTENDED_BASE == 16
    and Canvas.EXTENDED_BASE + Canvas.WHEEL_HUES * Canvas.WHEEL_SHADES == Canvas.NUM_COLORS,
    "the wheel fills the palette exactly from EXTENDED_BASE to 63")
ok = true
for c = 0, Canvas.NUM_COLORS - 1 do
    local col = Canvas.PALETTE[c]
    if type(col) ~= "table" then
        ok = false
    else
        for i = 1, 3 do
            if type(col[i]) ~= "number" or col[i] < 0 or col[i] > 1 then
                ok = false
            end
        end
    end
end
check(ok and Canvas.PALETTE[64] == nil, "all 64 palette entries are well-formed RGB and no more exist")

local function near(a, b)
    return math.abs(a - b) < 1e-9
end
local function colorIs(c, r, g, b)
    local col = Canvas.PALETTE[c]
    return col and near(col[1], r) and near(col[2], g) and near(col[3], b)
end
check(colorIs(0, 1, 1, 1) and colorIs(3, 0.133, 0.133, 0.133) and colorIs(5, 0.898, 0, 0),
    "the classic 16 keep their published values")
check(colorIs(17, 1, 0, 0) and colorIs(33, 0, 1, 0) and colorIs(49, 0, 0, 1),
    "the vivid ring hits pure red, green and blue at hues 0, 4 and 8")
check(colorIs(16, 1, 0.62, 0.62), "the pale ring starts at pale red")
check(colorIs(63, 0.4, 0, 0.2), "index 63 is the dark shade of the last hue")

local hr, hg, hb = Canvas.HSVToRGB(390, 1, 1)
check(near(hr, 1) and near(hg, 0.5) and near(hb, 0), "HSVToRGB wraps hue past 360")

-- Char codec ---------------------------------------------------------------

local ok = true
for n = 0, 63 do
    local c = PP.EncodeChar(n)
    if type(c) ~= "string" or #c ~= 1 or PP.DecodeChar(c) ~= n then
        ok = false
    end
end
check(ok, "EncodeChar/DecodeChar round-trips 0..63")
check(PP.EncodeChar(64) == nil and PP.EncodeChar(-1) == nil, "EncodeChar rejects out-of-range")
check(PP.DecodeChar("|") == nil and PP.DecodeChar(":") == nil and PP.DecodeChar("") == nil,
    "DecodeChar rejects unknown characters")

-- Alphabet must avoid characters the chat layer treats specially, and the
-- protocol's own delimiter.
local unsafe = false
for n = 0, 63 do
    local c = PP.EncodeChar(n)
    if c == "|" or c == ":" or c:byte() < 33 or c:byte() > 126 then
        unsafe = true
    end
end
check(not unsafe, "alphabet contains only safe printable characters")

-- RLE codec ----------------------------------------------------------------

local SZ = Canvas.DEFAULT_SIZE
local blank = Canvas.New(SZ)
local data = Canvas.Serialize(SZ, blank)
check(#data == 128, "blank canvas serializes to 128 chars (64 max-runs)")
local back = Canvas.Deserialize(SZ, data)
ok = back ~= nil
if ok then
    for i = 1, Canvas.Cells(SZ) do
        if back[i] ~= blank[i] then
            ok = false
        end
    end
end
check(ok, "blank canvas round-trips")

math.randomseed(42)
local noisy = {}
for i = 1, Canvas.Cells(SZ) do
    noisy[i] = math.random(0, Canvas.NUM_COLORS - 1)
end
data = Canvas.Serialize(SZ, noisy)
back = Canvas.Deserialize(SZ, data)
ok = back ~= nil
if ok then
    for i = 1, Canvas.Cells(SZ) do
        if back[i] ~= noisy[i] then
            ok = false
        end
    end
end
check(ok, "noisy canvas round-trips")
check(#data % 2 == 0, "serialized form has even length")

check(Canvas.Deserialize(SZ, nil) == nil, "Deserialize rejects nil")
check(Canvas.Deserialize(SZ, "abc") == nil, "Deserialize rejects odd length")
check(Canvas.Deserialize(SZ, "!!") == nil, "Deserialize rejects unknown chars")
check(Canvas.Deserialize(SZ, data .. "00") == nil, "Deserialize rejects cell overflow")

-- Every alphabet character is a valid color since 0.7; a canvas painted
-- entirely in the last color must round-trip.
local loud = {}
for i = 1, Canvas.Cells(SZ) do
    loud[i] = Canvas.NUM_COLORS - 1
end
back = Canvas.Deserialize(SZ, Canvas.Serialize(SZ, loud))
check(back ~= nil and back[1] == 63 and back[Canvas.Cells(SZ)] == 63,
    "a canvas of wheel colors round-trips")
check(Canvas.Deserialize(SZ, data:sub(1, #data - 2)) == nil, "Deserialize rejects short payloads")

-- SetPixel bounds ----------------------------------------------------------

local cells = Canvas.New(SZ)
check(Canvas.SetPixel(SZ, cells, 1, 1, 5) == true, "SetPixel changes a cell")
check(Canvas.SetPixel(SZ, cells, 1, 1, 5) == false, "SetPixel no-ops on same color")
check(Canvas.SetPixel(SZ, cells, 0, 1, 5) == false, "SetPixel rejects x < 1")
check(Canvas.SetPixel(SZ, cells, 65, 1, 5) == false, "SetPixel rejects x > 64")
check(Canvas.SetPixel(SZ, cells, 1, 0, 5) == false, "SetPixel rejects y < 1")
check(Canvas.SetPixel(SZ, cells, 1, 65, 5) == false, "SetPixel rejects y > 64")
check(Canvas.SetPixel(SZ, cells, 1, 2, 63) == true, "SetPixel accepts the last wheel color")
check(Canvas.SetPixel(SZ, cells, 1, 3, 64) == false, "SetPixel rejects color >= 64")
check(Canvas.SetPixel(SZ, cells, 1, 2, -1) == false, "SetPixel rejects color < 0")
check(Canvas.HasExtendedColors(SZ, cells) == true, "HasExtendedColors sees the wheel color")
cells[Canvas.Index(SZ, 1, 2)] = 0
check(Canvas.HasExtendedColors(SZ, cells) == false,
    "HasExtendedColors ignores a canvas of classic colors")
check(Canvas.GetPixel(SZ, cells, 1, 1) == 5, "GetPixel reads back the value")

-- A 128 canvas must not be readable as a 64 one, and vice versa.
local big = Canvas.New(128)
check(Canvas.Cells(128) == 16384, "a 128 canvas has 16384 cells")
check(Canvas.SetPixel(128, big, 100, 100, 7) == true, "SetPixel reaches past 64 on a 128 canvas")
check(Canvas.SetPixel(SZ, big, 100, 100, 7) == false, "the same cell is out of bounds at size 64")
check(Canvas.Index(128, 1, 2) == 129 and Canvas.Index(64, 1, 2) == 65,
    "Index strides by the canvas size")
local bigData = Canvas.Serialize(128, big)
check(Canvas.Deserialize(128, bigData) ~= nil, "a 128 snapshot round-trips at 128")
check(Canvas.Deserialize(64, bigData) == nil, "a 128 snapshot is rejected as a 64 canvas")
check(Canvas.Deserialize(128, data) == nil, "a 64 snapshot is rejected as a 128 canvas")
check(Canvas.ValidSize(64) and Canvas.ValidSize(128) and not Canvas.ValidSize(96)
    and not Canvas.ValidSize(nil), "ValidSize admits exactly the supported sizes")

-- Bresenham ----------------------------------------------------------------

local function walkLine(x0, y0, x1, y1)
    local pts = {}
    PP.ForLine(x0, y0, x1, y1, function(x, y)
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

-- Paint op codec -------------------------------------------------------------

check(PP.OpWidth(64) == 3 and PP.OpWidth(128) == 5, "op width follows the canvas size")

-- The 64 encoding must stay byte-for-byte what earlier versions emit, or the
-- Shared canvas stops being readable across versions.
check(PP.EncodeOp(64, 1, 1, 0) == PP.EncodeChar(0) .. PP.EncodeChar(0) .. PP.EncodeChar(0),
    "the 3-char encoding is unchanged")
check(#PP.EncodeOp(64, 64, 64, 15) == 3 and #PP.EncodeOp(128, 1, 1, 0) == 5,
    "ops are 3 chars at size 64 and 5 above it")

ok = true
for _, size in ipairs(Canvas.SIZES) do
    for _, pt in ipairs({ { 1, 1, 0 }, { size, size, 15 }, { 1, size, 7 }, { size, 1, 3 },
        { 65, 100, 9 }, { 33, 17, 5 }, { 2, 2, 63 }, { 70, 3, 63 } }) do
        local x, y, c = pt[1], pt[2], pt[3]
        if x <= size and y <= size then
            local dx, dy, dc = PP.DecodeOp(size, PP.EncodeOp(size, x, y, c), 1)
            if dx ~= x or dy ~= y or dc ~= c then
                ok = false
            end
        end
    end
end
check(ok, "every op round-trips at both widths, including past 64")

check(PP.DecodeOp(128, "aa", 1) == nil, "DecodeOp rejects a truncated wide op")
check(PP.DecodeOp(64, "a|a", 1) == nil, "DecodeOp rejects characters off the alphabet")

-- A batch must stay inside the 255-byte payload with the kind byte and id.
check(1 + 6 + 76 * 3 <= 240 and 1 + 6 + 48 * 5 <= 247,
    "both batch limits fit the addon message cap")

-- Invite and snapshot headers carry the size --------------------------------

local iowner2, isize, iname = ("Iaabbcc:Owner-Testrealm:128:Fan: Art"):sub(8)
    :match("^:(.-):(%d+):(.*)$")
check(iowner2 == "Owner-Testrealm" and tonumber(isize) == 128 and iname == "Fan: Art",
    "invite parsing splits owner, size and a name containing colons")
check(("Iaabbcc:Owner-Testrealm:Fan Art"):sub(8):match("^:(.-):(%d+):(.*)$") == nil,
    "an invite without a size field is rejected rather than misread")

local sh = ("Saabbcc:3:41:1234:L:128:0A0B"):sub(8)
local si, sn, srev, sflag, ssize, sdata = sh:match("^:(%d+):(%d+):(%d+):([LU]):(%d+):(.*)$")
check(tonumber(si) == 3 and tonumber(sn) == 41 and tonumber(srev) == 1234 and sflag == "L"
    and tonumber(ssize) == 128 and sdata == "0A0B", "S header carries size alongside the lock flag")

-- Viewport mapping -----------------------------------------------------------

check(PP.VisibleCells(64, 8, 512) == 64, "a 64 canvas fills the viewport at 8px")
check(PP.VisibleCells(64, 16, 512) == 32, "zooming to 16px halves what is visible")
check(PP.VisibleCells(64, 4, 512) == 64, "visible cells never exceed the canvas")
check(PP.VisibleCells(128, 4, 512) == 128, "a 128 canvas fits at 4px")
check(PP.VisibleCells(128, 8, 512) == 64, "a 128 canvas shows half its width at 8px")

check(PP.FitZoom(64, 512) == 8, "64 fits the viewport exactly at 8px")
check(PP.FitZoom(128, 512) == 4, "128 needs 4px to fit")
check(PP.FitZoom(256, 512) == 4, "beyond the zoom range, fit falls back to the smallest zoom")

local zooms = PP.ZoomList(64, 512)
check(#zooms == 3 and zooms[1] == 8 and zooms[3] == 32,
    "a 64 canvas offers 8/16/32 and never a wasteful zoom-out")
check(#PP.ZoomList(128, 512) == 4, "a 128 canvas also offers the 4px fit level")

check(PP.ClampPan(64, 64, 5) == 1, "pan is pinned when the whole canvas is visible")
check(PP.ClampPan(64, 32, 1) == 1, "pan cannot go above the first cell")
check(PP.ClampPan(64, 32, 99) == 33, "pan stops with the last cell flush to the edge")
check(PP.ClampPan(64, 32, 20) == 20, "pan passes through inside its range")

local vx, vy = PP.ViewToCanvas(33, 17, 1, 1)
check(vx == 33 and vy == 17, "the first slot shows the panned-to cell")
vx, vy = PP.ViewToCanvas(33, 17, 32, 32)
check(vx == 64 and vy == 48, "the last slot shows the far corner of the window")

local cc, cr = PP.CanvasToView(33, 17, 32, 33, 17)
check(cc == 1 and cr == 1, "CanvasToView inverts ViewToCanvas")
check(PP.CanvasToView(33, 17, 32, 32, 17) == nil, "cells left of the window are not visible")
check(PP.CanvasToView(33, 17, 32, 65, 17) == nil, "cells right of the window are not visible")
ok = true
for x = 33, 64 do
    for y = 17, 48 do
        local c, r = PP.CanvasToView(33, 17, 32, x, y)
        if not c or PP.ViewToCanvas(33, 17, c, r) ~= x then
            ok = false
        end
    end
end
check(ok, "every cell in the window round-trips through both mappings")

-- Wire-format size assumptions ---------------------------------------------

local op = PP.EncodeChar(63) .. PP.EncodeChar(63) .. PP.EncodeChar(15)
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

check(PP.NormalizeName("Bob") == "Bob-Testrealm", "NormalizeName appends our realm to bare names")
check(PP.NormalizeName("Bob-Other") == "Bob-Other", "NormalizeName keeps existing realm")
check(PP.NormalizeName("") == nil and PP.NormalizeName(nil) == nil, "NormalizeName rejects empty input")

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

-- Member-name validation -----------------------------------------------------

check(Portraits.ValidMemberName("Bob-Testrealm"), "ValidMemberName accepts Name-Realm")
check(Portraits.ValidMemberName("\195\129strid-Ravencrest"),
    "ValidMemberName accepts accented (non-ASCII) names")
check(not Portraits.ValidMemberName("|cffff0000Bob|r-Realm"),
    "ValidMemberName rejects chat escapes")
check(not Portraits.ValidMemberName("A,B-Realm"), "ValidMemberName rejects the roster delimiter")
check(not Portraits.ValidMemberName("A:B-Realm"), "ValidMemberName rejects the protocol delimiter")
check(not Portraits.ValidMemberName("-Alice-Realm") and not Portraits.ValidMemberName("+Alice-Realm"),
    "ValidMemberName rejects tombstone/revoke marks, so a name cannot forge one")
check(not Portraits.ValidMemberName(string.rep("x", 49)), "ValidMemberName caps length")

local escaped = Portraits.Create("Escapes", "MEMBERS", nil, "Owner-Testrealm")
Portraits.AddMembers(escaped, { "|cff00ff00Sneak|r-Realm", "Fine-Realm" })
check(#escaped.members == 2 and escaped.members[2] == "Fine-Realm",
    "AddMembers drops names carrying chat escapes")

-- Uninvite tombstones --------------------------------------------------------

local kicked = Portraits.Create("Kicks", "MEMBERS", nil, "Owner-Testrealm")
Portraits.AddMembers(kicked, { "Ann-Realm", "Ben-Realm" })
check(Portraits.RemoveMembers(kicked, { "Ann-Realm" }) == true, "RemoveMembers drops the member")
check(not Portraits.IsMember(kicked, "Ann-Realm") and #kicked.members == 2,
    "removed member is off the roster")
check(Portraits.IsRemoved(kicked, "Ann-Realm"), "removal leaves a tombstone")
Portraits.AddMembers(kicked, { "Ann-Realm" })
check(not Portraits.IsMember(kicked, "Ann-Realm"),
    "roster gossip cannot resurrect a tombstoned member")
Portraits.RemoveMembers(kicked, { "Owner-Testrealm" })
check(Portraits.IsMember(kicked, "Owner-Testrealm") and not Portraits.IsRemoved(kicked, "Owner-Testrealm"),
    "the creator cannot be uninvited")
check(Portraits.Unremove(kicked, "Ann-Realm") == true, "Unremove lifts a tombstone")
Portraits.AddMembers(kicked, { "Ann-Realm" })
check(Portraits.IsMember(kicked, "Ann-Realm"), "re-invite works once the tombstone is lifted")

-- Drawing tools --------------------------------------------------------------

local function collect(fn)
    local pts, seen = {}, {}
    fn(function(x, y)
        local key = x .. ":" .. y
        if seen[key] then
            pts.dup = true
        end
        seen[key] = true
        pts[#pts + 1] = { x, y }
    end)
    return pts, seen
end

pts = collect(function(add) PP.ForRect(4, 4, 8, 7, false, add) end)
check(#pts == 2 * 5 + 2 * 4 - 4 and not pts.dup, "ForRect outlines a 5x4 box without repeats")
pts = collect(function(add) PP.ForRect(8, 7, 4, 4, true, add) end)
check(#pts == 20, "ForRect fills from reversed corners too")
pts = collect(function(add) PP.ForRect(3, 3, 3, 3, false, add) end)
check(#pts == 1, "ForRect degenerates to a single cell")

local outlinePts, outline = collect(function(add) PP.ForEllipse(10, 10, 20, 16, false, add) end)
local filledPts, filled = collect(function(add) PP.ForEllipse(10, 10, 20, 16, true, add) end)
check(#filledPts > #outlinePts and not filledPts.dup and not outlinePts.dup,
    "ForEllipse fills more than it outlines, neither with repeats")

ok = true
for key in pairs(outline) do
    if not filled[key] then
        ok = false
    end
end
check(ok, "ForEllipse outline is a subset of its fill")

-- Closure: on every row and column of the filled shape, the two extreme
-- cells must belong to the outline. A leaky outline (the classic midpoint
-- failure at shallow slopes) breaks this.
local rows, cols = {}, {}
for _, c in ipairs(filledPts) do
    local x, y = c[1], c[2]
    rows[y] = rows[y] or { x, x }
    rows[y][1], rows[y][2] = math.min(rows[y][1], x), math.max(rows[y][2], x)
    cols[x] = cols[x] or { y, y }
    cols[x][1], cols[x][2] = math.min(cols[x][1], y), math.max(cols[x][2], y)
end
ok = true
for y, r in pairs(rows) do
    if not outline[r[1] .. ":" .. y] or not outline[r[2] .. ":" .. y] then
        ok = false
    end
end
for x, c in pairs(cols) do
    if not outline[x .. ":" .. c[1]] or not outline[x .. ":" .. c[2]] then
        ok = false
    end
end
check(ok, "ForEllipse outline closes on every row and column")
pts = collect(function(add) PP.ForEllipse(5, 5, 5, 5, false, add) end)
check(#pts == 1, "ForEllipse degenerates to a single cell")

-- Flood fill -----------------------------------------------------------------

local fillCells = Canvas.New(SZ)
check(Canvas.FloodFill(SZ, fillCells, 1, 1, function() end) == Canvas.Cells(SZ),
    "FloodFill covers a blank canvas exactly once")
-- Wall down column 32 splits the canvas; the left region is 31 columns wide.
for y = 1, SZ do
    fillCells[Canvas.Index(SZ, 32, y)] = 5
end
check(Canvas.FloodFill(SZ, fillCells, 1, 1, function() end) == 31 * SZ,
    "FloodFill stops at a colour boundary")
check(Canvas.FloodFill(SZ, fillCells, 32, 1, function() end) == SZ,
    "FloodFill follows the wall itself")
check(Canvas.FloodFill(SZ, fillCells, 0, 1, function() end) == 0,
    "FloodFill rejects out-of-bounds seeds")
check(Canvas.FloodFill(128, Canvas.New(128), 1, 1, function() end) == 16384,
    "FloodFill spans a whole 128 canvas")

ok = true
for _, size in ipairs(Canvas.SIZES) do
    for _, i in ipairs({ 1, size, size + 1, Canvas.Cells(size) }) do
        local x, y = Canvas.Coords(size, i)
        if Canvas.Index(size, x, y) ~= i then
            ok = false
        end
    end
end
check(ok, "Canvas.Coords inverts Canvas.Index at every size")

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

-- Inbound protocol: trust rules for rosters, locks and uninvites -------------
--
-- Comm only touches the game API through a handful of globals, so stubbing
-- them lets the desktop suite drive real messages through OnMessage. This is
-- where the trust rules live, and they are the part of the addon a hostile
-- peer talks to directly.

local now = 1000
GetTime = function() return now end
UnitName = function() return "Me" end
UnitFullName = function() return "Me", "Testrealm" end
Ambiguate = function(name) return (name:gsub("%-.*", "")) end
IsInGuild = function() return false end
IsInGroup = function() return false end
IsInRaid = function() return false end
local registeredPrefix
C_ChatInfo = {
    RegisterAddonMessagePrefix = function(prefix)
        registeredPrefix = prefix
        return true
    end,
    SendAddonMessage = function() end,
}
C_Timer = { NewTicker = function() end, After = function() end }

local noop = function() end
PP.Print = noop
PP.UI = setmetatable({}, { __index = function() return noop end })
PP.playerFullName = "Me-Testrealm"

-- StaticPopup dialogs on the modern client ---------------------------------
--
-- 1.15.7+ clients ship the retail dialog rework: the edit box hangs off the
-- dialog as .EditBox behind a :GetEditBox() accessor, and the old lowercase
-- .editBox field is gone. Every edit-box dialog must reach the text through
-- the accessor or its Accept button dies with a nil index error. UI.lua's
-- popup handlers are plain functions, so a mock dialog drives them here.

StaticPopupDialogs = {}
ACCEPT, CANCEL, YES, NO, DECLINE = "Accept", "Cancel", "Yes", "No", "Decline"
loadModule("UI.lua")

local function modernDialog(text)
    local dialog = {}
    dialog.EditBox = {
        text = text,
        GetText = function(self) return self.text end,
        SetText = function(self, t) self.text = t end,
        HighlightText = function() end,
        GetParent = function() return dialog end,
    }
    function dialog:GetEditBox() return self.EditBox end
    function dialog:Hide() end
    return dialog
end

local act = Portraits.Create("Live", "MEMBERS", nil, "Me-Testrealm")
PP.db.portraits[act.id] = act
Portraits.SetActive(act.id)

local saveDef = StaticPopupDialogs["PIXELPARTY_SAVE"]
local dlg = modernDialog("")
check(pcall(saveDef.OnShow, dlg) and dlg.EditBox.text == "Live",
    "the save dialog prefills the portrait name through GetEditBox()")
dlg.EditBox.text = "Kept Name"
local galleryBefore = #PP.db.gallery
check(pcall(saveDef.OnAccept, dlg) and #PP.db.gallery == galleryBefore + 1
    and PP.db.gallery[#PP.db.gallery].name == "Kept Name",
    "the save dialog's Accept button saves under the typed name")

check(pcall(StaticPopupDialogs["PIXELPARTY_NEW"].OnAccept, modernDialog("Fresh"))
    and Portraits.FindByName("Fresh") ~= nil,
    "the new-portrait dialog's Accept button creates the named portrait")

local invited
PP.Comm.SendInvite = function(_, _, name)
    invited = name
    return true
end
local inviteDef = StaticPopupDialogs["PIXELPARTY_INVITE_SEND"]
dlg = modernDialog("")
check(pcall(inviteDef.OnShow, dlg, { prefill = "Pal-Testrealm" })
    and dlg.EditBox.text == "Pal-Testrealm",
    "the invite dialog prefills the target through GetEditBox()")
check(pcall(inviteDef.OnAccept, dlg) and invited == "Pal-Testrealm",
    "the invite dialog's Accept button sends to the typed name")
PP.Comm.SendInvite = nil
PP.db.activeId = Portraits.SHARED_ID
-- Loading UI.lua replaced the noop UI stub; the Comm tests below drive real
-- messages and only want inert UI callbacks, so put the stub back.
PP.UI = setmetatable({}, { __index = function() return noop end })

loadModule("Comm.lua")
local Comm = PP.Comm
check(Comm.PREFIX == "PixelParty", "the wire protocol uses the PixelParty prefix")

local OWNER, OTHER = "Owner-Testrealm", "Other-Testrealm"

local function newShared(id, owner, members)
    local sp = Portraits.Create("Wire" .. id, "MEMBERS", id, owner)
    Portraits.AddMembers(sp, members)
    return sp
end

local function sent(match)
    for _, item in ipairs(Comm.queue) do
        if item.msg:find(match, 1, true) then
            return item
        end
    end
    return nil
end

-- Roster tombstones are honoured from the owner and from nobody else.
local wire = newShared("aaaaaa", OWNER, { OWNER, OTHER, "Ann-Testrealm" })
Comm:OnMessage("PixelParty", "Maaaaaa:-Ann-Testrealm", "WHISPER", OTHER)
check(Portraits.IsMember(wire, "Ann-Testrealm"),
    "a plain member cannot uninvite anyone through roster gossip")
Comm:OnMessage("PixelParty", "Maaaaaa:-Ann-Testrealm", "WHISPER", OWNER)
check(not Portraits.IsMember(wire, "Ann-Testrealm") and Portraits.IsRemoved(wire, "Ann-Testrealm"),
    "the owner's roster tombstone removes the member")
Comm:OnMessage("PixelParty", "Maaaaaa:Ann-Testrealm", "WHISPER", OTHER)
check(not Portraits.IsMember(wire, "Ann-Testrealm"),
    "a stale peer's roster cannot resurrect the uninvited member")
Comm:OnMessage("PixelParty", "Maaaaaa:+Ann-Testrealm", "WHISPER", OWNER)
check(Portraits.IsMember(wire, "Ann-Testrealm"), "the owner can lift a tombstone and re-add")

-- Locking is the owner's in both directions.
Comm:OnMessage("PixelParty", "Laaaaaa", "WHISPER", OTHER)
check(not wire.locked, "a plain member cannot lock the portrait")
Comm:OnMessage("PixelParty", "Laaaaaa", "WHISPER", OWNER)
check(wire.locked, "the owner can lock the portrait")
Comm:OnMessage("PixelParty", "Uaaaaaa", "WHISPER", OTHER)
check(wire.locked, "a plain member cannot unlock the portrait")
Comm:OnMessage("PixelParty", "Uaaaaaa", "WHISPER", OWNER)
check(not wire.locked, "the owner can unlock the portrait")

-- Locked canvases drop inbound paint, and only the owner answers with a nag.
wire.locked = true
local before = wire.cells[Canvas.Index(wire.size, 1, 1)]
Comm.queue = {}
Comm:OnMessage("PixelParty", "Baaaaaa" .. PP.EncodeChar(0) .. PP.EncodeChar(0) .. PP.EncodeChar(5),
    "WHISPER", OTHER)
check(wire.cells[Canvas.Index(wire.size, 1, 1)] == before, "paint on a locked portrait is dropped")
check(sent("Laaaaaa") == nil, "a non-owner does not nag stale painters (its L is ignored anyway)")
wire.locked = false

-- Being uninvited drops the local copy, but only when the owner says so.
local victim = newShared("bbbbbb", OWNER, { OWNER, "Me-Testrealm" })
Comm:OnMessage("PixelParty", "Kbbbbbb", "WHISPER", OTHER)
check(Portraits.Get("bbbbbb") ~= nil, "a stranger cannot uninvite us")
Comm:OnMessage("PixelParty", "Kbbbbbb", "WHISPER", OWNER)
check(Portraits.Get("bbbbbb") == nil, "the owner's uninvite deletes our copy")

-- The owner's own uninvite: notify first, then drop them from the roster.
local mine = Portraits.Create("Mine", "MEMBERS", "cccccc", "Me-Testrealm")
-- Three on the roster: someone has to still be there to receive the gossip.
Portraits.AddMembers(mine, { "Me-Testrealm", OTHER, "Ann-Testrealm" })
Comm.queue = {}
ok = Comm:SendKick(mine, OTHER)
check(ok == true, "the creator may uninvite a member")
check(not Portraits.IsMember(mine, OTHER) and Portraits.IsRemoved(mine, OTHER),
    "uninvite removes and tombstones locally")
local kickMsg, rosterMsg = sent("Kcccccc"), sent("Mcccccc")
check(kickMsg ~= nil and kickMsg.target == OTHER, "the removed player is told directly")
check(rosterMsg ~= nil and rosterMsg.msg:find("-" .. OTHER, 1, true) ~= nil,
    "remaining members receive the tombstone in the roster gossip")
check(not Comm:SendKick(mine, "Me-Testrealm"), "the creator cannot uninvite themselves")
local notMine = Portraits.Create("NotMine", "MEMBERS", "dddddd", OWNER)
Portraits.AddMembers(notMine, { OWNER, "Me-Testrealm", "Ann-Testrealm" })
check(not Comm:SendKick(notMine, "Ann-Testrealm"),
    "a plain member cannot uninvite anyone")

-- Battle.net carries snapshots only, and never ordering-sensitive messages.
local bnetPortrait = newShared("ffffff", OWNER, { OWNER, "Me-Testrealm" })
bnetPortrait.rev = 3
Comm.queue = {}
-- A clear smuggled onto the unordered pipe must be ignored outright.
Comm:OnBNetMessage("PixelParty", "Cffffff", "WHISPER", 1234)
check(bnetPortrait.rev == 3, "a clear arriving over Battle.net is dropped")
Comm:OnBNetMessage("PixelParty", "Bffffff" .. PP.EncodeOp(64, 1, 1, 5), "WHISPER", 1234)
check(bnetPortrait.cells[Canvas.Index(64, 1, 1)] == 0, "paint arriving over Battle.net is dropped")
check(not Comm:BNetAccountFor(OWNER),
    "with no Battle.net API present, snapshots fall back to the chat transport")

-- Batches are un-counted once each when a remote clear drops them, even when
-- two batches carry byte-identical ops.
local rev = Portraits.Create("Rev", "MEMBERS", "eeeeee", "Me-Testrealm")
Portraits.AddMembers(rev, { "Me-Testrealm", OWNER, OTHER })
Comm.queue = {}
local dup = PP.EncodeChar(0) .. PP.EncodeChar(0) .. PP.EncodeChar(5)
rev.rev = 2
Comm:Send(rev, "Beeeeee" .. dup, 101) -- two members => two queued copies each
Comm:Send(rev, "Beeeeee" .. dup, 102)
check(#Comm.queue == 4, "a MEMBERS batch is queued once per other member")
Comm:DropQueuedPaints("eeeeee")
check(#Comm.queue == 0, "a remote clear drops every queued copy")
check(rev.rev == 0, "each dropped batch un-counts exactly one revision")

-- Old-version peers and wheel colors -----------------------------------------

local legacy = newShared("gggggg", OWNER, { OWNER, OTHER, "Me-Testrealm" })
local warns = {}
PP.Print = function(msg)
    warns[#warns + 1] = tostring(msg)
end
Comm:OnMessage("PixelParty", "Hgggggg:0:0.6.1:64", "WHISPER", OWNER)
check(#warns == 0, "an old-version hello alone does not warn")
legacy.cells[1] = 40
Comm:OnMessage("PixelParty", "Hgggggg:0:0.6.1:64", "WHISPER", OWNER)
check(#warns == 1 and warns[1]:find("older Pixel Party", 1, true) ~= nil,
    "an old-version hello warns once the canvas holds wheel colors")
now = now + 10
Comm:OnMessage("PixelParty", "Hgggggg:0:0.6.1:64", "WHISPER", OWNER)
check(#warns == 1, "the wheel-color warning is throttled")
now = now + 1000
Comm:Paint(legacy, 5, 5, 40)
check(#warns == 2, "painting a wheel color warns while a legacy peer is known")
-- Legacy peers are a set: a second one warns on its own hello, and one
-- upgrading must not silence warnings about the other.
Comm:OnMessage("PixelParty", "Hgggggg:0:0.6.1:64", "WHISPER", OTHER)
check(#warns == 3 and warns[3]:find("Other", 1, true) ~= nil,
    "a second legacy peer warns on its own hello")
Comm:OnMessage("PixelParty", "Hgggggg:0:0.7.0:64", "WHISPER", OTHER)
now = now + 1000
Comm:Paint(legacy, 6, 6, 40)
check(#warns == 4 and warns[4]:find("Owner", 1, true) ~= nil,
    "one peer upgrading does not hide another still-legacy peer")
Comm:OnMessage("PixelParty", "Hgggggg:0:0.7.0:64", "WHISPER", OWNER)
now = now + 1000
Comm:Paint(legacy, 7, 7, 40)
check(#warns == 4, "no more warnings once every legacy peer upgrades")
-- A legacy member uninvited since its hello is dropped, not nagged about.
Comm:OnMessage("PixelParty", "Hgggggg:0:0.6.1:64", "WHISPER", OTHER)
check(#warns == 5, "the returning legacy peer warns again after the throttle")
Portraits.RemoveMembers(legacy, { OTHER })
now = now + 1000
Comm:Paint(legacy, 8, 8, 40)
check(#warns == 5, "an uninvited legacy member is dropped, not warned about")
now = now + 1000
Comm:Paint(legacy, 9, 9, 5)
check(#warns == 5, "classic colors never warn")
PP.Print = noop

-- Snapshot offers prefer sources that saw every color -------------------------

local offerP = newShared("iiiiii", OWNER, { OWNER, OTHER, "Me-Testrealm" })
Comm.queue = {}
Comm:OnMessage("PixelParty", "Oiiiiii:5", "WHISPER", OTHER)       -- legacy, first
Comm:OnMessage("PixelParty", "Oiiiiii:5:0.7.0", "WHISPER", OWNER) -- modern, same rev
Comm:AcceptBestOffer()
check(Comm.sync ~= nil and Comm.sync.source == OWNER,
    "a modern offer beats an earlier same-rev legacy offer")
local getMsg = sent("Giiiiii")
check(getMsg ~= nil and getMsg.target == OWNER, "the snapshot request goes to the modern source")
Comm.sync = nil

-- ...but a lone legacy offer is still usable, with a warning when it is
-- about to overwrite wheel pixels we hold.
local lone = newShared("jjjjjj", OWNER, { OWNER, "Me-Testrealm" })
lone.cells[1] = 40
warns = {}
PP.Print = function(msg)
    warns[#warns + 1] = tostring(msg)
end
Comm:OnMessage("PixelParty", "Ojjjjjj:5", "WHISPER", OWNER)
Comm:AcceptBestOffer()
check(Comm.sync ~= nil and Comm.sync.source == OWNER, "a lone legacy offer is accepted")
check(#warns == 1 and warns[1]:find("older Pixel Party", 1, true) ~= nil,
    "accepting a legacy snapshot over wheel pixels warns")
-- The request must go to the legacy source itself. Aiming it anywhere else
-- (the bug: at the empty modern slot, so at nobody) leaves the transfer
-- permanently pending, and every stroke for the portrait buffers unseen
-- behind it until the sync watchdog gives up.
local legacyGet = sent("Gjjjjjj")
check(legacyGet ~= nil and legacyGet.target == OWNER,
    "the snapshot request goes to the legacy source")
PP.Print = noop
Comm.sync = nil

-- A joiner's welcome offer must carry our version, or the joiner files the
-- inviter under "legacy" and prefers any other source over it.
local joinP = Portraits.Create("JoinOffer", "MEMBERS", "kkkkkk", "Me-Testrealm")
Portraits.AddMembers(joinP, { "Me-Testrealm" })
joinP.rev = 4
Comm.queue = {}
Comm:SendInvite(joinP, OTHER)
Comm:OnMessage("PixelParty", "Jkkkkkk", "WHISPER", OTHER)
local joinOffer = sent("Okkkkkk")
check(joinOffer ~= nil and joinOffer.msg == "Okkkkkk:4:" .. PP.VERSION,
    "the offer made to a fresh joiner announces our version")

-- SavedVariables migration and sanitising --------------------------------
--
-- Core owns the upgrade path for canvases people have already painted, so it
-- is worth driving for real rather than trusting it. Loading it needs a few
-- more stubs, and the ADDON_LOADED handler is the only way in: InitDB is a
-- local.

local eventHandler
DEFAULT_CHAT_FRAME = { AddMessage = function() end }
SlashCmdList = {}
StaticPopup_Show = function() end
CreateFrame = function()
    return {
        RegisterEvent = function() end,
        SetScript = function(_, which, fn)
            if which == "OnEvent" then
                eventHandler = fn
            end
        end,
    }
end

loadModule("Core.lua")
check(type(eventHandler) == "function", "Core installs an event handler")
check(SLASH_PIXELPARTY1 == "/pixelparty" and SLASH_PIXELPARTY2 == "/pparty",
    "Pixel Party registers both supported slash commands")
check(type(SlashCmdList["PIXELPARTY"]) == "function",
    "Pixel Party installs its renamed slash-command handler")
PixelPartyDB = nil
eventHandler(nil, "ADDON_LOADED", "AnotherAddon")
check(PixelPartyDB == nil and registeredPrefix == nil,
    "an unrelated ADDON_LOADED event does not initialise Pixel Party")

local function migrate(saved)
    PixelPartyDB = saved
    eventHandler(nil, "ADDON_LOADED", "PixelParty")
    return PP.db
end

-- A v1 database: one flat canvas, no portraits at all.
local v1cells = Canvas.New(64)
v1cells[Canvas.Index(64, 5, 5)] = 9
local db = migrate({ dbVersion = 1, cells = v1cells, rev = 12, channel = "GUILD" })
check(registeredPrefix == "PixelParty", "initialisation registers the PixelParty wire prefix")
local shared = db.portraits[Portraits.SHARED_ID]
check(db.dbVersion == 2, "the database is upgraded to v2")
check(shared ~= nil and shared.rev == 12 and shared.dist == "GUILD",
    "the old canvas becomes the Shared portrait, keeping its revision and scope")
check(shared.cells[Canvas.Index(64, 5, 5)] == 9, "painted pixels survive the migration")
check(shared.size == 64, "the Shared canvas is size 64")
check(db.cells == nil and db.rev == nil, "the v1 fields are cleared")

-- Portraits saved before per-portrait sizes existed.
db = migrate({
    dbVersion = 2,
    portraits = {
        ["000000"] = { name = "Shared", dist = "AUTO", cells = Canvas.New(64), rev = 1 },
        ["abcdef"] = { name = "Old", dist = "MEMBERS", cells = Canvas.New(64), rev = 2,
            owner = "Owner-Testrealm", members = { "Owner-Testrealm" } },
    },
    gallery = { { name = "Keep", cells = Canvas.New(64), savedAt = 0 } },
})
check(db.portraits["abcdef"].size == 64, "a sizeless portrait is adopted as 64")
check(db.gallery[1].size == 64, "a sizeless gallery entry is adopted as 64")

-- Junk must be repaired, not propagated, and a 128 canvas must survive.
local bigCells = Canvas.New(128)
bigCells[Canvas.Index(128, 100, 100)] = 11
bigCells[7] = "not a colour"
db = migrate({
    dbVersion = 2,
    portraits = {
        ["000000"] = { name = "Shared", dist = "NONSENSE", cells = Canvas.New(64), rev = -5,
            size = 128, locked = true },
        ["bigpor"] = { name = "Big", dist = "MEMBERS", cells = bigCells, rev = 3, size = 128,
            owner = "Owner-Testrealm", members = { "Owner-Testrealm", "|cffBad-Realm" } },
        ["!!bad!"] = { name = "Bogus", cells = Canvas.New(64) },
    },
    gallery = { "not a table", { name = "", cells = Canvas.New(64) } },
})
check(db.portraits["000000"].size == 64,
    "the Shared canvas is forced back to 64 however it was stored")
check(db.portraits["000000"].dist == "AUTO" and db.portraits["000000"].rev == 0
    and db.portraits["000000"].locked == false, "a corrupt Shared portrait is repaired")
check(db.portraits["!!bad!"] == nil, "a portrait under an invalid id is dropped")
local bigp = db.portraits["bigpor"]
check(bigp and bigp.size == 128 and bigp.cells[Canvas.Index(128, 100, 100)] == 11,
    "a 128 portrait keeps its size and its pixels")
check(bigp.cells[7] == 0, "a non-numeric cell is repaired to the background colour")
check(#bigp.members == 1, "a roster name carrying chat escapes is dropped on load")
check(#db.gallery == 1 and db.gallery[1].name == "Untitled",
    "gallery junk is dropped and unnamed entries are labelled")

-- Cells past the end of a canvas must not linger: Serialize would read them.
local overlong = Canvas.New(64)
for i = Canvas.Cells(64) + 1, Canvas.Cells(64) + 50 do
    overlong[i] = 3
end
db = migrate({
    dbVersion = 2,
    portraits = { ["000000"] = { name = "Shared", dist = "AUTO", cells = overlong, rev = 0 } },
})
check(#db.portraits["000000"].cells == Canvas.Cells(64),
    "cells past the canvas area are trimmed on load")

--------------------------------------------------------------------------

if failures > 0 then
    print(("\n%d test(s) FAILED"):format(failures))
    os.exit(1)
end
print("\nAll tests passed.")
