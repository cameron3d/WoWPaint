local ADDON_NAME, WP = ...

local Canvas = WP.Canvas

local UI = {}
WP.UI = UI

local CELL = 8                      -- on-screen pixels per canvas cell
local GRID = Canvas.SIZE * CELL     -- 512
local FRAME_W = GRID + 28
local FRAME_H = 620

local SWATCH = 24
local SWATCH_GAP = 8

local CHANNEL_LABELS = { AUTO = "Auto", GUILD = "Guild", PARTY = "Party", RAID = "Raid" }
local CHANNEL_ORDER = { "AUTO", "GUILD", "PARTY", "RAID" }

UI.selectedColor = 3 -- black

StaticPopupDialogs["WOWPAINT_CLEAR"] = {
    text = "Clear the shared canvas? This clears it for everyone in your current scope.",
    button1 = YES,
    button2 = NO,
    OnAccept = function()
        WP.Comm:SendClear()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

function UI:EnsureFrame()
    if self.frame then
        return
    end

    local f = CreateFrame("Frame", "WoWPaintFrame", UIParent, "BackdropTemplate")
    self.frame = f
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

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOP", f, "TOP", 0, -16)
    title:SetText("WoWPaint")

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)

    self:BuildPalette(f)
    self:BuildCanvas(f)
    self:BuildBottomBar(f)

    tinsert(UISpecialFrames, "WoWPaintFrame")

    f:SetScript("OnShow", function()
        UI:RedrawAll()
        UI:UpdateStatus()
        WP.Comm:SendHello(false)
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
            WP.Comm:Paint(px, py, color)
        end)
    else
        WP.Comm:Paint(x, y, self.paintColor)
    end
    self.lastCell = { x, y }
end

function UI:BuildBottomBar(f)
    local channelBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    self.channelBtn = channelBtn
    channelBtn:SetSize(110, 22)
    channelBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 14, 14)
    channelBtn:SetScript("OnClick", function()
        UI:CycleChannel()
    end)

    local clearBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    clearBtn:SetSize(70, 22)
    clearBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -14, 14)
    clearBtn:SetText("Clear")
    clearBtn:SetScript("OnClick", function()
        StaticPopup_Show("WOWPAINT_CLEAR")
    end)

    local status = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    self.status = status
    status:SetPoint("BOTTOM", f, "BOTTOM", 0, 19)
end

function UI:CycleChannel()
    local current = WP.db.channel or "AUTO"
    local idx = 1
    for i, mode in ipairs(CHANNEL_ORDER) do
        if mode == current then
            idx = i
            break
        end
    end
    WP.db.channel = CHANNEL_ORDER[idx % #CHANNEL_ORDER + 1]
    self:UpdateStatus()
end

function UI:UpdateCell(x, y)
    if not self.cellTex then
        return
    end
    local i = Canvas.Index(x, y)
    local col = Canvas.PALETTE[WP.db.cells[i]] or Canvas.PALETTE[0]
    self.cellTex[i]:SetColorTexture(col[1], col[2], col[3])
end

function UI:RedrawAll()
    if not self.cellTex then
        return
    end
    local cells = WP.db.cells
    for i = 1, Canvas.NUM_CELLS do
        local col = Canvas.PALETTE[cells[i]] or Canvas.PALETTE[0]
        self.cellTex[i]:SetColorTexture(col[1], col[2], col[3])
    end
end

function UI:UpdateStatus()
    if not self.status then
        return
    end
    local scope = WP.db.channel or "AUTO"
    if self.channelBtn then
        self.channelBtn:SetText("Scope: " .. (CHANNEL_LABELS[scope] or scope))
    end
    local text
    if WP.Comm.sync then
        text = "Syncing canvas from " .. Ambiguate(WP.Comm.sync.source, "short") .. "..."
    else
        local dist = WP.Comm:GetDistribution()
        if dist then
            text = ("Broadcasting to %s  -  rev %d"):format(CHANNEL_LABELS[dist] or dist, WP.db.rev)
        else
            text = ("|cffff6060Offline|r (no %s available)  -  rev %d"):format(
                CHANNEL_LABELS[scope] or scope, WP.db.rev)
        end
    end
    self.status:SetText(text)
end

function UI:Toggle()
    self:EnsureFrame()
    if self.frame:IsShown() then
        self.frame:Hide()
    else
        self.frame:Show()
    end
end
