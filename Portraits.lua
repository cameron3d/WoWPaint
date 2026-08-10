local ADDON_NAME, WP = ...

local Canvas = WP.Canvas

local Portraits = {}
WP.Portraits = Portraits

Portraits.SHARED_ID = "000000" -- every client agrees on the built-in Shared canvas
Portraits.MAX_NAME = 24
Portraits.MAX_MEMBERS = 24     -- bounds whisper fan-out per paint batch
Portraits.MAX_REMOVED = 32     -- bounds the uninvite tombstone set

-- 6 random chars from the wire alphabet; retried on the (negligible) chance
-- of colliding with an existing portrait or the reserved Shared id.
function Portraits.GenerateId()
    local chars = {}
    for i = 1, 6 do
        chars[i] = WP.EncodeChar(math.random(0, 63))
    end
    local id = table.concat(chars)
    if id == Portraits.SHARED_ID or (WP.db and WP.db.portraits and WP.db.portraits[id]) then
        return Portraits.GenerateId()
    end
    return id
end

function Portraits.ValidId(id)
    if type(id) ~= "string" or #id ~= 6 then
        return false
    end
    for i = 1, 6 do
        if not WP.DecodeChar(id:sub(i, i)) then
            return false
        end
    end
    return true
end

-- Portrait names travel on the wire (invites) and rosters are
-- comma-separated, so strip the characters that would break either, plus
-- chat escapes.
function Portraits.SanitizeName(name)
    name = tostring(name or ""):gsub("[|,]", ""):gsub("^%s+", ""):gsub("%s+$", "")
    return name:sub(1, Portraits.MAX_NAME)
end

-- Roster names ride the wire inside comma-separated M messages and end up in
-- chat output, so reject the characters that would break the protocol or
-- smuggle chat escapes. Accented and other non-ASCII letters are legal in WoW
-- names, so they must pass through untouched.
-- A leading "-" or "+" is what marks a tombstone or a revocation inside an M
-- message. No real character name starts with either, so rejecting them here
-- stops a member called "-Alice-Realm" from being laundered into a kick for
-- Alice the next time the owner gossips the roster.
function Portraits.ValidMemberName(name)
    if type(name) ~= "string" or name == "" or #name > 48 then
        return false
    end
    return not name:find("^[-+]") and not name:find("[|,:%c]")
end

function Portraits.NewCells()
    local cells = {}
    for i = 1, Canvas.NUM_CELLS do
        cells[i] = 0
    end
    return cells
end

function Portraits.Create(name, dist, id, owner)
    local p = {
        id = id or Portraits.GenerateId(),
        name = Portraits.SanitizeName(name),
        dist = dist or "MEMBERS",
        owner = owner,
        cells = Portraits.NewCells(),
        rev = 0,
        locked = false,
        lockedBy = nil,
        createdAt = time(),
    }
    if p.dist == "MEMBERS" then
        p.members = {}
        p.removed = {}
        if owner then
            p.members[1] = owner
        end
    end
    WP.db.portraits[p.id] = p
    return p
end

function Portraits.Get(id)
    return WP.db and WP.db.portraits and WP.db.portraits[id] or nil
end

function Portraits.Active()
    return Portraits.Get(WP.db.activeId) or Portraits.Get(Portraits.SHARED_ID)
end

function Portraits.SetActive(id)
    if not Portraits.Get(id) then
        return false
    end
    -- Pending strokes belong to the portrait they were painted on.
    WP.Comm:FlushPaintOps()
    WP.db.activeId = id
    return true
end

-- Scope portraits (Shared) have implicit membership; MEMBERS portraits
-- trust their roster only.
function Portraits.IsMember(p, who)
    if p.dist ~= "MEMBERS" then
        return true
    end
    if not p.members or not who then
        return false
    end
    for _, m in ipairs(p.members) do
        if m == who then
            return true
        end
    end
    return false
end

-- Add-only union merge (concurrent invites converge). Returns true if the
-- roster changed. Capped so a hostile roster can't explode whisper fan-out.
function Portraits.AddMembers(p, names)
    if p.dist ~= "MEMBERS" then
        return false
    end
    p.members = p.members or {}
    local added = false
    for _, name in ipairs(names) do
        if Portraits.ValidMemberName(name)
            and #p.members < Portraits.MAX_MEMBERS
            and not Portraits.IsRemoved(p, name)
            and not Portraits.IsMember(p, name) then
            p.members[#p.members + 1] = name
            added = true
        end
    end
    return added
end

function Portraits.IsRemoved(p, who)
    if not p.removed or not who then
        return false
    end
    for _, m in ipairs(p.removed) do
        if m == who then
            return true
        end
    end
    return false
end

-- Uninviting is the owner's privilege alone (callers enforce that). Rosters
-- union-merge, so a bare removal would be undone by the next roster gossip
-- from a member who had not heard about it yet: every removal leaves an
-- add-only tombstone that suppresses the name until the owner revokes it.
-- The owner is never removable.
function Portraits.RemoveMembers(p, names)
    if p.dist ~= "MEMBERS" then
        return false
    end
    p.members = p.members or {}
    p.removed = p.removed or {}
    local changed = false
    for _, name in ipairs(names) do
        if Portraits.ValidMemberName(name) and not Portraits.IsOwner(p, name) then
            for i = #p.members, 1, -1 do
                if p.members[i] == name then
                    table.remove(p.members, i)
                    changed = true
                end
            end
            if not Portraits.IsRemoved(p, name) and #p.removed < Portraits.MAX_REMOVED then
                p.removed[#p.removed + 1] = name
                changed = true
            end
        end
    end
    return changed
end

-- Lift a tombstone so the owner can re-invite someone they removed.
function Portraits.Unremove(p, name)
    if not p.removed then
        return false
    end
    for i = #p.removed, 1, -1 do
        if p.removed[i] == name then
            table.remove(p.removed, i)
            return true
        end
    end
    return false
end

function Portraits.FindByName(name)
    name = Portraits.SanitizeName(name):lower()
    if name == "" then
        return nil
    end
    for _, p in pairs(WP.db.portraits) do
        if p.name:lower() == name then
            return p
        end
    end
    return nil
end

function Portraits.IsOwner(p, who)
    return p.owner ~= nil and who ~= nil and p.owner == who
end

function Portraits.Lockable(p)
    return p.id ~= Portraits.SHARED_ID
end

-- Stable display order: Shared first, then creation order.
function Portraits.List()
    local arr = {}
    for _, p in pairs(WP.db.portraits) do
        arr[#arr + 1] = p
    end
    table.sort(arr, function(a, b)
        if a.id == Portraits.SHARED_ID then
            return true
        end
        if b.id == Portraits.SHARED_ID then
            return false
        end
        if (a.createdAt or 0) ~= (b.createdAt or 0) then
            return (a.createdAt or 0) < (b.createdAt or 0)
        end
        return a.id < b.id
    end)
    return arr
end

function Portraits.Delete(id)
    if id == Portraits.SHARED_ID or not Portraits.Get(id) then
        return false
    end
    WP.db.portraits[id] = nil
    if WP.db.activeId == id then
        WP.db.activeId = Portraits.SHARED_ID
    end
    return true
end

----------------------------------------------------------------------
-- Gallery: local, immutable snapshots of finished (or in-progress) work
----------------------------------------------------------------------

function Portraits.SaveToGallery(p, name)
    local cells = {}
    for i = 1, Canvas.NUM_CELLS do
        cells[i] = p.cells[i]
    end
    local entry = {
        name = Portraits.SanitizeName(name and name ~= "" and name or p.name),
        cells = cells,
        savedAt = time(),
        source = p.name,
    }
    WP.db.gallery[#WP.db.gallery + 1] = entry
    return entry
end

function Portraits.DeleteGalleryEntry(index)
    if WP.db.gallery[index] then
        table.remove(WP.db.gallery, index)
        return true
    end
    return false
end
