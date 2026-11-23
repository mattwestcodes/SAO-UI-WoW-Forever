-- SAO Frames: Sword Art Online-styled skin for Blizzard's player trade window (SAOTrade.lua).
--
-- This is a SKIN, not a replacement: Blizzard's TradeFrame, its item slot buttons (click, drag
-- and drop, the "Will not be traded" enchant slot), the money input and the Trade / Cancel
-- buttons keep all of their own scripts. We only hide Blizzard's art (SetAlpha 0), restyle its
-- text, re-anchor its two buttons and the two name texts, and add our own regions: a white SAO
-- panel, column boxes, round icon rings and round button discs.
--
-- TradeFrame lives in Blizzard_UIPanels_Game (always loaded, not load-on-demand in 12.x); if it
-- is missing at login we retry on ADDON_LOADED and TRADE_SHOW.
--
-- Accepted state: hooksecurefunc("TradeFrame_SetAcceptState") + OnShow/OnHide hooks on
-- TradeHighlightPlayer / TradeHighlightRecipient (+ TRADE_ACCEPT_UPDATE as a fallback) show an
-- orange (you) / cyan (target) glow around that column.
--
-- Secret values: player/target names are only ever passed to SetText by Blizzard (we never read
-- them). Item qualities/textures from GetTrade*ItemInfo go through Plain() before any logic.
-- Original alpha/points/size/fonts of every Blizzard region we touch are saved in a weak-keyed
-- table and restored on disable (a /reload restores everything else).
--
-- Public (on ns): InitTrade, TradeSetEnabled, IsTradeEnabled, TradeTest.

local ADDON, ns = ...

---------------------------------------------------------------------------
-- Constants
---------------------------------------------------------------------------

local WHITE = "Interface\\Buttons\\WHITE8X8"
local EXT = 28                  -- the SAO panel extends this far below TradeFrame (round buttons)
local BTN = 30                  -- round button disc size
local PANEL_U = 376.16 / 512    -- TradePanel.tga: used width (see make_trade_textures.py)
local NUM_SLOTS = 7             -- 6 trade slots + the enchant ("Will not be traded") slot
local TRADE_DEFAULTS = { enabled = true }

local SIDES = {
    { key = "player", prefix = "TradePlayerItem",    info = "GetTradePlayerItemInfo" },
    { key = "target", prefix = "TradeRecipientItem", info = "GetTradeTargetItemInfo" },
}

local GLOW = { player = { 1.00, 0.55, 0.12 }, target = { 0.30, 0.85, 1.00 } }  -- orange / cyan

-- Fallback rectangles (TradeFrame TOPLEFT coords from TradeFrame.xml) if an inset is missing.
local BOXES = {
    { key = "pMoney", inset = "TradePlayerInputMoneyInset", rect = { 4, -58, 166, -82 },   money = true },
    { key = "tMoney", inset = "TradeRecipientMoneyInset",   rect = { 175, -58, 338, -81 }, money = true },
    { key = "pItems", inset = "TradePlayerItemsInset",      rect = { 4, -83, 166, -352 } },
    { key = "tItems", inset = "TradeRecipientItemsInset",   rect = { 175, -83, 338, -352 } },
    { key = "pEnch",  inset = "TradePlayerEnchantInset",    rect = { 4, -354, 166, -418 } },
    { key = "tEnch",  inset = "TradeRecipientEnchantInset", rect = { 175, -354, 338, -418 } },
}

-- Blizzard frames whose art is hidden as a whole (no functional children). Nil-safe.
local HIDE_FRAMES = {
    "TradePlayerItemsInset", "TradePlayerEnchantInset", "TradePlayerInputMoneyInset",
    "TradeRecipientItemsInset", "TradeRecipientEnchantInset", "TradeRecipientMoneyInset",
    "TradeRecipientMoneyBg",
}
local HIDE_KEYS = { "NineSlice", "PortraitContainer", "TitleContainer", "Inset", "RecipientOverlay",
                    "TopTileStreaks", "Bg", "Background" }
local HIGHLIGHTS = { "TradeHighlightPlayer", "TradeHighlightRecipient",
                     "TradeHighlightPlayerEnchant", "TradeHighlightRecipientEnchant" }

-- /sao trade test preview items (shown on our standalone mock window only).
local SAMPLES = {
    player = {
        { icon = "Interface\\Icons\\INV_Sword_04", name = "Elucidator", quality = 4 },
        { icon = "Interface\\Icons\\INV_Potion_51", name = "Healing Crystal", quality = 1, count = 5 },
        { icon = "Interface\\Icons\\INV_Misc_Gem_Sapphire_02", name = "Blue Sapphire", quality = 2 },
    },
    target = {
        { icon = "Interface\\Icons\\INV_Chest_Cloth_17", name = "Coat of Midnight", quality = 3 },
        { icon = "Interface\\Icons\\INV_Misc_Food_15", name = "Ragout Rabbit Stew", quality = 1, count = 2 },
    },
}

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------

local tdb                -- db.trade
local events             -- our event frame
local built = false      -- our panel exists
local hooksDone = false
local applied = false    -- Blizzard art currently hidden / restyled
local pending = false    -- apply/revert waiting for combat to end
local mock                -- /sao trade test preview: our own frame, never Blizzard's TradeFrame
local failed = false     -- Apply errored: don't retry until the user re-enables
local logged = {}
local ui = {}            -- our own regions on the panel

local saved = setmetatable({}, { __mode = "k" })   -- Blizzard region -> original state
local slotUI = setmetatable({}, { __mode = "k" })  -- Blizzard item button -> our ring regions
local btnUI = setmetatable({}, { __mode = "k" })   -- Blizzard button -> our disc regions
local hookedScript = setmetatable({}, { __mode = "k" })

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
    if ns.LogError then pcall(ns.LogError, "SAOTrade " .. tag .. ": " .. tostring(err)) end
end

local function LogOnce(tag, err)
    if logged[tag] then return end
    logged[tag] = true
    LogError(tag, err)
end

local function Media(name)
    return (ns.MEDIA or ("Interface\\AddOns\\" .. ADDON .. "\\Media\\")) .. name
end

-- Forbidden objects (e.g. TradePlayerInputMoneyFrame:SetForbidden() in TradeFrame_OnLoad and its
-- children) error on any access from addon code; treat them as missing.
local function Forbidden(v)
    local ok, f = pcall(function() return v.IsForbidden and v:IsForbidden() end)
    return (not ok) or (f and true) or false
end

local function G(name)
    local v = _G[name]
    if type(v) == "table" and not Forbidden(v) then return v end
    return nil
end

local function Call(tag, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then LogOnce(tag, err) end
    return ok
end

local function GetDB()
    if ns.GetDB then return ns.GetDB() end
    return SAOFramesDB
end

local function InitDefaults()
    local db = GetDB()
    if type(db) ~= "table" then return nil end
    if type(db.trade) ~= "table" then db.trade = {} end
    local t = db.trade
    if type(t.enabled) ~= "boolean" then t.enabled = TRADE_DEFAULTS.enabled end
    return t
end

local function InCombat()
    return InCombatLockdown ~= nil and InCombatLockdown() and true or false
end

-- TradeFrame is not a protected frame in the live UI; only wait for combat if it is.
local function Blocked()
    if not InCombat() or not TradeFrame then return false end
    local ok, prot = pcall(TradeFrame.IsProtected, TradeFrame)
    return ok and prot and true or false
end

local function SetFontPath(fs, size)
    local path = ns.fontPath or STANDARD_TEXT_FONT
    if not (pcall(fs.SetFont, fs, path, size, "") and fs:GetFont()) then
        pcall(fs.SetFont, fs, STANDARD_TEXT_FONT, size, "")
    end
end

-- Flat dark text for the light panel (no outline, no shadow).
local function Font(fs, size, r, g, b)
    SetFontPath(fs, size)
    pcall(fs.SetShadowOffset, fs, 0, 0)
    pcall(fs.SetTextColor, fs, r or 0.42, g or 0.45, b or 0.50)
end

local function NewText(parent, size, r, g, b)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    Font(fs, size, r, g, b)
    return fs
end

-- Item quality -> text/ring color that reads on the light panel (common becomes dark gray).
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
    return r * 0.85, g * 0.85, b * 0.85
end

-- 9-slice our own textures when the client supports it (corners stay round at any size).
-- Returns true when slicing is active.
local function Slice(tex, m)
    if not tex.SetTextureSliceMargins then return false end
    if not pcall(tex.SetTextureSliceMargins, tex, m, m, m, m) then return false end
    if tex.SetTextureSliceMode and Enum and Enum.UITextureSliceMode and Enum.UITextureSliceMode.Stretched ~= nil then
        pcall(tex.SetTextureSliceMode, tex, Enum.UITextureSliceMode.Stretched)
    end
    return true
end

---------------------------------------------------------------------------
-- Save / restore Blizzard region state (weak-keyed; nothing written onto Blizzard frames)
---------------------------------------------------------------------------

local function State(r)
    local s = saved[r]
    if not s then
        s = {}
        saved[r] = s
    end
    return s
end

local function HideArt(r)
    if type(r) ~= "table" or Forbidden(r) or not r.SetAlpha then return end
    local s = State(r)
    if s.alpha == nil then
        local ok, a = pcall(r.GetAlpha, r)
        s.alpha = ok and type(a) == "number" and a or 1
    end
    pcall(r.SetAlpha, r, 0)
end

local function SaveGeometry(r)
    local s = State(r)
    if s.points then return end
    local pts = {}
    local ok, n = pcall(r.GetNumPoints, r)
    for i = 1, (ok and type(n) == "number") and n or 0 do
        local p = { pcall(r.GetPoint, r, i) }
        if p[1] then
            table.remove(p, 1)
            pts[#pts + 1] = p
        end
    end
    s.points = pts
    local okw, w, h = pcall(r.GetSize, r)
    if okw then s.w, s.h = w, h end
end

local function Place(r, ...)
    SaveGeometry(r)
    pcall(r.ClearAllPoints, r)
    return pcall(r.SetPoint, r, ...)
end

local function SaveFont(fs)
    local s = State(fs)
    if s.fontSaved then return end
    s.fontSaved = true
    if fs.GetFontObject then
        local ok, fo = pcall(fs.GetFontObject, fs)
        if ok then s.fontObj = fo end
    end
    local ok, path, size, flags = pcall(fs.GetFont, fs)
    if ok then s.font = { path, size, flags } end
    local okc, r, g, b, a = pcall(fs.GetTextColor, fs)
    if okc then s.color = { r, g, b, a } end
    local oks, x, y = pcall(fs.GetShadowOffset, fs)
    if oks then s.shadow = { x, y } end
    if fs.GetJustifyH then
        local okj, j = pcall(fs.GetJustifyH, fs)
        if okj then s.justify = j end
    end
end

local function Restyle(fs, size, r, g, b)
    if type(fs) ~= "table" or not fs.SetFont then return end
    SaveFont(fs)
    Font(fs, size, r, g, b)
end

local function RestoreOne(r, s)
    if s.points then
        pcall(r.ClearAllPoints, r)
        for _, p in ipairs(s.points) do pcall(r.SetPoint, r, unpack(p)) end
    end
    if s.w and s.h then pcall(r.SetSize, r, s.w, s.h) end
    if s.fontObj then pcall(r.SetFontObject, r, s.fontObj)
    elseif s.font and s.font[1] then pcall(r.SetFont, r, s.font[1], s.font[2], s.font[3]) end
    if s.color and s.color[1] then pcall(r.SetTextColor, r, s.color[1], s.color[2], s.color[3], s.color[4]) end
    if s.shadow and s.shadow[1] then pcall(r.SetShadowOffset, r, s.shadow[1], s.shadow[2]) end
    if s.justify then pcall(r.SetJustifyH, r, s.justify) end
    if s.btnFonts then
        pcall(r.SetNormalFontObject, r, s.btnFonts[1])
        if s.btnFonts[2] then pcall(r.SetHighlightFontObject, r, s.btnFonts[2]) end
        if s.btnFonts[3] then pcall(r.SetDisabledFontObject, r, s.btnFonts[3]) end
    end
    if s.text ~= nil then pcall(r.SetText, r, s.text) end
    if s.texCoord then pcall(r.SetTexCoord, r, unpack(s.texCoord)) end
    if s.alpha then pcall(r.SetAlpha, r, s.alpha) end
end

local function RestoreAll()
    for r, s in pairs(saved) do
        local ok, err = pcall(RestoreOne, r, s)
        if not ok then LogOnce("Restore", err) end
    end
    wipe(saved)
end

-- Hide every texture region directly on a frame (fontstrings are kept).
-- except: optional set { [region] = true } of regions to leave alone.
local function HideTextures(f, except)
    if type(f) ~= "table" or Forbidden(f) or not f.GetRegions then return end
    local regions = { pcall(f.GetRegions, f) }
    if not regions[1] then return end
    for i = 2, #regions do
        local r = regions[i]
        local okT, isTex = pcall(function() return r:IsObjectType("Texture") end)
        if okT and isTex and not (except and except[r]) then
            HideArt(r)
        end
    end
end

---------------------------------------------------------------------------
-- Our panel
---------------------------------------------------------------------------

-- host: TradeFrame (real skin, boxes follow Blizzard's insets) or our preview frame (rects only).
local function Anchor(tex, host, insetName, rect, padX, padY)
    local inset = host == TradeFrame and G(insetName)
    tex:ClearAllPoints()
    if inset and inset.GetNumPoints and inset:GetNumPoints() > 0 then
        tex:SetPoint("TOPLEFT", inset, "TOPLEFT", padX, -padY)
        tex:SetPoint("BOTTOMRIGHT", inset, "BOTTOMRIGHT", -padX, padY)
    else
        tex:SetPoint("TOPLEFT", host, "TOPLEFT", rect[1] + padX, rect[2] - padY)
        tex:SetPoint("BOTTOMRIGHT", host, "TOPLEFT", rect[3] - padX, rect[4] + padY)
    end
end

-- Builds the SAO chrome (panel, header, boxes, glows) on tf into the given ui table.
local function BuildChrome(tf, ui)
    local skin = CreateFrame("Frame", nil, tf)
    skin:SetPoint("TOPLEFT")
    skin:SetPoint("BOTTOMRIGHT")
    pcall(skin.SetFrameLevel, skin, tf:GetFrameLevel()) -- under every Blizzard child of TradeFrame
    ui.skin = skin

    local bg = skin:CreateTexture(nil, "BACKGROUND", nil, -8)
    bg:SetTexture(Media("TradePanel"))
    bg:SetTexCoord(0, PANEL_U, 0, 1)
    bg:SetVertexColor(0.76, 0.80, 0.86) -- softened white
    bg:SetPoint("TOPLEFT", tf, "TOPLEFT", -8, 8)
    bg:SetPoint("BOTTOMRIGHT", tf, "BOTTOMRIGHT", 8, -(EXT + 8))

    -- The panel's lower extension (behind the round buttons) eats clicks like the window does.
    local ext = CreateFrame("Frame", nil, skin)
    ext:SetPoint("TOPLEFT", tf, "BOTTOMLEFT", 0, 0)
    ext:SetPoint("BOTTOMRIGHT", tf, "BOTTOMRIGHT", 0, -EXT)
    ext:EnableMouse(true)
    pcall(ext.SetFrameLevel, ext, skin:GetFrameLevel()) -- below the Trade / Cancel buttons

    -- Header strip: title, thin cyan accent line.
    ui.title = NewText(skin, 9)
    ui.title:SetPoint("TOPLEFT", tf, "TOPLEFT", 12, -7)
    ui.title:SetText(string.upper(type(TRADE) == "string" and TRADE or "Trade"))
    local line = skin:CreateTexture(nil, "BORDER")
    line:SetTexture(WHITE)
    line:SetVertexColor(0.30, 0.85, 1.00, 0.75)
    line:SetPoint("TOPLEFT", tf, "TOPLEFT", 8, -22)
    line:SetPoint("TOPRIGHT", tf, "TOPRIGHT", -8, -22)
    line:SetHeight(1)

    -- Column divider.
    local div = skin:CreateTexture(nil, "BORDER")
    div:SetTexture(WHITE)
    div:SetVertexColor(0.84, 0.86, 0.89, 0.9)
    div:SetPoint("TOPLEFT", tf, "TOPLEFT", 170, -28)
    div:SetPoint("BOTTOMLEFT", tf, "TOPLEFT", 170, -418)
    div:SetWidth(1)

    -- Column headers (small uppercase gray) and the "accepted" tags.
    ui.you = NewText(skin, 8)
    ui.you:SetPoint("TOPLEFT", tf, "TOPLEFT", 12, -29)
    ui.you:SetText("YOU")
    ui.target = NewText(skin, 8)
    ui.target:SetPoint("TOPLEFT", tf, "TOPLEFT", 183, -29)
    ui.target:SetText("TARGET")
    ui.accP = NewText(skin, 8, GLOW.player[1] * 0.9, GLOW.player[2] * 0.9, GLOW.player[3] * 0.9)
    ui.accP:SetPoint("TOPRIGHT", tf, "TOPLEFT", 164, -29)
    ui.accT = NewText(skin, 8, 0.15, 0.62, 0.85)
    ui.accT:SetPoint("TOPRIGHT", tf, "TOPRIGHT", -8, -29)
    ui.accP:SetText("ACCEPTED")
    ui.accT:SetText("ACCEPTED")
    ui.accP:Hide()
    ui.accT:Hide()

    -- Column boxes and money input bars, anchored to Blizzard's (hidden) insets.
    ui.boxes = {}
    for _, spec in ipairs(BOXES) do
        local t = skin:CreateTexture(nil, "BORDER", nil, 1)
        t:SetTexture(Media("TradeBox"))
        Slice(t, 8)
        Anchor(t, tf, spec.inset, spec.rect, 2, 1)
        t:SetVertexColor(0.86, 0.88, 0.92)
        if spec.money then t:SetVertexColor(0.90, 0.92, 0.95) end
        ui.boxes[spec.key] = t
    end
    -- Thin divider lines between the six item rows of each column.
    for _, side in ipairs(SIDES) do
        for i = 2, 6 do
            local item = G(side.prefix .. i)
            if item then
                local line = skin:CreateTexture(nil, "BORDER", nil, 3)
                line:SetTexture(WHITE)
                line:SetVertexColor(0.55, 0.60, 0.68, 0.55)
                line:SetHeight(1)
                line:SetWidth(150)
                line:SetPoint("LEFT", item, "TOPLEFT", 0, 3)
            end
        end
    end
    -- Cyan underline on the editable money bar.
    local ul = skin:CreateTexture(nil, "BORDER", nil, 2)
    ul:SetTexture(WHITE)
    ul:SetVertexColor(0.30, 0.85, 1.00, 0.8)
    ul:SetPoint("BOTTOMLEFT", ui.boxes.pMoney, "BOTTOMLEFT", 5, 1)
    ul:SetPoint("BOTTOMRIGHT", ui.boxes.pMoney, "BOTTOMRIGHT", -5, 1)
    ul:SetHeight(1)

    -- Accepted glows: around money bar + item box + enchant box of that column.
    ui.glow = {}
    for side, boxes in pairs({ player = { "pMoney", "pEnch" }, target = { "tMoney", "tEnch" } }) do
        local g = skin:CreateTexture(nil, "ARTWORK")
        g:SetTexture(Media("TradeGlow"))
        local pad = 22
        if Slice(g, 32) then
            g:SetVertexColor(GLOW[side][1], GLOW[side][2], GLOW[side][3], 0.95)
        else
            -- No 9-slice on this client: a stretched glow ring would land inside the column,
            -- so use a light colored wash over the column instead.
            g:SetTexture(WHITE)
            g:SetVertexColor(GLOW[side][1], GLOW[side][2], GLOW[side][3], 0.14)
            pad = -1
        end
        g:SetPoint("TOPLEFT", ui.boxes[boxes[1]], "TOPLEFT", -pad, pad)
        g:SetPoint("BOTTOMRIGHT", ui.boxes[boxes[2]], "BOTTOMRIGHT", pad, -pad)
        g:Hide()
        ui.glow[side] = g
    end
end

local function BuildPanel()
    if built then return end
    BuildChrome(TradeFrame, ui)
    built = true
end

---------------------------------------------------------------------------
-- Item slots: round ring frames over Blizzard's item buttons
---------------------------------------------------------------------------

local function IconOf(btn)
    local icon = btn.icon or btn.Icon
    if not icon then
        local ok, n = pcall(btn.GetName, btn)
        if ok and type(n) == "string" then icon = G(n .. "IconTexture") end
    end
    return icon
end

local function SlotParts(btn)
    local s = slotUI[btn]
    if s then return s end
    local ok, w = pcall(btn.GetWidth, btn)
    local size = (ok and type(w) == "number" and w > 10) and w or 37
    s = {}
    s.fill = btn:CreateTexture(nil, "BACKGROUND", nil, 1)
    s.fill:SetTexture(Media("LootIconMask"))
    s.fill:SetVertexColor(0.90, 0.92, 0.94)
    s.fill:SetSize(size, size)
    s.fill:SetPoint("CENTER")
    s.outer = btn:CreateTexture(nil, "BACKGROUND", nil, 0)
    s.outer:SetTexture(Media("LootRing"))
    s.outer:SetVertexColor(0.80, 0.82, 0.86)
    s.outer:SetSize(size + 9, size + 9)
    s.outer:SetPoint("CENTER")
    s.ring = btn:CreateTexture(nil, "ARTWORK", nil, 1)
    s.ring:SetTexture(Media("LootRing"))
    s.ring:SetSize(size + 6, size + 6)
    s.ring:SetPoint("CENTER")
    s.hi = btn:CreateTexture(nil, "HIGHLIGHT")
    s.hi:SetTexture(Media("LootButtonHi"))
    s.hi:SetVertexColor(1.00, 0.55, 0.12)
    s.hi:SetSize(size + 13, size + 13)
    s.hi:SetPoint("CENTER")
    s.icon = IconOf(btn)
    if s.icon and s.icon.AddMaskTexture and btn.CreateMaskTexture then
        local okm, m = pcall(btn.CreateMaskTexture, btn)
        if okm and m then
            pcall(m.SetTexture, m, Media("LootIconMask"), "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
            m:SetAllPoints(s.icon)
            s.mask = m
        end
    end
    slotUI[btn] = s
    return s
end

local function ShowSlotParts(s, shown)
    for _, k in ipairs({ "fill", "outer", "ring", "hi" }) do s[k]:SetShown(shown) end
    if s.icon and s.mask then
        if shown and not s.masked then
            s.masked = Call("AddMaskTexture", s.icon.AddMaskTexture, s.icon, s.mask)
        elseif not shown and s.masked then
            s.masked = false
            Call("RemoveMaskTexture", s.icon.RemoveMaskTexture, s.icon, s.mask)
        end
    end
end

local function SkinSlot(side, id)
    local item = G(side.prefix .. id)
    local btn = G(side.prefix .. id .. "ItemButton")
    if item then HideTextures(item) end -- SlotTexture, NameFrame, the enchant slot's icon art
    Restyle(G(side.prefix .. id .. "Name"), 10, 0.20, 0.22, 0.26)
    if not btn then return end
    local getters = { "GetNormalTexture", "GetPushedTexture", "GetHighlightTexture" }
    for _, gname in ipairs(getters) do
        if btn[gname] then
            local ok, t = pcall(btn[gname], btn)
            if ok then HideArt(t) end
        end
    end
    HideArt(btn.IconBorder)
    local s = SlotParts(btn)
    if s.icon and s.icon.GetTexCoord then
        local st = State(s.icon)
        if not st.texCoord then
            local tc = { pcall(s.icon.GetTexCoord, s.icon) }
            if tc[1] then
                table.remove(tc, 1)
                st.texCoord = tc
            end
        end
        pcall(s.icon.SetTexCoord, s.icon, 0.07, 0.93, 0.07, 0.93)
    end
    ShowSlotParts(s, true)
end

-- Ring + name color for one slot, after Blizzard filled it.
local function UpdateSlot(sideKey, id)
    if not applied then return end
    id = Plain(id)
    if type(id) ~= "number" then return end
    local side = sideKey == "player" and SIDES[1] or SIDES[2]
    local btn = G(side.prefix .. id .. "ItemButton")
    local s = btn and slotUI[btn]
    if not s then return end
    local has, quality
    local fn = _G[side.info]
    if type(fn) == "function" then
        local ok, _, texture, _, q = pcall(fn, id)
        if ok then
            has = IsSecret(texture) or texture ~= nil
            quality = q
        end
    end
    if has then
        s.ring:SetVertexColor(QualityRGB(quality))
        s.ring:SetAlpha(1)
        local nameFS = G(side.prefix .. id .. "Name")
        if nameFS then pcall(nameFS.SetTextColor, nameFS, QualityRGB(quality)) end
    else
        s.ring:SetVertexColor(0.72, 0.75, 0.80)
        s.ring:SetAlpha(0.8)
    end
end

local function UpdateAllSlots()
    for _, side in ipairs(SIDES) do
        for id = 1, NUM_SLOTS do UpdateSlot(side.key, id) end
    end
end

---------------------------------------------------------------------------
-- Round buttons (Blizzard's Trade / Cancel / close buttons, re-textured; OnClick untouched)
---------------------------------------------------------------------------

local function ButtonFonts()
    if ui.fontN then return end
    local function Make(name, r, g, b)
        local f = _G[name]
        if type(f) ~= "table" then f = CreateFont(name) end
        local path = ns.fontPath or STANDARD_TEXT_FONT
        if not pcall(f.SetFont, f, path, 8, "") then pcall(f.SetFont, f, STANDARD_TEXT_FONT, 8, "") end
        f:SetShadowOffset(0, 0)
        f:SetTextColor(r, g, b)
        return f
    end
    ui.fontN = Make("SAOFramesTradeButtonFont", 0.36, 0.39, 0.44)
    ui.fontH = Make("SAOFramesTradeButtonFontHi", 0.95, 0.50, 0.10)
    ui.fontD = Make("SAOFramesTradeButtonFontOff", 0.68, 0.70, 0.73)
end

local function RefreshButton(btn)
    local b = btn and btnUI[btn]
    if not b then return end
    local ok, en = pcall(btn.IsEnabled, btn)
    local on = not ok or (en and true or false)
    b.disc:SetDesaturated(not on)
    b.disc:SetAlpha(on and 1 or 0.45)
end

local function DiscDown(btn)
    local b = applied and btnUI[btn]
    if b and btn:IsEnabled() then b.disc:SetSize(b.size - 3, b.size - 3) end
end

local function DiscUp(btn)
    local b = btnUI[btn]
    if b then b.disc:SetSize(b.size, b.size) end
end

local function HookButton(btn)
    if hookedScript[btn] then return end
    hookedScript[btn] = true
    btn:HookScript("OnMouseDown", DiscDown)
    btn:HookScript("OnMouseUp", DiscUp)
    btn:HookScript("OnEnable", RefreshButton)
    btn:HookScript("OnDisable", RefreshButton)
end

local function HideButtonArt(btn, keep)
    for _, k in ipairs({ "Left", "Middle", "Right" }) do HideArt(btn[k]) end
    for _, gname in ipairs({ "GetNormalTexture", "GetPushedTexture", "GetHighlightTexture", "GetDisabledTexture" }) do
        if btn[gname] then
            local ok, t = pcall(btn[gname], btn)
            if ok then HideArt(t) end
        end
    end
    local except = {}
    if keep then except[keep] = true end
    local b = btnUI[btn]
    if b then except[b.disc], except[b.hi] = true, true end
    HideTextures(btn, except)
end

local function DiscParts(btn, tex, size, r, g, b)
    local d = btnUI[btn]
    if d then return d end
    d = { size = size }
    d.disc = btn:CreateTexture(nil, "ARTWORK", nil, 7)
    d.disc:SetTexture(Media(tex))
    d.disc:SetSize(size, size)
    d.hi = btn:CreateTexture(nil, "HIGHLIGHT")
    d.hi:SetTexture(Media("LootButtonHi"))
    d.hi:SetVertexColor(r, g, b)
    d.hi:SetSize(size + 8, size + 8)
    d.hi:SetPoint("CENTER", d.disc, "CENTER")
    btnUI[btn] = d
    return d
end

local function SkinRoundButton(btn, tex, label, r, g, b, xoff)
    if type(btn) ~= "table" or not btn.CreateTexture then return end
    local warn = btn.WarningIcon
    HideButtonArt(btn, warn)
    local d = DiscParts(btn, tex, BTN, r, g, b)
    d.disc:ClearAllPoints()
    d.disc:SetPoint("TOP", btn, "TOP", 0, 0)
    Place(btn, "TOP", TradeFrame, "BOTTOM", xoff, EXT - 6)
    pcall(btn.SetSize, btn, BTN + 34, BTN + 16)
    ButtonFonts()
    local s = State(btn)
    if not s.btnFonts then
        local okn, n = pcall(btn.GetNormalFontObject, btn)
        local okh, h = pcall(btn.GetHighlightFontObject, btn)
        local okd, dis = pcall(btn.GetDisabledFontObject, btn)
        s.btnFonts = { okn and n or nil, okh and h or nil, okd and dis or nil }
        local okt, txt = pcall(btn.GetText, btn)
        if okt and not IsSecret(txt) then s.text = txt end
    end
    pcall(btn.SetNormalFontObject, btn, ui.fontN)
    pcall(btn.SetHighlightFontObject, btn, ui.fontH)
    pcall(btn.SetDisabledFontObject, btn, ui.fontD)
    pcall(btn.SetText, btn, label)
    local ok, fs = pcall(btn.GetFontString, btn)
    fs = ok and fs or btn.Text
    if fs then Place(fs, "TOP", d.disc, "BOTTOM", 0, -3) end
    if warn then Place(warn, "CENTER", d.disc, "TOPRIGHT", -3, -3) end
    d.disc:Show()
    d.hi:Show()
    HookButton(btn)
    RefreshButton(btn)
end

local function SkinCloseButton()
    local cb = TradeFrame.CloseButton or G("TradeFrameCloseButton")
    if type(cb) ~= "table" or not cb.CreateTexture then return end
    HideButtonArt(cb)
    local d = DiscParts(cb, "LootPass", 16, 1.00, 0.35, 0.35)
    d.disc:ClearAllPoints()
    d.disc:SetPoint("CENTER")
    Place(cb, "TOPRIGHT", TradeFrame, "TOPRIGHT", -2, 0)
    pcall(cb.SetSize, cb, 22, 22)
    d.disc:Show()
    d.hi:Show()
    HookButton(cb)
end

---------------------------------------------------------------------------
-- Money, names, enchant texts
---------------------------------------------------------------------------

local COINS = { "Gold", "Silver", "Copper" }

local function RecolorRecipientMoney()
    if not applied then return end
    for _, c in ipairs(COINS) do
        local b = G("TradeRecipientMoneyFrame" .. c .. "Button")
        local fs = (b and type(b.Text) == "table" and b.Text) or G("TradeRecipientMoneyFrame" .. c .. "ButtonText")
        if fs and fs.SetTextColor then
            SaveFont(fs)
            pcall(fs.SetTextColor, fs, 0.20, 0.22, 0.26)
            pcall(fs.SetShadowOffset, fs, 0, 0)
        end
    end
end

local function SkinMoney()
    for _, c in ipairs(COINS) do
        local name = "TradePlayerInputMoneyFrame" .. c
        local eb = G(name)
        if eb then
            HideArt(eb.left)
            HideArt(eb.right)
            HideArt(G(name .. "Left"))
            HideArt(G(name .. "Right"))
            HideArt(G(name .. "Middle"))
            if eb.SetTextColor then
                local s = State(eb)
                if not s.color then
                    local ok, r, g, b, a = pcall(eb.GetTextColor, eb)
                    if ok then s.color = { r, g, b, a } end
                end
                pcall(eb.SetTextColor, eb, 0.20, 0.22, 0.26)
            end
        end
    end
    RecolorRecipientMoney()
end

local function SkinTexts()
    local tf = TradeFrame
    local pn, rn = G("TradeFramePlayerNameText"), G("TradeFrameRecipientNameText")
    if pn then
        Restyle(pn, 11, 0.20, 0.22, 0.26)
        Place(pn, "TOPLEFT", tf, "TOPLEFT", 12, -40)
        pcall(pn.SetWidth, pn, 150)
        pcall(pn.SetJustifyH, pn, "LEFT")
    end
    if rn then
        Restyle(rn, 11, 0.20, 0.22, 0.26)
        Place(rn, "TOPLEFT", tf, "TOPLEFT", 183, -40)
        pcall(rn.SetWidth, rn, 150)
        pcall(rn.SetJustifyH, rn, "LEFT")
    end
    Restyle(G("TradeFramePlayerEnchantText"), 9)
    Restyle(G("TradeFrameRecipientEnchantText"), 9)
end

---------------------------------------------------------------------------
-- Accepted state
---------------------------------------------------------------------------

local function UpdateAccept(pState, tState)
    if not built then return end
    local p, t = false, false
    if applied then
        local hp, hr = G("TradeHighlightPlayer"), G("TradeHighlightRecipient")
        if hp and hr then
            p, t = hp:IsShown() and true or false, hr:IsShown() and true or false
        else
            p, t = Plain(pState) == 1, Plain(tState) == 1
        end
    end
    ui.glow.player:SetShown(p)
    ui.glow.target:SetShown(t)
    ui.accP:SetShown(p)
    ui.accT:SetShown(t)
    -- soft base tint (not pure white); a faint warm / cool shift when that side accepted
    ui.boxes.pItems:SetVertexColor(0.86, p and 0.84 or 0.88, p and 0.80 or 0.92)
    ui.boxes.tItems:SetVertexColor(t and 0.82 or 0.86, t and 0.90 or 0.88, 0.92)
end

local function RefreshAll()
    if not applied then return end
    UpdateAllSlots()
    RecolorRecipientMoney()
    UpdateAccept()
    RefreshButton(G("TradeFrameTradeButton"))
    RefreshButton(G("TradeFrameCancelButton"))
end

---------------------------------------------------------------------------
-- Apply / revert
---------------------------------------------------------------------------

local function HideBlizzardArt()
    local tf = TradeFrame
    HideTextures(tf)
    for _, k in ipairs(HIDE_KEYS) do
        local f = tf[k]
        if type(f) == "table" and f ~= ui.skin then HideArt(f) end
    end
    HideArt(G("TradeFrameBg"))
    for _, n in ipairs(HIDE_FRAMES) do HideArt(G(n)) end
    -- Accept highlights keep being shown/hidden by Blizzard; only their textures go.
    for _, n in ipairs(HIGHLIGHTS) do HideTextures(G(n)) end
end

local function InstallHooks()
    if hooksDone then return end
    hooksDone = true
    if hooksecurefunc then
        if type(TradeFrame_UpdatePlayerItem) == "function" then
            hooksecurefunc("TradeFrame_UpdatePlayerItem", function(id) UpdateSlot("player", id) end)
        end
        if type(TradeFrame_UpdateTargetItem) == "function" then
            hooksecurefunc("TradeFrame_UpdateTargetItem", function(id) UpdateSlot("target", id) end)
        end
        if type(TradeFrame_SetAcceptState) == "function" then
            hooksecurefunc("TradeFrame_SetAcceptState", function(a, b) UpdateAccept(a, b) end)
        end
        if type(MoneyFrame_Update) == "function" then
            hooksecurefunc("MoneyFrame_Update", function(f)
                if not applied then return end
                if type(f) == "string" then f = _G[f] end
                if f ~= nil and f == G("TradeRecipientMoneyFrame") then RecolorRecipientMoney() end
            end)
        end
    end
    for _, n in ipairs({ "TradeHighlightPlayer", "TradeHighlightRecipient" }) do
        local f = G(n)
        if f and f.HookScript then
            f:HookScript("OnShow", function() UpdateAccept() end)
            f:HookScript("OnHide", function() UpdateAccept() end)
        end
    end
    TradeFrame:HookScript("OnShow", function() if applied then RefreshAll() end end)
    TradeFrame:HookScript("OnHide", function() UpdateAccept() end)
end

local function Apply()
    if not TradeFrame then return false end
    if Blocked() then
        pending = true
        return false
    end
    pending = false
    BuildPanel()
    InstallHooks()
    HideBlizzardArt()
    for _, side in ipairs(SIDES) do
        for id = 1, NUM_SLOTS do
            local ok, err = pcall(SkinSlot, side, id)
            if not ok then LogOnce("SkinSlot", err) end
        end
    end
    Call("SkinMoney", SkinMoney)
    Call("SkinTexts", SkinTexts)
    local trade, cancel = G("TradeFrameTradeButton"), G("TradeFrameCancelButton")
    local tradeLabel = string.upper(type(TRADE) == "string" and TRADE or "Trade")
    local cancelLabel = string.upper(type(CANCEL) == "string" and CANCEL or "Cancel")
    Call("TradeButton", SkinRoundButton, trade, "LootNeed", tradeLabel, 0.35, 0.70, 1.00, -42)
    Call("CancelButton", SkinRoundButton, cancel, "LootPass", cancelLabel, 1.00, 0.35, 0.35, 42)
    Call("CloseButton", SkinCloseButton)
    ui.skin:Show()
    applied = true
    RefreshAll()
    return true
end

local function Revert()
    if not applied then return true end
    if Blocked() then
        pending = true
        return false
    end
    pending = false
    applied = false
    for _, s in pairs(slotUI) do ShowSlotParts(s, false) end
    for _, d in pairs(btnUI) do
        d.disc:Hide()
        d.hi:Hide()
    end
    RestoreAll()
    if ui.skin then ui.skin:Hide() end
    UpdateAccept()
    return true
end

local function TryApply()
    if not (tdb and tdb.enabled) or applied or failed then return end
    local ok, res = pcall(Apply)
    if not ok then
        failed = true
        LogError("Apply", res)
        pcall(Revert)
        Print("trade window skin failed; Blizzard's look kept (see /sao errors).")
    end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local function OnEvent(_, event, a1, a2)
    if event == "ADDON_LOADED" then
        if TradeFrame and not applied then TryApply() end
    elseif event == "TRADE_SHOW" then
        if mock then mock:Hide() end
        if not applied then TryApply() end
        if applied and C_Timer and C_Timer.After then C_Timer.After(0, RefreshAll) end
    elseif event == "TRADE_ACCEPT_UPDATE" then
        UpdateAccept(a1, a2)
    elseif event == "TRADE_CLOSED" then
        UpdateAccept()
    elseif event == "PLAYER_REGEN_ENABLED" and pending then
        if tdb and tdb.enabled then TryApply() else pcall(Revert) end
    end
end

local function SafeOnEvent(...)
    local ok, err = pcall(OnEvent, ...)
    if not ok then LogOnce(tostring((select(2, ...))), err) end
end

local function RegisterEvents()
    if events then return end
    events = CreateFrame("Frame")
    events:SetScript("OnEvent", SafeOnEvent)
    for _, e in ipairs({ "ADDON_LOADED", "TRADE_SHOW", "TRADE_ACCEPT_UPDATE", "TRADE_CLOSED", "PLAYER_REGEN_ENABLED" }) do
        pcall(events.RegisterEvent, events, e)
    end
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

function ns.InitTrade()
    tdb = InitDefaults()
    if not tdb then
        LogOnce("InitTrade", "saved variables not ready")
        return
    end
    RegisterEvents()
    TryApply()
end

function ns.IsTradeEnabled()
    tdb = tdb or InitDefaults()
    return tdb ~= nil and tdb.enabled == true
end

function ns.TradeSetEnabled(on)
    tdb = tdb or InitDefaults()
    if not tdb then return end
    tdb.enabled = on and true or false
    RegisterEvents()
    if on then
        failed = false
        TryApply()
        Print("SAO trade window skin enabled.")
    else
        if mock then mock:Hide() end
        local ok, done = pcall(Revert)
        if not ok then LogError("Revert", done) end
        Print("SAO trade window skin disabled" .. ((ok and not done) and " after combat" or "")
            .. ". Type /reload to fully restore Blizzard's trade window.")
    end
end

-- Preview: a standalone, purely visual mock built from the same SAO chrome and textures. It
-- never shows, fills or hides Blizzard's TradeFrame: opening TradeFrame without a trade runs
-- TradeFrame_OnShow / OnHide from addon code (C_TradeInfo.SetTradeMoney, CloseTrade, and
-- writes to TradeFrame.acceptState / TradeFrameTradeButton.enabled), i.e. taint and server
-- calls with no trade. The mock's buttons only close the mock.

local function MockText(parent, size, r, g, b)
    local fs = NewText(parent, size, r, g, b)
    pcall(fs.SetJustifyH, fs, "LEFT")
    return fs
end

local function MockSlot(f, sideKey, i, sample)
    local size = 37
    local b = CreateFrame("Button", nil, f)
    b:SetSize(size, size)
    b:SetPoint("TOPLEFT", f, "TOPLEFT", sideKey == "player" and 14 or 182,
        i < NUM_SLOTS and (-89 - (i - 1) * 44) or -374)
    local fill = b:CreateTexture(nil, "BACKGROUND", nil, 1)
    fill:SetTexture(Media("LootIconMask"))
    fill:SetVertexColor(0.90, 0.92, 0.94)
    fill:SetAllPoints()
    local outer = b:CreateTexture(nil, "BACKGROUND", nil, 0)
    outer:SetTexture(Media("LootRing"))
    outer:SetVertexColor(0.80, 0.82, 0.86)
    outer:SetSize(size + 9, size + 9)
    outer:SetPoint("CENTER")
    local ring = b:CreateTexture(nil, "ARTWORK", nil, 1)
    ring:SetTexture(Media("LootRing"))
    ring:SetSize(size + 6, size + 6)
    ring:SetPoint("CENTER")
    local hi = b:CreateTexture(nil, "HIGHLIGHT")
    hi:SetTexture(Media("LootButtonHi"))
    hi:SetVertexColor(1.00, 0.55, 0.12)
    hi:SetSize(size + 13, size + 13)
    hi:SetPoint("CENTER")
    local name = MockText(b, 10, 0.20, 0.22, 0.26)
    name:SetPoint("LEFT", b, "RIGHT", 8, 0)
    name:SetWidth(100)
    if not sample then
        ring:SetVertexColor(0.72, 0.75, 0.80)
        ring:SetAlpha(0.8)
        if i == NUM_SLOTS then
            Font(name, 9)
            name:SetText("Will not be traded")
        end
        return
    end
    local icon = b:CreateTexture(nil, "ARTWORK", nil, 0)
    icon:SetTexture(sample.icon)
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    icon:SetAllPoints()
    if icon.AddMaskTexture and b.CreateMaskTexture then
        local okm, m = pcall(b.CreateMaskTexture, b)
        if okm and m then
            pcall(m.SetTexture, m, Media("LootIconMask"), "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
            m:SetAllPoints(icon)
            pcall(icon.AddMaskTexture, icon, m)
        end
    end
    ring:SetVertexColor(QualityRGB(sample.quality))
    name:SetTextColor(QualityRGB(sample.quality))
    name:SetText(sample.name)
    if sample.count and sample.count > 1 then
        local c = NewText(b, 10, 1, 1, 1)
        pcall(c.SetShadowOffset, c, 1, -1)
        c:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -4, 4)
        c:SetText(tostring(sample.count))
    end
end

local function MockButton(f, tex, size, label, r, g, b)
    local btn = CreateFrame("Button", nil, f)
    local disc = btn:CreateTexture(nil, "ARTWORK")
    disc:SetTexture(Media(tex))
    disc:SetSize(size, size)
    local hi = btn:CreateTexture(nil, "HIGHLIGHT")
    hi:SetTexture(Media("LootButtonHi"))
    hi:SetVertexColor(r, g, b)
    hi:SetSize(size + 8, size + 8)
    hi:SetPoint("CENTER", disc, "CENTER")
    if label then
        btn:SetSize(BTN + 34, BTN + 16)
        disc:SetPoint("TOP")
        local fs = NewText(btn, 8, 0.36, 0.39, 0.44)
        fs:SetPoint("TOP", disc, "BOTTOM", 0, -3)
        fs:SetText(label)
        btn:SetScript("OnEnter", function() fs:SetTextColor(0.95, 0.50, 0.10) end)
        btn:SetScript("OnLeave", function() fs:SetTextColor(0.36, 0.39, 0.44) end)
    else
        btn:SetSize(22, 22)
        disc:SetPoint("CENTER")
    end
    btn:SetScript("OnMouseDown", function() disc:SetSize(size - 3, size - 3) end)
    btn:SetScript("OnMouseUp", function() disc:SetSize(size, size) end)
    btn:SetScript("OnClick", function() f:Hide() end)
    return btn
end

local function MoneyString(copper, fallback)
    if type(GetCoinTextureString) == "function" then
        local ok, s = pcall(GetCoinTextureString, copper)
        if ok and type(s) == "string" then return s end
    end
    return fallback
end

local function BuildMock()
    local f = CreateFrame("Frame", nil, UIParent)
    f:SetSize(344, 446)
    f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 16, -116)
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    pcall(f.SetHitRectInsets, f, 0, 0, 0, -EXT) -- the panel's round-button strip below
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    local mui = {}
    BuildChrome(f, mui)
    mui.title:SetText(string.upper(type(TRADE) == "string" and TRADE or "Trade") .. "  -  PREVIEW")
    -- The target "accepted", as in a real trade.
    mui.glow.target:Show()
    mui.accT:Show()
    mui.boxes.tItems:SetVertexColor(0.95, 0.99, 1)
    local pn = MockText(f, 11, 0.20, 0.22, 0.26)
    pn:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -40)
    pn:SetWidth(150)
    if UnitName then pcall(pn.SetText, pn, (UnitName("player"))) end -- may be secret: setter only
    local rn = MockText(f, 11, 0.20, 0.22, 0.26)
    rn:SetPoint("TOPLEFT", f, "TOPLEFT", 183, -40)
    rn:SetWidth(150)
    rn:SetText("Asuna")
    local pm = NewText(f, 10, 0.20, 0.22, 0.26)
    pm:SetPoint("RIGHT", mui.boxes.pMoney, "RIGHT", -8, 0)
    pm:SetText(MoneyString(0, "0c"))
    local tm = NewText(f, 10, 0.20, 0.22, 0.26)
    tm:SetPoint("RIGHT", mui.boxes.tMoney, "RIGHT", -8, 0)
    tm:SetText(MoneyString(125000, "12g 50s 0c"))
    for sideKey, list in pairs(SAMPLES) do
        for i = 1, NUM_SLOTS do MockSlot(f, sideKey, i, list[i]) end
    end
    local tradeLabel = string.upper(type(TRADE) == "string" and TRADE or "Trade")
    local cancelLabel = string.upper(type(CANCEL) == "string" and CANCEL or "Cancel")
    MockButton(f, "LootNeed", BTN, tradeLabel, 0.35, 0.70, 1.00):SetPoint("TOP", f, "BOTTOM", -42, EXT - 6)
    MockButton(f, "LootPass", BTN, cancelLabel, 1.00, 0.35, 0.35):SetPoint("TOP", f, "BOTTOM", 42, EXT - 6)
    MockButton(f, "LootPass", 16, nil, 1.00, 0.35, 0.35):SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, 0)
    f:Hide()
    return f
end

local function SafeTradeTest()
    if mock and mock:IsShown() then mock:Hide() return end
    if not ns.IsTradeEnabled() then Print("the SAO trade skin is disabled.") return end
    if TradeFrame and TradeFrame:IsShown() then Print("close the trade window first.") return end
    if not mock then mock = BuildMock() end
    mock:Show()
    Print("trade window preview (visual only; no trade is opened). Click a button to close it.")
end

function ns.TradeTest()
    tdb = tdb or InitDefaults()
    local ok, err = pcall(SafeTradeTest)
    if not ok then
        if mock then pcall(mock.Hide, mock) end
        LogError("TradeTest", err)
        Print("preview not available.")
    end
end
