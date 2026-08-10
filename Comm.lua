local ADDON_NAME, WP = ...

local Canvas = WP.Canvas

local Comm = {}
WP.Comm = Comm

Comm.PREFIX = "WoWPaint"

-- One send per interval keeps worst-case throughput around 730 B/s, below
-- the ~800 B/s rate the chat server tolerates indefinitely.
local QUEUE_INTERVAL = 0.35
local FLUSH_INTERVAL = 0.5      -- how often locally painted pixels are broadcast
local MAX_OPS_PER_MSG = 78      -- 3 chars per op; keeps total payload under 240
local SNAP_CHUNK = 200          -- snapshot data characters per whisper
local OFFER_WINDOW = 3          -- seconds spent collecting snapshot offers
local SYNC_TIMEOUT = 15         -- abort when chunks stall this long mid-transfer
local SYNC_FIRST_TIMEOUT = 60   -- allowance for the first chunk: the source may
                                -- be streaming a full canvas to someone else
                                -- ahead of us in its send queue
local HELLO_MIN_INTERVAL = 60   -- throttle for automatic hello broadcasts
local OFFER_MIN_INTERVAL = 30   -- per-target throttle for snapshot offers
local SNAP_MIN_INTERVAL = 30    -- per-requester throttle for snapshot streams

-- Each message type is only ever produced on one kind of channel; anything
-- arriving elsewhere is forged (e.g. a whispered clear from a stranger).
local BROADCAST_CHANNELS = { GUILD = true, PARTY = true, RAID = true, INSTANCE_CHAT = true }

Comm.queue = {}
Comm.pendingOps = {}          -- locally painted ops awaiting broadcast
Comm.bufferedEvents = {}      -- ordered B/C events deferred while syncing
Comm.lastOfferAt = {}
Comm.lastSnapAt = {}
Comm.sync = nil               -- active inbound snapshot transfer
Comm.offerWindow = nil        -- open offer-collection window

function Comm:Init()
    C_ChatInfo.RegisterAddonMessagePrefix(self.PREFIX)
    self.sendTicker = C_Timer.NewTicker(QUEUE_INTERVAL, function()
        self:DrainQueue()
    end)
    self.flushTicker = C_Timer.NewTicker(FLUSH_INTERVAL, function()
        self:FlushPaintOps()
    end)
end

-- Resolve the chat type to broadcast on, honoring the user's pinned scope.
-- Returns nil when the pinned (or any) scope is unavailable. Battleground
-- and instance groups only deliver addon messages on INSTANCE_CHAT — the
-- bare "RAID"/"PARTY" chat types fail silently there — so instance-category
-- membership is checked explicitly.
function Comm:GetDistribution()
    local mode = WP.db and WP.db.channel or "AUTO"
    local inInstanceGroup = IsInGroup(LE_PARTY_CATEGORY_INSTANCE)
    if mode == "GUILD" then
        return IsInGuild() and "GUILD" or nil
    elseif mode == "RAID" then
        if IsInRaid(LE_PARTY_CATEGORY_HOME) then
            return "RAID"
        end
        return inInstanceGroup and "INSTANCE_CHAT" or nil
    elseif mode == "PARTY" then
        if IsInGroup(LE_PARTY_CATEGORY_HOME) then
            return "PARTY"
        end
        return inInstanceGroup and "INSTANCE_CHAT" or nil
    end
    if inInstanceGroup then
        return "INSTANCE_CHAT"
    elseif IsInRaid(LE_PARTY_CATEGORY_HOME) then
        return "RAID"
    elseif IsInGroup(LE_PARTY_CATEGORY_HOME) then
        return "PARTY"
    elseif IsInGuild() then
        return "GUILD"
    end
    return nil
end

function Comm:Enqueue(msg, chatType, target)
    self.queue[#self.queue + 1] = { msg = msg, chatType = chatType, target = target }
end

function Comm:Broadcast(msg)
    local dist = self:GetDistribution()
    if not dist then
        return false
    end
    self:Enqueue(msg, dist)
    return true
end

function Comm:Whisper(msg, target)
    self:Enqueue(msg, "WHISPER", target)
end

function Comm:DrainQueue()
    local item = table.remove(self.queue, 1)
    if not item then
        return
    end
    C_ChatInfo.SendAddonMessage(self.PREFIX, item.msg, item.chatType, item.target)
end

----------------------------------------------------------------------
-- Painting
----------------------------------------------------------------------

-- Entry point for the UI: apply a local paint immediately and queue it for
-- broadcast.
function Comm:Paint(x, y, color)
    if not WP.db then
        return
    end
    if Canvas.SetPixel(WP.db.cells, x, y, color) then
        WP.UI:UpdateCell(x, y)
        self.pendingOps[#self.pendingOps + 1] =
            WP.EncodeChar(x - 1) .. WP.EncodeChar(y - 1) .. WP.EncodeChar(color)
        if #self.pendingOps >= MAX_OPS_PER_MSG then
            self:FlushPaintOps()
        end
    end
end

function Comm:FlushPaintOps()
    if #self.pendingOps == 0 then
        return
    end
    local ops = table.concat(self.pendingOps)
    self.pendingOps = {}
    WP.db.rev = WP.db.rev + 1
    self:Broadcast("B" .. ops)
    if self.sync then
        -- The snapshot in flight predates these strokes; re-apply them on
        -- top of it once it lands. rev was already counted at flush time,
        -- so the replay must not count it again.
        self.bufferedEvents[#self.bufferedEvents + 1] = { ops = ops, own = true }
    end
    WP.UI:UpdateStatus()
end

-- Apply a string of 3-character (x, y, color) triples. Input is untrusted;
-- bad triples are skipped.
function Comm:ApplyOps(ops)
    for i = 1, #ops - 2, 3 do
        local x = WP.DecodeChar(ops:sub(i, i))
        local y = WP.DecodeChar(ops:sub(i + 1, i + 1))
        local c = WP.DecodeChar(ops:sub(i + 2, i + 2))
        if x and y and c and c < Canvas.NUM_COLORS then
            if Canvas.SetPixel(WP.db.cells, x + 1, y + 1, c) then
                WP.UI:UpdateCell(x + 1, y + 1)
            end
        end
    end
end

function Comm:SendClear()
    if not WP.db then
        return
    end
    -- Unflushed strokes predate the clear; broadcasting them afterward
    -- would resurrect them on peers only.
    self.pendingOps = {}
    Canvas.Clear(WP.db.cells)
    WP.db.rev = WP.db.rev + 1
    WP.UI:RedrawAll()
    self:Broadcast("C")
    WP.UI:UpdateStatus()
end

----------------------------------------------------------------------
-- Hello / snapshot negotiation
--
-- A joiner broadcasts H:<rev>. Peers that are ahead whisper an offer after
-- a small random delay; peers that are behind whisper Q:<rev>, which makes
-- the joiner offer back to them (Q never triggers another Q, so there are
-- no loops). The joiner collects offers briefly, accepts the highest
-- revision with G, and receives the canvas as S: chunks over whisper.
----------------------------------------------------------------------

function Comm:SendHello(force)
    local now = GetTime()
    if not force and self.lastHelloAt and now - self.lastHelloAt < HELLO_MIN_INTERVAL then
        return false
    end
    local sent = self:Broadcast("H:" .. WP.db.rev .. ":" .. WP.VERSION)
    if sent then
        self.lastHelloAt = now
    end
    return sent
end

function Comm:OnHello(rev, sender)
    if rev < WP.db.rev then
        self:ScheduleOffer(sender)
    elseif rev > WP.db.rev then
        self:Whisper("Q:" .. WP.db.rev, sender)
    end
end

function Comm:OnQuery(rev, sender)
    if rev < WP.db.rev then
        self:ScheduleOffer(sender)
    end
end

function Comm:ScheduleOffer(sender)
    local now = GetTime()
    local last = self.lastOfferAt[sender]
    if last and now - last < OFFER_MIN_INTERVAL then
        return
    end
    self.lastOfferAt[sender] = now
    -- Random delay spreads out replies when many peers are ahead of the
    -- requester; the requester only accepts one offer anyway.
    C_Timer.After(0.5 + math.random() * 2, function()
        self:Whisper("O:" .. WP.db.rev, sender)
    end)
end

function Comm:OnOffer(rev, sender)
    if self.sync or rev <= WP.db.rev then
        return
    end
    if not self.offerWindow then
        self.offerWindow = {}
        C_Timer.After(OFFER_WINDOW, function()
            self:AcceptBestOffer()
        end)
    end
    local w = self.offerWindow
    if not w.rev or rev > w.rev then
        w.rev = rev
        w.sender = sender
    end
end

function Comm:AcceptBestOffer()
    local w = self.offerWindow
    self.offerWindow = nil
    if not w or not w.sender or self.sync or w.rev <= WP.db.rev then
        return
    end
    self.sync = {
        source = w.sender,
        chunks = {},
        received = 0,
        total = nil,
        rev = nil,
        lastAt = GetTime(),
    }
    self.bufferedEvents = {}
    self:Whisper("G", w.sender)
    WP.UI:UpdateStatus()
    self:WatchSync()
end

function Comm:WatchSync()
    C_Timer.After(5, function()
        local s = self.sync
        if not s then
            return
        end
        -- Before the first chunk arrives, the source may still be draining
        -- another requester's snapshot through its throttled queue, so give
        -- it much longer than the between-chunk stall limit.
        local limit = s.received == 0 and SYNC_FIRST_TIMEOUT or SYNC_TIMEOUT
        if GetTime() - s.lastAt >= limit then
            self:AbortSync()
        else
            self:WatchSync()
        end
    end)
end

function Comm:AbortSync()
    self.sync = nil
    self:ReplayBuffered()
    WP.Print("Canvas sync timed out.")
    WP.UI:UpdateStatus()
end

-- Apply B/C events that arrived while a snapshot was in flight, in their
-- original order. Remote events still owe a rev bump; our own flushed
-- batches (own = true) were counted when they were sent.
function Comm:ReplayBuffered()
    local events = self.bufferedEvents
    self.bufferedEvents = {}
    for _, ev in ipairs(events) do
        if ev.clear then
            Canvas.Clear(WP.db.cells)
            WP.UI:RedrawAll()
            WP.db.rev = WP.db.rev + 1
        elseif ev.ops then
            self:ApplyOps(ev.ops)
            if not ev.own then
                WP.db.rev = WP.db.rev + 1
            end
        end
    end
end

function Comm:OnGet(sender)
    local now = GetTime()
    local last = self.lastSnapAt[sender]
    if last and now - last < SNAP_MIN_INTERVAL then
        return
    end
    self.lastSnapAt[sender] = now
    local data = Canvas.Serialize(WP.db.cells)
    local total = math.ceil(#data / SNAP_CHUNK)
    local rev = WP.db.rev
    for i = 1, total do
        local chunk = data:sub((i - 1) * SNAP_CHUNK + 1, i * SNAP_CHUNK)
        self:Whisper(("S:%d:%d:%d:%s"):format(i, total, rev, chunk), sender)
    end
end

function Comm:OnSnapshotChunk(text, sender)
    local s = self.sync
    if not s or sender ~= s.source then
        return
    end
    local i, n, rev, data = text:match("^S:(%d+):(%d+):(%d+):(.*)$")
    i, n, rev = tonumber(i), tonumber(n), tonumber(rev)
    if not i or not n or not rev or n < 1 or i < 1 or i > n then
        return
    end
    if s.total and (n ~= s.total or rev ~= s.rev) then
        return
    end
    s.total, s.rev = n, rev
    if not s.chunks[i] then
        s.chunks[i] = data
        s.received = s.received + 1
    end
    s.lastAt = GetTime()
    if s.received == s.total then
        self:FinishSync()
    end
end

function Comm:FinishSync()
    local s = self.sync
    self.sync = nil
    local cells = Canvas.Deserialize(table.concat(s.chunks))
    if cells then
        for i = 1, Canvas.NUM_CELLS do
            WP.db.cells[i] = cells[i]
        end
        WP.db.rev = math.max(WP.db.rev, s.rev)
        WP.UI:RedrawAll()
        WP.Print("Canvas synced from " .. Ambiguate(s.source, "short") .. ".")
    end
    -- Batches that arrived mid-transfer may or may not already be in the
    -- snapshot; pixel ops are idempotent, so replaying them is safe.
    self:ReplayBuffered()
    WP.UI:UpdateStatus()
end

----------------------------------------------------------------------
-- Inbound dispatch
----------------------------------------------------------------------

function Comm:OnMessage(prefix, text, channel, sender)
    if prefix ~= self.PREFIX or type(text) ~= "string" or not WP.db then
        return
    end
    if WP.IsSelf(sender) then
        return
    end
    local kind = text:sub(1, 1)
    -- B/C/H only ever travel on group broadcasts and Q/O/G/S only on
    -- whispers; enforcing that stops strangers outside the scope from
    -- whispering forged paints/clears or triggering snapshot streams via a
    -- group channel.
    if kind == "B" or kind == "C" or kind == "H" then
        if not BROADCAST_CHANNELS[channel] then
            return
        end
    elseif channel ~= "WHISPER" then
        return
    end
    if kind == "B" then
        local ops = text:sub(2)
        if #ops == 0 or #ops % 3 ~= 0 then
            return
        end
        if self.sync then
            self.bufferedEvents[#self.bufferedEvents + 1] = { ops = ops }
            return
        end
        self:ApplyOps(ops)
        WP.db.rev = WP.db.rev + 1
        WP.UI:UpdateStatus()
    elseif kind == "C" then
        self.pendingOps = {}
        if self.sync then
            -- Defer alongside batches so the snapshot in flight cannot
            -- resurrect the canvas this clear just wiped everywhere else.
            self.bufferedEvents[#self.bufferedEvents + 1] = { clear = true }
        else
            Canvas.Clear(WP.db.cells)
            WP.db.rev = WP.db.rev + 1
            WP.UI:RedrawAll()
            WP.UI:UpdateStatus()
        end
        WP.Print(Ambiguate(sender, "short") .. " cleared the canvas.")
    elseif kind == "H" then
        local rev = tonumber(text:match("^H:(%d+)"))
        if rev then
            self:OnHello(rev, sender)
        end
    elseif kind == "Q" then
        local rev = tonumber(text:match("^Q:(%d+)"))
        if rev then
            self:OnQuery(rev, sender)
        end
    elseif kind == "O" then
        local rev = tonumber(text:match("^O:(%d+)"))
        if rev then
            self:OnOffer(rev, sender)
        end
    elseif kind == "G" then
        self:OnGet(sender)
    elseif kind == "S" then
        self:OnSnapshotChunk(text, sender)
    end
end
