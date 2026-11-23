-- SAO Frames: Sword Art Online-styled damage / healing meter (SAOMeter.lua).
--
-- Combat log events are not available on Forever, so all data comes from Blizzard's
-- C_DamageMeter API. In combat most values it returns are "secret": addon Lua may not
-- compare, add, concatenate or index with them, but StatusBar and FontString setters
-- accept them directly. So this file never sorts or does math on amounts: it uses
-- Blizzard's array order and passes values straight to widgets, always inside pcall.
--
-- Public (on ns): InitMeter, ToggleMeter, IsMeterShown, MeterSetLocked, MeterReset,
-- MeterResetPosition, MeterDebug.

local ADDON, ns = ...

---------------------------------------------------------------------------
-- Constants
---------------------------------------------------------------------------

local WHITE = "Interface\\Buttons\\WHITE8X8"
local ACCENT_R, ACCENT_G, ACCENT_B = 0.40, 0.85, 1.00 -- #66d9ff
local BORDER_R, BORDER_G, BORDER_B = 0.88, 0.92, 0.96

local WIDTH = 240
local PAD = 6
local HEADER_H = 22
local ROW_H = 19
local BAR_H = 16
local RANK_W = 16
local BUTTON = 16
local MAX_ROWS = 20

-- Meter modes, in cycle order. kind: "both" = total (per second), "ps" = per second
-- only, "count" = total only. fallback = Enum.DamageMeterType value if Enum is missing.
local MODES = {
    { key = "DamageDone",   label = "DAMAGE",       name = "Damage",       kind = "both",  fallback = 0 },
    { key = "Dps",          label = "DPS",          name = "DPS",          kind = "ps",    fallback = 1 },
    { key = "HealingDone",  label = "HEALING",      name = "Healing",      kind = "both",  fallback = 2 },
    { key = "Hps",          label = "HPS",          name = "HPS",          kind = "ps",    fallback = 3 },
    { key = "DamageTaken",  label = "DAMAGE TAKEN", name = "Damage Taken", kind = "both",  fallback = 7 },
    { key = "Interrupts",   label = "INTERRUPTS",   name = "Interrupts",   kind = "count", fallback = 5 },
    { key = "Dispels",      label = "DISPELS",      name = "Dispels",      kind = "count", fallback = 6 },
    { key = "Deaths",       label = "DEATHS",       name = "Deaths",       kind = "count", fallback = 9 },
}
local MODE_INDEX = {}
for i, m in ipairs(MODES) do MODE_INDEX[m.key] = i end

local METER_DEFAULTS = {
    shown = true,
    mode = "DamageDone",
    session = "current",
    pos = { "BOTTOMRIGHT", "BOTTOMRIGHT", -40, 260 },
    scale = 1,
    rows = 8,
}

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------

local meter        -- the window frame (nil until InitMeter)
local rows = {}    -- reusable row widgets
local mdb          -- db.meter
local ticker
local tickCount = 0
local pending = false
local logged = {}  -- error tags already logged once

-- Resolved enum values (filled by ResolveEnums).
local SESSION = { current = nil, overall = nil, currentSrc = "?", overallSrc = "?" }

---------------------------------------------------------------------------
-- Namespace helpers (looked up lazily so a missing helper never breaks us)
---------------------------------------------------------------------------

local function IsSecret(v)
    local f = ns.IsSecret
    if f then return f(v) end
    return issecretvalue ~= nil and issecretvalue(v) or false
end

local function Abbrev(v)
    local f = ns.Abbrev
    if f then return f(v) end
    return v
end

local function Print(msg)
    if ns.Print then ns.Print(msg) else print("SAO Frames: " .. msg) end
end

local function LogOnce(tag, err)
    if logged[tag] then return end
    logged[tag] = true
    if ns.LogError then
        pcall(ns.LogError, "SAOMeter " .. tag .. ": " .. tostring(err))
    end
end

local function GetDB()
    if ns.GetDB then return ns.GetDB() end
    return SAOFramesDB
end

local function Media(name)
    return (ns.MEDIA or ("Interface\\AddOns\\" .. ADDON .. "\\Media\\")) .. name
end

local function Font(fs, size, bold)
    if ns.SetFont then
        local ok = pcall(ns.SetFont, fs, size, bold)
        if ok then return end
    end
    fs:SetFont(STANDARD_TEXT_FONT, size, "OUTLINE")
    fs:SetTextColor(1, 1, 1)
end

-- Description of a value for debug output, never touching a secret.
local function Describe(v)
    if IsSecret(v) then return "<secret>" end
    return tostring(v)
end

local function InCombat()
    if InCombatLockdown and InCombatLockdown() then return true end
    if UnitAffectingCombat then
        local c = UnitAffectingCombat("player")
        if not IsSecret(c) and c then return true end
    end
    return false
end

---------------------------------------------------------------------------
-- API wrappers
---------------------------------------------------------------------------

local function ResolveEnums()
    local E = Enum and Enum.DamageMeterSessionType
    SESSION.current, SESSION.overall = nil, nil
    if E then
        if E.Current ~= nil then SESSION.current, SESSION.currentSrc = E.Current, "Enum.Current"
        elseif E.CurrentFight ~= nil then SESSION.current, SESSION.currentSrc = E.CurrentFight, "Enum.CurrentFight"
        elseif E.Current_Fight ~= nil then SESSION.current, SESSION.currentSrc = E.Current_Fight, "Enum.Current_Fight"
        end
        if E.Overall ~= nil then SESSION.overall, SESSION.overallSrc = E.Overall, "Enum.Overall" end
    end
    if SESSION.current == nil then SESSION.current, SESSION.currentSrc = 1, E and "fallback (Enum lacks Current)" or "fallback" end
    if SESSION.overall == nil then SESSION.overall, SESSION.overallSrc = 0, E and "fallback (Enum lacks Overall)" or "fallback" end
end

local function MeterTypeOf(mode)
    local E = Enum and Enum.DamageMeterType
    if E then return E[mode.key] end -- nil if this client's enum lacks the key
    return mode.fallback
end

local function CurrentMode()
    return MODES[MODE_INDEX[mdb and mdb.mode or "DamageDone"] or 1]
end

local function SessionTypeOf(which)
    if which == "overall" then return SESSION.overall end
    return SESSION.current
end

-- true, or false plus an optional plain reason string.
local function IsAvailable()
    local api = C_DamageMeter
    if not api then return false, "C_DamageMeter missing" end
    if not api.IsDamageMeterAvailable then
        if api.GetCombatSessionFromType then return true end
        return false, "GetCombatSessionFromType missing"
    end
    local ok, avail, reason = pcall(api.IsDamageMeterAvailable)
    if not ok then
        LogOnce("IsDamageMeterAvailable", avail)
        return api.GetCombatSessionFromType ~= nil
    end
    if IsSecret(avail) then return true end
    if avail == false then
        if type(reason) == "string" and not IsSecret(reason) then return false, reason end
        return false
    end
    return true
end

local function FetchSession(sessionType, meterType)
    local api = C_DamageMeter
    local fn = api and api.GetCombatSessionFromType
    if not fn then return nil end
    local ok, s = pcall(fn, sessionType, meterType)
    if not ok then
        LogOnce("GetCombatSessionFromType", s)
        return nil
    end
    if type(s) ~= "table" then return nil end
    return s
end

local function SourcesOf(session)
    local src = session and session.combatSources
    if type(src) ~= "table" then return nil, 0 end
    return src, #src
end

-- Fight duration in seconds, only when it is a plain number.
local function DurationOf(session, sessionType)
    local d = session and session.durationSeconds
    if type(d) == "number" and not IsSecret(d) then return d end
    local api = C_DamageMeter
    if api and api.GetSessionDurationSeconds then
        local ok, v = pcall(api.GetSessionDurationSeconds, sessionType)
        if ok and not IsSecret(v) and type(v) == "number" then return v end
    end
    return nil
end

---------------------------------------------------------------------------
-- Row painting (file-scope helpers, passed to pcall with args: no closures per tick)
---------------------------------------------------------------------------

local PaintRow, TopOf, HeightFor
do
local function SetBarRange(bar, top, value)
    bar:SetMinMaxValues(0, top)
    bar:SetValue(value)
end

local function SetName(fs, name)
    if not IsSecret(name) and type(name) == "string" and Ambiguate then
        name = Ambiguate(name, "short")
    end
    fs:SetText(name)
end

-- Per-second numbers: one decimal under 100 ("51.3"), abbreviated above ("1.2K").
-- Hidden (secret) values in combat can't be branched on, so they print whole ("1234").
local function PS(v)
    if type(v) ~= "number" then return "0" end
    if v < 100 then return ("%.1f"):format(v) end
    return Abbrev(math.floor(v + 0.5))
end

local function SetBoth(fs, total, aps)
    if IsSecret(aps) then
        fs:SetFormattedText("%s  %.0f/s", Abbrev(total), aps)
    else
        fs:SetFormattedText("%s  %s/s", Abbrev(total), PS(aps))
    end
end

local function SetPS(fs, aps)
    if IsSecret(aps) then fs:SetFormattedText("%.0f/s", aps) else fs:SetText(PS(aps) .. "/s") end
end

local function SetOne(fs, v)
    fs:SetText(Abbrev(v))
end

local function ClassRGB(class)
    if not IsSecret(class) and type(class) == "string" then
        local c = (CUSTOM_CLASS_COLORS and CUSTOM_CLASS_COLORS[class]) or (RAID_CLASS_COLORS and RAID_CLASS_COLORS[class])
        if c then return c.r, c.g, c.b end
    end
    return ACCENT_R, ACCENT_G, ACCENT_B
end

function PaintRow(row, src, kind, top)
    -- Bar fill and scale.
    -- (no "a and b or c" here: that would truth-test a possibly secret value)
    local value
    if kind == "ps" then value = src.amountPerSecond else value = src.totalAmount end
    local ok, err = pcall(SetBarRange, row.bar, top, value)
    if not ok then
        LogOnce("SetBarRange", err)
        pcall(SetBarRange, row.bar, 1, 0)
    end

    local r, g, b = ClassRGB(src.classFilename)
    row.bar:SetStatusBarColor(r, g, b, 0.9)

    local mine = src.isLocalPlayer
    if not IsSecret(mine) and mine == true then
        row.border:SetVertexColor(ACCENT_R, ACCENT_G, ACCENT_B, 1)
    else
        row.border:SetVertexColor(BORDER_R, BORDER_G, BORDER_B, 0.8)
    end

    ok, err = pcall(SetName, row.name, src.name)
    if not ok then
        LogOnce("SetName", err)
        row.name:SetText("?")
    end

    if kind == "both" then
        ok = pcall(SetBoth, row.value, src.totalAmount, src.amountPerSecond)
        if not ok then ok = pcall(SetOne, row.value, src.totalAmount) end
    elseif kind == "ps" then
        ok = pcall(SetPS, row.value, src.amountPerSecond)
    else
        ok = pcall(SetOne, row.value, src.totalAmount)
    end
    if not ok then row.value:SetText("") end

    row:Show()
end

-- Bar maximum: the top (first, pre-sorted) source's value, so #1 is always a full bar.
-- (session.maxAmount turned out not to match the top player in overall data.)
function TopOf(session, sources, kind)
    local top
    local first = sources[1]
    if first then
        if kind == "ps" then top = first.amountPerSecond else top = first.totalAmount end
    end
    if type(top) == "nil" then top = session.maxAmount end
    if type(top) == "nil" then return 1 end
    if not IsSecret(top) and (type(top) ~= "number" or top <= 0) then return 1 end
    return top
end
end -- row painting

---------------------------------------------------------------------------
-- Update
---------------------------------------------------------------------------

local function SetHeaderText(mode, sessionKey, duration)
    meter.title:SetText(mode.label)
    local label = sessionKey == "overall" and "OVERALL" or "CURRENT"
    if duration then
        local d = math.floor(duration)
        meter.session:SetFormattedText("%s  %d:%02d", label, math.floor(d / 60), d % 60)
    else
        meter.session:SetText(label)
    end
    meter.sessionBtn.label:SetText(sessionKey == "overall" and "O" or "C")
end

-- Window height for a number of rows (it shrinks to fit; at least one row tall).
function HeightFor(count)
    count = math.max(1, count)
    return HEADER_H + 5 + count * ROW_H + PAD - (ROW_H - BAR_H)
end

local function ShowNoData(text)
    if meter then meter:SetHeight(HeightFor(1)) end
    for i = 1, #rows do rows[i]:Hide() end
    meter.noData:SetText(text or "No data")
    meter.noData:Show()
end

local function Update()
    if not meter or not meter:IsShown() then return end
    pending = false
    tickCount = 0
    local mode = CurrentMode()
    local sessionKey = mdb.session
    local sessionType = SessionTypeOf(sessionKey)

    local avail, reason = IsAvailable()
    if not avail then
        SetHeaderText(mode, sessionKey, nil)
        ShowNoData(reason and ("Meter unavailable: " .. reason) or "Meter unavailable")
        return
    end

    local meterType = MeterTypeOf(mode)
    if meterType == nil then
        SetHeaderText(mode, sessionKey, nil)
        ShowNoData("Mode not supported on this client")
        return
    end

    local session = FetchSession(sessionType, meterType)
    SetHeaderText(mode, sessionKey, session and DurationOf(session, sessionType) or nil)
    local sources, n = SourcesOf(session)
    if not sources or n == 0 then
        ShowNoData("No data")
        return
    end
    meter.noData:Hide()

    local top = TopOf(session, sources, mode.kind)
    local kind = mode.kind
    meter:SetHeight(HeightFor(math.min(n, #rows)))
    for i = 1, #rows do
        local row, src = rows[i], sources[i]
        if i <= n and type(src) == "table" then
            local ok, err = pcall(PaintRow, row, src, kind, top)
            if not ok then
                LogOnce("PaintRow", err)
                row:Hide()
            end
        else
            row:Hide()
        end
    end
end

local function SafeUpdate()
    local ok, err = pcall(Update)
    if not ok then LogOnce("Update", err) end
end

local RequestUpdate, StartTicker, StopTicker, ApplyBlizzardMeter -- ApplyBlizzardMeter defined in the Blizzard meter block below
do
local blizzTick = 0
-- Event-driven updates are coalesced into one update shortly after.
local function RunPending()
    if pending then SafeUpdate() end
end

function RequestUpdate()
    if not meter or not meter:IsShown() then return end
    if pending then return end
    pending = true
    if C_Timer and C_Timer.After then
        C_Timer.After(0.15, RunPending)
    else
        SafeUpdate()
    end
end

-- One 0.5 s ticker: every tick in combat, every 4th tick (2 s) out of combat.
local function OnTick()
    if not meter or not meter:IsShown() then return end
    -- every 2 s (separate counter: tickCount is reset by SafeUpdate): catch late Blizzard frames / new entries
    blizzTick = blizzTick + 1
    if blizzTick >= 4 then blizzTick = 0; if ApplyBlizzardMeter then pcall(ApplyBlizzardMeter) end end
    tickCount = tickCount + 1
    if InCombat() or tickCount >= 4 then SafeUpdate() end
end

function StartTicker()
    if ticker or not (C_Timer and C_Timer.NewTicker) then return end
    tickCount = 0
    ticker = C_Timer.NewTicker(0.5, OnTick)
end

function StopTicker()
    if ticker then ticker:Cancel() end
    ticker = nil
end
end -- ticker

---------------------------------------------------------------------------
-- Mode / session / reset
---------------------------------------------------------------------------

local function CycleMode(step)
    local i = MODE_INDEX[mdb.mode] or 1
    i = (i - 1 + step) % #MODES + 1
    mdb.mode = MODES[i].key
    SafeUpdate()
end

local function CycleSession()
    mdb.session = mdb.session == "overall" and "current" or "overall"
    SafeUpdate()
end

local function DoReset()
    if InCombat() then
        Print("can't reset the meter in combat.")
        return
    end
    local api = C_DamageMeter
    if not (api and api.ResetAllCombatSessions) then
        Print("meter reset isn't available (C_DamageMeter.ResetAllCombatSessions missing).")
        return
    end
    local ok, err = pcall(api.ResetAllCombatSessions)
    if ok then
        Print("meter data reset.")
    else
        LogOnce("ResetAllCombatSessions", err)
        Print("meter reset failed: " .. tostring(err))
    end
    SafeUpdate()
end

if StaticPopupDialogs then
    StaticPopupDialogs["SAOFRAMES_METER_RESET"] = {
        text = "Reset all damage meter data?",
        button1 = YES, button2 = NO,
        OnAccept = function() DoReset() end,
        timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
    }
end

local function ConfirmReset()
    if InCombat() then
        Print("can't reset the meter in combat.")
        return
    end
    if StaticPopup_Show then StaticPopup_Show("SAOFRAMES_METER_RESET") else DoReset() end
end

---------------------------------------------------------------------------
-- Position
---------------------------------------------------------------------------

local function ApplyPosition()
    local p = mdb.pos
    if type(p) ~= "table" or not p[1] then p = METER_DEFAULTS.pos end
    local s = meter:GetScale()
    meter:ClearAllPoints()
    meter:SetPoint(p[1], UIParent, p[2] or p[1], (p[3] or 0) / s, (p[4] or 0) / s)
end

local function SavePosition()
    local point, _, rel, x, y = meter:GetPoint(1)
    if not point then return end
    local s = meter:GetScale()
    mdb.pos = { point, rel or point, (x or 0) * s, (y or 0) * s }
end

---------------------------------------------------------------------------
-- Widgets
---------------------------------------------------------------------------

local CreateMeter, ApplyLock
do
    local function AddBorder(f, r, g, b, a, layer)
        local t = {}
        for i = 1, 4 do
            local tex = f:CreateTexture(nil, layer or "BORDER")
            tex:SetColorTexture(r, g, b, a)
            t[i] = tex
        end
        t[1]:SetPoint("TOPLEFT"); t[1]:SetPoint("TOPRIGHT"); t[1]:SetHeight(1)
        t[2]:SetPoint("BOTTOMLEFT"); t[2]:SetPoint("BOTTOMRIGHT"); t[2]:SetHeight(1)
        t[3]:SetPoint("TOPLEFT"); t[3]:SetPoint("BOTTOMLEFT"); t[3]:SetWidth(1)
        t[4]:SetPoint("TOPRIGHT"); t[4]:SetPoint("BOTTOMRIGHT"); t[4]:SetWidth(1)
        return t
    end

    local function SetBorderColor(t, r, g, b, a)
        for i = 1, 4 do t[i]:SetColorTexture(r, g, b, a) end
    end

    local function ButtonEnter(self)
        SetBorderColor(self.edges, ACCENT_R, ACCENT_G, ACCENT_B, 1)
        if GameTooltip then
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(self.tipTitle, ACCENT_R, ACCENT_G, ACCENT_B)
            if self.tipFunc then
                GameTooltip:AddLine(self.tipFunc(), 1, 1, 1, true)
            end
            GameTooltip:Show()
        end
    end

    local function ButtonLeave(self)
        SetBorderColor(self.edges, BORDER_R, BORDER_G, BORDER_B, 0.6)
        if GameTooltip then GameTooltip:Hide() end
    end

    local function MakeButton(parent, label, tipTitle, tipFunc, onClick)
        local b = CreateFrame("Button", nil, parent)
        b:SetSize(BUTTON, BUTTON)
        b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        local bg = b:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0.06, 0.07, 0.10, 0.85)
        b.edges = AddBorder(b, BORDER_R, BORDER_G, BORDER_B, 0.6)
        local hl = b:CreateTexture(nil, "HIGHLIGHT")
        hl:SetPoint("TOPLEFT", 1, -1); hl:SetPoint("BOTTOMRIGHT", -1, 1)
        hl:SetColorTexture(ACCENT_R, ACCENT_G, ACCENT_B, 0.25)
        b.label = b:CreateFontString(nil, "OVERLAY")
        Font(b.label, 9, true)
        b.label:SetPoint("CENTER", 1, 0)
        b.label:SetText(label)
        b.tipTitle, b.tipFunc = tipTitle, tipFunc
        b:SetScript("OnEnter", ButtonEnter)
        b:SetScript("OnLeave", ButtonLeave)
        b:SetScript("OnClick", onClick)
        return b
    end

    local function MakeRow(parent, i, barW)
        local y = -(HEADER_H + 5 + (i - 1) * ROW_H)
        local bar = CreateFrame("StatusBar", nil, parent)
        bar:SetPoint("TOPLEFT", PAD + RANK_W + 2, y)
        bar:SetSize(barW, BAR_H)
        bar:SetStatusBarTexture(WHITE)
        bar:SetMinMaxValues(0, 1)
        bar:SetValue(0)

        local bg = bar:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetTexture(Media("Power"))
        bg:SetVertexColor(0, 0, 0, 0.6)

        local mask = bar:CreateMaskTexture()
        mask:SetAllPoints()
        mask:SetTexture(Media("PowerMask"), "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        bar:GetStatusBarTexture():AddMaskTexture(mask)

        local border = bar:CreateTexture(nil, "OVERLAY", nil, 1)
        border:SetAllPoints()
        border:SetTexture(Media("PowerBorder"))
        border:SetVertexColor(BORDER_R, BORDER_G, BORDER_B, 0.8)

        -- Text sits on its own frame level above the bar art.
        local textFrame = CreateFrame("Frame", nil, bar)
        textFrame:SetAllPoints()
        textFrame:SetFrameLevel(bar:GetFrameLevel() + 2)

        local value = textFrame:CreateFontString(nil, "OVERLAY")
        Font(value, 11)
        value:SetPoint("RIGHT", bar, "RIGHT", -10, 0)
        value:SetJustifyH("RIGHT")
        value:SetWordWrap(false)

        local name = textFrame:CreateFontString(nil, "OVERLAY")
        Font(name, 11)
        name:SetPoint("LEFT", bar, "LEFT", 9, 0)
        name:SetPoint("RIGHT", value, "LEFT", -4, 0)
        name:SetJustifyH("LEFT")
        name:SetWordWrap(false)
        if name.SetNonSpaceWrap then name:SetNonSpaceWrap(false) end

        local rank = bar:CreateFontString(nil, "OVERLAY")
        Font(rank, 9)
        rank:SetPoint("RIGHT", bar, "LEFT", -3, 0)
        rank:SetTextColor(ACCENT_R, ACCENT_G, ACCENT_B)
        rank:SetText(i)

        bar.bar, bar.border, bar.name, bar.value, bar.rank = bar, border, name, value, rank
        bar:Hide()
        return bar
    end

    -- Dragging (only while unlocked).
    local function DragStart()
        local db = GetDB()
        if db and db.locked then return end
        meter:StartMoving()
        meter.moving = true
    end

    local function DragStop()
        if not meter.moving then return end
        meter.moving = nil
        meter:StopMovingOrSizing()
        meter:SetUserPlaced(false)
        local db = GetDB()
        if ns.SnapToGrid and db and db.snap then
            local ok, err = pcall(ns.SnapToGrid, meter)
            if not ok then LogOnce("SnapToGrid", err) end
        end
        SavePosition()
        meter.dragEnd = GetTime and GetTime() or 0
    end

    local function TitleClick(_, button)
        -- Ignore the click that ends a drag.
        if meter.dragEnd and GetTime and GetTime() - meter.dragEnd < 0.2 then return end
        if button == "RightButton" then
            CycleSession()
        else
            CycleMode(IsShiftKeyDown and IsShiftKeyDown() and -1 or 1)
        end
    end

    local H = {} -- script handlers, created once

    function H.TitleEnter(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("SAO Meter", ACCENT_R, ACCENT_G, ACCENT_B)
        GameTooltip:AddLine("Left-click: next mode (Shift: previous)", 1, 1, 1)
        GameTooltip:AddLine("Right-click: current / overall", 1, 1, 1)
        local db = GetDB()
        if db and not db.locked then GameTooltip:AddLine("Drag to move", 0.7, 0.7, 0.7) end
        GameTooltip:Show()
    end

    function H.HideTip() if GameTooltip then GameTooltip:Hide() end end

    function H.ModeTip()
        local i = MODE_INDEX[mdb.mode] or 1
        local nextMode = MODES[i % #MODES + 1]
        return "Showing " .. MODES[i].name .. ". Click: " .. nextMode.name .. " (right-click: previous)."
    end

    function H.SessionTip()
        return mdb.session == "overall" and "Showing overall data. Click: current fight."
            or "Showing the current fight. Click: overall data."
    end

    function H.ResetTip() return "Reset all meter data (out of combat)." end
    function H.CloseTip() return "Hide the meter. /sao meter shows it again." end

    function H.ModeClick(_, button) CycleMode(button == "RightButton" and -1 or 1) end
    function H.SessionClick() CycleSession() end
    function H.ResetClick() ConfirmReset() end
    function H.CloseClick()
        H.HideTip()
        mdb.shown = false
        meter:Hide()
        Print("meter hidden. Type /sao meter to show it again.")
    end

    function H.OnShow()
        StartTicker()
        SafeUpdate()
        if ApplyBlizzardMeter then pcall(ApplyBlizzardMeter) end
    end

    function H.OnHide()
        StopTicker()
        pending = false
        -- Restore Blizzard's meter however ours was hidden (X button, toggle, ...).
        if ApplyBlizzardMeter then pcall(ApplyBlizzardMeter) end
    end

    CreateMeter = function()
        local n = mdb.rows
        local f = CreateFrame("Frame", "SAOFramesMeter", UIParent)
        meter = f
        f:SetSize(WIDTH, HeightFor(1))
        f:SetFrameStrata("MEDIUM")
        f:SetClampedToScreen(true)
        f:SetMovable(true)
        f:EnableMouse(false)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", DragStart)
        f:SetScript("OnDragStop", DragStop)
        f:Hide()

        -- Dark slate panel with a thin light border.
        local bg = f:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(1, 1, 1, 1)
        bg:SetGradient("VERTICAL", CreateColor(0.06, 0.07, 0.10, 0.80), CreateColor(0.13, 0.15, 0.19, 0.80))
        f.edges = AddBorder(f, BORDER_R, BORDER_G, BORDER_B, 0.45)

        local headBg = f:CreateTexture(nil, "BACKGROUND", nil, 1)
        headBg:SetPoint("TOPLEFT", 1, -1); headBg:SetPoint("TOPRIGHT", -1, -1)
        headBg:SetHeight(HEADER_H - 1)
        headBg:SetColorTexture(0.10, 0.12, 0.16, 0.85)

        local rule = f:CreateTexture(nil, "ARTWORK")
        rule:SetColorTexture(ACCENT_R, ACCENT_G, ACCENT_B, 0.8)
        rule:SetPoint("TOPLEFT", PAD, -HEADER_H); rule:SetPoint("TOPRIGHT", -PAD, -HEADER_H)
        rule:SetHeight(1)

        -- Header buttons, right to left: close, reset, session, mode.
        local close = MakeButton(f, "X", "Close", H.CloseTip, H.CloseClick)
        close:SetPoint("TOPRIGHT", -3, -3)
        local reset = MakeButton(f, "R", "Reset", H.ResetTip, H.ResetClick)
        reset:SetPoint("RIGHT", close, "LEFT", -2, 0)
        local sessionBtn = MakeButton(f, "C", "Current / Overall", H.SessionTip, H.SessionClick)
        sessionBtn:SetPoint("RIGHT", reset, "LEFT", -2, 0)
        f.sessionBtn = sessionBtn
        local modeBtn = sessionBtn -- (no separate mode button: click the title to change mode)

        f.session = f:CreateFontString(nil, "OVERLAY")
        Font(f.session, 9)
        f.session:SetPoint("RIGHT", modeBtn, "LEFT", -5, 0)
        f.session:SetTextColor(0.75, 0.80, 0.86)
        f.session:SetJustifyH("RIGHT")
        f.session:SetWordWrap(false)

        -- Clickable title: left-click cycles mode, right-click cycles session.
        local titleBtn = CreateFrame("Button", nil, f)
        titleBtn:SetPoint("TOPLEFT", 1, -1)
        titleBtn:SetPoint("BOTTOMRIGHT", modeBtn, "BOTTOMLEFT", -2, -2)
        titleBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        titleBtn:RegisterForDrag("LeftButton")
        titleBtn:SetScript("OnClick", TitleClick)
        titleBtn:SetScript("OnDragStart", DragStart)
        titleBtn:SetScript("OnDragStop", DragStop)
        titleBtn:SetScript("OnEnter", H.TitleEnter)
        titleBtn:SetScript("OnLeave", H.HideTip)

        local diamond = titleBtn:CreateTexture(nil, "OVERLAY")
        diamond:SetSize(6, 6)
        diamond:SetPoint("LEFT", f, "TOPLEFT", PAD + 2, -HEADER_H / 2)
        diamond:SetColorTexture(ACCENT_R, ACCENT_G, ACCENT_B, 1)
        if diamond.SetRotation then diamond:SetRotation(math.pi / 4) end

        f.title = titleBtn:CreateFontString(nil, "OVERLAY")
        Font(f.title, 11, true)
        f.title:SetPoint("LEFT", diamond, "RIGHT", 6, 0)
        f.title:SetPoint("RIGHT", f.session, "LEFT", -4, 0)
        f.title:SetJustifyH("LEFT")
        f.title:SetWordWrap(false)

        -- Rows.
        local barW = WIDTH - 2 * PAD - RANK_W - 2
        for i = 1, n do rows[i] = MakeRow(f, i, barW) end

        f.noData = f:CreateFontString(nil, "OVERLAY")
        Font(f.noData, 10)
        f.noData:SetPoint("TOP", f, "TOP", 0, -(HEADER_H + 8))
        f.noData:SetTextColor(0.7, 0.75, 0.8)
        f.noData:SetText("No data")
        f.noData:Hide()

        -- Unlocked highlight.
        local hl = f:CreateTexture(nil, "BACKGROUND", nil, 2)
        hl:SetAllPoints()
        hl:SetColorTexture(ACCENT_R, ACCENT_G, ACCENT_B, 0.07)
        hl:Hide()
        f.unlockGlow = hl
        f.dragHint = f:CreateFontString(nil, "OVERLAY")
        Font(f.dragHint, 9)
        f.dragHint:SetPoint("TOP", f, "BOTTOM", 0, -2)
        f.dragHint:SetTextColor(ACCENT_R, ACCENT_G, ACCENT_B)
        f.dragHint:SetText("drag to move")
        f.dragHint:Hide()

        f:SetScale(mdb.scale)
        ApplyPosition()
        f:SetScript("OnShow", H.OnShow)
        f:SetScript("OnHide", H.OnHide)
        return f
    end

    -- Unlocked: draggable, with a subtle highlight. Locked: clicks pass through the panel.
    ApplyLock = function(locked)
        if not meter then return end
        meter:EnableMouse(not locked)
        if locked then
            meter.unlockGlow:Hide()
            meter.dragHint:Hide()
            SetBorderColor(meter.edges, BORDER_R, BORDER_G, BORDER_B, 0.45)
            if meter.moving then DragStop() end
        else
            meter.unlockGlow:Show()
            meter.dragHint:Show()
            SetBorderColor(meter.edges, ACCENT_R, ACCENT_G, ACCENT_B, 0.8)
        end
    end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local RegisterEvents, EventsRegistered
do
local METER_EVENTS = {
    "DAMAGE_METER_COMBAT_SESSION_UPDATED",
    "DAMAGE_METER_CURRENT_SESSION_UPDATED",
    "DAMAGE_METER_RESET",
}
local eventFrame

local function OnMeterEvent()
    RequestUpdate()
end

local function OnFrameEvent(_, event, arg1)
    if event == "PLAYER_REGEN_ENABLED" or event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_ENTERING_WORLD" then
        if event ~= "PLAYER_REGEN_DISABLED" then pcall(ApplyBlizzardMeter) end -- catch late frames, fix mouse after combat
        tickCount = 0
        RequestUpdate()
    elseif event == "ADDON_LOADED" then
        if arg1 == "Blizzard_DamageMeter" then pcall(ApplyBlizzardMeter) end
    else
        OnMeterEvent()
    end
end

function RegisterEvents()
    eventFrame = CreateFrame("Frame")
    eventFrame:SetScript("OnEvent", OnFrameEvent)
    for _, e in ipairs({ "PLAYER_REGEN_ENABLED", "PLAYER_REGEN_DISABLED", "PLAYER_ENTERING_WORLD", "ADDON_LOADED" }) do
        pcall(eventFrame.RegisterEvent, eventFrame, e)
    end
    for _, e in ipairs(METER_EVENTS) do
        local ok, err = pcall(eventFrame.RegisterEvent, eventFrame, e)
        if not ok then LogOnce("RegisterEvent " .. e, err) end
    end
end

function EventsRegistered() return eventFrame ~= nil end
end -- events

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

local function InitDefaults()
    local db = GetDB()
    if type(db) ~= "table" then return nil end
    if type(db.meter) ~= "table" then db.meter = {} end
    local m = db.meter
    for k, v in pairs(METER_DEFAULTS) do
        if m[k] == nil then
            if type(v) == "table" then
                local copy = {}
                for i = 1, #v do copy[i] = v[i] end
                m[k] = copy
            else
                m[k] = v
            end
        end
    end
    if not MODE_INDEX[m.mode] then m.mode = METER_DEFAULTS.mode end
    if m.session ~= "current" and m.session ~= "overall" then m.session = "current" end
    if type(m.hideBlizzard) ~= "boolean" then m.hideBlizzard = true end
    if type(m.rows) ~= "number" then m.rows = METER_DEFAULTS.rows end
    m.rows = math.max(1, math.min(MAX_ROWS, math.floor(m.rows)))
    if type(m.scale) ~= "number" or m.scale <= 0.2 or m.scale > 3 then m.scale = 1 end
    if type(m.pos) ~= "table" or type(m.pos[1]) ~= "string" then
        m.pos = { METER_DEFAULTS.pos[1], METER_DEFAULTS.pos[2], METER_DEFAULTS.pos[3], METER_DEFAULTS.pos[4] }
    end
    return m
end

---------------------------------------------------------------------------
-- Blizzard's built-in meter: fade it out (alpha 0, no mouse) while ours is shown.
-- Never Hide() it or turn off its CVar - that taints / may stop the data feed.
---------------------------------------------------------------------------
do
local hooked = setmetatable({}, { __mode = "k" })
local function BlizzFrames()
    local list = {}
    if _G.DamageMeter then list[#list + 1] = _G.DamageMeter end
    for i = 1, 3 do
        local w = _G["DamageMeterSessionWindow" .. i]
        if w then list[#list + 1] = w end
    end
    return list
end
local faded = setmetatable({}, { __mode = "k" })
local mouseOrig = setmetatable({}, { __mode = "k" }) -- frame -> { click, motion, wheel } before we turned the mouse off
local alphaOrig = setmetatable({}, { __mode = "k" }) -- frame -> alpha before our fade
-- EnableMouse is only blocked on protected frames in combat; these display frames are normally not protected.
local function CanTouch(fr)
    local okp, prot = pcall(fr.IsProtected, fr)
    return not (InCombatLockdown and InCombatLockdown() and okp and prot)
end
local function ReadBool(fr, method)
    if not fr[method] then return nil end
    local ok, v = pcall(fr[method], fr)
    if ok and not IsSecret(v) and type(v) == "boolean" then return v end
    return nil
end
-- Alpha 0 still takes mouse input, and EnableMouse on a parent doesn't reach children: walk the tree.
local function MouseOff(fr)
    if CanTouch(fr) then
        if mouseOrig[fr] == nil then
            local click, motion
            if fr.IsMouseClickEnabled and fr.IsMouseMotionEnabled then
                click, motion = ReadBool(fr, "IsMouseClickEnabled"), ReadBool(fr, "IsMouseMotionEnabled")
            else
                click = ReadBool(fr, "IsMouseEnabled")
                motion = click
            end
            mouseOrig[fr] = { click == true, motion == true, ReadBool(fr, "IsMouseWheelEnabled") == true }
        end
        if fr.EnableMouse then pcall(fr.EnableMouse, fr, false) end
        if fr.EnableMouseWheel then pcall(fr.EnableMouseWheel, fr, false) end
    end
    if fr.GetChildren then
        local kids = { pcall(fr.GetChildren, fr) }
        if kids[1] then
            for i = 2, #kids do
                if type(kids[i]) == "table" then MouseOff(kids[i]) end
            end
        end
    end
end
-- Iterates mouseOrig (not current children) so recycled entries are restored too; frames still locked wait for the next call.
local function RestoreMouse()
    local done = {}
    for fr, o in pairs(mouseOrig) do
        if CanTouch(fr) then
            if fr.SetMouseClickEnabled and fr.SetMouseMotionEnabled then
                pcall(fr.SetMouseClickEnabled, fr, o[1])
                pcall(fr.SetMouseMotionEnabled, fr, o[2])
            elseif fr.EnableMouse then
                pcall(fr.EnableMouse, fr, o[1] or o[2])
            end
            if fr.EnableMouseWheel then pcall(fr.EnableMouseWheel, fr, o[3]) end
            done[#done + 1] = fr
        end
    end
    for i = 1, #done do mouseOrig[done[i]] = nil end
end
local function Fade(f)
    local hide = meter and meter:IsShown() and mdb and mdb.hideBlizzard
    if hide then
        if not faded[f] then
            local ok, a = pcall(f.GetAlpha, f)
            if ok and type(a) == "number" and not IsSecret(a) and a > 0 then alphaOrig[f] = a end
        end
        faded[f] = true
        pcall(f.SetAlpha, f, 0)
        MouseOff(f)
    elseif faded[f] then
        -- only undo our own fade; leave Blizzard's own opacity alone otherwise
        faded[f] = nil
        pcall(f.SetAlpha, f, alphaOrig[f] or 1)
        alphaOrig[f] = nil
    end
end
function ApplyBlizzardMeter()
    for _, f in ipairs(BlizzFrames()) do
        if not hooked[f] then
            hooked[f] = true
            hooksecurefunc(f, "Show", function(self) Fade(self) end)
            if f.SetShown then hooksecurefunc(f, "SetShown", function(self) Fade(self) end) end
        end
        Fade(f)
    end
    if not (meter and meter:IsShown() and mdb and mdb.hideBlizzard) then RestoreMouse() end
end
end -- blizzard meter

function ns.InitMeter()
    if meter then return end
    mdb = InitDefaults()
    if not mdb then
        LogOnce("InitMeter", "saved variables not ready")
        return
    end
    ResolveEnums()
    CreateMeter()
    RegisterEvents()
    local db = GetDB()
    ApplyLock(not db or db.locked ~= false)
    if mdb.shown then meter:Show() end
    pcall(ApplyBlizzardMeter)
    -- Blizzard_DamageMeter may load after us; re-apply once it does.
    if C_Timer then C_Timer.After(3, function() pcall(ApplyBlizzardMeter) end) end
end

function ns.IsMeterShown()
    return meter ~= nil and meter:IsShown() or false
end

function ns.ToggleMeter()
    if not meter then
        Print("meter isn't ready yet.")
        return
    end
    if meter:IsShown() then
        meter:Hide()
        mdb.shown = false
    else
        meter:Show()
        mdb.shown = true
    end
    pcall(ApplyBlizzardMeter)
end

function ns.MeterSetLocked(locked)
    if ApplyLock then ApplyLock(locked and true or false) end
end

function ns.MeterReset()
    DoReset()
end

-- /sao reset: put the window back at its default position.
function ns.MeterResetPosition()
    if not mdb then return end
    local d = METER_DEFAULTS.pos
    mdb.pos = { d[1], d[2], d[3], d[4] }
    if not meter then return end
    if meter.moving then meter.moving = nil; meter:StopMovingOrSizing() end
    meter:SetUserPlaced(false)
    ApplyPosition()
end

do
local function DebugSession(label, sessionType, meterType)
    local s = FetchSession(sessionType, meterType)
    if not s then
        Print(("  %s (type %s): no session"):format(label, Describe(sessionType)))
        return
    end
    local sources, n = SourcesOf(s)
    Print(("  %s (type %s): %d sources, totalAmount %s, maxAmount %s, durationSeconds %s"):format(
        label, Describe(sessionType), n, Describe(s.totalAmount), Describe(s.maxAmount), Describe(s.durationSeconds)))
    local first = sources and sources[1]
    if type(first) == "table" then
        Print(("  first source: name %s, total %s, perSecond %s, class %s, local %s, spec %s, guid %s"):format(
            IsSecret(first.name) and "secret" or "plain",
            IsSecret(first.totalAmount) and "secret" or "plain",
            IsSecret(first.amountPerSecond) and "secret" or "plain",
            Describe(first.classFilename), Describe(first.isLocalPlayer),
            Describe(first.specIconID), IsSecret(first.sourceGUID) and "secret" or "plain"))
    end
end

function ns.MeterDebug()
    local api = C_DamageMeter
    Print("meter debug:")
    if not api then
        Print("  C_DamageMeter: missing")
        return
    end
    local avail, reason = IsAvailable()
    Print(("  available: %s%s, in combat: %s"):format(tostring(avail), reason and (" (" .. reason .. ")") or "",
        tostring(InCombat())))
    Print(("  functions: GetCombatSessionFromType %s, GetSessionDurationSeconds %s, ResetAllCombatSessions %s, IsDamageMeterAvailable %s"):format(
        tostring(api.GetCombatSessionFromType ~= nil), tostring(api.GetSessionDurationSeconds ~= nil),
        tostring(api.ResetAllCombatSessions ~= nil), tostring(api.IsDamageMeterAvailable ~= nil)))
    if SESSION.current == nil then ResolveEnums() end
    Print(("  session types: current = %s [%s], overall = %s [%s]"):format(
        Describe(SESSION.current), SESSION.currentSrc, Describe(SESSION.overall), SESSION.overallSrc))
    local E = Enum and Enum.DamageMeterSessionType
    if E then
        local parts = {}
        for k, v in pairs(E) do parts[#parts + 1] = tostring(k) .. "=" .. Describe(v) end
        table.sort(parts)
        Print("  Enum.DamageMeterSessionType: " .. table.concat(parts, ", "))
    else
        Print("  Enum.DamageMeterSessionType: missing (using numbers)")
    end
    local mode = mdb and CurrentMode() or MODES[1]
    local meterType = MeterTypeOf(mode)
    Print(("  mode: %s, meter type = %s [%s]"):format(mode.key, Describe(meterType),
        (Enum and Enum.DamageMeterType and Enum.DamageMeterType[mode.key] ~= nil) and "Enum" or "fallback"))
    DebugSession("current", SESSION.current, meterType)
    DebugSession("overall", SESSION.overall, meterType)
    if C_CVar and C_CVar.GetCVar then
        local ok, v = pcall(C_CVar.GetCVar, "damageMeterEnabled")
        if ok then Print("  CVar damageMeterEnabled: " .. Describe(v)) end
    end
    Print(("  window: %s, rows %d, events %s"):format(ns.IsMeterShown() and "shown" or "hidden",
        #rows, EventsRegistered() and "registered" or "not registered"))
end
end -- debug
