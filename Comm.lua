local ADDON_NAME, PP = ...

local Canvas = PP.Canvas
local Portraits = PP.Portraits

local Comm = {}
PP.Comm = Comm

Comm.PREFIX = "PixelParty"

-- One send per interval keeps worst-case throughput around 730 B/s, below
-- the ~800 B/s rate the chat server tolerates indefinitely.
local QUEUE_INTERVAL = 0.35
local FLUSH_INTERVAL = 0.5      -- how often locally painted pixels are sent
-- Ops per batch, per op width: both land at <= 240 chars after the "B"
-- and the 6-char portrait id, inside the 255-byte payload cap.
local MAX_OPS = { [3] = 76, [5] = 48 }
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
local SIZE_WARN_INTERVAL = 300  -- per-sender throttle for canvas-size mismatch nags
local COLOR_WARN_INTERVAL = 300 -- per-sender throttle for old-version color nags
local INVITE_TTL = 120          -- seconds an outgoing invite stays honorable
Comm.INVITE_TTL = INVITE_TTL    -- exported for Core's SavedVariables sanitizer

-- Each message type is only ever produced on one kind of channel; anything
-- arriving elsewhere is forged (e.g. a whispered clear from a stranger).
local BROADCAST_CHANNELS = { GUILD = true, PARTY = true, RAID = true, INSTANCE_CHAT = true }

-- Resolved at call time, not load time: the name moved to C_BattleNet in
-- later API versions and is absent entirely on clients without it, in which
-- case everything falls back to the chat transport.
local function BNetSender()
    return (C_BattleNet and C_BattleNet.SendGameData) or BNSendGameData
end

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
Comm.lastSizeWarnAt = {}      -- [pid..";"..sender] = time
Comm.legacyColorPeers = {}    -- [pid] = { [sender] = true } for pre-0.7 hellos
Comm.lastColorWarnAt = {}     -- [pid..";"..sender] = time
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
        local me = PP.PlayerFullName()
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
    if BROADCAST_CHANNELS[item.chatType] then
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
    if item.chatType == "BNET" then
        local send = BNetSender()
        if send then
            send(item.target, self.PREFIX, item.msg)
        end
    else
        C_ChatInfo.SendAddonMessage(self.PREFIX, item.msg, item.chatType, item.target)
    end
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
                    Canvas.Clear(p.size, p.cells)
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
                    PP.UI:RedrawAll()
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
    if not PP.db or p.locked then
        return
    end
    if self.pendingPid and self.pendingPid ~= p.id then
        self:FlushPaintOps()
    end
    if Canvas.SetPixel(p.size, p.cells, x, y, color) then
        if color >= Canvas.EXTENDED_BASE then
            self:WarnLegacyColors(p)
        end
        self.pendingPid = p.id
        PP.UI:UpdateCell(p, x, y)
        self.pendingOps[#self.pendingOps + 1] = PP.EncodeOp(p.size, x, y, color)
        if #self.pendingOps >= MAX_OPS[PP.OpWidth(p.size)] then
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
    PP.UI:UpdateStatus()
end

-- Apply a string of 3-character (x, y, color) triples. Input is untrusted;
-- bad triples are skipped.
function Comm:ApplyOps(p, ops)
    local width = PP.OpWidth(p.size)
    for i = 1, #ops - width + 1, width do
        local x, y, c = PP.DecodeOp(p.size, ops, i)
        if x and c < Canvas.NUM_COLORS then
            if Canvas.SetPixel(p.size, p.cells, x, y, c) then
                PP.UI:UpdateCell(p, x, y)
            end
        end
    end
end

function Comm:SendClear(p)
    if not PP.db or p.locked then
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
    Canvas.Clear(p.size, p.cells)
    p.rev = p.rev + 1
    PP.UI:RedrawAll()
    self:Send(p, "C" .. p.id)
    PP.UI:UpdateStatus()
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
    local sent = self:Send(p, "H" .. p.id .. ":" .. p.rev .. ":" .. PP.VERSION .. ":" .. p.size)
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

-- A peer announcing a different size for the same portrait id is running an
-- addon version that disagrees with ours about it. Ops would decode into
-- nonsense, so say so once in a while rather than silently scribbling.
function Comm:WarnSizeMismatch(p, theirSize, sender)
    if theirSize == p.size then
        return
    end
    if theirSize == nil and p.size == Canvas.DEFAULT_SIZE then
        return -- an older client on a 64 canvas is fully compatible
    end
    local now = GetTime()
    local key = p.id .. ";" .. sender
    local last = self.lastSizeWarnAt[key]
    if last and now - last < SIZE_WARN_INTERVAL then
        return
    end
    self.lastSizeWarnAt[key] = now
    PP.Print(("%s sees '%s' as a %s canvas, you see %d. They need the same addon version; paint will not line up until then."):format(
        Ambiguate(sender, "short"), p.name,
        theirSize and (theirSize .. "x" .. theirSize) or "64x64 (older version)", p.size))
end

-- A peer announcing a pre-0.7 version cannot see the wheel colors: its op
-- loop skips them (each cell keeps whatever was painted there before) and
-- its snapshot decoder rejects any canvas containing one. Remember every
-- such peer per portrait — an upgrade hello clears only its own sender, so
-- one peer updating cannot hide another that has not — and say so,
-- throttled like size mismatches, whenever wheel colors and a legacy peer
-- actually meet: here when the canvas already has one, and from Paint when
-- one is used. Best effort by construction: it only knows peers whose
-- hello arrived this session, so a legacy peer at equal revision that
-- never hellos stays invisible.
function Comm:NoteColorSupport(p, version, sender)
    local peers = self.legacyColorPeers[p.id]
    if PP.VersionAtLeast(version, 0, 7) then
        if peers then
            peers[sender] = nil
        end
        return
    end
    if not peers then
        peers = {}
        self.legacyColorPeers[p.id] = peers
    end
    peers[sender] = true
    if Canvas.HasExtendedColors(p.size, p.cells) then
        self:WarnLegacyColors(p)
    end
end

-- Warn about one still-relevant legacy peer, at most once per peer per
-- interval. A member uninvited since its hello no longer paints or syncs
-- this portrait, so it is dropped rather than nagged about.
function Comm:WarnLegacyColors(p)
    local peers = self.legacyColorPeers[p.id]
    if not peers then
        return
    end
    local now = GetTime()
    for sender in pairs(peers) do
        if p.dist == "MEMBERS" and not Portraits.IsMember(p, sender) then
            peers[sender] = nil
        else
            local key = p.id .. ";" .. sender
            local last = self.lastColorWarnAt[key]
            if not last or now - last >= COLOR_WARN_INTERVAL then
                self.lastColorWarnAt[key] = now
                PP.Print(("%s runs an older Pixel Party that only knows the classic 16 colors. Wheel strokes on '%s' never reach them (they keep seeing what was there before), and they cannot sync it until they update."):format(
                    Ambiguate(sender, "short"), p.name))
                return
            end
        end
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
    -- requester; the requester only accepts one offer anyway. The version
    -- rides along so requesters can prefer sources that saw every color;
    -- pre-0.7 clients match the rev off the front and ignore the rest.
    C_Timer.After(0.5 + math.random() * 2, function()
        local cur = Portraits.Get(pid)
        if cur then
            self:Whisper("O" .. pid .. ":" .. cur.rev .. ":" .. PP.VERSION, sender)
        end
    end)
end

function Comm:OnOffer(p, rev, sender, version)
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
    -- A pre-0.7 source is a last resort: it counts batches whose wheel
    -- colors it never applied, so its revision claims parity its pixels do
    -- not have. Any modern offer beats every legacy one; within a class,
    -- highest revision wins. (A version-less offer is pre-0.7 by
    -- definition — 0.7.0 is the first version that sends one.)
    if PP.VersionAtLeast(version, 0, 7) then
        if not w.rev or rev > w.rev then
            w.rev = rev
            w.sender = sender
        end
    else
        if not w.legacyRev or rev > w.legacyRev then
            w.legacyRev = rev
            w.legacySender = sender
        end
    end
end

function Comm:AcceptBestOffer()
    local w = self.offerWindow
    self.offerWindow = nil
    if not w or self.sync then
        return
    end
    local sender, rev, legacy = w.sender, w.rev, false
    if not sender then
        sender, rev, legacy = w.legacySender, w.legacyRev, true
    end
    if not sender then
        return
    end
    local p = Portraits.Get(w.pid)
    if not p or rev <= p.rev then
        return
    end
    if legacy and Canvas.HasExtendedColors(p.size, p.cells) then
        PP.Print(("Syncing '%s' from %s, whose older Pixel Party never saw its wheel colors; they will come back as classic colors or background."):format(
            p.name, Ambiguate(sender, "short")))
    end
    self.sync = {
        pid = p.id,
        source = sender,
        chunks = {},
        received = 0,
        total = nil,
        rev = nil,
        locked = nil,
        lastAt = GetTime(),
    }
    self:DiscardBufferedFor(p.id)
    self:Whisper("G" .. p.id, sender)
    PP.UI:UpdateStatus()
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
    PP.Print(message or "Canvas sync timed out.")
    PP.UI:UpdateStatus()
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
                Canvas.Clear(p.size, p.cells)
                -- Our batches that were unechoed when this clear arrived
                -- were serialized after it; peers kept them.
                for _, ops in ipairs(ev.reapply or {}) do
                    self:ApplyOps(p, ops)
                end
                PP.UI:RedrawAll()
            elseif ev.ops then
                self:ApplyOps(p, ev.ops)
            end
            p.rev = p.rev + 1
        end
    end
end

----------------------------------------------------------------------
-- Battle.net bulk transport (snapshots only)
--
-- Addon data can also be sent straight to a Battle.net friend's game
-- account, which carries up to 4078 bytes per message against the chat
-- transport's 255. A full canvas that costs ~41 whispers costs 3 messages
-- here, which is what makes big canvases practical.
--
-- The catch is that Battle.net delivery is explicitly NOT ordered. Only
-- snapshot chunks ride this path: they are numbered "i of n" and reassembled
-- by index, so order is irrelevant to them. Everything whose meaning depends
-- on sequence -- paints, clears, locks -- stays on the ordered chat
-- transport, and inbound BNet messages that are not snapshot chunks are
-- dropped rather than trusted.
----------------------------------------------------------------------

local BNET_CHUNK = 3900 -- leaves room for the header inside the 4078 cap

-- The game account of a roster member who is also an online Battle.net
-- friend playing WoW, or nil. Realm names carry spaces in this API and never
-- do in ours.
function Comm:BNetAccountFor(fullName)
    if not BNetSender() or not C_BattleNet or not BNGetNumFriends then
        return nil
    end
    for i = 1, BNGetNumFriends() do
        local accounts = C_BattleNet.GetFriendNumGameAccounts
            and C_BattleNet.GetFriendNumGameAccounts(i) or 0
        for j = 1, accounts do
            local g = C_BattleNet.GetFriendGameAccountInfo(i, j)
            if g and g.isOnline and g.clientProgram == "WoW" and g.characterName then
                local realm = g.realmName and g.realmName:gsub("%s", "") or nil
                local full = realm and (g.characterName .. "-" .. realm) or g.characterName
                if full == fullName then
                    return g.gameAccountID
                end
            end
        end
    end
    return nil
end

local function BNetNameFor(gameAccountID)
    local info = C_BattleNet and C_BattleNet.GetGameAccountInfoByID
        and C_BattleNet.GetGameAccountInfoByID(gameAccountID)
    if not info or not info.characterName then
        return nil
    end
    local realm = info.realmName and info.realmName:gsub("%s", "") or nil
    return realm and (info.characterName .. "-" .. realm) or info.characterName
end

function Comm:OnBNetMessage(prefix, text, _, gameAccountID)
    if prefix ~= self.PREFIX or type(text) ~= "string" then
        return
    end
    -- Snapshot chunks only. Anything else arriving here is either a bug or
    -- someone trying to smuggle an ordering-sensitive message onto an
    -- unordered pipe.
    if text:sub(1, 1) ~= "S" then
        return
    end
    local sender = BNetNameFor(gameAccountID)
    if not sender then
        return
    end
    -- Re-enter the normal path as a whisper so every trust rule still applies.
    self:OnMessage(prefix, text, "WHISPER", sender)
end

function Comm:StreamSnapshot(p, target)
    local data = Canvas.Serialize(p.size, p.cells)
    local flag = p.locked and "L" or "U"
    -- A Battle.net friend gets the whole thing in a handful of messages
    -- instead of dozens of whispers.
    local account = self:BNetAccountFor(target)
    local chunkSize = account and BNET_CHUNK or SNAP_CHUNK
    local total = math.ceil(#data / chunkSize)
    for i = 1, total do
        local chunk = data:sub((i - 1) * chunkSize + 1, i * chunkSize)
        local msg = ("S%s:%d:%d:%d:%s:%d:%s"):format(p.id, i, total, p.rev, flag, p.size, chunk)
        if account then
            self:Enqueue(msg, "BNET", account)
        else
            self:Whisper(msg, target)
        end
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
    local i, n, rev, flag, size, data = rest:match("^:(%d+):(%d+):(%d+):([LU]):(%d+):(.*)$")
    i, n, rev, size = tonumber(i), tonumber(n), tonumber(rev), tonumber(size)
    if not i or not n or not rev or n < 1 or i < 1 or i > n or not Canvas.ValidSize(size) then
        return
    end
    if s.total and (n ~= s.total or rev ~= s.rev or size ~= s.size) then
        return
    end
    s.total, s.rev, s.size = n, rev, size
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
        -- Decode against the size the sender declared, not ours: a snapshot
        -- for a differently-sized canvas must be rejected outright rather
        -- than reinterpreted into a scrambled picture.
        local cells = (s.size == p.size) and Canvas.Deserialize(p.size, table.concat(s.chunks)) or nil
        if cells then
            for i = 1, Canvas.Cells(p.size) do
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
            PP.UI:RedrawAll()
            PP.Print("Canvas synced from " .. Ambiguate(s.source, "short") .. ".")
        else
            PP.Print("Canvas sync failed (corrupt snapshot data); use /pixelparty sync to retry.")
        end
    end
    -- Batches that arrived mid-transfer may or may not already be in the
    -- snapshot; pixel ops are idempotent, so replaying them is safe.
    self:ReplayBuffered()
    PP.UI:UpdateAll()
end

----------------------------------------------------------------------
-- Invitations and roster
----------------------------------------------------------------------

-- Pending invites are stored under the name the inviter typed but looked up
-- under the canonical sender of the join ack, so the name half of the key
-- must be case-insensitive: names are unique case-insensitively in WoW, and
-- a case-sensitive match would silently drop the ack of anyone invited as
-- "bob", leaving the roster without them and the portrait forever unsynced.
-- The pid half stays as-is — portrait ids ARE case-sensitive. (:lower()
-- only folds ASCII; a non-ASCII letter typed in the wrong case still
-- misses, exactly as every case missed before.)
local function InviteKey(pid, name)
    return pid .. ";" .. name:lower()
end

-- Pending invites live in SavedVariables, not in Comm's session state: a
-- reload between sending an invite and the target's accept would otherwise
-- wipe them and silently discard the join ack. Expiries are wall-clock
-- time(), never GetTime() session uptime — a persisted uptime from a long
-- session would read as unexpired for the whole of the next one, holding
-- the trust window open indefinitely.
local function PendingInvites()
    PP.db.pendingInvites = PP.db.pendingInvites or {}
    return PP.db.pendingInvites
end

function Comm:SendInvite(p, target)
    if p.dist ~= "MEMBERS" then
        return false, "Only member portraits can send invites (not the Shared canvas)."
    end
    target = PP.NormalizeName(target)
    if not target then
        return false, "No player name given."
    end
    -- Adopt the roster/tombstone casing for typed names; the checks below
    -- compare case-sensitively.
    target = Portraits.ResolveName(p, target)
    if Portraits.IsMember(p, target) then
        return false, Ambiguate(target, "short") .. " is already a member."
    end
    if Portraits.IsRemoved(p, target) then
        -- Only the owner can undo their own uninvite; anyone else's re-invite
        -- would be filtered out by every peer's tombstone anyway.
        if not Portraits.IsOwner(p, PP.PlayerFullName()) then
            return false, Ambiguate(target, "short")
                .. " was uninvited by the creator - only they can bring them back."
        end
        Portraits.Unremove(p, target)
        self:Send(p, "M" .. p.id .. ":+" .. target)
    end
    if #(p.members or {}) >= Portraits.MAX_MEMBERS then
        return false, "This portrait is at its member limit."
    end
    local now = time()
    -- Sweep invites that aged out, so a long run of inviting cannot grow
    -- the table without bound.
    local invites = PendingInvites()
    for key, expiry in pairs(invites) do
        if now > expiry then
            invites[key] = nil
        end
    end
    invites[InviteKey(p.id, target)] = now + INVITE_TTL
    self:Whisper("I" .. p.id .. ":" .. (p.owner or "") .. ":" .. p.size .. ":" .. p.name, target)
    return true
end

function Comm:OnInvite(id, rest, sender)
    local existing = Portraits.Get(id)
    if existing then
        -- We already have this portrait. A re-invite from a member we
        -- already trust is the inviter repairing a half-joined roster (our
        -- J ack was lost to a crash, or to an older version's case-
        -- sensitive invite matching): ack again so they can re-add us. No new
        -- authority flows in either direction — we only re-ack someone
        -- already on our own roster, and their OnJoin still demands the
        -- fresh pending invite their own re-invite just recorded.
        if existing.dist == "MEMBERS" and Portraits.IsMember(existing, sender) then
            self:Whisper("J" .. id, sender)
        end
        return
    end
    -- Strict: an invite from an older addon has no size field and will not
    -- match, which is what we want -- it would create a canvas of the wrong
    -- size and scramble every op that followed.
    local owner, size, name = rest:match("^:(.-):(%d+):(.*)$")
    size = tonumber(size)
    if not owner or not Canvas.ValidSize(size) then
        return
    end
    name = Portraits.SanitizeName(name)
    if name == "" then
        name = "Untitled"
    end
    PP.UI:ShowInvitePopup({
        id = id,
        name = name,
        size = size,
        owner = PP.NormalizeName(owner ~= "" and owner or sender),
        from = sender,
    })
end

-- Called by the UI when the player accepts an invitation.
function Comm:AcceptInvite(data)
    if Portraits.Get(data.id) then
        return
    end
    local p = Portraits.Create(data.name, "MEMBERS", data.id, data.owner, data.size)
    -- Roster stub: us, the inviter, and the owner. The full roster arrives
    -- in the inviter's M message moments later. Built by appending rather
    -- than as a literal: a nil in the middle would truncate the ipairs walk
    -- and leave us with a roster that trusts nobody.
    local roster = {}
    for _, name in ipairs({ PP.PlayerFullName() or false, data.from or false, data.owner or false }) do
        if name then
            roster[#roster + 1] = name
        end
    end
    Portraits.AddMembers(p, roster)
    self:Whisper("J" .. p.id, data.from)
    Portraits.SetActive(p.id)
    PP.Print("Joined portrait '" .. p.name .. "'. Syncing from " .. Ambiguate(data.from, "short") .. "...")
    PP.UI:UpdateAll()
end

function Comm:OnJoin(p, sender)
    local invites = PendingInvites()
    local key = InviteKey(p.id, sender)
    local expiry = invites[key]
    if not expiry or time() > expiry then
        return
    end
    invites[key] = nil
    Portraits.AddMembers(p, { sender })
    self:SendRoster(p)
    -- Offer rather than streaming blind: the standard offer/G/S flow gives
    -- the joiner its usual guards, timeouts, and single-transfer rule.
    if p.rev > 0 then
        self:Whisper("O" .. p.id .. ":" .. p.rev .. ":" .. PP.VERSION, sender)
    end
    PP.Print(Ambiguate(sender, "short") .. " joined portrait '" .. p.name .. "'.")
    PP.UI:UpdateAll()
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
    if Portraits.IsOwner(p, PP.PlayerFullName()) then
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
        local me = PP.PlayerFullName()
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
        PP.UI:UpdateAll()
    end
end

----------------------------------------------------------------------
-- Uninvite (owner only)
----------------------------------------------------------------------

function Comm:SendKick(p, name)
    if p.dist ~= "MEMBERS" then
        return false, "The Shared canvas has no roster to remove anyone from."
    end
    if not Portraits.IsOwner(p, PP.PlayerFullName()) then
        return false, "Only the portrait's creator can uninvite members."
    end
    name = PP.NormalizeName(name)
    if not name then
        return false, "No player name given."
    end
    -- Typed names must match the roster's casing for the checks below, and
    -- the tombstone gossiped to peers must be canonical or their own
    -- case-sensitive IsRemoved never matches it.
    name = Portraits.ResolveName(p, name)
    if Portraits.IsOwner(p, name) then
        return false, "The creator cannot be uninvited."
    end
    if not Portraits.IsMember(p, name) then
        return false, Ambiguate(name, "short") .. " is not a member of '" .. p.name .. "'."
    end
    -- Tell them before dropping them: once they are off the roster, Send no
    -- longer routes anything their way.
    self:Whisper("K" .. p.id, name)
    PendingInvites()[InviteKey(p.id, name)] = nil
    Portraits.RemoveMembers(p, { name })
    self:SendRoster(p)
    PP.UI:UpdateAll()
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
        PP.Print("You were removed from portrait '" .. name .. "' by its creator.")
        PP.UI:UpdateAll()
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
    p.lockedBy = locked and PP.PlayerFullName() or nil
    self:Send(p, (locked and "L" or "U") .. p.id)
    PP.UI:UpdateAll()
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
        PP.Print("Portrait '" .. p.name .. "' was locked by " .. Ambiguate(sender, "short") .. ".")
        PP.UI:UpdateAll()
    end
end

function Comm:OnUnlock(p, sender)
    if not Portraits.Lockable(p) or not Portraits.IsOwner(p, sender) then
        return
    end
    if p.locked then
        p.locked = false
        p.lockedBy = nil
        PP.Print("Portrait '" .. p.name .. "' was unlocked by its owner.")
        PP.UI:UpdateAll()
    end
end

-- A paint/clear arrived for a locked portrait: the sender evidently missed
-- the lock. The ops are dropped either way; only the owner can usefully say
-- so, since only the owner's L is honored.
function Comm:NagLocked(p, sender)
    if not Portraits.IsOwner(p, PP.PlayerFullName()) then
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
    if prefix ~= self.PREFIX or type(text) ~= "string" or #text < 7 or not PP.db then
        return
    end
    if PP.IsSelf(sender) then
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
    sender = PP.NormalizeName(sender)
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
        if #rest == 0 or #rest % PP.OpWidth(p.size) ~= 0 then
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
        PP.UI:UpdateStatus()
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
            Canvas.Clear(p.size, p.cells)
            p.rev = p.rev + 1
            -- Our own unechoed batches were serialized after this clear;
            -- peers keep them, so must we.
            self:ReapplyInflightOps(p)
            PP.UI:RedrawAll()
            PP.UI:UpdateStatus()
        end
        PP.Print(Ambiguate(sender, "short") .. " cleared portrait '" .. p.name .. "'.")
    elseif kind == "H" then
        local rev = tonumber(rest:match("^:(%d+)"))
        -- Matched strictly against the whole tail, so an older client's
        -- "H<id>:<rev>:<version>" yields nil rather than a digit scavenged
        -- out of its version string.
        local theirSize = tonumber(rest:match("^:%d+:[^:]*:(%d+)$"))
        -- May be nil: the oldest clients sent bare "H<id>:<rev>".
        local theirVersion = rest:match("^:%d+:([^:]+)")
        if rev then
            self:WarnSizeMismatch(p, theirSize, sender)
            self:NoteColorSupport(p, theirVersion, sender)
            self:OnHello(p, rev, sender)
        end
    elseif kind == "Q" then
        local rev = tonumber(rest:match("^:(%d+)"))
        if rev then
            self:OnQuery(p, rev, sender)
        end
    elseif kind == "O" then
        local rev = tonumber(rest:match("^:(%d+)"))
        -- Absent on pre-0.7 offers ("O<id>:<rev>").
        local theirVersion = rest:match("^:%d+:([^:]+)")
        if rev then
            self:OnOffer(p, rev, sender, theirVersion)
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
            self:AbortSync("Canvas sync declined by source; use /pixelparty sync to retry in a moment.")
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
