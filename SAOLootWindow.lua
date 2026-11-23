-- SAO Frames: Sword Art Online-styled loot window (SAOLootWindow.lua).
--
-- Skins Blizzard's own LootFrame (the window that opens when you loot a corpse or chest) as
-- an SAO "system window": a light translucent panel, a gray "ITEM" header with the item
-- count and a thin cyan accent line, rows with round item icons in quality-tinted rings,
-- names in quality color, an orange hover, and round buttons (blue LOOT ALL, red CLOSE).
--
-- Why a skin and not a replacement: the 12.x LootFrame (ScrollBox of element frames) keeps
-- doing all the work - click-to-loot, shift-click linking, tooltips, autoloot, cursor or Edit
-- Mode positioning, Escape, bind-on-pickup / loot distribution popups. We only hide its art
-- (SetAlpha(0) on its regions; nothing is replaced, no Blizzard function is overwritten) and
-- add our own textures. Our art is always created BEFORE any Blizzard art is hidden, so if
-- anything fails the window stays usable. If the expected structure isn't there (no
-- LootFrame.ScrollBox), Blizzard's window is left untouched.
--
-- Element frames are styled from the ScrollBox's "initialized frame" callback (fires after
-- Blizzard's Init) and again one frame after LOOT_OPENED / LOOT_SLOT_CHANGED / LOOT_SLOT_CLEARED.
-- Per-frame data lives in weak-keyed tables, never on Blizzard frames.
--
-- Secret values: names/links go straight to widget setters (Blizzard sets them); anything
-- we compare goes through Plain() first. API calls are wrapped in pcall.
--
-- Public (on ns): InitLootWindow, LootWindowSetEnabled, IsLootWindowEnabled, LootWindowTest.
-- Saved: db.lootWindow = { enabled = true }.

local ADDON, ns = ...

---------------------------------------------------------------------------
-- Constants
---------------------------------------------------------------------------

local WHITE = "Interface\\Buttons\\WHITE8X8"
local LW_DEFAULTS = { enabled = true }
local HEADER_H = 22       -- header strip height (Blizzard's title area)
local FOOTER_H = 46       -- footer with the round buttons, below Blizzard's frame
local BTN = 26            -- round button size
local BTN_STEP = 70       -- distance between the two button centers
local ICON = 30           -- round item icon size
local ROW_H, ROW_GAP, ROW_PAD = 46, 2, 6 -- Blizzard's element height / spacing / padding
local PREVIEW_W = 220     -- Blizzard's panelWidth
local RING_IDLE = { 0.78, 0.80, 0.84 }
local RING_HOVER = { 1.00, 0.60, 0.15 }
local MONEY_RGB = { 0.30, 0.33, 0.38 }
local GOLD_RGB = { 0.95, 0.75, 0.25 }

-- Sample items for /sao lootwindowtest (clicks only close the preview).
local SAMPLES = {
    { name = "Elucidator", icon = "Interface\\Icons\\INV_Sword_04", quality = 4, count = 1 },
    { name = "Dark Repulser", icon = "Interface\\Icons\\INV_Sword_27", quality = 3, count = 1 },
    { name = "Crystallite Ingot", icon = "Interface\\Icons\\INV_Misc_Gem_Diamond_02", quality = 2, count = 3,
      quest = "!" },
    { name = "Healing Crystal", icon = "Interface\\Icons\\INV_Misc_Gem_Pearl_04", quality = 1, count = 5 },
    { name = "Coat of Midnight", icon = "Interface\\Icons\\INV_Chest_Cloth_17", quality = 3, count = 1,
      locked = true },
    { name = "12 Gold 34 Silver", icon = "Interface\\Icons\\INV_Misc_Coin_01", money = true, count = 1 },
}

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------

local lwdb               -- db.lootWindow
local active = false     -- skin applied (feature enabled and LootFrame found)
local hooksDone = false  -- one-time hooks on LootFrame / its ScrollBox
local events             -- our event frame
local panel              -- our panel art on LootFrame (our own frame)
local preview            -- test preview window
local refreshQueued = false
local clampSaved         -- LootFrame's original clamp insets (we extend the bottom by the footer)
local logged = {}
local cbOwner = {}       -- owner token for the ScrollBox callback
local rowArt = setmetatable({}, { __mode = "k" })      -- Blizzard element frame -> our art
local artByButton = setmetatable({}, { __mode = "k" }) -- item button -> our art (hover)
local hiddenAlpha = setmetatable({}, { __mode = "k" }) -- Blizzard region -> original alpha
local saved = setmetatable({}, { __mode = "k" })       -- Blizzard region -> original look
local noMouse = setmetatable({}, { __mode = "k" })     -- Blizzard buttons we made click-through

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
    if ns.LogError then pcall(ns.LogError, "SAOLootWindow " .. tag .. ": " .. tostring(err)) end
end

local function LogOnce(tag, err)
    if logged[tag] then return end
    logged[tag] = true
    LogError(tag, err)
end

local function Media(name)
    return (ns.MEDIA or ("Interface\\AddOns\\" .. ADDON .. "\\Media\\")) .. name
end

-- outline = true: the addon's white outlined font. Otherwise flat gray text for the light panel.
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
    if type(db.lootWindow) ~= "table" then db.lootWindow = {} end
    local l = db.lootWindow
    if type(l.enabled) ~= "boolean" then l.enabled = LW_DEFAULTS.enabled end
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
    if type(q) ~= "number" then return "" end
    local s = _G["ITEM_QUALITY" .. q .. "_DESC"]
    return type(s) == "string" and s or ""
end

-- 9-slice texture (rounded corners at any size); flat color if slicing isn't supported.
local function Slice(tex, file, margin, r, g, b, a, fallback)
    local ok = false
    if tex.SetTextureSliceMargins then
        tex:SetTexture(Media(file))
        ok = pcall(tex.SetTextureSliceMargins, tex, margin, margin, margin, margin)
        if ok and tex.SetTextureSliceMode then
            local mode = Enum and Enum.UITextureSliceMode and Enum.UITextureSliceMode.Stretched or 0
            pcall(tex.SetTextureSliceMode, tex, mode)
        end
    end
    if ok then
        tex:SetVertexColor(r, g, b, a)
    else
        local f = fallback or { r, g, b, a }
        tex:SetColorTexture(f[1], f[2], f[3], f[4])
    end
end

local function SlotTypeConst(key, default)
    local e = Enum and Enum.LootSlotType
    local v = e and e[key]
    if type(v) == "number" then return v end
    local g = _G["LOOT_SLOT_" .. string.upper(key)]
    return type(g) == "number" and g or default
end
local SLOT_NONE = SlotTypeConst("None", 0)
local SLOT_MONEY = SlotTypeConst("Money", 2)

local function SlotType(slot)
    if type(slot) ~= "number" or not GetLootSlotType then return nil end
    local ok, t = pcall(GetLootSlotType, slot)
    return ok and Plain(t) or nil
end

-- Plain (non-secret) facts about a loot slot; unknown values stay nil.
local function SlotInfo(slot)
    local info = { slotType = SlotType(slot) }
    if type(slot) ~= "number" or not GetLootSlotInfo then return info end
    local ok, err, _, _, _, quality, locked, isQuestItem, questID, isActive = pcall(GetLootSlotInfo, slot)
    if not ok then LogOnce("GetLootSlotInfo", err) return info end
    info.quality, info.locked = Plain(quality), Plain(locked) == true
    info.isQuestItem, info.questID, info.isActive = Plain(isQuestItem), Plain(questID), Plain(isActive)
    return info
end

local function QuestMode(info)
    if info.questID and not info.isActive then return "!" end -- starts a quest
    if info.isQuestItem or info.questID then return "Q" end    -- quest item
    return nil
end

local function NumLootItems()
    if not GetNumLootItems then return nil end
    local ok, n = pcall(GetNumLootItems)
    n = ok and Plain(n) or nil
    return type(n) == "number" and n or nil
end

-- Number of slots that still hold something.
local function CountItems()
    local n = NumLootItems()
    if not n then return nil end
    local c = 0
    for i = 1, n do
        local t = SlotType(i)
        if t == nil or t ~= SLOT_NONE then c = c + 1 end
    end
    return c
end

local function HideTip(self)
    if GameTooltip and GameTooltip:IsOwned(self) then GameTooltip:Hide() end
end

---------------------------------------------------------------------------
-- Blizzard regions: hide / restyle with a record so a disable can put them back
---------------------------------------------------------------------------

local function HideRegion(r)
    if type(r) ~= "table" or not r.SetAlpha then return end
    if hiddenAlpha[r] == nil then hiddenAlpha[r] = r:GetAlpha() or 1 end
    r:SetAlpha(0)
end

-- Remember a region's anchors, size, font and draw layer before we change them.
local function SaveRegion(r)
    if saved[r] then return end
    local rec = { points = {} }
    for i = 1, (r:GetNumPoints() or 0) do rec.points[i] = { r:GetPoint(i) } end
    rec.w, rec.h = r:GetSize()
    if r.GetFontObject then
        rec.fontObj = r:GetFontObject()
        rec.font = { r:GetFont() }
        rec.justV = r.GetJustifyV and r:GetJustifyV()
        rec.justH = r.GetJustifyH and r:GetJustifyH()
        rec.wrap = r.CanWordWrap and r:CanWordWrap()
    end
    if r.GetDrawLayer then rec.layer, rec.sub = r:GetDrawLayer() end
    saved[r] = rec
end

local function RestoreRegion(r, rec)
    if #rec.points > 0 then
        r:ClearAllPoints()
        for _, p in ipairs(rec.points) do r:SetPoint(p[1], p[2], p[3], p[4], p[5]) end
    end
    if rec.w and rec.h then r:SetSize(rec.w, rec.h) end
    if rec.fontObj then
        r:SetFontObject(rec.fontObj)
    elseif rec.font and rec.font[1] then
        r:SetFont(rec.font[1], rec.font[2], rec.font[3])
    end
    if rec.justV and r.SetJustifyV then r:SetJustifyV(rec.justV) end
    if rec.justH and r.SetJustifyH then r:SetJustifyH(rec.justH) end
    if rec.wrap ~= nil and r.SetWordWrap then r:SetWordWrap(rec.wrap) end
    if rec.layer then r:SetDrawLayer(rec.layer, rec.sub or 0) end
end

local function RestoreAllRegions()
    for r, a in pairs(hiddenAlpha) do pcall(r.SetAlpha, r, a) end
    wipe(hiddenAlpha)
    for r, rec in pairs(saved) do
        local ok, err = pcall(RestoreRegion, r, rec)
        if not ok then LogOnce("RestoreRegion", err) end
    end
    wipe(saved)
    for b in pairs(noMouse) do pcall(b.EnableMouse, b, true) end
    wipe(noMouse)
end

---------------------------------------------------------------------------
-- Shared art: panel (header + footer buttons) and rows
---------------------------------------------------------------------------

local function ButtonEnter(self)
    if not GameTooltip then return end
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText(self.title, self.r, self.g, self.b)
    GameTooltip:Show()
end

local function ButtonDown(self) self.disc:SetSize(BTN - 3, BTN - 3) end
local function ButtonUp(self) self.disc:SetSize(BTN, BTN) end

local function CreateRoundButton(parent, tex, label, title, r, g, b, onClick)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(BTN + 24, BTN + 16)
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
    btn.label:SetTextColor(0.36, 0.39, 0.44)
    btn.label:SetPoint("TOP", btn.disc, "BOTTOM", 0, -3)
    btn.label:SetText(label)
    btn.title, btn.r, btn.g, btn.b = title, r, g, b
    btn:SetScript("OnEnter", ButtonEnter)
    btn:SetScript("OnLeave", HideTip)
    btn:SetScript("OnMouseDown", ButtonDown)
    btn:SetScript("OnMouseUp", ButtonUp)
    btn:SetScript("OnClick", onClick)
    return btn
end

-- Panel art on our own frame, covering host plus a footer below it.
local function BuildPanel(host, onLootAll, onClose)
    local p = CreateFrame("Frame", nil, host)
    p:SetPoint("TOPLEFT", host, "TOPLEFT", 0, 0)
    p:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", 0, -FOOTER_H)
    p:SetFrameLevel(host:GetFrameLevel()) -- under the host's rows

    local bg = p:CreateTexture(nil, "BACKGROUND", nil, -7)
    Slice(bg, "LootWindowPanel", 16, 1, 1, 1, 1, { 0.76, 0.80, 0.86, 0.94 })
    bg:SetPoint("TOPLEFT", -5, 5)
    bg:SetPoint("BOTTOMRIGHT", 5, -5)

    local strip = p:CreateTexture(nil, "BACKGROUND", nil, -6)
    Slice(strip, "LootWindowRow", 8, 0.82, 0.85, 0.89, 0.95)
    strip:SetPoint("TOPLEFT", 4, -3)
    strip:SetPoint("TOPRIGHT", -4, -3)
    strip:SetHeight(HEADER_H - 5)
    local accent = p:CreateTexture(nil, "BORDER")
    accent:SetColorTexture(0.30, 0.85, 1.00, 0.9)
    accent:SetHeight(1)
    accent:SetPoint("TOPLEFT", 8, -HEADER_H)
    accent:SetPoint("TOPRIGHT", -8, -HEADER_H)

    p.title = p:CreateFontString(nil, "OVERLAY")
    Font(p.title, 9)
    p.title:SetPoint("LEFT", strip, "LEFT", 8, 0)
    p.title:SetText("ITEM")
    p.count = p:CreateFontString(nil, "OVERLAY")
    Font(p.count, 9)
    p.count:SetTextColor(0.25, 0.28, 0.33)
    p.count:SetPoint("RIGHT", strip, "RIGHT", -8, 0)
    p.count:SetJustifyH("RIGHT")

    local footer = CreateFrame("Frame", nil, p)
    footer:SetPoint("BOTTOMLEFT")
    footer:SetPoint("BOTTOMRIGHT")
    footer:SetHeight(FOOTER_H)
    footer:SetFrameLevel(host:GetFrameLevel() + 20)
    footer:EnableMouse(true) -- don't click through to the world
    local sep = footer:CreateTexture(nil, "ARTWORK")
    sep:SetColorTexture(0.80, 0.83, 0.87, 0.9)
    sep:SetHeight(1)
    sep:SetPoint("TOPLEFT", 8, 0)
    sep:SetPoint("TOPRIGHT", -8, 0)
    p.lootAll = CreateRoundButton(footer, "LootNeed", "LOOT ALL", "Loot all", 0.35, 0.70, 1.00, onLootAll)
    p.lootAll:SetPoint("TOP", footer, "TOP", -BTN_STEP / 2, -5)
    p.close = CreateRoundButton(footer, "LootPass", "CLOSE", "Close", 1.00, 0.35, 0.35, onClose)
    p.close:SetPoint("TOP", footer, "TOP", BTN_STEP / 2, -5)
    p.footer = footer
    return p
end

local function RowEnter(btn)
    local a = artByButton[btn]
    if a and a.shown then a.outer:SetVertexColor(RING_HOVER[1], RING_HOVER[2], RING_HOVER[3]) end
end

local function RowLeave(btn)
    local a = artByButton[btn]
    if a then a.outer:SetVertexColor(RING_IDLE[1], RING_IDLE[2], RING_IDLE[3]) end
end

-- Row art: background, orange hover (HIGHLIGHT layer of btn), icon rings, quest badge, round mask.
local function BuildRowArt(row, btn, icon)
    local a = {}
    a.bg = row:CreateTexture(nil, "BACKGROUND", nil, 1)
    Slice(a.bg, "LootWindowRow", 8, 0.88, 0.90, 0.93, 0.80)
    a.bg:SetPoint("TOPLEFT", row, "TOPLEFT", 1, -1)
    a.bg:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -1, 1)
    a.hi = btn:CreateTexture(nil, "HIGHLIGHT", nil, 1)
    Slice(a.hi, "LootWindowRow", 8, 1.00, 0.62, 0.18, 0.28)
    a.hi:SetAllPoints(a.bg)
    a.bar = btn:CreateTexture(nil, "HIGHLIGHT", nil, 2)
    a.bar:SetColorTexture(1.00, 0.55, 0.10, 0.95)
    a.bar:SetWidth(3)
    a.bar:SetPoint("TOPLEFT", a.bg, "TOPLEFT", 1, -4)
    a.bar:SetPoint("BOTTOMLEFT", a.bg, "BOTTOMLEFT", 1, 4)

    a.outer = btn:CreateTexture(nil, "OVERLAY", nil, 1)
    a.outer:SetTexture(Media("LootRing"))
    a.outer:SetVertexColor(RING_IDLE[1], RING_IDLE[2], RING_IDLE[3])
    a.outer:SetSize(ICON + 10, ICON + 10)
    a.ring = btn:CreateTexture(nil, "OVERLAY", nil, 2)
    a.ring:SetTexture(Media("LootRing"))
    a.ring:SetSize(ICON + 5, ICON + 5)
    if icon then
        a.outer:SetPoint("CENTER", icon, "CENTER")
        a.ring:SetPoint("CENTER", icon, "CENTER")
    end
    a.quest = btn:CreateTexture(nil, "OVERLAY", nil, 4)
    a.quest:SetTexture(Media("SocialDisc"))
    a.quest:SetVertexColor(GOLD_RGB[1], GOLD_RGB[2], GOLD_RGB[3])
    a.quest:SetSize(14, 14)
    a.quest:SetPoint("CENTER", a.outer, "TOPLEFT", 6, -6)
    a.questText = btn:CreateFontString(nil, "OVERLAY")
    Font(a.questText, 9, true)
    a.questText:SetPoint("CENTER", a.quest, "CENTER", 0, 0)
    a.quest:Hide()
    a.questText:Hide()

    if icon and btn.CreateMaskTexture and icon.AddMaskTexture then
        local m = btn:CreateMaskTexture()
        local ok = pcall(m.SetTexture, m, Media("LootIconMask"), "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        if ok then
            m:SetAllPoints(icon)
            a.mask, a.icon = m, icon
        end
    end
    a.regions = { a.bg, a.hi, a.bar, a.outer, a.ring }
    artByButton[btn] = a
    return a
end

local function ShowRowArt(a, on)
    a.shown = on
    for _, r in ipairs(a.regions) do r:SetShown(on) end
    if not on then
        a.quest:Hide()
        a.questText:Hide()
    end
    if a.mask and a.icon then
        if on and not a.masked then
            a.icon:AddMaskTexture(a.mask)
            a.masked = true
        elseif not on and a.masked then
            pcall(a.icon.RemoveMaskTexture, a.icon, a.mask)
            a.masked = false
        end
    end
end

-- Per-slot look. ownText: our own font string (preview) -> SetTextColor; Blizzard's Text is
-- colored with SetVertexColor, the same call Blizzard uses, so ours wins after its Init.
local function ApplyRowState(a, nameFS, icon, quality, locked, questMode, money, ownText)
    local r, g, b
    if money then r, g, b = MONEY_RGB[1], MONEY_RGB[2], MONEY_RGB[3] else r, g, b = QualityRGB(quality) end
    if nameFS then
        if ownText then nameFS:SetTextColor(r, g, b) else nameFS:SetVertexColor(r, g, b) end
        nameFS:SetAlpha(locked and 0.5 or 1)
    end
    if money then a.ring:SetVertexColor(GOLD_RGB[1], GOLD_RGB[2], GOLD_RGB[3]) else a.ring:SetVertexColor(r, g, b) end
    if icon then
        icon:SetDesaturated(locked and true or false)
        if locked then icon:SetVertexColor(0.75, 0.75, 0.75)
        elseif ownText then icon:SetVertexColor(1, 1, 1) end -- Blizzard resets its own icon
    end
    if locked then a.bg:SetVertexColor(0.90, 0.91, 0.92, 0.80) else a.bg:SetVertexColor(1, 1, 1, 0.80) end
    if questMode then
        a.questText:SetText(questMode)
        a.quest:Show()
        a.questText:Show()
    else
        a.quest:Hide()
        a.questText:Hide()
    end
end

---------------------------------------------------------------------------
-- Skinning Blizzard's LootFrame element frames
---------------------------------------------------------------------------

local function IsElement(f)
    return type(f) == "table" and type(f.GetObjectType) == "function" and type(f.GetSlotIndex) == "function"
end

local function ButtonTexture(btn, getter)
    local fn = btn[getter]
    if type(fn) ~= "function" then return nil end
    local ok, t = pcall(fn, btn)
    return ok and t or nil
end

-- One-time restyle of a Blizzard element (our art is built before anything is hidden).
local function ApplyElementSkin(f, a)
    local item = f.Item
    local icon = item.icon or item.Icon
    ShowRowArt(a, true)
    HideRegion(f.NameFrame)
    HideRegion(f.BorderFrame)
    HideRegion(f.HighlightNameFrame)
    HideRegion(f.PushedNameFrame)
    HideRegion(f.QualityStripe)
    HideRegion(f.IconQuestTexture)
    HideRegion(item.IconBorder)
    HideRegion(ButtonTexture(item, "GetNormalTexture"))
    HideRegion(ButtonTexture(item, "GetPushedTexture"))
    HideRegion(ButtonTexture(item, "GetHighlightTexture"))
    if icon then
        SaveRegion(icon)
        icon:ClearAllPoints()
        icon:SetPoint("CENTER", item, "CENTER")
        icon:SetSize(ICON, ICON)
        icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    end
    local text, qt = f.Text, f.QualityText
    if text then
        SaveRegion(text)
        Font(text, 12)
        text:SetTextColor(1, 1, 1) -- the quality color comes from SetVertexColor (ApplyRowState)
        text:ClearAllPoints()
        text:SetJustifyH("LEFT")
        if qt then
            text:SetPoint("LEFT", item, "RIGHT", 10, 6)
            text:SetPoint("RIGHT", f, "RIGHT", -8, 6)
            text:SetHeight(14)
            text:SetWordWrap(false)
            text:SetJustifyV("MIDDLE")
        else -- money: may be two lines
            text:SetPoint("LEFT", item, "RIGHT", 10, 0)
            text:SetPoint("RIGHT", f, "RIGHT", -8, 0)
        end
    end
    if qt and text then
        SaveRegion(qt)
        Font(qt, 8)
        qt:ClearAllPoints()
        qt:SetPoint("TOPLEFT", text, "BOTTOMLEFT", 0, -2)
        qt:SetJustifyH("LEFT")
    end
    local count = item.Count
    if count and count.SetFont then
        SaveRegion(count)
        Font(count, 10, true)
        count:SetDrawLayer("OVERLAY", 7)
        count:ClearAllPoints()
        count:SetPoint("BOTTOMRIGHT", a.outer, "BOTTOMRIGHT", 1, 0)
    end
    a.applied = true
end

local function UpdateElement(f, a)
    local ok, slot = pcall(f.GetSlotIndex, f)
    slot = ok and Plain(slot) or nil
    local info = SlotInfo(slot)
    local q = info.quality
    if q == nil and type(f.GetQuality) == "function" then
        local ok2, v = pcall(f.GetQuality, f)
        q = ok2 and Plain(v) or nil
    end
    local item = f.Item
    local money = info.slotType ~= nil and info.slotType == SLOT_MONEY
    ApplyRowState(a, f.Text, item.icon or item.Icon, q, info.locked, QuestMode(info), money, false)
end

local function StyleElement(f)
    if not active or not IsElement(f) then return end
    local item = f.Item
    if type(item) ~= "table" or type(item.CreateTexture) ~= "function" then return end -- empty slot
    local a = rowArt[f]
    if not a then
        a = BuildRowArt(f, item, item.icon or item.Icon)
        rowArt[f] = a
        if item.HookScript then
            item:HookScript("OnEnter", RowEnter)
            item:HookScript("OnLeave", RowLeave)
        end
    end
    if not a.applied then ApplyElementSkin(f, a) end
    UpdateElement(f, a)
end

local function SafeStyle(...)
    -- Callbacks pass (frame, data) or (owner, frame, data): take the first element frame.
    for i = 1, select("#", ...) do
        local f = select(i, ...)
        if IsElement(f) then
            local ok, err = pcall(StyleElement, f)
            if not ok then LogOnce("StyleElement", err) end
            return
        end
    end
end

local function ForEachElement(fn)
    local sb = LootFrame and LootFrame.ScrollBox
    if type(sb) ~= "table" then return end
    if type(sb.ForEachFrame) == "function" then
        local ok, err = pcall(sb.ForEachFrame, sb, fn)
        if ok then return end
        LogOnce("ForEachFrame", err)
    end
    if type(sb.GetFrames) == "function" then
        local ok, list = pcall(sb.GetFrames, sb)
        if ok and type(list) == "table" then
            for _, f in ipairs(list) do fn(f) end
        end
    end
end

---------------------------------------------------------------------------
-- LootFrame chrome
---------------------------------------------------------------------------

local function InEditMode()
    return LootFrame and Plain(LootFrame.isInEditMode) == true or false
end

local function UpdateHeader()
    if not panel then return end
    local editing = InEditMode()
    local c = not editing and CountItems() or nil
    panel.count:SetText(c and tostring(c) or "")
    panel.footer:SetShown(not editing)
end

local function LootAll()
    local n = NumLootItems()
    if not n or type(LootSlot) ~= "function" then return end
    for i = 1, n do -- one bounded pass; BoP slots raise Blizzard's LOOT_BIND popup, locked ones are skipped
        local info = SlotInfo(i)
        if info.slotType ~= SLOT_NONE and not info.locked then
            local ok, err = pcall(LootSlot, i)
            if not ok then LogError("LootSlot", err) end
        end
    end
end

local function OnLootAllClick()
    if InEditMode() then return end
    LootAll()
end

local function OnCloseClick()
    if InEditMode() then return end
    -- CloseLoot fires LOOT_CLOSED; Blizzard's handler hides its frame.
    local ok, err = pcall(CloseLoot)
    if not ok then
        LogError("CloseLoot", err)
        if LootFrame and LootFrame:IsShown() then pcall(LootFrame.Hide, LootFrame) end
    end
end

local function ApplyChrome()
    local lf = LootFrame
    if not panel then panel = BuildPanel(lf, OnLootAllClick, OnCloseClick) end
    panel:Show()
    HideRegion(lf.NineSlice)
    HideRegion(lf.Bg)
    HideRegion(lf.TitleContainer)
    HideRegion(lf.TopTileStreaks)
    HideRegion(lf.Inset)
    -- Loose textures on the frame itself (template art); font strings and child frames stay.
    for _, r in ipairs({ lf:GetRegions() }) do
        if r.GetObjectType and r:GetObjectType() == "Texture" then HideRegion(r) end
    end
    local cb = lf.CloseButton
    if type(cb) == "table" and cb.EnableMouse then
        HideRegion(cb)
        if cb:IsMouseEnabled() then
            noMouse[cb] = true
            cb:EnableMouse(false)
        end
    end
    -- The footer hangs below LootFrame: extend its clamp rect so the buttons stay on screen
    -- (loot-under-mouse near the bottom edge). Saved once, restored by Unapply.
    if not clampSaved and lf.GetClampRectInsets and lf.SetClampRectInsets then
        local ok, l, r, t, b = pcall(lf.GetClampRectInsets, lf)
        if ok and type(l) == "number" and type(r) == "number" and type(t) == "number" and type(b) == "number" then
            clampSaved = { l, r, t, b }
            pcall(lf.SetClampRectInsets, lf, l, r, t, b - FOOTER_H)
        end
    end
    local sb = lf.ScrollBox
    if type(sb) == "table" then
        HideRegion(ButtonTexture(sb, "GetUpperShadowTexture"))
        HideRegion(ButtonTexture(sb, "GetLowerShadowTexture"))
    end
end

local function RefreshAll()
    refreshQueued = false
    if not active then return end
    local ok, err = pcall(ApplyChrome)
    if not ok then LogOnce("ApplyChrome", err) end
    ForEachElement(SafeStyle)
    ok, err = pcall(UpdateHeader)
    if not ok then LogOnce("UpdateHeader", err) end
end

local function QueueRefresh()
    if refreshQueued then return end
    refreshQueued = true
    if C_Timer and C_Timer.After then C_Timer.After(0, RefreshAll) else RefreshAll() end
end

-- Turn the skin off: hide our art and put Blizzard's regions back (a /reload is cleaner).
local function Unapply()
    active = false
    if panel then panel:Hide() end
    for f, a in pairs(rowArt) do
        ShowRowArt(a, false)
        a.applied = false
        if f.Text then pcall(f.Text.SetAlpha, f.Text, 1) end
        local item = f.Item
        local icon = item and (item.icon or item.Icon)
        if icon then
            pcall(icon.SetDesaturated, icon, false)
            pcall(icon.SetTexCoord, icon, 0, 1, 0, 1)
        end
    end
    RestoreAllRegions()
    if clampSaved and LootFrame and LootFrame.SetClampRectInsets then
        local c = clampSaved
        pcall(LootFrame.SetClampRectInsets, LootFrame, c[1], c[2], c[3], c[4])
    end
    clampSaved = nil
end

local function OnEvent(_, event)
    if event == "PLAYER_REGEN_ENABLED" then
        if events then events:UnregisterEvent("PLAYER_REGEN_ENABLED") end
        if lwdb and lwdb.enabled and not active and ns.LootWindowSetEnabled then ns.LootWindowSetEnabled(true, true) end
        return
    end
    if active then QueueRefresh() end
end

local function SafeOnEvent(...)
    local ok, err = pcall(OnEvent, ...)
    if not ok then LogError(tostring((select(2, ...))), err) end
end

local function RegisterEvents()
    if events then return end
    events = CreateFrame("Frame")
    events:SetScript("OnEvent", SafeOnEvent)
    for _, e in ipairs({ "LOOT_OPENED", "LOOT_SLOT_CLEARED", "LOOT_SLOT_CHANGED", "LOOT_READY" }) do
        pcall(events.RegisterEvent, events, e) -- unknown events error on some clients
    end
end

local function HookLootFrame()
    if hooksDone then return end
    local lf, sb = LootFrame, LootFrame.ScrollBox
    hooksDone = true
    lf:HookScript("OnShow", function()
        if active then RefreshAll() end
    end)
    -- Style each element right after Blizzard initializes it (also pooled/reused frames).
    local ok, err = false, "no ScrollUtil.AddInitializedFrameCallback"
    if ScrollUtil and type(ScrollUtil.AddInitializedFrameCallback) == "function" then
        ok, err = pcall(ScrollUtil.AddInitializedFrameCallback, sb, SafeStyle, cbOwner, true)
    end
    if not ok and type(sb.RegisterCallback) == "function" then
        local ev = (ScrollBoxListMixin and ScrollBoxListMixin.Event and ScrollBoxListMixin.Event.OnInitializedFrame)
            or (BaseScrollBoxEvents and BaseScrollBoxEvents.OnInitializedFrame) or "OnInitializedFrame"
        ok, err = pcall(sb.RegisterCallback, sb, ev, SafeStyle, cbOwner)
    end
    if not ok then LogOnce("InitializedFrameCallback", err) end -- events still restyle one frame later
end

-- Returns true when the skin is on.
local function Activate()
    local lf = LootFrame
    if type(lf) ~= "table" or type(lf.GetObjectType) ~= "function" or type(lf.ScrollBox) ~= "table" then
        LogOnce("structure", "LootFrame.ScrollBox not found; Blizzard's loot window left unchanged")
        return false
    end
    if InCombatLockdown and InCombatLockdown() and lf.IsProtected and lf:IsProtected() then
        RegisterEvents()
        events:RegisterEvent("PLAYER_REGEN_ENABLED")
        return false
    end
    -- Build our panel first: if that fails nothing of Blizzard's is hidden.
    if not panel then
        local ok, p = pcall(BuildPanel, lf, OnLootAllClick, OnCloseClick)
        if not ok then
            LogError("BuildPanel", p)
            return false
        end
        panel = p
    end
    RegisterEvents()
    local ok, err = pcall(HookLootFrame)
    if not ok then LogError("HookLootFrame", err) end
    active = true
    ok, err = pcall(RefreshAll)
    if not ok then
        LogError("RefreshAll", err)
        pcall(Unapply)
        return false
    end
    return true
end

---------------------------------------------------------------------------
-- Test preview (fake window; clicks only close it)
---------------------------------------------------------------------------

local function PreviewItemEnter(btn)
    RowEnter(btn)
    if not GameTooltip then return end
    local s = btn.sample
    GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
    if s.money then GameTooltip:SetText(s.name, 1, 1, 1) else GameTooltip:SetText(s.name, QualityRGB(s.quality)) end
    GameTooltip:AddLine("Sample item (preview)", 0.7, 0.7, 0.7)
    GameTooltip:Show()
end

local function PreviewItemLeave(btn)
    RowLeave(btn)
    HideTip(btn)
end

local function ClosePreview()
    if preview then preview:Hide() end
end

local function BuildPreviewRow(f, i, s)
    local row = CreateFrame("Frame", nil, f)
    row:SetHeight(ROW_H)
    local y = -(HEADER_H + ROW_PAD) - (i - 1) * (ROW_H + ROW_GAP)
    row:SetPoint("TOPLEFT", f, "TOPLEFT", ROW_PAD, y)
    row:SetPoint("TOPRIGHT", f, "TOPRIGHT", -ROW_PAD, y)
    local btn = CreateFrame("Button", nil, row)
    btn:SetAllPoints()
    btn.sample = s
    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetSize(ICON, ICON)
    icon:SetPoint("CENTER", row, "LEFT", 5 + 37 / 2, 0)
    icon:SetTexture(s.icon)
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    local a = BuildRowArt(row, btn, icon)
    ShowRowArt(a, true)
    local name = btn:CreateFontString(nil, "OVERLAY")
    Font(name, 12)
    name:SetJustifyH("LEFT")
    name:SetWordWrap(false)
    name:SetText(s.name)
    local sub
    if not s.money then
        name:SetPoint("LEFT", icon, "RIGHT", 15, 6)
        name:SetPoint("RIGHT", row, "RIGHT", -8, 6)
        sub = btn:CreateFontString(nil, "OVERLAY")
        Font(sub, 8)
        sub:SetPoint("TOPLEFT", name, "BOTTOMLEFT", 0, -2)
        sub:SetText(QualityName(s.quality))
    else
        name:SetPoint("LEFT", icon, "RIGHT", 15, 0)
        name:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    end
    local count = btn:CreateFontString(nil, "OVERLAY")
    Font(count, 10, true)
    count:SetDrawLayer("OVERLAY", 7)
    count:SetPoint("BOTTOMRIGHT", a.outer, "BOTTOMRIGHT", 1, 0)
    count:SetText(s.count and s.count > 1 and tostring(s.count) or "")
    ApplyRowState(a, name, icon, s.quality, s.locked, s.quest, s.money, true)
    btn:SetScript("OnEnter", PreviewItemEnter)
    btn:SetScript("OnLeave", PreviewItemLeave)
    btn:SetScript("OnClick", ClosePreview)
end

local function BuildPreview()
    if preview then return preview end
    local f = CreateFrame("Frame", "SAOFrames_LootWindowPreview", UIParent)
    local h = HEADER_H + ROW_PAD * 2 + #SAMPLES * ROW_H + (#SAMPLES - 1) * ROW_GAP
    f:SetSize(PREVIEW_W, h)
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:SetClampRectInsets(-6, 6, 6, -FOOTER_H - 6)
    f:Hide()
    local p = BuildPanel(f, ClosePreview, ClosePreview)
    p.count:SetText(tostring(#SAMPLES))
    for i, s in ipairs(SAMPLES) do BuildPreviewRow(f, i, s) end
    if type(UISpecialFrames) == "table" then table.insert(UISpecialFrames, "SAOFrames_LootWindowPreview") end
    preview = f
    return f
end

-- Same placement rules as Blizzard: at the cursor with "lootUnderMouse", else where LootFrame sits.
local function PlacePreview(f)
    f:ClearAllPoints()
    local under = false
    if GetCVarBool then
        local ok, v = pcall(GetCVarBool, "lootUnderMouse")
        under = ok and v == true
    end
    local s = f:GetEffectiveScale()
    if under and GetCursorPosition then
        local x, y = GetCursorPosition()
        f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x / s - 30, math.max(y / s + 50, 350))
        return
    end
    local lf = LootFrame
    local left, top
    if lf and lf.GetLeft then
        local ok, l, t = pcall(function() return lf:GetLeft(), lf:GetTop() end)
        if ok then left, top = Plain(l), Plain(t) end
    end
    if type(left) == "number" and type(top) == "number" then
        local ls = lf:GetEffectiveScale()
        f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left * ls / s, top * ls / s)
    else
        f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 120, -220)
    end
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

function ns.InitLootWindow()
    lwdb = InitDefaults()
    if not lwdb then
        LogOnce("InitLootWindow", "saved variables not ready")
        return
    end
    if not lwdb.enabled or active then return end
    Activate()
end

function ns.IsLootWindowEnabled()
    lwdb = lwdb or InitDefaults()
    return lwdb ~= nil and lwdb.enabled == true and active
end

function ns.LootWindowSetEnabled(on, quiet)
    lwdb = lwdb or InitDefaults()
    if not lwdb then return end
    lwdb.enabled = on and true or false
    if on then
        if active or Activate() then
            if not quiet then Print("SAO loot window enabled.") end
        elseif not quiet then
            Print("SAO loot window couldn't be applied; Blizzard's loot window is unchanged (see /sao errors).")
        end
    else
        local ok, err = pcall(Unapply)
        if not ok then LogError("Unapply", err) end
        Print("SAO loot window disabled. Type /reload to fully restore Blizzard's loot window.")
    end
end

function ns.LootWindowTest()
    local ok, f = pcall(BuildPreview)
    if not ok then
        LogError("LootWindowTest", f)
        Print("loot window preview failed (see /sao errors).")
        return
    end
    PlacePreview(f)
    f:Show()
    f:Raise()
end
