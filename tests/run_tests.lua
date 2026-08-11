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

-- Viewport mapping -----------------------------------------------------------

check(WP.VisibleCells(64, 8, 512) == 64, "a 64 canvas fills the viewport at 8px")
check(WP.VisibleCells(64, 16, 512) == 32, "zooming to 16px halves what is visible")
check(WP.VisibleCells(64, 4, 512) == 64, "visible cells never exceed the canvas")
check(WP.VisibleCells(128, 4, 512) == 128, "a 128 canvas fits at 4px")
check(WP.VisibleCells(128, 8, 512) == 64, "a 128 canvas shows half its width at 8px")

check(WP.FitZoom(64, 512) == 8, "64 fits the viewport exactly at 8px")
check(WP.FitZoom(128, 512) == 4, "128 needs 4px to fit")
check(WP.FitZoom(256, 512) == 4, "beyond the zoom range, fit falls back to the smallest zoom")

local zooms = WP.ZoomList(64, 512)
check(#zooms == 3 and zooms[1] == 8 and zooms[3] == 32,
    "a 64 canvas offers 8/16/32 and never a wasteful zoom-out")
check(#WP.ZoomList(128, 512) == 4, "a 128 canvas also offers the 4px fit level")

check(WP.ClampPan(64, 64, 5) == 1, "pan is pinned when the whole canvas is visible")
check(WP.ClampPan(64, 32, 1) == 1, "pan cannot go above the first cell")
check(WP.ClampPan(64, 32, 99) == 33, "pan stops with the last cell flush to the edge")
check(WP.ClampPan(64, 32, 20) == 20, "pan passes through inside its range")

local vx, vy = WP.ViewToCanvas(33, 17, 1, 1)
check(vx == 33 and vy == 17, "the first slot shows the panned-to cell")
vx, vy = WP.ViewToCanvas(33, 17, 32, 32)
check(vx == 64 and vy == 48, "the last slot shows the far corner of the window")

local cc, cr = WP.CanvasToView(33, 17, 32, 33, 17)
check(cc == 1 and cr == 1, "CanvasToView inverts ViewToCanvas")
check(WP.CanvasToView(33, 17, 32, 32, 17) == nil, "cells left of the window are not visible")
check(WP.CanvasToView(33, 17, 32, 65, 17) == nil, "cells right of the window are not visible")
ok = true
for x = 33, 64 do
    for y = 17, 48 do
        local c, r = WP.CanvasToView(33, 17, 32, x, y)
        if not c or WP.ViewToCanvas(33, 17, c, r) ~= x then
            ok = false
        end
    end
end
check(ok, "every cell in the window round-trips through both mappings")

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

pts = collect(function(add) WP.ForRect(4, 4, 8, 7, false, add) end)
check(#pts == 2 * 5 + 2 * 4 - 4 and not pts.dup, "ForRect outlines a 5x4 box without repeats")
pts = collect(function(add) WP.ForRect(8, 7, 4, 4, true, add) end)
check(#pts == 20, "ForRect fills from reversed corners too")
pts = collect(function(add) WP.ForRect(3, 3, 3, 3, false, add) end)
check(#pts == 1, "ForRect degenerates to a single cell")

local outlinePts, outline = collect(function(add) WP.ForEllipse(10, 10, 20, 16, false, add) end)
local filledPts, filled = collect(function(add) WP.ForEllipse(10, 10, 20, 16, true, add) end)
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
pts = collect(function(add) WP.ForEllipse(5, 5, 5, 5, false, add) end)
check(#pts == 1, "ForEllipse degenerates to a single cell")

-- Flood fill -----------------------------------------------------------------

local fillCells = {}
for i = 1, Canvas.NUM_CELLS do
    fillCells[i] = 0
end
check(Canvas.FloodFill(fillCells, 1, 1, function() end) == Canvas.NUM_CELLS,
    "FloodFill covers a blank canvas exactly once")
-- Wall down column 32 splits the canvas; the left region is 31 columns wide.
for y = 1, Canvas.SIZE do
    fillCells[Canvas.Index(32, y)] = 5
end
check(Canvas.FloodFill(fillCells, 1, 1, function() end) == 31 * Canvas.SIZE,
    "FloodFill stops at a colour boundary")
check(Canvas.FloodFill(fillCells, 32, 1, function() end) == Canvas.SIZE,
    "FloodFill follows the wall itself")
check(Canvas.FloodFill(fillCells, 0, 1, function() end) == 0, "FloodFill rejects out-of-bounds seeds")

ok = true
for _, i in ipairs({ 1, 64, 65, 2048, Canvas.NUM_CELLS }) do
    local x, y = Canvas.Coords(i)
    if Canvas.Index(x, y) ~= i then
        ok = false
    end
end
check(ok, "Canvas.Coords inverts Canvas.Index")

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
C_ChatInfo = { RegisterAddonMessagePrefix = function() end, SendAddonMessage = function() end }
C_Timer = { NewTicker = function() end, After = function() end }

local noop = function() end
WP.Print = noop
WP.UI = setmetatable({}, { __index = function() return noop end })
WP.playerFullName = "Me-Testrealm"

loadModule("Comm.lua")
local Comm = WP.Comm

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
Comm:OnMessage("WoWPaint", "Maaaaaa:-Ann-Testrealm", "WHISPER", OTHER)
check(Portraits.IsMember(wire, "Ann-Testrealm"),
    "a plain member cannot uninvite anyone through roster gossip")
Comm:OnMessage("WoWPaint", "Maaaaaa:-Ann-Testrealm", "WHISPER", OWNER)
check(not Portraits.IsMember(wire, "Ann-Testrealm") and Portraits.IsRemoved(wire, "Ann-Testrealm"),
    "the owner's roster tombstone removes the member")
Comm:OnMessage("WoWPaint", "Maaaaaa:Ann-Testrealm", "WHISPER", OTHER)
check(not Portraits.IsMember(wire, "Ann-Testrealm"),
    "a stale peer's roster cannot resurrect the uninvited member")
Comm:OnMessage("WoWPaint", "Maaaaaa:+Ann-Testrealm", "WHISPER", OWNER)
check(Portraits.IsMember(wire, "Ann-Testrealm"), "the owner can lift a tombstone and re-add")

-- Locking is the owner's in both directions.
Comm:OnMessage("WoWPaint", "Laaaaaa", "WHISPER", OTHER)
check(not wire.locked, "a plain member cannot lock the portrait")
Comm:OnMessage("WoWPaint", "Laaaaaa", "WHISPER", OWNER)
check(wire.locked, "the owner can lock the portrait")
Comm:OnMessage("WoWPaint", "Uaaaaaa", "WHISPER", OTHER)
check(wire.locked, "a plain member cannot unlock the portrait")
Comm:OnMessage("WoWPaint", "Uaaaaaa", "WHISPER", OWNER)
check(not wire.locked, "the owner can unlock the portrait")

-- Locked canvases drop inbound paint, and only the owner answers with a nag.
wire.locked = true
local before = wire.cells[Canvas.Index(1, 1)]
Comm.queue = {}
Comm:OnMessage("WoWPaint", "Baaaaaa" .. WP.EncodeChar(0) .. WP.EncodeChar(0) .. WP.EncodeChar(5),
    "WHISPER", OTHER)
check(wire.cells[Canvas.Index(1, 1)] == before, "paint on a locked portrait is dropped")
check(sent("Laaaaaa") == nil, "a non-owner does not nag stale painters (its L is ignored anyway)")
wire.locked = false

-- Being uninvited drops the local copy, but only when the owner says so.
local victim = newShared("bbbbbb", OWNER, { OWNER, "Me-Testrealm" })
Comm:OnMessage("WoWPaint", "Kbbbbbb", "WHISPER", OTHER)
check(Portraits.Get("bbbbbb") ~= nil, "a stranger cannot uninvite us")
Comm:OnMessage("WoWPaint", "Kbbbbbb", "WHISPER", OWNER)
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

-- Batches are un-counted once each when a remote clear drops them, even when
-- two batches carry byte-identical ops.
local rev = Portraits.Create("Rev", "MEMBERS", "eeeeee", "Me-Testrealm")
Portraits.AddMembers(rev, { "Me-Testrealm", OWNER, OTHER })
Comm.queue = {}
local dup = WP.EncodeChar(0) .. WP.EncodeChar(0) .. WP.EncodeChar(5)
rev.rev = 2
Comm:Send(rev, "Beeeeee" .. dup, 101) -- two members => two queued copies each
Comm:Send(rev, "Beeeeee" .. dup, 102)
check(#Comm.queue == 4, "a MEMBERS batch is queued once per other member")
Comm:DropQueuedPaints("eeeeee")
check(#Comm.queue == 0, "a remote clear drops every queued copy")
check(rev.rev == 0, "each dropped batch un-counts exactly one revision")

--------------------------------------------------------------------------

if failures > 0 then
    print(("\n%d test(s) FAILED"):format(failures))
    os.exit(1)
end
print("\nAll tests passed.")
