local ADDON_NAME, WP = ...

local Canvas = WP.Canvas
local Portraits = WP.Portraits

local VALID_SCOPES = { AUTO = true, GUILD = true, PARTY = true, RAID = true }

function WP.Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff7ec0eeWoWPaint:|r " .. tostring(msg))
end

local function FreshCells()
    local cells = {}
    for i = 1, Canvas.NUM_CELLS do
        cells[i] = 0
    end
    return cells
end

local function SanitizeCells(cells)
    if type(cells) ~= "table" then
        return FreshCells()
    end
    for i = 1, Canvas.NUM_CELLS do
        local v = cells[i]
        if type(v) ~= "number" or v < 0 or v >= Canvas.NUM_COLORS or v % 1 ~= 0 then
            cells[i] = 0
        end
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
        p.dist = VALID_SCOPES[p.dist] and p.dist or "AUTO"
        p.members = nil
        p.removed = nil
        p.owner = nil
        p.locked = false
        p.lockedBy = nil
    else
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
    p.cells = SanitizeCells(p.cells)
    p.rev = (type(p.rev) == "number" and p.rev >= 0) and math.floor(p.rev) or 0
    p.createdAt = type(p.createdAt) == "number" and p.createdAt or 0
    return p
end

local function InitDB()
    WoWPaintDB = WoWPaintDB or {}
    local db = WoWPaintDB

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
            e.cells = SanitizeCells(e.cells)
        end
    end

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
    if type(db.minimap) ~= "table" then
        db.minimap = {}
    end
    if type(db.minimap.angle) ~= "number" then
        db.minimap.angle = 200
    end
    db.minimap.hide = db.minimap.hide == true
    WP.db = db
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("CHAT_MSG_ADDON")
events:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        local name = ...
        if name == ADDON_NAME then
            InitDB()
            WP.Comm:Init()
            -- Cheap: the button does not build the canvas frame, so the
            -- 4096-texture hitch still waits for a real click.
            WP.UI:EnsureMinimapButton()
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        local isLogin, isReload = ...
        if isLogin or isReload then
            -- Give the world (and guild roster) a moment to settle before
            -- asking peers for current canvases.
            C_Timer.After(8, function()
                WP.Comm:HelloAll(true)
            end)
        end
    elseif event == "CHAT_MSG_ADDON" then
        WP.Comm:OnMessage(...)
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
    if WP.db.activeId == p.id then
        bits[#bits + 1] = "|cff7ec0ee<- active|r"
    end
    return table.concat(bits, " ")
end

SLASH_WOWPAINT1 = "/wowpaint"
SLASH_WOWPAINT2 = "/wpaint"
SlashCmdList["WOWPAINT"] = function(input)
    if not WP.db then
        return
    end
    input = (input or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local cmd, rest = input:match("^(%S*)%s*(.*)$")
    cmd = cmd:lower()
    local active = Portraits.Active()

    if cmd == "" or cmd == "show" or cmd == "toggle" then
        WP.UI:Toggle()
    elseif cmd == "new" then
        WP.UI:EnsureFrame()
        if rest ~= "" then
            WP.UI:CreatePortrait(rest)
        else
            StaticPopup_Show("WOWPAINT_NEW")
        end
    elseif cmd == "invite" then
        WP.UI:EnsureFrame()
        if rest ~= "" then
            WP.UI:SendInvite(rest)
        else
            WP.UI:OnInviteClick()
        end
    elseif cmd == "open" then
        local p = Portraits.FindByName(rest)
        if p then
            Portraits.SetActive(p.id)
            WP.UI:UpdateAll()
            WP.Print("Now painting '" .. p.name .. "'.")
        else
            WP.Print("No portrait named '" .. rest .. "'. /wowpaint list shows them.")
        end
    elseif cmd == "list" then
        WP.Print("Portraits:")
        for _, p in ipairs(Portraits.List()) do
            WP.Print("  " .. DescribePortrait(p))
        end
        WP.Print(("Gallery: %d saved. /wowpaint gallery to browse."):format(#WP.db.gallery))
    elseif cmd == "delete" then
        local p = Portraits.FindByName(rest)
        if not p then
            WP.Print("No portrait named '" .. rest .. "'.")
        elseif p.id == Portraits.SHARED_ID then
            WP.Print("The Shared canvas cannot be removed.")
        else
            WP.UI:EnsureFrame()
            StaticPopup_Show("WOWPAINT_DELETE_PORTRAIT", p.name, nil, { id = p.id })
        end
    elseif cmd == "uninvite" or cmd == "kick" then
        WP.UI:EnsureFrame()
        if rest ~= "" then
            WP.UI:Uninvite(rest)
        else
            WP.UI:ToggleMembers()
        end
    elseif cmd == "lock" or cmd == "unlock" then
        WP.UI:EnsureFrame()
        -- Explicit verbs, not a toggle: "/wowpaint lock" on a locked
        -- portrait must not unlock it.
        WP.UI:OnLockClick(cmd == "lock")
    elseif cmd == "members" then
        WP.UI:EnsureFrame()
        WP.UI.frame:Show()
        WP.UI:ToggleMembers()
    elseif cmd == "portraits" then
        WP.UI:EnsureFrame()
        WP.UI:TogglePicker()
    elseif cmd == "minimap" then
        WP.UI:ToggleMinimapButton()
    elseif cmd == "save" then
        WP.UI:EnsureFrame()
        if rest ~= "" then
            WP.UI:SaveToGallery(rest)
        else
            StaticPopup_Show("WOWPAINT_SAVE")
        end
    elseif cmd == "gallery" then
        WP.UI:EnsureFrame()
        if not WP.UI.frame:IsShown() then
            WP.UI.frame:Show()
        end
        WP.UI:ToggleGallery()
    elseif cmd == "sync" then
        if WP.Comm:SendHello(active, true) then
            WP.Print("Requested sync for '" .. active.name .. "'.")
        else
            WP.Print("No one to sync with - check your scope or the portrait's members.")
        end
    elseif cmd == "clear" then
        if active.locked then
            WP.Print("'" .. active.name .. "' is locked.")
        else
            WP.UI:EnsureFrame()
            StaticPopup_Show("WOWPAINT_CLEAR", active.name)
        end
    elseif cmd == "channel" then
        local shared = Portraits.Get(Portraits.SHARED_ID)
        local mode = rest:upper()
        if VALID_SCOPES[mode] then
            shared.dist = mode
            WP.UI:UpdateAll()
            WP.Print("Shared canvas scope set to " .. mode:lower() .. ".")
        else
            WP.Print(("Shared scope is %s. Usage: /wowpaint channel auto | guild | party | raid"):format(
                (shared.dist or "AUTO"):lower()))
        end
    else
        WP.Print("Commands:")
        WP.Print("  /wowpaint - toggle the canvas")
        WP.Print("  /wowpaint new [name] - create a portrait you can invite people to")
        WP.Print("  /wowpaint invite [player] - invite someone to the active portrait")
        WP.Print("  /wowpaint open <name> | list | delete <name> - manage portraits")
        WP.Print("  /wowpaint portraits | members - open the picker / roster panels")
        WP.Print("  /wowpaint minimap - show or hide the minimap button")
        WP.Print("  /wowpaint uninvite [player] - remove a member (creator only)")
        WP.Print("  /wowpaint lock | unlock - freeze the active portrait (creator only)")
        WP.Print("  /wowpaint save [name] | gallery - snapshot to / browse your gallery")
        WP.Print("  /wowpaint channel auto|guild|party|raid - Shared canvas scope")
        WP.Print("  /wowpaint sync | clear - re-sync / wipe the active portrait")
    end
end
