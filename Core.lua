local ADDON_NAME, PP = ...

local Canvas = PP.Canvas
local Portraits = PP.Portraits

local VALID_SCOPES = { AUTO = true, GUILD = true, PARTY = true, RAID = true }

function PP.Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff7ec0eePixel Party:|r " .. tostring(msg))
end

local function SanitizeCells(cells, size)
    if type(cells) ~= "table" then
        return Canvas.New(size)
    end
    local total = Canvas.Cells(size)
    for i = 1, total do
        local v = cells[i]
        if type(v) ~= "number" or v < 0 or v >= Canvas.NUM_COLORS or v % 1 ~= 0 then
            cells[i] = 0
        end
    end
    -- A canvas that shrank (or a corrupt file) must not keep a tail of cells
    -- past its own area: Serialize would read past the end of the picture.
    for i = total + 1, #cells do
        cells[i] = nil
    end
    return cells
end

-- Repair one stored portrait in place; returns nil if it is beyond saving.
local function SanitizePortrait(id, p)
    if type(p) ~= "table" or not Portraits.ValidId(id) then
        return nil
    end
    p.id = id
    p.name = Portraits.SanitizeName(p.name)
    if p.name == "" then
        p.name = id == Portraits.SHARED_ID and "Shared" or "Untitled"
    end
    if id == Portraits.SHARED_ID then
        -- The Shared canvas is pinned at the original size on every client
        -- forever; that is what keeps it readable by any addon version.
        p.size = Canvas.DEFAULT_SIZE
        p.dist = VALID_SCOPES[p.dist] and p.dist or "AUTO"
        p.members = nil
        p.removed = nil
        p.owner = nil
        p.locked = false
        p.lockedBy = nil
    else
        p.size = Canvas.ValidSize(p.size) and p.size or Canvas.DEFAULT_SIZE
        p.dist = "MEMBERS"
        local members = {}
        if type(p.members) == "table" then
            for _, m in ipairs(p.members) do
                if Portraits.ValidMemberName(m) and #members < Portraits.MAX_MEMBERS then
                    members[#members + 1] = m
                end
            end
        end
        p.members = members
        local removed = {}
        if type(p.removed) == "table" then
            for _, m in ipairs(p.removed) do
                if Portraits.ValidMemberName(m) and #removed < Portraits.MAX_REMOVED then
                    removed[#removed + 1] = m
                end
            end
        end
        p.removed = removed
        p.owner = type(p.owner) == "string" and p.owner or nil
        p.locked = p.locked == true
        p.lockedBy = type(p.lockedBy) == "string" and p.lockedBy or nil
    end
    p.cells = SanitizeCells(p.cells, p.size)
    p.rev = (type(p.rev) == "number" and p.rev >= 0) and math.floor(p.rev) or 0
    p.createdAt = type(p.createdAt) == "number" and p.createdAt or 0
    return p
end

local function InitDB()
    PixelPartyDB = PixelPartyDB or {}
    local db = PixelPartyDB

    if (db.dbVersion or 0) < 2 then
        -- v1 -> v2: fold the single canvas into the built-in Shared portrait.
        local oldCells, oldRev, oldChannel = db.cells, db.rev, db.channel
        db.cells, db.rev, db.channel = nil, nil, nil
        db.portraits = db.portraits or {}
        db.portraits[Portraits.SHARED_ID] = {
            id = Portraits.SHARED_ID,
            name = "Shared",
            dist = VALID_SCOPES[oldChannel] and oldChannel or "AUTO",
            cells = oldCells,
            rev = oldRev,
            createdAt = 0,
        }
        db.dbVersion = 2
    end

    db.portraits = type(db.portraits) == "table" and db.portraits or {}
    local cleaned = {}
    for id, p in pairs(db.portraits) do
        local ok = SanitizePortrait(id, p)
        if ok then
            cleaned[id] = ok
        end
    end
    db.portraits = cleaned
    if not db.portraits[Portraits.SHARED_ID] then
        db.portraits[Portraits.SHARED_ID] = SanitizePortrait(Portraits.SHARED_ID, {
            name = "Shared", dist = "AUTO", createdAt = 0,
        })
    end

    db.gallery = type(db.gallery) == "table" and db.gallery or {}
    for i = #db.gallery, 1, -1 do
        local e = db.gallery[i]
        if type(e) ~= "table" or type(e.cells) ~= "table" then
            table.remove(db.gallery, i)
        else
            e.name = Portraits.SanitizeName(e.name)
            if e.name == "" then
                e.name = "Untitled"
            end
            -- Gallery entries predating per-portrait sizes are all 64.
            e.size = Canvas.ValidSize(e.size) and e.size or Canvas.DEFAULT_SIZE
            e.cells = SanitizeCells(e.cells, e.size)
        end
    end

    -- Pending portrait invites ride SavedVariables so a reload between an
    -- invite and its accept cannot orphan the joiner (Comm consults them
    -- when the join ack arrives). Expiries are wall-clock time(). Junk and
    -- expired entries are dropped, and the rest are clamped so a corrupt
    -- file cannot mint an invite that outlives the TTL.
    local invites = {}
    if type(db.pendingInvites) == "table" then
        local nowT = time()
        local ttl = PP.Comm.INVITE_TTL
        for key, expiry in pairs(db.pendingInvites) do
            if type(key) == "string" and Portraits.ValidId(key:sub(1, 6))
                and key:sub(7, 7) == ";" and #key > 7
                and type(expiry) == "number" and expiry > nowT then
                invites[key] = math.min(expiry, nowT + ttl)
            end
        end
    end
    db.pendingInvites = invites

    if not db.portraits[db.activeId] then
        db.activeId = Portraits.SHARED_ID
    end

    -- Local tool preferences; the UI re-validates the tool id against its own
    -- table, so only the numeric ranges need clamping here.
    if type(db.brushSize) ~= "number" or db.brushSize < 1 or db.brushSize > 3 then
        db.brushSize = 1
    end
    db.brushSize = math.floor(db.brushSize)
    if type(db.color) ~= "number" or db.color < 0 or db.color >= Canvas.NUM_COLORS then
        db.color = 3
    end
    db.color = math.floor(db.color)
    db.showGrid = db.showGrid == true
    if type(db.tool) ~= "string" then
        db.tool = nil
    end
    -- The viewport re-validates the zoom against the active canvas, so this
    -- only has to reject non-numbers.
    if type(db.zoom) ~= "number" then
        db.zoom = nil
    end
    if not Canvas.ValidSize(db.newSize) then
        db.newSize = Canvas.DEFAULT_SIZE
    end
    if type(db.minimap) ~= "table" then
        db.minimap = {}
    end
    if type(db.minimap.angle) ~= "number" then
        db.minimap.angle = 200
    end
    db.minimap.hide = db.minimap.hide == true
    PP.db = db
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("CHAT_MSG_ADDON")
-- Battle.net addon delivery carries bulk snapshots where it exists. Registering
-- an event the client does not know about raises, so ask forgiveness: without
-- it, snapshots simply stay on the chat transport.
pcall(events.RegisterEvent, events, "BN_CHAT_MSG_ADDON")
events:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        local name = ...
        if name == ADDON_NAME then
            InitDB()
            PP.Comm:Init()
            -- Cheap: the button does not build the canvas frame, so the
            -- 4096-texture hitch still waits for a real click.
            PP.UI:EnsureMinimapButton()
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        local isLogin, isReload = ...
        if isLogin or isReload then
            -- Give the world (and guild roster) a moment to settle before
            -- asking peers for current canvases.
            C_Timer.After(8, function()
                PP.Comm:HelloAll(true)
            end)
        end
    elseif event == "CHAT_MSG_ADDON" then
        PP.Comm:OnMessage(...)
    elseif event == "BN_CHAT_MSG_ADDON" then
        PP.Comm:OnBNetMessage(...)
    end
end)

local function DescribePortrait(p)
    local bits = { p.name }
    if p.id == Portraits.SHARED_ID then
        bits[#bits + 1] = "(shared scope: " .. (p.dist or "AUTO"):lower() .. ")"
    else
        bits[#bits + 1] = ("(%d member%s)"):format(#(p.members or {}), #(p.members or {}) == 1 and "" or "s")
    end
    if p.locked then
        bits[#bits + 1] = "|cffffcc00[locked]|r"
    end
    if PP.db.activeId == p.id then
        bits[#bits + 1] = "|cff7ec0ee<- active|r"
    end
    return table.concat(bits, " ")
end

SLASH_PIXELPARTY1 = "/pixelparty"
SLASH_PIXELPARTY2 = "/pparty"
SlashCmdList["PIXELPARTY"] = function(input)
    if not PP.db then
        return
    end
    input = (input or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local cmd, rest = input:match("^(%S*)%s*(.*)$")
    cmd = cmd:lower()
    local active = Portraits.Active()

    if cmd == "" or cmd == "show" or cmd == "toggle" then
        PP.UI:Toggle()
    elseif cmd == "new" then
        PP.UI:EnsureFrame()
        if rest ~= "" then
            PP.UI:CreatePortrait(rest)
        else
            StaticPopup_Show("PIXELPARTY_NEW")
        end
    elseif cmd == "invite" then
        PP.UI:EnsureFrame()
        if rest ~= "" then
            PP.UI:SendInvite(rest)
        else
            PP.UI:OnInviteClick()
        end
    elseif cmd == "open" then
        local p = Portraits.FindByName(rest)
        if p then
            Portraits.SetActive(p.id)
            PP.UI:UpdateAll()
            PP.Print("Now painting '" .. p.name .. "'.")
        else
            PP.Print("No portrait named '" .. rest .. "'. /pixelparty list shows them.")
        end
    elseif cmd == "list" then
        PP.Print("Portraits:")
        for _, p in ipairs(Portraits.List()) do
            PP.Print("  " .. DescribePortrait(p))
        end
        PP.Print(("Gallery: %d saved. /pixelparty gallery to browse."):format(#PP.db.gallery))
    elseif cmd == "delete" then
        local p = Portraits.FindByName(rest)
        if not p then
            PP.Print("No portrait named '" .. rest .. "'.")
        elseif p.id == Portraits.SHARED_ID then
            PP.Print("The Shared canvas cannot be removed.")
        else
            PP.UI:EnsureFrame()
            StaticPopup_Show("PIXELPARTY_DELETE_PORTRAIT", p.name, nil, { id = p.id })
        end
    elseif cmd == "uninvite" or cmd == "kick" then
        PP.UI:EnsureFrame()
        if rest ~= "" then
            PP.UI:Uninvite(rest)
        else
            PP.UI:ToggleMembers()
        end
    elseif cmd == "lock" or cmd == "unlock" then
        PP.UI:EnsureFrame()
        -- Explicit verbs, not a toggle: "/pixelparty lock" on a locked
        -- portrait must not unlock it.
        PP.UI:OnLockClick(cmd == "lock")
    elseif cmd == "members" then
        PP.UI:EnsureFrame()
        PP.UI.frame:Show()
        PP.UI:ToggleMembers()
    elseif cmd == "portraits" then
        PP.UI:EnsureFrame()
        PP.UI:TogglePicker()
    elseif cmd == "minimap" then
        PP.UI:ToggleMinimapButton()
    elseif cmd == "save" then
        PP.UI:EnsureFrame()
        if rest ~= "" then
            PP.UI:SaveToGallery(rest)
        else
            StaticPopup_Show("PIXELPARTY_SAVE")
        end
    elseif cmd == "gallery" then
        PP.UI:EnsureFrame()
        if not PP.UI.frame:IsShown() then
            PP.UI.frame:Show()
        end
        PP.UI:ToggleGallery()
    elseif cmd == "sync" then
        if PP.Comm:SendHello(active, true) then
            PP.Print("Requested sync for '" .. active.name .. "'.")
        else
            PP.Print("No one to sync with - check your scope or the portrait's members.")
        end
    elseif cmd == "clear" then
        if active.locked then
            PP.Print("'" .. active.name .. "' is locked.")
        else
            PP.UI:EnsureFrame()
            StaticPopup_Show("PIXELPARTY_CLEAR", active.name)
        end
    elseif cmd == "channel" then
        local shared = Portraits.Get(Portraits.SHARED_ID)
        local mode = rest:upper()
        if VALID_SCOPES[mode] then
            shared.dist = mode
            PP.UI:UpdateAll()
            PP.Print("Shared canvas scope set to " .. mode:lower() .. ".")
        else
            PP.Print(("Shared scope is %s. Usage: /pixelparty channel auto | guild | party | raid"):format(
                (shared.dist or "AUTO"):lower()))
        end
    else
        PP.Print("Commands:")
        PP.Print("  /pixelparty - toggle the canvas")
        PP.Print("  /pixelparty new [name] - create a portrait you can invite people to")
        PP.Print("  /pixelparty invite [player] - invite someone to the active portrait")
        PP.Print("  /pixelparty open <name> | list | delete <name> - manage portraits")
        PP.Print("  /pixelparty portraits | members - open the picker / roster panels")
        PP.Print("  /pixelparty minimap - show or hide the minimap button")
        PP.Print("  /pixelparty uninvite [player] - remove a member (creator only)")
        PP.Print("  /pixelparty lock | unlock - freeze the active portrait (creator only)")
        PP.Print("  /pixelparty save [name] | gallery - snapshot to / browse your gallery")
        PP.Print("  /pixelparty channel auto|guild|party|raid - Shared canvas scope")
        PP.Print("  /pixelparty sync | clear - re-sync / wipe the active portrait")
    end
end
