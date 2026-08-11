local ADDON_NAME, WP = ...

local Canvas = WP.Canvas
local Portraits = WP.Portraits

local UI = {}
WP.UI = UI

local CELL = 8                      -- on-screen pixels per canvas cell
local GRID = Canvas.SIZE * CELL     -- 512
local FRAME_W = GRID + 28
-- Canvas bottom edge sits 608px from the frame top; two 22px button rows
-- (y=14 and y=42) plus breathing room need ~74px below it.
local FRAME_H = 682

local SWATCH = 24
local SWATCH_GAP = 8

local GALLERY_ROWS = 8
local PICKER_ROWS = 6
local MEMBER_ROWS = 8
local MAX_UNDO = 20

local CHANNEL_LABELS = {
    AUTO = "Auto",
    GUILD = "Guild",
    PARTY = "Party",
    RAID = "Raid",
    INSTANCE_CHAT = "Instance",
}
local CHANNEL_ORDER = { "AUTO", "GUILD", "PARTY", "RAID" }

-- Right mouse button always means "erase", so every tool has a subtractive
-- twin without doubling the button count.
local TOOLS = {
    { id = "PENCIL", label = "Pencil", tip = "Freehand. Drag to draw; right-drag erases." },
    { id = "LINE",   label = "Line",   tip = "Drag for a straight line." },
    { id = "RECT",   label = "Box",    tip = "Drag for a rectangle. Hold Shift to fill it." },
    { id = "CIRCLE", label = "Circle", tip = "Drag for an ellipse. Hold Shift to fill it." },
    { id = "FILL",   label = "Fill",   tip = "Flood-fill the matching area under the cursor." },
    { id = "PICK",   label = "Pick",   tip = "Pick up the colour under the cursor." },
}
local TOOL_BY_ID = {}
for _, t in ipairs(TOOLS) do
    TOOL_BY_ID[t.id] = t
end

UI.selectedColor = 3 -- black
UI.tool = "PENCIL"
UI.brushSize = 1
UI.galleryView = nil -- gallery entry being viewed read-only, or nil
UI.galleryPage = 1
UI.pickerPage = 1
UI.memberPage = 1
UI.undoStack = {}

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

StaticPopupDialogs["WOWPAINT_UNINVITE"] = {
    text = "Remove %s from this portrait? Their copy is deleted and they can no longer paint it.",
    button1 = YES,
    button2 = NO,
    OnAccept = function(self, data)
        UI:DoUninvite(data.name)
    end,
    timeout = 0,
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

    self.tool = TOOL_BY_ID[WP.db.tool] and WP.db.tool or "PENCIL"
    self.brushSize = WP.db.brushSize or 1
    self.selectedColor = WP.db.color or self.selectedColor

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

    self:BuildToolbar(f)
    self:BuildPalette(f)
    self:BuildCanvas(f)
    self:BuildBottomBars(f)
    self:BuildGalleryPanel(f)
    self:BuildPickerPanel(f)
    self:BuildMembersPanel(f)

    tinsert(UISpecialFrames, "WoWPaintFrame")

    -- The picker floats free of this window, so it has to be re-anchored
    -- whenever the canvas appears or disappears underneath it.
    f:SetScript("OnShow", function()
        if UI.picker:IsShown() then
            UI:AnchorPicker()
        end
        UI:UpdateAll()
        WP.Comm:SendHello(Portraits.Active(), false)
    end)
    f:SetScript("OnHide", function()
        if UI.picker:IsShown() then
            UI:AnchorPicker()
            UI:RefreshPicker()
        end
    end)
end

local function Tooltip(frame, title, body)
    frame:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(title)
        if body then
            GameTooltip:AddLine(body, 1, 1, 1, true)
        end
        GameTooltip:Show()
    end)
    frame:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
end

function UI:BuildToolbar(f)
    local bar = CreateFrame("Frame", nil, f)
    bar:SetSize(506, 22)
    bar:SetPoint("TOP", f, "TOP", 0, -38)

    local x = 0
    self.toolBtns = {}
    for _, tool in ipairs(TOOLS) do
        local b = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
        b:SetSize(54, 22)
        b:SetPoint("LEFT", bar, "LEFT", x, 0)
        b:SetText(tool.label)
        b:SetScript("OnClick", function()
            UI:SetTool(tool.id)
        end)
        Tooltip(b, tool.label, tool.tip)
        self.toolBtns[tool.id] = b
        x = x + 58
    end

    x = x + 4
    self.sizeBtn = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
    self.sizeBtn:SetSize(46, 22)
    self.sizeBtn:SetPoint("LEFT", bar, "LEFT", x, 0)
    self.sizeBtn:SetScript("OnClick", function()
        UI.brushSize = UI.brushSize % 3 + 1
        WP.db.brushSize = UI.brushSize
        UI:UpdateButtons()
    end)
    Tooltip(self.sizeBtn, "Brush size", "Freehand nib width, 1 to 3 cells.")
    x = x + 50

    self.undoBtn = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
    self.undoBtn:SetSize(54, 22)
    self.undoBtn:SetPoint("LEFT", bar, "LEFT", x, 0)
    self.undoBtn:SetText("Undo")
    self.undoBtn:SetScript("OnClick", function()
        UI:Undo()
    end)
    Tooltip(self.undoBtn, "Undo", "Repaints what your last action covered. Peers see the repaint like any other strokes.")
    x = x + 58

    self.gridBtn = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
    self.gridBtn:SetSize(46, 22)
    self.gridBtn:SetPoint("LEFT", bar, "LEFT", x, 0)
    self.gridBtn:SetText("Grid")
    self.gridBtn:SetScript("OnClick", function()
        WP.db.showGrid = not WP.db.showGrid
        UI:UpdateGrid()
        UI:UpdateButtons()
    end)
    Tooltip(self.gridBtn, "Grid", "Overlay cell guides. Local only.")
end

function UI:SetTool(id)
    if not TOOL_BY_ID[id] then
        return
    end
    self:ClearPreview()
    self.tool = id
    WP.db.tool = id
    self:UpdateButtons()
end

function UI:BuildPalette(f)
    local bar = CreateFrame("Frame", nil, f)
    local barWidth = Canvas.NUM_COLORS * SWATCH + (Canvas.NUM_COLORS - 1) * SWATCH_GAP
    bar:SetSize(barWidth, SWATCH)
    bar:SetPoint("TOP", f, "TOP", 0, -66)

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
    if WP.db then
        WP.db.color = c
    end
    for i, ring in pairs(self.rings) do
        ring:SetShown(i == c)
    end
end

function UI:BuildCanvas(f)
    local canvas = CreateFrame("Frame", nil, f)
    self.canvas = canvas
    canvas:SetSize(GRID, GRID)
    canvas:SetPoint("TOP", f, "TOP", 0, -96)
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
        if button == "LeftButton" then
            UI:OnCanvasDown(UI.selectedColor)
        elseif button == "RightButton" then
            UI:OnCanvasDown(0)
        end
    end)
    canvas:SetScript("OnMouseUp", function()
        UI:OnCanvasUp()
    end)
    canvas:SetScript("OnUpdate", function()
        if not UI.dragging then
            return
        end
        if IsMouseButtonDown("LeftButton") or IsMouseButtonDown("RightButton") then
            UI:OnCanvasDrag()
        else
            UI:OnCanvasUp()
        end
    end)
end

-- Grid guides are built the first time they are switched on: 126 hairline
-- textures are cheap, but there is no reason to pay for them unasked.
function UI:UpdateGrid()
    if not self.canvas then
        return
    end
    local want = WP.db.showGrid and true or false
    if want and not self.gridTex then
        self.gridTex = {}
        for i = 1, Canvas.SIZE - 1 do
            local v = self.canvas:CreateTexture(nil, "OVERLAY")
            v:SetColorTexture(0, 0, 0, 0.18)
            v:SetSize(1, GRID)
            v:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", i * CELL, 0)
            local h = self.canvas:CreateTexture(nil, "OVERLAY")
            h:SetColorTexture(0, 0, 0, 0.18)
            h:SetSize(GRID, 1)
            h:SetPoint("TOPLEFT", self.canvas, "TOPLEFT", 0, -i * CELL)
            self.gridTex[#self.gridTex + 1] = v
            self.gridTex[#self.gridTex + 1] = h
        end
    end
    for _, t in ipairs(self.gridTex or {}) do
        t:SetShown(want)
    end
end

----------------------------------------------------------------------
-- Canvas input
----------------------------------------------------------------------

-- `clamp` keeps a shape drag anchored to the canvas edge when the cursor
-- wanders off it, which is how every other pixel editor behaves.
function UI:CellFromCursor(clamp)
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
        if not clamp then
            return nil
        end
        x = math.min(Canvas.SIZE, math.max(1, x))
        y = math.min(Canvas.SIZE, math.max(1, y))
    end
    return x, y
end

-- Every write to the canvas funnels through here so undo sees all of it.
function UI:Apply(p, x, y, color)
    if x < 1 or x > Canvas.SIZE or y < 1 or y > Canvas.SIZE then
        return
    end
    local i = Canvas.Index(x, y)
    if p.cells[i] == color then
        return
    end
    if self.undoScratch then
        self.undoScratch[#self.undoScratch + 1] = { i, p.cells[i] }
    end
    WP.Comm:Paint(p, x, y, color)
end

function UI:ApplyBrush(p, x, y, color)
    local n = self.brushSize or 1
    if n <= 1 then
        return self:Apply(p, x, y, color)
    end
    local half = math.floor((n - 1) / 2)
    for dy = -half, n - 1 - half do
        for dx = -half, n - 1 - half do
            self:Apply(p, x + dx, y + dy, color)
        end
    end
end

function UI:ActivePaintable()
    if self.galleryView then
        return nil
    end
    local p = Portraits.Active()
    if not p or p.locked then
        return nil
    end
    return p
end

function UI:OnCanvasDown(color)
    local p = self:ActivePaintable()
    if not p then
        return
    end
    local x, y = self:CellFromCursor()
    if not x then
        return
    end
    self.paintColor = color

    if self.tool == "PICK" then
        self:SelectColor(p.cells[Canvas.Index(x, y)] or 0)
        self:SetTool("PENCIL")
        return
    end

    if self.tool == "FILL" then
        -- Collect the region before painting any of it: the fill walk reads
        -- the same cells the paint would be mutating.
        local region = {}
        Canvas.FloodFill(p.cells, x, y, function(fx, fy)
            region[#region + 1] = { fx, fy }
        end)
        self.undoScratch = {}
        for _, c in ipairs(region) do
            self:Apply(p, c[1], c[2], color)
        end
        self:PushUndo(p)
        return
    end

    self.dragging = true
    self.anchor = { x, y }
    self.lastCell = nil
    if self.tool == "PENCIL" then
        self.undoScratch = {}
        self:Stroke(p, x, y)
    end
end

function UI:OnCanvasDrag()
    local p = self:ActivePaintable()
    if not p then
        return
    end
    if self.tool == "PENCIL" then
        local x, y = self:CellFromCursor()
        if not x then
            -- Cursor left the canvas mid-drag; restart the stroke when it
            -- returns rather than drawing a line across the gap.
            self.lastCell = nil
            return
        end
        self:Stroke(p, x, y)
    else
        local x, y = self:CellFromCursor(true)
        if x then
            self:PreviewShape(x, y)
        end
    end
end

function UI:OnCanvasUp()
    if not self.dragging then
        return
    end
    self.dragging = false
    local list = self:ClearPreview()
    local p = self:ActivePaintable()
    if p and self.tool ~= "PENCIL" then
        self.undoScratch = {}
        for _, c in ipairs(list) do
            self:Apply(p, c[1], c[2], self.paintColor)
        end
    end
    if p then
        self:PushUndo(p)
    end
    self.undoScratch = nil
    self.lastCell = nil
    self.anchor = nil
end

function UI:Stroke(p, x, y)
    local last = self.lastCell
    if last then
        if last[1] == x and last[2] == y then
            return
        end
        -- Fill in cells a fast drag skipped between two OnUpdate samples.
        local color = self.paintColor
        WP.ForLine(last[1], last[2], x, y, function(px, py)
            UI:ApplyBrush(p, px, py, color)
        end)
    else
        self:ApplyBrush(p, x, y, self.paintColor)
    end
    self.lastCell = { x, y }
end

function UI:ShapeCells(x, y)
    local list = {}
    local a = self.anchor
    if not a then
        return list
    end
    local filled = IsShiftKeyDown()
    local function add(px, py)
        list[#list + 1] = { px, py }
    end
    if self.tool == "LINE" then
        WP.ForLine(a[1], a[2], x, y, add)
    elseif self.tool == "RECT" then
        WP.ForRect(a[1], a[2], x, y, filled, add)
    elseif self.tool == "CIRCLE" then
        WP.ForEllipse(a[1], a[2], x, y, filled, add)
    end
    return list
end

-- Shapes are drawn straight onto the cell textures while dragging and only
-- committed on release, so an in-progress box costs no wire traffic.
function UI:PreviewShape(x, y)
    self:ClearPreview()
    local list = self:ShapeCells(x, y)
    self.previewList = list
    local col = Canvas.PALETTE[self.paintColor] or Canvas.PALETTE[0]
    for _, c in ipairs(list) do
        self.cellTex[Canvas.Index(c[1], c[2])]:SetColorTexture(col[1], col[2], col[3])
    end
end

function UI:ClearPreview()
    local list = self.previewList
    self.previewList = nil
    if not list then
        return {}
    end
    local cells = self:CurrentCells()
    if cells and self.cellTex then
        for _, c in ipairs(list) do
            local i = Canvas.Index(c[1], c[2])
            local col = Canvas.PALETTE[cells[i]] or Canvas.PALETTE[0]
            self.cellTex[i]:SetColorTexture(col[1], col[2], col[3])
        end
    end
    return list
end

----------------------------------------------------------------------
-- Undo (local, and broadcast like any other paint)
----------------------------------------------------------------------

function UI:PushUndo(p)
    local scratch = self.undoScratch
    self.undoScratch = nil
    if not scratch or #scratch == 0 then
        return
    end
    self.undoStack[#self.undoStack + 1] = { pid = p.id, cells = scratch }
    while #self.undoStack > MAX_UNDO do
        table.remove(self.undoStack, 1)
    end
    self:UpdateButtons()
end

function UI:UndoIndex()
    local p = Portraits.Active()
    if not p then
        return nil
    end
    for i = #self.undoStack, 1, -1 do
        if self.undoStack[i].pid == p.id then
            return i
        end
    end
    return nil
end

function UI:Undo()
    local p = self:ActivePaintable()
    if not p then
        return
    end
    local idx = self:UndoIndex()
    if not idx then
        WP.Print("Nothing to undo on '" .. p.name .. "'.")
        return
    end
    local entry = table.remove(self.undoStack, idx)
    -- Newest change first: a cell touched twice in one action must land back
    -- on the colour it had before the action started.
    for i = #entry.cells, 1, -1 do
        local x, y = Canvas.Coords(entry.cells[i][1])
        WP.Comm:Paint(p, x, y, entry.cells[i][2])
    end
    self:UpdateButtons()
end

----------------------------------------------------------------------
-- Bottom bars
----------------------------------------------------------------------

function UI:BuildBottomBars(f)
    -- Row 1 (y=14): scope/members, status, clear
    local scopeBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    self.scopeBtn = scopeBtn
    scopeBtn:SetSize(110, 22)
    scopeBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 14, 14)
    scopeBtn:SetScript("OnClick", function()
        UI:OnScopeClick()
    end)
    scopeBtn:SetScript("OnEnter", function(self)
        local p = Portraits.Active()
        if not p then
            return
        end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if p.dist ~= "MEMBERS" then
            GameTooltip:AddLine("Shared canvas scope")
            GameTooltip:AddLine("Click to cycle Auto / Guild / Party / Raid.", 1, 1, 1, true)
        else
            GameTooltip:AddLine("Members of '" .. p.name .. "'")
            for _, m in ipairs(p.members or {}) do
                local label = Ambiguate(m, "short")
                if Portraits.IsOwner(p, m) then
                    label = label .. " |cff9d9d9d(creator)|r"
                end
                GameTooltip:AddLine(label, 1, 1, 1)
            end
            GameTooltip:AddLine("Click to manage the roster.", 0.6, 0.6, 0.6, true)
        end
        GameTooltip:Show()
    end)
    scopeBtn:SetScript("OnLeave", function()
        GameTooltip:Hide()
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

    -- Row 2 (y=42): portrait picker, new, invite, lock, save, gallery
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
        UI:TogglePicker()
    end)
    Tooltip(self.portraitBtn, "Portraits", "Pick which canvas you are painting.")
    self.newBtn = rowBtn(50, "New", function()
        StaticPopup_Show("WOWPAINT_NEW")
    end)
    self.inviteBtn = rowBtn(60, "Invite", function()
        UI:OnInviteClick()
    end)
    -- A disabled button cannot be clicked, so the chat message explaining why
    -- it is disabled never reaches the person who needs it. Keep the mouse
    -- scripts alive while disabled and say it in the tooltip instead.
    self.inviteBtn:SetMotionScriptsWhileDisabled(true)
    self.inviteBtn:SetScript("OnEnter", function(btn)
        local p = Portraits.Active()
        GameTooltip:SetOwner(btn, "ANCHOR_TOP")
        GameTooltip:AddLine("Invite")
        if UI.galleryView then
            GameTooltip:AddLine("Not while viewing a saved piece - go back to painting first.",
                1, 1, 1, true)
        elseif p and p.dist ~= "MEMBERS" then
            GameTooltip:AddLine("The Shared canvas has no roster: everyone in your scope already paints it. Use New to create a portrait you can invite people to.",
                1, 1, 1, true)
        else
            GameTooltip:AddLine("Whisper an invitation. Prefills a friendly target if you have one.",
                1, 1, 1, true)
        end
        GameTooltip:Show()
    end)
    self.inviteBtn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    self.lockBtn = rowBtn(62, "Lock", function()
        UI:OnLockClick()
    end)
    self.lockBtn:SetMotionScriptsWhileDisabled(true)
    self.lockBtn:SetScript("OnEnter", function(btn)
        local p = Portraits.Active()
        GameTooltip:SetOwner(btn, "ANCHOR_TOP")
        GameTooltip:AddLine(p and p.locked and "Unlock" or "Lock")
        if p and not Portraits.IsOwner(p, WP.PlayerFullName()) then
            GameTooltip:AddLine("Only the portrait's creator can lock or unlock it.", 1, 1, 1, true)
        else
            GameTooltip:AddLine("Freezes the portrait for everyone: no painting, no clearing, until you unlock it. Inviting still works, which is how you share finished art.",
                1, 1, 1, true)
        end
        GameTooltip:Show()
    end)
    self.lockBtn:SetScript("OnLeave", function()
        GameTooltip:Hide()
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
-- Side panels
----------------------------------------------------------------------

-- side "FLOAT" makes the panel a sibling of the main window rather than a
-- child, so it can stand on its own when the canvas is closed. Its position
-- is set by the caller.
local function BuildPanel(f, globalName, titleText, w, h, side)
    local float = side == "FLOAT"
    local g = CreateFrame("Frame", globalName, float and UIParent or f, "BackdropTemplate")
    g:Hide()
    g:SetSize(w, h)
    if float then
        -- HIGH, not DIALOG: above the canvas window, but still below the
        -- StaticPopups this panel opens.
        g:SetFrameStrata("HIGH")
        g:SetClampedToScreen(true)
    elseif side == "LEFT" then
        g:SetPoint("TOPRIGHT", f, "TOPLEFT", 8, 0)
    else
        g:SetPoint("TOPLEFT", f, "TOPRIGHT", -8, 0)
    end
    g:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true,
        tileSize = 32,
        edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })

    g.title = g:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    g.title:SetPoint("TOP", g, "TOP", 0, -16)
    g.title:SetText(titleText)

    local close = CreateFrame("Button", nil, g, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", g, "TOPRIGHT", -6, -6)

    tinsert(UISpecialFrames, globalName)
    return g
end

local function BuildPager(g, onChange)
    local text = g:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    text:SetPoint("BOTTOM", g, "BOTTOM", 0, 70)

    local prev = CreateFrame("Button", nil, g, "UIPanelButtonTemplate")
    prev:SetSize(50, 20)
    prev:SetPoint("BOTTOMLEFT", g, "BOTTOMLEFT", 16, 16)
    prev:SetText("<")
    prev:SetScript("OnClick", function()
        onChange(-1)
    end)

    local next = CreateFrame("Button", nil, g, "UIPanelButtonTemplate")
    next:SetSize(50, 20)
    next:SetPoint("BOTTOMRIGHT", g, "BOTTOMRIGHT", -16, 16)
    next:SetText(">")
    next:SetScript("OnClick", function()
        onChange(1)
    end)
    return text
end

----------------------------------------------------------------------
-- Gallery panel
----------------------------------------------------------------------

function UI:BuildGalleryPanel(f)
    -- Taller than the other panels: 8 rows plus the pager plus the Back
    -- control, which only appears while an entry is open read-only.
    local g = BuildPanel(f, "WoWPaintGalleryFrame", "Gallery", 300, 500, "RIGHT")
    self.gallery = g

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

    self.galleryPageText = BuildPager(g, function(delta)
        UI.galleryPage = math.max(1, UI.galleryPage + delta)
        UI:RefreshGallery()
    end)

    -- Explicit way out of read-only viewing, without closing the panel.
    self.galleryBackBtn = CreateFrame("Button", nil, g, "UIPanelButtonTemplate")
    self.galleryBackBtn:SetSize(120, 22)
    self.galleryBackBtn:SetPoint("BOTTOM", g, "BOTTOM", 0, 42)
    self.galleryBackBtn:SetText("Back to painting")
    self.galleryBackBtn:Hide()
    self.galleryBackBtn:SetScript("OnClick", function()
        UI.galleryView = nil
        UI:UpdateAll()
    end)
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
    self.galleryBackBtn:SetShown(self.galleryView ~= nil)
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
-- Portrait picker panel
----------------------------------------------------------------------

function UI:BuildPickerPanel(f)
    -- Floating: this is also what the minimap button opens, and it has to
    -- work as a launcher with the canvas window closed.
    local g = BuildPanel(f, "WoWPaintPortraitsFrame", "Portraits", 300, 440, "FLOAT")
    self.picker = g

    self.pickerRows = {}
    for i = 1, PICKER_ROWS do
        local row = CreateFrame("Button", nil, g)
        row:SetSize(264, 44)
        row:SetPoint("TOPLEFT", g, "TOPLEFT", 18, -34 - (i - 1) * 46)

        row.highlight = row:CreateTexture(nil, "BACKGROUND")
        row.highlight:SetAllPoints(row)
        row.highlight:SetColorTexture(0.5, 0.65, 0.85, 0.22)
        row.highlight:Hide()

        row.text = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.text:SetPoint("TOPLEFT", row, "TOPLEFT", 2, -2)
        row.text:SetPoint("RIGHT", row, "RIGHT", -2, 0)
        row.text:SetJustifyH("LEFT")

        row.sub = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.sub:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 2, 5)
        row.sub:SetJustifyH("LEFT")

        row.openBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        row.openBtn:SetSize(56, 18)
        row.openBtn:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -62, 2)
        row.openBtn:SetText("Paint")

        row.delBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        row.delBtn:SetSize(56, 18)
        row.delBtn:SetPoint("LEFT", row.openBtn, "RIGHT", 6, 0)
        row.delBtn:SetText("Remove")

        self.pickerRows[i] = row
    end

    self.pickerPageText = BuildPager(g, function(delta)
        UI.pickerPage = math.max(1, UI.pickerPage + delta)
        UI:RefreshPicker()
    end)

    local canvasBtn = CreateFrame("Button", nil, g, "UIPanelButtonTemplate")
    canvasBtn:SetSize(150, 22)
    canvasBtn:SetPoint("BOTTOM", g, "BOTTOM", 0, 94)
    canvasBtn:SetText("Open the canvas")
    canvasBtn:SetScript("OnClick", function()
        UI.frame:Show()
    end)
    self.pickerCanvasBtn = canvasBtn

    local newBtn = CreateFrame("Button", nil, g, "UIPanelButtonTemplate")
    newBtn:SetSize(132, 22)
    newBtn:SetPoint("BOTTOM", g, "BOTTOM", -68, 42)
    newBtn:SetText("New portrait")
    newBtn:SetScript("OnClick", function()
        StaticPopup_Show("WOWPAINT_NEW")
    end)

    local galleryBtn = CreateFrame("Button", nil, g, "UIPanelButtonTemplate")
    galleryBtn:SetSize(132, 22)
    galleryBtn:SetPoint("BOTTOM", g, "BOTTOM", 68, 42)
    galleryBtn:SetText("Gallery")
    galleryBtn:SetScript("OnClick", function()
        -- Viewing a saved piece renders it into the main canvas grid, so the
        -- gallery only makes sense with the window up.
        UI.frame:Show()
        if not UI.gallery:IsShown() then
            UI:ToggleGallery()
        end
    end)
end

-- Beside the canvas when it is open, centre-screen when it is not.
function UI:AnchorPicker()
    local g = self.picker
    g:ClearAllPoints()
    if self.frame:IsShown() then
        g:SetPoint("TOPRIGHT", self.frame, "TOPLEFT", 8, 0)
    else
        g:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
end

function UI:TogglePicker()
    if self.picker:IsShown() then
        self.picker:Hide()
    else
        self.members:Hide()
        self.pickerPage = 1
        self:AnchorPicker()
        self.picker:Show()
        self:RefreshPicker()
    end
end

function UI:RefreshPicker()
    if not self.picker or not self.picker:IsShown() then
        return
    end
    local list = Portraits.List()
    local pages = math.max(1, math.ceil(#list / PICKER_ROWS))
    if self.pickerPage > pages then
        self.pickerPage = pages
    end
    local page = self.pickerPage
    local activeId = Portraits.Active().id
    for i = 1, PICKER_ROWS do
        local row = self.pickerRows[i]
        local p = list[(page - 1) * PICKER_ROWS + i]
        if p then
            row:Show()
            row.highlight:SetShown(p.id == activeId)
            row.text:SetText(p.name .. (p.locked and "  |cffffcc00(locked)|r" or ""))
            if p.dist == "MEMBERS" then
                local n = #(p.members or {})
                row.sub:SetText(("%d member%s%s"):format(n, n == 1 and "" or "s",
                    Portraits.IsOwner(p, WP.PlayerFullName()) and "  -  yours" or ""))
            else
                row.sub:SetText("shared - " .. (CHANNEL_LABELS[p.dist] or p.dist))
            end
            row.openBtn:SetEnabled(p.id ~= activeId)
            row.openBtn:SetScript("OnClick", function()
                UI:OpenPortrait(p.id)
            end)
            row.delBtn:SetEnabled(p.id ~= Portraits.SHARED_ID)
            row.delBtn:SetScript("OnClick", function()
                StaticPopup_Show("WOWPAINT_DELETE_PORTRAIT", p.name, nil, { id = p.id })
            end)
        else
            row:Hide()
        end
    end
    self.pickerPageText:SetText(("Page %d / %d  -  %d portrait%s"):format(
        page, pages, #list, #list == 1 and "" or "s"))
    self.pickerCanvasBtn:SetEnabled(not self.frame:IsShown())
end

function UI:OpenPortrait(id)
    local p = Portraits.Get(id)
    if not p or not Portraits.SetActive(id) then
        return
    end
    self.galleryView = nil
    -- Picking a portrait is a request to paint it, including from the
    -- minimap launcher with the canvas closed.
    self.frame:Show()
    self:UpdateAll()
    WP.Comm:SendHello(p, false)
    WP.Print("Now painting '" .. p.name .. "'.")
end

----------------------------------------------------------------------
-- Members panel (uninvite is the creator's alone)
----------------------------------------------------------------------

function UI:BuildMembersPanel(f)
    local g = BuildPanel(f, "WoWPaintMembersFrame", "Members", 300, 410, "LEFT")
    self.members = g

    self.memberRows = {}
    for i = 1, MEMBER_ROWS do
        local row = CreateFrame("Frame", nil, g)
        row:SetSize(264, 26)
        row:SetPoint("TOPLEFT", g, "TOPLEFT", 18, -40 - (i - 1) * 28)

        row.text = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.text:SetPoint("LEFT", row, "LEFT", 2, 0)
        row.text:SetJustifyH("LEFT")

        row.kickBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        row.kickBtn:SetSize(72, 18)
        row.kickBtn:SetPoint("RIGHT", row, "RIGHT", -2, 0)
        row.kickBtn:SetText("Uninvite")

        self.memberRows[i] = row
    end

    self.memberPageText = BuildPager(g, function(delta)
        UI.memberPage = math.max(1, UI.memberPage + delta)
        UI:RefreshMembers()
    end)

    local inviteBtn = CreateFrame("Button", nil, g, "UIPanelButtonTemplate")
    inviteBtn:SetSize(150, 22)
    inviteBtn:SetPoint("BOTTOM", g, "BOTTOM", 0, 42)
    inviteBtn:SetText("Invite a player")
    inviteBtn:SetScript("OnClick", function()
        UI:OnInviteClick()
    end)
    self.memberInviteBtn = inviteBtn
end

function UI:ToggleMembers()
    local p = Portraits.Active()
    if not p or p.dist ~= "MEMBERS" then
        WP.Print("The Shared canvas has no roster - everyone in your scope already paints it. Create a portrait to invite people.")
        return
    end
    if self.members:IsShown() then
        self.members:Hide()
    else
        self.picker:Hide()
        self.memberPage = 1
        self.members:Show()
        self:RefreshMembers()
    end
end

function UI:RefreshMembers()
    if not self.members or not self.members:IsShown() then
        return
    end
    local p = Portraits.Active()
    if not p or p.dist ~= "MEMBERS" then
        self.members:Hide()
        return
    end
    local roster = p.members or {}
    local iAmOwner = Portraits.IsOwner(p, WP.PlayerFullName())
    local pages = math.max(1, math.ceil(#roster / MEMBER_ROWS))
    if self.memberPage > pages then
        self.memberPage = pages
    end
    local page = self.memberPage
    self.members.title:SetText("Members of '" .. p.name:sub(1, 18) .. "'")
    for i = 1, MEMBER_ROWS do
        local row = self.memberRows[i]
        local name = roster[(page - 1) * MEMBER_ROWS + i]
        if name then
            row:Show()
            local isOwner = Portraits.IsOwner(p, name)
            local label = Ambiguate(name, "short")
            if isOwner then
                label = label .. "  |cff9d9d9d(creator)|r"
            elseif name == WP.PlayerFullName() then
                label = label .. "  |cff9d9d9d(you)|r"
            end
            row.text:SetText(label)
            -- Only the creator may uninvite, and never themselves.
            row.kickBtn:SetShown(iAmOwner and not isOwner)
            row.kickBtn:SetScript("OnClick", function()
                UI:Uninvite(name)
            end)
        else
            row:Hide()
        end
    end
    local removed = #(p.removed or {})
    self.memberPageText:SetText(("Page %d / %d  -  %d of %d seats%s"):format(
        page, pages, #roster, Portraits.MAX_MEMBERS,
        removed > 0 and ("  -  %d uninvited"):format(removed) or ""))
    self.memberInviteBtn:SetEnabled(#roster < Portraits.MAX_MEMBERS)
end

function UI:Uninvite(name)
    local p = Portraits.Active()
    if not p then
        return
    end
    local full = WP.NormalizeName(name)
    if not full then
        WP.Print("Who should be removed? /wowpaint uninvite <player>")
        return
    end
    if not Portraits.IsOwner(p, WP.PlayerFullName()) then
        WP.Print("Only the portrait's creator can uninvite members.")
        return
    end
    if not Portraits.IsMember(p, full) then
        WP.Print(Ambiguate(full, "short") .. " is not a member of '" .. p.name .. "'.")
        return
    end
    StaticPopup_Show("WOWPAINT_UNINVITE", Ambiguate(full, "short"), nil, { name = full })
end

function UI:DoUninvite(name)
    local p = Portraits.Active()
    if not p then
        return
    end
    local ok, err = WP.Comm:SendKick(p, name)
    if ok then
        WP.Print("Removed " .. Ambiguate(name, "short") .. " from '" .. p.name .. "'.")
    else
        WP.Print(err or "Could not remove that member.")
    end
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
    StaticPopup_Show("WOWPAINT_INVITE_SEND", p.name, nil, { prefill = prefill })
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

-- `desired` is true/false from the explicit slash verbs; the button passes
-- nil and toggles.
function UI:OnLockClick(desired)
    local p = Portraits.Active()
    if not p then
        return
    end
    if not Portraits.Lockable(p) then
        WP.Print("The Shared canvas cannot be locked - create a portrait for work you want to freeze.")
        return
    end
    if not Portraits.IsOwner(p, WP.PlayerFullName()) then
        WP.Print("Only the portrait's creator can lock or unlock it.")
        return
    end
    if desired == nil then
        desired = not p.locked
    end
    if desired == p.locked then
        WP.Print(("'%s' is already %s."):format(p.name, desired and "locked" or "unlocked"))
        return
    end
    WP.Comm:SendLockState(p, desired)
end

function UI:ShowInvitePopup(data)
    StaticPopup_Show("WOWPAINT_INVITE_RECV", Ambiguate(data.from, "short"), data.name, data)
end

function UI:OnScopeClick()
    local p = Portraits.Active()
    if p.dist == "MEMBERS" then
        self:ToggleMembers()
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
    self:UpdateButtons()
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
        self.status:SetText(("Viewing '%s' (saved %s) - read-only"):format(
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
        -- The roster counts us; we whisper to everyone else on it.
        local others = math.max(0, #(p.members or {}) - 1)
        text = ("Whispering %d member%s  -  rev %d"):format(others, others == 1 and "" or "s", p.rev)
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
    local viewing = self.galleryView ~= nil
    local paintable = not viewing and not p.locked

    self.portraitBtn:SetText("Portrait: " .. p.name:sub(1, 14))
    if p.dist == "MEMBERS" then
        self.scopeBtn:SetText(("Members: %d"):format(#(p.members or {})))
    else
        self.scopeBtn:SetText("Scope: " .. (CHANNEL_LABELS[p.dist] or p.dist))
    end
    self.inviteBtn:SetEnabled(p.dist == "MEMBERS" and not viewing)
    if Portraits.Lockable(p) then
        self.lockBtn:Show()
        self.lockBtn:SetText(p.locked and "Unlock" or "Lock")
        self.lockBtn:SetEnabled(Portraits.IsOwner(p, me) and not viewing)
    else
        self.lockBtn:Hide()
    end
    self.clearBtn:SetEnabled(paintable)
    self.saveBtn:SetEnabled(not viewing)

    for id, btn in pairs(self.toolBtns) do
        btn:SetEnabled(paintable)
        if id == self.tool then
            btn:LockHighlight()
        else
            btn:UnlockHighlight()
        end
    end
    self.sizeBtn:SetText("Nib " .. (self.brushSize or 1))
    self.sizeBtn:SetEnabled(paintable)
    self.undoBtn:SetEnabled(paintable and self:UndoIndex() ~= nil)
    if WP.db.showGrid then
        self.gridBtn:LockHighlight()
    else
        self.gridBtn:UnlockHighlight()
    end
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
    self:UpdateGrid()
    self:RedrawAll()
    self:RefreshGallery()
    self:RefreshPicker()
    self:RefreshMembers()
end

function UI:Toggle()
    self:EnsureFrame()
    if self.frame:IsShown() then
        self.frame:Hide()
    else
        self.frame:Show()
    end
end

----------------------------------------------------------------------
-- Minimap button
----------------------------------------------------------------------

local MINIMAP_RADIUS = 80
-- WoW runs Lua 5.1 (math.atan2); the two-argument math.atan of 5.4 is the
-- same function, which keeps this file loadable off-client too.
local atan2 = math.atan2 or math.atan

function UI:PositionMinimapButton()
    local b = self.minimapBtn
    if not b then
        return
    end
    local angle = math.rad(WP.db.minimap.angle or 200)
    b:ClearAllPoints()
    b:SetPoint("CENTER", Minimap, "CENTER",
        math.cos(angle) * MINIMAP_RADIUS, math.sin(angle) * MINIMAP_RADIUS)
end

local function DragUpdate()
    local mx, my = Minimap:GetCenter()
    if not mx then
        return
    end
    local scale = Minimap:GetEffectiveScale()
    local cx, cy = GetCursorPosition()
    WP.db.minimap.angle = math.deg(atan2(cy / scale - my, cx / scale - mx)) % 360
    UI:PositionMinimapButton()
end

function UI:EnsureMinimapButton()
    if self.minimapBtn or not Minimap then
        return
    end
    local b = CreateFrame("Button", "WoWPaintMinimapButton", Minimap)
    self.minimapBtn = b
    b:SetSize(31, 31)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(Minimap:GetFrameLevel() + 8)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:RegisterForDrag("LeftButton")
    b:SetMovable(true)

    -- The icon is four quads of the addon's own palette rather than an art
    -- path: it reads as pixel art at this size, and it cannot break when
    -- Blizzard moves an icon file.
    for i, colorIndex in ipairs({ 5, 8, 10, 13 }) do
        local t = b:CreateTexture(nil, "ARTWORK")
        local col = Canvas.PALETTE[colorIndex]
        t:SetColorTexture(col[1], col[2], col[3])
        t:SetSize(8, 8)
        t:SetPoint("TOPLEFT", b, "TOPLEFT",
            7 + ((i - 1) % 2) * 8, -6 - math.floor((i - 1) / 2) * 8)
    end

    local border = b:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)
    b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    b:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", DragUpdate)
        GameTooltip:Hide()
    end)
    b:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)
    b:SetScript("OnClick", function(_, button)
        UI:EnsureFrame()
        if button == "RightButton" then
            UI:TogglePicker()
        else
            UI:Toggle()
        end
    end)
    b:SetScript("OnEnter", function(self)
        local p = Portraits.Active()
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("WoWPaint")
        if p then
            local sub
            if p.dist == "MEMBERS" then
                local n = #(p.members or {})
                sub = ("%d member%s"):format(n, n == 1 and "" or "s")
            else
                sub = "shared, " .. (CHANNEL_LABELS[p.dist] or p.dist)
            end
            GameTooltip:AddLine(("Painting '%s' (%s)%s"):format(p.name, sub,
                p.locked and "  |cffffcc00locked|r" or ""), 1, 1, 1, true)
        end
        GameTooltip:AddLine("Left-click: open the canvas", 0.6, 0.6, 0.6)
        GameTooltip:AddLine("Right-click: portraits, gallery, canvas", 0.6, 0.6, 0.6)
        GameTooltip:AddLine("Drag: move around the minimap", 0.6, 0.6, 0.6)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    self:PositionMinimapButton()
    b:SetShown(not WP.db.minimap.hide)
end

function UI:ToggleMinimapButton()
    WP.db.minimap.hide = not WP.db.minimap.hide
    if self.minimapBtn then
        self.minimapBtn:SetShown(not WP.db.minimap.hide)
    end
    WP.Print(WP.db.minimap.hide
        and "Minimap button hidden - /wowpaint minimap brings it back."
        or "Minimap button shown.")
end
