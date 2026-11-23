-- SAO Frames: Sword Art Online-styled skin of Blizzard's quest NPC windows (SAOQuest.lua).
--
-- A SKIN, not a replacement: QuestFrame (Detail = pick up, Progress = required items,
-- Reward = turn in / choose a reward, Greeting = NPC with several quests) and GossipFrame
-- (NPC talk / quest list) keep all of their own logic: accepting, declining, completing,
-- choosing a reward (Blizzard's click handler and QuestInfoFrame.itemChoice), item tooltips
-- and shift-links, scrolling, gossip options and Escape / close. We only hide their art
-- (SetAlpha(0), remembered so a disable can put it back), draw a soft steel-gray SAO panel
-- behind them, restyle their text and re-texture their buttons.
--
-- Blizzard re-colors text on every display (QuestInfo_Display / material colors / the gossip
-- theme), so colors are re-applied after it: hooksecurefunc on QuestInfo_Display,
-- QuestInfoItem_OnClick, QuestFrameProgressItems_Update, QuestFrame_SetPortrait,
-- MoneyFrame_Update / SetMoneyFrameColor, HookScript("OnShow") on the four panels (their
-- OnShow handlers are bound from XML, so hooking the global names alone would not fire), and
-- ScrollUtil.AddInitializedFrameCallback on the gossip ScrollBox.
--
-- QuestInfoFrame (title / description / objectives / rewards) is shared with the quest log
-- details: every font / color / alpha change on it is undone when Blizzard displays it
-- anywhere other than the QuestFrame panels.
--
-- No Blizzard function is replaced and no field is written onto a Blizzard frame (all our
-- per-frame state lives in weak-keyed tables). Secret values: NPC names only ever go to
-- FontString:SetText; every other value read back is checked with IsSecret before any logic.
--
-- Public (on ns): InitQuest, QuestSetEnabled, IsQuestEnabled. db.quest = { enabled }.

local ADDON, ns = ...

---------------------------------------------------------------------------
-- Constants
---------------------------------------------------------------------------

local WHITE = "Interface\\Buttons\\WHITE8X8"
local BOOK_ICON = "Interface\\QuestFrame\\UI-QuestLog-BookIcon"
local QUEST_DEFAULTS = { enabled = true }
local MAX_PROGRESS_ITEMS = 10
local DISC = 22                       -- round button disc size
local BTN_W, BTN_H = 140, 28          -- action button hit box

local DARK = { 0.20, 0.22, 0.26 }     -- body text
local TITLE = { 0.14, 0.16, 0.20 }    -- quest title
local LABEL = { 0.42, 0.45, 0.50 }    -- small uppercase labels
local ORANGE = { 1.00, 0.60, 0.15 }   -- hover / selected
local CYAN = { 0.30, 0.85, 1.00 }     -- accent line
local BLUE = { 0.35, 0.70, 1.00 }     -- confirm glow
local RED = { 1.00, 0.35, 0.35 }      -- cancel glow
local DIVIDER = { 0.55, 0.60, 0.68, 0.55 }
local RING_PLAIN = { 0.78, 0.80, 0.84 }
local CARD = { 0.92, 0.93, 0.95 }
local CARD_RED = { 0.93, 0.76, 0.76 }
local CARD_SEL = { 1.00, 0.87, 0.72 }

-- Round action buttons: { global name, disc texture, glow color }.
local ACTIONS = {
    { "QuestFrameAcceptButton", "LootNeed", BLUE },
    { "QuestFrameCompleteButton", "LootNeed", BLUE },       -- progress panel: Continue
    { "QuestFrameCompleteQuestButton", "LootNeed", BLUE },  -- reward panel: Complete Quest
    { "QuestFrameDeclineButton", "LootPass", RED },
    { "QuestFrameGoodbyeButton", "LootPass", RED },         -- progress panel: Cancel
    { "QuestFrameGreetingGoodbyeButton", "LootPass", RED },
}

local PANELS = {
    { "QuestFrameDetailPanel", "QuestDetailScrollFrame" },
    { "QuestFrameProgressPanel", "QuestProgressScrollFrame" },
    { "QuestFrameRewardPanel", "QuestRewardScrollFrame" },
    { "QuestFrameGreetingPanel", "QuestGreetingScrollFrame" },
}

-- QuestInfoFrame text (shared with the quest log: styled only inside QuestFrame).
local INFO_TITLES = { "QuestInfoTitleHeader" }
local INFO_BODY = { "QuestInfoDescriptionText", "QuestInfoObjectivesText", "QuestInfoRewardText",
    "QuestInfoGroupSize", "QuestInfoQuestType", "QuestInfoAnchor", "QuestInfoTimerText",
    "QuestInfoSpellObjectiveLearnLabel", "QuestInfoRequiredMoneyText" }
local INFO_HEADERS = { "QuestInfoDescriptionHeader", "QuestInfoObjectivesHeader" }
local REWARD_BODY = { "PlayerTitleText", "QuestSessionBonusReward" }       -- on QuestInfoRewardsFrame
local REWARD_SECTIONS = { "Header", "ItemChooseText", "ItemReceiveText" } -- on QuestInfoRewardsFrame

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------

local qdb               -- db.quest
local enabled = false
local skinnedQuest = false
local skinnedGossip = false
local pendingCombat = false
local infoStyled = false  -- QuestInfoFrame currently wears our style
local events
local logged = {}
local hooked = {}
local qui, gui = {}, {}   -- our chrome on QuestFrame / GossipFrame
local fonts = {}          -- our button font objects

local weak = { __mode = "k" }
local own = setmetatable({}, weak)       -- regions we created
local dynamic = setmetatable({}, weak)   -- our regions whose shown state a refresh decides
local hidden = setmetatable({}, weak)    -- Blizzard region -> its alpha before we hid it
local saved = setmetatable({}, weak)     -- Blizzard FontString -> original font / shadow / color
local ctxKill = setmetatable({}, weak)   -- Blizzard regions hidden only while QuestInfo is ours
local ctxOwn = setmetatable({}, weak)    -- our regions shown only while QuestInfo is ours
local items = setmetatable({}, weak)     -- item / reward button -> our parts
local sections = setmetatable({}, weak)  -- header FontString -> { label, line }
local rows = setmetatable({}, weak)      -- list row button -> our parts
local btnUI = setmetatable({}, weak)     -- action button -> disc parts
local lastColor = setmetatable({}, weak) -- FontString -> color we set (idempotent darkening)
local hookedFrame = setmetatable({}, weak)
local infoFS = setmetatable({}, weak)    -- QuestInfo FontStrings we restyled (undone outside QuestFrame)
local moneyFS = setmetatable({}, weak)   -- money / number FontStrings we recolored
local infoParent                         -- parentFrame of the last QuestInfo_Display call
local MONEY_GOLD = { 0.72, 0.55, 0.05 }

local RefreshQuest, RefreshRewards -- forward declarations (defined below)

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

local function LogOnce(tag, err)
    if logged[tag] then return end
    logged[tag] = true
    if ns.LogError then pcall(ns.LogError, "SAOQuest " .. tag .. ": " .. tostring(err)) end
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
    if type(db.quest) ~= "table" then db.quest = {} end
    local q = db.quest
    if type(q.enabled) ~= "boolean" then q.enabled = QUEST_DEFAULTS.enabled end
    return q
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

local function Field(t, key)
    if not t then return nil end
    local ok, v = pcall(function() return t[key] end)
    if ok and not IsSecret(v) then return v end
    return nil
end

local function Shown(r)
    if not (r and r.IsShown) then return false end
    local ok, s = pcall(r.IsShown, r)
    return ok and not IsSecret(s) and s and true or false
end

local function Defer(fn)
    if C_Timer and C_Timer.After then C_Timer.After(0, fn) else fn() end
end

-- Button / label font: the SAO font only for Latin locales (localized labels need glyphs).
local LATIN = { enUS = true, enGB = true, deDE = true, frFR = true, esES = true, esMX = true,
    itIT = true, ptBR = true }
local function LabelFontPath()
    local ok, loc = pcall(GetLocale)
    if ns.fontPath and ok and type(loc) == "string" and LATIN[loc] then return ns.fontPath end
    return STANDARD_TEXT_FONT
end

local function NewText(parent, size, color)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    own[fs] = true
    if not (pcall(fs.SetFont, fs, STANDARD_TEXT_FONT, size, "") and fs:GetFont()) then
        fs:SetFontObject(GameFontNormal)
    end
    fs:SetShadowOffset(0, 0)
    local c = color or LABEL
    fs:SetTextColor(c[1], c[2], c[3])
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

local function Unkill(region)
    if region and hidden[region] ~= nil then pcall(region.SetAlpha, region, hidden[region]) end
end

-- Dim (not hide) a Blizzard region, e.g. scroll bars.
local function Fade(region, a)
    if not (region and region.SetAlpha) or own[region] then return end
    if hidden[region] == nil then
        local ok, old = pcall(region.GetAlpha, region)
        hidden[region] = (ok and type(old) == "number" and not IsSecret(old)) and old or 1
    end
    pcall(region.SetAlpha, region, a)
end

local function StripTextures(frame)
    if not (frame and frame.GetRegions) then return end
    for _, r in ipairs({ frame:GetRegions() }) do
        local ok, kind = pcall(r.GetObjectType, r)
        if ok and kind == "Texture" and not own[r] then Kill(r) end
    end
end

-- 9-slice texture (manual): texSize/slice in texture pixels, disp the on-screen corner size,
-- l/t/r/b offsets of the outer edge from `anchor`'s corners.
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

local function SliceColor(s, c, a)
    for _, tex in ipairs(s) do tex:SetVertexColor(c[1], c[2], c[3], a or 1) end
end

local function SliceShown(s, on)
    for _, tex in ipairs(s) do tex:SetShown(on) end
end

-- Invisible region used only as an anchor box for slices.
local function Box(owner)
    return NewTexture(owner, "BACKGROUND", -8)
end

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

-- Round close button (keeps Blizzard's OnClick).
local function RoundClose(btn)
    if not btn then return end
    btn:SetSize(20, 20)
    local function apply(setter, getter, tint)
        if not btn[setter] then return end
        pcall(btn[setter], btn, Media("LootPass"))
        local t = btn[getter] and btn[getter](btn)
        if not t then return end
        pcall(t.SetTexCoord, t, 0, 1, 0, 1)
        t:ClearAllPoints()
        t:SetAllPoints(btn)
        t:SetVertexColor(tint, tint, tint)
    end
    apply("SetNormalTexture", "GetNormalTexture", 1)
    apply("SetPushedTexture", "GetPushedTexture", 0.82)
    apply("SetDisabledTexture", "GetDisabledTexture", 0.6)
    RoundHighlight(btn, btn, 30, RED)
end

local function Near(a, b) return math.abs(a - b) < 0.012 end

local function ReadColor(fs)
    if not (fs and fs.GetTextColor) then return nil end
    local ok, r, g, b = pcall(fs.GetTextColor, fs)
    if not ok or type(r) ~= "number" or IsSecret(r) or IsSecret(g) or IsSecret(b) then return nil end
    return r, g, b
end

local function SetColor(fs, c)
    if fs and fs.SetTextColor then pcall(fs.SetTextColor, fs, c[1], c[2], c[3]) end
end

-- Item names: white / very light ones are unreadable on our panel -> slate; quality colors
-- are darkened a bit. Returns the original color (for the ring). Idempotent via lastColor.
local function NameColor(fs)
    local r, g, b = ReadColor(fs)
    if not r then return nil end
    local c = lastColor[fs]
    if c and Near(c[1], r) and Near(c[2], g) and Near(c[3], b) then return c[4], c[5], c[6] end
    local nr, ng, nb, rr, rg, rb
    if r > 0.9 and g > 0.9 and b > 0.9 then
        nr, ng, nb = DARK[1], DARK[2], DARK[3]
        rr, rg, rb = RING_PLAIN[1], RING_PLAIN[2], RING_PLAIN[3]
    elseif r > 0.9 and g > 0.75 and b < 0.25 then
        nr, ng, nb = 0.62, 0.45, 0.02           -- GameFontNormal yellow -> dark gold
        rr, rg, rb = RING_PLAIN[1], RING_PLAIN[2], RING_PLAIN[3]
    else
        nr, ng, nb = r * 0.82, g * 0.82, b * 0.82
        rr, rg, rb = r, g, b
    end
    fs:SetTextColor(nr, ng, nb)
    lastColor[fs] = { nr, ng, nb, rr, rg, rb }
    return rr, rg, rb
end

-- Numbers on the light panel: no outline / shadow; white -> slate, yellow -> dark gold,
-- red ("not enough money") stays.
local Save -- forward (defined below)
local function MoneyText(fs, info)
    if not (fs and fs.GetFont) or own[fs] then return end
    Save(fs)
    moneyFS[fs] = true
    if info then infoFS[fs] = true end
    local okF, font, size = pcall(fs.GetFont, fs)
    if okF and font then pcall(fs.SetFont, fs, font, size or 12, "") end
    pcall(fs.SetShadowOffset, fs, 0, 0)
    local r, g, b = ReadColor(fs)
    if not r then return end
    if r > 0.9 and g > 0.9 and b > 0.9 then
        fs:SetTextColor(DARK[1], DARK[2], DARK[3])
    elseif r > 0.9 and g > 0.7 and b < 0.25 then
        fs:SetTextColor(MONEY_GOLD[1], MONEY_GOLD[2], MONEY_GOLD[3])
    end
end

local function ButtonText(btn)
    if not btn then return nil end
    local fs = Child(btn, "Text")
    if not fs and btn.GetFontString then fs = btn:GetFontString() end
    return fs
end

local function RecolorMoneyFrame(frame, info)
    if not frame then return end
    for _, key in ipairs({ "GoldButton", "SilverButton", "CopperButton" }) do
        MoneyText(ButtonText(Child(frame, key)), info)
    end
end

---------------------------------------------------------------------------
-- Text styling (saved first so it can be undone)
---------------------------------------------------------------------------

function Save(fs)
    if saved[fs] then return end
    local s = {}
    local ok, f, size, flags = pcall(fs.GetFont, fs)
    if ok and f then s.font, s.size, s.flags = f, size, flags end
    local okS, sx, sy = pcall(fs.GetShadowOffset, fs)
    if okS then s.sx, s.sy = sx, sy end
    s.r, s.g, s.b = ReadColor(fs)
    saved[fs] = s
end

local function NearC(r, g, b, c) return Near(r, c[1]) and Near(g, c[2]) and Near(b, c[3]) end

-- Font / shadow come back; the color only if it is still ours (Blizzard may have re-colored
-- the string since, e.g. QuestInfo_Display on a material change or SetMoneyFrameColor).
local function Unstyle(fs)
    local s = fs and saved[fs]
    if not s then return end
    if s.font then pcall(fs.SetFont, fs, s.font, s.size, s.flags or "") end
    if s.sx then pcall(fs.SetShadowOffset, fs, s.sx, s.sy) end
    local r, g, b = ReadColor(fs)
    if r and moneyFS[fs] then
        if NearC(r, g, b, DARK) then pcall(fs.SetTextColor, fs, 1, 1, 1)
        elseif NearC(r, g, b, MONEY_GOLD) then pcall(fs.SetTextColor, fs, 1, 0.82, 0) end
    elseif s.r and (not r or NearC(r, g, b, DARK) or NearC(r, g, b, TITLE)) then
        pcall(fs.SetTextColor, fs, s.r, s.g, s.b)
    end
    lastColor[fs] = nil
end

-- kind: "title" (dark slate, bold-ish standard font) or "body" (Blizzard's face, dark slate).
local function Style(fs, kind)
    if not (fs and fs.SetTextColor) or own[fs] then return end
    Save(fs)
    pcall(fs.SetShadowOffset, fs, 0, 0)
    if kind == "title" then
        local s = saved[fs]
        local size = (type(s.size) == "number" and not IsSecret(s.size)) and math.max(13, math.min(16, s.size)) or 15
        pcall(fs.SetFont, fs, STANDARD_TEXT_FONT, size, "")
        SetColor(fs, TITLE)
    else
        SetColor(fs, DARK)
    end
end

-- Section header ("Required items", "Rewards", ...): Blizzard's FontString keeps its place
-- in the layout (alpha 0); our small uppercase gray label + a thin divider sit on it.
local function Section(fs, noLine)
    if not (fs and fs.GetParent) or own[fs] then return end
    local p = sections[fs]
    if not p then
        local parent = fs:GetParent()
        if not (parent and parent.CreateFontString) then return end
        p = {}
        p.label = NewText(parent, 9, LABEL)
        p.label:SetWordWrap(true)
        p.label:SetJustifyH("LEFT")
        p.label:SetPoint("TOPLEFT", fs, "TOPLEFT", 0, -3)
        p.label:SetPoint("RIGHT", parent, "RIGHT", -10, 0)
        dynamic[p.label] = true
        if not noLine then
            p.line = ColorTex(parent, "ARTWORK", 0, DIVIDER, DIVIDER[4])
            p.line:SetHeight(1)
            p.line:SetPoint("TOPLEFT", fs, "TOPLEFT", 0, 2)
            p.line:SetPoint("RIGHT", parent, "RIGHT", -10, 0)
            dynamic[p.line] = true
        end
        sections[fs] = p
    end
    Kill(fs)
    local ok, t = pcall(fs.GetText, fs)
    if ok then
        if type(t) == "string" and not IsSecret(t) and not t:find("|", 1, true) then
            t = string.upper((t:gsub("[:：]%s*$", "")))
        end
        pcall(p.label.SetText, p.label, t)
    end
    local on = Shown(fs)
    p.label:SetShown(on)
    if p.line then p.line:SetShown(on) end
end

local function Unsection(fs)
    local p = fs and sections[fs]
    if not p then return end
    Unkill(fs)
    p.label:Hide()
    if p.line then p.line:Hide() end
end

---------------------------------------------------------------------------
-- Item / reward buttons (LargeItemButtonTemplate: Icon, NameFrame, Name, Count, IconBorder)
---------------------------------------------------------------------------

local function CtxKill(region, ctx)
    if not region then return end
    if ctx then ctxKill[region] = true end
    Kill(region)
end

local function CtxOwn(region, ctx)
    dynamic[region] = true
    if ctx then ctxOwn[region] = true end
end

local function SkinItemButton(btn, ctx)
    if not (btn and btn.CreateTexture) then return nil end
    if items[btn] then return items[btn] end
    local p = { ctx = ctx, button = btn }
    p.nameFrame = Child(btn, "NameFrame")
    p.border = Child(btn, "IconBorder")
    CtxKill(p.nameFrame, ctx)
    CtxKill(p.border, ctx)
    p.box = Box(btn)
    p.box:SetPoint("TOPLEFT", btn, "TOPLEFT", -3, 3)
    p.box:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 3, -3)
    p.card = MakeSlices(btn, p.box, Media("MerchantCard"), 64, 16, 10, 0, 0, 0, 0, "BACKGROUND", -8)
    SliceColor(p.card, CARD)
    for _, t in ipairs(p.card) do CtxOwn(t, ctx) end
    p.line = ColorTex(btn, "BACKGROUND", -7, DIVIDER, DIVIDER[4])
    p.line:SetHeight(1)
    p.line:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 8, -5)
    p.line:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -8, -5)
    CtxOwn(p.line, ctx)
    local icon = Child(btn, "Icon", "IconTexture")
    if icon and icon.SetSize then
        -- a little smaller so the ring fits inside the row height
        icon:SetSize(34, 34)
        icon:ClearAllPoints()
        icon:SetPoint("TOPLEFT", btn, "TOPLEFT", 3, -3)
        RoundIcon(btn, icon)
        p.outer = NewTexture(btn, "ARTWORK", 6, Media("LootRing"))
        p.outer:SetPoint("CENTER", icon, "CENTER")
        p.outer:SetSize(40, 40)
        p.outer:SetVertexColor(RING_PLAIN[1], RING_PLAIN[2], RING_PLAIN[3])
        p.inner = NewTexture(btn, "ARTWORK", 7, Media("LootRing"))
        p.inner:SetPoint("CENTER", icon, "CENTER")
        p.inner:SetSize(36, 36)
        p.sel = NewTexture(btn, "OVERLAY", 4, Media("LootButtonHi"))
        pcall(p.sel.SetBlendMode, p.sel, "ADD")
        p.sel:SetPoint("CENTER", icon, "CENTER")
        p.sel:SetSize(50, 50)
        p.sel:SetVertexColor(ORANGE[1], ORANGE[2], ORANGE[3], 0.9)
        p.sel:Hide()
        CtxOwn(p.outer, ctx); CtxOwn(p.inner, ctx); CtxOwn(p.sel, ctx)
        RoundHighlight(btn, icon, 46, ORANGE)
    end
    p.name = Child(btn, "Name")
    if p.name then
        -- Blizzard never re-colors Name (only SetText), so this original stays valid
        p.nr, p.ng, p.nb = ReadColor(p.name)
        local ok, sx, sy = pcall(p.name.GetShadowOffset, p.name)
        if ok and type(sx) == "number" and not IsSecret(sx) and not IsSecret(sy) then p.sx, p.sy = sx, sy end
    end
    items[btn] = p
    return p
end

-- Give a button's Name its Blizzard color / shadow back (it sits on Blizzard's dark name frame again).
local function RestoreName(p)
    local fs = p and p.name
    if not fs then return end
    if p.nr and lastColor[fs] then pcall(fs.SetTextColor, fs, p.nr, p.ng, p.nb) end
    lastColor[fs] = nil
    if p.sx then pcall(fs.SetShadowOffset, fs, p.sx, p.sy) end
end

-- The reward the player has picked (Blizzard keeps it in QuestInfoFrame.itemChoice).
local function IsChosen(btn)
    local hl = G("QuestInfoItemHighlight")
    if hl and not Shown(hl) then return false end
    local choice = Field(G("QuestInfoFrame"), "itemChoice")
    if type(choice) ~= "number" or choice <= 0 then return false end
    if Field(btn, "type") ~= "choice" then return false end
    local ok, id = pcall(btn.GetID, btn)
    return ok and not IsSecret(id) and id == choice
end

local function RefreshItemButton(btn, ctxOn)
    local p = btn and items[btn]
    if not p then return end
    local on = not p.ctx or ctxOn
    SliceShown(p.card, on)
    p.line:SetShown(on)
    if p.outer then p.outer:SetShown(on); p.inner:SetShown(on) end
    if not on then
        if p.sel then p.sel:Hide() end
        RestoreName(p)
        return
    end
    if p.name then pcall(p.name.SetShadowOffset, p.name, 0, 0) end
    -- ring color: Blizzard's quality border (hidden by us) if it is shown, else the name color
    local rr, rg, rb
    if p.border and Shown(p.border) and p.border.GetVertexColor then
        local ok, r, g, b = pcall(p.border.GetVertexColor, p.border)
        if ok and type(r) == "number" and not IsSecret(r) and not IsSecret(g) and not IsSecret(b) then
            rr, rg, rb = r, g, b
        end
    end
    local nr, ng, nb = NameColor(p.name)
    if not rr then rr, rg, rb = nr, ng, nb end
    -- Blizzard tints the (hidden) name frame red when the item can't be used.
    local red = false
    if p.nameFrame and p.nameFrame.GetVertexColor then
        local ok, r, g, b = pcall(p.nameFrame.GetVertexColor, p.nameFrame)
        red = ok and type(r) == "number" and not IsSecret(r) and not IsSecret(g) and not IsSecret(b)
            and r > 0.4 and g < 0.2 and b < 0.2 or false
    end
    local chosen = IsChosen(btn)
    SliceColor(p.card, chosen and CARD_SEL or red and CARD_RED or CARD)
    if p.outer then
        if chosen then
            p.outer:SetVertexColor(ORANGE[1], ORANGE[2], ORANGE[3])
        elseif rr then
            p.outer:SetVertexColor(rr, rg, rb)
        else
            p.outer:SetVertexColor(RING_PLAIN[1], RING_PLAIN[2], RING_PLAIN[3])
        end
        p.sel:SetShown(chosen)
    end
end

---------------------------------------------------------------------------
-- Round action buttons (Accept / Continue / Complete = blue, Decline / Cancel / Goodbye = red)
---------------------------------------------------------------------------

local function ButtonFonts()
    if fonts.n then return end
    local function Make(name, c)
        local f = _G[name]
        if type(f) ~= "table" then f = CreateFont(name) end
        if not pcall(f.SetFont, f, LabelFontPath(), 10, "") then pcall(f.SetFont, f, STANDARD_TEXT_FONT, 10, "") end
        f:SetShadowOffset(0, 0)
        f:SetTextColor(c[1], c[2], c[3])
        return f
    end
    fonts.n = Make("SAOFramesQuestButtonFont", DARK)
    fonts.h = Make("SAOFramesQuestButtonFontHi", { 0.95, 0.50, 0.10 })
    fonts.d = Make("SAOFramesQuestButtonFontOff", { 0.58, 0.60, 0.64 })
end

local function RefreshActionButton(btn)
    local d = btn and btnUI[btn]
    if not d then return end
    local ok, en = pcall(btn.IsEnabled, btn)
    local on = not ok or IsSecret(en) or (en and true or false)
    pcall(d.disc.SetDesaturated, d.disc, not on)
    d.disc:SetAlpha(on and 1 or 0.45)
    -- uppercase label (Blizzard may change the text, e.g. Accept -> OK for auto-accepted quests)
    local okT, t = pcall(btn.GetText, btn)
    if okT and type(t) == "string" and not IsSecret(t) and not t:find("|", 1, true) then
        local u = string.upper(t)
        if u ~= t then pcall(btn.SetText, btn, u) end
    end
end

local function DiscDown(btn)
    local d = enabled and btnUI[btn]
    if d and btn:IsEnabled() then d.disc:SetSize(DISC - 3, DISC - 3) end
end

local function DiscUp(btn)
    local d = btnUI[btn]
    if d then d.disc:SetSize(DISC, DISC) end
end

local function SkinActionButton(btn, tex, glow)
    if not (btn and btn.CreateTexture) or btnUI[btn] then return end
    for _, k in ipairs({ "Left", "Middle", "Right" }) do Kill(Child(btn, k)) end
    for _, getter in ipairs({ "GetNormalTexture", "GetPushedTexture", "GetDisabledTexture", "GetHighlightTexture" }) do
        if btn[getter] then
            local ok, t = pcall(btn[getter], btn)
            if ok then Kill(t) end
        end
    end
    StripTextures(btn)
    -- which side of the panel Blizzard put it on (its anchors stay untouched)
    local okP, point = pcall(btn.GetPoint, btn, 1)
    local right = okP and type(point) == "string" and not IsSecret(point) and point:find("RIGHT", 1, true) ~= nil
    local d = {}
    d.disc = NewTexture(btn, "ARTWORK", 7, Media(tex))
    d.disc:SetSize(DISC, DISC)
    d.disc:SetPoint(right and "RIGHT" or "LEFT", btn, right and "RIGHT" or "LEFT", right and -4 or 4, 0)
    d.hi = NewTexture(btn, "HIGHLIGHT", 0, Media("LootButtonHi"))
    pcall(d.hi.SetBlendMode, d.hi, "ADD")
    d.hi:SetVertexColor(glow[1], glow[2], glow[3])
    d.hi:SetSize(DISC + 10, DISC + 10)
    d.hi:SetPoint("CENTER", d.disc, "CENTER")
    btnUI[btn] = d
    pcall(btn.SetSize, btn, BTN_W, BTN_H)
    ButtonFonts()
    pcall(btn.SetNormalFontObject, btn, fonts.n)
    pcall(btn.SetHighlightFontObject, btn, fonts.h)
    pcall(btn.SetDisabledFontObject, btn, fonts.d)
    local ok, fs = pcall(btn.GetFontString, btn)
    fs = ok and fs or Child(btn, "Text")
    if fs then
        fs:ClearAllPoints()
        if right then fs:SetPoint("RIGHT", d.disc, "LEFT", -5, 0) else fs:SetPoint("LEFT", d.disc, "RIGHT", 5, 0) end
        pcall(fs.SetShadowOffset, fs, 0, 0)
    end
    btn:HookScript("OnMouseDown", DiscDown)
    btn:HookScript("OnMouseUp", DiscUp)
    btn:HookScript("OnEnable", RefreshActionButton)
    btn:HookScript("OnDisable", RefreshActionButton)
    btn:HookScript("OnShow", function(b) if enabled then RefreshActionButton(b) end end)
    RefreshActionButton(btn)
end

---------------------------------------------------------------------------
-- List rows (QuestFrame greeting quests, gossip options / quests)
---------------------------------------------------------------------------

local function RowText(btn)
    local ok, fs = pcall(btn.GetFontString, btn)
    if ok and fs then return fs end
    return Child(btn, "ButtonText") or Child(btn, "Text")
end

local function RowEnter(btn)
    local p = rows[btn]
    if not (p and enabled) then return end
    p.hover = true
    SetColor(RowText(btn), ORANGE)
end

local function RowLeave(btn)
    local p = rows[btn]
    if not (p and enabled) then return end
    p.hover = false
    SetColor(RowText(btn), DARK)
end

-- Flat row: dark text (quest titles may carry their own |c color codes - those stay), soft
-- orange hover bar, thin divider underneath; Blizzard's quest / gossip icon is kept.
local function SkinRow(btn)
    if not (btn and btn.CreateTexture) then return end
    local p = rows[btn]
    if not p then
        p = {}
        Kill(btn.GetHighlightTexture and btn:GetHighlightTexture())
        Kill(Child(btn, "HighlightTexture"))
        p.hl = ColorTex(btn, "HIGHLIGHT", 0, ORANGE, 0.14)
        p.hl:SetPoint("TOPLEFT", btn, "TOPLEFT", -2, 1)
        p.hl:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 2, -1)
        p.bar = ColorTex(btn, "HIGHLIGHT", 1, ORANGE, 0.9)
        p.bar:SetWidth(2)
        p.bar:SetPoint("TOPLEFT", btn, "TOPLEFT", -4, 1)
        p.bar:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", -4, -1)
        p.line = ColorTex(btn, "BACKGROUND", -8, DIVIDER, DIVIDER[4])
        p.line:SetHeight(1)
        p.line:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 0, -1)
        p.line:SetPoint("TOPRIGHT", btn, "BOTTOMRIGHT", 0, -1)
        rows[btn] = p
        if not hookedFrame[btn] then
            hookedFrame[btn] = true
            btn:HookScript("OnEnter", RowEnter)
            btn:HookScript("OnLeave", RowLeave)
        end
    end
    local fs = RowText(btn)
    if fs then
        pcall(fs.SetShadowOffset, fs, 0, 0)
        SetColor(fs, p.hover and ORANGE or DARK)
    end
end

---------------------------------------------------------------------------
-- Window chrome (shared by QuestFrame and GossipFrame)
---------------------------------------------------------------------------

local function HideButtonFrameArt(frame)
    for _, key in ipairs({ "NineSlice", "Bg", "Background", "TopTileStreaks", "PortraitContainer", "TitleContainer" }) do
        Kill(Child(frame, key))
    end
    local inset = Child(frame, "Inset")
    if inset then
        Kill(Child(inset, "Bg"))
        Kill(Child(inset, "NineSlice"))
        StripTextures(inset)
    end
    StripTextures(frame) -- portrait, button-bar corners and anything else drawn on the frame itself
end

local function BuildChrome(frame, ui, label)
    ui.panel = MakeSlices(frame, frame, Media("MerchantPanel"), 128, 32, 32, -12, 12, 12, -12, "BACKGROUND", -8)
    SliceColor(ui.panel, { 0.76, 0.80, 0.86 }, 0.94) -- soft steel-gray glass

    ui.headerBox = Box(frame)
    ui.headerBox:SetPoint("TOPLEFT", frame, "TOPLEFT", 3, -3)
    ui.headerBox:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", -3, -31)
    ui.header = MakeSlices(frame, ui.headerBox, Media("MerchantCard"), 64, 16, 10, 0, 0, 0, 0, "BACKGROUND", -6)
    SliceColor(ui.header, { 0.82, 0.85, 0.90 })
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
    if ns.fontPath then pcall(ui.label.SetFont, ui.label, ns.fontPath, 8, "") end
    ui.label:SetPoint("TOPLEFT", frame, "TOPLEFT", 38, -7)
    ui.label:SetText(label)
    ui.name = NewText(frame, 12, DARK) -- game font: NPC names in any locale
    ui.name:SetPoint("TOPLEFT", frame, "TOPLEFT", 38, -16)
    ui.name:SetPoint("RIGHT", frame, "TOPRIGHT", -34, -16)
    ui.name:SetJustifyH("LEFT")

    local close = Child(frame, "CloseButton") or G((FrameName(frame) or "") .. "CloseButton")
    if close then
        Safe("Close", RoundClose, close)
        close:ClearAllPoints()
        close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, -6)
    end
end

-- Lighter inner box behind a scroll area (parented to its panel so it hides with it).
local function InnerBox(panel, frame, area)
    if not (panel and area and panel.CreateTexture) then return end
    local box = Box(panel)
    box:SetPoint("LEFT", frame, "LEFT", 7, 0)
    box:SetPoint("RIGHT", frame, "RIGHT", -7, 0)
    box:SetPoint("TOP", area, "TOP", 0, 6)
    box:SetPoint("BOTTOM", area, "BOTTOM", 0, -6)
    local s = MakeSlices(panel, box, Media("MerchantCard"), 64, 16, 10, 0, 0, 0, 0, "BACKGROUND", -8)
    SliceColor(s, { 0.84, 0.86, 0.90 }, 0.92)
    -- scroll bars stay functional, just quieter
    Fade(Child(area, "ScrollBar"), 0.6)
end

-- NPC name: copy Blizzard's own title text (pass-through, never inspected) or UnitName.
local function UpdateHeader(frame, ui, unit)
    if not (frame and ui.name) then return end
    local tc = Child(frame, "TitleContainer")
    local tt = Child(tc, "TitleText") or G((FrameName(frame) or "") .. "TitleText")
    local set = false
    if tt and tt.GetText then
        local ok, t = pcall(tt.GetText, tt)
        if ok and (IsSecret(t) or (type(t) == "string" and t ~= "")) then
            set = pcall(ui.name.SetText, ui.name, t)
        end
    end
    if not set then
        local ok, n = pcall(UnitName, unit)
        if ok then pcall(ui.name.SetText, ui.name, n) end
    end
    if ui.portrait then
        local okE, exists = pcall(UnitExists, unit)
        if okE and (IsSecret(exists) or exists) and SetPortraitTexture then
            pcall(SetPortraitTexture, ui.portrait, unit)
        else
            ui.portrait:SetTexture(BOOK_ICON)
        end
    end
end

-- Is QuestInfo currently laid out inside one of the QuestFrame panels? QuestInfoFrame itself
-- is never reparented: QuestInfo_Display reparents its elements to `parentFrame` (we keep the
-- last one; before the first hooked call, the title header's parent tells).
local function GetParentOf(r)
    if not (r and r.GetParent) then return nil end
    local ok, p = pcall(r.GetParent, r)
    return ok and p or nil
end

local function InfoIsOurs()
    local parent = infoParent or GetParentOf(G("QuestInfoTitleHeader"))
    if not parent then return false end
    return parent == G("QuestDetailScrollChildFrame") or parent == G("QuestRewardScrollChildFrame")
end

-- Is this QuestInfo region (or its sub-frame / reward button) in the current QuestFrame layout?
local function InLayout(region)
    if not InfoIsOurs() then return false end
    local target = infoParent or GetParentOf(G("QuestInfoTitleHeader"))
    local p = GetParentOf(region)
    for _ = 1, 3 do
        if not p then return false end
        if p == target then return true end
        p = GetParentOf(p)
    end
    return false
end

---------------------------------------------------------------------------
-- QuestFrame
---------------------------------------------------------------------------

local function SkinQuest()
    local frame = G("QuestFrame")
    HideButtonFrameArt(frame)
    Kill(G("QuestFramePortrait"))
    Kill(G("QuestNpcNameFrame"))
    Kill(G("QuestFrameNpcNameText"))
    BuildChrome(frame, qui, "QUEST")
    for _, spec in ipairs(PANELS) do
        local panel, area = G(spec[1]), G(spec[2])
        if panel then
            StripTextures(panel) -- parchment Bg, material corners, seal background
            for _, key in ipairs({ "Bg", "MaterialTopLeft", "MaterialTopRight", "MaterialBotLeft", "MaterialBotRight",
                "SealMaterialBG" }) do
                Kill(Child(panel, key))
            end
            Safe("InnerBox", InnerBox, panel, frame, area)
            panel:HookScript("OnShow", function() if enabled then Defer(function() Safe("Panel", RefreshQuest) end) end end)
        end
    end
    Kill(G("QuestGreetingFrameHorizontalBreak"))
    -- Blizzard's selection glow is replaced by our ring only while QuestInfo is in QuestFrame
    CtxKill(G("QuestInfoItemHighlight"), true)
    for _, spec in ipairs(ACTIONS) do Safe("Action", SkinActionButton, G(spec[1]), spec[2], spec[3]) end
    for i = 1, MAX_PROGRESS_ITEMS do Safe("ProgressItem", SkinItemButton, G("QuestProgressItem" .. i), false) end
    local hl = G("QuestInfoItemHighlight")
    if hl and hl.HookScript then
        hl:HookScript("OnShow", function() if enabled then Safe("Choice", RefreshRewards) end end)
        hl:HookScript("OnHide", function() if enabled then Safe("Choice", RefreshRewards) end end)
    end
end

local function RewardButtons(fn)
    local rf = G("QuestInfoRewardsFrame")
    if not rf then return end
    local list = Field(rf, "RewardButtons")
    if type(list) == "table" then
        for _, b in ipairs(list) do fn(b) end
    else
        for i = 1, 12 do
            local b = G("QuestInfoRewardsFrameQuestInfoItem" .. i)
            if not b then break end
            fn(b)
        end
    end
    for _, key in ipairs({ "HonorFrame", "ArtifactXPFrame", "WarModeBonusFrame", "SkillPointFrame" }) do
        local b = Child(rf, key)
        if b then fn(b) end
    end
end

local function EachPool(owner, key, fn)
    local pool = Field(owner, key)
    if not (pool and pool.EnumerateActive) then return end
    pcall(function() for obj in pool:EnumerateActive() do fn(obj) end end)
end

-- Reward buttons, money / XP, spell / reputation rows (ctxOn: QuestInfo is in QuestFrame).
local function InfoStyle(fs, kind)
    if not fs or own[fs] then return end
    infoFS[fs] = true
    Style(fs, kind)
end

function RefreshRewards()
    local rf = G("QuestInfoRewardsFrame")
    local ctxOn = enabled and rf ~= nil and InLayout(rf)
    RewardButtons(function(b)
        if ctxOn then SkinItemButton(b, true) end
        RefreshItemButton(b, ctxOn)
    end)
    if not ctxOn then return end
    infoStyled = true -- so UnstyleInfo undoes this even if StyleInfo did not run
    RecolorMoneyFrame(Child(rf, "MoneyFrame") or G("QuestInfoMoneyFrame"), true)
    local xp = Child(rf, "XPFrame") or G("QuestInfoXPFrame")
    if xp then
        InfoStyle(Child(xp, "ReceiveText"), "body")
        MoneyText(Child(xp, "ValueText"), true)
    end
    for _, key in ipairs(REWARD_BODY) do InfoStyle(Child(rf, key), "body") end
    -- Title / spell / reputation / follower names stay as Blizzard draws them: they sit on
    -- Blizzard's dark name-frame art, which we do not hide.
    EachPool(rf, "spellHeaderPool", function(fs) InfoStyle(fs, "body") end)
end

-- Style QuestInfoFrame text inside QuestFrame (only the strings laid out there now)...
local function StyleInfo()
    for _, n in ipairs(INFO_TITLES) do
        local fs = G(n)
        if InLayout(fs) then InfoStyle(fs, "title") else Unstyle(fs) end
    end
    for _, n in ipairs(INFO_BODY) do
        local fs = G(n)
        if InLayout(fs) then InfoStyle(fs, "body") else Unstyle(fs) end
    end
    local heads = {}
    for _, n in ipairs(INFO_HEADERS) do heads[#heads + 1] = { G(n), false } end
    local rf = G("QuestInfoRewardsFrame")
    for i, key in ipairs(REWARD_SECTIONS) do heads[#heads + 1] = { Child(rf, key), i > 1 } end -- sub-lines: no divider
    for _, h in ipairs(heads) do
        local fs = h[1]
        if fs and InLayout(fs) then
            Section(fs, h[2])
            if sections[fs] then ctxKill[fs] = true end
        else
            Unsection(fs)
        end
    end
    local req = G("QuestInfoRequiredMoneyDisplay")
    if InLayout(req) then RecolorMoneyFrame(req, true) end
    for region in pairs(ctxKill) do
        if InLayout(region) then Kill(region) else Unkill(region) end
    end
    infoStyled = true
end

-- ...and undo it when Blizzard shows QuestInfoFrame elsewhere (quest log / map details).
-- Blizzard's own material recolor list (QuestInfo_Display), re-applied because Blizzard only
-- recolors when the material or the text-contrast setting changes.
local MAT_TITLE = { "QuestInfoTitleHeader", "QuestInfoDescriptionHeader", "QuestInfoObjectivesHeader" }
local MAT_TEXT = { "QuestInfoDescriptionText", "QuestInfoObjectivesText", "QuestInfoGroupSize", "QuestInfoRewardText",
    "QuestInfoTimerText", "QuestInfoSpellObjectiveLearnLabel" }
local MAT_RF_TEXT = { "ItemChooseText", "ItemReceiveText", "PlayerTitleText", "QuestSessionBonusReward" }

local function UnstyleInfo(material)
    if not infoStyled then return end
    infoStyled = false
    for fs in pairs(infoFS) do Unstyle(fs) end
    for _, n in ipairs(INFO_HEADERS) do Unsection(G(n)) end
    local rf = G("QuestInfoRewardsFrame")
    if rf then
        for _, key in ipairs(REWARD_SECTIONS) do Unsection(Child(rf, key)) end
    end
    for region in pairs(ctxKill) do Unkill(region) end
    for region in pairs(ctxOwn) do pcall(region.Hide, region) end
    RewardButtons(function(b) RefreshItemButton(b, false) end)
    if type(GetMaterialTextColors) ~= "function" then return end
    if type(material) ~= "string" or IsSecret(material) then material = Field(G("QuestInfoFrame"), "material") end
    local mat = type(material) == "string" and material or "Parchment"
    local okL, light = pcall(function()
        return QuestTextContrast and QuestTextContrast.UseLightText and QuestTextContrast.UseLightText()
    end)
    if okL and not IsSecret(light) and light then mat = "Stone" end
    local ok, text, title = pcall(GetMaterialTextColors, mat)
    if not ok or type(text) ~= "table" or type(title) ~= "table" then return end
    local function rgb(fs, c)
        if fs and fs.SetTextColor and type(c[1]) == "number" then pcall(fs.SetTextColor, fs, c[1], c[2], c[3]) end
    end
    for _, n in ipairs(MAT_TITLE) do rgb(G(n), title) end
    for _, n in ipairs(MAT_TEXT) do rgb(G(n), text) end
    if rf then
        rgb(Child(rf, "Header"), title)
        for _, key in ipairs(MAT_RF_TEXT) do rgb(Child(rf, key), text) end
        rgb(Child(Child(rf, "XPFrame"), "ReceiveText"), text)
    end
end

local function RefreshInfo(material)
    if enabled and InfoIsOurs() then
        StyleInfo()
    else
        UnstyleInfo(material)
    end
    RefreshRewards()
end

local function RefreshProgress()
    Style(G("QuestProgressTitleText"), "title")
    Style(G("QuestProgressText"), "body")
    Section(G("QuestProgressRequiredItemsText"))
    local money = G("QuestProgressRequiredMoneyText")
    if money then pcall(money.SetShadowOffset, money, 0, 0) end
    RecolorMoneyFrame(G("QuestProgressRequiredMoneyFrame"))
    for i = 1, MAX_PROGRESS_ITEMS do
        local b = G("QuestProgressItem" .. i)
        if not b then break end
        SkinItemButton(b, false)
        RefreshItemButton(b, true)
    end
end

local function RefreshGreeting()
    local scrollChild = G("QuestGreetingScrollChildFrame")
    Style(Child(scrollChild, "GreetingText") or G("GreetingText"), "body")
    Section(G("CurrentQuestsText"))
    Section(G("AvailableQuestsText"))
    EachPool(G("QuestFrameGreetingPanel"), "titleButtonPool", SkinRow)
end

local function TrySkinQuest()
    if skinnedQuest then return true end
    local frame = G("QuestFrame")
    if not frame then return false end
    local okP, prot = pcall(frame.IsProtected, frame)
    if okP and prot and InCombatLockdown and InCombatLockdown() then
        pendingCombat = true
        if events then events:RegisterEvent("PLAYER_REGEN_ENABLED") end
        return false
    end
    skinnedQuest = true -- even if a piece fails, never run twice (logged once)
    Safe("SkinQuest", SkinQuest)
    return true
end

function RefreshQuest()
    if not enabled or not TrySkinQuest() then return end
    local frame = G("QuestFrame")
    UpdateHeader(frame, qui, "questnpc")
    for _, spec in ipairs(ACTIONS) do RefreshActionButton(G(spec[1])) end
    local notice = Child(frame, "AccountCompletedNotice")
    local nt = Child(notice, "Text")
    if nt then pcall(nt.SetShadowOffset, nt, 0, 0); SetColor(nt, { 0.62, 0.45, 0.02 }) end
    if Shown(G("QuestFrameProgressPanel")) then Safe("Progress", RefreshProgress) end
    if Shown(G("QuestFrameGreetingPanel")) then Safe("Greeting", RefreshGreeting) end
    if Shown(G("QuestFrameDetailPanel")) or Shown(G("QuestFrameRewardPanel")) then Safe("Info", RefreshInfo) end
end

---------------------------------------------------------------------------
-- GossipFrame
---------------------------------------------------------------------------

local function GossipPanel()
    local f = G("GossipFrame")
    return f, Child(f, "GreetingPanel") or G("GossipFrameGreetingPanel")
end

local function GossipElement(frame)
    if not frame then return end
    local greet = Child(frame, "GreetingText")
    if greet and greet.SetTextColor then
        Style(greet, "body")
        return
    end
    local ok, kind = pcall(frame.GetObjectType, frame)
    if ok and kind == "Button" then SkinRow(frame) end
end

local function SkinGossip()
    local frame, gp = GossipPanel()
    HideButtonFrameArt(frame)
    Kill(Child(frame, "Background"))
    Kill(G("GossipFramePortrait"))
    BuildChrome(frame, gui, "NPC")
    if gp then
        StripTextures(gp) -- material corners
        local box = Child(gp, "ScrollBox")
        Safe("InnerBox", InnerBox, gp, frame, box)
        Fade(Child(gp, "ScrollBar"), 0.6)
        if box and ScrollUtil and ScrollUtil.AddInitializedFrameCallback then
            -- runs after Blizzard's initializer for every row, including rows acquired on scroll
            Safe("RowCallback", ScrollUtil.AddInitializedFrameCallback, box, function(a, b)
                if not enabled then return end
                local f = (type(a) == "table" and a.GetObjectType) and a or b
                Safe("Row", GossipElement, f)
            end, gui, true)
        end
    end
    local bye = Child(gp, "GoodbyeButton") or Child(frame, "GoodbyeButton") or G("GossipFrameGreetingGoodbyeButton")
    Safe("Goodbye", SkinActionButton, bye, "LootPass", RED)
    gui.goodbye = bye
end

local function TrySkinGossip()
    if skinnedGossip then return true end
    local frame = G("GossipFrame")
    if not frame then return false end
    local okP, prot = pcall(frame.IsProtected, frame)
    if okP and prot and InCombatLockdown and InCombatLockdown() then
        pendingCombat = true
        if events then events:RegisterEvent("PLAYER_REGEN_ENABLED") end
        return false
    end
    skinnedGossip = true
    Safe("SkinGossip", SkinGossip)
    return true
end

local function RefreshGossip()
    if not enabled or not TrySkinGossip() then return end
    local frame, gp = GossipPanel()
    UpdateHeader(frame, gui, "npc")
    RefreshActionButton(gui.goodbye)
    -- the gossip theme re-colors registered font strings at the end of each update
    local box = Child(gp, "ScrollBox")
    if box and box.ForEachFrame then pcall(box.ForEachFrame, box, GossipElement) end
end

---------------------------------------------------------------------------
-- Hooks / events
---------------------------------------------------------------------------

local function HookGlobal(name, fn)
    if hooked[name] or type(_G[name]) ~= "function" or not hooksecurefunc then return end
    hooked[name] = true
    hooksecurefunc(name, fn)
end

local function QuestShown()
    return Shown(G("QuestFrame"))
end

local function InstallHooks()
    -- Shared with the quest log: styles inside QuestFrame, undoes the style everywhere else.
    HookGlobal("QuestInfo_Display", function(_, parentFrame, _, material)
        if type(parentFrame) == "table" then infoParent = parentFrame end
        if enabled or infoStyled then Safe("Display", RefreshInfo, material) end
    end)
    HookGlobal("QuestInfoItem_OnClick", function() if enabled then Safe("Choice", RefreshRewards) end end)
    HookGlobal("QuestFrameProgressItems_Update", function() if enabled and skinnedQuest then Safe("Progress", RefreshProgress) end end)
    HookGlobal("QuestFrameGreetingPanel_OnShow", function() if enabled and skinnedQuest then Safe("Greeting", RefreshGreeting) end end)
    HookGlobal("QuestFrame_SetPortrait", function()
        if enabled and skinnedQuest then Safe("Header", UpdateHeader, G("QuestFrame"), qui, "questnpc") end
    end)
    local function money(f)
        if not (enabled and skinnedQuest and QuestShown()) then return end
        if type(f) == "string" then f = _G[f] end
        if not f then return end
        if f == G("QuestProgressRequiredMoneyFrame") then
            Safe("Money", RecolorMoneyFrame, f)
        elseif (f == G("QuestInfoMoneyFrame") or f == G("QuestInfoRequiredMoneyDisplay")) and InLayout(f) then
            Safe("Money", RecolorMoneyFrame, f, true) -- shared with the quest log: only while laid out here
        end
    end
    HookGlobal("MoneyFrame_Update", money)
    HookGlobal("SetMoneyFrameColor", money)
    local q = G("QuestFrame")
    if q and not hookedFrame[q] then
        hookedFrame[q] = true
        q:HookScript("OnShow", function() if enabled then Defer(function() Safe("Refresh", RefreshQuest) end) end end)
    end
    local gf = G("GossipFrame")
    if gf and not hookedFrame[gf] then
        hookedFrame[gf] = true
        gf:HookScript("OnShow", function() if enabled then Defer(function() Safe("Gossip", RefreshGossip) end) end end)
    end
end

local QUEST_EVENTS = { QUEST_DETAIL = true, QUEST_PROGRESS = true, QUEST_COMPLETE = true, QUEST_GREETING = true,
    QUEST_ITEM_UPDATE = true }

local function OnEvent(_, event, arg1)
    if event == "PLAYER_REGEN_ENABLED" then
        events:UnregisterEvent("PLAYER_REGEN_ENABLED")
        if pendingCombat then
            pendingCombat = false
            if enabled then
                if QuestShown() then Safe("Refresh", RefreshQuest) end
                if Shown(G("GossipFrame")) then Safe("Gossip", RefreshGossip) end
            end
        end
        return
    end
    if not enabled then return end
    if event == "ADDON_LOADED" then
        if type(arg1) == "string" and not IsSecret(arg1) and (arg1:find("UIPanels", 1, true) or arg1:find("Quest", 1, true)
            or arg1:find("Gossip", 1, true)) then
            InstallHooks()
        end
    elseif QUEST_EVENTS[event] then
        InstallHooks()
        -- after Blizzard's own handling has drawn the panel
        Defer(function() Safe("Refresh", RefreshQuest) end)
    elseif event == "GOSSIP_SHOW" then
        InstallHooks()
        Defer(function() Safe("Gossip", RefreshGossip) end)
    end
end

local EVENT_LIST = { "ADDON_LOADED", "QUEST_DETAIL", "QUEST_PROGRESS", "QUEST_COMPLETE", "QUEST_GREETING",
    "QUEST_ITEM_UPDATE", "GOSSIP_SHOW" }

local function Activate()
    if not events then
        events = CreateFrame("Frame")
        events:SetScript("OnEvent", function(...) Safe("OnEvent", OnEvent, ...) end)
    end
    for _, e in ipairs(EVENT_LIST) do pcall(events.RegisterEvent, events, e) end
    InstallHooks()
    -- Re-enable in the same session: re-hide Blizzard art, re-show our static parts (the
    -- dynamic ones are decided by the next refresh).
    if skinnedQuest or skinnedGossip then
        for region in pairs(hidden) do
            if not ctxKill[region] then pcall(region.SetAlpha, region, 0) end
        end
        for region in pairs(own) do
            local ok, kind = pcall(region.GetObjectType, region)
            if ok and kind ~= "MaskTexture" and not dynamic[region] then pcall(region.Show, region) end
        end
        -- scroll bars are dimmed, not hidden
        for _, n in ipairs({ "QuestDetailScrollFrame", "QuestProgressScrollFrame", "QuestRewardScrollFrame",
            "QuestGreetingScrollFrame" }) do
            Fade(Child(G(n), "ScrollBar"), 0.6)
        end
        local _, gp = GossipPanel()
        Fade(Child(gp, "ScrollBar"), 0.6)
    end
    if QuestShown() then Safe("Refresh", RefreshQuest) end
    if Shown(G("GossipFrame")) then Safe("Gossip", RefreshGossip) end
end

local function Deactivate()
    if events then
        for _, e in ipairs(EVENT_LIST) do pcall(events.UnregisterEvent, events, e) end
    end
    -- Best effort: Blizzard's art, fonts and colors come back, ours hide (button textures,
    -- sizes and anchors stay changed until /reload).
    UnstyleInfo()
    for _, p in pairs(items) do RestoreName(p) end
    for region, a in pairs(hidden) do pcall(region.SetAlpha, region, a) end
    for fs in pairs(saved) do Unstyle(fs) end
    for region in pairs(own) do
        local ok, kind = pcall(region.GetObjectType, region)
        if ok and kind ~= "MaskTexture" then pcall(region.Hide, region) end
    end
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

function ns.InitQuest()
    qdb = InitDefaults()
    if not qdb then
        LogOnce("InitQuest", "saved variables not ready")
        return
    end
    enabled = qdb.enabled == true
    if enabled then Activate() end
end

function ns.IsQuestEnabled()
    qdb = qdb or InitDefaults()
    return qdb ~= nil and qdb.enabled == true
end

function ns.QuestSetEnabled(on)
    qdb = qdb or InitDefaults()
    if not qdb then return end
    on = on and true or false
    qdb.enabled = on
    local was = enabled
    enabled = on
    if on then
        if not was then Activate() end
        Print("SAO quest / NPC windows enabled.")
    else
        if was then Deactivate() end
        Print("SAO quest / NPC windows disabled. Type /reload to fully restore Blizzard's look.")
    end
end
