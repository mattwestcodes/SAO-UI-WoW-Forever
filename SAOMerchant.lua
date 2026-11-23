-- SAO Frames: Sword Art Online-styled skin of Blizzard's vendor window (SAOMerchant.lua).
--
-- A SKIN, not a replacement: MerchantFrame keeps all of its own logic (buying, selling by
-- right-clicking bag items, repair, buyback, paging, stack split, extended costs). We only
-- hide its art (SetAlpha(0), remembered so a disable can put it back), draw an SAO white
-- panel behind it, restyle its regions and re-texture its buttons. Blizzard's OnClick
-- handlers, names, prices, colors and red "can't use / can't buy" tints are left alone; we
-- read text colors afterwards and only darken ones that would vanish on a white panel.
--
-- Updates follow Blizzard through hooksecurefunc (MerchantFrame_UpdateMerchantInfo,
-- MerchantFrame_UpdateBuybackInfo, MerchantFrameItem_UpdateQuality, currencies) - no
-- Blizzard function is replaced and no field is written onto a Blizzard frame (all our
-- per-frame state lives in weak-keyed tables).
--
-- Secret values: the vendor name (UnitName("npc")) only ever goes to FontString:SetText.
--
-- Public (on ns): InitMerchant, MerchantSetEnabled, IsMerchantEnabled. db.merchant = { enabled }.

local ADDON, ns = ...

---------------------------------------------------------------------------
-- Constants
---------------------------------------------------------------------------

local WHITE = "Interface\\Buttons\\WHITE8X8"
local MERCHANT_DEFAULTS = { enabled = true }
local NUM_ITEMS = 12

local DARK = { 0.20, 0.22, 0.26 }    -- body text
local LABEL = { 0.42, 0.45, 0.50 }   -- small uppercase labels
local MUTED = { 0.05, 0.06, 0.08 }   -- tabs: all near-black (the orange underline marks the selected one)
local ORANGE = { 1.00, 0.60, 0.15 }  -- hover / selected
local CYAN = { 0.30, 0.85, 1.00 }    -- accent line
local RING_PLAIN = { 0.78, 0.80, 0.84 }

-- Tabs moved into the header: { global name, label, x, width }.
local TABS = {
    { "MerchantFrameTab1", "BUY", 12, 46 },
    { "MerchantFrameTab2", "BUYBACK", 62, 70 },
}
local TAB_TOP, TAB_BOTTOM = -36, -58

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------

local mdb               -- db.merchant
local enabled = false
local skinned = false   -- MerchantFrame restyled
local pendingCombat = false
local mode = "merchant" -- "merchant" | "buyback" (the tab Blizzard last drew)
local events            -- our event frame
local logged = {}
local hooked = {}       -- global function name / script key -> true
local ui = {}           -- our own header / panel parts

local weak = { __mode = "k" }
local own = setmetatable({}, weak)       -- regions we created
local hidden = setmetatable({}, weak)    -- Blizzard region -> its alpha before we hid it
local cards = setmetatable({}, weak)     -- MerchantItemN / MerchantBuyBackItem -> our parts
local tabParts = setmetatable({}, weak)  -- tab button -> { label, line, index }
local chevrons = setmetatable({}, weak)  -- page button -> our arrow texture
local lastColor = setmetatable({}, weak) -- FontString -> { r, g, b, ringR, ringG, ringB } we set

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function IsSecret(v)
    if ns.IsSecret then return ns.IsSecret(v) end
    return issecretvalue ~= nil and issecretvalue(v) or false
end

local function Print(msg)
    if ns.Print then ns.Print(msg) else print("SAO Frames: " .. msg) end
end

local function LogError(tag, err)
    if ns.LogError then pcall(ns.LogError, "SAOMerchant " .. tag .. ": " .. tostring(err)) end
end

local function LogOnce(tag, err)
    if logged[tag] then return end
    logged[tag] = true
    LogError(tag, err)
end

local function Safe(tag, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then LogOnce(tag, err) end
    return ok
end

local function Media(name)
    return (ns.MEDIA or ("Interface\\AddOns\\" .. ADDON .. "\\Media\\")) .. name
end

local function GetDB()
    if ns.GetDB then return ns.GetDB() end
    return SAOFramesDB
end

local function InitDefaults()
    local db = GetDB()
    if type(db) ~= "table" then return nil end
    if type(db.merchant) ~= "table" then db.merchant = {} end
    local m = db.merchant
    if type(m.enabled) ~= "boolean" then m.enabled = MERCHANT_DEFAULTS.enabled end
    return m
end

local function G(name) return _G[name] end

local function FrameName(f)
    if not (f and f.GetName) then return nil end
    local ok, n = pcall(f.GetName, f)
    if ok and type(n) == "string" and not IsSecret(n) then return n end
    return nil
end

-- A child of a Blizzard frame by parentKey, falling back to its global "$parent<suffix>" name.
local function Child(f, key, suffix)
    if not f then return nil end
    local ok, v = pcall(function() return f[key] end)
    if ok and v then return v end
    local n = FrameName(f)
    return n and _G[n .. (suffix or key)] or nil
end

-- Flat dark text for the light panel (addon font when available, no outline/shadow).
local function Font(fs, size, color, stdFont)
    local path = (not stdFont and ns.fontPath) or STANDARD_TEXT_FONT
    if not (pcall(fs.SetFont, fs, path, size, "") and fs:GetFont()) then
        fs:SetFont(STANDARD_TEXT_FONT, size, "")
    end
    fs:SetShadowOffset(0, 0)
    local c = color or LABEL
    fs:SetTextColor(c[1], c[2], c[3])
end

local function NewText(parent, size, color, stdFont)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    own[fs] = true
    Font(fs, size, color, stdFont)
    fs:SetWordWrap(false)
    return fs
end

local function NewTexture(parent, layer, sub, path)
    local t = parent:CreateTexture(nil, layer or "ARTWORK", nil, sub or 0)
    own[t] = true
    if path then t:SetTexture(path) end
    return t
end

local function ColorTex(parent, layer, sub, c, a)
    local t = NewTexture(parent, layer, sub, WHITE)
    t:SetVertexColor(c[1], c[2], c[3], a or 1)
    return t
end

-- Hide a Blizzard region or frame by alpha (survives Blizzard's Show/Hide); remember the
-- original alpha the first time so a disable can restore it.
local function Kill(region)
    if not (region and region.SetAlpha) or own[region] then return end
    if hidden[region] == nil then
        local ok, a = pcall(region.GetAlpha, region)
        hidden[region] = (ok and type(a) == "number" and not IsSecret(a)) and a or 1
    end
    pcall(region.SetAlpha, region, 0)
end

-- Hide every texture region a frame owns itself (not its children, not ours).
local function StripTextures(frame)
    if not (frame and frame.GetRegions) then return end
    local regions = { frame:GetRegions() }
    for _, r in ipairs(regions) do
        local ok, kind = pcall(r.GetObjectType, r)
        if ok and kind == "Texture" and not own[r] then Kill(r) end
    end
end

local function KillFontStrings(frame)
    if not (frame and frame.GetRegions) then return end
    local regions = { frame:GetRegions() }
    for _, r in ipairs(regions) do
        local ok, kind = pcall(r.GetObjectType, r)
        if ok and kind == "FontString" and not own[r] then Kill(r) end
    end
end

-- 9-slice texture (manual, works on any client): texSize/slice in texture pixels, disp is the
-- on-screen corner size, l/t/r/b offsets of the outer edge from `anchor`'s corners.
local function MakeSlices(owner, anchor, path, texSize, slice, disp, l, t, r, b, layer, sub)
    local c = slice / texSize
    local span = { { 0, c }, { c, 1 - c }, { 1 - c, 1 } }
    local s = {}
    for row = 1, 3 do
        for col = 1, 3 do
            local tex = NewTexture(owner, layer or "BACKGROUND", sub or -8, path)
            tex:SetTexCoord(span[col][1], span[col][2], span[row][1], span[row][2])
            s[#s + 1] = tex
        end
    end
    local tl, tm, tr, ml, mm, mr, bl, bm, br = unpack(s)
    tl:SetSize(disp, disp); tr:SetSize(disp, disp); bl:SetSize(disp, disp); br:SetSize(disp, disp)
    tl:SetPoint("TOPLEFT", anchor, "TOPLEFT", l, t)
    tr:SetPoint("TOPRIGHT", anchor, "TOPRIGHT", r, t)
    bl:SetPoint("BOTTOMLEFT", anchor, "BOTTOMLEFT", l, b)
    br:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMRIGHT", r, b)
    tm:SetPoint("TOPLEFT", tl, "TOPRIGHT"); tm:SetPoint("BOTTOMRIGHT", tr, "BOTTOMLEFT")
    bm:SetPoint("TOPLEFT", bl, "TOPRIGHT"); bm:SetPoint("BOTTOMRIGHT", br, "BOTTOMLEFT")
    ml:SetPoint("TOPLEFT", tl, "BOTTOMLEFT"); ml:SetPoint("BOTTOMRIGHT", bl, "TOPRIGHT")
    mr:SetPoint("TOPLEFT", tr, "BOTTOMLEFT"); mr:SetPoint("BOTTOMRIGHT", br, "TOPRIGHT")
    mm:SetPoint("TOPLEFT", tl, "BOTTOMRIGHT"); mm:SetPoint("BOTTOMRIGHT", br, "TOPLEFT")
    return s
end

local function SliceColor(s, r, g, b, a)
    for _, tex in ipairs(s) do tex:SetVertexColor(r, g, b, a or 1) end
end

local function SliceAlpha(s, a)
    for _, tex in ipairs(s) do tex:SetAlpha(a) end
end

-- Invisible region used only as a two-point anchor box for slices.
local function Box(owner, p1, rel1, rp1, x1, y1, p2, rel2, rp2, x2, y2)
    local t = NewTexture(owner, "BACKGROUND", -8)
    t:SetPoint(p1, rel1, rp1, x1, y1)
    t:SetPoint(p2, rel2, rp2, x2, y2)
    return t
end

-- Round icon: clip a Blizzard icon texture with our circular mask.
local function RoundIcon(owner, icon)
    if not (icon and owner.CreateMaskTexture and icon.AddMaskTexture) then return end
    Safe("mask", function()
        local m = owner:CreateMaskTexture()
        own[m] = true
        m:SetTexture(Media("LootIconMask"), "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        m:SetAllPoints(icon)
        icon:AddMaskTexture(m)
    end)
end

-- Replace a button's highlight with the round SAO glow (keeps the same texture object).
local function RoundHighlight(btn, anchor, size, c)
    local hl = btn.GetHighlightTexture and btn:GetHighlightTexture()
    if not hl then
        if not btn.SetHighlightTexture then return end
        pcall(btn.SetHighlightTexture, btn, Media("LootButtonHi"), "ADD")
        hl = btn:GetHighlightTexture()
        if not hl then return end
    end
    pcall(hl.SetTexture, hl, Media("LootButtonHi"))
    pcall(hl.SetTexCoord, hl, 0, 1, 0, 1)
    pcall(hl.SetBlendMode, hl, "ADD")
    hl:SetVertexColor(c[1], c[2], c[3], 0.9)
    hl:ClearAllPoints()
    hl:SetPoint("CENTER", anchor or btn, "CENTER")
    hl:SetSize(size, size)
end

-- Give a Blizzard button round textures (its OnClick stays untouched).
local function RoundButton(btn, path, size, r, g, b, hi)
    if not btn then return end
    btn:SetSize(size, size)
    local function apply(setter, getter, tint, desat)
        if not btn[setter] then return end
        pcall(btn[setter], btn, path)
        local t = btn[getter] and btn[getter](btn)
        if not t then return end
        pcall(t.SetTexCoord, t, 0, 1, 0, 1)
        t:ClearAllPoints()
        t:SetAllPoints(btn)
        t:SetVertexColor(r * tint, g * tint, b * tint)
        if desat then pcall(t.SetDesaturated, t, true); t:SetAlpha(0.45) end
    end
    apply("SetNormalTexture", "GetNormalTexture", 1)
    apply("SetPushedTexture", "GetPushedTexture", 0.82)
    apply("SetDisabledTexture", "GetDisabledTexture", 1, true)
    RoundHighlight(btn, btn, size + 10, hi or ORANGE)
end

local function Near(a, b) return math.abs(a - b) < 0.012 end

local function ReadColor(fs)
    if not (fs and fs.GetTextColor) then return nil end
    local ok, r, g, b = pcall(fs.GetTextColor, fs)
    if not ok or type(r) ~= "number" or IsSecret(r) or IsSecret(g) or IsSecret(b) then return nil end
    return r, g, b
end

-- Item name: Blizzard sets the quality color; white/very light ones are unreadable on our
-- panel, so darken them (white -> slate). Returns the original color for the icon ring.
-- lastColor makes this idempotent (re-running never darkens our own color again).
local function NameColor(fs)
    local r, g, b = ReadColor(fs)
    if not r then return nil end
    local c = lastColor[fs]
    if c and Near(c[1], r) and Near(c[2], g) and Near(c[3], b) then return c[4], c[5], c[6] end
    local nr, ng, nb, rr, rg, rb
    if r > 0.9 and g > 0.9 and b > 0.9 then
        nr, ng, nb = DARK[1], DARK[2], DARK[3]
        rr, rg, rb = RING_PLAIN[1], RING_PLAIN[2], RING_PLAIN[3]
    else
        nr, ng, nb = r * 0.82, g * 0.82, b * 0.82
        rr, rg, rb = r, g, b
    end
    fs:SetTextColor(nr, ng, nb)
    lastColor[fs] = { nr, ng, nb, rr, rg, rb }
    return rr, rg, rb
end

-- Price / money text: white -> slate, yellow -> dark gold; gray and red (Blizzard's
-- "can't afford") stay exactly as Blizzard set them. Idempotent.
local function MoneyText(fs)
    -- Blizzard's price font has a heavy outline + shadow made for dark backgrounds; on the
    -- light SAO cards it smears the digits, so draw them clean (no outline / shadow).
    local okF, font, size = pcall(fs.GetFont, fs)
    if okF and font then pcall(fs.SetFont, fs, font, size or 12, "") end
    if fs.SetShadowOffset then fs:SetShadowOffset(0, 0) end
    local r, g, b = ReadColor(fs)
    if not r then return end
    if r > 0.9 and g > 0.9 and b > 0.9 then
        fs:SetTextColor(DARK[1], DARK[2], DARK[3])
    elseif r > 0.9 and g > 0.7 and b < 0.25 then
        fs:SetTextColor(0.72, 0.55, 0.05)
    end
end

local function ButtonText(btn)
    if not btn then return nil end
    local fs = Child(btn, "Text")
    if not fs and btn.GetFontString then fs = btn:GetFontString() end
    return fs
end

local function RecolorMoneyFrame(frame)
    if not frame then return end
    for _, key in ipairs({ "GoldButton", "SilverButton", "CopperButton" }) do
        local fs = ButtonText(Child(frame, key))
        if fs then MoneyText(fs) end
    end
end

local function RecolorAltCurrency(frame)
    local n = FrameName(frame)
    if not n then return end
    for k = 1, 3 do
        local fs = ButtonText(_G[n .. "Item" .. k])
        if fs then MoneyText(fs) end
    end
end

---------------------------------------------------------------------------
-- Skinning pieces
---------------------------------------------------------------------------

-- One item cell (MerchantItemN or MerchantBuyBackItem): light rounded card, round icon.
local function SkinItem(item)
    if not item or cards[item] then return end
    StripTextures(item) -- SlotTexture, NameFrame
    local p = {}
    p.card = MakeSlices(item, item, Media("MerchantCard"), 64, 16, 10, -3, 2, 3, -3, "BACKGROUND", -8)
    local btn = Child(item, "ItemButton")
    if btn then
        local icon = Child(btn, "icon", "IconTexture") or Child(btn, "Icon", "IconTexture")
        Kill(btn.GetNormalTexture and btn:GetNormalTexture())
        Kill(btn.GetPushedTexture and btn:GetPushedTexture())
        Kill(Child(btn, "IconBorder"))
        if icon then
            RoundIcon(btn, icon)
            p.outer = NewTexture(btn, "ARTWORK", 6, Media("LootRing"))
            p.outer:SetPoint("CENTER", icon, "CENTER")
            p.outer:SetSize(44, 44)
            p.outer:SetVertexColor(RING_PLAIN[1], RING_PLAIN[2], RING_PLAIN[3])
            p.inner = NewTexture(btn, "ARTWORK", 7, Media("LootRing"))
            p.inner:SetPoint("CENTER", icon, "CENTER")
            p.inner:SetSize(39, 39)
            RoundHighlight(btn, icon, 50, ORANGE)
        end
        p.button = btn
    end
    local name = Child(item, "Name")
    if name then
        -- Keep Blizzard's font (glyph coverage for item names), just drop the shadow.
        pcall(name.SetShadowOffset, name, 0, 0)
        p.name = name
    end
    p.nameFrame = Child(item, "NameFrame")
    local n = FrameName(item)
    p.money = n and _G[n .. "MoneyFrame"]
    p.alt = n and _G[n .. "AltCurrencyFrame"]
    cards[item] = p
end

local function RefreshItem(item)
    local p = item and cards[item]
    if not p then return end
    if p.name and p.outer then
        local r, g, b = NameColor(p.name)
        if r then p.outer:SetVertexColor(r, g, b) end
    elseif p.name then
        NameColor(p.name)
    end
    -- Mirror Blizzard's red "can't use / can't buy" tint (on the hidden NameFrame) on our card.
    -- Blizzard uses (1,0,0) when available and (0.5,0,0) when sold out / known heirloom.
    local red = false
    if p.nameFrame and p.nameFrame.GetVertexColor then
        local ok, r, g, b = pcall(p.nameFrame.GetVertexColor, p.nameFrame)
        red = ok and type(r) == "number" and not IsSecret(r) and not IsSecret(g) and not IsSecret(b)
            and r > 0.4 and g < 0.2 and b < 0.2 or false
    end
    -- softened (not pure white) cards; red = can't buy / can't use
    if red then SliceColor(p.card, 0.93, 0.76, 0.76) else SliceColor(p.card, 0.87, 0.89, 0.92) end
    local filled = p.button and p.button:IsShown()
    SliceAlpha(p.card, filled and 1 or 0.45)
    RecolorMoneyFrame(p.money)
    RecolorAltCurrency(p.alt)
end

-- Blizzard re-shows / re-colors its own tab text ("Merchant", "BuyBack") whenever tabs
-- change, so its text is hidden again every time we update (only our labels show).
local function HideBlizzardTabText(tab)
    KillFontStrings(tab)
    local fs = tab.Text or (tab.GetFontString and tab:GetFontString())
    if fs and not own[fs] then
        pcall(fs.SetAlpha, fs, 0)
        if fs.Hide then pcall(fs.Hide, fs) end
    end
end

local function SetTabSelected(index)
    for tab in pairs(tabParts) do HideBlizzardTabText(tab) end
    for _, t in pairs(tabParts) do
        local sel = t.index == index
        t.selected = sel
        t.line:SetShown(sel)
        local c = t.hover and ORANGE or MUTED
        t.label:SetTextColor(c[1], c[2], c[3])
    end
end

local function TabEnter(tab)
    local t = tabParts[tab]
    if not t then return end
    t.hover = true
    t.label:SetTextColor(ORANGE[1], ORANGE[2], ORANGE[3])
end

local function TabLeave(tab)
    local t = tabParts[tab]
    if not t then return end
    t.hover = false
    local c = MUTED
    t.label:SetTextColor(c[1], c[2], c[3])
end

-- Blizzard's tab buttons, flattened and moved into the header (OnClick unchanged). Two-point
-- anchors fix their size, so PanelTemplates_TabResize can't stretch them.
local function SkinTab(frame, spec, index)
    local tab = G(spec[1])
    if not tab or tabParts[tab] then return end
    StripTextures(tab)
    KillFontStrings(tab)
    tab:ClearAllPoints()
    tab:SetPoint("TOPLEFT", frame, "TOPLEFT", spec[3], TAB_TOP)
    tab:SetPoint("BOTTOMRIGHT", frame, "TOPLEFT", spec[3] + spec[4], TAB_BOTTOM)
    local label = NewText(tab, 11, MUTED)
    -- bold: same face, thick outline swapped for a heavier font when the bold font exists
    if ns.BOLD_FONT then pcall(label.SetFont, label, ns.fontPath or ns.BOLD_FONT, 11, "") end
    label:SetPoint("CENTER", 0, 1)
    label:SetText(spec[2])
    local line = ColorTex(tab, "OVERLAY", 2, ORANGE)
    line:SetHeight(2)
    line:SetPoint("BOTTOMLEFT", 4, 0)
    line:SetPoint("BOTTOMRIGHT", -4, 0)
    line:Hide()
    tabParts[tab] = { label = label, line = line, index = index }
    tab:HookScript("OnEnter", TabEnter)
    tab:HookScript("OnLeave", TabLeave)
    tab:HookScript("OnShow", HideBlizzardTabText)
    tab:HookScript("OnClick", HideBlizzardTabText)
    HideBlizzardTabText(tab)
end

local function ChevronState(btn)
    local t = chevrons[btn]
    if t then t:SetAlpha(btn:IsEnabled() and 1 or 0.35) end
end

local function SkinPageButton(btn, flip)
    if not btn or chevrons[btn] then return end
    KillFontStrings(btn)
    -- Hide the unnamed UI-PageButton-Background region, but not the state textures that
    -- RoundButton re-textures (killing those would leave the button invisible).
    local state = {}
    for _, getter in ipairs({ "GetNormalTexture", "GetPushedTexture", "GetDisabledTexture", "GetHighlightTexture" }) do
        local t = btn[getter] and btn[getter](btn)
        if t then state[t] = true end
    end
    for _, r in ipairs({ btn:GetRegions() }) do
        local ok, kind = pcall(r.GetObjectType, r)
        if ok and kind == "Texture" and not state[r] then Kill(r) end
    end
    RoundButton(btn, Media("SocialDisc"), 24, 0.90, 0.92, 0.95)
    local ring = NewTexture(btn, "ARTWORK", 1, Media("LootRing"))
    ring:SetAllPoints(btn)
    ring:SetVertexColor(0.72, 0.75, 0.80)
    local arrow = NewTexture(btn, "OVERLAY", 1, Media("SocialIconChevron"))
    arrow:SetSize(11, 11)
    arrow:SetPoint("CENTER", flip and -1 or 1, 0)
    arrow:SetVertexColor(DARK[1], DARK[2], DARK[3])
    if flip then arrow:SetTexCoord(1, 0, 0, 1) end
    chevrons[btn] = arrow
    btn:HookScript("OnEnable", ChevronState)
    btn:HookScript("OnDisable", ChevronState)
    ChevronState(btn)
end

-- Repair / sell-junk buttons: keep Blizzard's icon (it desaturates it when unusable), clip it
-- round and put it in a ring.
local function SkinIconButton(btn)
    if not btn or chevrons[btn] then return end
    local icon = Child(btn, "Icon")
    btn:SetSize(32, 32)
    if icon then
        -- Only when the icon is its own texture (else the normal texture IS the icon).
        Kill(btn.GetNormalTexture and btn:GetNormalTexture())
        Kill(btn.GetPushedTexture and btn:GetPushedTexture())
        icon:ClearAllPoints()
        icon:SetPoint("CENTER")
        icon:SetSize(28, 28)
        RoundIcon(btn, icon)
    end
    if icon then
        -- hide the square gold button frame around the icon (keep only the icon itself)
        for _, region in ipairs({ btn:GetRegions() }) do
            if region ~= icon and region.GetObjectType and region:GetObjectType() == "Texture"
                and region ~= (btn.GetHighlightTexture and btn:GetHighlightTexture()) then
                region:SetAlpha(0)
            end
        end
    end
    local ring = NewTexture(btn, "OVERLAY", 1, Media("LootRing"))
    ring:SetSize(33, 33)
    ring:SetPoint("CENTER")
    ring:SetVertexColor(0.80, 0.68, 0.40)
    RoundHighlight(btn, btn, 42, ORANGE)
    chevrons[btn] = ring -- marks it skinned (alpha follows enabled state too)
    btn:HookScript("OnEnable", ChevronState)
    btn:HookScript("OnDisable", ChevronState)
    ChevronState(btn)
end

local function SkinCloseButton(frame)
    local close = Child(frame, "CloseButton") or G("MerchantFrameCloseButton")
    if not close then return end
    RoundButton(close, Media("LootPass"), 20, 1, 1, 1, { 1.00, 0.35, 0.35 })
    close:ClearAllPoints()
    close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, -6)
end

local function SkinTokens()
    local i = 1
    while true do
        local tok = _G["MerchantToken" .. i]
        if not tok then break end
        local fs = Child(tok, "Count")
        if fs then
            pcall(fs.SetShadowOffset, fs, 0, 0)
            MoneyText(fs)
        end
        i = i + 1
    end
end

local function UpdateHeader()
    if not ui.name then return end
    -- UnitName may be secret: pass it straight to SetText, never test it.
    local ok, n = pcall(UnitName, "npc")
    if ok then pcall(ui.name.SetText, ui.name, n) end
    if ui.portrait and SetPortraitTexture then
        pcall(SetPortraitTexture, ui.portrait, "npc")
    end
end

-- Hide Blizzard's frame art and build our panel, header and money bar.
local function SkinFrame(frame)
    Kill(Child(frame, "NineSlice"))
    Kill(Child(frame, "Bg"))
    Kill(Child(frame, "TopTileStreaks"))
    Kill(Child(frame, "PortraitContainer"))
    Kill(Child(frame, "TitleContainer"))
    Kill(G("MerchantFramePortrait"))
    Kill(Child(frame, "portrait", "Portrait"))
    Kill(G("MerchantFrameTitleText"))
    local inset = Child(frame, "Inset") or G("MerchantFrameInset")
    if inset then
        Kill(Child(inset, "Bg"))
        Kill(Child(inset, "NineSlice"))
        StripTextures(inset)
    end
    for _, n in ipairs({ "MerchantExtraCurrencyInset", "MerchantMoneyInset" }) do
        local f = G(n)
        if f then
            Kill(Child(f, "Bg"))
            Kill(Child(f, "NineSlice"))
            StripTextures(f)
        end
    end
    StripTextures(G("MerchantExtraCurrencyBg"))
    StripTextures(G("MerchantMoneyBg"))
    Kill(G("BuybackBG"))
    Kill(G("MerchantFrameBottomLeftBorder"))
    Kill(G("MerchantFrameBottomRightBorder"))
    StripTextures(frame) -- anything else drawn on the frame itself

    -- Panel (shadow margin 12px in the texture, drawn 1:1).
    ui.panel = MakeSlices(frame, frame, Media("MerchantPanel"), 128, 32, 32, -12, 12, 12, -12, "BACKGROUND", -8)
    SliceColor(ui.panel, 0.74, 0.78, 0.84, 0.95) -- soft steel-gray glass instead of bright white

    -- Header strip: round NPC portrait, small label, vendor name, cyan accent line.
    ui.headerBox = Box(frame, "TOPLEFT", frame, "TOPLEFT", 3, -3, "BOTTOMRIGHT", frame, "TOPRIGHT", -3, -31)
    ui.header = MakeSlices(frame, ui.headerBox, Media("MerchantCard"), 64, 16, 10, 0, 0, 0, 0, "BACKGROUND", -6)
    SliceColor(ui.header, 0.82, 0.85, 0.90)
    ui.accent = ColorTex(frame, "BORDER", 1, CYAN, 0.9)
    ui.accent:SetHeight(1)
    ui.accent:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -32)
    ui.accent:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -10, -32)

    ui.portraitRing = NewTexture(frame, "ARTWORK", 2, Media("LootRing"))
    ui.portraitRing:SetSize(26, 26)
    ui.portraitRing:SetPoint("CENTER", frame, "TOPLEFT", 20, -17)
    ui.portraitRing:SetVertexColor(0.72, 0.75, 0.80)
    ui.portrait = NewTexture(frame, "ARTWORK", 1)
    ui.portrait:SetSize(22, 22)
    ui.portrait:SetPoint("CENTER", ui.portraitRing, "CENTER")
    RoundIcon(frame, ui.portrait)

    ui.label = NewText(frame, 8, LABEL)
    ui.label:SetPoint("TOPLEFT", frame, "TOPLEFT", 38, -7)
    ui.label:SetText("MERCHANT")
    ui.name = NewText(frame, 12, DARK, true) -- game font: vendor names in any locale
    ui.name:SetPoint("TOPLEFT", frame, "TOPLEFT", 38, -16)
    ui.name:SetPoint("RIGHT", frame, "TOPRIGHT", -34, -16)
    ui.name:SetJustifyH("LEFT")

    -- Tab row baseline (the selected tab's orange underline sits on it).
    ui.baseline = ColorTex(frame, "BORDER", 1, { 0.82, 0.85, 0.89 })
    ui.baseline:SetHeight(1)
    ui.baseline:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, TAB_BOTTOM - 1)
    ui.baseline:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -10, TAB_BOTTOM - 1)

    -- Divider above the repair / buyback zone (merchant tab only).
    ui.divider = ColorTex(frame, "BORDER", 1, { 0.82, 0.85, 0.89 })
    ui.divider:SetHeight(1)
    ui.divider:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 10, 76)
    ui.divider:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -10, 76)

    -- Light money bar along the bottom (player money right, extra currencies left).
    ui.barBox = Box(frame, "TOPLEFT", frame, "BOTTOMLEFT", 6, 27, "BOTTOMRIGHT", frame, "BOTTOMRIGHT", -6, 5)
    ui.bar = MakeSlices(frame, ui.barBox, Media("MerchantCard"), 64, 16, 8, 0, 0, 0, 0, "BACKGROUND", -6)
    SliceColor(ui.bar, 0.84, 0.86, 0.90)
    ui.barAccent = ColorTex(frame, "BACKGROUND", -5, CYAN, 0.7)
    ui.barAccent:SetHeight(1)
    ui.barAccent:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 14, 28)
    ui.barAccent:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -14, 28)

    -- Filter dropdown: nudge it into the tab row, under the header's accent line.
    local dd = Child(frame, "FilterDropdown") or G("MerchantFrameLootFilter")
    if dd and dd.ClearAllPoints then
        dd:ClearAllPoints()
        dd:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -12, -34)
    end

    local pageText = G("MerchantPageText")
    if pageText then
        pcall(pageText.SetShadowOffset, pageText, 0, 0)
        pageText:SetTextColor(LABEL[1], LABEL[2], LABEL[3])
    end
end

local function Skin()
    local frame = G("MerchantFrame")
    if not frame then return end
    Safe("SkinFrame", SkinFrame, frame)
    for i, spec in ipairs(TABS) do Safe("SkinTab", SkinTab, frame, spec, i) end
    for i = 1, NUM_ITEMS do Safe("SkinItem", SkinItem, G("MerchantItem" .. i)) end
    Safe("SkinItem", SkinItem, G("MerchantBuyBackItem"))
    Safe("SkinPage", SkinPageButton, G("MerchantPrevPageButton"), true)
    Safe("SkinPage", SkinPageButton, G("MerchantNextPageButton"), false)
    for _, n in ipairs({ "MerchantRepairAllButton", "MerchantRepairItemButton",
        "MerchantGuildBankRepairButton", "MerchantSellAllJunkButton" }) do
        Safe("SkinIconButton", SkinIconButton, G(n))
    end
    Safe("SkinClose", SkinCloseButton, frame)
    -- Money text recolor doesn't survive a font object change, so it is re-applied in Refresh.
    local money = G("MerchantMoneyFrame")
    if money then
        for _, key in ipairs({ "GoldButton", "SilverButton", "CopperButton" }) do
            local fs = ButtonText(Child(money, key))
            if fs then pcall(fs.SetShadowOffset, fs, 0, 0) end
        end
    end
end

local function TrySkin()
    if skinned then return true end
    local frame = G("MerchantFrame")
    if not frame then return false end
    local okP, prot = pcall(frame.IsProtected, frame)
    if okP and prot and InCombatLockdown and InCombatLockdown() then
        pendingCombat = true
        if events then events:RegisterEvent("PLAYER_REGEN_ENABLED") end
        return false
    end
    skinned = true -- even if a piece fails, never run twice (logged once)
    Safe("Skin", Skin)
    return true
end

local function Refresh(newMode)
    if newMode then mode = newMode end
    if not enabled or not TrySkin() then return end
    SetTabSelected(mode == "buyback" and 2 or 1)
    UpdateHeader()
    for i = 1, NUM_ITEMS do RefreshItem(G("MerchantItem" .. i)) end
    RefreshItem(G("MerchantBuyBackItem"))
    if ui.divider then ui.divider:SetShown(mode ~= "buyback") end
    RecolorMoneyFrame(G("MerchantMoneyFrame"))
    SkinTokens()
    local pageText = G("MerchantPageText")
    if pageText then pageText:SetTextColor(LABEL[1], LABEL[2], LABEL[3]) end
end

---------------------------------------------------------------------------
-- Hooks / events
---------------------------------------------------------------------------

local function SafeRefresh(newMode)
    Safe("Refresh", Refresh, newMode)
end

local function HookGlobal(name, fn)
    if hooked[name] or type(_G[name]) ~= "function" or not hooksecurefunc then return end
    hooked[name] = true
    hooksecurefunc(name, fn)
end

local function InstallHooks()
    HookGlobal("MerchantFrame_UpdateMerchantInfo", function() SafeRefresh("merchant") end)
    HookGlobal("MerchantFrame_UpdateBuybackInfo", function() SafeRefresh("buyback") end)
    HookGlobal("MerchantFrame_UpdateCurrencies", function() if enabled and skinned then Safe("Tokens", SkinTokens) end end)
    HookGlobal("MerchantFrame_UpdateCurrencyAmounts", function() if enabled and skinned then Safe("Tokens", SkinTokens) end end)
    -- Fired again when item info arrives later (GET_ITEM_INFO_RECEIVED): recolor that cell.
    HookGlobal("MerchantFrameItem_UpdateQuality", function(item)
        if enabled and skinned and item and cards[item] then Safe("UpdateQuality", RefreshItem, item) end
    end)
    -- Blizzard's tab helpers restyle the tab text after our refresh: hide it again.
    local function RehideTabs() if enabled and skinned then for tab in pairs(tabParts) do HideBlizzardTabText(tab) end end end
    for _, fname in ipairs({ "PanelTemplates_SelectTab", "PanelTemplates_DeselectTab", "PanelTemplates_UpdateTabs",
        "PanelTemplates_SetTab" }) do
        HookGlobal(fname, RehideTabs)
    end
    local frame = G("MerchantFrame")
    if frame and not hooked.OnShow then
        hooked.OnShow = true
        frame:HookScript("OnShow", function() SafeRefresh() end)
    end
end

local function OnEvent(_, event, arg1)
    if event == "PLAYER_REGEN_ENABLED" then
        events:UnregisterEvent("PLAYER_REGEN_ENABLED")
        if pendingCombat then
            pendingCombat = false
            local frame = G("MerchantFrame")
            if enabled and frame and frame:IsShown() then SafeRefresh() end
        end
        return
    end
    if not enabled then return end
    if event == "ADDON_LOADED" then
        if type(arg1) == "string" and not IsSecret(arg1) and arg1:find("Merchant", 1, true) then InstallHooks() end
    elseif event == "MERCHANT_SHOW" then
        InstallHooks()
        -- After Blizzard's own MERCHANT_SHOW handling has drawn the page.
        if C_Timer and C_Timer.After then C_Timer.After(0, function() SafeRefresh() end) else SafeRefresh() end
    elseif event == "PLAYER_MONEY" then
        local frame = G("MerchantFrame")
        if skinned and frame and frame:IsShown() then
            Safe("Money", RecolorMoneyFrame, G("MerchantMoneyFrame"))
        end
    end
end

local function Activate()
    if not events then
        events = CreateFrame("Frame")
        events:SetScript("OnEvent", function(...) Safe("OnEvent", OnEvent, ...) end)
    end
    events:RegisterEvent("ADDON_LOADED")
    events:RegisterEvent("MERCHANT_SHOW")
    events:RegisterEvent("PLAYER_MONEY")
    InstallHooks()
    -- Re-show our parts and re-hide Blizzard art if this is a re-enable in the same session.
    if skinned then
        for region in pairs(hidden) do pcall(region.SetAlpha, region, 0) end
        for region in pairs(own) do pcall(region.Show, region) end
    end
    local frame = G("MerchantFrame")
    if frame and frame:IsShown() then SafeRefresh() end
end

local function Deactivate()
    if events then
        events:UnregisterEvent("MERCHANT_SHOW")
        events:UnregisterEvent("PLAYER_MONEY")
        events:UnregisterEvent("ADDON_LOADED")
    end
    -- Best effort: bring Blizzard's art back and hide ours (button textures, tab anchors and
    -- fonts stay changed until /reload).
    for region, a in pairs(hidden) do pcall(region.SetAlpha, region, a) end
    for region in pairs(own) do
        local ok, kind = pcall(region.GetObjectType, region)
        if ok and kind ~= "MaskTexture" then pcall(region.Hide, region) end
    end
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

function ns.InitMerchant()
    mdb = InitDefaults()
    if not mdb then
        LogOnce("InitMerchant", "saved variables not ready")
        return
    end
    enabled = mdb.enabled == true
    if enabled then Activate() end
end

function ns.IsMerchantEnabled()
    mdb = mdb or InitDefaults()
    return mdb ~= nil and mdb.enabled == true
end

function ns.MerchantSetEnabled(on)
    mdb = mdb or InitDefaults()
    if not mdb then return end
    on = on and true or false
    mdb.enabled = on
    local was = enabled
    enabled = on
    if on then
        if not was then Activate() end
        Print("SAO vendor window enabled.")
    else
        if was then Deactivate() end
        Print("SAO vendor window disabled. Type /reload to fully restore Blizzard's look.")
    end
end
