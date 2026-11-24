-- SAO Frames: SAO-style unit frames for World of Warcraft: Forever (interface 16001).
--
-- Forever uses the modern (Midnight) addon API, where UnitHealth/UnitHealthMax can
-- return "secret" values. Lua may not do math or comparisons on those, but widgets
-- such as StatusBar and FontString accept them directly. Everything below that
-- touches health is written to pass values straight through, with pcall fallbacks.

local ADDON, ns = ... -- ns is shared with SAOMeter.lua
local MEDIA = "Interface\\AddOns\\" .. ADDON .. "\\Media\\"
local FONT = "Fonts\\ARIALN.TTF"

local DEFAULTS = {
    scale = 1,
    raidScale = 0.85,
    targetOnlyMine = true, -- on hostile targets, show only debuffs you applied
    raidPowerAll = false,  -- raid frames: power bar for everyone, or healers only
    background = false,    -- dark panel behind player/target/party frames
    threat = true,         -- threat glow on bar edges
    smooth = false,        -- animate bar changes (off = bars show the exact value instantly)
    nameplates = true,     -- SAO-style nameplates (replaces Blizzard's plate art)
    saoFont = true,        -- use Fonts\SAOUI.ttf (SAO-style font) when the file is present
    grid = true,           -- show alignment grid while unlocked
    snap = true,           -- snap dropped frames to the grid
    gridSize = 32,         -- grid spacing (UI units)
    hideRaidTools = true,  -- hide Blizzard's raid tools tab on the left screen edge
    threatBars = true,     -- enemy health bars take the threat color while you're in combat with them
    targetRed = true,      -- the enemy you have selected always shows a red bar
    eliteBorders = true,   -- gold / silver / red borders for elite, rare and boss enemies
    guildNames = true,     -- <Guild> under player names (frames and nameplates)
    restZ = true,          -- floating Z's on the player frame while resting
    healPredict = true,    -- translucent green incoming-heal extension on health bars
    absorbs = true,        -- pale-blue shield (damage absorb) layer after the heals
    levelColors = true,    -- color enemy levels gray / green / white / orange / red by difficulty
    friendlyPlates = true, -- turn on friendly player nameplates (health bars, not name-only)
    friendlyNPCs = false,  -- also friendly NPC nameplates (busy in cities)
    friendlyClickThrough = true, -- friendly nameplates don't catch mouse clicks
    threatRole = "auto",   -- "auto" (stance/form/spec/role), "TANK" or "DPS"
    locked = true,
    hideBlizzard = true,
    pos = {},
}

-- Single-unit frames. scale multiplies the global scale.
local UNITS = {
    { key = "player", unit = "player", scale = 1.00, point = { "TOPLEFT", "TOPLEFT", 24, -30 } },
    { key = "target", unit = "target", scale = 0.90, point = { "TOP", "TOP", 0, -30 } },
    { key = "targettarget", unit = "targettarget", scale = 0.90, tot = true },
    { key = "focus", unit = "focus", scale = 0.80, point = { "TOP", "TOP", 0, -225 } },
    { key = "party1", unit = "party1", party = 1 },
    { key = "party2", unit = "party2", party = 2 },
    { key = "party3", unit = "party3", party = 3 },
    { key = "party4", unit = "party4", party = 4 },
}
local PARTY_SCALE = 0.72
local PARTY_POINT = { "TOPLEFT", "TOPLEFT", 32, -240 } -- offsets are in the frame's own (0.72) scale
local RAID_POINT  = { "TOPLEFT", "TOPLEFT", 28, -150 }

-- Colors (SAO convention: green > 50%, yellow 20-50%, red < 20%).
local C_GREEN  = { 0.56, 0.86, 0.16 }
local C_YELLOW = { 0.96, 0.80, 0.10 }
local C_RED    = { 0.90, 0.16, 0.16 }
local C_GREY   = { 0.45, 0.45, 0.45 }

-- Layout (unscaled pixels).
local PANEL_W, PANEL_H = 436, 58           -- player / target / party
local BAR_X, BAR_Y, BAR_W, BAR_H = 128, -8, 256, 32 -- BAR_X = room for the name column
local AURA_GAP = 18 -- aura rows start this far under the health bar (clears the power bar and LV line)
local RAID_W, RAID_H, RAID_GAP = 140, 52, 4 -- one raid button
local RAID_BAR_W, RAID_BAR_H = 112, 14

-- Debuff icons: count, icon size, and where the row starts.
local DEBUFFS = {
    big   = { max = 8, size = 24, point = { "TOPLEFT", "BOTTOMLEFT", BAR_X, -3 } },  -- player: under the bar
    target = { max = 7, size = 24, point = { "TOPLEFT", "BOTTOMLEFT", BAR_X, -3 } }, -- target: under the bar
    party = { max = 6, size = 28, point = { "TOPLEFT", "TOPRIGHT", 4, -4 } },    -- party: to the right
    raid  = { max = 4, size = 12, point = { "TOPLEFT", "TOPLEFT", 5, -39 } },    -- raid: inside, under the power bar
}
-- Buff icons (player and target only). Rows stack under the frame; order per unit below.
local BUFFS = { max = 12, size = 22 }
local BUFFS_TARGET = { max = 7, size = 22 }
local BUFF_BORDER = { 0.12, 0.12, 0.14 }

local DEBUFF_COLORS = {
    Magic   = { 0.20, 0.60, 1.00 },
    Curse   = { 0.60, 0.00, 1.00 },
    Disease = { 0.60, 0.40, 0.00 },
    Poison  = { 0.00, 0.60, 0.00 },
    none    = { 0.80, 0.00, 0.00 },
}

-- Power bar colors by power type (falls back to Blizzard's PowerBarColor).
local POWER_COLORS = {
    MANA        = { 0.25, 0.50, 1.00 },
    RAGE        = { 0.90, 0.15, 0.15 },
    ENERGY      = { 1.00, 0.85, 0.20 },
    FOCUS       = { 1.00, 0.50, 0.25 },
    RUNIC_POWER = { 0.00, 0.82, 1.00 },
}

local db
local UpdateHealth -- defined with the update functions below
local frames = {}      -- single-unit frames by key
local raidButtons = {} -- buttons spawned by the raid headers
local raidHeaders = {} -- one secure group header per raid group
local partyContainer, raidAnchor

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function IsSecret(v)
    return issecretvalue ~= nil and issecretvalue(v) or false
end

local function Plain(v)
    if IsSecret(v) then return nil end
    return v
end

local BOLD_FONT = "Fonts\\FRIZQT__.TTF"

local function SetFont(fs, size, bold)
    -- FontString:SetFont returns nothing, so check with GetFont whether it took.
    -- ns.fontPath is the optional SAO-style font (Fonts\SAOUI.ttf), chosen in Init.
    local flags = bold and "THICKOUTLINE" or "OUTLINE"
    fs:SetFont(ns.fontPath or (bold and BOLD_FONT or FONT), size, flags)
    if not fs:GetFont() then fs:SetFont(STANDARD_TEXT_FONT, size, flags) end
    fs:SetShadowOffset(bold and 2 or 1, bold and -2 or -1)
    fs:SetShadowColor(0, 0, 0, bold and 1 or 0.8)
    fs:SetTextColor(1, 1, 1)
end

local function Abbrev(v)
    local fn = AbbreviateNumbers or AbbreviateLargeNumbers
    if fn then
        local ok, r = pcall(fn, v)
        if ok then return r end
    end
    return v
end

local function Print(msg)
    print("|cff7fd1ffSAO Frames|r: " .. msg)
end

---------------------------------------------------------------------------
-- Error log: every Lua error that comes from this addon is recorded (message,
-- count, first stack) in SAOFramesDB.errors, then passed on to the normal error
-- handler unchanged. /sao errors lists them; /sao clearerrors empties the log.
---------------------------------------------------------------------------
local pendingErrors = {}
local MAX_ERRORS = 40

local function ErrorStore()
    if SAOFramesDB then
        SAOFramesDB.errors = SAOFramesDB.errors or {}
        return SAOFramesDB.errors
    end
    return pendingErrors
end

local function LogError(msg, stack)
    msg = tostring(msg)
    local store = ErrorStore()
    local e = store[msg]
    if e then
        e.count = e.count + 1
        e.last = date("%H:%M:%S")
        return
    end
    local n = 0
    for _ in pairs(store) do n = n + 1 end
    if n >= MAX_ERRORS then return end
    store[msg] = { count = 1, first = date("%Y-%m-%d %H:%M:%S"), last = date("%H:%M:%S"),
                   stack = stack and stack:sub(1, 1500) or nil, combat = InCombatLockdown() }
end

do
    local previous = geterrorhandler()
    seterrorhandler(function(msg, ...)
        pcall(function()
            local text = tostring(msg)
            local stack = debugstack and debugstack(3) or ""
            if text:find("SAOFrames", 1, true) or stack:find("SAOFrames", 1, true) then
                LogError(text, stack)
            end
        end)
        return previous(msg, ...)
    end)

    local blocked = CreateFrame("Frame")
    blocked:RegisterEvent("ADDON_ACTION_BLOCKED")
    blocked:RegisterEvent("ADDON_ACTION_FORBIDDEN")
    blocked:SetScript("OnEvent", function(_, event, addon, func)
        if addon == ADDON then
            pcall(LogError, event .. ": " .. tostring(func), debugstack and debugstack(2) or nil)
        end
    end)
end

-- Step color curve so the bar can be colored even when health is secret.
local healthCurve
pcall(function()
    if not (C_CurveUtil and C_CurveUtil.CreateColorCurve and UnitHealthPercent) then return end
    local c = C_CurveUtil.CreateColorCurve()
    if Enum.LuaCurveType and c.SetType then c:SetType(Enum.LuaCurveType.Step) end
    c:AddPoint(0.0, CreateColor(unpack(C_RED)))
    c:AddPoint(0.2, CreateColor(unpack(C_YELLOW)))
    c:AddPoint(0.5, CreateColor(unpack(C_GREEN)))
    healthCurve = c
end)

local INTERP = Enum and Enum.StatusBarInterpolation and Enum.StatusBarInterpolation.ExponentialEaseOut

-- Health percent (0-100). Plain math when allowed, otherwise the client computes it
-- and the (possibly secret) result goes straight into a FontString.
local function HealthPercent(u, cur, max)
    if not IsSecret(cur) and not IsSecret(max) then
        if max and max > 0 then return cur / max * 100 end
        return nil
    end
    if UnitHealthPercent then
        local scale = CurveConstants and CurveConstants.ScaleTo100
        local ok, p = pcall(UnitHealthPercent, u, false, scale)
        if ok and scale then return p end
        if ok and not IsSecret(p) and p then return p * 100 end
    end
    return nil
end

---------------------------------------------------------------------------
-- Shared visuals
---------------------------------------------------------------------------

-- Optional dark panel behind a frame (off by default on big frames: /sao bg).
local function AddPanel(f)
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(1, 1, 1, 1)
    bg:SetGradient("HORIZONTAL", CreateColor(0.07, 0.08, 0.11, 0.85), CreateColor(0.15, 0.17, 0.21, 0.55))

    local edge = f:CreateTexture(nil, "BORDER")
    edge:SetPoint("TOPLEFT"); edge:SetPoint("TOPRIGHT")
    edge:SetHeight(1)
    edge:SetColorTexture(1, 1, 1, 0.22)

    f.panel = { bg, edge }
end

-- The angled SAO bar: a StatusBar whose fill is clipped to the shape by a mask.
-- prefix picks the texture set ("Bar" = slim, "RaidBar" = full).
-- Big frames get a slanted class chip (class icon cut to shape, class-colored outline);
-- raid frames get the small flat badge.
local function AddBar(f, x, y, w, h, prefix, chip, glowMargin)
    local bar = CreateFrame("StatusBar", nil, f)
    bar:SetPoint("TOPLEFT", x, y)
    bar:SetSize(w, h)
    bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(1)

    local shapeBg = bar:CreateTexture(nil, "BACKGROUND")
    shapeBg:SetAllPoints()
    shapeBg:SetTexture(MEDIA .. prefix)
    shapeBg:SetVertexColor(0, 0, 0, 0.6)

    local mask = bar:CreateMaskTexture()
    mask:SetAllPoints()
    mask:SetTexture(MEDIA .. prefix .. "Mask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    bar:GetStatusBarTexture():AddMaskTexture(mask)

    local gloss = bar:CreateTexture(nil, "OVERLAY", nil, 1)
    gloss:SetAllPoints()
    gloss:SetTexture(MEDIA .. prefix .. "Gloss")
    gloss:SetBlendMode("ADD")

    local border = bar:CreateTexture(nil, "OVERLAY", nil, 2)
    border:SetAllPoints()
    border:SetTexture(MEDIA .. prefix .. "Border")
    border:SetVertexColor(0.88, 0.92, 0.96, 0.95)
    f.barBorder = border

    -- Incoming heals: a full-width StatusBar that starts where the health fill ends.
    -- Its value is the (possibly hidden) heal amount on the same 0..max scale, so no
    -- math on secret values is needed; the bar-shaped mask clips anything past full.
    local heal = CreateFrame("StatusBar", nil, bar)
    heal:SetFrameLevel(bar:GetFrameLevel())
    heal:SetPoint("TOPLEFT", bar:GetStatusBarTexture(), "TOPRIGHT")
    heal:SetPoint("BOTTOMLEFT", bar:GetStatusBarTexture(), "BOTTOMRIGHT")
    heal:SetWidth(w)
    heal:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    heal:SetStatusBarColor(0.35, 1, 0.55, 0.45)
    heal:SetMinMaxValues(0, 1)
    heal:SetValue(0)
    local hmask = heal:CreateMaskTexture()
    hmask:SetAllPoints(bar)
    hmask:SetTexture(MEDIA .. prefix .. "Mask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    heal:GetStatusBarTexture():AddMaskTexture(hmask)
    heal:Hide()
    f.healBar = heal

    -- Shields (damage absorbs): the next layer, starting where the heal layer ends.
    local absorb = CreateFrame("StatusBar", nil, bar)
    absorb:SetFrameLevel(bar:GetFrameLevel())
    absorb:SetPoint("TOPLEFT", heal:GetStatusBarTexture(), "TOPRIGHT")
    absorb:SetPoint("BOTTOMLEFT", heal:GetStatusBarTexture(), "BOTTOMRIGHT")
    absorb:SetWidth(w)
    absorb:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    absorb:SetStatusBarColor(0.7, 0.9, 1, 0.55)
    absorb:SetMinMaxValues(0, 1)
    absorb:SetValue(0)
    local amask = absorb:CreateMaskTexture()
    amask:SetAllPoints(bar)
    amask:SetTexture(MEDIA .. prefix .. "Mask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    absorb:GetStatusBarTexture():AddMaskTexture(amask)
    absorb:Hide()
    f.absorbBar = absorb
    f.absorbOnHealth = false -- anchored to the heal layer (see AnchorAbsorb)
    -- Bright edge at the bar's end when the shield is bigger than the missing health.
    local over = absorb:CreateTexture(nil, "OVERLAY")
    over:SetPoint("TOPRIGHT", bar, "TOPRIGHT", 0, 0)
    over:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", 0, 0)
    over:SetWidth(math.max(4, math.floor(h * 0.35)))
    over:SetColorTexture(1, 1, 1, 1)
    over:SetGradient("HORIZONTAL", CreateColor(0.7, 0.9, 1, 0), CreateColor(0.85, 0.95, 1, 0.9))
    over:AddMaskTexture(amask)
    over:SetAlpha(0)
    f.overAbsorb = over

    -- Text inside the bar lives on its own layer above the heal overlay.
    local textLayer = CreateFrame("Frame", nil, bar)
    textLayer:SetAllPoints(bar)
    textLayer:SetFrameLevel(bar:GetFrameLevel() + 3)
    f.barText = textLayer

    -- Elite / rare / boss: a second, colored outline just outside the normal one.
    local edge = bar:CreateTexture(nil, "OVERLAY", nil, 0)
    local em = prefix == "RaidBar" and 1 or 2
    edge:SetPoint("TOPLEFT", bar, "TOPLEFT", -em, em)
    edge:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", em, -em)
    edge:SetTexture(MEDIA .. prefix .. "Border")
    edge:Hide()
    f.eliteEdge = edge

    -- Threat glow around the bar's edge (hidden until there's threat to show).
    local m = glowMargin or (prefix == "RaidBar" and 5 or 8)
    local glow = bar:CreateTexture(nil, "BACKGROUND", nil, -8)
    glow:SetPoint("TOPLEFT", bar, "TOPLEFT", -m, m)
    glow:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", m, -m)
    glow:SetTexture(MEDIA .. prefix .. "Glow")
    glow:SetBlendMode("ADD")
    glow:Hide()
    f.threatGlow = glow

    local badge, badgeBorder
    if chip then
        badge = bar:CreateTexture(nil, "ARTWORK")
        badge:SetSize(chip, chip)
        badge:SetPoint("TOPLEFT", bar, "TOPRIGHT", -3, 0)
        badge:SetTexture(MEDIA .. "Chip")

        local ci = bar:CreateTexture(nil, "OVERLAY", nil, 3)
        ci:SetAllPoints(badge)
        local cmask = bar:CreateMaskTexture()
        cmask:SetAllPoints(badge)
        cmask:SetTexture(MEDIA .. "ChipMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        ci:AddMaskTexture(cmask)
        ci:Hide()
        f.classIcon = ci

        badgeBorder = bar:CreateTexture(nil, "OVERLAY", nil, 4)
        badgeBorder:SetAllPoints(badge)
        badgeBorder:SetTexture(MEDIA .. "ChipBorder")
    else
        local bw, bh = math.floor(h * 1.3 + 0.5), math.floor(h * 0.65 + 0.5)
        badge = bar:CreateTexture(nil, "ARTWORK")
        badge:SetSize(bw, bh)
        badge:SetPoint("TOPLEFT", bar, "TOPRIGHT", 0, 0)
        badge:SetTexture(MEDIA .. "Badge")

        badgeBorder = bar:CreateTexture(nil, "OVERLAY", nil, 2)
        badgeBorder:SetAllPoints(badge)
        badgeBorder:SetTexture(MEDIA .. "BadgeBorder")
    end
    badgeBorder:SetVertexColor(0.88, 0.92, 0.96, 0.95)

    f.bar, f.badge, f.badgeBorder = bar, badge, badgeBorder
end

-- Thin slanted power bar (mana / rage / energy ...) under the health bar's thick section.
local function AddPowerBar(f, x, y, w, h, withText)
    local p = CreateFrame("StatusBar", nil, f)
    p:SetPoint("TOPLEFT", f.bar, "TOPLEFT", x, y)
    p:SetSize(w, h)
    p:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    p:SetMinMaxValues(0, 1)
    p:SetValue(1)

    local bg = p:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture(MEDIA .. "Power")
    bg:SetVertexColor(0, 0, 0, 0.6)

    local mask = p:CreateMaskTexture()
    mask:SetAllPoints()
    mask:SetTexture(MEDIA .. "PowerMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    p:GetStatusBarTexture():AddMaskTexture(mask)

    local border = p:CreateTexture(nil, "OVERLAY")
    border:SetAllPoints()
    border:SetTexture(MEDIA .. "PowerBorder")
    border:SetVertexColor(0.88, 0.92, 0.96, 0.85)

    if withText then
        p.text = p:CreateFontString(nil, "OVERLAY")
        SetFont(p.text, 11)
        p.text:SetPoint("LEFT", p, "RIGHT", 4, 0)
    end

    f.power = p
end

-- Aggro spikes: a pulsing chevron cluster on each side (right one mirrored).
local function AddSpikes(f, w, h, leftPoint, rightPoint, push)
    f.spikes = {}
    for i, side in ipairs({ "LEFT", "RIGHT" }) do
        local sp = f:CreateTexture(nil, "OVERLAY", nil, 5)
        sp:SetSize(w, h)
        sp:SetTexture(MEDIA .. "Spikes")
        sp:SetBlendMode("BLEND")
        if side == "RIGHT" then sp:SetTexCoord(1, 0, 0, 1) end
        sp:SetPoint(unpack(side == "LEFT" and leftPoint or rightPoint))
        local ag = sp:CreateAnimationGroup()
        ag:SetLooping("BOUNCE")
        local a = ag:CreateAnimation("Alpha")
        a:SetFromAlpha(1); a:SetToAlpha(0.55); a:SetDuration(0.4)
        local t = ag:CreateAnimation("Translation")
        t:SetOffset(side == "LEFT" and -push or push, 0); t:SetDuration(0.4)
        sp.anim = ag
        sp:Hide()
        f.spikes[i] = sp
    end
end

local function AddTooltip(f)
    f:HookScript("OnEnter", function(self)
        local u = self.preview and "player" or self.unit
        if u and UnitExists(u) then
            GameTooltip_SetDefaultAnchor(GameTooltip, self)
            GameTooltip:SetUnit(u)
            GameTooltip:Show()
        end
    end)
    f:HookScript("OnLeave", function() GameTooltip:Hide() end)
end

local function AuraOnEnter(self)
    if not self.auraInstanceID then return end
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
    local fn = self.isBuff and GameTooltip.SetUnitBuffByAuraInstanceID or GameTooltip.SetUnitDebuffByAuraInstanceID
    local ok = fn and pcall(fn, GameTooltip, self.unit, self.auraInstanceID, self.filter)
    if not ok then ok = pcall(GameTooltip.SetUnitAura, GameTooltip, self.unit, self.index, self.filter) end
    if ok then GameTooltip:Show() else GameTooltip:Hide() end
end

-- A row of aura icons (border colored by debuff type or dark for buffs, cooldown
-- swipe, stack count). The first icon's position is set by the caller / UpdateAuras.
local function AddAuraRow(f, layout, showNumbers, isBuff)
    local row = {}
    for i = 1, layout.max do
        local icon = CreateFrame("Frame", nil, f)
        icon:SetSize(layout.size, layout.size)
        icon.isBuff = isBuff
        if i > 1 then icon:SetPoint("LEFT", row[i - 1], "RIGHT", showNumbers and 4 or 2, 0) end

        icon.border = icon:CreateTexture(nil, "BACKGROUND")
        icon.border:SetAllPoints()
        icon.border:SetColorTexture(1, 1, 1, 1)
        if isBuff then icon.border:SetVertexColor(BUFF_BORDER[1], BUFF_BORDER[2], BUFF_BORDER[3]) end

        icon.tex = icon:CreateTexture(nil, "ARTWORK")
        icon.tex:SetPoint("TOPLEFT", 1, -1)
        icon.tex:SetPoint("BOTTOMRIGHT", -1, 1)
        icon.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)

        icon.cd = CreateFrame("Cooldown", nil, icon, "CooldownFrameTemplate")
        icon.cd:SetAllPoints(icon.tex)
        icon.cd:SetReverse(true)
        icon.cd:SetDrawEdge(false)
        icon.cd:SetHideCountdownNumbers(not showNumbers)
        if showNumbers and icon.cd.GetCountdownFontString then
            -- The client formats the timer (works even when the duration is secret);
            -- we just make it small and put it under the icon so neighbours don't collide.
            local cdText = icon.cd:GetCountdownFontString()
            if cdText and layout.timerInside then
                SetFont(cdText, 8)
            elseif cdText then
                SetFont(cdText, 9)
                cdText:ClearAllPoints()
                cdText:SetPoint("TOP", icon, "BOTTOM", 0, -1)
            end
        end

        local over = CreateFrame("Frame", nil, icon)
        over:SetAllPoints()
        over:SetFrameLevel(icon.cd:GetFrameLevel() + 2)
        icon.count = over:CreateFontString(nil, "OVERLAY")
        SetFont(icon.count, math.max(8, math.floor(layout.size * 0.45)))
        icon.count:SetPoint("BOTTOMRIGHT", 1, 0)

        -- Hover for a tooltip, but let clicks fall through to the unit frame.
        if icon.SetMouseClickEnabled then
            icon:EnableMouse(true)
            icon:SetMouseClickEnabled(false)
            icon:SetScript("OnEnter", AuraOnEnter)
            icon:SetScript("OnLeave", GameTooltip_Hide)
        end

        icon:Hide()
        row[i] = icon
    end
    return row
end

local function AddDebuffs(f, layout, showNumbers)
    f.debuffs = AddAuraRow(f, layout, showNumbers, false)
    local p = layout.point
    f.debuffs[1]:SetPoint(p[1], f, p[2], p[3], p[4])
end

---------------------------------------------------------------------------
-- Updates
---------------------------------------------------------------------------

local function SetBarColor(f, c)
    f.bar:SetStatusBarColor(c[1], c[2], c[3])
end
local function SetBarColorObj(bar, col) bar:SetStatusBarColor(col:GetRGB()) end
local function SetBarSelectionColor(bar, u) bar:SetStatusBarColor(UnitSelectionColor(u)) end

-- Nameplates: color by how the unit reacts to you, so you can tell at a glance
-- what will pull. Red = hostile (attacks on sight), yellow = neutral, green =
-- friendly, grey = tapped by someone else.
local C_TAPPED = { 0.55, 0.55, 0.55 }

local function ColorByReaction(f, u)
    if Plain(UnitIsTapDenied(u)) then SetBarColor(f, C_TAPPED) return end
    local r = Plain(UnitReaction(u, "player"))
    if r then
        SetBarColor(f, r <= 3 and C_RED or r == 4 and C_YELLOW or C_GREEN)
        return
    end
    -- Hidden reaction: Blizzard's own selection color is the same red/yellow/green.
    if not pcall(SetBarSelectionColor, f.bar, u) then
        SetBarColor(f, Plain(UnitCanAttack("player", u)) and C_RED or C_YELLOW)
    end
end

-- The target frame always shows a red bar on an enemy, whatever its threat
-- (nameplates keep their threat colors). Tapped mobs stay grey.
local function IsTargetEnemy(f, u)
    if f.preview or f.isPlate or db.targetRed == false or f.unit ~= "target" then return false end
    return Plain(UnitCanAttack("player", u or f.unit)) == true
end

local function ColorHealth(f, u, cur, max)
    if f.threatColored then return end
    if IsTargetEnemy(f, u) then
        SetBarColor(f, Plain(UnitIsTapDenied(u)) and C_TAPPED or C_RED)
        return
    end
    if f.isPlate then ColorByReaction(f, u) return end
    if not IsSecret(cur) and not IsSecret(max) and max and max > 0 then
        local pct = cur / max
        SetBarColor(f, pct >= 0.5 and C_GREEN or pct >= 0.2 and C_YELLOW or C_RED)
        return
    end
    if healthCurve then
        local ok, col = pcall(UnitHealthPercent, u, false, healthCurve)
        if ok and col and pcall(SetBarColorObj, f.bar, col) then
            return
        end
    end
    SetBarColor(f, C_GREEN)
end

local CLASS_TEXTURE = "Interface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES"

-- Class icon, cropped inward so the icon's own square frame is cut away and only
-- the emblem shows inside the slanted chip.
local ICON_CROP = 0.14

local function SetCropped(tex, l, r, t, b, crop)
    crop = crop or ICON_CROP
    local dx, dy = (r - l) * crop, (b - t) * crop
    tex:SetTexCoord(l + dx, r - dx, t + dy, b - dy)
end

-- Plain square class icons (no frame), e.g. Interface\Icons\ClassIcon_Hunter.
local CLASS_ICON_FILE = {
    WARRIOR = "Warrior", PALADIN = "Paladin", HUNTER = "Hunter", ROGUE = "Rogue", PRIEST = "Priest",
    SHAMAN = "Shaman", MAGE = "Mage", WARLOCK = "Warlock", DRUID = "Druid", DEATHKNIGHT = "DeathKnight",
    MONK = "Monk", DEMONHUNTER = "DemonHunter", EVOKER = "Evoker",
}

local function SetClassIcon(tex, class)
    local name = CLASS_ICON_FILE[class]
    if name and tex:SetTexture("Interface\\Icons\\ClassIcon_" .. name) ~= false then
        SetCropped(tex, 0, 1, 0, 1, 0.07)
        return true
    end
    local atlas = "classicon-" .. strlower(class)
    local info = C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(atlas)
    local file = info and (info.file or info.filename)
    if file then
        tex:SetTexture(file)
        SetCropped(tex, info.leftTexCoord, info.rightTexCoord, info.topTexCoord, info.bottomTexCoord)
        return true
    end
    local tc = CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[class]
    if not tc then return false end
    tex:SetTexture(CLASS_TEXTURE)
    SetCropped(tex, tc[1], tc[2], tc[3], tc[4])
    return true
end

-- Big frames: class icon in the chip with a class-colored outline (red while you're in
-- combat); NPC targets get a chip filled with reaction color instead.
-- Raid frames: small badge filled with class color.
local classRGB = {}

local function UpdateBadge(f, u)
    local _, class = UnitClass(u)
    class = Plain(class)
    local isPlayer = Plain(UnitIsPlayer(u))
    local cc = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]

    local c = C_YELLOW
    if (f.kind == "enemy" or f.kind == "tot") and not isPlayer then
        local r = Plain(UnitReaction(u, "player"))
        if r then c = r <= 3 and C_RED or r == 4 and C_YELLOW or C_GREEN end
    elseif cc then
        c = classRGB[class]
        if not c then c = { cc.r, cc.g, cc.b }; classRGB[class] = c end
    end

    local hasIcon = false
    if f.classIcon then
        local want = class ~= nil and (isPlayer or f.kind ~= "enemy") and class or nil
        if want ~= f.iconClass then
            f.iconClass = want
            f.iconOk = want and SetClassIcon(f.classIcon, want) or false
        end
        hasIcon = f.iconOk or false
        f.classIcon:SetShown(hasIcon)
    end

    if hasIcon then
        f.badge:SetVertexColor(0.04, 0.05, 0.07, 0.9)
    else
        f.badge:SetVertexColor(c[1], c[2], c[3])
    end

    if f.kind == "player" and Plain(UnitAffectingCombat("player")) then
        f.badgeBorder:SetVertexColor(1, 0.15, 0.15, 1)
    elseif hasIcon then
        f.badgeBorder:SetVertexColor(c[1], c[2], c[3], 1)
    else
        f.badgeBorder:SetVertexColor(0.88, 0.92, 0.96, 0.95)
    end
end

-- Can I attack this unit? A hidden (secret) answer is treated as "yes" for enemy-style
-- frames: nameplate units often hide this, and hostile is the common case there.
local function CanAttack(u)
    local can = UnitCanAttack("player", u)
    if not IsSecret(can) then return can and true or false end
    local friend = UnitIsFriend("player", u)
    if not IsSecret(friend) then return not friend end
    return true
end

local function DebuffFilter(f, u)
    if f.kind == "enemy" and db.targetOnlyMine and CanAttack(u) then
        return "HARMFUL|PLAYER"
    end
    return "HARMFUL"
end

-- Border color by dispel type, resolved by the client (works when the type is secret).
local dispelCurve
pcall(function()
    if not (C_CurveUtil and C_CurveUtil.CreateColorCurve and C_UnitAuras and C_UnitAuras.GetAuraDispelTypeColor) then return end
    local c = C_CurveUtil.CreateColorCurve()
    if Enum.LuaCurveType and c.SetType then c:SetType(Enum.LuaCurveType.Step) end
    for i, k in ipairs({ "none", "Magic", "Curse", "Disease", "Poison" }) do
        c:AddPoint(i - 1, CreateColor(unpack(DEBUFF_COLORS[k])))
    end
    c:AddPoint(5, CreateColor(unpack(DEBUFF_COLORS.none)))
    dispelCurve = c
end)

-- Fill one icon from an aura instance ID. In combat Midnight-style clients keep aura
-- contents secret, but instance IDs stay readable and these per-ID helpers hand the
-- secret values straight to the widgets. Each part is guarded on its own, so only a
-- missing icon texture keeps the debuff from showing.
-- Icons we've been able to read, by unit and aura instance ID. In combat the client may
-- hide aura details; auras that were already up (or seen while readable) keep their icon.
local iconCache = {}

local function CacheIcon(u, id, iconFile)
    if IsSecret(id) or IsSecret(iconFile) or not id or not iconFile then return end
    iconCache[u] = iconCache[u] or {}
    iconCache[u][id] = iconFile
end

local EMPTY = {}
local function AuraTex(icon, u, id, aura) local file = aura.icon; icon.tex:SetTexture(file); CacheIcon(u, id, file) end
local function AuraDispel(icon, u, id) icon.border:SetVertexColor(C_UnitAuras.GetAuraDispelTypeColor(u, id, dispelCurve):GetRGB()) end
local function AuraStacks(icon, u, id) icon.count:SetText(C_UnitAuras.GetAuraApplicationDisplayCount(u, id, 2, 99)) end
local function AuraDur(icon, u, id) icon.cd:SetCooldownFromDurationObject(C_UnitAuras.GetAuraDuration(u, id)) end

local function SetAura(icon, u, id, index, filter, stale, scanned)
    icon.unit, icon.index, icon.filter, icon.auraInstanceID = u, index, filter, id

    local aura, lookupErrored = scanned, scanned == nil
    if not aura and C_UnitAuras.GetAuraDataByAuraInstanceID then
        local ok, a = pcall(C_UnitAuras.GetAuraDataByAuraInstanceID, u, id)
        if ok then aura, lookupErrored = a, false end
    end
    -- From a stale (cached) list, "no data" means the aura has gone. From a live list it
    -- may just be hidden in combat, so fall back to the cached icon below.
    if stale and not lookupErrored and not aura then return false, "aura expired" end

    local okTex, texErr = false, "no aura data for id"
    if aura then
        okTex, texErr = pcall(AuraTex, icon, u, id, aura)
    end
    if not okTex then
        local cached = not IsSecret(id) and iconCache[u] and iconCache[u][id]
        if not cached and stale then return false, "icon: " .. tostring(texErr) end
        icon.tex:SetTexture(cached or "Interface\\Icons\\INV_Misc_QuestionMark")
    end
    aura = aura or EMPTY

    -- Border color (debuffs by dispel type; buffs stay dark).
    local colored = icon.isBuff or dispelCurve and pcall(AuraDispel, icon, u, id)
    if not colored then
        local okName, name = pcall(function() return Plain(aura.dispelName) end)
        local c = DEBUFF_COLORS[(okName and name) or "none"] or DEBUFF_COLORS.none
        icon.border:SetVertexColor(c[1], c[2], c[3])
    end

    -- Stack count (blank below 2).
    icon.count:SetText("")
    if C_UnitAuras.GetAuraApplicationDisplayCount then
        pcall(AuraStacks, icon, u, id)
    else
        pcall(function()
            local n = aura.applications
            if not IsSecret(n) and n and n > 1 then icon.count:SetText(n) end
        end)
    end

    -- Duration swipe.
    local timed = C_UnitAuras.GetAuraDuration and icon.cd.SetCooldownFromDurationObject and pcall(AuraDur, icon, u, id)
    if not timed then
        local ok = pcall(function()
            local dur, exp = aura.duration, aura.expirationTime
            if not IsSecret(dur) and not IsSecret(exp) and dur and dur > 0 then
                icon.cd:SetCooldown(exp - dur, dur)
            else
                icon.cd:Clear()
            end
        end)
        if not ok then icon.cd:Clear() end
    end

    icon:Show()
    return true
end

-- Diagnostics for /sao debug: which API answered, how many auras, last error.
local auraDiag = {}
local reportedErrors = {}

-- Length of a list the client returned (a table or a vector object).
local function VecLen(v)
    if v == nil then return nil end
    if type(v) == "table" then return #v end
    local ok, n = pcall(function() return #v end)
    if ok and type(n) == "number" then return n end
    ok, n = pcall(function() local c = 0 for _ in ipairs(v) do c = c + 1 end return c end)
    if ok then return n end
end

local function IdOf(aura)
    if type(aura) == "table" then
        local ok, id = pcall(rawget, aura, "auraInstanceID")
        if ok and id ~= nil then return id end
    end
    local ok, id = pcall(function() return aura.auraInstanceID end)
    if ok then return id end
end

-- Aura listing strategies, in order. Each returns a list of { id, index } or errors.
-- An empty answer from one doesn't end the search: on some clients an early method
-- comes back empty for enemies while a later one works.
local AURA_SOURCES = {
    { "GetUnitAuras", function(u, filter, max)
        local res = C_UnitAuras.GetUnitAuras(u, filter, max)
        local n = VecLen(res)
        if not n then error("returned " .. type(res)) end
        local list = {}
        for i = 1, math.min(n, max) do
            local id = IdOf(res[i])
            if id then list[#list + 1] = { id = id, index = i, aura = res[i] } end
        end
        -- Entries exist but none could be read: that's a failure, not "no auras".
        if n > 0 and #list == 0 then error("entries unreadable") end
        return list
    end, function() return C_UnitAuras and C_UnitAuras.GetUnitAuras end },

    { "GetUnitAuraInstanceIDs", function(u, filter, max)
        local ids = C_UnitAuras.GetUnitAuraInstanceIDs(u, filter, max)
        local n = VecLen(ids)
        if not n then error("returned " .. type(ids)) end
        local list = {}
        for i = 1, math.min(n, max) do list[#list + 1] = { id = ids[i], index = i } end
        return list
    end, function() return C_UnitAuras and C_UnitAuras.GetUnitAuraInstanceIDs end },

    { "GetAuraSlots", function(u, filter, max)
        local res = { C_UnitAuras.GetAuraSlots(u, filter, max) }
        local list = {}
        for i = 2, #res do -- res[1] is the continuation token
            local aura = C_UnitAuras.GetAuraDataBySlot(u, res[i])
            local id = aura and IdOf(aura)
            if id then list[#list + 1] = { id = id, index = #list + 1, aura = aura } end
            if #list >= max then break end
        end
        if #res > 1 and #list == 0 then error("slots unreadable") end
        return list
    end, function() return C_UnitAuras and C_UnitAuras.GetAuraSlots and C_UnitAuras.GetAuraDataBySlot end },

    { "GetAuraDataByIndex", function(u, filter, max)
        local list = {}
        for i = 1, 40 do
            if #list >= max then break end
            local aura = C_UnitAuras.GetAuraDataByIndex(u, i, filter)
            if not aura then break end
            local id = IdOf(aura)
            if id then list[#list + 1] = { id = id, index = i } end
        end
        return list
    end, function() return C_UnitAuras and C_UnitAuras.GetAuraDataByIndex end },

    { "AuraUtil.ForEachAura", function(u, filter, max)
        local list = {}
        AuraUtil.ForEachAura(u, filter, max, function(aura)
            local id = IdOf(aura)
            if id then list[#list + 1] = { id = id, index = #list + 1 } end
            return #list >= max
        end, true)
        return list
    end, function() return AuraUtil and AuraUtil.ForEachAura end },
}

local function ScanAuras(u, filter, max)
    local diag = { api = "none", tried = {} }
    local anyOk = false
    for _, src in ipairs(AURA_SOURCES) do
        local name, fn, available = src[1], src[2], src[3]
        if available() then
            local ok, list = pcall(fn, u, filter, max)
            if ok then
                diag.tried[#diag.tried + 1] = name .. "=" .. #list
                anyOk = true
                if #list > 0 then
                    diag.api, diag.err = name, nil
                    return list, diag
                end
            else
                diag.tried[#diag.tried + 1] = name .. "=error"
                diag.err = name .. ": " .. tostring(list)
            end
        end
    end
    -- Nothing found anywhere. If at least one method answered cleanly, there really are none.
    if anyOk then diag.err = nil end
    diag.api = "none found (" .. table.concat(diag.tried, ", ") .. ")"
    return {}, diag
end

local SAMPLE_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

-- Last aura list that could be read, per unit + filter, reused if the client refuses
-- to list auras mid-combat.
local listCache = {}

local function FillRow(f, row, u, filter, diagKey)
    local shown = 0
    local list, diag = ScanAuras(u, filter, #row)
    local ckey = u .. "|" .. filter
    if #list > 0 or not diag.err then
        listCache[ckey] = list
    elseif listCache[ckey] then
        list = {}
        for i, e in ipairs(listCache[ckey]) do list[i] = { id = e.id, index = e.index, stale = true } end
        diag.api = diag.api .. " (using last good list)"
    end
    diag.combat = InCombatLockdown()
    diag.count, diag.unit, diag.filter = #list, u, filter
    if not diag.err and iconCache[u] then
        local keep = {}
        for _, entry in ipairs(list) do
            if not IsSecret(entry.id) and iconCache[u][entry.id] then keep[entry.id] = iconCache[u][entry.id] end
        end
        -- other rows (buffs vs debuffs) of the same unit share the cache: only prune per filter pass
        f.cacheKeep = f.cacheKeep or {}
        f.cacheKeep[filter] = keep
        local merged = {}
        for _, k in pairs(f.cacheKeep) do for id, file in pairs(k) do merged[id] = file end end
        iconCache[u] = merged
    end
    for _, entry in ipairs(list) do
        local icon = row[shown + 1]
        if not icon then break end
        local ok, good, why = pcall(SetAura, icon, u, entry.id, entry.index, filter, entry.stale, entry.aura)
        if ok and good then
            shown = shown + 1
        else
            diag.err = "SetAura: " .. tostring(ok and why or good)
            icon:Hide()
        end
    end
    auraDiag[diagKey] = diag
    local rkey = (diag.combat and "c:" or "") .. (diag.err or "")
    if diag.err and diag.err ~= "SetAura: aura expired" and shown == 0 and not reportedErrors[rkey] then
        reportedErrors[rkey] = true
        Print("|cffff7070aura lookup problem|r (" .. u .. " " .. filter .. (diag.combat and ", in combat" or "") .. "): " .. diag.err)
    end
    return shown
end

local function FillSamples(row, n, isBuff)
    for i = 1, math.min(n, #row) do
        local icon = row[i]
        icon.tex:SetTexture(SAMPLE_ICON)
        local c = isBuff and BUFF_BORDER or DEBUFF_COLORS[i == 1 and "Magic" or i == 2 and "Poison" or "none"]
        icon.border:SetVertexColor(c[1], c[2], c[3])
        icon.count:SetText("")
        icon.cd:Clear()
        icon.auraInstanceID = nil
        icon:Show()
    end
    return math.min(n, #row)
end

-- Debuffs (and buffs on player/target). Big frames stack their rows under the frame:
-- player = buffs then debuffs, target = your debuffs then its buffs; empty rows collapse.
---------------------------------------------------------------------------
-- Aura containers. From 12.1 the game no longer lets addon code read hostile
-- units' auras in combat; instead it provides an "AuraContainer" widget that is
-- given a unit + filter string and enumerates / draws the auras itself (icon,
-- timer, stacks). When available, every aura row uses one; otherwise the older
-- C_UnitAuras-based rows above are used.
---------------------------------------------------------------------------
local HAS_AURA_CONTAINER, SetContainerUnit, AttachAuraContainers, UpdateAuraContainers, RestackAuras -- see block below
do
local FLOW_AXIS = AnchorUtil and AnchorUtil.FlowLayoutAxis or { Horizontal = 0, Vertical = 1 }
local FLOW_DIR  = AnchorUtil and AnchorUtil.FlowDirection or { Left = -1, Right = 1, Up = 1, Down = -1 }
local SORT_METHOD = AuraContainerSortMethod or { Default = 0, ExpirationOnly = 5 }
local SORT_DIR    = AuraContainerSortDirection or { Normal = 0, Reverse = 1 }

HAS_AURA_CONTAINER = (function()
    if not AuraContainerSortMethod then return false end
    local ok, fr = pcall(CreateFrame, "AuraContainer", nil, UIParent, "CustomAuraContainerTemplate")
    if not ok or not fr then return false end
    local good = type(fr.AddAuraGroup) == "function" and type(fr.SetUnit) == "function"
    fr:Hide()
    return good
end)()

-- Style one aura button the container creates. The container fills the icon,
-- cooldown swipe, timer text and stack count; we only build and register them.
local function StyleContainerIcon(button, opts)
    button:SetSize(opts.size, opts.size)
    if button.SetMouseClickEnabled then
        pcall(button.SetMouseClickEnabled, button, false) -- clicks pass through; hover keeps the aura tooltip
    else
        pcall(button.EnableMouse, button, false)
    end

    local border = button:CreateTexture(nil, "BACKGROUND")
    border:SetAllPoints()
    border:SetColorTexture(1, 1, 1, 1)
    local c = opts.isBuff and BUFF_BORDER or DEBUFF_COLORS.none
    border:SetVertexColor(c[1], c[2], c[3])

    -- Debuffs: the game colours this border by dispel type (magic, curse, disease,
    -- poison...) even when the aura is secret; debuffs with no type keep the red base.
    if not opts.isBuff and button.SetAuraBorder then
        local dispel = button:CreateTexture(nil, "BORDER")
        dispel:SetAllPoints()
        dispel:SetColorTexture(1, 1, 1, 1)
        if not pcall(button.SetAuraBorder, button, dispel) then dispel:Hide() end
    end

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", 2, -2)
    icon:SetPoint("BOTTOMRIGHT", -2, 2)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    pcall(button.SetIcon, button, icon)

    local cd = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
    cd:SetAllPoints(icon)
    cd:SetDrawEdge(false)
    if cd.SetDrawBling then cd:SetDrawBling(false) end
    cd:SetReverse(true)
    cd:SetHideCountdownNumbers(true)
    pcall(button.SetDurationCooldown, button, cd)

    local over = CreateFrame("Frame", nil, button)
    over:SetAllPoints()
    over:SetFrameLevel(cd:GetFrameLevel() + 2)

    if opts.timer then
        local t = over:CreateFontString(nil, "OVERLAY")
        if opts.timerInside then
            SetFont(t, 8)
            t:SetPoint("CENTER", icon, "CENTER", 0, 0)
        else
            SetFont(t, 9)
            t:SetPoint("TOP", button, "BOTTOM", 0, -1)
        end
        pcall(button.SetDurationText, button, t)
    end

    local count = over:CreateFontString(nil, "OVERLAY")
    SetFont(count, math.max(8, math.floor(opts.size * 0.45)))
    count:SetPoint("BOTTOMRIGHT", 1, 0)
    pcall(button.SetApplicationCount, button, count)
end

-- One aura row: a plain holder frame plus the game's container inside it.
-- opts: size, max, filter, isBuff, timer, timerInside, growUp, parent
local function MakeAuraContainer(opts)
    local holder = CreateFrame("Frame", nil, opts.parent)
    holder:SetSize(1, 1)
    -- Right-to-left rows need FlowDirection.Left; without it, fall back to left-to-right
    -- rather than failing (a failed container drops every row to the old style).
    if opts.growLeft and FLOW_DIR.Left == nil then opts.growLeft = nil end
    local ok, c = pcall(function()
        local c = CreateFrame("AuraContainer", nil, holder, "CustomAuraContainerTemplate")
        c:SetFlowLayoutAxis(FLOW_AXIS.Horizontal)
        c:SetFlowLayoutMaximumLineSize(math.huge)
        c:AddAuraGroup("main", opts.filter, {
            maxFrameCount = opts.max,
            candidateFilters = {},
            sortMethod = SORT_METHOD.ExpirationOnly,
            sortDirection = SORT_DIR.Normal,
            initializeFrame = function(button) StyleContainerIcon(button, opts) end,
            layout = { elementSpacing = opts.timer and not opts.timerInside and 4 or 2,
                       elementWidth = opts.size, elementHeight = opts.size },
        })
        local corner = (opts.growUp and "BOTTOM" or "TOP") .. (opts.growLeft and "RIGHT" or "LEFT")
        c:ClearAllPoints()
        c:SetPoint(corner, holder, corner, 0, 0)
        c:SetFlowLayoutAnchorPoint(corner)
        c:SetFlowLayoutGrowthDirection(opts.growLeft and FLOW_DIR.Left or FLOW_DIR.Right,
            opts.growUp and FLOW_DIR.Up or FLOW_DIR.Down)
        return c
    end)
    if not ok or not c then
        LogError("AuraContainer setup failed: " .. tostring(c))
        holder:Hide()
        return nil
    end
    holder.container, holder.filter = c, opts.filter
    return holder
end

SetContainerUnit = function(holder, unit, filter)
    local c = holder.container
    if filter and filter ~= holder.filter then
        holder.filter = filter
        if not pcall(c.SetAuraGroupFilterString, c, "main", filter) then holder.filter = nil end
        holder.unit = false -- force a refresh below (false ~= nil, so a nil unit still disables)
    end
    if unit ~= holder.unit then
        holder.unit = unit
        if unit then
            if pcall(c.SetUnit, c, unit) then pcall(c.SetEnabled, c, true)
            else holder.unit = nil; pcall(c.SetEnabled, c, false) end
        else
            pcall(c.SetEnabled, c, false)
        end
    end
end

-- Build the containers for a frame (replaces its old aura rows).
-- rows: list of { kind = "debuffs"|"buffs", size, max, point = {p, rel, x, y} or anchorTo = previous row, ... }
AttachAuraContainers = function(f, rows, parent)
    if not HAS_AURA_CONTAINER then return false end
    local holders = {}
    for _, r in ipairs(rows) do
        local h = MakeAuraContainer({
            parent = parent or f, size = r.size, max = r.max,
            filter = r.kind == "buffs" and "HELPFUL" or (r.filter or "HARMFUL"),
            isBuff = r.kind == "buffs", timer = r.timer, timerInside = r.timerInside, growUp = r.growUp,
            growLeft = r.growLeft,
        })
        if not h then
            for _, old in ipairs(holders) do old:Hide() end
            return false
        end
        h.kind, h.role = r.kind, r.role
        local p = r.point
        h:SetPoint(p[1], p[2] or f, p[3], p[4], p[5])
        -- Second row: slides up into the first row's place while that row is empty.
        if r.emptyAbove and #holders > 0 then
            h.fullPoint, h.emptyPoint, h.above = p, r.emptyAbove, holders[#holders]
        end
        holders[#holders + 1] = h
    end
    -- The old rows stay hidden from now on.
    for _, row in ipairs({ f.debuffs or {}, f.buffs or {} }) do
        for _, icon in ipairs(row) do icon:Hide() end
    end
    f.auraHolders = holders
    return true
end

-- Does this row have anything to show? Ask the game for the unit's first aura with the
-- row's filter (the result is a table or nil; an error counts as "yes" to be safe).
local function RowHasAuras(h)
    local u = h.unit
    if not u or not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then return false end
    -- Enemy auras can be hidden from this query even when present: never collapse
    -- over them (the rows would overlap).
    if CanAttack(u) then return true end
    -- (the row's own filter is in the aura-container syntax; ask with the plain one)
    local ok, d = pcall(C_UnitAuras.GetAuraDataByIndex, u, 1, h.kind == "debuffs" and "HARMFUL" or "HELPFUL")
    if not ok then return true end
    return type(d) == "table"
end

-- Pull a second aura row up when the row above it is empty (no gap under the bar).
RestackAuras = function(f)
    if not f.auraHolders then return end
    for _, h in ipairs(f.auraHolders) do
        if h.above then
            local empty = not RowHasAuras(h.above)
            if empty ~= h.stackEmpty then
                h.stackEmpty = empty
                local p = empty and h.emptyPoint or h.fullPoint
                h:ClearAllPoints()
                h:SetPoint(p[1], p[2], p[3], p[4], p[5])
            end
        end
    end
end

UpdateAuraContainers = function(f)
    local u = f.preview and "player" or f.unit
    if u then
        local ex = UnitExists(u)
        if not IsSecret(ex) and not ex then u = nil end
    end
    local friendly
    if u and f.isPlate then friendly = not CanAttack(u) end
    local plateScale
    if f.isPlate then
        local ok, es = pcall(f.GetEffectiveScale, f)
        local ui = UIParent:GetEffectiveScale()
        if ok and not IsSecret(es) and es and es > 0 and ui > 0 then plateScale = es / ui end
    end
    for _, h in ipairs(f.auraHolders) do
        if plateScale and math.abs((h.plateScale or 1) - plateScale) > 0.01 then
            if pcall(h.SetScale, h, plateScale) then h.plateScale = plateScale end
        end
        local hu, filter = u, nil
        -- Role rows (nameplates): friendly rows only for friends, enemy rows only for enemies.
        if h.role and u then
            local wanted = (h.role == "friendly") == friendly
            if not wanted then hu = nil end
            h:SetShown(wanted)
        end
        if h.kind == "debuffs" then
            filter = u and DebuffFilter(f, u) or h.filter
            if f.isPlate and filter == "HARMFUL|PLAYER" then filter = "HARMFUL|PLAYER|INCLUDE_NAME_PLATE_ONLY" end
        end
        if f.forceAuraUnit then h.unit = false end
        SetContainerUnit(h, hu, filter)
        -- A new target/focus doesn't always fire UNIT_AURA: nudge the container to re-read.
        if f.forceAuraUnit and hu and h.container.UpdateAllAuras then
            pcall(h.container.UpdateAllAuras, h.container)
        end
    end
    f.forceAuraUnit = nil
end

end -- aura container block

local function UpdateAuras(f)
    if f.auraHolders then UpdateAuraContainers(f) return end
    if not f.debuffs then return end
    local u = f.preview and "player" or f.unit
    local key = f.isPlate and "plate" or f.cfg and f.cfg.key or "raid"
    local counts = f.auraCounts or {}
    f.auraCounts = counts
    counts.debuffs, counts.buffs = 0, 0

    if u and UnitExists(u) then
        counts.debuffs = FillRow(f, f.debuffs, u, DebuffFilter(f, u), key)
        if f.buffs then counts.buffs = FillRow(f, f.buffs, u, "HELPFUL", key .. "-buffs") end
    end
    if not db.locked and not f.isPlate then
        if counts.debuffs == 0 then counts.debuffs = FillSamples(f.debuffs, 3, false) end
        if f.buffs and counts.buffs == 0 then counts.buffs = FillSamples(f.buffs, 4, true) end
    end

    for i = counts.debuffs + 1, #f.debuffs do f.debuffs[i]:Hide() end
    if f.buffs then
        for i = counts.buffs + 1, #f.buffs do f.buffs[i]:Hide() end
        -- Stack rows: first non-empty row right under the frame, the next under it.
        local anchor = nil
        for _, name in ipairs(f.auraOrder) do
            local row = f[name]
            row[1]:ClearAllPoints()
            if anchor then
                row[1]:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -14)
            else
                row[1]:SetPoint("TOPLEFT", f.bar, "BOTTOMLEFT", 0, -AURA_GAP)
            end
            if counts[name] > 0 then anchor = row[1] end
        end
    end
end

-- Power bar: colored by the unit's current power type (so druids switch with forms).
-- Hidden for units with no power; on raid frames, healers only unless /sao raidpower.
local function UpdatePower(f)
    local p = f.power
    if not p then return end
    local u = f.preview and "player" or f.unit
    if not u or not UnitExists(u) then return end

    local show = true
    if f.compact and not db.raidPowerAll and not f.preview then
        -- Healers only; with no roles assigned (common outside LFG), anyone using mana.
        local role = Plain(UnitGroupRolesAssigned(u))
        show = role == "HEALER" or ((role == nil or role == "NONE") and Plain(select(2, UnitPowerType(u))) == "MANA")
    end
    local max = UnitPowerMax(u)
    if not IsSecret(max) and (not max or max <= 0) then show = false end
    p:SetShown(show)
    if not show then return end

    local _, token = UnitPowerType(u)
    token = Plain(token)
    local c = token and POWER_COLORS[token]
    if not c and token and PowerBarColor and PowerBarColor[token] then
        local pc = PowerBarColor[token]
        c = { pc.r, pc.g, pc.b }
        POWER_COLORS[token] = c
    end
    c = c or POWER_COLORS.MANA
    p:SetStatusBarColor(c[1], c[2], c[3])

    p:SetMinMaxValues(0, max)
    local cur = UnitPower(u)
    if not (db.smooth and pcall(p.SetValue, p, cur, INTERP)) then p:SetValue(cur) end
    if p.text then
        p.text:SetTextColor(c[1] * 0.4 + 0.6, c[2] * 0.4 + 0.6, c[3] * 0.4 + 0.6)
        if not pcall(p.text.SetFormattedText, p.text, "%s", Abbrev(cur)) then p.text:SetText("") end
    end
end

-- Health bar + text. Called from events and also polled 10x a second, so the number
-- is never behind the real value (execute range!). Percent is rounded down, so it
-- only reads 19% once the unit is really under 20%.
local function SetPercentText(fs, p)
    if not IsSecret(p) then
        fs:SetFormattedText("%d%%", math.floor(p))
        return true
    end
    -- Secret value: let the client format it; "%d" truncates like floor for positives.
    return pcall(fs.SetFormattedText, fs, "%d%%", p) or pcall(fs.SetFormattedText, fs, "%.0f%%", p)
end

-- Incoming heals (all healers), clamped by the game to the unit's missing health.
local healCalc
local function GetCalc()
    if healCalc == nil then
        healCalc = false
        if CreateUnitHealPredictionCalculator and UnitGetDetailedHealPrediction then
            local okC, c = pcall(CreateUnitHealPredictionCalculator)
            if okC and c then
                healCalc = c
                if c.SetIncomingHealClampMode then pcall(c.SetIncomingHealClampMode, c, 0) end -- missing health
                if c.SetIncomingHealOverflowPercent then pcall(c.SetIncomingHealOverflowPercent, c, 0) end
            end
        end
    end
    return healCalc
end
local UpdateAbsorb
-- A StatusBar at its minimum may hide its fill texture and leave its rect stale, so a
-- shield chained to an empty heal layer could start at the wrong spot. When the heal
-- amount is known (plain) to be zero, start the shield at the health end instead.
-- A hidden amount can't be tested, so then we keep chaining. Re-anchor only on change.
local function AnchorAbsorb(f, toHealth)
    local ab = f.absorbBar
    if not ab or f.absorbOnHealth == toHealth then return end
    f.absorbOnHealth = toHealth
    local tex = (toHealth and f.bar or f.healBar):GetStatusBarTexture()
    ab:ClearAllPoints()
    ab:SetPoint("TOPLEFT", tex, "TOPRIGHT")
    ab:SetPoint("BOTTOMLEFT", tex, "BOTTOMRIGHT")
end
local function UpdateHeal(f, u, max, show)
    local hb = f.healBar
    if not hb then return end
    if not show or f.preview then
        hb:Hide()
        if f.absorbBar then f.absorbBar:Hide(); f.overAbsorb:SetAlpha(0) end
        return
    end
    -- Fill the shared calculator once for this unit; heals and shields both read it.
    local calc = GetCalc()
    f.calcFilled = calc and pcall(UnitGetDetailedHealPrediction, u, nil, calc) or false
    UpdateAbsorb(f, u, max)
    if not db.healPredict then
        -- Off: no heal layer; the shield layer starts at the health end.
        pcall(hb.SetMinMaxValues, hb, 0, 1); hb:SetValue(0); hb:Hide()
        AnchorAbsorb(f, true)
        return
    end
    local amt
    -- (UpdateAbsorb just filled the calculator for this unit)
    if f.calcFilled and healCalc then
        local okA, a = pcall(healCalc.GetIncomingHeals, healCalc)
        if okA then amt = a end
    end
    if not IsSecret(amt) and amt == nil and UnitGetIncomingHeals then
        local okU, a = pcall(UnitGetIncomingHeals, u)
        if okU then amt = a end
    end
    -- (never "amt or 0": that truth-tests a possibly hidden value)
    if not IsSecret(amt) and type(amt) ~= "number" then amt = 0 end
    if not pcall(hb.SetMinMaxValues, hb, 0, max) or not pcall(hb.SetValue, hb, amt) then
        pcall(hb.SetMinMaxValues, hb, 0, 1); hb:SetValue(0)
        amt = 0
    end
    hb:Show()
    -- (amt is only compared when it is a plain number)
    AnchorAbsorb(f, not IsSecret(amt) and amt <= 0)
end

-- Shields: total damage absorbs on the unit (hidden values are fine - no math).
-- The calculator also says whether the shield was cut off at full health; that
-- (possibly hidden) yes/no lights the bright edge via SetAlphaFromBoolean.
UpdateAbsorb = function(f, u, max)
    local ab = f.absorbBar
    if not ab then return end
    if not db.absorbs or f.preview then ab:Hide(); f.overAbsorb:SetAlpha(0) return end
    local amt, clamped
    if healCalc and healCalc.GetDamageAbsorbs and f.calcFilled then
        local ok, a, c = pcall(healCalc.GetDamageAbsorbs, healCalc)
        if ok then amt, clamped = a, c end
    end
    if not IsSecret(amt) and amt == nil and UnitGetTotalAbsorbs then
        local ok, a = pcall(UnitGetTotalAbsorbs, u)
        if ok then amt = a end
    end
    if not IsSecret(amt) and type(amt) ~= "number" then ab:Hide(); f.overAbsorb:SetAlpha(0) return end
    if not pcall(ab.SetMinMaxValues, ab, 0, max) or not pcall(ab.SetValue, ab, amt) then
        ab:Hide(); f.overAbsorb:SetAlpha(0) return
    end
    ab:Show()
    if IsSecret(clamped) then
        if not (f.overAbsorb.SetAlphaFromBoolean and pcall(f.overAbsorb.SetAlphaFromBoolean, f.overAbsorb, clamped, 1, 0)) then
            f.overAbsorb:SetAlpha(0)
        end
    else
        f.overAbsorb:SetAlpha(clamped == true and 1 or 0)
    end
end

UpdateHealth = function(f)
    local u = f.preview and "player" or f.unit
    if not u or not UnitExists(u) then return end

    local cur, max = UnitHealth(u), UnitHealthMax(u)
    f.bar:SetMinMaxValues(0, max)
    if not (db.smooth and pcall(f.bar.SetValue, f.bar, cur, INTERP)) then f.bar:SetValue(cur) end

    local dead = Plain(UnitIsDeadOrGhost(u))
    local online = Plain(UnitIsConnected(u))
    UpdateHeal(f, u, max, online ~= false and not dead)
    -- Raid frames show only the percentage (in f.hp); big frames show "cur / max" plus f.pct.
    local pctText = f.pct or f.hp
    pctText:SetText("")
    if online == false then
        SetBarColor(f, C_GREY); f.hp:SetText("OFFLINE")
    elseif dead then
        SetBarColor(f, C_GREY); f.hp:SetText("DEAD")
    else
        ColorHealth(f, u, cur, max)
        if f.pct and not pcall(f.hp.SetFormattedText, f.hp, "%s / %s", Abbrev(cur), Abbrev(max)) then
            f.hp:SetText("")
        end
        local p = HealthPercent(u, cur, max)
        local havePct = IsSecret(p) or p ~= nil -- never compare a secret value, even to nil
        if not havePct or not SetPercentText(pctText, p) then
            if f.compact then pcall(f.hp.SetText, f.hp, Abbrev(cur)) end
        end
    end
end

-- Forever characters have a first name and a surname; UnitName returns them as its
-- two values (where retail returns name and realm). Big frames stack them on two lines.
local function SetUnitName(fs, u, stacked)
    local first, last = UnitName(u)
    local hasLast = IsSecret(last) or (last ~= nil and last ~= "")
    local fmt = hasLast and (stacked and "%s\n%s" or "%s %s") or "%s"
    if not pcall(fs.SetFormattedText, fs, fmt, first, last) then pcall(fs.SetText, fs, first) end
end

-- Raid target markers (skull, cross, star...): an icon on every frame and nameplate
-- of a marked unit, refreshed on RAID_TARGET_UPDATE and every frame update.
local AddRaidMark, UpdateRaidMark, InitRaidMarks
do
local marked = {} -- frames that carry a marker icon (plates included)

AddRaidMark = function(f, size, point, rel, relPoint, x, y)
    local layer = CreateFrame("Frame", nil, f)
    layer:SetAllPoints(f)
    layer:SetFrameLevel(f:GetFrameLevel() + 15)
    local icon = layer:CreateTexture(nil, "OVERLAY", nil, 7)
    icon:SetSize(size, size)
    icon:SetPoint(point, rel or f, relPoint or point, x or 0, y or 0)
    icon:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcons")
    icon:Hide()
    f.raidMark = icon
    marked[#marked + 1] = f
end

-- The marker index is always a hidden (secret) value for addons, so it can't be
-- compared or used in math. Texture:SetSpriteSheetCell (12.0+) takes it as-is and
-- picks the cell from the 4x4 marker sheet - exactly what Blizzard's frames do.
local function SetMark(icon, idx)
    if icon.SetSpriteSheetCell then return icon:SetSpriteSheetCell(idx, 4, 4) end
    if SetRaidTargetIconTexture then return SetRaidTargetIconTexture(icon, idx) end
    local col, row = (idx - 1) % 4, math.floor((idx - 1) / 4) -- plain values only
    icon:SetTexCoord(col / 4, (col + 1) / 4, row / 4, (row + 1) / 4)
end

UpdateRaidMark = function(f, u)
    local icon = f.raidMark
    if not icon then return end
    u = u or (f.preview and "player" or f.unit)
    if not u or not GetRaidTargetIndex then icon:Hide() return end
    local okI, idx = pcall(GetRaidTargetIndex, u)
    -- Unmarked = nil. A secret value is never nil, so "secret" means marked.
    if not okI or not (IsSecret(idx) or type(idx) == "number") then icon:Hide() return end
    if not IsSecret(idx) and (idx < 1 or idx > 8) then icon:Hide() return end
    if pcall(SetMark, icon, idx) then icon:Show() else icon:Hide() end
end

InitRaidMarks = function()
    local ev = CreateFrame("Frame")
    ev:RegisterEvent("RAID_TARGET_UPDATE")
    ev:RegisterEvent("PLAYER_TARGET_CHANGED")
    ev:RegisterEvent("PLAYER_FOCUS_CHANGED")
    ev:RegisterEvent("GROUP_ROSTER_UPDATE")
    ev:SetScript("OnEvent", function()
        for _, f in ipairs(marked) do
            if f.unit or f.preview then UpdateRaidMark(f) else f.raidMark:Hide() end
        end
    end)
end
end -- raid markers

-- Extras: guild names under player names, and floating "Z"s on the player frame while
-- resting (inn / city). One table keeps the main chunk's local count down.
local Extras = {}
do
-- <Guild> under the name on big frames, and on a small line under the bar on player
-- nameplates (friendly buff/debuff rows on that plate move down to make room).
function Extras.UpdateGuild(f, u)
    if not f.name or (f.compact and not f.isPlate) then return end -- raid/ToT: no room
    local g
    if db.guildNames ~= false and u and not f.preview and Plain(UnitIsPlayer(u)) and GetGuildInfo then
        local ok, name = pcall(GetGuildInfo, u)
        if ok and (IsSecret(name) or (type(name) == "string" and name ~= "")) then g = name end
    end
    local has = IsSecret(g) or g ~= nil
    local t = f.guildText
    if not t then
        if not has then return end -- create lazily, on the first guilded unit
        t = f:CreateFontString(nil, "OVERLAY")
        if f.isPlate then
            SetFont(t, 9)
            t:SetPoint("TOPLEFT", f.bar, "BOTTOMLEFT", 4, -1)
            t:SetPoint("TOPRIGHT", f.bar, "BOTTOMRIGHT", -4, -1)
            t:SetJustifyH("LEFT")
        else
            SetFont(t, 10)
            t:SetPoint("TOPRIGHT", f.name, "BOTTOMRIGHT", 0, -2)
            t:SetWidth(BAR_X - 12)
            t:SetJustifyH("RIGHT")
        end
        t:SetWordWrap(false)
        t:SetTextColor(0.62, 0.86, 1)
        f.guildText = t
    end
    local shown = has and pcall(t.SetFormattedText, t, "<%s>", g) or false
    t:SetShown(shown)
    -- Plates: friendly aura rows sit under the guild line while it's shown.
    if f.isPlate and f.auraHolders and f.guildShift ~= shown then
        f.guildShift = shown
        local y = shown and -14 or -3
        for _, h in ipairs(f.auraHolders) do
            if h.role == "friendly" then
                h:ClearAllPoints()
                if h.kind == "buffs" then h:SetPoint("TOPLEFT", f.bar, "BOTTOMLEFT", 0, y)
                else h:SetPoint("TOPRIGHT", f.bar, "BOTTOMRIGHT", 0, y) end
            end
        end
    end
end

-- A pulsing "z Z Z" above the player frame's class chip while resting.
function Extras.InitRestZ()
    local pf = frames.player
    if not (pf and pf.badge) then return end
    local holder = CreateFrame("Frame", nil, pf)
    holder:SetSize(40, 40)
    holder:SetPoint("BOTTOMLEFT", pf.badge, "TOPRIGHT", -6, -4)
    holder:SetFrameLevel(pf:GetFrameLevel() + 25)
    -- Static "z Z Z" stepping up and to the right, with one slow gentle pulse on the group.
    local prev
    for i, size in ipairs({ 10, 13, 16 }) do
        local z = holder:CreateFontString(nil, "OVERLAY")
        SetFont(z, size, true)
        z:SetText(i == 1 and "z" or "Z")
        z:SetTextColor(0.62, 0.90, 1)
        if prev then z:SetPoint("BOTTOMLEFT", prev, "TOPRIGHT", -4, -8)
        else z:SetPoint("BOTTOMLEFT", 0, 0) end
        prev = z
    end
    local ag = holder:CreateAnimationGroup()
    ag:SetLooping("BOUNCE")
    local pulse = ag:CreateAnimation("Alpha")
    pulse:SetFromAlpha(1); pulse:SetToAlpha(0.45)
    pulse:SetDuration(1.4)
    pulse:SetSmoothing("IN_OUT")
    ag:Play()
    local function Update()
        local r = IsResting and Plain(IsResting())
        holder:SetShown(r == true and db.restZ ~= false)
    end
    local ev = CreateFrame("Frame")
    ev:RegisterEvent("PLAYER_UPDATE_RESTING")
    ev:RegisterEvent("PLAYER_ENTERING_WORLD")
    ev:SetScript("OnEvent", Update)
    Extras.UpdateRestZ = Update
    Update()
end
end -- extras

-- Ready checks: a check / cross / "?" icon on party frames (next to the class chip)
-- and centred on raid frames. Stays up for a few seconds after the check ends, with
-- anyone who never answered shown as not ready.
local AddReadyCheck, InitReadyCheck
do
local TEX = {
    ready    = READY_CHECK_READY_TEXTURE or "Interface\\RaidFrame\\ReadyCheck-Ready",
    notready = READY_CHECK_NOT_READY_TEXTURE or "Interface\\RaidFrame\\ReadyCheck-NotReady",
    waiting  = READY_CHECK_WAITING_TEXTURE or "Interface\\RaidFrame\\ReadyCheck-Waiting",
}
local holders = {} -- every frame that has a ready-check icon
local hideToken = 0

AddReadyCheck = function(f, size, point, rel, relPoint, x, y)
    local layer = CreateFrame("Frame", nil, f)
    layer:SetAllPoints(f)
    layer:SetFrameLevel(f:GetFrameLevel() + 20)
    local icon = layer:CreateTexture(nil, "OVERLAY", nil, 7)
    icon:SetSize(size, size)
    icon:SetPoint(point, rel or f, relPoint or point, x or 0, y or 0)
    icon:Hide()
    f.readyIcon = icon
    holders[#holders + 1] = f
end

local function Refresh(finished)
    for _, f in ipairs(holders) do
        local icon, u = f.readyIcon, f.unit
        local st = u and Plain(GetReadyCheckStatus and GetReadyCheckStatus(u)) or nil
        if finished then
            -- the API usually answers nil once the check is over: use what we saw last
            if st == nil and u and f.readyUnit == u then st = f.readyStatus end
            if st == "waiting" then st = "notready" end
        else
            f.readyStatus, f.readyUnit = st, u
        end
        if st and TEX[st] and f:IsVisible() then
            icon:SetTexture(TEX[st])
            icon:Show()
        else
            icon:Hide()
        end
    end
end

InitReadyCheck = function()
    local ev = CreateFrame("Frame")
    ev:RegisterEvent("READY_CHECK")
    ev:RegisterEvent("READY_CHECK_CONFIRM")
    ev:RegisterEvent("READY_CHECK_FINISHED")
    ev:SetScript("OnEvent", function(_, event)
        if event == "READY_CHECK_FINISHED" then
            Refresh(true)
            hideToken = hideToken + 1
            local token = hideToken
            C_Timer.After(8, function()
                if token ~= hideToken then return end -- a new check started meanwhile
                for _, f in ipairs(holders) do f.readyIcon:Hide(); f.readyStatus, f.readyUnit = nil, nil end
            end)
        else
            hideToken = hideToken + 1
            Refresh(false)
        end
    end)
end
end -- ready check

-- Group role (tank / healer / dps) from what the player picked.
local ROLE_ATLAS = { TANK = "roleicon-tiny-tank", HEALER = "roleicon-tiny-healer", DAMAGER = "roleicon-tiny-dps" }

local function UpdateRole(f, u)
    local icon = f.roleIcon
    if not icon then return end
    local role = Plain(UnitGroupRolesAssigned(u))
    if f.preview then role = role ~= "NONE" and role or "DAMAGER" end
    local atlas = role and ROLE_ATLAS[role]
    if not atlas then icon:Hide() return end
    if C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(atlas) then
        icon:SetAtlas(atlas)
    elseif GetTexCoordsForRoleSmallCircle then
        icon:SetTexture("Interface\\LFGFrame\\UI-LFG-ICON-PORTROLES")
        icon:SetTexCoord(GetTexCoordsForRoleSmallCircle(role))
    else
        icon:Hide() return
    end
    icon:Show()
end

-- Put the left aggro arrow just left of the name's actual text.
local function PlaceLeftSpike(f)
    if not f.spikeHugsName then return end
    local boxW = f.name:GetWidth()
    if IsSecret(boxW) or not boxW then boxW = BAR_X - 12 end
    local ok, w = pcall(f.name.GetStringWidth, f.name)
    w = (ok and not IsSecret(w) and w) and math.min(w, boxW) or boxW
    local sp = f.spikes[1]
    sp:ClearAllPoints()
    sp:SetPoint("RIGHT", f.bar, "TOPLEFT", -(w + 6) - 8, -13)
end

-- Level text colored by difficulty vs. your level:
--   gray = no XP (trivial), green = easy, white = around your level,
--   orange = a few levels above, red = 5+ above or a ?? skull.
local LevelColor, SkullLevel
do
-- "??" (skull) mobs: the client hides their real level, so show a red "30+"
-- (your level + 10, the skull threshold) instead of a skull / "??".
SkullLevel = function()
    local pl = Plain(UnitLevel("player"))
    if type(pl) == "number" and pl > 0 then return (pl + 10) .. "+" end
    return "??"
end
local GRAY, GREEN, WHITE, ORANGE, RED = { 0.55, 0.55, 0.55 }, { 0.25, 0.85, 0.25 }, { 1, 1, 1 }, { 1, 0.5, 0.1 }, { 1, 0.15, 0.15 }
local function GrayLevel(pl)
    -- Highest mob level that gives no XP. Prefer the client's own answer.
    if GetQuestGreenRange then
        local ok, range = pcall(GetQuestGreenRange, "player")
        range = ok and Plain(range) or nil
        if type(range) == "number" then return pl - range - 1 end
    end
    if pl <= 5 then return 0 end
    if pl <= 39 then return pl - math.floor(pl / 10) - 5 end
    if pl <= 59 then return pl - math.floor(pl / 5) - 1 end
    return pl - 9
end
-- Returns r, g, b for a unit's level text (white if unknown or turned off).
LevelColor = function(u)
    if not db.levelColors then return 1, 1, 1 end
    local lv, pl = Plain(UnitLevel(u)), Plain(UnitLevel("player"))
    local c
    if type(lv) ~= "number" or type(pl) ~= "number" then c = WHITE
    elseif lv <= 0 then c = RED -- ?? (boss / far above you)
    else
        local d = lv - pl
        c = d >= 5 and RED or d >= 3 and ORANGE or d >= -2 and WHITE
            or lv > GrayLevel(pl) and GREEN or GRAY
    end
    return c[1], c[2], c[3]
end
end -- level colors

-- Elite / rare / boss borders on enemy-style frames and nameplates.
--   elite = gold, rare = silver, rare elite = gold outline + silver border,
--   boss = red outline + gold border.  Normal units keep the plain white border.
local UpdateClassification
do
local GOLD, SILVER, BOSSRED = { 1, 0.8, 0.2 }, { 0.78, 0.88, 1 }, { 1, 0.22, 0.18 }
local STYLES = {
    elite     = { edge = GOLD,    border = GOLD },
    rare      = { edge = SILVER,  border = SILVER },
    rareelite = { edge = GOLD,    border = SILVER },
    worldboss = { edge = BOSSRED, border = GOLD },
}
UpdateClassification = function(f, u)
    if not f.eliteEdge then return end
    local style
    if db.eliteBorders and (f.kind == "enemy" or f.kind == "tot") and not f.preview
        and not Plain(UnitIsPlayer(u)) and CanAttack(u) then -- enemies only (not friendly elite guards)
        local ok, cls = pcall(UnitClassification, u)
        cls = ok and Plain(cls) or nil
        style = cls and STYLES[cls]
        -- Bosses report "elite" with level -1 (skull) on many clients.
        if cls == "elite" then
            local lv = Plain(UnitLevel(u))
            if lv and lv < 0 then style = STYLES.worldboss end
        end
    end
    if style then
        local e, b = style.edge, style.border
        f.eliteEdge:SetVertexColor(e[1], e[2], e[3], 1)
        f.eliteEdge:Show()
        f.barBorder:SetVertexColor(b[1], b[2], b[3], 1)
        if f.badgeBorder then f.badgeBorder:SetVertexColor(b[1], b[2], b[3], 1) end
    elseif f.eliteEdge:IsShown() or f.eliteStyled then
        f.eliteEdge:Hide()
        f.barBorder:SetVertexColor(0.88, 0.92, 0.96, 0.95)
    end
    f.eliteStyled = style ~= nil
end
end -- classification

local function UpdateFrame(f)
    local u = f.preview and "player" or f.unit
    if not u or not UnitExists(u) then return end

    SetUnitName(f.name, u, not f.compact)
    PlaceLeftSpike(f)

    if f.lv then
        local lv = UnitLevel(u)
        if not IsSecret(lv) and (not lv or lv <= 0) then lv = SkullLevel() end
        if not pcall(f.lv.SetFormattedText, f.lv, "LV: %s", lv) then f.lv:SetText("") end
        if f.kind == "enemy" or f.kind == "tot" then f.lv:SetTextColor(LevelColor(u))
        else f.lv:SetTextColor(1, 1, 1) end
    end

    UpdateHealth(f)
    UpdateBadge(f, u)
    UpdateClassification(f, u)
    UpdateRaidMark(f, u)
    Extras.UpdateGuild(f, u)
    UpdateRole(f, u)
    UpdatePower(f)
    UpdateAuras(f)
end

local POWER_EVENTS = { UNIT_POWER_FREQUENT = true, UNIT_MAXPOWER = true, UNIT_DISPLAYPOWER = true }

local function OnEvent(f, event)
    if event == "PLAYER_FOCUS_CHANGED" or event == "PLAYER_TARGET_CHANGED"
        or event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_ENTERING_WORLD" then
        f.forceAuraUnit = true
    end
    if event == "PLAYER_FOCUS_CHANGED" then
        f.cacheKeep = nil
        iconCache.focus = nil
        listCache["focus|HARMFUL"], listCache["focus|HARMFUL|PLAYER"], listCache["focus|HELPFUL"] = nil, nil, nil
    end
    if event == "PLAYER_TARGET_CHANGED" and f.unit == "target" then
        f.cacheKeep = nil
        iconCache.target = nil
        listCache["target|HARMFUL"], listCache["target|HARMFUL|PLAYER"], listCache["target|HELPFUL"] = nil, nil, nil
    end
    if event == "UNIT_AURA" then
        UpdateAuras(f)
    elseif event == "UNIT_HEALTH" or event == "UNIT_MAXHEALTH" then
        UpdateHealth(f)
    elseif POWER_EVENTS[event] then
        UpdatePower(f)
    else
        UpdateFrame(f)
    end
end

-- Threat glow, Threat Plates style.
--  Target frame: your threat on that mob. DPS/healer: yellow = close to pulling,
--    orange = you're tanking it insecurely, red = it's on you.
--    Tank: green = solidly yours, yellow = insecure, red = someone else has it.
--  Player/party/raid frames: that person's aggro (yellow/orange/red).
local THREAT_DPS  = { [1] = { 1, 0.85, 0.1 }, [2] = { 1, 0.5, 0 }, [3] = { 1, 0.1, 0.1 } }

local function MakeThreatCurve(map)
    local ok, c = pcall(function()
        if not (C_CurveUtil and C_CurveUtil.CreateColorCurve) then return end
        local curve = C_CurveUtil.CreateColorCurve()
        if Enum.LuaCurveType and curve.SetType then curve:SetType(Enum.LuaCurveType.Step) end
        for i = 0, 3 do
            local col = map[i]
            curve:AddPoint(i, col and CreateColor(col[1], col[2], col[3], 1) or CreateColor(0, 0, 0, 0))
        end
        return curve
    end)
    return ok and c or nil
end
local threatCurveDps = MakeThreatCurve(THREAT_DPS)

-- Am I tanking? Stance/form first (Defensive Stance, Bear Form, Righteous Fury),
-- then spec role, then group role. Buff checks are cached out of combat because
-- spell-ID aura lookups are blocked while auras are secret.
local TANK_FORMS = { WARRIOR = { [18] = true }, DRUID = { [5] = true, [8] = true } }
local TANK_BUFFS = { PALADIN = { 25780 } } -- Righteous Fury
local tankBuffCache = false
local detectedRole, roleSource = "DPS", "default"

local function RefreshTankBuffCache()
    if InCombatLockdown() then return end
    local _, class = UnitClass("player")
    local ids = TANK_BUFFS[class]
    tankBuffCache = false
    if not ids or not (C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID) then return end
    for _, id in ipairs(ids) do
        local ok, aura = pcall(C_UnitAuras.GetPlayerAuraBySpellID, id)
        if ok and aura then tankBuffCache = true end
    end
end

local function DetectRole()
    local _, class = UnitClass("player")
    local form = Plain(GetShapeshiftFormID and GetShapeshiftFormID())
    if form and TANK_FORMS[class] and TANK_FORMS[class][form] then return "TANK", "stance/form" end
    if TANK_FORMS[class] and form then return "DPS", "stance/form" end -- e.g. Battle/Berserker, Cat
    if tankBuffCache then return "TANK", "Righteous Fury" end
    if GetSpecialization and GetSpecializationRole then
        local ok, role = pcall(function() return GetSpecializationRole(GetSpecialization()) end)
        role = ok and Plain(role)
        if role == "TANK" or role == "HEALER" or role == "DAMAGER" then
            return role == "DAMAGER" and "DPS" or role, "spec"
        end
    end
    local role = Plain(UnitGroupRolesAssigned("player"))
    if role == "TANK" or role == "HEALER" then return role, "group role" end
    return "DPS", "default"
end

local roleCheckedAt = 0
local function IsTank()
    if db.threatRole ~= "auto" then return db.threatRole == "TANK" end
    local now = GetTime()
    if now - roleCheckedAt > 0.2 then
        detectedRole, roleSource = DetectRole()
        roleCheckedAt = now
    end
    return detectedRole == "TANK"
end

-- Enemy threat (target frame + nameplates): arrows and edge glow share one color.
--  DPS/healer, by your threat % on the mob: green < 50, yellow 50-79, orange 80-99,
--    red = you have aggro (pulsing).
--  Tank, by your threat status: green = solidly yours, yellow = slipping,
--    orange = someone's about to take it, red = lost (orange/red pulse).
local ShowSpikes, UpdateThreat -- defined in the threat block below
local PaintAggroBool
do
local PLATE_ALIASES = { "target", "focus", "mouseover", "boss1", "boss2", "boss3", "boss4", "boss5" }
local T_GREEN, T_YELLOW, T_ORANGE, T_RED = { 0.2, 0.9, 0.3 }, { 1, 0.85, 0.1 }, { 1, 0.5, 0 }, { 1, 0.1, 0.1 }
local TANK_STATUS = { [0] = T_RED, [1] = T_ORANGE, [2] = T_YELLOW, [3] = T_GREEN }
-- Non-tank, by status when the % is hidden: 0 = safe, 1 = above the tank (about to
-- pull), 2/3 = you have aggro.
local DPS_STATUS = { [0] = T_GREEN, [1] = T_ORANGE, [2] = T_RED, [3] = T_RED }

local function DpsColor(pct)
    return pct >= 100 and T_RED or pct >= 80 and T_ORANGE or pct >= 50 and T_YELLOW or T_GREEN
end

local function MakeStepCurve(points)
    local ok, c = pcall(function()
        if not (C_CurveUtil and C_CurveUtil.CreateColorCurve) then return end
        local curve = C_CurveUtil.CreateColorCurve()
        if Enum.LuaCurveType and curve.SetType then curve:SetType(Enum.LuaCurveType.Step) end
        for _, pt in ipairs(points) do curve:AddPoint(pt[1], CreateColor(pt[2][1], pt[2][2], pt[2][3], 1)) end
        return curve
    end)
    return ok and c or nil
end

-- Color every texture from a value: plain values use plainColor, secret ones go
-- through the client-side curve.
local function PaintSecret(texs, value, curve)
    local r, g, b = curve:Evaluate(value):GetRGB()
    for _, t in ipairs(texs) do t:SetVertexColor(r, g, b, 1) end
end
local function PaintSecretOne(tex, value, curve)
    tex:SetVertexColor(curve:Evaluate(value):GetRGBA())
end

local function PaintThreat(texs, value, plainColor, curve)
    if IsSecret(value) then
        if curve ~= nil and pcall(PaintSecret, texs, value, curve) then return true end
        -- Can't grade a secret value (addon code may not run curves on secrets): still show the arrows,
        -- in a neutral "in combat with you" orange, so aggro is never invisible.
        for _, t in ipairs(texs) do t:SetVertexColor(T_ORANGE[1], T_ORANGE[2], T_ORANGE[3], 1) end
        return true, "threat hidden by the game, neutral color"
    end
    if not plainColor then return false end
    for _, t in ipairs(texs) do t:SetVertexColor(plainColor[1], plainColor[2], plainColor[3], 1) end
    return true
end

-- Generic aggro glow for your own / party / raid frames (that person has aggro).
local function SetThreatTexture(tex, status, map, curve)
    if IsSecret(status) then
        return curve ~= nil and (pcall(PaintSecretOne, tex, status, curve)) or false
    end
    local col = status ~= nil and map[status]
    if col then tex:SetVertexColor(col[1], col[2], col[3], 1) return true end
    return false
end

-- Color textures from a possibly hidden (secret) yes/no: the game allows
-- SetVertexColorFromBoolean on secrets. b = "am I tanking it?", or else
-- "is it targeting me?". Returns ok, reason.
local boolColors = {}
local function BoolColor(c)
    local col = boolColors[c]
    if not col and CreateColor then col = CreateColor(c[1], c[2], c[3], 1); boolColors[c] = col end
    return col
end
PaintAggroBool = function(texs, b, u, cYes, cNo)
    if IsSecret(b) or type(b) ~= "boolean" then
        if not IsSecret(b) then -- no tanking answer at all: is the mob targeting me?
            local ok, r = pcall(UnitIsUnit, u .. "target", "player")
            if not ok then return false end
            b = r
        end
    end
    if not IsSecret(b) then
        if type(b) ~= "boolean" then return false end
        local c = b and cYes or cNo
        for _, t in ipairs(texs) do t:SetVertexColor(c[1], c[2], c[3], 1) end
        return true, "aggro yes/no"
    end
    local yes, no = BoolColor(cYes), BoolColor(cNo)
    if not yes then return false end
    for _, t in ipairs(texs) do
        if not (t.SetVertexColorFromBoolean and pcall(t.SetVertexColorFromBoolean, t, b, yes, no)) then
            return false
        end
    end
    return true, "hidden aggro yes/no"
end

-- Threat % text (target/focus frames and nameplates). Secret values are formatted
-- by the client; color follows the arrows when it's known, white otherwise.
-- Threat text range:
--   not tanking: raw % = your threat vs. the current tank's. It goes past 100 - you
--     pull at about 110% in melee range or 130% at range (0-255 from the API).
--   tanking: % of lead over the next player, capped at 300% ("300%+").
local THREAT_CAP = 300 -- threat text tops out at "300%+"
local function SetThreatText(f, u, tanking, raw, scaled, color)
    local t = f.threatText
    if not t then return end
    local pre = f.isPlate and "" or "THREAT "
    local ok
    if not IsSecret(tanking) and tanking == true then
        -- While it's on you: your % of lead over the next player, capped at 300%
        -- (solo it reads thousands, e.g. 3890%, so it shows "300%+"). A hidden lead
        -- value can't be capped, so then it shows your threat % (100%) instead.
        if UnitThreatPercentageOfLead then
            local okL, v = pcall(UnitThreatPercentageOfLead, "player", u)
            if okL and not IsSecret(v) and type(v) == "number" and v > 0 then
                if v >= THREAT_CAP then t:SetText(pre .. THREAT_CAP .. "%+")
                else t:SetFormattedText(pre .. "%.0f%%", v) end
                ok = true
            end
        end
        if not ok then
            if IsSecret(scaled) or type(scaled) == "number" then
                ok = pcall(t.SetFormattedText, t, pre .. "%.0f%%", scaled)
            end
            if not ok then t:SetText(pre .. "100%"); ok = true end
        end
    elseif not IsSecret(raw) and type(raw) == "number" and raw >= THREAT_CAP then
        t:SetText(pre .. THREAT_CAP .. "%+"); ok = true
    elseif IsSecret(raw) or type(raw) == "number" then
        ok = pcall(t.SetFormattedText, t, pre .. "%.0f%%", raw)
    end
    if not ok then t:Hide() return end
    if color then t:SetTextColor(color[1], color[2], color[3]) else t:SetTextColor(1, 1, 1) end
    t:Show()
end

ShowSpikes = function(f, on, pulse)
    if not f.spikes then return end
    for _, sp in ipairs(f.spikes) do
        if on then
            sp:Show()
            if pulse and not sp.anim:IsPlaying() then sp.anim:Play()
            elseif not pulse and sp.anim:IsPlaying() then sp.anim:Stop() end
        elseif sp:IsShown() then
            sp.anim:Stop(); sp:Hide()
        end
    end
end

UpdateThreat = function(f)
    local g = f.threatGlow
    if not g then return end
    local u = f.unit
    local live = db.threat and not f.preview and u and f:IsVisible() and UnitExists(u)

    if f.kind == "enemy" then
        if not live or not CanAttack(u) then
            f.threatWhy = not live and "not live" or "not attackable"
            g:Hide(); ShowSpikes(f, false); f.threatColored = false
            if f.threatText then f.threatText:Hide() end
            return
        end
        local tanking, status, scaled, raw = UnitDetailedThreatSituation("player", u)
        if IsSecret(status) or status == nil then
            -- The simple query is restricted less often than the detailed one: when the
            -- detailed status is empty or hidden, a readable 0-3 status from it lets the
            -- plate grade green / orange / red instead of only "on you or not".
            local okS, st = pcall(UnitThreatSituation, "player", u)
            if okS then
                if not IsSecret(st) and st ~= nil then status = st
                elseif not IsSecret(status) and status == nil and IsSecret(st) then status = st end
            end
        end
        -- Nameplate tokens can be restricted (empty or hidden/secret answers). If this
        -- plate is also our target / focus / mouseover / a boss, ask through that token,
        -- so the plate matches the target frame exactly.
        f.threatAlias = nil
        if f.isPlate and C_NamePlate and (IsSecret(status) or status == nil or IsSecret(scaled)) then
            local plate = f:GetParent()
            for _, alias in ipairs(PLATE_ALIASES) do
                local ok, ap = pcall(C_NamePlate.GetNamePlateForUnit, alias, false)
                if ok and ap == plate then
                    local aTank, aStatus, aScaled, aRaw = UnitDetailedThreatSituation("player", alias)
                    if not IsSecret(aStatus) and aStatus == nil then aStatus = UnitThreatSituation("player", alias) end
                    -- Use the alias answer only if it's more readable than what we had.
                    if not IsSecret(aStatus) and aStatus ~= nil then
                        tanking, status, scaled, raw = aTank, aStatus, aScaled, aRaw
                        u = alias
                        f.threatAlias = alias
                    end
                    break
                end
            end
        end
        -- Not on this mob's threat list (yet): nothing to show.
        if not IsSecret(status) and status == nil then
            f.threatWhy = "no threat data (not in combat with you, or blocked)"
            g:Hide(); ShowSpikes(f, false); f.threatColored = false
            if f.threatText then f.threatText:Hide() end
            return
        end

        local texs = f.threatTexs or {}
        f.threatTexs = texs
        wipe(texs)
        texs[1] = g
        -- A mob tagged by someone else keeps its grey bar even once it's fighting you
        -- (the glow and arrows still show your threat).
        local tapped = Plain(UnitIsTapDenied(u)) == true
        local selRed = IsTargetEnemy(f, f.unit)
        if db.threatBars and not tapped and not selRed then texs[#texs + 1] = f.bar:GetStatusBarTexture() end
        if f.spikes then for _, sp in ipairs(f.spikes) do texs[#texs + 1] = sp end end
        local ok, pulse, why
        if IsTank() and IsSecret(status) then
            -- Hidden threat: the game still lets us color from a hidden yes/no
            -- ("am I tanking it?"): green = yours, red = lost.
            ok, why = PaintAggroBool(texs, tanking, u, T_GREEN, T_RED)
            if not ok then ok, why = PaintThreat(texs, status, nil, nil) end
            pulse = false
        elseif IsTank() then
            ok, why = PaintThreat(texs, status, TANK_STATUS[status], nil)
            pulse = status <= 1
        elseif IsSecret(status) then
            -- Hidden threat, non-tank: red = it's on you, green = it isn't.
            ok, why = PaintAggroBool(texs, tanking, u, T_RED, T_GREEN)
            if not ok then ok, why = PaintThreat(texs, status, nil, nil) end
            pulse = false
        elseif not IsSecret(scaled) and scaled ~= nil then
            ok, why = PaintThreat(texs, scaled, DpsColor(scaled), nil)
            pulse = scaled >= 100
        else
            -- Percentage hidden (secret) or missing. Addon code can't run a curve on a
            -- secret, so grade by the coarse status instead (Plater does the same).
            -- No percentage (e.g. only the simple status came back): grade by status,
            -- 3 = you have aggro (red) ... 0 = low threat (green).
            ok, why = PaintThreat(texs, status, not IsSecret(status) and DPS_STATUS[status] or nil, nil)
            pulse = IsSecret(status) or status >= 2
        end
        f.threatWhy = ok and ("shown" .. (why and (" (" .. why .. ")") or "")
            .. (f.threatAlias and (" via " .. f.threatAlias) or "")
            .. (IsSecret(status) and ", status secret" or "")) or "paint failed"
        g:SetShown(ok)
        ShowSpikes(f, ok, pulse)
        f.threatColored = db.threatBars and ok and not tapped and not selRed or false
        if ok then
            -- Text color matches the arrows (scaled % already accounts for the
            -- 110% / 130% pull margin: 100 scaled = you pull).
            local col
            if IsTank() then col = not IsSecret(status) and TANK_STATUS[status] or nil
            elseif not IsSecret(scaled) and type(scaled) == "number" then col = DpsColor(scaled)
            elseif not IsSecret(status) then col = DPS_STATUS[status] end
            SetThreatText(f, u, tanking, raw, scaled, col)
        elseif f.threatText then
            f.threatText:Hide()
        end
    else
        if not live then g:Hide() return end
        g:SetShown(SetThreatTexture(g, UnitThreatSituation(u), THREAT_DPS, threatCurveDps))
    end
end

end -- threat block

-- Fade party/raid members who are out of range (gently, so they stay readable).
local RANGE_FADE = 0.75
local function UpdateRange(f)
    if f.preview or not f.unit or not f:IsVisible() then return end
    local u = f.unit
    if Plain(UnitIsUnit(u, "player")) then f:SetAlpha(1) return end
    local inRange, checked = UnitInRange(u)
    if IsSecret(inRange) then
        if f.SetAlphaFromBoolean then pcall(f.SetAlphaFromBoolean, f, inRange, 1, RANGE_FADE) end
    elseif IsSecret(checked) or checked == false then
        f:SetAlpha(1)
    else
        f:SetAlpha(inRange and 1 or RANGE_FADE)
    end
end

local function UpdateAll()
    for _, f in pairs(frames) do
        if f:IsShown() then UpdateFrame(f) end
    end
    for _, b in ipairs(raidButtons) do
        if b:IsShown() then UpdateFrame(b) end
    end
end

local UNIT_EVENTS = {
    "UNIT_HEALTH", "UNIT_MAXHEALTH", "UNIT_NAME_UPDATE", "UNIT_LEVEL",
    "UNIT_CONNECTION", "UNIT_FACTION", "UNIT_FLAGS", "UNIT_AURA",
    "UNIT_POWER_FREQUENT", "UNIT_MAXPOWER", "UNIT_DISPLAYPOWER",
}

local function RegisterUnitEvents(f)
    f:UnregisterAllEvents()
    f:RegisterEvent("PLAYER_ENTERING_WORLD")
    f:RegisterEvent("GROUP_ROSTER_UPDATE")
    f:RegisterEvent("PLAYER_ROLES_ASSIGNED")
    if not f.unit then return end
    if f.unit ~= "targettarget" then
        for _, e in ipairs(UNIT_EVENTS) do f:RegisterUnitEvent(e, f.unit) end
    end
    if f.unit == "player" then
        f:RegisterEvent("PLAYER_REGEN_DISABLED")
        f:RegisterEvent("PLAYER_REGEN_ENABLED")
    elseif f.unit == "target" then
        f:RegisterEvent("PLAYER_TARGET_CHANGED")
    elseif f.unit == "focus" then
        f:RegisterEvent("PLAYER_FOCUS_CHANGED")
    elseif f.unit == "targettarget" then
        f:RegisterEvent("PLAYER_TARGET_CHANGED")
        f:RegisterUnitEvent("UNIT_TARGET", "target")
    end
end

---------------------------------------------------------------------------
-- Frame construction
---------------------------------------------------------------------------

-- Player / target / party: full-size SAO frame.
local function CreateUnitFrame(cfg, parent)
    local f = CreateFrame("Button", "SAOFrames_" .. cfg.key, parent, "SecureUnitButtonTemplate")
    f.cfg, f.unit = cfg, cfg.unit
    f.kind = cfg.unit == "player" and "player" or cfg.party and "group" or "enemy"
    f:SetSize(PANEL_W, PANEL_H)
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:RegisterForClicks("AnyUp")
    f:RegisterForDrag("LeftButton")
    f:SetAttribute("unit", cfg.unit)
    f:SetAttribute("*type1", "target")
    f:SetAttribute("*type2", "togglemenu")

    AddPanel(f)

    -- Name, vertically centered on the bar's thick section (texture rows 6-46 of 64).
    f.name = f:CreateFontString(nil, "OVERLAY")
    SetFont(f.name, 13, true)
    f.name:SetWidth(BAR_X - 12)
    f.name:SetJustifyH("RIGHT")
    f.name:SetWordWrap(true)
    f.name:SetMaxLines(2)

    AddBar(f, BAR_X, BAR_Y, BAR_W, BAR_H, "Bar", 24)
    if cfg.party or cfg.unit == "player" then
        AddReadyCheck(f, 22, "LEFT", f.badge, "RIGHT", 6, 0) -- just right of the class chip
    end

    -- Party role icon sits between the name and the bar.
    if cfg.party then
        f.roleIcon = f:CreateTexture(nil, "OVERLAY")
        f.roleIcon:SetSize(16, 16)
        f.roleIcon:SetPoint("RIGHT", f.bar, "TOPLEFT", -3, -13)
        f.roleIcon:Hide()
        f.name:SetPoint("RIGHT", f.roleIcon, "LEFT", -4, 0)
        f.name:SetWidth(BAR_X - 35)
    else
        f.name:SetPoint("RIGHT", f.bar, "TOPLEFT", -6, -13)
    end

    AddPowerBar(f, 3, -25, 180, 7, true)

    -- "96 / 100   96%   LV: 27" under the bar's right side.
    AddRaidMark(f, 22, "BOTTOMRIGHT", f.bar, "TOPLEFT", -6, 4) -- raid marker above the name (the cast bar sits above the bar)

    f.lv = f:CreateFontString(nil, "OVERLAY")
    SetFont(f.lv, 12)
    f.lv:SetPoint("TOPRIGHT", f.bar, "TOPRIGHT", -12, -35)

    -- HP % inside the bar (thick part, right side); "cur / max" stays under the bar.
    f.pct = f.barText:CreateFontString(nil, "OVERLAY", nil, 7)
    SetFont(f.pct, 13, true)
    f.pct:SetPoint("LEFT", f.bar, "TOPLEFT", 10, -math.floor(BAR_H * 26 / 64 + 0.5))
    f.pct:SetJustifyH("LEFT")

    -- "cur / max" inside the bar too, right after the %.
    f.hp = f.barText:CreateFontString(nil, "OVERLAY", nil, 7)
    SetFont(f.hp, 11)
    f.hp:SetPoint("LEFT", f.pct, "RIGHT", 8, 0)
    f.hp:SetJustifyH("LEFT")

    local enemyStyle = cfg.unit == "target" or cfg.unit == "focus"
    AddDebuffs(f, cfg.party and DEBUFFS.party or enemyStyle and DEBUFFS.target or DEBUFFS.big, true)
    if enemyStyle then
        -- "THREAT 87%" just above the bar's right end, colored like the arrows.
        f.threatText = f:CreateFontString(nil, "OVERLAY")
        SetFont(f.threatText, 11, true)
        f.threatText:SetPoint("BOTTOMRIGHT", f.bar, "TOPRIGHT", -24, 1)
        f.threatText:SetJustifyH("RIGHT")
        f.threatText:Hide()
        -- Aggro spikes either side of the frame, pulsing outward.
        AddSpikes(f, 44, 28, { "RIGHT", f.bar, "TOPLEFT", -(BAR_X - 12) - 10, -13 }, { "LEFT", f.badge, "RIGHT", 4, 0 }, 5)
        f.spikeHugsName = true
    end
    if not cfg.party then
        f.buffs = AddAuraRow(f, enemyStyle and BUFFS_TARGET or BUFFS, true, true)
        f.auraOrder = cfg.unit == "player" and { "buffs", "debuffs" } or { "debuffs", "buffs" }
    end
    -- Rows use the game's aura containers when available (fixed row slots).
    if cfg.party then
        AttachAuraContainers(f, {
            { kind = "debuffs", size = 28, max = 6, timer = true, point = { "TOPLEFT", f, "TOPRIGHT", 4, -4 } },
        })
    elseif enemyStyle then
        -- Aura rows hang off an invisible anchor just under the bar's "LV" line, so they
        -- can all drop below the target-of-target frame while it's shown.
        local anchor = CreateFrame("Frame", nil, f)
        anchor:SetSize(1, 1)
        anchor:SetPoint("TOPLEFT", f.bar, "BOTTOMLEFT", 0, -AURA_GAP)
        f.auraAnchor = anchor
        AttachAuraContainers(f, {
            { kind = "debuffs", size = 24, max = 7, timer = true, point = { "TOPLEFT", anchor, "TOPLEFT", 0, 0 } },
            -- moves up into the debuff row's place while the target has no debuffs
            { kind = "buffs",   size = 22, max = 7, timer = true, point = { "TOPLEFT", anchor, "TOPLEFT", 0, -40 },
              emptyAbove = { "TOPLEFT", anchor, "TOPLEFT", 0, 0 } },
        })
    else
        AttachAuraContainers(f, {
            { kind = "buffs",   size = 22, max = 12, timer = true, point = { "TOPLEFT", f.bar, "BOTTOMLEFT", 0, -AURA_GAP } },
            { kind = "debuffs", size = 24, max = 8,  timer = true, point = { "TOPLEFT", f.bar, "BOTTOMLEFT", 0, -AURA_GAP - 38 },
              emptyAbove = { "TOPLEFT", f.bar, "BOTTOMLEFT", 0, -AURA_GAP } },
        })
    end

    -- Drag handle shown while unlocked (sits above everything so it always catches the drag).
    local m = CreateFrame("Frame", nil, f)
    m:SetAllPoints()
    m:SetFrameLevel(f:GetFrameLevel() + 30)
    local mt = m:CreateTexture(nil, "OVERLAY")
    mt:SetAllPoints()
    mt:SetColorTexture(0.3, 0.7, 1, 0.3)
    local ml = m:CreateFontString(nil, "OVERLAY")
    SetFont(ml, 14)
    ml:SetPoint("CENTER")
    ml:SetText((cfg.party and "Party" or cfg.key == "player" and "Player" or cfg.key == "focus" and "Focus" or "Target") .. " - drag to move")
    m:EnableMouse(true)
    m:RegisterForDrag("LeftButton")
    m:Hide()
    f.mover = m

    AddTooltip(f)
    RegisterUnitEvents(f)
    f:SetScript("OnEvent", OnEvent)
    f:HookScript("OnShow", UpdateFrame)

    frames[cfg.key] = f
    return f
end

---------------------------------------------------------------------------
-- Nameplates: SAO-style plate drawn on top of each Blizzard nameplate (whose own
-- art is faded out). Clicks still go to the Blizzard plate, so targeting works as usual.
---------------------------------------------------------------------------

local PLATE_BAR_W, PLATE_BAR_H = 160, 18
local PLATE_DEBUFFS = { max = 5, size = 18, timerInside = true }
local plateByUnit = {}
-- Bookkeeping about Blizzard's plate frames lives here, never as fields on their frames.
local alphaHooked = setmetatable({}, { __mode = "k" })
local settingAlpha = setmetatable({}, { __mode = "k" })
ns.plateOf = setmetatable({}, { __mode = "k" }) -- Blizzard plate frame -> our SAO plate (never a field on their frame)
local PLATE_FILTERS = { "HARMFUL", "HARMFUL|PLAYER", "HELPFUL" }

-- Cast bar: thin slanted bar (power-bar art) with spell icon and name.
-- Gold = interruptible, grey = can't be interrupted, red flash = interrupted.
local AddCastBar, CAST_EVENTS, OnCastEvent, CheckCasting -- defined in the cast bar block below
do
local CAST_OK, CAST_LOCKED, CAST_FAIL = { 1, 0.75, 0.1 }, { 0.6, 0.6, 0.6 }, { 0.9, 0.15, 0.15 }

AddCastBar = function(f, x, y, w, h)
    local cb = CreateFrame("StatusBar", nil, f)
    cb:SetPoint("TOPLEFT", f.bar, "TOPLEFT", x, y)
    cb:SetSize(w, h)
    cb:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")

    local bg = cb:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture(MEDIA .. "Power")
    bg:SetVertexColor(0, 0, 0, 0.7)

    local mask = cb:CreateMaskTexture()
    mask:SetAllPoints()
    mask:SetTexture(MEDIA .. "PowerMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    cb:GetStatusBarTexture():AddMaskTexture(mask)

    local border = cb:CreateTexture(nil, "OVERLAY")
    border:SetAllPoints()
    border:SetTexture(MEDIA .. "PowerBorder")
    border:SetVertexColor(0.88, 0.92, 0.96, 0.85)

    -- Full-width red overlay for the "Interrupted" flash (independent of the bar value).
    cb.flash = cb:CreateTexture(nil, "ARTWORK", nil, 3)
    cb.flash:SetAllPoints()
    cb.flash:SetTexture(MEDIA .. "PowerMask")
    cb.flash:SetVertexColor(unpack(CAST_FAIL))
    cb.flash:Hide()

    cb.icon = cb:CreateTexture(nil, "ARTWORK")
    cb.icon:SetSize(h + 4, h + 4)
    cb.icon:SetPoint("RIGHT", cb, "LEFT", -2, 0)
    cb.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    cb.text = cb:CreateFontString(nil, "OVERLAY")
    SetFont(cb.text, 8, true)
    cb.text:SetPoint("CENTER", cb, "CENTER", 0, 0)
    cb.text:SetWidth(w - 6)
    cb.text:SetWordWrap(false)

    -- Plain timings are driven here; secret timings use the client's own timer.
    cb.CastOnUpdate = function(self)
        if not self.plainTiming then self:SetScript("OnUpdate", nil) return end
        local now = GetTime() * 1000
        if now >= self.endMS then self.plainTiming = false; self:SetScript("OnUpdate", nil); self:Hide() return end
        self:SetValue(self.channel and (self.endMS - now) or (now - self.startMS))
    end
    cb:Hide()
    f.cast = cb
end

local COL_CAST_LOCKED, COL_CAST_OK = CreateColor(unpack(CAST_LOCKED)), CreateColor(unpack(CAST_OK))

local function SetCastColor(cb, notInterruptible)
    local tex = cb:GetStatusBarTexture()
    if IsSecret(notInterruptible) then
        local ok = tex.SetVertexColorFromBoolean and pcall(tex.SetVertexColorFromBoolean, tex, notInterruptible,
            COL_CAST_LOCKED, COL_CAST_OK)
        if not ok then cb:SetStatusBarColor(unpack(CAST_OK)) end
    else
        cb:SetStatusBarColor(unpack(notInterruptible and CAST_LOCKED or CAST_OK))
    end
end

local function StartCast(f, channel)
    local cb, u = f.cast, f.unit
    if not cb or not u then return end
    local name, tex, startMS, endMS, notInt, _
    if channel then
        name, _, tex, startMS, endMS, _, notInt = UnitChannelInfo(u)
    else
        name, _, tex, startMS, endMS, _, _, notInt = UnitCastingInfo(u)
    end
    if not IsSecret(name) and name == nil then cb:Hide() return end

    cb.channel, cb.interruptedAt = channel, nil
    pcall(cb.icon.SetTexture, cb.icon, tex)
    pcall(cb.text.SetText, cb.text, name)
    SetCastColor(cb, notInt)

    cb.flash:Hide()
    cb.plainTiming = false
    cb:SetScript("OnUpdate", nil)
    local durFn = channel and UnitChannelDuration or UnitCastingDuration
    local SB = Enum and Enum.StatusBarTimerDirection
    local timed = durFn and cb.SetTimerDuration and pcall(function()
        local dir = SB and (channel and SB.RemainingTime or SB.ElapsedTime)
        local interp = Enum.StatusBarInterpolation and Enum.StatusBarInterpolation.Immediate
        cb:SetTimerDuration(durFn(u), interp, dir)
    end)
    if not timed then
        if not IsSecret(startMS) and not IsSecret(endMS) and startMS and endMS then
            cb.plainTiming, cb.startMS, cb.endMS = true, startMS, endMS
            cb:SetScript("OnUpdate", cb.CastOnUpdate)
            cb:SetMinMaxValues(0, endMS - startMS)
            cb:SetValue(channel and (endMS - startMS) or 0)
        else
            cb:SetMinMaxValues(0, 1); cb:SetValue(1)
        end
    end
    cb:Show()
end

local function StopCast(f, interrupted)
    local cb = f.cast
    if not cb or not cb:IsShown() then return end
    if interrupted then
        cb.plainTiming = false
        cb.interruptedAt = GetTime()
        cb.flash:Show()
        cb.text:SetText("Interrupted")
        local stamp = cb.interruptedAt
        C_Timer.After(0.6, function() if cb.interruptedAt == stamp then cb:Hide() end end)
    elseif not cb.interruptedAt then
        cb.plainTiming = false
        cb:Hide()
    end
end

CAST_EVENTS = {
    UNIT_SPELLCAST_START = "start", UNIT_SPELLCAST_DELAYED = "start",
    UNIT_SPELLCAST_CHANNEL_START = "channel", UNIT_SPELLCAST_CHANNEL_UPDATE = "channel",
    UNIT_SPELLCAST_STOP = "stop", UNIT_SPELLCAST_FAILED = "stop", UNIT_SPELLCAST_CHANNEL_STOP = "stop",
    UNIT_SPELLCAST_INTERRUPTED = "interrupted",
    UNIT_SPELLCAST_INTERRUPTIBLE = "refresh", UNIT_SPELLCAST_NOT_INTERRUPTIBLE = "refresh",
    UNIT_SPELLCAST_EMPOWER_START = "channel", UNIT_SPELLCAST_EMPOWER_UPDATE = "channel", UNIT_SPELLCAST_EMPOWER_STOP = "stop",
}

OnCastEvent = function(f, event)
    local kind = CAST_EVENTS[event]
    if kind == "start" then StartCast(f, false)
    elseif kind == "channel" then StartCast(f, true)
    elseif kind == "stop" then StopCast(f, false)
    elseif kind == "interrupted" then StopCast(f, true)
    elseif kind == "refresh" and f.cast and f.cast:IsShown() then StartCast(f, f.cast.channel)
    end
end

-- A unit that was already casting when its plate appeared.
CheckCasting = function(f)
    if not f.cast then return end
    f.cast:Hide()
    local name = UnitCastingInfo(f.unit)
    if IsSecret(name) or name ~= nil then StartCast(f, false) return end
    name = UnitChannelInfo(f.unit)
    if IsSecret(name) or name ~= nil then StartCast(f, true) end
end

end -- cast bar block

local function CreatePlate(plate)
    local f = CreateFrame("Frame", nil, plate)
    f:SetSize(PLATE_BAR_W + 30, 46)
    f:SetPoint("CENTER", plate, "CENTER", 8, 0)
    f:EnableMouse(false)
    f.kind, f.compact, f.isPlate = "enemy", true, true

    f.name = f:CreateFontString(nil, "OVERLAY")
    SetFont(f.name, 10, true)
    f.name:SetPoint("TOPLEFT", 4, 0)
    f.name:SetWidth(PLATE_BAR_W - 34)
    f.name:SetJustifyH("LEFT")
    f.name:SetWordWrap(false)

    -- Threat % above the bar's right end (colored like the aggro arrows).
    f.threatText = f:CreateFontString(nil, "OVERLAY")
    SetFont(f.threatText, 9)
    f.threatText:SetPoint("TOPRIGHT", f, "TOPLEFT", 4 + PLATE_BAR_W - 6, -1)
    f.threatText:SetJustifyH("RIGHT")
    f.threatText:Hide()

    AddBar(f, 4, -13, PLATE_BAR_W, PLATE_BAR_H, "Bar", nil, 5)

    -- HP % inside the bar, on the thick part just left of the level badge.
    f.hp = f.barText:CreateFontString(nil, "OVERLAY", nil, 7)
    SetFont(f.hp, 9, true)
    f.hp:SetPoint("LEFT", f.bar, "TOPLEFT", 6, -math.floor(PLATE_BAR_H * 26 / 64 + 0.5))
    f.hp:SetJustifyH("LEFT")

    -- Level badge: roomy enough for two/three digits, centred on the bar's thick part
    -- (rows 6-46 of the 64px texture -> about 7px down at this bar height).
    f.badge:SetSize(30, 14)
    f.badge:ClearAllPoints()
    f.badge:SetPoint("LEFT", f.bar, "TOPRIGHT", -6, -math.floor(PLATE_BAR_H * 26 / 64 + 0.5))

    f.levelText = f.bar:CreateFontString(nil, "OVERLAY", nil, 6)
    f.levelText:SetFont(ns.fontPath or BOLD_FONT, 9, "OUTLINE")
    if not f.levelText:GetFont() then f.levelText:SetFont(STANDARD_TEXT_FONT, 9, "OUTLINE") end
    f.levelText:SetShadowOffset(1, -1)
    f.levelText:SetShadowColor(0, 0, 0, 1)
    f.levelText:SetTextColor(1, 1, 1)
    f.levelText:SetDrawLayer("OVERLAY", 6)
    f.levelText:SetPoint("CENTER", f.badge, "CENTER", 1, 0)

    AddSpikes(f, 34, 22, { "RIGHT", f.bar, "LEFT", -1, 3 }, { "LEFT", f.badge, "RIGHT", 2, 0 }, 4)
    -- raid marker above the plate's right end (debuffs grow up from the left)
    AddRaidMark(f, 20, "BOTTOMRIGHT", f, "TOPRIGHT", 0, 2)

    AddCastBar(f, 16, -15, PLATE_BAR_W - 22, 10)

    f.debuffs = AddAuraRow(f, PLATE_DEBUFFS, true, false)
    f.debuffs[1]:SetPoint("BOTTOMLEFT", f, "TOPLEFT", 4, 3)
    if AttachAuraContainers(f, {
        { kind = "debuffs", role = "enemy", size = 18, max = 5, timer = true, timerInside = true, growUp = true,
          point = { "BOTTOMLEFT", f, "TOPLEFT", 4, 3 } },
        -- Friendly units: one tidy line right under the bar. Buffs fill from the left
        -- edge; debuffs (dispel-colored, with timers) fill from the right edge inward.
        -- Buff timers are off: long buffs ("35 m") don't fit inside a small icon.
        { kind = "debuffs", role = "friendly", size = 16, max = 4, timer = true, timerInside = true,
          growLeft = true, point = { "TOPRIGHT", f.bar, "BOTTOMRIGHT", 0, -3 } },
        { kind = "buffs", role = "friendly", size = 16, max = 4,
          point = { "TOPLEFT", f.bar, "BOTTOMLEFT", 0, -3 } },
    }, UIParent) then
        for _, h in ipairs(f.auraHolders) do h:SetFrameStrata("MEDIUM"); h:Hide() end
    end

    local uf = plate.UnitFrame
    if uf and not alphaHooked[uf] then
        alphaHooked[uf] = true
        hooksecurefunc(uf, "SetAlpha", function(self, a)
            local sp = ns.plateOf[plate]
            if settingAlpha[self] or not sp or not sp:IsShown() then return end
            if IsSecret(a) or a ~= 0 then
                settingAlpha[self] = true
                pcall(self.SetAlpha, self, 0)
                settingAlpha[self] = nil
            end
        end)
    end

    ns.plateOf[plate] = f
    return f
end

local function PlateLevel(f, u)
    f.levelText:SetTextColor(LevelColor(u))
    local lv = UnitLevel(u)
    if IsSecret(lv) then pcall(f.levelText.SetText, f.levelText, lv) return end
    f.levelText:SetText((not lv or lv <= 0) and SkullLevel() or lv)
end

-- Current target's plate pops a little: bigger and with a bright outline.
local function PlateTargetHighlight(f)
    local isTarget = Plain(UnitIsUnit(f.unit, "target"))
    if isTarget == nil and C_NamePlate then
        local ok, tp = pcall(C_NamePlate.GetNamePlateForUnit, "target", false)
        isTarget = ok and tp ~= nil and tp == f:GetParent()
    end
    f:SetScale(isTarget and 1.15 or 1) -- our own plain frame: allowed in combat
    f.auraDirty = true -- re-sync the aura rows' scale with the plate
    f:SetAlpha(isTarget and 1 or 0.9)
end

local function HideBlizzardPlateArt(f)
    local uf = f:GetParent().UnitFrame
    if uf then pcall(uf.SetAlpha, uf, 0) end
end

local function UpdatePlate(f)
    -- Fade Blizzard's plate art first, whatever else happens below.
    HideBlizzardPlateArt(f)
    if not f.unit then return end
    local exists = UnitExists(f.unit)
    if not IsSecret(exists) and not exists then return end
    f.ready = true
    UpdateFrame(f)
    PlateLevel(f, f.unit)
    PlateTargetHighlight(f)
    UpdateThreat(f)
end

local function OnPlateAdded(unit)
    if Plain(UnitIsUnit(unit, "player")) then return end
    local ok, plate = pcall(C_NamePlate.GetNamePlateForUnit, unit, false)
    if not ok or not plate then
        -- Forbidden plate (e.g. friendlies in dungeons): the game won't hand it to addons.
        ns.forbiddenPlates = (ns.forbiddenPlates or 0) + 1
        ns.lastForbidden = Plain(UnitName(unit)) or unit
        return
    end
    local f = ns.plateOf[plate] or CreatePlate(plate)
    if f.unit and f.unit ~= unit and plateByUnit[f.unit] == f then plateByUnit[f.unit] = nil end
    f.unit = unit
    f.ready = nil
    plateByUnit[unit] = f
    -- A plate is recycled between units: wipe the last unit's text and keep the plate
    -- invisible until this unit's data has been drawn (UpdatePlate fades it in).
    f.name:SetText(""); f.hp:SetText(""); f.levelText:SetText("")
    if f.threatText then f.threatText:Hide() end
    f:SetAlpha(0)
    f:Show()
    HideBlizzardPlateArt(f)
    if f.auraHolders then
        f.forceAuraUnit = true
        for _, h in ipairs(f.auraHolders) do h:Hide() end -- shown again once the unit is known
    end
    -- Draw above Blizzard's plate layer, so its art can never cover ours.
    local base = plate.UnitFrame or plate
    f:SetFrameLevel(base:GetFrameLevel() + 20)
    UpdatePlate(f)
    CheckCasting(f)
end

local function OnPlateRemoved(unit)
    local f = plateByUnit[unit]
    plateByUnit[unit] = nil
    iconCache[unit] = nil
    for _, flt in ipairs(PLATE_FILTERS) do listCache[unit .. "|" .. flt] = nil end
    if f then
        f.unit = nil
        f.cacheKeep = nil
        f:Hide()
        f:SetScale(1) -- a recycled plate must not keep the old target's enlargement
        if f.spikes then ShowSpikes(f, false) end
        if f.threatText then f.threatText:Hide() end
        if f.threatGlow then f.threatGlow:Hide() end
        if f.cast then f.cast.plainTiming = false; f.cast.interruptedAt = nil; f.cast:Hide() end
        f.threatColored = false
        if f.auraHolders then
            for _, h in ipairs(f.auraHolders) do SetContainerUnit(h, nil); h:Hide() end
        end
        local uf = f:GetParent().UnitFrame
        if uf then pcall(uf.SetAlpha, uf, 1) end
    end
end

-- Friendly nameplates are a Blizzard setting (CVars). The game hides them by default
-- and shows friendly units as name-only labels, which addons can't restyle.
-- CVars can only change out of combat; unknown CVar names are ignored safely.
-- Game settings (CVars) are saved by the game itself, so they'd outlive the addon. Remember
-- each one's value from before SAO Frames first touched it and put it back at logout, so
-- disabling or removing the addon leaves nameplates exactly as the player had them.
local function SetCVarSafe(name, value)
    local get = C_CVar and C_CVar.GetCVar or GetCVar
    if not db.cvarOriginal then
        -- Earlier versions already changed these without remembering the old values, so the
        -- current ones aren't the player's: start from the game's defaults for them.
        db.cvarOriginal = {
            nameplateShowOnlyNames = "0",
            nameplateShowOnlyNameForFriendlyPlayerUnits = "0",
            nameplateUseClassColorForFriendlyPlayerUnitNames = "0",
        }
    end
    if db.cvarOriginal[name] == nil and get then
        local ok, cur = pcall(get, name)
        if ok and type(cur) == "string" then db.cvarOriginal[name] = cur end
    end
    local fn = C_CVar and C_CVar.SetCVar or SetCVar
    if fn then pcall(fn, name, value) end
end

function ns.RestoreCVars()
    local fn = C_CVar and C_CVar.SetCVar or SetCVar
    if not (fn and db and db.cvarOriginal) then return end
    for name, value in pairs(db.cvarOriginal) do pcall(fn, name, value) end
end

local function ApplyFriendlyPlateCVars()
    if InCombatLockdown() or not db.nameplates then return end
    SetCVarSafe("nameplateShowFriends", db.friendlyPlates and "1" or "0")
    SetCVarSafe("nameplateShowFriendlyNPCs", db.friendlyNPCs and "1" or "0")
    if db.friendlyPlates or db.friendlyNPCs then
        -- Health bars on friendly plates everywhere (not name-only). Inside dungeons/raids
        -- the game keeps friendly plates locked to its own default look, but they still
        -- show health; outside, they get the SAO style.
        SetCVarSafe("nameplateShowOnlyNames", "0")                       -- older clients
        SetCVarSafe("nameplateShowOnlyNameForFriendlyPlayerUnits", "0")  -- 12.x name
        db.onlyNamesForced = nil
    end
    -- Friendly plates click-through: their (large) hit boxes otherwise catch clicks
    -- meant for the mob or the world behind a party member. Huge positive insets
    -- shrink the friendly hit area to nothing; 0s restore the game's default.
    if C_NamePlateManager and C_NamePlateManager.SetNamePlateHitTestInsets then
        local friendly = Enum and Enum.NamePlateType and Enum.NamePlateType.Friendly or 0
        local n = db.friendlyClickThrough ~= false and 10000 or 0
        if n > 0 or ns.clickThroughSet then
            ns.clickThroughOk = pcall(C_NamePlateManager.SetNamePlateHitTestInsets, friendly, n, n, n, n)
            ns.clickThroughSet = n > 0 or nil
        end
    end
    -- SAO font on the game's own nameplate text too (the locked friendly plates in
    -- dungeons use these shared fonts; our own plates set their fonts directly).
    if ns.fontPath then
        for _, name in ipairs({ "SystemFont_NamePlate", "SystemFont_NamePlate_Outlined", "SystemFont_NamePlateLevel" }) do
            local fo = _G[name]
            if fo and fo.GetFont and fo.SetFont then
                local okF, _, size, flags = pcall(fo.GetFont, fo)
                if okF then pcall(fo.SetFont, fo, ns.fontPath, size or 10, flags or "OUTLINE") end
            end
        end
    end
end

local function InitNameplates()
    if not db.nameplates or not C_NamePlate then return end
    ApplyFriendlyPlateCVars()
    local ev = CreateFrame("Frame")
    ev:RegisterEvent("NAME_PLATE_UNIT_ADDED")
    ev:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
    ev:RegisterEvent("PLAYER_TARGET_CHANGED")
    ev:RegisterEvent("PLAYER_REGEN_ENABLED")
    ev:RegisterEvent("PLAYER_LEVEL_UP") -- re-color difficulty levels
    ev:RegisterEvent("PLAYER_ENTERING_WORLD")  -- dungeon in/out: friendly plate style
    ev:RegisterEvent("PLAYER_LOGOUT")          -- put the player's own nameplate settings back
    ev:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    ev.cvarsApplied = not InCombatLockdown()
    for _, e in ipairs({ "UNIT_HEALTH", "UNIT_MAXHEALTH", "UNIT_AURA", "UNIT_NAME_UPDATE",
                         "UNIT_LEVEL", "UNIT_FACTION", "UNIT_THREAT_LIST_UPDATE" }) do
        ev:RegisterEvent(e)
    end
    for e in pairs(CAST_EVENTS) do pcall(ev.RegisterEvent, ev, e) end
    ev:SetScript("OnEvent", function(_, event, unit)
        if event == "NAME_PLATE_UNIT_ADDED" then
            local ok, err = pcall(OnPlateAdded, unit)
            if not ok then LogError("plate added: " .. tostring(err)) end
        elseif event == "NAME_PLATE_UNIT_REMOVED" then
            OnPlateRemoved(unit)
        elseif event == "PLAYER_LOGOUT" then
            ns.RestoreCVars()
        elseif event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
            if InCombatLockdown() then ev.cvarsApplied = false else ApplyFriendlyPlateCVars() end
        elseif event == "PLAYER_LEVEL_UP" then
            -- UnitLevel("player") lags the event slightly; refresh a moment later.
            C_Timer.After(0.5, function()
                for _, pl in pairs(plateByUnit) do PlateLevel(pl, pl.unit) end
                for _, fr in pairs(frames) do if fr:IsShown() then UpdateFrame(fr) end end
            end)
        elseif event == "PLAYER_TARGET_CHANGED" or event == "PLAYER_REGEN_ENABLED" then
            for _, f in pairs(plateByUnit) do if f.ready then PlateTargetHighlight(f) end end
            if event == "PLAYER_REGEN_ENABLED" and not ev.cvarsApplied then
                ev.cvarsApplied = true
                ApplyFriendlyPlateCVars()
            end
        else
            local f = unit and plateByUnit[unit]
            if not f then return end
            if CAST_EVENTS[event] then
                OnCastEvent(f, event)
            elseif event == "UNIT_HEALTH" or event == "UNIT_MAXHEALTH" then
                UpdateHealth(f)
            elseif event == "UNIT_AURA" then
                f.auraDirty = true
            elseif event == "UNIT_THREAT_LIST_UPDATE" then
                UpdateThreat(f)
            else
                UpdatePlate(f)
            end
        end
    end)
    -- Plate health: fast poll (~30x a second, same as the unit frames) so the %
    -- keeps up in combat.
    do
        local poll, acc = CreateFrame("Frame"), 0
        poll:SetScript("OnUpdate", function(_, elapsed)
            acc = acc + elapsed
            if acc < 0.033 then return end
            acc = 0
            for _, f in pairs(plateByUnit) do
                if f.ready then
                    local ok, err = pcall(UpdateHealth, f)
                    if not ok then LogError("plate health: " .. tostring(err)) end
                end
            end
        end)
    end
    -- Threat and health catch-up for every visible plate.
    C_Timer.NewTicker(0.2, function()
        for _, f in pairs(plateByUnit) do
            HideBlizzardPlateArt(f)
            if not f.ready then
                local ex = UnitExists(f.unit)
                if IsSecret(ex) or ex then
                    f.ready = true
                    local okP, errP = pcall(UpdatePlate, f)
                    if not okP then LogError("plate update: " .. tostring(errP)) end
                end
            end
            -- pcall each step so one bad plate can't stop updates for every plate
            -- (plate health also has its own faster poll below)
            local ok, err = pcall(UpdateThreat, f)
            if not ok then LogError("plate threat: " .. tostring(err)) end
            -- The plate's own scale also changes without our SetScale (distance /
            -- selected-plate scaling, in combat too): re-sync the aura rows then.
            if f.auraHolders and not f.auraDirty then
                local okS, es = pcall(f.GetEffectiveScale, f)
                if okS and not IsSecret(es) and es and math.abs(es - (f.auraEffScale or 0)) > 0.005 then
                    f.auraEffScale = es
                    f.auraDirty = true
                end
            end
            if f.auraDirty then
                f.auraDirty = nil
                local okA, errA = pcall(UpdateAuras, f)
                if not okA then LogError("plate auras: " .. tostring(errA)) end
            end
        end
    end)
    -- Plates already on screen (e.g. after /reload).
    for _, plate in ipairs(C_NamePlate.GetNamePlates(false) or {}) do
        local u = plate.namePlateUnitToken or (plate.UnitFrame and plate.UnitFrame.unit)
        if u then
            local ok, err = pcall(OnPlateAdded, u)
            if not ok then LogError("plate added: " .. tostring(err)) end
        end
    end
end

-- Target of target: compact frame (raid-style bar) right under the target's health bar
-- frame. It moves with the target frame.
local TOT_W = 170
local TOT_H = 36

local function CreateToTFrame(cfg)
    local f = CreateFrame("Button", "SAOFrames_" .. cfg.key, UIParent, "SecureUnitButtonTemplate")
    f.cfg, f.unit, f.kind, f.compact = cfg, cfg.unit, "tot", true
    f:SetSize(TOT_W, TOT_H)
    f:SetClampedToScreen(true)
    f:RegisterForClicks("AnyUp")
    f:RegisterForDrag("LeftButton")
    f:SetAttribute("unit", cfg.unit)
    f:SetAttribute("*type1", "target")
    f:SetAttribute("*type2", "togglemenu")

    AddPanel(f)

    f.name = f:CreateFontString(nil, "OVERLAY")
    SetFont(f.name, 11, true)
    f.name:SetPoint("TOPLEFT", 5, -3)
    f.name:SetWidth(TOT_W - 56)
    f.name:SetJustifyH("LEFT")
    f.name:SetWordWrap(false)

    f.hp = f:CreateFontString(nil, "OVERLAY")
    SetFont(f.hp, 10)
    f.hp:SetPoint("TOPRIGHT", -24, -4)
    f.hp:SetJustifyH("RIGHT")

    AddBar(f, 4, -18, TOT_W - 28, RAID_BAR_H, "RaidBar")
    AddRaidMark(f, 14, "LEFT", f.bar, "RIGHT", 20, 0)

    local m = CreateFrame("Frame", nil, f)
    m:SetAllPoints()
    m:SetFrameLevel(f:GetFrameLevel() + 30)
    local mt = m:CreateTexture(nil, "OVERLAY")
    mt:SetAllPoints()
    mt:SetColorTexture(0.3, 0.7, 1, 0.3)
    local ml = m:CreateFontString(nil, "OVERLAY")
    SetFont(ml, 10)
    ml:SetPoint("CENTER")
    ml:SetText("Target of target")
    m:EnableMouse(true)
    m:RegisterForDrag("LeftButton")
    m:Hide()
    f.mover = m

    AddTooltip(f)
    RegisterUnitEvents(f)
    f:SetScript("OnEvent", OnEvent)
    f:HookScript("OnShow", UpdateFrame)

    frames[cfg.key] = f
    return f
end

-- Raid: compact SAO frame (name + current HP on top, angled bar below).
-- Called by the secure group header for each button it spawns.
local function StyleRaidButton(b)
    b.kind, b.compact = "group", true
    if not InCombatLockdown() then b:RegisterForClicks("AnyUp") end
    AddPanel(b)

    b.name = b:CreateFontString(nil, "OVERLAY")
    SetFont(b.name, 10, true)
    b.roleIcon = b:CreateTexture(nil, "OVERLAY")
    b.roleIcon:SetSize(11, 11)
    b.roleIcon:SetPoint("TOPLEFT", 4, -3)
    b.roleIcon:Hide()
    b.name:SetPoint("TOPLEFT", 17, -3)
    b.name:SetWidth(RAID_W - 71)
    b.name:SetJustifyH("LEFT")
    b.name:SetWordWrap(false)

    b.hp = b:CreateFontString(nil, "OVERLAY")
    SetFont(b.hp, 10)
    b.hp:SetPoint("TOPRIGHT", -24, -4)
    b.hp:SetJustifyH("RIGHT")

    AddBar(b, 4, -18, RAID_BAR_W, RAID_BAR_H, "RaidBar")
    AddPowerBar(b, 1, -RAID_BAR_H - 1, 80, 4)
    AddReadyCheck(b, 18, "CENTER") -- right on top of the raid member
    AddRaidMark(b, 13, "TOPRIGHT", b, "TOPRIGHT", -6, -2)
    AddDebuffs(b, DEBUFFS.raid, false)
    AttachAuraContainers(b, {
        { kind = "debuffs", size = 12, max = 4, timer = false, point = { "TOPLEFT", b, "TOPLEFT", 5, -39 } },
    })
    AddTooltip(b)

    b:SetScript("OnEvent", OnEvent)
    b:HookScript("OnShow", UpdateFrame)
    b:HookScript("OnAttributeChanged", function(self, name, value)
        if name ~= "unit" or value == self.unit then return end
        self.unit = value
        self.cacheKeep = nil
        self.forceAuraUnit = true
        RegisterUnitEvents(self)
        if value then UpdateFrame(self) end
    end)
    b.unit = b:GetAttribute("unit")
    RegisterUnitEvents(b)

    raidButtons[#raidButtons + 1] = b
end

local function CreateRaid()
    raidAnchor = CreateFrame("Frame", "SAOFrames_RaidAnchor", UIParent)
    raidAnchor:SetSize(5 * (RAID_W + RAID_GAP), 8 * (RAID_H + RAID_GAP))
    raidAnchor:SetMovable(true)
    raidAnchor:SetClampedToScreen(true)
    raidAnchor:SetFrameStrata("LOW") -- keep party previews clickable on top of it
    raidAnchor:RegisterForDrag("LeftButton")

    -- Placeholder shown while unlocked so the raid block can be positioned.
    local ph = raidAnchor:CreateTexture(nil, "BACKGROUND")
    ph:SetAllPoints()
    ph:SetColorTexture(0.3, 0.7, 1, 0.18)
    local label = raidAnchor:CreateFontString(nil, "OVERLAY")
    SetFont(label, 16)
    label:SetPoint("CENTER")
    label:SetText("SAO Raid Frames\n(drag to move)")
    raidAnchor.placeholder = { ph, label }

    -- One secure header per raid group, so each group always gets its own row
    -- (5 members left to right, groups 1-8 stacked downward).
    for g = 1, 8 do
        local h = CreateFrame("Frame", "SAOFrames_RaidGroup" .. g, UIParent, "SecureGroupHeaderTemplate")
        h:SetPoint("TOPLEFT", raidAnchor, "TOPLEFT", 0, -(g - 1) * (RAID_H + RAID_GAP))
        h.InitButton = function(_, name) StyleRaidButton(_G[name]) end
        -- initialConfigFunction before template, so the first child is always configured.
        h:SetAttribute("initialConfigFunction", ([[
            self:SetWidth(%d)
            self:SetHeight(%d)
            self:SetAttribute("*type1", "target")
            self:SetAttribute("*type2", "togglemenu")
            self:GetParent():CallMethod("InitButton", self:GetName())
        ]]):format(RAID_W, RAID_H))
        h:SetAttribute("groupFilter", tostring(g)) -- before showRaid, in case the header is visible
        h:SetAttribute("showRaid", true)
        h:SetAttribute("showParty", false)
        h:SetAttribute("showPlayer", true)
        h:SetAttribute("point", "LEFT")
        h:SetAttribute("xOffset", RAID_GAP)
        -- One column of 5: caps the pre-spawn below at 5 buttons (without it a full
        -- group at login/reload builds unitCount + 5 = 10).
        h:SetAttribute("unitsPerColumn", 5)
        h:SetAttribute("maxColumns", 1)
        h:SetAttribute("template", "SecureUnitButtonTemplate")

        -- Spawn this group's 5 buttons now (out of combat) so none are created mid-fight.
        h:SetAttribute("startingIndex", -4)
        h:Show()
        h:SetAttribute("startingIndex", 1)

        RegisterAttributeDriver(h, "state-visibility", "[group:raid] show; hide")
        raidHeaders[g] = h
    end
end

---------------------------------------------------------------------------
-- Positioning, locking, scale
---------------------------------------------------------------------------

-- Positions are saved in UIParent units (ui = true) so size changes don't move frames.
local function ApplyPoint(region, key, default)
    local p = db.pos[key] or default
    local s = p.ui and region:GetScale() or 1
    region:ClearAllPoints()
    region:SetPoint(p[1], UIParent, p[2], p[3] / s, p[4] / s)
end

local function SavePoint(region, key)
    local point, _, rel, x, y = region:GetPoint(1)
    local s = region:GetScale()
    db.pos[key] = { point, rel, x * s, y * s, ui = true }
end

---------------------------------------------------------------------------
-- Alignment grid (shown while unlocked) and snap-to-grid
---------------------------------------------------------------------------

local UpdateGrid, SnapToGrid -- defined in the grid block below
do
local grid

local function BuildGrid()
    grid = grid or CreateFrame("Frame", "SAOFrames_Grid", UIParent)
    grid:SetAllPoints(UIParent)
    grid:SetFrameStrata("BACKGROUND")
    grid.lines = grid.lines or {}
    for _, t in ipairs(grid.lines) do t:Hide() end

    local n, size = 0, db.gridSize
    local w, h = UIParent:GetWidth(), UIParent:GetHeight()
    local function Line(isCenter)
        n = n + 1
        local t = grid.lines[n] or grid:CreateTexture(nil, "BACKGROUND")
        grid.lines[n] = t
        t:ClearAllPoints()
        if isCenter then t:SetColorTexture(1, 0.35, 0.35, 0.55) else t:SetColorTexture(1, 1, 1, 0.1) end
        if t.SetSnapToPixelGrid then t:SetSnapToPixelGrid(false); t:SetTexelSnappingBias(0) end
        t:Show()
        return t
    end
    -- Lines are laid out from the screen center so the center lines are exact.
    for x = 0, w / 2, size do
        for _, sign in ipairs(x == 0 and { 1 } or { 1, -1 }) do
            local t = Line(x == 0)
            t:SetSize((PixelUtil and PixelUtil.GetNearestPixelSize(1, grid:GetEffectiveScale(), 1) or 1), h)
            t:SetPoint("CENTER", UIParent, "CENTER", sign * x, 0)
        end
    end
    for y = 0, h / 2, size do
        for _, sign in ipairs(y == 0 and { 1 } or { 1, -1 }) do
            local t = Line(y == 0)
            t:SetSize(w, (PixelUtil and PixelUtil.GetNearestPixelSize(1, grid:GetEffectiveScale(), 1) or 1))
            t:SetPoint("CENTER", UIParent, "CENTER", 0, sign * y)
        end
    end
end

UpdateGrid = function()
    if not db.locked and db.grid then
        BuildGrid()
        grid:Show()
    elseif grid then
        grid:Hide()
    end
end

-- Move a dropped frame so its top-left corner sits on the nearest grid point.
SnapToGrid = function(frame)
    local left, top = frame:GetLeft(), frame:GetTop()
    if not left or not top then return end
    local ratio = frame:GetEffectiveScale() / UIParent:GetEffectiveScale() -- frame units -> UIParent units
    local size = db.gridSize
    local cx, cy = UIParent:GetWidth() / 2, UIParent:GetHeight() / 2
    local x = cx + math.floor((left * ratio - cx) / size + 0.5) * size
    local y = cy + math.floor((top * ratio - cy) / size + 0.5) * size
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x / ratio, y / ratio)
end

end -- grid block

local function StartDrag(self)
    if db.locked or InCombatLockdown() then return end
    local mover = self.cfg and (self.cfg.party and partyContainer or self.cfg.tot and frames.target) or self
    mover:StartMoving()
    self.dragging = mover
end

local function StopDrag(self)
    local mover = self.dragging
    if not mover then return end
    if InCombatLockdown() then self.dragging = nil return end
    mover:StopMovingOrSizing()
    mover:SetUserPlaced(false)
    if db.snap then SnapToGrid(mover) end
    local key = mover == partyContainer and "party" or mover == raidAnchor and "raid" or mover.cfg.key
    SavePoint(mover, key)
    self.dragging = nil
end

local function Layout()
    partyContainer:SetScale(db.scale * PARTY_SCALE)
    ApplyPoint(partyContainer, "party", PARTY_POINT)
    raidAnchor:SetScale(db.raidScale)
    ApplyPoint(raidAnchor, "raid", RAID_POINT)
    for _, h in ipairs(raidHeaders) do h:SetScale(db.raidScale) end
    for _, cfg in ipairs(UNITS) do
        local f = frames[cfg.key]
        if cfg.party then
            f:ClearAllPoints()
            if cfg.party == 1 then
                f:SetPoint("TOPLEFT", partyContainer, "TOPLEFT")
            else
                f:SetPoint("TOPLEFT", frames["party" .. (cfg.party - 1)], "BOTTOMLEFT", 0, -10)
            end
        elseif cfg.tot then
            -- Above the target (over its cast bar), lined up with the bar's left edge, so
            -- the target's buffs/debuffs sit right under the target with no gap.
            -- (Offsets are in this frame's own scale, relative to the target's.)
            local rel = cfg.scale / frames.target.cfg.scale
            f:SetScale(db.scale * cfg.scale)
            f:ClearAllPoints()
            f:SetPoint("BOTTOMLEFT", frames.target.bar, "TOPLEFT", -4 / rel, 34 / rel)
        else
            f:SetScale(db.scale * cfg.scale)
            ApplyPoint(f, cfg.key, cfg.point)
        end
    end
end

-- Unlocked = show target/party (player data stands in) and the raid placeholder.
local function ApplyBackground()
    for _, f in pairs(frames) do
        for _, t in ipairs(f.panel) do t:SetShown(db.background) end
    end
end

local function ApplyLock()
    for _, cfg in ipairs(UNITS) do
        local f = frames[cfg.key]
        f.mover:SetShown(not db.locked)
        if cfg.unit ~= "player" then
            if db.locked then
                f.preview = false
                RegisterUnitWatch(f)
            else
                UnregisterUnitWatch(f)
                f.preview = true
                f:SetAlpha(1)
                f:Show()
            end
        end
    end
    if db.locked then
        RegisterAttributeDriver(partyContainer, "state-visibility", "[group:raid] hide; show")
    else
        UnregisterAttributeDriver(partyContainer, "state-visibility")
        partyContainer:Show()
    end
    raidAnchor:EnableMouse(not db.locked)
    for _, r in ipairs(raidAnchor.placeholder) do r:SetShown(not db.locked) end
    -- While unlocked, let drags on the raid block reach the placeholder underneath.
    for _, h in ipairs(raidHeaders) do h:SetAlpha(db.locked and 1 or 0.3) end
    for _, b in ipairs(raidButtons) do b:EnableMouse(db.locked) end
    UpdateGrid()
    if ns.MeterSetLocked then pcall(ns.MeterSetLocked, db.locked) end
    if ns.SocialSetLocked then pcall(ns.SocialSetLocked, db.locked) end
    if ns.LootSetLocked then pcall(ns.LootSetLocked, db.locked) end
    UpdateAll()
end

---------------------------------------------------------------------------
-- Blizzard frames
---------------------------------------------------------------------------

local hiddenParent = CreateFrame("Frame")
hiddenParent:Hide()

-- Blizzard's raid-tools pull-out (CompactRaidFrameManager: raid markers, ready check,
-- role check) is hidden separately, controlled by db.hideRaidTools.
local BLIZZ_UNIT = { "PlayerFrame", "TargetFrame", "FocusFrame", "PartyFrame" }
local BLIZZ_COMPACT = { "CompactPartyFrame", "CompactRaidFrameContainer" }

local function HideBlizzard()
    if InCombatLockdown() then return end
    if db.hideRaidTools then
        local mgr = _G.CompactRaidFrameManager
        if mgr and mgr:GetParent() ~= hiddenParent then
            -- some FrameXML parents the raid container to the manager: keep it when the user
            -- wants Blizzard's raid frames (only the tools tab is to be hidden)
            local box = _G.CompactRaidFrameContainer
            if not db.hideBlizzard and box and box:GetParent() == mgr then pcall(box.SetParent, box, UIParent) end
            pcall(mgr.SetParent, mgr, hiddenParent)
        end
    end
    if not db.hideBlizzard then return end
    for _, name in ipairs(BLIZZ_UNIT) do
        local fr = _G[name]
        if fr and fr:GetParent() ~= hiddenParent then pcall(fr.SetParent, fr, hiddenParent) end
    end
    -- Give back what SAO has no replacement for, which hid along with its parent unit frame:
    -- the pet frame and the class-resource bars (combo points, holy power, runes, totems...).
    -- Moved only while they sit under hiddenParent (so this is idempotent); names the client
    -- lacks are skipped. They keep Blizzard's anchors (the hidden frames keep their positions).
    for _, name in ipairs({ "PetFrame", "PlayerFrameBottomManagedFramesContainer", "TotemFrame", "ComboFrame",
        "ComboPointPlayerFrame", "RuneFrame", "PaladinPowerBarFrame", "MonkHarmonyBarFrame", "WarlockPowerFrame",
        "MageArcaneChargesFrame", "EssencePlayerFrame" }) do
        local fr = _G[name]
        local p = fr and fr.GetParent and fr:GetParent()
        -- Single class bars only when they hang directly off PlayerFrame / TargetFrame
        -- (on retail they live in the managed container and must stay there).
        local always = name == "PetFrame" or name == "PlayerFrameBottomManagedFramesContainer"
        if p and (always or p == _G.PlayerFrame or p == _G.TargetFrame) then
            local q, depth = p, 0
            while q and q ~= hiddenParent and depth < 8 do q, depth = q:GetParent(), depth + 1 end
            if q == hiddenParent then pcall(fr.SetParent, fr, UIParent) end
        end
    end
    -- Compact frames are hidden and silenced so they stop updating in the background.
    for _, name in ipairs(BLIZZ_COMPACT) do
        local fr = _G[name]
        if fr and fr:GetParent() ~= hiddenParent then
            pcall(fr.UnregisterAllEvents, fr)
            pcall(fr.SetParent, fr, hiddenParent)
        end
    end
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------

local function Help()
    Print("type /sao on its own to open the options window. Commands:")
    print("  /sao unlock  - show all frames and drag them into place")
    print("  /sao lock    - lock frames")
    print("  /sao scale <0.5-2>      - player/target/party size (now " .. db.scale .. ")")
    print("  /sao raidscale <0.4-2>  - raid frame size (now " .. db.raidScale .. ")")
    print("  /sao friendly     - friendly player health bars (now " .. (db.friendlyPlates and "on" or "off") .. ")")
    print("  /sao friendlynpcs - friendly NPC health bars (now " .. (db.friendlyNPCs and "on" or "off") .. ")")
    print("  /sao font    - SAO-style font from Fonts\\SAOUI.ttf (now " .. (ns.fontPath and "in use" or db.saoFont and "on, file not found" or "off") .. ", reloads)")
    print("  /sao meter   - show/hide the SAO damage & heal meter (meterreset, meterdebug)")
    print("  /sao chat    - SAO-styled chat windows on/off")
    print("  /sao social  - open the SAO social menu (socialtoggle turns the button on/off)")
    print("  /sao loot    - SAO need/greed/pass roll windows on/off (loottest shows a preview)")
    print("  /sao lootwindow / trade / merchant / quest - SAO loot, trade and vendor windows on/off (lootwindowtest / tradetest preview)")
    print("  /sao plates  - toggle SAO nameplates (now " .. (db.nameplates and "on" or "off") .. ", reloads)")
    print("  /sao smooth  - animate bar changes (now " .. (db.smooth and "on" or "off") .. ")")
    print("  /sao levels  - color enemy levels gray/green/white/orange/red by difficulty (now " .. (db.levelColors and "on" or "off") .. ")")
    print("  /sao heals   - show incoming heals on health bars (now " .. (db.healPredict and "on" or "off") .. ")")
    print("  /sao absorbs - show shields (absorbs) on health bars (now " .. (db.absorbs and "on" or "off") .. ")")
    print("  /sao guilds  - <Guild> under player names (now " .. (db.guildNames ~= false and "on" or "off") .. ");  /sao restz - floating Z's while resting")
    print("  /sao elite   - gold/silver/red borders on elite, rare and boss enemies (now " .. (db.eliteBorders and "on" or "off") .. ")")
    print("  /sao threatbars  - color enemy health bars by threat in combat (now " .. (db.threatBars and "on" or "off") .. ")")
    print("  /sao clickthrough - friendly nameplates ignore clicks (now " .. (db.friendlyClickThrough ~= false and "on" or "off") .. ")")
    print("  /sao mouse       - show which frame is under the cursor (if a click doesn't go through)")
    print("  /sao targetred   - the target frame's bar is always red on enemies (now " .. (db.targetRed and "on" or "off") .. ")")
    print("  /sao threat  - toggle threat glow (now " .. (db.threat and "on" or "off") .. ")")
    print("  /sao tank    - threat role: auto / tank / dps (now " .. db.threatRole .. ")")
    print("  /sao bg  - toggle the dark panel behind player/target/party (now " .. (db.background and "on" or "off") .. ")")
    print("  /sao raidpower  - raid power bars for healers only or everyone (now " .. (db.raidPowerAll and "everyone" or "healers") .. ")")
    print("  /sao targetdebuffs  - enemy target: show only your debuffs or all (now " .. (db.targetOnlyMine and "yours" or "all") .. ")")
    print("  /sao raidtools  - show/hide Blizzard's raid tools tab (now " .. (db.hideRaidTools and "hidden" or "shown") .. ", reloads)")
    print("  /sao blizz   - toggle hiding Blizzard's unit and raid frames (now " .. (db.hideBlizzard and "hidden" or "shown") .. ", reloads)")
    print("  /sao grid    - show grid while unlocked (now " .. (db.grid and "on" or "off") .. ")")
    print("  /sao snap    - snap dropped frames to the grid (now " .. (db.snap and "on" or "off") .. ")")
    print("  /sao gridsize <8-128>  - grid spacing (now " .. db.gridSize .. ")")
    print("  /sao reset   - reset positions and scale")
    print("  /sao errors  - list errors this addon has caused (clearerrors to reset)")
    print("  /sao debug   - report what the debuff scan sees (works in combat)")
end

---------------------------------------------------------------------------
-- Options window (/sao). Every control runs the matching /sao command, so the
-- window and the slash commands always behave the same.
---------------------------------------------------------------------------

local RefreshOptions, ToggleOptions, OptButton -- defined in the options block below
do
local optionsFrame
local optionWidgets = {}

local function Run(cmd) SlashCmdList.SAOFRAMES(cmd) end

StaticPopupDialogs["SAOFRAMES_CONFIRM"] = {
    text = "%s",
    button1 = YES, button2 = NO,
    OnAccept = function(_, data) Run(data) end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}
local function Confirm(text, cmd)
    StaticPopup_Show("SAOFRAMES_CONFIRM", text, nil, cmd)
end

local function AddBorder(f, a)
    for _, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
        local t = f:CreateTexture(nil, "BORDER")
        t:SetColorTexture(0.88, 0.92, 0.96, a or 0.6)
        if side == "TOP" or side == "BOTTOM" then
            t:SetPoint(side .. "LEFT"); t:SetPoint(side .. "RIGHT"); t:SetHeight(1)
        else
            t:SetPoint("TOP" .. side); t:SetPoint("BOTTOM" .. side); t:SetWidth(1)
        end
    end
end

OptButton = function(parent, w, textFn, onClick)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w, 22)
    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.12, 0.14, 0.18, 0.95)
    AddBorder(b)
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(0.45, 0.8, 1, 0.2)
    b.label = b:CreateFontString(nil, "OVERLAY")
    SetFont(b.label, 11)
    b.label:SetPoint("CENTER")
    b.Refresh = function() b.label:SetText(type(textFn) == "function" and textFn() or textFn) end
    b:SetScript("OnClick", onClick)
    b.Refresh()
    optionWidgets[#optionWidgets + 1] = b
    return b
end

local function OptCheck(parent, label, getter, onClick)
    local c = CreateFrame("Button", nil, parent)
    c:SetSize(288, 20)
    local box = CreateFrame("Frame", nil, c)
    box:SetSize(14, 14)
    box:SetPoint("LEFT")
    local bg = box:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.04, 0.05, 0.07, 0.95)
    AddBorder(box, 0.8)
    local mark = box:CreateTexture(nil, "OVERLAY")
    mark:SetPoint("TOPLEFT", 3, -3); mark:SetPoint("BOTTOMRIGHT", -3, 3)
    mark:SetColorTexture(0.4, 0.85, 1, 1)
    local text = c:CreateFontString(nil, "OVERLAY")
    SetFont(text, 11)
    text:SetPoint("LEFT", box, "RIGHT", 8, 0)
    text:SetText(label)
    local hl = c:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(0.45, 0.8, 1, 0.12)
    c.Refresh = function() mark:SetShown(getter() and true or false) end
    c:SetScript("OnClick", onClick)
    c.Refresh()
    optionWidgets[#optionWidgets + 1] = c
    return c
end

local function OptStepper(parent, label, getter, fmt, onStep)
    local s = CreateFrame("Frame", nil, parent)
    s:SetSize(288, 22)
    local text = s:CreateFontString(nil, "OVERLAY")
    SetFont(text, 11)
    text:SetPoint("LEFT")
    text:SetText(label)
    local minus = OptButton(s, 22, "-", function() onStep(-1) end)
    minus:SetPoint("LEFT", 170, 0)
    local val = s:CreateFontString(nil, "OVERLAY")
    SetFont(val, 11)
    val:SetPoint("LEFT", minus, "RIGHT", 0, 0)
    val:SetWidth(52)
    local plus = OptButton(s, 22, "+", function() onStep(1) end)
    plus:SetPoint("LEFT", val, "RIGHT", 0, 0)
    s.Refresh = function() val:SetText(fmt:format(getter())) end
    s.Refresh()
    optionWidgets[#optionWidgets + 1] = s
    return s
end

RefreshOptions = function()
    if not optionsFrame or not optionsFrame:IsShown() then return end
    for _, w in ipairs(optionWidgets) do w.Refresh() end
end

local function Clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

local function BuildOptions()
    local f = CreateFrame("Frame", "SAOFramesOptions", UIParent)
    f:SetSize(620, 808)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    tinsert(UISpecialFrames, "SAOFramesOptions") -- Escape closes it

    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(1, 1, 1, 1)
    bg:SetGradient("VERTICAL", CreateColor(0.06, 0.07, 0.10, 0.95), CreateColor(0.13, 0.15, 0.19, 0.95))
    AddBorder(f, 0.75)

    local title = f:CreateFontString(nil, "OVERLAY")
    SetFont(title, 16, true)
    title:SetPoint("TOPLEFT", 16, -12)
    title:SetText("SAO Frames")
    local sub = f:CreateFontString(nil, "OVERLAY")
    SetFont(sub, 10)
    sub:SetPoint("LEFT", title, "RIGHT", 8, -1)
    sub:SetTextColor(0.55, 0.85, 1)
    sub:SetText("OPTIONS")
    local rule = f:CreateTexture(nil, "ARTWORK")
    rule:SetColorTexture(0.4, 0.85, 1, 0.8)
    rule:SetPoint("TOPLEFT", 12, -36); rule:SetPoint("TOPRIGHT", -12, -36)
    local divider = f:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(0.4, 0.85, 1, 0.35)
    divider:SetPoint("TOPLEFT", 306, -48); divider:SetPoint("BOTTOMLEFT", 306, 16)
    divider:SetWidth(1)
    rule:SetHeight(1)

    local close = OptButton(f, 22, "X", function() f:Hide() end)
    close:SetPoint("TOPRIGHT", -10, -9)

    local y = -46
    local function Place(widget, h) widget:SetPoint("TOPLEFT", 16, y); y = y - (h or 24) end
    local function Header(text)
        y = y - 6
        local h = f:CreateFontString(nil, "OVERLAY")
        SetFont(h, 12, true)
        h:SetTextColor(0.55, 0.85, 1)
        h:SetPoint("TOPLEFT", 16, y)
        h:SetText(text)
        y = y - 20
    end

    -- Right-hand column: the SAO window modules (meter, chat, social, loot, trade, vendor).
    local y2 = -52
    local h2 = f:CreateFontString(nil, "OVERLAY")
    SetFont(h2, 12, true)
    h2:SetTextColor(0.55, 0.85, 1)
    h2:SetPoint("TOPLEFT", 320, y2)
    h2:SetText("SAO WINDOWS")
    y2 = y2 - 20
    local function Place2(widget) widget:SetPoint("TOPLEFT", 320, y2); y2 = y2 - 24 end
    local function ModCheck(label, isOn, cmd)
        Place2(OptCheck(f, label, function() return ns[isOn] and ns[isOn]() end, function() Run(cmd) end))
    end
    ModCheck("Damage / heal meter", "IsMeterShown", "meter")
    ModCheck("SAO chat windows", "IsChatEnabled", "chat")
    ModCheck("SAO social menu button", "IsSocialEnabled", "socialtoggle")
    ModCheck("SAO need / greed / pass rolls", "IsLootEnabled", "loot")
    ModCheck("SAO loot window", "IsLootWindowEnabled", "lootwindow")
    ModCheck("SAO trade window", "IsTradeEnabled", "trade")
    ModCheck("SAO vendor (buy / sell) window", "IsMerchantEnabled", "merchant")
    ModCheck("SAO quest and NPC talk windows", "IsQuestEnabled", "quest")
    local prev = OptButton(f, 140, "Preview loot roll", function() Run("loottest") end)
    Place2(prev)
    local prevW = OptButton(f, 140, "Preview loot window", function() Run("lootwindowtest") end)
    Place2(prevW)
    Place2(OptButton(f, 140, "Preview trade window", function() Run("tradetest") end))

    Header("LAYOUT")
    local lockBtn = OptButton(f, 140, function() return db.locked and "Unlock frames" or "Lock frames" end,
        function() Run(db.locked and "unlock" or "lock") end)
    Place(lockBtn, 0)
    local resetBtn = OptButton(f, 140, "Reset positions",
        function() Confirm("Reset all SAO Frames positions and sizes?", "reset") end)
    resetBtn:SetPoint("TOPLEFT", 164, y)
    y = y - 28
    Place(OptCheck(f, "Show grid while unlocked", function() return db.grid end, function() Run("grid") end))
    Place(OptCheck(f, "Snap frames to the grid", function() return db.snap end, function() Run("snap") end))
    Place(OptStepper(f, "Grid spacing", function() return db.gridSize end, "%d",
        function(d) Run("gridsize " .. Clamp(db.gridSize + d * 8, 8, 128)) end))
    Place(OptStepper(f, "Frame size", function() return db.scale end, "%.2f",
        function(d) Run(("scale %.2f"):format(Clamp(db.scale + d * 0.05, 0.5, 2))) end))
    Place(OptStepper(f, "Raid frame size", function() return db.raidScale end, "%.2f",
        function(d) Run(("raidscale %.2f"):format(Clamp(db.raidScale + d * 0.05, 0.4, 2))) end))

    Header("FEATURES")
    Place(OptCheck(f, "SAO font (Fonts\\SAOUI.ttf, reloads UI)", function() return db.saoFont end,
        function() Confirm("Toggle the SAO font? This reloads your UI.", "font") end))
    Place(OptCheck(f, "SAO nameplates (reloads UI)", function() return db.nameplates end,
        function() Confirm("Toggle SAO nameplates? This reloads your UI.", "plates") end))
    Place(OptCheck(f, "Friendly player health bars", function() return db.friendlyPlates end, function() Run("friendly") end))
    Place(OptCheck(f, "Friendly NPC health bars", function() return db.friendlyNPCs end, function() Run("friendlynpcs") end))
    Place(OptCheck(f, "Clicks pass through friendly nameplates", function() return db.friendlyClickThrough ~= false end, function() Run("clickthrough") end))
    Place(OptCheck(f, "Threat glow and aggro arrows", function() return db.threat end, function() Run("threat") end))
    Place(OptCheck(f, "Color enemy levels by difficulty", function() return db.levelColors end, function() Run("levels") end))
    Place(OptCheck(f, "Show incoming heals on health bars", function() return db.healPredict end, function() Run("heals") end))
    Place(OptCheck(f, "Show shields (absorbs) on health bars", function() return db.absorbs end, function() Run("absorbs") end))
    Place(OptCheck(f, "Guild names under player names", function() return db.guildNames ~= false end, function() Run("guilds") end))
    Place(OptCheck(f, "Floating Z's while resting", function() return db.restZ ~= false end, function() Run("restz") end))
    Place(OptCheck(f, "Elite / rare / boss borders", function() return db.eliteBorders end, function() Run("elite") end))
    Place(OptCheck(f, "Color enemy health bars by threat", function() return db.threatBars end, function() Run("threatbars") end))
    Place(OptCheck(f, "Target frame bar always red on enemies", function() return db.targetRed end, function() Run("targetred") end))
    Place(OptCheck(f, "Dark background behind frames", function() return db.background end, function() Run("bg") end))
    Place(OptCheck(f, "Smooth bar animation", function() return db.smooth end, function() Run("smooth") end))
    Place(OptCheck(f, "Hide Blizzard unit and raid frames (reloads UI)", function() return db.hideBlizzard end,
        function() Confirm("Toggle Blizzard's unit and raid frames? This reloads your UI.", "blizz") end))
    Place(OptCheck(f, "Hide Blizzard raid tools tab (reloads UI)", function() return db.hideRaidTools end,
        function() Confirm("Toggle Blizzard's raid tools tab (markers, ready check)? This reloads your UI.", "raidtools") end))
    Place(OptCheck(f, "Raid power bars for everyone (not just healers)", function() return db.raidPowerAll end,
        function() Run("raidpower") end))
    Place(OptCheck(f, "Enemy target: show only my debuffs", function() return db.targetOnlyMine end,
        function() Run("targetdebuffs") end))
    y = y - 4
    Place(OptButton(f, 288, function()
        local r = db.threatRole
        return "Threat role: " .. (r == "auto" and "Auto (stance / spec)" or r == "TANK" and "Tank" or "DPS / Healer")
    end, function() Run("tank") end), 30)

    Header("TOOLS")
    local dbg = OptButton(f, 140, "Debug report", function() Run("debug") end)
    Place(dbg, 0)
    local help = OptButton(f, 140, "List / commands", function() Run("help") end)
    help:SetPoint("TOPLEFT", 164, y)

    f:SetScript("OnShow", RefreshOptions)
    f:Hide()
    optionsFrame = f
end

ToggleOptions = function(forceShow)
    if not db then return end
    if not optionsFrame then BuildOptions() end
    if forceShow or not optionsFrame:IsShown() then
        -- shrink to fit short screens (832 tall vs a 768-tall UIParent without UI scale)
        optionsFrame:SetScale(math.min(1, (UIParent:GetHeight() - 16) / optionsFrame:GetHeight()))
        optionsFrame:Show()
    else
        optionsFrame:Hide()
    end
end

-- Minimap addon-compartment entry (see the .toc).
function SAOFrames_OnAddonCompartmentClick()
    ToggleOptions()
end
end -- options block

SLASH_SAOFRAMES1 = "/sao"
SLASH_SAOFRAMES2 = "/saoframes"
local function HandleCommand(msg)
    if not db then
        Print("still loading - it finishes when you leave combat.")
        return
    end
    local cmd, arg = strsplit(" ", strlower(strtrim(msg or "")), 2)
    if cmd ~= "" and cmd ~= "help" and cmd ~= "debug" and cmd ~= "options" and cmd ~= "config"
        and cmd ~= "errors" and cmd ~= "meter" and cmd ~= "meterdebug" and cmd ~= "social"
        and InCombatLockdown() then
        Print("can't change frames in combat.")
        return
    end
    local n = tonumber(arg)
    if cmd == "unlock" then
        db.locked = false; ApplyLock()
        Print("unlocked - drag frames with the left mouse button. /sao lock when done.")
    elseif cmd == "lock" then
        db.locked = true; ApplyLock(); Print("locked.")
    elseif cmd == "scale" then
        if n and n >= 0.5 and n <= 2 then
            db.scale = n; Layout(); Print("scale set to " .. n)
        else
            Print("scale must be between 0.5 and 2.")
        end
    elseif cmd == "raidscale" then
        if n and n >= 0.4 and n <= 2 then
            db.raidScale = n; Layout(); Print("raid scale set to " .. n)
        else
            Print("raid scale must be between 0.4 and 2.")
        end
    elseif cmd == "debug" then
        do
            local n, direct, alias, none = 0, 0, 0, 0
            for _, pl in pairs(plateByUnit) do
                n = n + 1
                local _, st = UnitDetailedThreatSituation("player", pl.unit)
                if IsSecret(st) or st ~= nil then direct = direct + 1
                elseif pl.threatAlias then alias = alias + 1 else none = none + 1 end
            end
            Print(("nameplates: %d shown; threat readable directly on %d, via target/focus on %d, not at all on %d"):format(n, direct, alias, none))
            local inInst, instKind = IsInInstance()
            Print(("nameplates the game refused to give addons this session: %d (last: %s); in instance: %s"):format(
                ns.forbiddenPlates or 0, tostring(ns.lastForbidden or "-"), inInst and tostring(instKind) or "no"))
            Print(("threat: role=%s, curves=%s, threat setting=%s"):format(IsTank() and "tank" or "non-tank",
                (C_CurveUtil and C_CurveUtil.CreateColorCurve) and "yes" or "NO", tostring(db.threat)))
            local shownN = 0
            for _, pl in pairs(plateByUnit) do
                if shownN < 6 then
                    shownN = shownN + 1
                    local sp = pl.spikes and pl.spikes[1]
                    print(("  %s: %s | arrows %s"):format(pl.unit, tostring(pl.threatWhy),
                        sp and (sp:IsShown() and "visible" or "hidden") or "missing"))
                end
            end
            local tf = frames.target
            if tf and tf:IsVisible() then
                local sp = tf.spikes and tf.spikes[1]
                print(("  target frame: %s | arrows %s"):format(tostring(tf.threatWhy),
                    sp and (sp:IsShown() and "visible" or "hidden") or "missing"))
            end
        end
        local active = frames.player and frames.player.auraHolders
        Print("aura containers (12.1+): " .. (active and "|cff7fff7fin use|r"
            or HAS_AURA_CONTAINER and "|cffffd070available but setup failed - using fallback (see /sao errors)|r"
            or "|cffff7070not available - using fallback|r"))
        if active then
            for _, key in ipairs({ "player", "target", "focus" }) do
                local fr = frames[key]
                for i, h in ipairs(fr and fr.auraHolders or {}) do
                    print(("  %s row %d (%s): unit=%s filter=%s shown=%s"):format(key, i, h.kind,
                        tostring(h.unit), tostring(h.filter), tostring(h:IsVisible())))
                end
            end
        end
        local CU = C_UnitAuras or {}
        local function has(fn) return fn and "y" or "n" end
        Print(("APIs: InstanceIDs=%s UnitAuras=%s ByIndex=%s ByInstanceID=%s Duration=%s DispelColor=%s Count=%s ForEachAura=%s"):format(
            has(CU.GetUnitAuraInstanceIDs), has(CU.GetUnitAuras), has(CU.GetAuraDataByIndex),
            has(CU.GetAuraDataByAuraInstanceID), has(CU.GetAuraDuration), has(CU.GetAuraDispelTypeColor),
            has(CU.GetAuraApplicationDisplayCount), has(AuraUtil and AuraUtil.ForEachAura)))
        if UnitExists("target") then
            for _, flt in ipairs({ "HARMFUL", "HARMFUL|PLAYER" }) do
                local list, d = ScanAuras("target", flt, 8)
                Print(("target raw scan %s: api=%s found=%d%s"):format(flt, d.api, #list, d.err and (" err=" .. d.err) or ""))
            end
        end
        for _, key in ipairs({ "player", "target" }) do
            local f = frames[key]
            if f and UnitExists(key) then UpdateAuras(f) end
            local d = auraDiag[key]
            if d then
                Print(("%s: api=%s filter=%s found=%d%s"):format(key, d.api, d.filter, d.count,
                    d.err and (" |cffff5555error: " .. d.err .. "|r") or ""))
            else
                Print(key .. ": no scan yet (unit missing?)")
            end
        end
        for _, key in ipairs({ "player-buffs", "target-buffs" }) do
            local d = auraDiag[key]
            if d then Print(("%s: api=%s found=%d combat=%s%s"):format(key, d.api, d.count, tostring(d.combat), d.err and (" error: " .. d.err) or "")) end
        end
        RefreshTankBuffCache(); IsTank()
        Print("threat role: " .. (db.threatRole == "auto" and (detectedRole .. " (" .. roleSource .. ")") or (db.threatRole .. " (forced)")))
        local f = frames.player
        if f and f.debuffs and f.debuffs[1] then
            local p = f.debuffs[1]
            Print(("player icon 1: shown=%s visible=%s size=%.0f"):format(tostring(p:IsShown()), tostring(p:IsVisible()), p:GetWidth()))
        end
    elseif cmd == "grid" then
        db.grid = not db.grid
        UpdateGrid()
        Print("grid " .. (db.grid and "on" or "off") .. " (shows while unlocked).")
    elseif cmd == "snap" then
        db.snap = not db.snap
        Print("snap to grid " .. (db.snap and "on." or "off."))
    elseif cmd == "gridsize" then
        if n and n >= 8 and n <= 128 then
            db.gridSize = math.floor(n); UpdateGrid(); Print("grid spacing " .. db.gridSize .. ".")
        else
            Print("grid spacing must be between 8 and 128.")
        end
    elseif cmd == "friendly" then
        db.friendlyPlates = not db.friendlyPlates
        ApplyFriendlyPlateCVars()
        Print("friendly player health bars " .. (db.friendlyPlates and "on." or "off.") ..
            " (in dungeons and raids the game keeps friendly plates locked to Blizzard's style.)")
    elseif cmd == "friendlynpcs" then
        db.friendlyNPCs = not db.friendlyNPCs
        ApplyFriendlyPlateCVars()
        Print("friendly NPC health bars " .. (db.friendlyNPCs and "on." or "off."))
    elseif cmd == "errors" then
        local list = {}
        for msg, e in pairs(db.errors or {}) do list[#list + 1] = { msg = msg, e = e } end
        table.sort(list, function(a, b) return a.e.count > b.e.count end)
        if #list == 0 then
            Print("no errors recorded.")
        else
            Print(#list .. " distinct error(s) recorded (most frequent first):")
            for i = 1, math.min(#list, 10) do
                local it = list[i]
                print(("  |cffff7070x%d|r [%s%s] %s"):format(it.e.count, it.e.first or "?", it.e.combat and ", combat" or "", it.msg))
            end
            Print("full details are saved in WTF\\Account\\...\\SavedVariables\\SAOFrames.lua after /reload or logout.")
        end
    elseif cmd == "clearerrors" then
        db.errors = {}
        Print("error log cleared.")
    elseif cmd == "levels" then
        db.levelColors = not db.levelColors
        UpdateAll()
        for _, pl in pairs(plateByUnit) do UpdatePlate(pl) end
        Print("difficulty-colored levels " .. (db.levelColors and "on." or "off."))
    elseif cmd == "heals" then
        db.healPredict = not db.healPredict
        UpdateAll()
        for _, pl in pairs(plateByUnit) do UpdatePlate(pl) end
        Print("incoming-heal display " .. (db.healPredict and "on." or "off."))
    elseif cmd == "absorbs" then
        db.absorbs = not db.absorbs
        UpdateAll()
        for _, pl in pairs(plateByUnit) do UpdatePlate(pl) end
        Print("shield (absorb) display " .. (db.absorbs and "on." or "off."))
    elseif cmd == "guilds" then
        db.guildNames = db.guildNames == false
        UpdateAll()
        for _, pl in pairs(plateByUnit) do UpdatePlate(pl) end
        Print("guild names " .. (db.guildNames and "on." or "off."))
    elseif cmd == "restz" then
        db.restZ = db.restZ == false
        if Extras.UpdateRestZ then Extras.UpdateRestZ() end
        Print("resting Z's " .. (db.restZ and "on." or "off."))
    elseif cmd == "elite" then
        db.eliteBorders = not db.eliteBorders
        UpdateAll()
        for _, pl in pairs(plateByUnit) do UpdatePlate(pl) end
        Print("elite / rare borders " .. (db.eliteBorders and "on." or "off."))
    elseif cmd == "threatbars" then
        db.threatBars = not db.threatBars
        for _, fr in pairs(frames) do fr.threatColored = false end
        for _, pl in pairs(plateByUnit) do pl.threatColored = false end
        UpdateAll()
        Print("threat-colored enemy health bars " .. (db.threatBars and "on." or "off."))
    elseif cmd == "clickthrough" then
        if InCombatLockdown() then Print("can't change nameplate clicks in combat; try again after.") return end
        db.friendlyClickThrough = db.friendlyClickThrough == false
        ApplyFriendlyPlateCVars()
        Print("click-through friendly nameplates " .. (db.friendlyClickThrough and "on." or "off.")
            .. (ns.clickThroughOk == false and " (the game refused the change)" or ""))
    elseif cmd == "mouse" then
        -- What is under the cursor right now (for "my click didn't go through").
        local foci = GetMouseFoci and GetMouseFoci() or { GetMouseFocus and GetMouseFocus() }
        if #foci == 0 then Print("nothing under the cursor (the game world).") end
        for _, fr in ipairs(foci) do
            local okF, forb = pcall(fr.IsForbidden, fr)
            local label
            if okF and forb then label = "a locked game frame (e.g. a nameplate)"
            else
                local okN, nm = pcall(fr.GetDebugName, fr)
                label = okN and nm or tostring(fr)
            end
            Print("under cursor: " .. tostring(label))
        end
    elseif cmd == "targetred" then
        db.targetRed = not db.targetRed
        for _, fr in pairs(frames) do fr.threatColored = false end
        for _, pl in pairs(plateByUnit) do pl.threatColored = false end
        UpdateAll()
        Print("red bar on the enemy target frame " .. (db.targetRed and "on." or "off."))
    elseif cmd == "raidtools" then
        db.hideRaidTools = not db.hideRaidTools
        ReloadUI()
    elseif cmd == "font" then
        db.saoFont = not db.saoFont
        Print("SAO font " .. (db.saoFont and "on (uses Fonts\\SAOUI.ttf if present)" or "off") .. " - reloading.")
        ReloadUI()
    elseif cmd == "meter" then
        if ns.ToggleMeter then ns.ToggleMeter() else Print("damage meter isn't loaded.") end
    elseif cmd == "meterreset" then
        if ns.MeterReset then ns.MeterReset() end
    elseif cmd == "meterdebug" then
        if ns.MeterDebug then ns.MeterDebug() end
    elseif cmd == "chat" then
        if ns.ChatSetEnabled then ns.ChatSetEnabled(not (ns.IsChatEnabled and ns.IsChatEnabled()))
        else Print("chat skin isn't loaded.") end
    elseif cmd == "social" then
        if ns.ToggleSocialMenu then ns.ToggleSocialMenu() else Print("social menu isn't loaded.") end
    elseif cmd == "socialtoggle" then
        if ns.SocialSetEnabled then ns.SocialSetEnabled(not (ns.IsSocialEnabled and ns.IsSocialEnabled())) end
    elseif cmd == "loot" then
        if ns.LootSetEnabled then ns.LootSetEnabled(not (ns.IsLootEnabled and ns.IsLootEnabled()))
        else Print("loot rolls aren't loaded.") end
    elseif cmd == "loottest" then
        if ns.LootTest then ns.LootTest() end
    elseif cmd == "lootwindow" or cmd == "trade" or cmd == "merchant" or cmd == "quest" then
        local key = cmd == "lootwindow" and "LootWindow" or cmd == "trade" and "Trade"
            or cmd == "quest" and "Quest" or "Merchant"
        -- toggle the saved setting (not whether the skin happens to be applied right now)
        local set, saved = ns[key .. "SetEnabled"], db[cmd == "lootwindow" and "lootWindow" or cmd]
        local on = not (type(saved) == "table" and saved.enabled == false)
        if set then set(not on) else Print(cmd .. " skin isn't loaded.") end
    elseif cmd == "tradetest" then
        if ns.TradeTest then ns.TradeTest() else Print("trade preview isn't available.") end
    elseif cmd == "lootwindowtest" then
        if ns.LootWindowTest then ns.LootWindowTest() else Print("loot window preview isn't available.") end
    elseif cmd == "plates" then
        db.nameplates = not db.nameplates
        ReloadUI()
    elseif cmd == "smooth" then
        db.smooth = not db.smooth
        Print("bar smoothing " .. (db.smooth and "on (bars glide, can trail real health)." or "off (bars show exact health)."))
    elseif cmd == "threat" then
        db.threat = not db.threat
        Print("threat glow " .. (db.threat and "on." or "off."))
    elseif cmd == "tank" or cmd == "role" then
        db.threatRole = db.threatRole == "auto" and "TANK" or db.threatRole == "TANK" and "DPS" or "auto"
        if db.threatRole == "auto" then
            RefreshTankBuffCache(); IsTank()
            Print("threat role: auto (now " .. detectedRole .. ", from " .. roleSource .. ").")
        else
            Print("threat role forced to " .. db.threatRole .. ". /sao tank again to change.")
        end
    elseif cmd == "bg" then
        db.background = not db.background
        ApplyBackground()
        Print("background " .. (db.background and "on." or "off."))
    elseif cmd == "raidpower" then
        db.raidPowerAll = not db.raidPowerAll
        UpdateAll()
        Print("raid power bars: " .. (db.raidPowerAll and "everyone." or "healers only."))
    elseif cmd == "targetdebuffs" then
        db.targetOnlyMine = not db.targetOnlyMine
        UpdateAll()
        for _, pl in pairs(plateByUnit) do UpdateAuras(pl) end
        Print("enemy target shows " .. (db.targetOnlyMine and "only your debuffs." or "all debuffs."))
    elseif cmd == "blizz" then
        db.hideBlizzard = not db.hideBlizzard
        ReloadUI()
    elseif cmd == "reset" then
        db.pos = {}; db.scale = DEFAULTS.scale; db.raidScale = DEFAULTS.raidScale
        Layout()
        for _, fn in ipairs({ "MeterResetPosition", "SocialResetPosition", "LootResetPosition" }) do
            if ns[fn] then pcall(ns[fn]) end
        end
        Print("positions reset.")
    elseif cmd == "" or cmd == "options" or cmd == "config" then
        ToggleOptions()
    else
        Help()
    end
end

SlashCmdList.SAOFRAMES = function(msg)
    HandleCommand(msg)
    RefreshOptions()
end

---------------------------------------------------------------------------
-- Init
---------------------------------------------------------------------------

-- Shared with SAOMeter.lua (loaded after this file).
ns.SetFont, ns.MEDIA, ns.BOLD_FONT = SetFont, MEDIA, BOLD_FONT
ns.Print, ns.LogError, ns.IsSecret, ns.Plain, ns.Abbrev = Print, LogError, IsSecret, Plain, Abbrev
ns.SnapToGrid = function(frame) return SnapToGrid(frame) end
ns.GetDB = function() return db end

local function Init()
    SAOFramesDB = SAOFramesDB or {}
    db = SAOFramesDB
    db.errors = db.errors or {}
    for msg, e in pairs(pendingErrors) do
        if db.errors[msg] then db.errors[msg].count = db.errors[msg].count + e.count else db.errors[msg] = e end
    end
    wipe(pendingErrors)
    db.clock = nil -- removed option
    for k, v in pairs(DEFAULTS) do
        if db[k] == nil then db[k] = type(v) == "table" and {} or v end
    end
    if db.tankMode ~= nil then
        if db.tankMode then db.threatRole = "TANK" end
        db.tankMode = nil
    end
    db.gridSize = math.max(8, math.min(128, tonumber(db.gridSize) or DEFAULTS.gridSize))

    -- SAO font: use it only if the file exists and actually renders text.
    ns.fontPath = nil
    if db.saoFont then
        local path = "Interface\\AddOns\\" .. ADDON .. "\\Fonts\\SAOUI.ttf"
        local probe = UIParent:CreateFontString(nil, "OVERLAY")
        -- SetText on a FontString with no font errors ("Font not set"), so only measure
        -- once GetFont confirms the file loaded.
        if pcall(probe.SetFont, probe, path, 12, "") and probe:GetFont() then
            local ok, w = pcall(function() probe:SetText("SAO 123"); return probe:GetStringWidth() end)
            if ok and not IsSecret(w) and w and w > 0 then ns.fontPath = path end
        end
        probe:Hide()
    end

    -- Party frames live in a secure container that hides itself in raids.
    partyContainer = CreateFrame("Frame", "SAOFrames_Party", UIParent, "SecureHandlerStateTemplate")
    partyContainer:SetSize(PANEL_W, PANEL_H)
    partyContainer:SetMovable(true)
    partyContainer:SetClampedToScreen(true)

    for _, cfg in ipairs(UNITS) do
        local f = cfg.tot and CreateToTFrame(cfg) or CreateUnitFrame(cfg, cfg.party and partyContainer or UIParent)
        f:SetScript("OnDragStart", StartDrag)
        f:SetScript("OnDragStop", StopDrag)
        f.mover:SetScript("OnDragStart", function() StartDrag(f) end)
        f.mover:SetScript("OnDragStop", function() StopDrag(f) end)
        if cfg.unit ~= "player" then
            f:Hide()
        end
    end

    -- Target / focus cast bars: Blizzard's live inside the hidden TargetFrame / FocusFrame.
    -- Plain (non-secure) child StatusBars, so showing/hiding them in combat is allowed.
    for _, key in ipairs({ "target", "focus" }) do
        local f = frames[key]
        if f and not f.cast then
            AddCastBar(f, 20, 28, BAR_W - 40, 12) -- above the bar, clear of the THREAT % text
            for e in pairs(CAST_EVENTS) do pcall(f.RegisterUnitEvent, f, e, f.unit) end
            f:SetScript("OnEvent", function(self, event, ...)
                if CAST_EVENTS[event] then OnCastEvent(self, event) return end
                OnEvent(self, event, ...)
                if event == "PLAYER_TARGET_CHANGED" or event == "PLAYER_FOCUS_CHANGED" or event == "PLAYER_ENTERING_WORLD" then
                    CheckCasting(self)
                end
            end)
            f:HookScript("OnShow", CheckCasting)
        end
    end

    CreateRaid()
    raidAnchor:SetScript("OnDragStart", StartDrag)
    raidAnchor:SetScript("OnDragStop", StopDrag)

    Layout()
    HideBlizzard()
    ApplyBackground()
    ApplyLock()
    if not db.seenHint then
        Print("type /sao unlock to move frames, /sao for all options.")
        db.seenHint = true
    end

    -- Auto-lock when combat starts (REGEN_DISABLED fires just before lockdown), and
    -- re-hide Blizzard frames that get created later, e.g. the compact party frame.
    -- Created early so a failing feature init below can't take it down.
    local watcher = CreateFrame("Frame")
    watcher:RegisterUnitEvent("UNIT_AURA", "player")
    watcher:RegisterEvent("PLAYER_REGEN_DISABLED")
    watcher:RegisterEvent("PLAYER_REGEN_ENABLED")
    watcher:RegisterEvent("GROUP_ROSTER_UPDATE")
    watcher:RegisterEvent("UI_SCALE_CHANGED")
    watcher:RegisterEvent("DISPLAY_SIZE_CHANGED")
    watcher:RegisterEvent("PLAYER_ENTERING_WORLD")
    watcher:RegisterEvent("ADDON_LOADED")
    watcher:SetScript("OnEvent", function(_, event)
        if event == "UNIT_AURA" then
            RefreshTankBuffCache()
        elseif event == "UI_SCALE_CHANGED" or event == "DISPLAY_SIZE_CHANGED" then
            UpdateGrid()
        elseif event == "PLAYER_REGEN_DISABLED" then
            if not db.locked then
                for _, fr in pairs(frames) do if fr.dragging then StopDrag(fr) end end
                if raidAnchor.dragging then StopDrag(raidAnchor) end
                db.locked = true
                ApplyLock()
                Print("frames locked for combat.")
                RefreshOptions()
            end
        else
            -- the tank-buff cache can't refresh in combat; catch up now
            if event == "PLAYER_REGEN_ENABLED" then RefreshTankBuffCache() end
            HideBlizzard()
            -- and again next frame, for frames Blizzard creates in this same event
            if C_Timer then C_Timer.After(0, HideBlizzard) end
        end
    end)

    -- Health text/bars: poll ~30 times a second on top of UNIT_HEALTH events, so the
    -- % never lags behind the fight (events alone can arrive in bursts).
    do
        local poll, acc = CreateFrame("Frame"), 0
        poll:SetScript("OnUpdate", function(_, elapsed)
            acc = acc + elapsed
            if acc < 0.033 then return end
            acc = 0
            for _, f in pairs(frames) do
                if f:IsVisible() then UpdateHealth(f) end
            end
        end)
    end

    C_Timer.NewTicker(0.25, function()
        for i = 1, 4 do UpdateRange(frames["party" .. i]) end
        for _, b in ipairs(raidButtons) do
            if b:IsVisible() then UpdateRange(b); UpdateThreat(b) end
        end
        for _, f in pairs(frames) do
            UpdateThreat(f)
            if f.auraHolders and f:IsVisible() then RestackAuras(f) end
        end
        local tot = frames.targettarget
        if tot and tot:IsVisible() then UpdateFrame(tot) end
    end)

    -- Feature inits: each fails on its own (logged) without stopping the rest of Init.
    for _, it in ipairs({ { RefreshTankBuffCache, "threat role" }, { InitNameplates, "nameplates" },
        { InitReadyCheck, "ready check" }, { InitRaidMarks, "raid marks" },
        { Extras.InitRestZ, "rest Zs" } }) do
        local ok, err = pcall(it[1])
        if not ok then LogError(it[2] .. " init: " .. tostring(err)); Print(it[2] .. " failed to start (see /sao errors).") end
    end
    if ns.InitMeter then
        local ok, err = pcall(ns.InitMeter)
        if not ok then LogError("meter init: " .. tostring(err)); Print("damage meter failed to start (see /sao errors).") end
    end
    -- Optional modules (separate files): each fails on its own without touching the rest.
    for _, m in ipairs({ { "InitChat", "chat skin" }, { "InitSocial", "social menu" }, { "InitLoot", "loot rolls" },
        { "InitLootWindow", "loot window" }, { "InitTrade", "trade window" }, { "InitMerchant", "vendor window" },
        { "InitQuest", "quest window" } }) do
        if ns[m[1]] then
            local ok, err = pcall(ns[m[1]])
            if not ok then LogError(m[2] .. " init: " .. tostring(err)); Print(m[2] .. " failed to start (see /sao errors).") end
        end
    end
    if ns.SocialSetLocked then pcall(ns.SocialSetLocked, db.locked) end
    if ns.LootSetLocked then pcall(ns.LootSetLocked, db.locked) end

    -- Entry under Esc > Options > AddOns with a button that opens the SAO window.
    if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
        pcall(function()
            local panel = CreateFrame("Frame")
            local t = panel:CreateFontString(nil, "OVERLAY")
            SetFont(t, 16, true)
            t:SetPoint("TOPLEFT", 16, -16)
            t:SetText("SAO Frames")
            local b = OptButton(panel, 220, "Open SAO Frames options", function()
                if SettingsPanel and SettingsPanel.Close then pcall(SettingsPanel.Close, SettingsPanel, true) end
                ToggleOptions(true)
            end)
            b:SetPoint("TOPLEFT", 16, -48)
            local cat = Settings.RegisterCanvasLayoutCategory(panel, "SAO Frames")
            Settings.RegisterAddOnCategory(cat)
        end)
    end

end

local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function(self)
    -- Secure frames can't be created or re-parented in combat (e.g. /reload mid-fight).
    if InCombatLockdown() then
        self:RegisterEvent("PLAYER_REGEN_ENABLED")
        return
    end
    self:UnregisterAllEvents()
    Init()
end)
