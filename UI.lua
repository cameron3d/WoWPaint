local ADDON_NAME, WP = ...

local Canvas = WP.Canvas
local Portraits = WP.Portraits

local UI = {}
WP.UI = UI

local CELL = 8                      -- on-screen pixels per canvas cell
local GRID = Canvas.SIZE * CELL     -- 512
local FRAME_W = GRID + 28
-- Canvas bottom edge sits 586px from the frame top; two 22px button rows
-- (y=14 and y=42) plus breathing room need ~74px below it.
local FRAME_H = 660

local SWATCH = 24
local SWATCH_GAP = 8

local GALLERY_ROWS = 8

local CHANNEL_LABELS = {
    AUTO = "Auto",
    GUILD = "Guild",
    PARTY = "Party",
    RAID = "Raid",
    INSTANCE_CHAT = "Instance",
}
local CHANNEL_ORDER = { "AUTO", "GUILD", "PARTY", "RAID" }

UI.selectedColor = 3 -- black
UI.galleryView = nil -- gallery entry being viewed read-only, or nil
UI.galleryPage = 1

----------------------------------------------------------------------
-- Static popups
----------------------------------------------------------------------

StaticPopupDialogs["WOWPAINT_CLEAR"] = {
    text = "Clear portrait '%s'? This clears it for everyone painting it.",
    button1 = YES,
    button2 = NO,
    OnAccept = function()
        WP.Comm:SendClear(Portraits.Active())
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["WOWPAINT_NEW"] = {
    text = "Name the new portrait:",
    button1 = ACCEPT,
    button2 = CANCEL,
    hasEditBox = true,
    maxLetters = 24,
    OnAccept = function(self)
        UI:CreatePortrait(self.editBox:GetText())
    end,
    EditBoxOnEnterPressed = function(self)
        local dialog = self:GetParent()
        UI:CreatePortrait(self:GetText())
        dialog:Hide()
    end,
    EditBoxOnEscapePressed = function(self)
        self:GetParent():Hide()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["WOWPAINT_INVITE_SEND"] = {
    text = "Invite whom to '%s'?",
    button1 = ACCEPT,
    button2 = CANCEL,
    hasEditBox = true,
    maxLetters = 48,
    OnShow = function(self, data)
        if data and data.prefill then
            self.editBox:SetText(data.prefill)
            self.editBox:HighlightText()
        end
    end,
    OnAccept = function(self)
        UI:SendInvite(self.editBox:GetText())
    end,
    EditBoxOnEnterPressed = function(self)
        local dialog = self:GetParent()
        UI:SendInvite(self:GetText())
        dialog:Hide()
    end,
    EditBoxOnEscapePressed = function(self)
        self:GetParent():Hide()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["WOWPAINT_INVITE_RECV"] = {
    text = "%s invites you to paint portrait '%s'. Join?",
    button1 = ACCEPT,
    button2 = DECLINE,
    OnAccept = function(self, data)
        WP.Comm:AcceptInvite(data)
    end,
    timeout = 60,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["WOWPAINT_SAVE"] = {
    text = "Save to gallery as:",
    button1 = ACCEPT,
    button2 = CANCEL,
    hasEditBox = true,
    maxLetters = 24,
    OnShow = function(self)
        local p = Portraits.Active()
        self.editBox:SetText(p and p.name or "")
        self.editBox:HighlightText()
    end,
    OnAccept = function(self)
        UI:SaveToGallery(self.editBox:GetText())
    end,
    EditBoxOnEnterPressed = function(self)
        local dialog = self:GetParent()
        UI:SaveToGallery(self:GetText())
        dialog:Hide()
    end,
    EditBoxOnEscapePressed = function(self)
        self:GetParent():Hide()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["WOWPAINT_GALLERY_DELETE"] = {
    text = "Delete gallery entry '%s'?",
    button1 = YES,
    button2 = NO,
    OnAccept = function(self, data)
        UI:DeleteGalleryEntry(data.index)
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["WOWPAINT_DELETE_PORTRAIT"] = {
    text = "Remove portrait '%s' from this character? (Other members keep their copies.)",
    button1 = YES,
    button2 = NO,
    OnAccept = function(self, data)
        if Portraits.Delete(data.id) then
            WP.Print("Portrait removed.")
            UI:UpdateAll()
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

----------------------------------------------------------------------
-- Frame construction
----------------------------------------------------------------------

function UI:EnsureFrame()
    if self.frame then
        return
    end

    local f = CreateFrame("Frame", "WoWPaintFrame", UIParent, "BackdropTemplate")
    self.frame = f
    -- CreateFrame returns a shown frame; start hidden so Toggle's first
    -- IsShown() check takes the Show() path and OnShow actually fires.
    f:Hide()
    f:SetSize(FRAME_W, FRAME_H)
    f:SetFrameStrata("MEDIUM")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(frame)
        frame:StopMovingOrSizing()
        local point, _, relPoint, x, y = frame:GetPoint(1)
        WP.db.pos = { point = point, relPoint = relPoint, x = x, y = y }
    end)
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true,
        tileSize = 32,
        edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })

    local pos = WP.db.pos
    if pos and pos.point then
        f:SetPoint(pos.point, UIParent, pos.relPoint or pos.point, pos.x or 0, pos.y or 0)
    else
        f:SetPoint("CENTER")
    end

    self.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    self.title:SetPoint("TOP", f, "TOP", 0, -16)

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)

    self:BuildPalette(f)
    self:BuildCanvas(f)
    self:BuildBottomBars(f)
    self:BuildGalleryPanel(f)

    tinsert(UISpecialFrames, "WoWPaintFrame")

    f:SetScript("OnShow", function()
        UI:UpdateAll()
        WP.Comm:SendHello(Portraits.Active(), false)
    end)
end

function UI:BuildPalette(f)
    local bar = CreateFrame("Frame", nil, f)
    local barWidth = Canvas.NUM_COLORS * SWATCH + (Canvas.NUM_COLORS - 1) * SWATCH_GAP
    bar:SetSize(barWidth, SWATCH)
    bar:SetPoint("TOP", f, "TOP", 0, -40)

    self.rings = {}
    for c = 0, Canvas.NUM_COLORS - 1 do
        local btn = CreateFrame("Button", nil, bar)
        btn:SetSize(SWATCH, SWATCH)
        btn:SetPoint("LEFT", bar, "LEFT", c * (SWATCH + SWATCH_GAP), 0)

        local ring = btn:CreateTexture(nil, "BACKGROUND")
        ring:SetPoint("TOPLEFT", -3, 3)
        ring:SetPoint("BOTTOMRIGHT", 3, -3)
        ring:SetColorTexture(1, 0.82, 0)
        ring:Hide()
        self.rings[c] = ring

        local border = btn:CreateTexture(nil, "BORDER")
        border:SetPoint("TOPLEFT", -1, 1)
        border:SetPoint("BOTTOMRIGHT", 1, -1)
        border:SetColorTexture(0, 0, 0)

        local swatch = btn:CreateTexture(nil, "ARTWORK")
        swatch:SetAllPoints(btn)
        local col = Canvas.PALETTE[c]
        swatch:SetColorTexture(col[1], col[2], col[3])

        btn:SetScript("OnClick", function()
            UI:SelectColor(c)
        end)
    end
    self:SelectColor(self.selectedColor)
end

function UI:SelectColor(c)
    self.selectedColor = c
    for i, ring in pairs(self.rings) do
        ring:SetShown(i == c)
    end
end

function UI:BuildCanvas(f)
    local canvas = CreateFrame("Frame", nil, f)
    self.canvas = canvas
    canvas:SetSize(GRID, GRID)
    canvas:SetPoint("TOP", f, "TOP", 0, -74)
    canvas:EnableMouse(true)

    -- One texture per cell, created once. ~4096 flat color textures batch
    -- cheaply; creation causes a single small hitch on first open.
    self.cellTex = {}
    for y = 1, Canvas.SIZE do
        for x = 1, Canvas.SIZE do
            local t = canvas:CreateTexture(nil, "ARTWORK")
            t:SetSize(CELL, CELL)
            t:SetPoint("TOPLEFT", canvas, "TOPLEFT", (x - 1) * CELL, -(y - 1) * CELL)
            self.cellTex[Canvas.Index(x, y)] = t
        end
    end

    canvas:SetScript("OnMouseDown", function(_, button)
        if UI.galleryView then
            return
        end
        if button == "LeftButton" then
            UI.paintColor = UI.selectedColor
        elseif button == "RightButton" then
            UI.paintColor = 0
        else
            return
        end
        UI.painting = true
        UI.lastCell = nil
        UI:PaintAtCursor()
    end)
    canvas:SetScript("OnMouseUp", function()
        UI.painting = false
        UI.lastCell = nil
    end)
    canvas:SetScript("OnUpdate", function()
        if not UI.painting then
            return
        end
        if IsMouseButtonDown("LeftButton") or IsMouseButtonDown("RightButton") then
            UI:PaintAtCursor()
        else
            UI.painting = false
            UI.lastCell = nil
        end
    end)
end

function UI:CellFromCursor()
    local canvas = self.canvas
    local left, top = canvas:GetLeft(), canvas:GetTop()
    if not left or not top then
        return nil
    end
    local scale = canvas:GetEffectiveScale()
    local cx, cy = GetCursorPosition()
    cx, cy = cx / scale, cy / scale
    local x = math.floor((cx - left) / CELL) + 1
    local y = math.floor((top - cy) / CELL) + 1
    if x < 1 or x > Canvas.SIZE or y < 1 or y > Canvas.SIZE then
        return nil
    end
    return x, y
end

function UI:PaintAtCursor()
    if self.galleryView then
        return
    end
    local p = Portraits.Active()
    if not p or p.locked then
        return
    end
    local x, y = self:CellFromCursor()
    if not x then
        -- Cursor left the canvas mid-drag; restart the stroke when it
        -- returns rather than drawing a line across the gap.
        self.lastCell = nil
        return
    end
    local last = self.lastCell
    if last then
        if last[1] == x and last[2] == y then
            return
        end
        -- Fill in cells a fast drag skipped between two OnUpdate samples.
        local color = self.paintColor
        WP.ForLine(last[1], last[2], x, y, function(px, py)
            WP.Comm:Paint(p, px, py, color)
        end)
    else
        WP.Comm:Paint(p, x, y, self.paintColor)
    end
    self.lastCell = { x, y }
end

function UI:BuildBottomBars(f)
    -- Row 1 (y=14): scope/members, status, clear
    local scopeBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    self.scopeBtn = scopeBtn
    scopeBtn:SetSize(110, 22)
    scopeBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 14, 14)
    scopeBtn:SetScript("OnClick", function()
        UI:OnScopeClick()
    end)

    local clearBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    self.clearBtn = clearBtn
    clearBtn:SetSize(70, 22)
    clearBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -14, 14)
    clearBtn:SetText("Clear")
    clearBtn:SetScript("OnClick", function()
        local p = Portraits.Active()
        if p and not p.locked and not UI.galleryView then
            StaticPopup_Show("WOWPAINT_CLEAR", p.name)
        end
    end)

    local status = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    self.status = status
    status:SetPoint("BOTTOM", f, "BOTTOM", 0, 19)

    -- Row 2 (y=42): portrait cycle, new, invite, lock, save, gallery
    local x = 14
    local function rowBtn(width, label, onClick)
        local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        b:SetSize(width, 22)
        b:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", x, 42)
        x = x + width + 6
        if label then
            b:SetText(label)
        end
        b:SetScript("OnClick", onClick)
        return b
    end

    self.portraitBtn = rowBtn(150, nil, function()
        UI:CyclePortrait()
    end)
    self.newBtn = rowBtn(50, "New", function()
        StaticPopup_Show("WOWPAINT_NEW")
    end)
    self.inviteBtn = rowBtn(60, "Invite", function()
        UI:OnInviteClick()
    end)
    self.lockBtn = rowBtn(62, "Lock", function()
        UI:OnLockClick()
    end)
    self.saveBtn = rowBtn(50, "Save", function()
        if not UI.galleryView then
            StaticPopup_Show("WOWPAINT_SAVE")
        end
    end)
    self.galleryBtn = rowBtn(64, "Gallery", function()
        UI:ToggleGallery()
    end)
end

----------------------------------------------------------------------
-- Gallery panel
----------------------------------------------------------------------

function UI:BuildGalleryPanel(f)
    local g = CreateFrame("Frame", "WoWPaintGalleryFrame", f, "BackdropTemplate")
    self.gallery = g
    g:Hide()
    g:SetSize(300, 460)
    g:SetPoint("TOPLEFT", f, "TOPRIGHT", -8, 0)
    g:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true,
        tileSize = 32,
        edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })

    local title = g:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOP", g, "TOP", 0, -16)
    title:SetText("Gallery")

    local close = CreateFrame("Button", nil, g, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", g, "TOPRIGHT", -6, -6)

    g:SetScript("OnHide", function()
        -- Closing the gallery returns the canvas to the live portrait.
        if UI.galleryView then
            UI.galleryView = nil
            UI:UpdateAll()
        end
    end)

    self.galleryRows = {}
    for i = 1, GALLERY_ROWS do
        local row = CreateFrame("Frame", nil, g)
        row:SetSize(260, 44)
        row:SetPoint("TOPLEFT", g, "TOPLEFT", 18, -34 - (i - 1) * 46)

        row.text = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.text:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -2)
        row.text:SetPoint("RIGHT", row, "RIGHT", 0, 0)
        row.text:SetJustifyH("LEFT")

        row.viewBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        row.viewBtn:SetSize(52, 18)
        row.viewBtn:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 2)
        row.viewBtn:SetText("View")

        row.delBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        row.delBtn:SetSize(52, 18)
        row.delBtn:SetPoint("LEFT", row.viewBtn, "RIGHT", 6, 0)
        row.delBtn:SetText("Del")

        self.galleryRows[i] = row
    end

    self.galleryPageText = g:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    self.galleryPageText:SetPoint("BOTTOM", g, "BOTTOM", 0, 20)

    local prev = CreateFrame("Button", nil, g, "UIPanelButtonTemplate")
    prev:SetSize(50, 20)
    prev:SetPoint("BOTTOMLEFT", g, "BOTTOMLEFT", 16, 16)
    prev:SetText("<")
    prev:SetScript("OnClick", function()
        UI.galleryPage = math.max(1, UI.galleryPage - 1)
        UI:RefreshGallery()
    end)

    local next = CreateFrame("Button", nil, g, "UIPanelButtonTemplate")
    next:SetSize(50, 20)
    next:SetPoint("BOTTOMRIGHT", g, "BOTTOMRIGHT", -16, 16)
    next:SetText(">")
    next:SetScript("OnClick", function()
        UI.galleryPage = UI.galleryPage + 1
        UI:RefreshGallery()
    end)

    tinsert(UISpecialFrames, "WoWPaintGalleryFrame")
end

function UI:ToggleGallery()
    if self.gallery:IsShown() then
        self.gallery:Hide()
    else
        self.galleryPage = 1
        self.gallery:Show()
        self:RefreshGallery()
    end
end

function UI:RefreshGallery()
    if not self.gallery or not self.gallery:IsShown() then
        return
    end
    local entries = WP.db.gallery
    local pages = math.max(1, math.ceil(#entries / GALLERY_ROWS))
    if self.galleryPage > pages then
        self.galleryPage = pages
    end
    local page = self.galleryPage
    for i = 1, GALLERY_ROWS do
        local row = self.galleryRows[i]
        local index = (page - 1) * GALLERY_ROWS + i
        local entry = entries[index]
        if entry then
            row:Show()
            local when = date("%b %d %H:%M", entry.savedAt or 0)
            row.text:SetText(("%s  |cff9d9d9d(%s)|r"):format(entry.name, when))
            row.viewBtn:SetScript("OnClick", function()
                UI.galleryView = { entry = entry, index = index }
                UI:UpdateAll()
            end)
            row.delBtn:SetScript("OnClick", function()
                StaticPopup_Show("WOWPAINT_GALLERY_DELETE", entry.name, nil, { index = index })
            end)
        else
            row:Hide()
        end
    end
    self.galleryPageText:SetText(("Page %d / %d  -  %d saved"):format(page, pages, #entries))
end

function UI:SaveToGallery(name)
    local p = Portraits.Active()
    if not p then
        return
    end
    local entry = Portraits.SaveToGallery(p, name)
    WP.Print("Saved '" .. entry.name .. "' to your gallery.")
    self:RefreshGallery()
end

function UI:DeleteGalleryEntry(index)
    if self.galleryView and self.galleryView.index == index then
        self.galleryView = nil
    end
    Portraits.DeleteGalleryEntry(index)
    self:RefreshGallery()
    self:UpdateAll()
end

----------------------------------------------------------------------
-- Button actions
----------------------------------------------------------------------

function UI:CreatePortrait(name)
    name = Portraits.SanitizeName(name)
    if name == "" then
        WP.Print("Give the portrait a name.")
        return
    end
    if Portraits.FindByName(name) then
        WP.Print("You already have a portrait named '" .. name .. "'.")
        return
    end
    local p = Portraits.Create(name, "MEMBERS", nil, WP.PlayerFullName())
    Portraits.SetActive(p.id)
    WP.Print("Created portrait '" .. p.name .. "'. Use Invite to bring in painters.")
    self:UpdateAll()
end

function UI:OnInviteClick()
    local p = Portraits.Active()
    if not p or p.dist ~= "MEMBERS" then
        WP.Print("The Shared canvas has no roster - everyone in your scope already paints it. Create a portrait to invite people.")
        return
    end
    local prefill = ""
    if UnitIsPlayer("target") and UnitIsFriend("player", "target") then
        prefill = GetUnitName("target", true) or ""
    end
    local dialog = StaticPopup_Show("WOWPAINT_INVITE_SEND", p.name, nil, { prefill = prefill })
end

function UI:SendInvite(name)
    local p = Portraits.Active()
    if not p then
        return
    end
    local ok, err = WP.Comm:SendInvite(p, name)
    if ok then
        WP.Print("Invited " .. name .. " to '" .. p.name .. "'.")
    else
        WP.Print(err or "Could not send the invite.")
    end
end

function UI:OnLockClick()
    local p = Portraits.Active()
    if not p or not Portraits.Lockable(p) then
        return
    end
    if not Portraits.IsOwner(p, WP.PlayerFullName()) then
        WP.Print("Only the portrait's creator can lock or unlock it.")
        return
    end
    WP.Comm:SendLockState(p, not p.locked)
end

function UI:ShowInvitePopup(data)
    StaticPopup_Show("WOWPAINT_INVITE_RECV", Ambiguate(data.from, "short"), data.name, data)
end

function UI:CyclePortrait()
    local list = Portraits.List()
    if #list <= 1 then
        WP.Print("No other portraits - use New to create one.")
        return
    end
    local activeId = Portraits.Active().id
    local idx = 1
    for i, p in ipairs(list) do
        if p.id == activeId then
            idx = i
            break
        end
    end
    local nextP = list[idx % #list + 1]
    Portraits.SetActive(nextP.id)
    self.galleryView = nil
    self:UpdateAll()
    WP.Comm:SendHello(nextP, false)
end

function UI:OnScopeClick()
    local p = Portraits.Active()
    if p.dist == "MEMBERS" then
        local names = {}
        for _, m in ipairs(p.members or {}) do
            names[#names + 1] = Ambiguate(m, "short")
        end
        WP.Print("Members of '" .. p.name .. "': " .. table.concat(names, ", "))
        return
    end
    local idx = 1
    for i, mode in ipairs(CHANNEL_ORDER) do
        if mode == p.dist then
            idx = i
            break
        end
    end
    p.dist = CHANNEL_ORDER[idx % #CHANNEL_ORDER + 1]
    self:UpdateStatus()
end

----------------------------------------------------------------------
-- Rendering
----------------------------------------------------------------------

function UI:CurrentCells()
    if self.galleryView then
        return self.galleryView.entry.cells
    end
    local p = Portraits.Active()
    return p and p.cells or nil
end

function UI:UpdateCell(p, x, y)
    if not self.cellTex or self.galleryView then
        return
    end
    local active = Portraits.Active()
    if not active or active.id ~= p.id then
        return
    end
    local i = Canvas.Index(x, y)
    local col = Canvas.PALETTE[p.cells[i]] or Canvas.PALETTE[0]
    self.cellTex[i]:SetColorTexture(col[1], col[2], col[3])
end

function UI:RedrawAll()
    if not self.cellTex then
        return
    end
    local cells = self:CurrentCells()
    if not cells then
        return
    end
    for i = 1, Canvas.NUM_CELLS do
        local col = Canvas.PALETTE[cells[i]] or Canvas.PALETTE[0]
        self.cellTex[i]:SetColorTexture(col[1], col[2], col[3])
    end
end

function UI:UpdateStatus()
    if not self.status then
        return
    end
    local p = Portraits.Active()
    if not p then
        return
    end
    if self.galleryView then
        local e = self.galleryView.entry
        self.status:SetText(("Viewing '%s' (saved %s) - read-only, close Gallery to paint"):format(
            e.name, date("%b %d", e.savedAt or 0)))
        return
    end
    local text
    if WP.Comm.sync and WP.Comm.sync.pid == p.id then
        text = "Syncing canvas from " .. Ambiguate(WP.Comm.sync.source, "short") .. "..."
    elseif p.locked then
        text = "|cffffcc00Locked|r by " .. (p.lockedBy and Ambiguate(p.lockedBy, "short") or "owner")
            .. "  -  rev " .. p.rev
    elseif p.dist == "MEMBERS" then
        local n = #(p.members or {})
        text = ("Whispering %d member%s  -  rev %d"):format(n - 1 >= 0 and n or 0, n == 1 and "" or "s", p.rev)
    else
        local chatType = WP.Comm:GetScopeChannel(p.dist)
        if chatType then
            text = ("Broadcasting to %s  -  rev %d"):format(CHANNEL_LABELS[chatType] or chatType, p.rev)
        else
            text = ("|cffff6060Offline|r (no %s available)  -  rev %d"):format(
                CHANNEL_LABELS[p.dist] or p.dist, p.rev)
        end
    end
    self.status:SetText(text)
end

function UI:UpdateButtons()
    if not self.frame then
        return
    end
    local p = Portraits.Active()
    if not p then
        return
    end
    local me = WP.PlayerFullName()

    self.portraitBtn:SetText("Portrait: " .. p.name:sub(1, 14))
    if p.dist == "MEMBERS" then
        self.scopeBtn:SetText(("Members: %d"):format(#(p.members or {})))
    else
        self.scopeBtn:SetText("Scope: " .. (CHANNEL_LABELS[p.dist] or p.dist))
    end
    self.inviteBtn:SetEnabled(p.dist == "MEMBERS" and not self.galleryView)
    if Portraits.Lockable(p) then
        self.lockBtn:Show()
        self.lockBtn:SetText(p.locked and "Unlock" or "Lock")
        self.lockBtn:SetEnabled(Portraits.IsOwner(p, me))
    else
        self.lockBtn:Hide()
    end
    self.clearBtn:SetEnabled(not p.locked and not self.galleryView)
    self.saveBtn:SetEnabled(not self.galleryView)
end

function UI:UpdateTitle()
    if not self.title then
        return
    end
    if self.galleryView then
        self.title:SetText("Gallery: " .. self.galleryView.entry.name)
        return
    end
    local p = Portraits.Active()
    if p then
        self.title:SetText("WoWPaint - " .. p.name .. (p.locked and "  (locked)" or ""))
    end
end

function UI:UpdateAll()
    if not self.frame then
        return
    end
    self:UpdateTitle()
    self:UpdateButtons()
    self:UpdateStatus()
    self:RedrawAll()
    self:RefreshGallery()
end

function UI:Toggle()
    self:EnsureFrame()
    if self.frame:IsShown() then
        self.frame:Hide()
    else
        self.frame:Show()
    end
end
