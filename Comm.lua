local ADDON_NAME, WP = ...

local Canvas = WP.Canvas
local Portraits = WP.Portraits

local Comm = {}
WP.Comm = Comm

Comm.PREFIX = "WoWPaint"

-- One send per interval keeps worst-case throughput around 730 B/s, below
-- the ~800 B/s rate the chat server tolerates indefinitely.
local QUEUE_INTERVAL = 0.35
local FLUSH_INTERVAL = 0.5      -- how often locally painted pixels are sent
local MAX_OPS_PER_MSG = 76      -- 3 chars per op after "B" + 6-char id, < 240
local SNAP_CHUNK = 200          -- snapshot data characters per whisper
local OFFER_WINDOW = 3          -- seconds spent collecting snapshot offers
local SYNC_TIMEOUT = 15         -- abort when chunks stall this long mid-transfer
local SYNC_FIRST_TIMEOUT = 60   -- allowance for the first chunk: the source may
                                -- be streaming a full canvas to someone else
                                -- ahead of us in its send queue
local HELLO_MIN_INTERVAL = 60   -- per-portrait throttle for automatic hellos
local OFFER_MIN_INTERVAL = 30   -- per-target throttle for snapshot offers
local SNAP_MIN_INTERVAL = 30    -- per-requester throttle for snapshot streams
local LOCK_NAG_INTERVAL = 30    -- per-sender throttle for "it's locked" replies
local INVITE_TTL = 120          -- seconds an outgoing invite stays honorable

-- Each message type is only ever produced on one kind of channel; anything
-- arriving elsewhere is forged (e.g. a whispered clear from a stranger).
local BROADCAST_CHANNELS = { GUILD = true, PARTY = true, RAID = true, INSTANCE_CHAT = true }

Comm.queue = {}
Comm.pendingOps = {}          -- locally painted ops awaiting send
Comm.pendingPid = nil         -- portrait the pending ops belong to
Comm.inflight = {}            -- own broadcast B/C sent but not yet echoed back
Comm.bufferedEvents = {}      -- ordered B/C events deferred while syncing
Comm.lastHelloAt = {}         -- [pid] = time
Comm.lastOfferAt = {}         -- [pid..";"..sender] = time
Comm.lastSnapAt = {}          -- [pid..";"..sender] = time
Comm.lastRejectAt = {}        -- [pid..";"..sender] = time
Comm.lastLockNagAt = {}       -- [pid..";"..sender] = time
Comm.pendingInvites = {}      -- [pid..";"..target] = expiry time
Comm.sync = nil               -- active inbound snapshot transfer {pid, source, ...}
Comm.offerWindow = nil        -- open offer-collection window {pid, rev, sender}

function Comm:Init()
    C_ChatInfo.RegisterAddonMessagePrefix(self.PREFIX)
    self.sendTicker = C_Timer.NewTicker(QUEUE_INTERVAL, function()
        self:DrainQueue()
    end)
    self.flushTicker = C_Timer.NewTicker(FLUSH_INTERVAL, function()
        self:FlushPaintOps()
    end)
end

-- Resolve the chat type for a scope distribution mode. Battleground and
-- instance groups only deliver addon messages on INSTANCE_CHAT — the bare
-- "RAID"/"PARTY" chat types fail silently there.
function Comm:GetScopeChannel(mode)
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

-- `tag` identifies the logical batch an item belongs to. MEMBERS portraits
-- enqueue one copy of a batch per roster member, so anything that needs to
-- reason about batches (rather than messages) matches on the tag.
function Comm:Enqueue(msg, chatType, target, tag)
    self.queue[#self.queue + 1] = { msg = msg, chatType = chatType, target = target, tag = tag }
end

-- Route a message on a portrait's distribution: whisper fan-out to the
-- roster for MEMBERS portraits, scope broadcast otherwise. Returns false
-- when nothing could be sent.
function Comm:Send(p, msg, tag)
    if p.dist == "MEMBERS" then
        local me = WP.PlayerFullName()
        local sent = false
        for _, m in ipairs(p.members or {}) do
            if m ~= me then
                self:Whisper(msg, m, tag)
                sent = true
            end
        end
        return sent
    end
    local chatType = self:GetScopeChannel(p.dist)
    if not chatType then
        return false
    end
    self:Enqueue(msg, chatType, nil, tag)
    return true
end

function Comm:Whisper(msg, target, tag)
    self:Enqueue(msg, "WHISPER", target, tag)
end

function Comm:DrainQueue()
    local item = table.remove(self.queue, 1)
    if not item then
        return
    end
    -- Group broadcasts echo back to us in server serialization order; track
    -- our own B/C until the echo returns so races against remote clears can
    -- be resolved by the channel's total order (whispers never echo, so
    -- MEMBERS traffic is not tracked).
    if item.chatType ~= "WHISPER" then
        local kind = item.msg:sub(1, 1)
        if kind == "B" or kind == "C" then
            self.inflight[#self.inflight + 1] = {
                msg = item.msg,
                kind = kind,
                pid = item.msg:sub(2, 7),
                ops = kind == "B" and item.msg:sub(8) or nil,
                at = GetTime(),
            }
        end
    end
    C_ChatInfo.SendAddonMessage(self.PREFIX, item.msg, item.chatType, item.target)
    -- A send that silently failed never echoes; don't let its entry leak.
    while #self.inflight > 0 and GetTime() - self.inflight[1].at > 15 do
        table.remove(self.inflight, 1)
    end
end

-- Re-apply the pixels of our own sent-but-unechoed batches for a portrait.
-- Any such batch is serialized AFTER a clear we just received (in-order
-- delivery guarantees it), so peers will apply it after their clear too.
function Comm:ReapplyInflightOps(p)
    for _, e in ipairs(self.inflight) do
        if e.pid == p.id and e.kind == "B" then
            self:ApplyOps(p, e.ops)
        end
    end
end

-- Our own broadcast came back around: its position in the stream is the
-- authoritative order. B echoes just retire their tracking entry. A C echo
-- re-establishes the clear at its true position: everything of ours that is
-- still unechoed, still queued, or still unflushed was serialized (or will
-- be) after the clear, so it survives; anything remote that arrived between
-- our SendClear and this echo was serialized before it, so it stays wiped.
function Comm:OnOwnEcho(text)
    local inflight = self.inflight
    for i = 1, #inflight do
        if inflight[i].msg == text then
            local e = table.remove(inflight, i)
            if e.kind == "C" then
                local p = Portraits.Get(e.pid)
                if p then
                    Canvas.Clear(p.cells)
                    for j = i, #inflight do
                        local later = inflight[j]
                        if later.pid == e.pid and later.kind == "B" then
                            self:ApplyOps(p, later.ops)
                        end
                    end
                    for _, item in ipairs(self.queue) do
                        if item.chatType ~= "WHISPER" and item.msg:sub(1, 7) == "B" .. e.pid then
                            self:ApplyOps(p, item.msg:sub(8))
                        end
                    end
                    if self.pendingPid == e.pid and #self.pendingOps > 0 then
                        self:ApplyOps(p, table.concat(self.pendingOps))
                    end
                    WP.UI:RedrawAll()
                end
            end
            return
        end
    end
end

----------------------------------------------------------------------
-- Painting
----------------------------------------------------------------------

-- Entry point for the UI: apply a local paint immediately and queue it for
-- sending. Ops are batched per portrait; switching portraits flushes.
function Comm:Paint(p, x, y, color)
    if not WP.db or p.locked then
        return
    end
    if self.pendingPid and self.pendingPid ~= p.id then
        self:FlushPaintOps()
    end
    if Canvas.SetPixel(p.cells, x, y, color) then
        self.pendingPid = p.id
        WP.UI:UpdateCell(p, x, y)
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
    local pid = self.pendingPid
    local ops = table.concat(self.pendingOps)
    self.pendingOps = {}
    self.pendingPid = nil
    local p = pid and Portraits.Get(pid)
    if not p then
        return
    end
    self.batchSeq = (self.batchSeq or 0) + 1
    local tag = self.batchSeq
    self:Send(p, "B" .. pid .. ops, tag)
    if self.sync and self.sync.pid == pid then
        -- The snapshot in flight predates these strokes; defer both the
        -- replay AND the rev count to ReplayBuffered so our counter ends
        -- aligned with peers, who count this batch when it arrives.
        self.bufferedEvents[#self.bufferedEvents + 1] = { pid = pid, ops = ops, own = true, tag = tag }
    else
        p.rev = p.rev + 1
    end
    WP.UI:UpdateStatus()
end

-- Apply a string of 3-character (x, y, color) triples. Input is untrusted;
-- bad triples are skipped.
function Comm:ApplyOps(p, ops)
    for i = 1, #ops - 2, 3 do
        local x = WP.DecodeChar(ops:sub(i, i))
        local y = WP.DecodeChar(ops:sub(i + 1, i + 1))
        local c = WP.DecodeChar(ops:sub(i + 2, i + 2))
        if x and y and c and c < Canvas.NUM_COLORS then
            if Canvas.SetPixel(p.cells, x + 1, y + 1, c) then
                WP.UI:UpdateCell(p, x + 1, y + 1)
            end
        end
    end
end

function Comm:SendClear(p)
    if not WP.db or p.locked then
        return
    end
    -- A local clear supersedes any snapshot in flight for this portrait and
    -- everything deferred behind it.
    if self.sync and self.sync.pid == p.id then
        self.sync = nil
        self:DiscardBufferedFor(p.id)
    end
    -- Unflushed strokes predate the clear; sending them afterward would
    -- resurrect them on peers only. (Batches already in the send queue are
    -- fine: FIFO order delivers them before this C.)
    if self.pendingPid == p.id then
        self.pendingOps = {}
        self.pendingPid = nil
    end
    Canvas.Clear(p.cells)
    p.rev = p.rev + 1
    WP.UI:RedrawAll()
    self:Send(p, "C" .. p.id)
    WP.UI:UpdateStatus()
end

function Comm:DiscardBufferedFor(pid)
    for i = #self.bufferedEvents, 1, -1 do
        if self.bufferedEvents[i].pid == pid then
            table.remove(self.bufferedEvents, i)
        end
    end
end

-- A remote clear supersedes our paint batches for that portrait still
-- waiting in the send queue; peers have already cleared, so delivering
-- them later would resurrect strokes everywhere except here. MEMBERS
-- portraits enqueue one copy per roster member, so un-count once per
-- unique batch: batches counted at flush time get a decrement, batches
-- deferred mid-sync lose their replay entry instead. Batches are identified
-- by their send tag, not their payload: two separate batches can carry byte-
-- identical ops (paint a cell, erase it, paint it again), and collapsing them
-- would leave our rev counter above every peer's.
function Comm:DropQueuedPaints(pid)
    local prefix = "B" .. pid
    local queue = self.queue
    local dropped, order = {}, {}
    for i = #queue, 1, -1 do
        local item = queue[i]
        if item.msg:sub(1, 7) == prefix then
            local key = item.tag or item.msg
            if not dropped[key] then
                dropped[key] = item
                order[#order + 1] = key
            end
            table.remove(queue, i)
        end
    end
    local p = Portraits.Get(pid)
    for _, key in ipairs(order) do
        local item = dropped[key]
        local deferred = false
        for j = #self.bufferedEvents, 1, -1 do
            local ev = self.bufferedEvents[j]
            local same
            if item.tag then
                same = ev.tag == item.tag
            else
                same = ev.ops == item.msg:sub(8)
            end
            if ev.own and ev.pid == pid and same then
                table.remove(self.bufferedEvents, j)
                deferred = true
                break
            end
        end
        if not deferred and p and p.rev > 0 then
            p.rev = p.rev - 1
        end
    end
end

----------------------------------------------------------------------
-- Hello / snapshot negotiation (per portrait)
--
-- A joiner sends H<id>:<rev>. Peers that are ahead whisper an offer after
-- a small random delay; peers that are behind whisper Q<id>:<rev>, which
-- makes the joiner offer back to them (Q never triggers another Q, so
-- there are no loops). The joiner collects offers briefly, accepts the
-- highest revision with G, and receives the canvas as S chunks. One
-- inbound transfer runs at a time across all portraits.
----------------------------------------------------------------------

function Comm:SendHello(p, force)
    local now = GetTime()
    local last = self.lastHelloAt[p.id]
    if not force and last and now - last < HELLO_MIN_INTERVAL then
        return false
    end
    local sent = self:Send(p, "H" .. p.id .. ":" .. p.rev .. ":" .. WP.VERSION)
    if sent then
        self.lastHelloAt[p.id] = now
    end
    return sent
end

function Comm:HelloAll(force)
    for _, p in ipairs(Portraits.List()) do
        self:SendHello(p, force)
    end
end

function Comm:OnHello(p, rev, sender)
    if rev < p.rev then
        self:ScheduleOffer(p, sender)
    elseif rev > p.rev then
        self:Whisper("Q" .. p.id .. ":" .. p.rev, sender)
    end
end

function Comm:OnQuery(p, rev, sender)
    if rev < p.rev then
        self:ScheduleOffer(p, sender)
    end
end

function Comm:ScheduleOffer(p, sender)
    local now = GetTime()
    local key = p.id .. ";" .. sender
    local last = self.lastOfferAt[key]
    if last and now - last < OFFER_MIN_INTERVAL then
        return
    end
    self.lastOfferAt[key] = now
    local pid = p.id
    -- Random delay spreads out replies when many peers are ahead of the
    -- requester; the requester only accepts one offer anyway.
    C_Timer.After(0.5 + math.random() * 2, function()
        local cur = Portraits.Get(pid)
        if cur then
            self:Whisper("O" .. pid .. ":" .. cur.rev, sender)
        end
    end)
end

function Comm:OnOffer(p, rev, sender)
    if self.sync or rev <= p.rev then
        return
    end
    if not self.offerWindow then
        self.offerWindow = { pid = p.id }
        C_Timer.After(OFFER_WINDOW, function()
            self:AcceptBestOffer()
        end)
    end
    local w = self.offerWindow
    if w.pid ~= p.id then
        return -- one negotiation at a time; later hellos re-trigger
    end
    if not w.rev or rev > w.rev then
        w.rev = rev
        w.sender = sender
    end
end

function Comm:AcceptBestOffer()
    local w = self.offerWindow
    self.offerWindow = nil
    if not w or not w.sender or self.sync then
        return
    end
    local p = Portraits.Get(w.pid)
    if not p or w.rev <= p.rev then
        return
    end
    self.sync = {
        pid = p.id,
        source = w.sender,
        chunks = {},
        received = 0,
        total = nil,
        rev = nil,
        locked = nil,
        lastAt = GetTime(),
    }
    self:DiscardBufferedFor(p.id)
    self:Whisper("G" .. p.id, w.sender)
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

-- Tear down an inbound transfer that will not complete. Flushing first
-- matters: unflushed strokes painted after a buffered clear must land in
-- bufferedEvents AFTER that clear, or the replayed clear would wipe them
-- here while peers keep them.
function Comm:AbortSync(message)
    self:FlushPaintOps()
    self.sync = nil
    self:ReplayBuffered()
    WP.Print(message or "Canvas sync timed out.")
    WP.UI:UpdateStatus()
end

-- Apply B/C events that were deferred while a snapshot was in flight, in
-- their original order. Every replayed event counts one rev, mirroring
-- what every peer counted when the same event reached them.
function Comm:ReplayBuffered()
    local events = self.bufferedEvents
    self.bufferedEvents = {}
    for _, ev in ipairs(events) do
        local p = Portraits.Get(ev.pid)
        if p then
            if ev.clear then
                Canvas.Clear(p.cells)
                -- Our batches that were unechoed when this clear arrived
                -- were serialized after it; peers kept them.
                for _, ops in ipairs(ev.reapply or {}) do
                    self:ApplyOps(p, ops)
                end
                WP.UI:RedrawAll()
            elseif ev.ops then
                self:ApplyOps(p, ev.ops)
            end
            p.rev = p.rev + 1
        end
    end
end

function Comm:StreamSnapshot(p, target)
    local data = Canvas.Serialize(p.cells)
    local total = math.ceil(#data / SNAP_CHUNK)
    local flag = p.locked and "L" or "U"
    for i = 1, total do
        local chunk = data:sub((i - 1) * SNAP_CHUNK + 1, i * SNAP_CHUNK)
        self:Whisper(("S%s:%d:%d:%d:%s:%s"):format(p.id, i, total, p.rev, flag, chunk), target)
    end
end

function Comm:OnGet(p, sender)
    local now = GetTime()
    local key = p.id .. ";" .. sender
    local last = self.lastSnapAt[key]
    if last and now - last < SNAP_MIN_INTERVAL then
        -- Decline explicitly: a requester that committed to us after an
        -- earlier failed attempt would otherwise wait out its full
        -- first-chunk timeout on a stream that is never coming.
        local lastR = self.lastRejectAt[key]
        if not lastR or now - lastR > 5 then
            self.lastRejectAt[key] = now
            self:Whisper("R" .. p.id, sender)
        end
        return
    end
    self.lastSnapAt[key] = now
    self:StreamSnapshot(p, sender)
end

function Comm:OnSnapshotChunk(p, rest, sender)
    local s = self.sync
    if not s or s.pid ~= p.id or sender ~= s.source then
        return
    end
    local i, n, rev, flag, data = rest:match("^:(%d+):(%d+):(%d+):([LU]):(.*)$")
    i, n, rev = tonumber(i), tonumber(n), tonumber(rev)
    if not i or not n or not rev or n < 1 or i < 1 or i > n then
        return
    end
    if s.total and (n ~= s.total or rev ~= s.rev) then
        return
    end
    s.total, s.rev = n, rev
    s.locked = (flag == "L")
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
    -- Flush the unflushed stroke tail while sync is still set: it gets
    -- sent now and deferred into bufferedEvents, so the snapshot overwrite
    -- below cannot erase strokes that peers are about to apply.
    self:FlushPaintOps()
    self.sync = nil
    local p = Portraits.Get(s.pid)
    if p then
        local cells = Canvas.Deserialize(table.concat(s.chunks))
        if cells then
            for i = 1, Canvas.NUM_CELLS do
                p.cells[i] = cells[i]
            end
            p.rev = math.max(p.rev, s.rev)
            -- Adopt the source's lock state with its pixels, so late
            -- joiners and re-syncers learn about locks they missed.
            if s.locked and not p.locked and Portraits.Lockable(p) then
                p.locked = true
                p.lockedBy = p.lockedBy or s.source
            elseif s.locked == false and p.locked then
                p.locked = false
                p.lockedBy = nil
            end
            WP.UI:RedrawAll()
            WP.Print("Canvas synced from " .. Ambiguate(s.source, "short") .. ".")
        else
            WP.Print("Canvas sync failed (corrupt snapshot data); use /wowpaint sync to retry.")
        end
    end
    -- Batches that arrived mid-transfer may or may not already be in the
    -- snapshot; pixel ops are idempotent, so replaying them is safe.
    self:ReplayBuffered()
    WP.UI:UpdateAll()
end

----------------------------------------------------------------------
-- Invitations and roster
----------------------------------------------------------------------

function Comm:SendInvite(p, target)
    if p.dist ~= "MEMBERS" then
        return false, "Only member portraits can send invites (not the Shared canvas)."
    end
    target = WP.NormalizeName(target)
    if not target then
        return false, "No player name given."
    end
    if Portraits.IsMember(p, target) then
        return false, Ambiguate(target, "short") .. " is already a member."
    end
    if Portraits.IsRemoved(p, target) then
        -- Only the owner can undo their own uninvite; anyone else's re-invite
        -- would be filtered out by every peer's tombstone anyway.
        if not Portraits.IsOwner(p, WP.PlayerFullName()) then
            return false, Ambiguate(target, "short")
                .. " was uninvited by the creator - only they can bring them back."
        end
        Portraits.Unremove(p, target)
        self:Send(p, "M" .. p.id .. ":+" .. target)
    end
    if #(p.members or {}) >= Portraits.MAX_MEMBERS then
        return false, "This portrait is at its member limit."
    end
    local now = GetTime()
    -- Sweep invites that aged out, so a long session of inviting cannot grow
    -- the table without bound.
    for key, expiry in pairs(self.pendingInvites) do
        if now > expiry then
            self.pendingInvites[key] = nil
        end
    end
    self.pendingInvites[p.id .. ";" .. target] = now + INVITE_TTL
    self:Whisper("I" .. p.id .. ":" .. (p.owner or "") .. ":" .. p.name, target)
    return true
end

function Comm:OnInvite(id, rest, sender)
    if Portraits.Get(id) then
        return -- we already have this portrait
    end
    local owner, name = rest:match("^:(.-):(.*)$")
    if not owner then
        return
    end
    name = Portraits.SanitizeName(name)
    if name == "" then
        name = "Untitled"
    end
    WP.UI:ShowInvitePopup({
        id = id,
        name = name,
        owner = WP.NormalizeName(owner ~= "" and owner or sender),
        from = sender,
    })
end

-- Called by the UI when the player accepts an invitation.
function Comm:AcceptInvite(data)
    if Portraits.Get(data.id) then
        return
    end
    local p = Portraits.Create(data.name, "MEMBERS", data.id, data.owner)
    -- Roster stub: us, the inviter, and the owner. The full roster arrives
    -- in the inviter's M message moments later. Built by appending rather
    -- than as a literal: a nil in the middle would truncate the ipairs walk
    -- and leave us with a roster that trusts nobody.
    local roster = {}
    for _, name in ipairs({ WP.PlayerFullName() or false, data.from or false, data.owner or false }) do
        if name then
            roster[#roster + 1] = name
        end
    end
    Portraits.AddMembers(p, roster)
    self:Whisper("J" .. p.id, data.from)
    Portraits.SetActive(p.id)
    WP.Print("Joined portrait '" .. p.name .. "'. Syncing from " .. Ambiguate(data.from, "short") .. "...")
    WP.UI:UpdateAll()
end

function Comm:OnJoin(p, sender)
    local key = p.id .. ";" .. sender
    local expiry = self.pendingInvites[key]
    if not expiry or GetTime() > expiry then
        return
    end
    self.pendingInvites[key] = nil
    Portraits.AddMembers(p, { sender })
    self:SendRoster(p)
    -- Offer rather than streaming blind: the standard offer/G/S flow gives
    -- the joiner its usual guards, timeouts, and single-transfer rule.
    if p.rev > 0 then
        self:Whisper("O" .. p.id .. ":" .. p.rev, sender)
    end
    WP.Print(Ambiguate(sender, "short") .. " joined portrait '" .. p.name .. "'.")
    WP.UI:UpdateAll()
end

-- Whisper the full roster to every member, chunked under the payload cap.
-- Union-merge semantics make chunk boundaries harmless. Tokens are plain
-- names to add and "-name" tombstones to remove; only the owner's tombstones
-- are honored, so only the owner spends bytes on them.
function Comm:SendRoster(p)
    if p.dist ~= "MEMBERS" or not p.members then
        return
    end
    local tokens = {}
    for _, m in ipairs(p.members) do
        tokens[#tokens + 1] = m
    end
    if Portraits.IsOwner(p, WP.PlayerFullName()) then
        for _, m in ipairs(p.removed or {}) do
            tokens[#tokens + 1] = "-" .. m
        end
    end
    local base = "M" .. p.id .. ":"
    local cur, curLen = {}, #base
    for _, m in ipairs(tokens) do
        local addLen = #m + (#cur > 0 and 1 or 0)
        if curLen + addLen > 235 and #cur > 0 then
            self:Send(p, base .. table.concat(cur, ","))
            cur, curLen = {}, #base
            addLen = #m
        end
        cur[#cur + 1] = m
        curLen = curLen + addLen
    end
    if #cur > 0 then
        self:Send(p, base .. table.concat(cur, ","))
    end
end

-- Tokens: "name" adds, "-name" tombstones, "+name" lifts a tombstone. Real
-- character names never start with either mark, so the grammar is
-- unambiguous. Removals and revocations are honored from the owner only.
function Comm:OnRoster(p, rest, sender)
    local csv = rest:match("^:(.*)$")
    if not csv then
        return
    end
    local fromOwner = Portraits.IsOwner(p, sender)
    local add, remove = {}, {}
    local changed = false
    for token in csv:gmatch("[^,]+") do
        local mark = token:sub(1, 1)
        if mark == "-" then
            if fromOwner then
                remove[#remove + 1] = token:sub(2)
            end
        elseif mark == "+" then
            if fromOwner then
                local name = token:sub(2)
                if Portraits.Unremove(p, name) then
                    changed = true
                end
                add[#add + 1] = name
            end
        else
            add[#add + 1] = token
        end
    end
    -- Adds first, then removals: a message carrying both marks for one name
    -- must leave that name off the roster.
    if Portraits.AddMembers(p, add) then
        changed = true
    end
    if #remove > 0 then
        local me = WP.PlayerFullName()
        for _, name in ipairs(remove) do
            if name == me then
                return self:OnKick(p, sender)
            end
        end
        if Portraits.RemoveMembers(p, remove) then
            changed = true
        end
    end
    if changed then
        WP.UI:UpdateAll()
    end
end

----------------------------------------------------------------------
-- Uninvite (owner only)
----------------------------------------------------------------------

function Comm:SendKick(p, name)
    if p.dist ~= "MEMBERS" then
        return false, "The Shared canvas has no roster to remove anyone from."
    end
    if not Portraits.IsOwner(p, WP.PlayerFullName()) then
        return false, "Only the portrait's creator can uninvite members."
    end
    name = WP.NormalizeName(name)
    if not name then
        return false, "No player name given."
    end
    if Portraits.IsOwner(p, name) then
        return false, "The creator cannot be uninvited."
    end
    if not Portraits.IsMember(p, name) then
        return false, Ambiguate(name, "short") .. " is not a member of '" .. p.name .. "'."
    end
    -- Tell them before dropping them: once they are off the roster, Send no
    -- longer routes anything their way.
    self:Whisper("K" .. p.id, name)
    self.pendingInvites[p.id .. ";" .. name] = nil
    Portraits.RemoveMembers(p, { name })
    self:SendRoster(p)
    WP.UI:UpdateAll()
    return true
end

-- We were uninvited: the portrait is no longer ours to paint, so drop the
-- local copy. Anything still whispered at us for that id is ignored from
-- here on (unknown portrait).
function Comm:OnKick(p, sender)
    if not Portraits.IsOwner(p, sender) then
        return
    end
    local name = p.name
    if Portraits.Delete(p.id) then
        WP.Print("You were removed from portrait '" .. name .. "' by its creator.")
        WP.UI:UpdateAll()
    end
end

----------------------------------------------------------------------
-- Locking
----------------------------------------------------------------------

-- UI restricts lock/unlock to the owner; receivers enforce trust rules.
function Comm:SendLockState(p, locked)
    if not Portraits.Lockable(p) then
        return
    end
    if locked then
        -- Strokes not yet sent would be rejected by peers once the lock
        -- lands; flush them ahead of the L so FIFO delivers paint-then-lock.
        self:FlushPaintOps()
    end
    p.locked = locked
    p.lockedBy = locked and WP.PlayerFullName() or nil
    self:Send(p, (locked and "L" or "U") .. p.id)
    WP.UI:UpdateAll()
end

-- Lock state is the owner's alone, in both directions. An earlier design let
-- any member relay a lock so stale painters converged without the owner
-- online; that also let a straggler who missed an unlock drag the owner back
-- into it, and it handed every member a freeze button. Members that are
-- locked simply drop inbound paints now, so a straggler diverges from nobody.
function Comm:OnLock(p, sender)
    if not Portraits.Lockable(p) or not Portraits.IsOwner(p, sender) then
        return
    end
    if not p.locked then
        p.locked = true
        p.lockedBy = sender
        WP.Print("Portrait '" .. p.name .. "' was locked by " .. Ambiguate(sender, "short") .. ".")
        WP.UI:UpdateAll()
    end
end

function Comm:OnUnlock(p, sender)
    if not Portraits.Lockable(p) or not Portraits.IsOwner(p, sender) then
        return
    end
    if p.locked then
        p.locked = false
        p.lockedBy = nil
        WP.Print("Portrait '" .. p.name .. "' was unlocked by its owner.")
        WP.UI:UpdateAll()
    end
end

-- A paint/clear arrived for a locked portrait: the sender evidently missed
-- the lock. The ops are dropped either way; only the owner can usefully say
-- so, since only the owner's L is honored.
function Comm:NagLocked(p, sender)
    if not Portraits.IsOwner(p, WP.PlayerFullName()) then
        return
    end
    local now = GetTime()
    local key = p.id .. ";" .. sender
    local last = self.lastLockNagAt[key]
    if not last or now - last > LOCK_NAG_INTERVAL then
        self.lastLockNagAt[key] = now
        self:Whisper("L" .. p.id, sender)
    end
end

----------------------------------------------------------------------
-- Inbound dispatch
----------------------------------------------------------------------

function Comm:OnMessage(prefix, text, channel, sender)
    if prefix ~= self.PREFIX or type(text) ~= "string" or #text < 7 or not WP.db then
        return
    end
    if WP.IsSelf(sender) then
        local kind = text:sub(1, 1)
        if kind == "B" or kind == "C" then
            self:OnOwnEcho(text)
        end
        return
    end
    local kind = text:sub(1, 1)
    local id = text:sub(2, 7)
    if not Portraits.ValidId(id) then
        return
    end
    local rest = text:sub(8)
    sender = WP.NormalizeName(sender)
    if not sender then
        return
    end

    -- Invitations may arrive for portraits we do not have yet, from
    -- players we do not know. Everything else requires a known portrait.
    if kind == "I" then
        if channel == "WHISPER" then
            self:OnInvite(id, rest, sender)
        end
        return
    end
    local p = Portraits.Get(id)
    if not p then
        return
    end
    if kind == "J" then
        if channel == "WHISPER" and p.dist == "MEMBERS" then
            self:OnJoin(p, sender)
        end
        return
    end

    -- Trust and channel enforcement. MEMBERS portraits: whispers from
    -- roster members only. Scope portraits: B/C/H on group broadcasts,
    -- sync negotiation on whispers, and no roster/lock messages at all.
    if p.dist == "MEMBERS" then
        if channel ~= "WHISPER" or not Portraits.IsMember(p, sender) then
            return
        end
    else
        if kind == "M" or kind == "L" or kind == "U" or kind == "K" then
            return
        end
        if kind == "B" or kind == "C" or kind == "H" then
            if not BROADCAST_CHANNELS[channel] then
                return
            end
        elseif channel ~= "WHISPER" then
            return
        end
    end

    if kind == "B" then
        if #rest == 0 or #rest % 3 ~= 0 then
            return
        end
        if p.locked then
            self:NagLocked(p, sender)
            return
        end
        if self.sync and self.sync.pid == p.id then
            self.bufferedEvents[#self.bufferedEvents + 1] = { pid = p.id, ops = rest }
            return
        end
        self:ApplyOps(p, rest)
        p.rev = p.rev + 1
        WP.UI:UpdateStatus()
    elseif kind == "C" then
        if p.locked then
            self:NagLocked(p, sender)
            return
        end
        self:DropQueuedPaints(p.id)
        if self.pendingPid == p.id then
            self.pendingOps = {}
            self.pendingPid = nil
        end
        if self.sync and self.sync.pid == p.id then
            -- Defer alongside batches so the snapshot in flight cannot
            -- resurrect the canvas this clear just wiped everywhere else.
            -- Capture our sent-but-unechoed batches now: they were
            -- serialized after this clear and must survive its replay.
            local reapply = {}
            for _, e in ipairs(self.inflight) do
                if e.pid == p.id and e.kind == "B" then
                    reapply[#reapply + 1] = e.ops
                end
            end
            self.bufferedEvents[#self.bufferedEvents + 1] =
                { pid = p.id, clear = true, reapply = reapply }
        else
            Canvas.Clear(p.cells)
            p.rev = p.rev + 1
            -- Our own unechoed batches were serialized after this clear;
            -- peers keep them, so must we.
            self:ReapplyInflightOps(p)
            WP.UI:RedrawAll()
            WP.UI:UpdateStatus()
        end
        WP.Print(Ambiguate(sender, "short") .. " cleared portrait '" .. p.name .. "'.")
    elseif kind == "H" then
        local rev = tonumber(rest:match("^:(%d+)"))
        if rev then
            self:OnHello(p, rev, sender)
        end
    elseif kind == "Q" then
        local rev = tonumber(rest:match("^:(%d+)"))
        if rev then
            self:OnQuery(p, rev, sender)
        end
    elseif kind == "O" then
        local rev = tonumber(rest:match("^:(%d+)"))
        if rev then
            self:OnOffer(p, rev, sender)
        end
    elseif kind == "G" then
        self:OnGet(p, sender)
    elseif kind == "S" then
        self:OnSnapshotChunk(p, rest, sender)
    elseif kind == "R" then
        -- Our snapshot request was declined (source-side throttle). Only
        -- honor it from the source we committed to, and only before any
        -- chunk arrived — a stream in progress is not abandoned for this.
        local s = self.sync
        if s and s.pid == p.id and sender == s.source and s.received == 0 then
            self:AbortSync("Canvas sync declined by source; use /wowpaint sync to retry in a moment.")
        end
    elseif kind == "M" then
        self:OnRoster(p, rest, sender)
    elseif kind == "L" then
        self:OnLock(p, sender)
    elseif kind == "U" then
        self:OnUnlock(p, sender)
    elseif kind == "K" then
        self:OnKick(p, sender)
    end
end
