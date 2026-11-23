-- SAO Frames: Sword Art Online-styled group loot roll dialogs (SAOLoot.lua).
--
-- Replaces Blizzard's Need / Greed / Pass popups with SAO "system message" boxes: a light
-- translucent panel, gray header labels, a round item icon, a countdown bar and round
-- buttons (blue NEED, gold GREED, gray DISENCHANT, red PASS).
--
-- Blizzard's roll frames are suppressed by unregistering START_LOOT_ROLL on the Blizzard
-- frame(s) that listen for it (UIParent in the live UI, as ElvUI / ShestakUI do), found with
-- GetFramesRegisteredForEvent. Nothing Blizzard owns is replaced or hooked insecurely; as a
-- fallback, any GroupLootFrameN that still shows is hidden one frame later.
-- Bind-on-pickup confirmation is left to Blizzard's StaticPopup when it appears; if it does
-- not, the dialog switches to its own SAO confirm (ConfirmLootRoll).
--
-- Secret values: item names/links/textures go straight to widget setters; anything that is
-- compared or concatenated goes through Plain() first. API calls are wrapped in pcall.
--
-- Public (on ns): InitLoot, LootSetLocked, LootSetEnabled, IsLootEnabled, LootTest, LootApply,
-- LootResetPosition.

local ADDON, ns = ...

---------------------------------------------------------------------------
-- Constants
---------------------------------------------------------------------------

local WHITE = "Interface\\Buttons\\WHITE8X8"
local W, H, GAP = 300, 134, 6  -- dialog size (trimmed: no dead space under the buttons)
local BTN = 30                  -- round button size
local BTN_STEP = 64             -- distance between button centers
local LOOT_DEFAULTS = { enabled = true, pos = { "TOP", "TOP", 0, -180 }, scale = 1 }

-- Roll buttons, left to right. roll = RollOnLoot type (0 pass, 1 need, 2 greed, 3 disenchant).
local ROLLS = {
    { key = "need",  roll = 1, tex = "LootNeed",       label = "NEED",       title = "Need",       r = 0.35, g = 0.70, b = 1.00 },
    { key = "greed", roll = 2, tex = "LootGreed",      label = "GREED",      title = "Greed",      r = 1.00, g = 0.80, b = 0.25 },
    { key = "de",    roll = 3, tex = "LootDisenchant", label = "DISENCHANT", title = "Disenchant", r = 0.80, g = 0.82, b = 0.86 },
    { key = "pass",  roll = 0, tex = "LootPass",       label = "PASS",       title = "Pass",       r = 1.00, g = 0.35, b = 0.35 },
}
local ROLL_NAMES = { [0] = "PASS", [1] = "NEED", [2] = "GREED", [3] = "DISENCHANT" }
local QUALITY_NAMES = { [0] = "Poor", "Common", "Uncommon", "Rare", "Epic", "Legendary", "Artifact", "Heirloom" }

-- Sample items for /sao loot test (second one shows a greyed-out NEED button).
local SAMPLES = {
    { name = "Elucidator", icon = "Interface\\Icons\\INV_Sword_04", quality = 4, type = "Weapon", ilvl = 30,
      bop = true, canNeed = true, canGreed = true, canDE = false },
    { name = "Coat of Midnight", icon = "Interface\\Icons\\INV_Chest_Cloth_17", quality = 3, type = "Armor", ilvl = 28,
      bop = false, canNeed = false, reasonNeed = 1, canGreed = true, canDE = false },
}

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------

local ldb              -- db.loot
local holder, mover    -- anchor frame (always shown, invisible) and the unlock placeholder
local events           -- our event frame
local dialogs = {}     -- shown dialogs, in stacking order
local pool = {}        -- released dialogs
local byRoll = {}      -- rollID -> dialog
local ours = {}        -- rollIDs we have shown (so CONFIRM events for them are ours)
local suppressed = {}  -- Blizzard frames we unregistered START_LOOT_ROLL on
local guarded = {}     -- Blizzard roll frames with our fallback OnShow hook
local active = false   -- handling new rolls (feature enabled and initialized)
local unlocked = false
local testSeq = 0
local logged = {}

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function IsSecret(v)
    if ns.IsSecret then return ns.IsSecret(v) end
    return issecretvalue ~= nil and issecretvalue(v) or false
end

local function Plain(v)
    if IsSecret(v) then return nil end
    return v
end

local function Print(msg)
    if ns.Print then ns.Print(msg) else print("SAO Frames: " .. msg) end
end

local function LogError(tag, err)
    if ns.LogError then pcall(ns.LogError, "SAOLoot " .. tag .. ": " .. tostring(err)) end
end

local function LogOnce(tag, err)
    if logged[tag] then return end
    logged[tag] = true
    LogError(tag, err)
end

local function Media(name)
    return (ns.MEDIA or ("Interface\\AddOns\\" .. ADDON .. "\\Media\\")) .. name
end

-- outline = true: the addon's normal white outlined font. Otherwise flat dark text for the
-- light panel (no outline, no shadow).
local function Font(fs, size, outline)
    if outline and ns.SetFont and pcall(ns.SetFont, fs, size, false) then return end
    local path = ns.fontPath or STANDARD_TEXT_FONT
    if not (pcall(fs.SetFont, fs, path, size, "") and fs:GetFont()) then
        fs:SetFont(STANDARD_TEXT_FONT, size, "")
    end
    fs:SetShadowOffset(0, 0)
    fs:SetTextColor(0.42, 0.45, 0.50)
end

local function GetDB()
    if ns.GetDB then return ns.GetDB() end
    return SAOFramesDB
end

local function InitDefaults()
    local db = GetDB()
    if type(db) ~= "table" then return nil end
    if type(db.loot) ~= "table" then db.loot = {} end
    local l = db.loot
    if type(l.enabled) ~= "boolean" then l.enabled = LOOT_DEFAULTS.enabled end
    if type(l.scale) ~= "number" or l.scale < 0.4 or l.scale > 3 then l.scale = LOOT_DEFAULTS.scale end
    if type(l.pos) ~= "table" or type(l.pos[1]) ~= "string" then
        local p = LOOT_DEFAULTS.pos
        l.pos = { p[1], p[2], p[3], p[4] }
    end
    return l
end

-- Item quality -> text color that reads on the light panel (white/common becomes dark gray).
local function QualityRGB(q)
    q = Plain(q)
    if type(q) ~= "number" or q == 1 then return 0.20, 0.22, 0.26 end
    if q == 0 then return 0.52, 0.53, 0.55 end
    local ok, r, g, b
    if C_Item and C_Item.GetItemQualityColor then ok, r, g, b = pcall(C_Item.GetItemQualityColor, q) end
    if not (ok and type(r) == "number") and GetItemQualityColor then ok, r, g, b = pcall(GetItemQualityColor, q) end
    if not (ok and type(r) == "number" and type(g) == "number" and type(b) == "number") then
        local c = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
        if not c then return 0.20, 0.22, 0.26 end
        r, g, b = c.r, c.g, c.b
    end
    return r * 0.85, g * 0.85, b * 0.85 -- a little darker for contrast on white
end

local function QualityName(q)
    q = Plain(q)
    if type(q) ~= "number" then return nil end
    local s = _G["ITEM_QUALITY" .. q .. "_DESC"]
    return type(s) == "string" and s or QUALITY_NAMES[q]
end

-- "Type: Weapon   Item Lv: 30   Quality: Rare" from values that are not secret.
local function HeaderText(itemType, ilvl, quality)
    local parts = {}
    itemType, ilvl = Plain(itemType), Plain(ilvl)
    if type(itemType) == "string" and itemType ~= "" then parts[#parts + 1] = "Type: " .. itemType end
    if type(ilvl) == "number" and ilvl > 0 then parts[#parts + 1] = "Item Lv: " .. math.floor(ilvl) end
    local qn = QualityName(quality)
    if qn then parts[#parts + 1] = "Quality: " .. qn end
    if #parts == 0 then return "System: Item Drop" end
    return table.concat(parts, "   ")
end

local function ItemTypeAndLevel(link)
    link = Plain(link)
    if type(link) ~= "string" then return nil, nil end
    local itemType, ilvl
    local info = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if info then
        local ok, _, t = pcall(info, link)
        if ok then itemType = t end
    end
    local lvl = (C_Item and C_Item.GetDetailedItemLevelInfo) or GetDetailedItemLevelInfo
    if lvl then
        local ok, v = pcall(lvl, link)
        if ok then ilvl = v end
    end
    return itemType, ilvl
end

-- Reason a roll button is disabled (LOOT_ROLL_INELIGIBLE_REASON<N>; #4 takes the DE skill).
local function ReasonText(code, skill)
    code = Plain(code)
    if type(code) ~= "number" or code == 0 then return nil end
    local s = _G["LOOT_ROLL_INELIGIBLE_REASON" .. code]
    if type(s) ~= "string" then return "Not available (reason " .. code .. ")." end
    if s:find("%%") then
        local ok, r = pcall(string.format, s, Plain(skill) or 0)
        if ok then return r end
    end
    return s
end

-- Durations: START_LOOT_ROLL's rollTime is in ms; accept seconds too, just in case.
local function ToMs(v)
    v = Plain(v)
    if type(v) ~= "number" or v <= 0 then return nil end
    return v < 1000 and v * 1000 or v
end

local function Allowed(v)
    if IsSecret(v) then return true end -- unknown: let the server decide
    return v and true or false
end

local function BarColor(frac)
    if frac > 0.5 then return 0.30, 0.85, 1.00 end
    if frac > 0.2 then
        local t = (frac - 0.2) / 0.3          -- 1 at cyan, 0 at orange
        return 1.00 - 0.70 * t, 0.60 + 0.25 * t, 0.10 + 0.90 * t
    end
    local t = math.max(frac, 0) / 0.2         -- 1 at orange, 0 at red
    return 1.00, 0.15 + 0.45 * t, 0.15 - 0.05 * t
end

---------------------------------------------------------------------------
-- Layout / position
---------------------------------------------------------------------------

local function ApplyPosition()
    local p = ldb.pos
    local s = holder:GetScale()
    holder:ClearAllPoints()
    holder:SetPoint(p[1], UIParent, p[2] or p[1], (p[3] or 0) / s, (p[4] or 0) / s)
end

local function SavePosition()
    local point, _, rel, x, y = holder:GetPoint(1)
    if not point then return end
    local s = holder:GetScale()
    ldb.pos = { point, rel or point, (x or 0) * s, (y or 0) * s }
end

-- Stack dialogs from the anchor: downward in the top half of the screen, upward below it.
-- When a column would run off screen, wrap into extra columns (toward the screen center).
local function Layout()
    if not holder then return end
    local s, ps = holder:GetEffectiveScale(), UIParent:GetEffectiveScale()
    local screenW, screenH = UIParent:GetWidth() * ps, UIParent:GetHeight() * ps
    local cx, cy = holder:GetCenter()
    local up, left, rows = false, false, math.max(#dialogs, 1)
    if cx and cy then
        up = cy * s < screenH / 2
        left = cx * s > screenW / 2
        local room = up and (screenH - (holder:GetBottom() or 0) * s) or ((holder:GetTop() or 0) * s)
        rows = math.max(1, math.floor((room / s + GAP) / (H + GAP)))
    end
    for i, d in ipairs(dialogs) do
        local col, row = math.floor((i - 1) / rows), (i - 1) % rows
        local x = col * (W + GAP) * (left and -1 or 1)
        d:ClearAllPoints()
        if up then d:SetPoint("BOTTOM", holder, "BOTTOM", x, row * (H + GAP))
        else d:SetPoint("TOP", holder, "TOP", x, -row * (H + GAP)) end
    end
end

local function ApplyLock()
    if not mover then return end
    mover:SetShown(unlocked and active)
end

---------------------------------------------------------------------------
-- Dialog widgets
---------------------------------------------------------------------------

local Release, OnRollClick, OnConfirmClick -- defined below

local function HideTip(self)
    if GameTooltip and GameTooltip:IsOwned(self) then GameTooltip:Hide() end
end

local function ButtonEnter(self)
    if not GameTooltip then return end
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText(self.title, self.r, self.g, self.b)
    if not self.allowed and self.reason then GameTooltip:AddLine(self.reason, 1, 0.35, 0.35, true) end
    GameTooltip:Show()
end

local function ButtonDown(self) if self:IsEnabled() then self.disc:SetSize(BTN - 3, BTN - 3) end end
local function ButtonUp(self) self.disc:SetSize(BTN, BTN) end

local function CreateRoundButton(parent, d, tex, label, title, r, g, b, onClick)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(BTN + 8, BTN + 16)
    btn:SetHitRectInsets(4, 4, 0, 0)
    btn.disc = btn:CreateTexture(nil, "ARTWORK")
    btn.disc:SetTexture(Media(tex))
    btn.disc:SetSize(BTN, BTN)
    btn.disc:SetPoint("TOP", 0, 0)
    local hi = btn:CreateTexture(nil, "HIGHLIGHT")
    hi:SetTexture(Media("LootButtonHi"))
    hi:SetBlendMode("ADD")
    hi:SetVertexColor(r, g, b)
    hi:SetSize(BTN + 8, BTN + 8)
    hi:SetPoint("CENTER", btn.disc, "CENTER")
    btn.label = btn:CreateFontString(nil, "OVERLAY")
    Font(btn.label, 8)
    btn.label:SetPoint("TOP", btn.disc, "BOTTOM", 0, -3)
    btn.label:SetText(label)
    btn.dialog, btn.title, btn.r, btn.g, btn.b, btn.allowed = d, title, r, g, b, true
    btn:SetScript("OnEnter", ButtonEnter)
    btn:SetScript("OnLeave", HideTip)
    btn:SetScript("OnMouseDown", ButtonDown)
    btn:SetScript("OnMouseUp", ButtonUp)
    btn:SetScript("OnClick", onClick)
    return btn
end

local function SetAllowed(btn, allowed, reason)
    btn.allowed, btn.reason = allowed, reason
    btn:SetEnabled(allowed)
    btn.disc:SetDesaturated(not allowed)
    btn.disc:SetAlpha(allowed and 1 or 0.45)
    if allowed then btn.label:SetTextColor(0.36, 0.39, 0.44) else btn.label:SetTextColor(0.68, 0.70, 0.73) end
end

-- Center the shown buttons of a row.
local function LayoutRow(row, list)
    local shown = {}
    for _, btn in ipairs(list) do if btn:IsShown() then shown[#shown + 1] = btn end end
    for i, btn in ipairs(shown) do
        btn:ClearAllPoints()
        btn:SetPoint("TOP", row, "TOP", (i - (#shown + 1) / 2) * BTN_STEP, 0)
    end
end

local function ItemEnter(self)
    local d = self.dialog
    if not GameTooltip then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    if d.test then
        local s = d.sample
        GameTooltip:SetText(s.name, QualityRGB(s.quality))
        GameTooltip:AddLine("Sample item (preview)", 0.7, 0.7, 0.7)
    else
        local ok, err = pcall(GameTooltip.SetLootRollItem, GameTooltip, d.rollID)
        if not ok then LogOnce("SetLootRollItem", err) end
    end
    GameTooltip:Show()
end

local function ItemClick(self)
    local d = self.dialog
    if d.test or not (IsModifiedClick and IsModifiedClick()) then return end
    local ok, link = pcall(GetLootRollItemLink, d.rollID)
    if ok then
        local ok2, err = pcall(HandleModifiedItemClick, link)
        if not ok2 then LogError("HandleModifiedItemClick", err) end
    else
        LogError("GetLootRollItemLink", link)
    end
end

local function BlizzardConfirmShown()
    if not StaticPopup_Visible then return false end
    local ok, a = pcall(StaticPopup_Visible, "CONFIRM_LOOT_ROLL")
    local ok2, b = pcall(StaticPopup_Visible, "CONFIRM_DISENCHANT_ROLL")
    return (ok and a and true) or (ok2 and b and true) or false
end

local function DialogUpdate(d, elapsed)
    d.acc = d.acc + elapsed
    if d.acc < 0.1 then return end
    d.acc = 0
    if d.popupWait and not BlizzardConfirmShown() then
        d.popupWait = nil
        d.sub:SetText(d.subText or "")
    end
    local left, fromApi
    if not d.test then
        local ok, v = pcall(GetLootRollTimeLeft, d.rollID)
        if ok then left = Plain(v) else LogOnce("GetLootRollTimeLeft", v) end
        fromApi = type(left) == "number"
    end
    if type(left) ~= "number" then left = (d.total or 60000) - (GetTime() - (d.started or GetTime())) * 1000 end
    local frac = math.max(0, math.min(1, left / math.max(d.total or 60000, 1)))
    d.bar:SetValue(frac)
    d.bar:SetStatusBarColor(BarColor(frac))
    d.time:SetText(string.format("Time: %ds", math.max(0, math.ceil(left / 1000))))
    if left <= 0 then
        -- CANCEL_LOOT_ROLL normally closes it; this is only a safety net.
        d.expired = d.expired or GetTime()
        -- Only an estimate (no readable time left): wait much longer, the roll may still be open.
        if d.test or GetTime() - d.expired > (fromApi and 3 or 120) then Release(d) end
    end
end

local function CreateDialog()
    local d = CreateFrame("Frame", nil, holder)
    d:SetSize(W, H)
    d:SetFrameStrata("DIALOG")
    d:SetFrameLevel(holder:GetFrameLevel() + 60) -- above the unlock mover (+50)
    -- While unlocked, dragging the panel moves the anchor (the mover is hidden behind dialog 1).
    d:RegisterForDrag("LeftButton")
    d:SetScript("OnDragStart", function() local f = mover and mover:GetScript("OnDragStart"); if f then f(mover) end end)
    d:SetScript("OnDragStop", function() local f = mover and mover:GetScript("OnDragStop"); if f then f(mover) end end)
    d:EnableMouse(true) -- don't click through to the world
    d:Hide()

    local bg = d:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture(Media("LootPanel"))
    bg:SetPoint("TOPLEFT", -8, 8)
    bg:SetPoint("BOTTOMRIGHT", 8, -8)
    bg:SetVertexColor(0.78, 0.82, 0.88) -- softened white

    d.header = d:CreateFontString(nil, "OVERLAY")
    Font(d.header, 9)
    d.header:SetPoint("TOPLEFT", 12, -6)
    d.header:SetJustifyH("LEFT")
    d.header:SetWordWrap(false)
    d.time = d:CreateFontString(nil, "OVERLAY")
    Font(d.time, 9)
    d.time:SetPoint("TOPRIGHT", -12, -6)
    d.time:SetJustifyH("RIGHT")
    d.header:SetPoint("RIGHT", d.time, "LEFT", -8, 0)

    -- Item row: round icon in a quality-tinted ring, name and a sub line.
    d.outer = d:CreateTexture(nil, "ARTWORK", nil, 1)
    d.outer:SetTexture(Media("LootRing"))
    d.outer:SetVertexColor(0.78, 0.80, 0.84)
    d.outer:SetSize(42, 42)
    d.outer:SetPoint("CENTER", d, "TOPLEFT", 36, -48)
    d.icon = d:CreateTexture(nil, "ARTWORK", nil, 2)
    d.icon:SetSize(32, 32)
    d.icon:SetPoint("CENTER", d.outer, "CENTER")
    d.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    -- Round icon via a mask texture (the same way the other SAO windows do it); the old
    -- SetMask call could draw the mask itself as stripes on some clients.
    local m = d:CreateMaskTexture()
    m:SetAllPoints(d.icon)
    if not pcall(m.SetTexture, m, Media("LootIconMask"), "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE") then
        pcall(m.SetTexture, m, "Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    end
    d.icon:AddMaskTexture(m)
    d.ring = d:CreateTexture(nil, "ARTWORK", nil, 3)
    d.ring:SetTexture(Media("LootRing"))
    d.ring:SetSize(37, 37)
    d.ring:SetPoint("CENTER", d.outer, "CENTER")
    d.count = d:CreateFontString(nil, "OVERLAY")
    Font(d.count, 10, true)
    d.count:SetPoint("BOTTOMRIGHT", d.outer, "BOTTOMRIGHT", 2, -1)

    d.name = d:CreateFontString(nil, "OVERLAY")
    Font(d.name, 13)
    d.name:SetPoint("LEFT", d, "TOPLEFT", 64, -41)
    d.name:SetPoint("RIGHT", d, "TOPRIGHT", -16, -41)
    d.name:SetJustifyH("LEFT")
    d.name:SetWordWrap(false)
    d.sub = d:CreateFontString(nil, "OVERLAY")
    Font(d.sub, 9)
    d.sub:SetPoint("LEFT", d, "TOPLEFT", 64, -58)
    d.sub:SetPoint("RIGHT", d, "TOPRIGHT", -16, -58)
    d.sub:SetJustifyH("LEFT")
    d.sub:SetWordWrap(false)

    local item = CreateFrame("Button", nil, d)
    item:SetPoint("TOPLEFT", 8, -26)
    item:SetPoint("BOTTOMRIGHT", d, "TOPRIGHT", -8, -70)
    item.dialog = d
    item:SetScript("OnEnter", ItemEnter)
    item:SetScript("OnLeave", HideTip)
    item:SetScript("OnClick", ItemClick)
    d.item = item

    -- Countdown bar.
    local bar = CreateFrame("StatusBar", nil, d)
    bar:SetPoint("TOPLEFT", 10, -74)
    bar:SetPoint("TOPRIGHT", -10, -74)
    bar:SetHeight(3)
    bar:SetStatusBarTexture(WHITE)
    bar:SetMinMaxValues(0, 1)
    local bbg = bar:CreateTexture(nil, "BACKGROUND")
    bbg:SetAllPoints()
    bbg:SetColorTexture(0.80, 0.83, 0.87, 0.9)
    d.bar = bar

    -- Roll buttons and the confirm row (own BoP confirm, used if Blizzard shows no popup).
    d.row = CreateFrame("Frame", nil, d)
    d.row:SetPoint("TOPLEFT", 0, -82)
    d.row:SetPoint("BOTTOMRIGHT")
    d.buttons, d.list = {}, {}
    for _, spec in ipairs(ROLLS) do
        local btn = CreateRoundButton(d.row, d, spec.tex, spec.label, spec.title, spec.r, spec.g, spec.b, OnRollClick)
        btn.roll = spec.roll
        d.buttons[spec.key] = btn
        d.list[#d.list + 1] = btn
    end
    d.confirmRow = CreateFrame("Frame", nil, d)
    d.confirmRow:SetAllPoints(d.row)
    d.confirmRow:Hide()
    local ok = CreateRoundButton(d.confirmRow, d, "LootNeed", "CONFIRM", "Confirm roll", 0.35, 0.70, 1.00, OnConfirmClick)
    local cancel = CreateRoundButton(d.confirmRow, d, "LootPass", "CANCEL", "Cancel", 1.00, 0.35, 0.35, OnConfirmClick)
    ok.confirm, cancel.confirm = true, false
    LayoutRow(d.confirmRow, { ok, cancel })

    d.acc = 0
    d:SetScript("OnUpdate", DialogUpdate)
    return d
end

---------------------------------------------------------------------------
-- Filling / releasing dialogs
---------------------------------------------------------------------------

local function SetBusy(d, busy)
    d.busy = busy
    d.row:SetAlpha(busy and 0.45 or 1)
end

local function ExitConfirm(d)
    d.confirming, d.confirmType = nil, nil
    d.confirmRow:Hide()
    d.row:Show()
    d.header:SetText(d.headerText or "")
    d.sub:SetText(d.subText or "")
    SetBusy(d, false)
end

-- Fill a dialog from the item data. info is a plain table (real roll or test sample).
local function Fill(d, info)
    local btns = d.buttons
    SetAllowed(btns.need, Allowed(info.canNeed), ReasonText(info.reasonNeed, info.deSkill))
    SetAllowed(btns.greed, Allowed(info.canGreed), ReasonText(info.reasonGreed, info.deSkill))
    SetAllowed(btns.de, true, nil)
    SetAllowed(btns.pass, true, nil)
    btns.de:SetShown(Plain(info.canDE) == true)
    LayoutRow(d.row, d.list)
    local icon = info.icon -- may be a hidden (secret) value: only nil-check it when plain
    if not IsSecret(icon) and icon == nil then icon = "Interface\\Icons\\INV_Misc_QuestionMark" end
    d.icon:SetTexture(icon)
    d.name:SetText(info.name)
    local r, g, b = QualityRGB(info.quality)
    d.name:SetTextColor(r, g, b)
    d.ring:SetVertexColor(r, g, b)
    local count = Plain(info.count)
    d.count:SetText(type(count) == "number" and count > 1 and count or "")
    d.headerText = HeaderText(info.type, info.ilvl, info.quality)
    d.subText = Plain(info.bop) and "Binds when picked up" or ""
    d.header:SetText(d.headerText)
    d.sub:SetText(d.subText)
    d.bar:SetValue(1)
    d.bar:SetStatusBarColor(BarColor(1))
end

local function RollInfo(rollID)
    local info = {}
    local ok, texture, name, count, quality, bop, canNeed, canGreed, canDE, rNeed, rGreed, _, deSkill =
        pcall(GetLootRollItemInfo, rollID)
    if not ok then
        LogError("GetLootRollItemInfo", texture)
        info.name, info.canNeed, info.canGreed = "?", true, true
        return info
    end
    info.icon, info.name, info.count, info.quality, info.bop = texture, name, count, quality, bop
    info.canNeed, info.canGreed, info.canDE = canNeed, canGreed, canDE
    info.reasonNeed, info.reasonGreed, info.deSkill = rNeed, rGreed, deSkill
    local lok, link = pcall(GetLootRollItemLink, rollID)
    if lok then info.type, info.ilvl = ItemTypeAndLevel(link) end
    return info
end

local function Acquire()
    local d = table.remove(pool) or CreateDialog()
    d.released, d.expired, d.busy, d.test, d.sample = nil, nil, nil, nil, nil
    d.confirming, d.confirmType, d.lastRoll, d.acc = nil, nil, nil, 1 -- update on the first frame
    d.popupWait = nil
    d.confirmRow:Hide()
    d.row:Show()
    SetBusy(d, false)
    return d
end

Release = function(d)
    if not d or d.released then return end
    d.released = true
    for i = #dialogs, 1, -1 do
        if dialogs[i] == d then table.remove(dialogs, i) end
    end
    if d.rollID ~= nil and byRoll[d.rollID] == d then byRoll[d.rollID] = nil end
    HideTip(d.item)
    for _, btn in ipairs(d.list) do HideTip(btn) end
    d:Hide()
    d.rollID = nil
    pool[#pool + 1] = d
    Layout()
end

local function RollDuration(rollID, rollTime)
    local total = ToMs(rollTime)
    if not total and C_Loot and C_Loot.GetLootRollDuration then
        local ok, v = pcall(C_Loot.GetLootRollDuration, rollID)
        if ok then total = ToMs(v) end
    end
    local ok, left = pcall(GetLootRollTimeLeft, rollID)
    left = ok and Plain(left) or nil
    if type(left) == "number" and left > 0 and (not total or left > total) then total = left end
    return total or 60000
end

local function ShowRoll(rollID, rollTime)
    rollID = Plain(rollID)
    if type(rollID) ~= "number" then
        LogOnce("rollID", "START_LOOT_ROLL with a secret or missing rollID")
        return nil
    end
    local d = byRoll[rollID]
    if not d then
        d = Acquire()
        d.rollID = rollID
        byRoll[rollID] = d
        dialogs[#dialogs + 1] = d
    end
    ours[rollID] = true
    local iok, info = pcall(RollInfo, rollID)
    if not iok then LogError("RollInfo", info) info = { name = "?", canNeed = true, canGreed = true } end
    local ok, err = pcall(Fill, d, info)
    if not ok then LogError("Fill", err) end
    d.total, d.started = RollDuration(rollID, rollTime), GetTime()
    Layout()
    d:Show()
    return d
end

---------------------------------------------------------------------------
-- Rolling and bind-on-pickup confirmation
---------------------------------------------------------------------------

local function ConfirmText(reason)
    reason = Plain(reason)
    if type(reason) == "string" and reason ~= "" then
        local ok, s = pcall(string.format, reason, "this item")
        if ok and type(s) == "string" then return s end
    end
    return "This item will bind to you when picked up."
end

local function EnterConfirm(d, rollType, reason)
    d.confirming, d.confirmType = true, rollType
    d.row:Hide()
    d.confirmRow:Show()
    d.header:SetText("Confirm: " .. (ROLL_NAMES[rollType] or "ROLL"))
    d.sub:SetText(ConfirmText(reason))
end

local function OnConfirm(rollID, rollType, reason)
    rollID, rollType = Plain(rollID), Plain(rollType)
    if type(rollID) ~= "number" or not ours[rollID] then return end
    local d = byRoll[rollID] or (active and ShowRoll(rollID))
    if not d then return end
    if type(rollType) ~= "number" then rollType = d.lastRoll end
    d.confirming, d.confirmType = true, rollType
    -- Give Blizzard's StaticPopup a moment; use our own confirm only if it didn't appear.
    C_Timer.After(0.15, function()
        if d.rollID ~= rollID or d.released then return end
        if BlizzardConfirmShown() then
            d.confirming = nil
            SetBusy(d, false)
            d.popupWait = true
            d.sub:SetText("Confirm the roll in the popup window.")
        else
            EnterConfirm(d, rollType, reason)
        end
    end)
end

OnConfirmClick = function(btn)
    local d = btn.dialog
    if d.test then Release(d) return end
    if not btn.confirm then ExitConfirm(d) return end
    local ok, err = pcall(ConfirmLootRoll, d.rollID, d.confirmType)
    if not ok then
        LogError("ConfirmLootRoll", err)
        Print("couldn't confirm the roll (see /sao errors).")
        ExitConfirm(d)
        return
    end
    Release(d)
end

OnRollClick = function(btn)
    local d = btn.dialog
    if not btn.allowed or d.busy then return end
    if d.test then Release(d) return end
    local id = d.rollID
    d.lastRoll = btn.roll
    local ok, err = pcall(RollOnLoot, id, btn.roll)
    if not ok then
        LogError("RollOnLoot", err)
        Print("roll failed (see /sao errors).")
        return
    end
    if btn.roll == 0 then Release(d) return end
    -- Need/greed/DE may ask for a bind-on-pickup confirmation (CONFIRM_LOOT_ROLL fires);
    -- otherwise the roll is done and the dialog can go.
    SetBusy(d, true)
    C_Timer.After(0.6, function()
        if d.rollID == id and not d.released and not d.confirming and d.busy then Release(d) end
    end)
end

---------------------------------------------------------------------------
-- Blizzard roll frames
---------------------------------------------------------------------------

local function FrameName(f)
    local ok, n = pcall(f.GetName, f)
    if ok and type(n) == "string" then return n end
    if f.GetDebugName then
        ok, n = pcall(f.GetDebugName, f)
        if ok and type(n) == "string" then return n end
    end
    return nil
end

-- Only touch Blizzard frames: UIParent (the live owner) or GroupLoot* / Blizzard* names.
local function IsBlizzardRollOwner(f)
    if f == UIParent then return true end
    local n = FrameName(f)
    if not n then return false end
    return n:find("^GroupLoot") ~= nil or n:find("^Blizzard") ~= nil
end

local function Suppress()
    -- Never hide Blizzard's frames unless our own handler is in place.
    if not (events and events:GetScript("OnEvent") and events:IsEventRegistered("START_LOOT_ROLL")) then
        LogOnce("Suppress", "event frame not ready; leaving Blizzard roll frames alone")
        return
    end
    if not GetFramesRegisteredForEvent then
        if UIParent:IsEventRegistered("START_LOOT_ROLL") then
            UIParent:UnregisterEvent("START_LOOT_ROLL")
            suppressed[#suppressed + 1] = UIParent
        end
        return
    end
    local list = { GetFramesRegisteredForEvent("START_LOOT_ROLL") }
    for _, f in ipairs(list) do
        if f ~= events and IsBlizzardRollOwner(f) then
            local ok, err = pcall(f.UnregisterEvent, f, "START_LOOT_ROLL")
            if ok then suppressed[#suppressed + 1] = f else LogError("Suppress", err) end
        end
    end
end

local function Restore()
    for i = #suppressed, 1, -1 do
        local f = suppressed[i]
        local ok, err = pcall(f.RegisterEvent, f, "START_LOOT_ROLL")
        if not ok then LogError("Restore", err) end
        suppressed[i] = nil
    end
end

-- Fallback: if a Blizzard GroupLootFrame still shows while we're active, hide it on the
-- next frame (outside Blizzard's own call chain).
-- Only hidden when one of our dialogs covers that roll, so a roll is never left without UI.
local function GuardOnShow(self)
    if not active then return end
    C_Timer.After(0, function()
        if not (active and self:IsShown()) then return end
        local id = Plain(self.rollID)
        if type(id) ~= "number" then return end          -- unknown roll: leave Blizzard's frame usable
        if not byRoll[id] then pcall(ShowRoll, id) end
        if byRoll[id] then pcall(self.Hide, self) end     -- hide only when our dialog covers this roll
    end)
end

local function GuardBlizzardFrames()
    for i = 1, math.max(4, tonumber(NUM_GROUP_LOOT_FRAMES) or 4) do
        local f = _G["GroupLootFrame" .. i]
        if f and f.HookScript then
            if not guarded[f] then
                guarded[f] = true
                f:HookScript("OnShow", GuardOnShow)
            end
            if f:IsShown() then GuardOnShow(f) end
        end
    end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local function AdoptOpenRolls()
    local fn = GetActiveLootRollIDs or (C_Loot and C_Loot.GetActiveLootRollIDs)
    if type(fn) ~= "function" then return end
    local res = { pcall(fn) }
    if not res[1] then LogError("GetActiveLootRollIDs", res[2]) return end
    local ids = type(res[2]) == "table" and res[2] or { select(2, unpack(res)) }
    for _, id in ipairs(ids) do
        if type(Plain(id)) == "number" then
            local ok, err = pcall(ShowRoll, id)
            if not ok then LogError("AdoptOpenRolls", err) end
        end
    end
end

-- Our dialog could not be shown: give rolls back to Blizzard so the user can still roll.
local function HandToBlizzard(rollID, rollTime, why)
    LogError("ShowRoll", why)
    active = false
    pcall(Restore)
    pcall(ApplyLock)
    if type(GroupLootFrame_OpenNewFrame) == "function" then
        local ok, err = pcall(GroupLootFrame_OpenNewFrame, rollID, rollTime)
        if not ok then LogError("GroupLootFrame_OpenNewFrame", err) end
    else
        Print("this roll can't be shown; open the roll with /reload or roll from chat links.")
    end
    Print("loot roll dialog failed; Blizzard's roll frames restored (see /sao errors).")
end

local function OnEvent(_, event, a1, a2, a3)
    if event == "START_LOOT_ROLL" then
        if active then
            local ok, d = pcall(ShowRoll, a1, a2)
            if not (ok and d) then HandToBlizzard(a1, a2, ok and "no dialog for roll" or d) end
        end
    elseif event == "CANCEL_LOOT_ROLL" then
        a1 = Plain(a1)
        if a1 ~= nil then
            if ours[a1] and StaticPopup_Hide then pcall(StaticPopup_Hide, "CONFIRM_LOOT_ROLL", a1) end
            Release(byRoll[a1])
            ours[a1] = nil
        end
    elseif event == "CANCEL_ALL_LOOT_ROLLS" then
        for i = #dialogs, 1, -1 do
            if not dialogs[i].test then Release(dialogs[i]) end
        end
        wipe(ours)
    elseif event == "CONFIRM_LOOT_ROLL" or event == "CONFIRM_DISENCHANT_ROLL" then
        OnConfirm(a1, a2, a3)
    elseif event == "ADDON_LOADED" and active then
        -- A load-on-demand Blizzard addon may register the roll event later.
        Suppress()
        GuardBlizzardFrames()
    end
end

local function SafeOnEvent(...)
    local ok, err = pcall(OnEvent, ...)
    if not ok then LogError(tostring((select(2, ...))), err) end
end

local function RegisterEvents()
    if events then return end
    events = CreateFrame("Frame")
    events:SetScript("OnEvent", SafeOnEvent)
    for _, e in ipairs({ "START_LOOT_ROLL", "CANCEL_LOOT_ROLL", "CANCEL_ALL_LOOT_ROLLS", "CONFIRM_LOOT_ROLL",
                         "CONFIRM_DISENCHANT_ROLL", "ADDON_LOADED" }) do
        pcall(events.RegisterEvent, events, e) -- unknown events error on some clients
    end
end

---------------------------------------------------------------------------
-- Anchor / mover
---------------------------------------------------------------------------

local function MoverDragStart()
    if not unlocked then return end
    holder:StartMoving()
    holder.moving = true
end

local function MoverDragStop()
    if not holder.moving then return end
    holder.moving = nil
    holder:StopMovingOrSizing()
    holder:SetUserPlaced(false)
    local db = GetDB()
    if ns.SnapToGrid and db and db.snap then
        local ok, err = pcall(ns.SnapToGrid, holder)
        if not ok then LogOnce("SnapToGrid", err) end
    end
    SavePosition()
    Layout()
end

local function BuildUI()
    if holder then return end
    holder = CreateFrame("Frame", "SAOFrames_LootAnchor", UIParent)
    holder:SetSize(W, H)
    holder:SetFrameStrata("DIALOG")
    holder:SetMovable(true)
    holder:SetClampedToScreen(true)
    holder:SetScale(ldb.scale)
    ApplyPosition()

    mover = CreateFrame("Frame", nil, holder)
    mover:SetAllPoints()
    mover:SetFrameLevel(holder:GetFrameLevel() + 50)
    mover:EnableMouse(true)
    mover:RegisterForDrag("LeftButton")
    mover:SetScript("OnDragStart", MoverDragStart)
    mover:SetScript("OnDragStop", MoverDragStop)
    local bg = mover:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture(Media("LootPanel"))
    bg:SetPoint("TOPLEFT", -8, 8)
    bg:SetPoint("BOTTOMRIGHT", 8, -8)
    bg:SetAlpha(0.75)
    local title = mover:CreateFontString(nil, "OVERLAY")
    Font(title, 16)
    title:SetTextColor(0.25, 0.55, 0.85)
    title:SetPoint("CENTER", 0, 8)
    title:SetText("LOOT ROLL")
    local hint = mover:CreateFontString(nil, "OVERLAY")
    Font(hint, 9)
    hint:SetPoint("TOP", title, "BOTTOM", 0, -6)
    hint:SetText("drag to move")
    mover:Hide()
end

local function Activate()
    BuildUI()
    RegisterEvents()
    active = true
    local ok, err = pcall(Suppress)
    if not ok then LogError("Suppress", err) end
    ok, err = pcall(GuardBlizzardFrames)
    if not ok then LogError("GuardBlizzardFrames", err) end
    ok, err = pcall(AdoptOpenRolls)
    if not ok then LogError("AdoptOpenRolls", err) end
    ApplyLock()
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

function ns.InitLoot()
    ldb = InitDefaults()
    if not ldb then
        LogOnce("InitLoot", "saved variables not ready")
        return
    end
    if not ldb.enabled or active then return end
    local db = GetDB()
    unlocked = db and db.locked == false or false
    Activate()
end

function ns.IsLootEnabled()
    ldb = ldb or InitDefaults()
    return ldb ~= nil and ldb.enabled == true and active
end

function ns.LootSetEnabled(on)
    ldb = ldb or InitDefaults()
    if not ldb then return end
    ldb.enabled = on and true or false
    if on then
        if not active then Activate() end
        Print("SAO loot roll dialogs enabled.")
    else
        active = false
        Restore()
        ApplyLock()
        -- Rolls already open stay in SAO dialogs until they finish.
        Print("SAO loot roll dialogs disabled. Type /reload to fully restore Blizzard's roll frames.")
    end
end

function ns.LootSetLocked(locked)
    unlocked = not locked
    if holder and holder.moving then MoverDragStop() end
    ApplyLock()
end

-- Re-apply scale and position from db.loot (e.g. after an options change).
function ns.LootApply()
    if not holder then return end
    holder:SetScale(ldb.scale)
    ApplyPosition()
    Layout()
end

-- Reset the anchor to its default position (used by /sao reset).
function ns.LootResetPosition()
    ldb = ldb or InitDefaults()
    if not ldb then return end
    local p = LOOT_DEFAULTS.pos
    ldb.pos = { p[1], p[2], p[3], p[4] }
    if not holder then return end
    if holder.moving then
        holder.moving = nil
        holder:StopMovingOrSizing()
    end
    ApplyPosition()
    Layout()
end

function ns.LootTest()
    ldb = ldb or InitDefaults()
    if not ldb then return end
    BuildUI()
    testSeq = testSeq + 1
    local sample = SAMPLES[(testSeq - 1) % #SAMPLES + 1]
    local d = Acquire()
    d.test, d.sample, d.rollID = true, sample, "test" .. testSeq
    byRoll[d.rollID] = d
    dialogs[#dialogs + 1] = d
    local info = {
        icon = sample.icon, name = sample.name, count = 1, quality = sample.quality, bop = sample.bop,
        canNeed = sample.canNeed, canGreed = sample.canGreed, canDE = sample.canDE,
        reasonNeed = sample.reasonNeed, type = sample.type, ilvl = sample.ilvl,
    }
    local ok, err = pcall(Fill, d, info)
    if not ok then LogError("LootTest", err) end
    d.total, d.started = 60000, GetTime()
    Layout()
    d:Show()
end
