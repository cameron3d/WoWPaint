local ADDON_NAME, WP = ...

local Canvas = WP.Canvas

local VALID_CHANNELS = { AUTO = true, GUILD = true, PARTY = true, RAID = true }

function WP.Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff7ec0eeWoWPaint:|r " .. tostring(msg))
end

local function InitDB()
    WoWPaintDB = WoWPaintDB or {}
    local db = WoWPaintDB
    db.dbVersion = 1
    if type(db.cells) ~= "table" then
        db.cells = {}
    end
    for i = 1, Canvas.NUM_CELLS do
        local v = db.cells[i]
        if type(v) ~= "number" or v < 0 or v >= Canvas.NUM_COLORS or v % 1 ~= 0 then
            db.cells[i] = 0
        end
    end
    if type(db.rev) ~= "number" or db.rev < 0 then
        db.rev = 0
    end
    if not VALID_CHANNELS[db.channel] then
        db.channel = "AUTO"
    end
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
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        local isLogin, isReload = ...
        if isLogin or isReload then
            -- Give the world (and guild roster) a moment to settle before
            -- asking peers for the current canvas.
            C_Timer.After(8, function()
                WP.Comm:SendHello(true)
            end)
        end
    elseif event == "CHAT_MSG_ADDON" then
        WP.Comm:OnMessage(...)
    end
end)

SLASH_WOWPAINT1 = "/wowpaint"
SLASH_WOWPAINT2 = "/wpaint"
SlashCmdList["WOWPAINT"] = function(input)
    input = (input or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local cmd, rest = input:match("^(%S*)%s*(.*)$")
    cmd = cmd:lower()
    rest = rest:lower()

    if cmd == "" or cmd == "show" or cmd == "toggle" then
        WP.UI:Toggle()
    elseif cmd == "sync" then
        if WP.Comm:SendHello(true) then
            WP.Print("Requested canvas sync.")
        else
            WP.Print("No broadcast channel available - join a guild or group, or check /wowpaint channel.")
        end
    elseif cmd == "clear" then
        StaticPopup_Show("WOWPAINT_CLEAR")
    elseif cmd == "channel" then
        local mode = rest:upper()
        if VALID_CHANNELS[mode] then
            WP.db.channel = mode
            WP.UI:UpdateStatus()
            WP.Print("Scope set to " .. mode:lower() .. ".")
        else
            WP.Print(("Scope is %s. Usage: /wowpaint channel auto | guild | party | raid"):format(
                (WP.db.channel or "AUTO"):lower()))
        end
    else
        WP.Print("Commands:")
        WP.Print("  /wowpaint - toggle the canvas")
        WP.Print("  /wowpaint sync - re-request the latest canvas from peers")
        WP.Print("  /wowpaint channel auto | guild | party | raid - set broadcast scope")
        WP.Print("  /wowpaint clear - clear the canvas for everyone (asks first)")
    end
end
