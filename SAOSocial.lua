-- SAO Frames: Sword Art Online-styled social menu (SAOSocial.lua).
--
-- A round button that pops out a vertical list of white options (Party, Friend, Guild,
-- Raid, Whisper). Each option opens a second-level list that slides out beside it;
-- the entries there run plain, non-protected API calls. Nothing here is secure.
--
-- Public (on ns): InitSocial, ToggleSocialMenu, SocialSetLocked, SocialSetEnabled,
-- IsSocialEnabled, SocialResetPosition. Saved settings: db.social = { enabled, pos }.
-- Macro/keybind: /click SAOFrames_SocialButton toggles the menu.

local ADDON, ns = ...

---------------------------------------------------------------------------
-- Constants
---------------------------------------------------------------------------

local WHITE = "Interface\\Buttons\\WHITE8X8"
local BUTTON_SIZE = 40
local ROW_W, ROW_H, ROW_GAP = 156, 26, 4
local GAP = 14                 -- space between the button / list and the next list
local SLIDE_TIME = 0.14
local MAX_SUB = 6

local SOCIAL_DEFAULTS = { enabled = true, pos = { "LEFT", "LEFT", 24, 140 } }

-- Colours (r, g, b[, a]).
local C = {
    text = { 0.24, 0.24, 0.27 }, textOff = { 0.62, 0.62, 0.65 },
    disc = { 0.30, 0.30, 0.33 }, discOff = { 0.66, 0.66, 0.69 },
    fill = { 1, 1, 1, 0.86 }, fillOff = { 1, 1, 1, 0.55 },
    hover = { 1, 0.86, 0.66, 0.94 }, press = { 1, 0.58, 0.14, 0.97 },
    orange = { 1, 0.58, 0.14 }, border = { 0.62, 0.62, 0.66, 0.9 },
    button = { 0.90, 0.90, 0.92 }, cyan = { 0.40, 0.85, 1.00 },
}

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------

local sdb             -- db.social
local button          -- the round button
local menu, sub       -- first- and second-level lists
local mainRows, subRows = {}, {}
local openEntry       -- top-level entry whose submenu is shown
local dir = 1         -- 1 = lists open to the right, -1 = to the left
local locked = true
local initDone = false
local events

local function Media(name) return (ns.MEDIA or "Interface\\AddOns\\SAOFrames\\Media\\") .. name end
local function Print(msg) if ns.Print then ns.Print(msg) else print("SAO Frames: " .. msg) end end
local function IsSecret(v) if ns.IsSecret then return ns.IsSecret(v) end return false end

local function LogError(where, err)
    if ns.LogError then pcall(ns.LogError, "SAOSocial " .. where .. ": " .. tostring(err)) end
end

-- Calls fn safely; returns a plain truthy/falsey result (secret or failed -> false).
local function Yes(fn, ...)
    if type(fn) ~= "function" then return false end
    local ok, v = pcall(fn, ...)
    if not ok or IsSecret(v) then return false end
    return v and true or false
end

local function Try(what, fn, ...)
    if type(fn) ~= "function" then
        Print(what .. " isn't available.")
        return false
    end
    local ok, err = pcall(fn, ...)
    if not ok then
        LogError(what, err)
        if InCombatLockdown and InCombatLockdown() then
            Print("can't do that in combat.")
        else
            Print(what .. " failed.")
        end
    end
    return ok
end

local function Field(tbl, key)
    if type(tbl) == "table" then return tbl[key] end
end

---------------------------------------------------------------------------
-- Unit / group helpers
---------------------------------------------------------------------------

-- Name of a friendly player target ("Name" or "Name-Realm"), or nil plus a reason.
local function TargetName(needFriendly)
    if not Yes(UnitExists, "target") then return nil, "No target." end
    if not Yes(UnitIsPlayer, "target") then return nil, "Target is not a player." end
    if Yes(UnitIsUnit, "target", "player") then return nil, "That's you." end
    if needFriendly ~= false and not Yes(UnitIsFriend, "player", "target") then
        return nil, "Target is not friendly."
    end
    local ok, name, realm = pcall(UnitName, "target")
    if not ok or IsSecret(name) or type(name) ~= "string" or name == "" then
        return nil, "Target's name is hidden."
    end
    if not IsSecret(realm) and type(realm) == "string" and realm ~= "" then
        name = name .. "-" .. realm
    end
    return name
end

local function InGroup() return Yes(IsInGroup) end
local function InRaid() return Yes(IsInRaid) end
local function IsLeader() return Yes(UnitIsGroupLeader, "player") end
local function IsLeadOrAssist()
    return IsLeader() or (InRaid() and Yes(UnitIsGroupAssistant, "player"))
end

local function CanInviteTarget()
    local name, why = TargetName()
    if not name then return false, why end
    if Yes(UnitInParty, "target") or Yes(UnitInRaid, "target") then return false, "Already in your group." end
    if InGroup() and not IsLeadOrAssist() then return false, "Only the leader can invite." end
    return true
end

local function NeedGroup()
    if not InGroup() then return false, "You are not in a group." end
    return true
end

local function NeedReadyCheck()
    if not InGroup() then return false, "You are not in a group." end
    if not IsLeadOrAssist() then return false, "Leader or assistant only." end
    return true
end

local PartyInfo = function(key) return Field(C_PartyInfo, key) end

local function OpenFriendsTab(globalName, fallback)
    local tab = _G[globalName]
    if type(tab) ~= "number" then tab = fallback end
    return Try("Opening the friends panel", ToggleFriendsFrame, tab)
end

local function OpenChatLine(text)
    local open = Field(ChatFrameUtil, "OpenChat") or ChatFrame_OpenChat
    return Try("Opening chat", open, text)
end

---------------------------------------------------------------------------
-- Menu tree. Each action: label, icon, test() -> ok, reason; run().
---------------------------------------------------------------------------

local MENU = {
    { label = "Party", icon = "Party", items = {
        { label = "Invite target", icon = "Plus", test = CanInviteTarget, run = function()
            local name = TargetName()
            if not name then return end
            Try("Invite", PartyInfo("InviteUnit") or InviteUnit, name)
        end },
        { label = "Leave party", icon = "Leave", test = NeedGroup, run = function()
            Try("Leaving the group", PartyInfo("LeaveParty") or LeaveParty)
        end },
        { label = "Ready check", icon = "Check", test = NeedReadyCheck, run = function()
            Try("Ready check", DoReadyCheck)
        end },
        { label = "Convert to raid", icon = "Raid", test = function()
            if not InGroup() or InRaid() then return false, "Needs a party (not a raid)." end
            if not IsLeader() then return false, "Party leader only." end
            return true
        end, run = function()
            Try("Convert to raid", PartyInfo("ConvertToRaid") or ConvertToRaid)
        end },
        { label = "Party chat", icon = "Whisper", test = NeedGroup, run = function()
            OpenChatLine(InRaid() and "/raid " or "/p ")
        end },
    } },
    { label = "Friend", icon = "Friend", items = {
        { label = "Friends list", icon = "List", run = function()
            OpenFriendsTab("FRIEND_TAB_FRIENDS", 1)
        end },
        { label = "Add target", icon = "Plus", test = function()
            local name, why = TargetName()
            if not name then return false, why end
            if not Field(C_FriendList, "AddFriend") then return false, "Not available." end
            return true
        end, run = function()
            local name = TargetName()
            if name then Try("Add friend", Field(C_FriendList, "AddFriend"), name) end
        end },
        { label = "Who list", icon = "Search", run = function()
            OpenFriendsTab("FRIEND_TAB_WHO", 2)
        end },
    } },
    { label = "Guild", icon = "Guild", items = {
        { label = "Guild & communities", icon = "List", run = function()
            Try("Opening the guild panel", ToggleGuildFrame or ToggleCommunitiesFrame)
        end },
        { label = "Invite target", icon = "Plus", test = function()
            if not Yes(IsInGuild) then return false, "You are not in a guild." end
            if CanGuildInvite and not Yes(CanGuildInvite) then return false, "No guild invite permission." end
            local name, why = TargetName()
            if not name then return false, why end
            if Yes(UnitIsInMyGuild, "target") then return false, "Already in your guild." end
            if not Field(C_GuildInfo, "Invite") and not GuildInvite then return false, "Not available." end
            return true
        end, run = function()
            local name = TargetName()
            if name then Try("Guild invite", Field(C_GuildInfo, "Invite") or GuildInvite, name) end
        end },
        { label = "Guild chat", icon = "Whisper", test = function()
            if not Yes(IsInGuild) then return false, "You are not in a guild." end
            return true
        end, run = function() OpenChatLine("/g ") end },
    } },
    { label = "Raid", icon = "Raid", items = {
        { label = "Raid panel", icon = "List", run = function()
            if ToggleRaidFrame then Try("Opening the raid panel", ToggleRaidFrame)
            else OpenFriendsTab("FRIEND_TAB_RAID", 3) end
        end },
        { label = "Ready check", icon = "Check", test = NeedReadyCheck, run = function()
            Try("Ready check", DoReadyCheck)
        end },
        { label = "Convert to party", icon = "Party", test = function()
            if not InRaid() then return false, "You are not in a raid." end
            if not IsLeader() then return false, "Raid leader only." end
            local ok, n = pcall(GetNumGroupMembers)
            if not ok or IsSecret(n) or type(n) ~= "number" or n > 5 then return false, "Too many members." end
            return true
        end, run = function()
            Try("Convert to party", PartyInfo("ConvertToParty") or ConvertToParty)
        end },
        { label = "Roll 1-100", icon = "Dice", run = function()
            Try("Roll", RandomRoll or Field(C_RandomRoll, "Roll"), 1, 100)
        end },
    } },
    { label = "Whisper", icon = "Whisper", items = {
        { label = "Whisper target", icon = "Whisper", test = function()
            local name, why = TargetName()
            if not name then return false, why end
            return true
        end, run = function()
            local name = TargetName()
            if not name then return end
            Try("Whisper", Field(ChatFrameUtil, "SendTell") or ChatFrame_SendTell, name)
        end },
        { label = "Reply", icon = "Whisper", run = function()
            local reply = Field(ChatFrameUtil, "ReplyTell") or ChatFrame_ReplyTell
            Try("Reply", reply)
        end },
    } },
}

---------------------------------------------------------------------------
-- Widgets
---------------------------------------------------------------------------

local function Color(tex, c, a)
    tex:SetVertexColor(c[1], c[2], c[3], a or c[4] or 1)
end

local function PlainFont(fs, size)
    if ns.SetFont then pcall(ns.SetFont, fs, size, false) end
    local path = fs:GetFont() or STANDARD_TEXT_FONT
    fs:SetFont(path, size, "")
    fs:SetShadowOffset(0, 0)
end

local function Border(f)
    local edges = {
        { "TOPLEFT", "TOPRIGHT", nil, 1 }, { "BOTTOMLEFT", "BOTTOMRIGHT", nil, 1 },
        { "TOPLEFT", "BOTTOMLEFT", 1, nil }, { "TOPRIGHT", "BOTTOMRIGHT", 1, nil },
    }
    for _, e in ipairs(edges) do
        local t = f:CreateTexture(nil, "BORDER")
        t:SetTexture(WHITE)
        Color(t, C.border)
        t:SetPoint(e[1]); t:SetPoint(e[2])
        if e[3] then t:SetWidth(e[3]) else t:SetHeight(e[4]) end
    end
end

-- Repaints a row for its state: disabled, pressed, hover/selected, normal.
local function Paint(row)
    local fill, text, disc, icon = C.fill, C.text, C.disc, nil
    if row.disabled then
        fill, text, disc = C.fillOff, C.textOff, C.discOff
    elseif row.pressed then
        fill, text, disc, icon = C.press, { 1, 1, 1 }, { 1, 1, 1 }, C.orange
    elseif row.hover or row.selected then
        fill, disc = C.hover, C.orange
    end
    Color(row.fill, fill)
    row.label:SetTextColor(text[1], text[2], text[3])
    Color(row.disc, disc)
    if icon then Color(row.icon, icon) else row.icon:SetVertexColor(1, 1, 1, 1) end
    Color(row.arrow, row.disabled and C.discOff or (row.pressed and { 1, 1, 1 } or C.disc))
end

local function ShowReason(row)
    if not row.reason or not GameTooltip then return end
    GameTooltip:SetOwner(row, dir == 1 and "ANCHOR_RIGHT" or "ANCHOR_LEFT")
    GameTooltip:SetText(row.reason, 1, 0.82, 0.3)
    GameTooltip:Show()
end

local function CreateRow(parent, onClick)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(ROW_W, ROW_H)
    row:RegisterForClicks("LeftButtonUp")

    row.fill = row:CreateTexture(nil, "BACKGROUND")
    row.fill:SetTexture(Media("SocialPanel"))
    row.fill:SetAllPoints()
    Border(row)

    row.disc = row:CreateTexture(nil, "ARTWORK")
    row.disc:SetTexture(Media("SocialIconDisc"))
    row.disc:SetSize(ROW_H - 6, ROW_H - 6)
    row.disc:SetPoint("LEFT", 4, 0)

    row.icon = row:CreateTexture(nil, "OVERLAY")
    row.icon:SetSize(ROW_H - 12, ROW_H - 12)
    row.icon:SetPoint("CENTER", row.disc)

    row.arrow = row:CreateTexture(nil, "OVERLAY")
    row.arrow:SetTexture(Media("SocialIconChevron"))
    row.arrow:SetSize(10, 10)
    row.arrow:SetPoint("RIGHT", -6, 0)

    row.label = row:CreateFontString(nil, "OVERLAY")
    PlainFont(row.label, 12)
    row.label:SetJustifyH("LEFT")
    row.label:SetPoint("LEFT", row.disc, "RIGHT", 7, 0)
    row.label:SetPoint("RIGHT", row.arrow, "LEFT", -4, 0)

    row:SetScript("OnEnter", function(self)
        self.hover = true; Paint(self)
        if self.disabled then ShowReason(self) end
    end)
    row:SetScript("OnLeave", function(self)
        self.hover, self.pressed = nil, nil; Paint(self)
        if GameTooltip and GameTooltip:IsOwned(self) then GameTooltip:Hide() end
    end)
    row:SetScript("OnMouseDown", function(self)
        if not self.disabled then self.pressed = true; Paint(self) end
    end)
    row:SetScript("OnMouseUp", function(self) self.pressed = nil; Paint(self) end)
    row:SetScript("OnClick", function(self)
        if self.disabled then return end
        local ok, err = pcall(onClick, self)
        if not ok then LogError("click", err) end
    end)
    return row
end

local function CreateList(name)
    local f = CreateFrame("Frame", name, UIParent)
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    f:Hide()
    f.pointer = f:CreateTexture(nil, "ARTWORK")
    f.pointer:SetTexture(Media("SocialPointer"))
    f.pointer:SetSize(10, 14)
    f.pointer:SetVertexColor(1, 1, 1, 0.92)
    return f
end

-- Lays rows out top-down and sizes the list frame.
local function Stack(list, rows, n)
    for i = 1, #rows do
        local r = rows[i]
        r:ClearAllPoints()
        if i <= n then
            r:SetPoint("TOPLEFT", list, "TOPLEFT", 0, -(i - 1) * (ROW_H + ROW_GAP))
            r:Show()
        else
            r:Hide()
        end
    end
    list:SetSize(ROW_W, n * ROW_H + math.max(0, n - 1) * ROW_GAP)
end

-- Places a list beside `anchor` (the button or a row), pointer aimed at it.
local function Place(list, anchor, offset)
    local near, far = dir == 1 and "LEFT" or "RIGHT", dir == 1 and "RIGHT" or "LEFT"
    list:ClearAllPoints()
    list:SetPoint(near, anchor, far, dir * (GAP + offset), 0)
    list.pointer:ClearAllPoints()
    list.pointer:SetPoint(near, anchor, far, dir * 3, 0)
    if dir == 1 then list.pointer:SetTexCoord(0, 1, 0, 1) else list.pointer:SetTexCoord(1, 0, 0, 1) end
end

-- Slide-in: the list moves GAP px outward from its anchor while fading in.
local function Slide(list, anchor)
    list.anchor, list.t = anchor, 0
    Place(list, anchor, -10)
    list:SetAlpha(0)
    list:Show()
    list:SetScript("OnUpdate", function(self, elapsed)
        self.t = math.min(1, self.t + elapsed / SLIDE_TIME)
        local e = 1 - (1 - self.t) * (1 - self.t)
        Place(self, self.anchor, -10 * (1 - e))
        self:SetAlpha(e)
        if self.t >= 1 then self:SetScript("OnUpdate", nil) end
    end)
end

---------------------------------------------------------------------------
-- Menu logic
---------------------------------------------------------------------------

local PaintButton

local function RefreshSub()
    if not openEntry or not sub or not sub:IsShown() then return end
    for i, item in ipairs(openEntry.items) do
        local row = subRows[i]
        if row and i <= MAX_SUB then
            local ok, can, why = true, true, nil
            if item.test then ok, can, why = pcall(item.test) end
            if not ok then LogError("test " .. item.label, can); can, why = false, "Unavailable." end
            row.disabled = not can
            row.reason = (not can) and why or nil
            Paint(row)
        end
    end
end

local function CloseSub()
    openEntry = nil
    if sub then sub:Hide() end
    for _, r in ipairs(mainRows) do r.selected = nil; Paint(r) end
end

local function CloseMenu()
    CloseSub()
    if menu and menu:IsShown() then menu:Hide() end
end

local function RunItem(row)
    local item = row.item
    CloseMenu()
    if item and item.run then
        local ok, err = pcall(item.run)
        if not ok then LogError("run " .. item.label, err) end
    end
end

local function OpenSub(row)
    local entry = row.entry
    if openEntry == entry then CloseSub() return end
    CloseSub()
    openEntry = entry
    row.selected = true; Paint(row)
    local n = math.min(#entry.items, MAX_SUB)
    for i = 1, n do
        local r = subRows[i]
        local item = entry.items[i]
        r.item = item
        r.label:SetText(item.label)
        r.icon:SetTexture(Media("SocialIcon" .. item.icon))
        r.arrow:Hide()
        r.hover, r.pressed = nil, nil
    end
    Stack(sub, subRows, n)
    Slide(sub, row)
    RefreshSub()
end

local function OpenMenu()
    if not menu then return end
    local x = button:GetCenter()
    local w = UIParent:GetWidth()
    dir = (not IsSecret(x) and not IsSecret(w) and type(x) == "number" and type(w) == "number"
        and x > w / 2) and -1 or 1
    for _, r in ipairs(mainRows) do r.hover, r.pressed, r.selected = nil, nil, nil; Paint(r) end
    Slide(menu, button)
    PaintButton()
end

local function ToggleMenu()
    if not menu then return end
    if menu:IsShown() then CloseMenu() else OpenMenu() end
end

local function OnEvent(_, event)
    if event == "GLOBAL_MOUSE_DOWN" then
        if menu and menu:IsShown() and not menu:IsMouseOver() and not button:IsMouseOver()
            and not (sub:IsShown() and sub:IsMouseOver()) then
            CloseMenu()
        end
    else
        RefreshSub()
    end
end

---------------------------------------------------------------------------
-- Round button
---------------------------------------------------------------------------

PaintButton = function()
    if not button then return end
    local active = menu and menu:IsShown()
    local disc = active and C.orange or (button.hover and { 1, 1, 1 } or C.button)
    if button.pressed then disc = { 0.92, 0.48, 0.08 } end
    Color(button.disc, disc)
    if active or button.pressed then button.icon:SetVertexColor(1, 1, 1) else Color(button.icon, C.disc) end
    Color(button.ring, active and C.orange or C.border)
    button.outline:SetShown(not locked)
end

local function ApplyPosition()
    local p = sdb.pos
    if type(p) ~= "table" or type(p[1]) ~= "string" then p = SOCIAL_DEFAULTS.pos end
    button:ClearAllPoints()
    button:SetPoint(p[1], UIParent, p[2] or p[1], tonumber(p[3]) or 0, tonumber(p[4]) or 0)
end

local function SavePosition()
    local ok, point, _, rel, x, y = pcall(button.GetPoint, button, 1)
    if ok and point and not IsSecret(x) and not IsSecret(y) then
        sdb.pos = { point, rel or point, math.floor((x or 0) + 0.5), math.floor((y or 0) + 0.5) }
    end
end

-- Ends a drag: shared by OnDragStop and SocialSetLocked (auto-lock mid-drag).
local function FinishDrag(b)
    if not b.moving then return end
    b.moving = nil
    b:StopMovingOrSizing()
    b:SetUserPlaced(false)
    local db = ns.GetDB and ns.GetDB()
    if ns.SnapToGrid and db and db.snap then
        local ok, err = pcall(ns.SnapToGrid, b)
        if not ok then LogError("SnapToGrid", err) end
    end
    SavePosition()
    b.dragEnd = GetTime()
end

local function CreateButton()
    local b = CreateFrame("Button", "SAOFrames_SocialButton", UIParent)
    b:SetSize(BUTTON_SIZE, BUTTON_SIZE)
    b:SetFrameStrata("MEDIUM")
    b:SetMovable(true)
    b:SetClampedToScreen(true)
    -- Down clicks too: /click from a keybind arrives as a down click when
    -- ActionButtonUseKeyDown is on. Real mouse presses act on the up click only.
    b:RegisterForClicks("AnyUp", "AnyDown")
    if not locked then b:RegisterForDrag("LeftButton") end

    local shadow = b:CreateTexture(nil, "BACKGROUND")
    shadow:SetTexture(Media("SocialDisc"))
    shadow:SetPoint("TOPLEFT", -1, -1); shadow:SetPoint("BOTTOMRIGHT", 2, -3)
    shadow:SetVertexColor(0, 0, 0, 0.35)
    b.disc = b:CreateTexture(nil, "ARTWORK")
    b.disc:SetTexture(Media("SocialDisc"))
    b.disc:SetAllPoints()
    b.ring = b:CreateTexture(nil, "OVERLAY")
    b.ring:SetTexture(Media("SocialRing"))
    b.ring:SetAllPoints()
    b.icon = b:CreateTexture(nil, "OVERLAY")
    b.icon:SetTexture(Media("SocialIconFriend"))
    b.icon:SetSize(BUTTON_SIZE * 0.56, BUTTON_SIZE * 0.56)
    b.icon:SetPoint("CENTER")
    b.outline = b:CreateTexture(nil, "OVERLAY")
    b.outline:SetTexture(Media("SocialRing"))
    b.outline:SetPoint("TOPLEFT", -4, 4); b.outline:SetPoint("BOTTOMRIGHT", 4, -4)
    Color(b.outline, C.cyan)

    b:SetScript("OnEnter", function(self)
        self.hover = true; PaintButton()
        if GameTooltip then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Social")
            GameTooltip:AddLine("Click: open / close the menu", 1, 1, 1)
            if not locked then GameTooltip:AddLine("Drag to move (unlocked)", 0.4, 0.85, 1) end
            GameTooltip:Show()
        end
    end)
    b:SetScript("OnLeave", function(self)
        self.hover, self.pressed = nil, nil; PaintButton()
        if GameTooltip and GameTooltip:IsOwned(self) then GameTooltip:Hide() end
    end)
    b:SetScript("OnMouseDown", function(self) self.pressed = true; PaintButton() end)
    b:SetScript("OnMouseUp", function(self) self.pressed = nil; PaintButton() end)
    b:SetScript("OnClick", function(self, mouseButton, down)
        if not ns.IsSocialEnabled() then CloseMenu() return end
        if down and self:IsMouseOver() and Yes(IsMouseButtonDown, mouseButton) then return end
        if self.dragEnd and GetTime() - self.dragEnd < 0.2 then return end
        ToggleMenu()
    end)
    b:SetScript("OnDragStart", function(self)
        if locked then return end
        CloseMenu()
        self:StartMoving()
        self.moving = true
    end)
    b:SetScript("OnDragStop", FinishDrag)
    return b
end

---------------------------------------------------------------------------
-- Build / public API
---------------------------------------------------------------------------

local function Build()
    if button then return end
    button = CreateButton()
    ApplyPosition()

    menu = CreateList("SAOFrames_SocialMenu")
    sub = CreateList("SAOFrames_SocialSubMenu")
    sub:SetFrameLevel(menu:GetFrameLevel() + 5)
    menu:SetScript("OnHide", function()
        CloseSub()
        if events then pcall(events.UnregisterEvent, events, "GLOBAL_MOUSE_DOWN") end
        PaintButton()
    end)
    menu:SetScript("OnShow", function()
        if events then pcall(events.RegisterEvent, events, "GLOBAL_MOUSE_DOWN") end
    end)
    if type(UISpecialFrames) == "table" then tinsert(UISpecialFrames, "SAOFrames_SocialMenu") end

    for i, entry in ipairs(MENU) do
        local r = CreateRow(menu, OpenSub)
        r.entry = entry
        r.label:SetText(entry.label)
        r.icon:SetTexture(Media("SocialIcon" .. entry.icon))
        mainRows[i] = r
        Paint(r)
    end
    Stack(menu, mainRows, #mainRows)
    for i = 1, MAX_SUB do subRows[i] = CreateRow(sub, RunItem) end

    events = CreateFrame("Frame")
    events:SetScript("OnEvent", OnEvent)
    for _, ev in ipairs({ "PLAYER_TARGET_CHANGED", "GROUP_ROSTER_UPDATE", "PARTY_LEADER_CHANGED",
                          "PLAYER_GUILD_UPDATE", "UNIT_FACTION" }) do
        pcall(events.RegisterEvent, events, ev)
    end
    PaintButton()
end

function ns.IsSocialEnabled()
    return not (sdb and sdb.enabled == false)
end

function ns.InitSocial()
    local db = ns.GetDB and ns.GetDB()
    if not db then return end
    db.social = type(db.social) == "table" and db.social or {}
    sdb = db.social
    if sdb.enabled == nil then sdb.enabled = SOCIAL_DEFAULTS.enabled end
    if type(sdb.pos) ~= "table" then
        local d = SOCIAL_DEFAULTS.pos
        sdb.pos = { d[1], d[2], d[3], d[4] }
    end
    locked = db.locked ~= false
    initDone = true
    if not sdb.enabled then return end
    local ok, err = pcall(Build)
    if not ok then LogError("Build", err) end
end

function ns.ToggleSocialMenu()
    if not initDone then return end
    if not ns.IsSocialEnabled() then
        Print("social menu is off.")
        return
    end
    if not button then
        local ok, err = pcall(Build)
        if not ok then LogError("Build", err) return end
    end
    button:Show()
    ToggleMenu()
end

function ns.SocialSetLocked(isLocked)
    locked = isLocked and true or false
    if button then
        if locked then FinishDrag(button) end
        if locked then button:RegisterForDrag() else button:RegisterForDrag("LeftButton") end
        PaintButton()
    end
end

function ns.SocialSetEnabled(on)
    on = on and true or false
    local db = not sdb and ns.GetDB and ns.GetDB()
    if db then
        db.social = type(db.social) == "table" and db.social or {}
        sdb = db.social
    end
    if sdb then sdb.enabled = on end
    if not initDone then return end
    if on then
        if not button then
            local ok, err = pcall(Build)
            if not ok then LogError("Build", err) return end
        end
        button:Show()
        PaintButton()
    elseif button then
        CloseMenu()
        button:Hide()
    end
end

function ns.SocialResetPosition()
    if not sdb then return end
    local d = SOCIAL_DEFAULTS.pos
    sdb.pos = { d[1], d[2], d[3], d[4] }
    if button then
        if button.moving then button.moving = nil; button:StopMovingOrSizing() end
        button:SetUserPlaced(false)
        ApplyPosition()
    end
end
