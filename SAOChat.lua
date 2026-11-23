-- SAO Frames: Sword Art Online-styled chat skin (SAOChat.lua).
--
-- A pure skin on top of Blizzard's chat frames: dark glass panels with cyan accents,
-- flat uppercase tabs (orange = selected), an SAO input bar and round buttons.
-- Nothing is replaced: Blizzard art is cleared, our own regions are added beside it,
-- and every update goes through hooksecurefunc / HookScript. No fields are written
-- onto Blizzard frames (state lives in weak-keyed tables here) and message text is
-- never read, so 12.x secret chat values are never touched.
--
-- Public (on ns): InitChat, ChatSetEnabled, IsChatEnabled.

local ADDON, ns = ...

---------------------------------------------------------------------------
-- Constants
---------------------------------------------------------------------------

local WHITE = "Interface\\Buttons\\WHITE8X8"
local ACCENT_R, ACCENT_G, ACCENT_B = 0.40, 0.85, 1.00 -- #66d9ff (same as the meter)
local BORDER_R, BORDER_G, BORDER_B = 0.88, 0.92, 0.96
local SEL_R, SEL_G, SEL_B = 0.95, 0.64, 0.23          -- #F2A33A, selected item
local GLASS_R, GLASS_G, GLASS_B = 0.05, 0.07, 0.10
local TEXT_R, TEXT_G, TEXT_B = 0.82, 0.88, 0.94

local CHAT_DEFAULTS = {
    enabled = true,
    alpha = 0.55,     -- chat panel opacity
    font = true,      -- use the SAO font (ns.fontPath) for chat text when available
    upperTabs = true, -- uppercase tab labels
    buttons = "sao",  -- "sao": round SAO backing on Blizzard's buttons; "hide": hide them
                      -- and show one SAO round menu button instead
}

-- Blizzard's own list of chat background/border texture suffixes, used as fallback.
local FRAME_TEXTURES = {
    "Background", "TopLeftTexture", "BottomLeftTexture", "TopRightTexture", "BottomRightTexture",
    "LeftTexture", "RightTexture", "BottomTexture", "TopTexture",
    "ButtonFrameBackground", "ButtonFrameTopLeftTexture", "ButtonFrameBottomLeftTexture",
    "ButtonFrameTopRightTexture", "ButtonFrameBottomRightTexture", "ButtonFrameLeftTexture",
    "ButtonFrameRightTexture", "ButtonFrameBottomTexture", "ButtonFrameTopTexture",
}
local TAB_PARTS = {
    "Left", "Middle", "Right", "ActiveLeft", "ActiveMiddle", "ActiveRight",
    "HighlightLeft", "HighlightMiddle", "HighlightRight",
}
local EDIT_PARTS = { "Left", "Mid", "Right", "FocusLeft", "FocusMid", "FocusRight" }
local GLOBAL_BUTTONS = {
    "ChatFrameMenuButton", "ChatFrameChannelButton", "ChatFrameToggleVoiceDeafenButton",
    "ChatFrameToggleVoiceMuteButton", "TextToSpeechButton", "QuickJoinToastButton",
}

---------------------------------------------------------------------------
-- State (weak-keyed: never store anything on Blizzard frames)
---------------------------------------------------------------------------

local skinned  = setmetatable({}, { __mode = "k" }) -- Blizzard frame -> true
local panels   = setmetatable({}, { __mode = "k" }) -- chat frame -> { fill, border, ... }
local tabParts = setmetatable({}, { __mode = "k" }) -- tab -> { fill, border, line, frame }
local editParts = setmetatable({}, { __mode = "k" }) -- edit box -> { border, arrow, line }
local hiddenFrames = setmetatable({}, { __mode = "k" }) -- frames we hide in "hide" mode
local overlays = {}   -- every region we created (shown/hidden with the skin)
local active, initialized, hooked = false, false, false
local menuButton
local fallbackDB

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function Media(file)
    return (ns.MEDIA or "Interface\\AddOns\\SAOFrames\\Media\\") .. file
end

local errCount = {} -- cap repeats so a hook that fails on every call can't flood the log
local function LogError(where, err)
    local n = (errCount[where] or 0) + 1
    errCount[where] = n
    if n > 3 then return end
    if ns.LogError then pcall(ns.LogError, "Chat skin (" .. where .. "): " .. tostring(err)) end
end

local function Try(where, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then LogError(where, err) end
    return ok
end

local function Print(msg)
    if ns.Print then ns.Print(msg) elseif DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage(msg) end
end

local function IsSecret(v)
    if ns.IsSecret then return ns.IsSecret(v) end
    return issecretvalue ~= nil and issecretvalue(v) or false
end

local function GetChatDB()
    local db = ns.GetDB and ns.GetDB()
    local c
    if type(db) == "table" then
        if type(db.chat) ~= "table" then db.chat = {} end
        c = db.chat
    else
        fallbackDB = fallbackDB or {}
        c = fallbackDB
    end
    for k, v in pairs(CHAT_DEFAULTS) do
        if c[k] == nil then c[k] = v end
    end
    if type(c.alpha) ~= "number" or c.alpha < 0 or c.alpha > 1 then c.alpha = CHAT_DEFAULTS.alpha end
    if c.buttons ~= "sao" and c.buttons ~= "hide" then c.buttons = CHAT_DEFAULTS.buttons end
    return c
end

local function Track(region)
    overlays[#overlays + 1] = region
    return region
end

local function SetOverlaysShown(shown)
    for _, r in ipairs(overlays) do
        if shown then r:Show() else r:Hide() end
    end
    if menuButton then menuButton:SetShown(shown and GetChatDB().buttons == "hide") end
end

-- Clear a Blizzard texture: SetTexture(nil) survives Blizzard's alpha fades.
-- The original look is recorded once so disabling the skin can put it back.
local stripped = setmetatable({}, { __mode = "k" }) -- tex -> { file, atlas, alpha, tc = {8 texcoords} }
local function Strip(tex)
    if tex and tex.SetTexture then
        if not stripped[tex] then -- record once; later Strips would see the nil texture
            local s = { tex:GetTexture(), tex.GetAtlas and tex:GetAtlas() or nil, tex:GetAlpha() }
            if tex.GetTexCoord then s.tc = { tex:GetTexCoord() } end
            stripped[tex] = s
        end
        tex:SetTexture(nil)
        tex:SetAlpha(0)
    end
end

local function RestoreStripped()
    for tex, s in pairs(stripped) do
        if s[2] then pcall(tex.SetAtlas, tex, s[2]) elseif s[1] then pcall(tex.SetTexture, tex, s[1]) end
        if s.tc and #s.tc == 8 then pcall(tex.SetTexCoord, tex, unpack(s.tc)) end
        pcall(tex.SetAlpha, tex, s[3] or 1)
    end
end

-- Nine-sliced beveled panel texture (fill or border); plain fill if slicing is missing.
local function Sliced(parent, layer, sub, file)
    local t = Track(parent:CreateTexture(nil, layer, nil, sub))
    if t.SetTextureSliceMargins then
        t:SetTexture(Media(file))
        t:SetTextureSliceMargins(8, 8, 8, 8)
        if t.SetTextureSliceMode and Enum and Enum.UITextureSliceMode then
            t:SetTextureSliceMode(Enum.UITextureSliceMode.Stretched)
        end
    else
        t:SetTexture(file == "ChatPanel" and WHITE or nil)
    end
    return t
end

local function MakePanel(parent, layer, sub)
    local fill = Sliced(parent, layer, sub, "ChatPanel")
    local border = Sliced(parent, layer, sub + 1, "ChatPanelBorder")
    return fill, border
end

local function SetPanelPoints(fill, border, rel, l, t, r, b)
    for _, tex in ipairs({ fill, border }) do
        tex:ClearAllPoints()
        tex:SetPoint("TOPLEFT", rel, "TOPLEFT", l, t)
        tex:SetPoint("BOTTOMRIGHT", rel, "BOTTOMRIGHT", r, b)
    end
end

-- Swap a font instance to the SAO font, keeping size and flags (size may be forced).
local function SwapFont(obj, size)
    if not (obj and obj.GetFont and ns.fontPath and GetChatDB().font) then return end
    local path, cur, flags = obj:GetFont()
    if IsSecret(path) or IsSecret(cur) or IsSecret(flags) then return end
    if not (type(size) == "number" and size > 0) then size = cur end
    if not size or (path == ns.fontPath and size == cur) then return end
    obj:SetFont(ns.fontPath, size, flags or "")
    if not obj:GetFont() and path then obj:SetFont(path, size, flags or "") end
end

---------------------------------------------------------------------------
-- Chat frame background
---------------------------------------------------------------------------

local function SkinPanel(frame)
    local name = frame:GetName()
    if not name then return end
    local list = type(CHAT_FRAME_TEXTURES) == "table" and CHAT_FRAME_TEXTURES or FRAME_TEXTURES
    for _, suffix in ipairs(list) do
        if type(suffix) == "string" then Strip(_G[name .. suffix]) end
    end
    local p = panels[frame]
    if not p then
        -- Follow Blizzard's Background region so the panel matches the user's
        -- window geometry (incl. the combat log filter bar on ChatFrame2).
        local bg = _G[name .. "Background"]
        p = {}
        p.fill, p.border = MakePanel(frame, "BACKGROUND", -6)
        if bg then
            SetPanelPoints(p.fill, p.border, bg, 0, 0, 0, 0)
        else
            SetPanelPoints(p.fill, p.border, frame, -4, 4, 4, -4)
        end
        local rel = bg or frame
        p.line = Track(frame:CreateTexture(nil, "BORDER", nil, 1))
        p.line:SetColorTexture(ACCENT_R, ACCENT_G, ACCENT_B, 0.8)
        p.line:SetHeight(1)
        p.line:SetPoint("TOPLEFT", rel, "TOPLEFT", 14, -1)
        p.line:SetPoint("TOPRIGHT", rel, "TOPRIGHT", -10, -1)
        p.diamond = Track(frame:CreateTexture(nil, "BORDER", nil, 2))
        p.diamond:SetSize(5, 5)
        p.diamond:SetColorTexture(ACCENT_R, ACCENT_G, ACCENT_B, 1)
        p.diamond:SetPoint("CENTER", p.line, "LEFT", -5, 0)
        if p.diamond.SetRotation then p.diamond:SetRotation(math.pi / 4) end
        panels[frame] = p
    end
    p.fill:SetVertexColor(GLASS_R, GLASS_G, GLASS_B, GetChatDB().alpha)
    p.border:SetVertexColor(BORDER_R, BORDER_G, BORDER_B, 0.35)
end

local function ApplyChatFont(frame, id)
    local size
    if FCF_GetChatWindowInfo and type(id) == "number" and id >= 1 and id <= (NUM_CHAT_WINDOWS or 10) then
        local _, fontSize = FCF_GetChatWindowInfo(id)
        if type(fontSize) == "number" and not IsSecret(fontSize) and fontSize > 0 then size = fontSize end
    end
    SwapFont(frame, size)
end

---------------------------------------------------------------------------
-- Tabs
---------------------------------------------------------------------------

local function UpdateTab(tab, selected)
    local p = tabParts[tab]
    if not p then return end
    for _, k in ipairs(TAB_PARTS) do
        local t = tab[k]
        if t and t.SetAlpha then t:SetAlpha(0) end
    end
    if selected == nil then
        selected = tab.ActiveLeft and tab.ActiveLeft:IsShown() or false
    end
    local fs = tab:GetFontString()
    if fs then SwapFont(fs) end
    if selected then
        p.line:SetColorTexture(SEL_R, SEL_G, SEL_B, 1)
        p.line:SetHeight(2)
        p.border:SetVertexColor(SEL_R, SEL_G, SEL_B, 0.85)
        p.fill:SetVertexColor(GLASS_R + 0.04, GLASS_G + 0.04, GLASS_B + 0.05, 0.85)
        if fs then fs:SetTextColor(SEL_R, SEL_G, SEL_B) end
    else
        p.line:SetColorTexture(ACCENT_R, ACCENT_G, ACCENT_B, 0.6)
        p.line:SetHeight(1)
        p.border:SetVertexColor(BORDER_R, BORDER_G, BORDER_B, 0.3)
        p.fill:SetVertexColor(GLASS_R, GLASS_G, GLASS_B, 0.75)
        -- Whisper/temporary tabs keep Blizzard's chat-type text color.
        if fs and not (p.frame and p.frame.isTemporary) then fs:SetTextColor(TEXT_R, TEXT_G, TEXT_B) end
    end
end

local function ResizeTab(tab, frame)
    if not PanelTemplates_TabResize then return end
    -- docked dynamic tabs are sized by the dock; don't override them
    if frame and frame.isDocked and not frame.isStaticDocked then return end
    local pad = tab.sizePadding
    pcall(PanelTemplates_TabResize, tab, type(pad) == "number" and pad or 0)
end

local function UpperTab(tab)
    if not (tab and tabParts[tab] and GetChatDB().upperTabs) then return end
    local txt = tab:GetText()
    if IsSecret(txt) or type(txt) ~= "string" then return end -- secret: no string functions at all
    if txt:find("|", 1, true) then return end -- escape codes (|K..|k, |c..|r, |T, |H): leave as is
    local up = txt:upper()
    if up == txt then return end
    tab:SetText(up)
    ResizeTab(tab, tabParts[tab].frame)
end

local function SkinTab(tab, frame)
    if not tab then return end
    local isNew = not tabParts[tab]
    if isNew then
        for _, k in ipairs(TAB_PARTS) do Strip(tab[k]) end
        local p = { frame = frame }
        -- Tab is 64x32 with its text centered 5px below the middle: the visible
        -- SAO tab is the lower 23px.
        p.fill, p.border = MakePanel(tab, "BACKGROUND", 1)
        SetPanelPoints(p.fill, p.border, tab, 2, -9, -2, 0)
        p.line = Track(tab:CreateTexture(nil, "ARTWORK", nil, 1))
        p.line:SetPoint("BOTTOMLEFT", p.fill, "BOTTOMLEFT", 4, 1)
        p.line:SetPoint("BOTTOMRIGHT", p.fill, "BOTTOMRIGHT", -4, 1)
        p.hl = Track(tab:CreateTexture(nil, "HIGHLIGHT"))
        p.hl:SetAllPoints(p.fill)
        p.hl:SetColorTexture(ACCENT_R, ACCENT_G, ACCENT_B, 0.10)
        tabParts[tab] = p
    end
    -- Font first, then uppercase/resize with the final font.
    UpdateTab(tab)
    UpperTab(tab)
    if isNew then ResizeTab(tab, frame) end
end

---------------------------------------------------------------------------
-- Edit box
---------------------------------------------------------------------------

local function SetEditFocus(eb, focused)
    local p = editParts[eb]
    if not p then return end
    if focused then
        p.border:SetVertexColor(ACCENT_R, ACCENT_G, ACCENT_B, 0.9)
        p.line:SetColorTexture(ACCENT_R, ACCENT_G, ACCENT_B, 0.9)
        p.arrow:SetVertexColor(ACCENT_R, ACCENT_G, ACCENT_B, 1)
    else
        p.border:SetVertexColor(BORDER_R, BORDER_G, BORDER_B, 0.35)
        p.line:SetColorTexture(ACCENT_R, ACCENT_G, ACCENT_B, 0.4)
        p.arrow:SetVertexColor(ACCENT_R, ACCENT_G, ACCENT_B, 0.6)
    end
end

local function OnEditFocusGained(eb) if active then Try("edit focus", SetEditFocus, eb, true) end end
local function OnEditFocusLost(eb) if active then Try("edit focus", SetEditFocus, eb, false) end end

local function SkinEditBox(eb)
    if not eb then return end
    if not editParts[eb] then
        local name = eb:GetName()
        for _, k in ipairs(EDIT_PARTS) do Strip(name and _G[name .. k]) end
        Strip(eb.focusLeft); Strip(eb.focusMid); Strip(eb.focusRight)
        local p = {}
        p.fill, p.border = MakePanel(eb, "BACKGROUND", -6)
        SetPanelPoints(p.fill, p.border, eb, 3, -4, -3, 4)
        p.fill:SetVertexColor(GLASS_R, GLASS_G, GLASS_B, 0.82)
        -- Cyan "play" prompt in front of the header text (header starts at x=15).
        p.arrow = Track(eb:CreateTexture(nil, "ARTWORK"))
        p.arrow:SetTexture(Media("ChatArrow"))
        p.arrow:SetSize(9, 9)
        p.arrow:SetPoint("LEFT", eb, "LEFT", 5, 0)
        p.line = Track(eb:CreateTexture(nil, "BORDER"))
        p.line:SetHeight(1)
        p.line:SetPoint("BOTTOMLEFT", p.fill, "BOTTOMLEFT", 6, 1)
        p.line:SetPoint("BOTTOMRIGHT", p.fill, "BOTTOMRIGHT", -6, 1)
        editParts[eb] = p
        eb:HookScript("OnEditFocusGained", OnEditFocusGained)
        eb:HookScript("OnEditFocusLost", OnEditFocusLost)
    end
    SetEditFocus(eb, eb.HasFocus and eb:HasFocus() or false)
    SwapFont(eb)
    SwapFont(eb.header)
    SwapFont(eb.headerSuffix)
end

---------------------------------------------------------------------------
-- Buttons
---------------------------------------------------------------------------

-- (The round backing behind Blizzard's chat buttons looked off against their own
-- square frames, so the buttons are left as they are; "hide" mode still swaps them
-- for one SAO round button.)
local function SkinRoundButton() end

-- hiddenFrames[f] = whether Blizzard wants f shown (restored on disable).
local hiding = false
local function ForceHide(f)
    hiding = true
    pcall(f.Hide, f)
    hiding = false
end

local function HideHooked(f)
    if not (f and f.Hide) then return end
    if hiddenFrames[f] == nil then
        hiddenFrames[f] = f:IsShown() and true or false
        local function OnShown(self, shown)
            if hiding then return end
            hiddenFrames[self] = shown and true or false
            if shown and active and GetChatDB().buttons == "hide" then ForceHide(self) end
        end
        hooksecurefunc(f, "Show", function(self) OnShown(self, true) end)
        if f.SetShown then hooksecurefunc(f, "SetShown", OnShown) end
        hooksecurefunc(f, "Hide", function(self) if not hiding then hiddenFrames[self] = false end end)
    end
    if active then ForceHide(f) end
end

-- Blizzard's chat menu is never opened from here: building it from addon code taints
-- the chat edit box. The SAO button opens the channels window and the social menu.
local function OpenSocial()
    if ns.ToggleSocialMenu and ns.IsSocialEnabled and ns.IsSocialEnabled() then
        ns.ToggleSocialMenu()
    elseif ToggleFriendsFrame then
        ToggleFriendsFrame()
    end
end

local function CreateMenuButton()
    if menuButton then return menuButton end
    local anchor = _G.ChatFrame1Background or _G.ChatFrame1
    if not anchor then return end
    local b = CreateFrame("Button", nil, UIParent)
    b:SetSize(20, 20)
    b:SetFrameStrata("LOW")
    b:SetFrameLevel(20)
    b:SetPoint("TOPRIGHT", anchor, "TOPLEFT", -3, 0)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    local disc = b:CreateTexture(nil, "BACKGROUND")
    disc:SetTexture(Media("ChatRound"))
    disc:SetVertexColor(GLASS_R, GLASS_G, GLASS_B, 0.85)
    disc:SetAllPoints()
    local ring = b:CreateTexture(nil, "BORDER")
    ring:SetTexture(Media("ChatRoundBorder"))
    ring:SetVertexColor(ACCENT_R, ACCENT_G, ACCENT_B, 0.9)
    ring:SetAllPoints()
    for i = -1, 1 do -- "menu" glyph: three short bars
        local bar = b:CreateTexture(nil, "ARTWORK")
        bar:SetColorTexture(BORDER_R, BORDER_G, BORDER_B, 0.95)
        bar:SetSize(8, 1)
        bar:SetPoint("CENTER", 0, i * 3)
    end
    b:SetScript("OnEnter", function(self)
        ring:SetVertexColor(SEL_R, SEL_G, SEL_B, 1)
        if GameTooltip then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine("CHAT", ACCENT_R, ACCENT_G, ACCENT_B)
            GameTooltip:AddLine("Click: channels", 1, 1, 1)
            GameTooltip:AddLine("Right-click / Shift-click: social", 1, 1, 1)
            GameTooltip:Show()
        end
    end)
    b:SetScript("OnLeave", function()
        ring:SetVertexColor(ACCENT_R, ACCENT_G, ACCENT_B, 0.9)
        if GameTooltip then GameTooltip:Hide() end
    end)
    b:SetScript("OnClick", function(_, button)
        if button == "RightButton" or IsShiftKeyDown() then
            Try("social", OpenSocial)
        elseif ToggleChannelFrame then
            Try("channels", ToggleChannelFrame)
        end
    end)
    menuButton = b
    return b
end

local function SkinButtons(frame)
    local bf = frame.buttonFrame or _G[(frame:GetName() or "") .. "ButtonFrame"]
    if GetChatDB().buttons == "hide" then
        HideHooked(bf)
    elseif bf then
        SkinRoundButton(bf.minimizeButton)
    end
end

local function SkinGlobalButtons()
    local hide = GetChatDB().buttons == "hide"
    for _, n in ipairs(GLOBAL_BUTTONS) do
        local b = _G[n]
        if b then
            if hide then HideHooked(b) else SkinRoundButton(b) end
        end
    end
    if hide then
        local b = CreateMenuButton()
        if b then b:Show() end
    elseif menuButton then
        menuButton:Hide()
    end
end

---------------------------------------------------------------------------
-- Driver
---------------------------------------------------------------------------

local function EachChatFrame(fn)
    local seen = {}
    for i = 1, NUM_CHAT_WINDOWS or 10 do
        local f = _G["ChatFrame" .. i]
        if f then
            seen[f] = true
            fn(f, i)
        end
    end
    if type(CHAT_FRAMES) == "table" then
        for _, name in ipairs(CHAT_FRAMES) do
            local f = type(name) == "string" and _G[name]
            if f and not seen[f] then
                seen[f] = true
                fn(f, f.GetID and f:GetID())
            end
        end
    end
end

local function SkinChatFrame(frame, id)
    local name = frame:GetName()
    if not name then return end
    skinned[frame] = true
    Try("panel", SkinPanel, frame)
    Try("tab", SkinTab, _G[name .. "Tab"], frame)
    Try("edit box", SkinEditBox, frame.editBox or _G[name .. "EditBox"])
    Try("font", ApplyChatFont, frame, id)
    Try("buttons", SkinButtons, frame)
end

local function SkinAll()
    if not active then return end
    EachChatFrame(SkinChatFrame)
    Try("global buttons", SkinGlobalButtons)
end

local function TabForFrame(frame)
    local name = frame and frame.GetName and frame:GetName()
    return name and _G[name .. "Tab"]
end

local function InstallHooks()
    if hooked then return end
    hooked = true
    local function Hook(fname, fn)
        if type(_G[fname]) == "function" then
            hooksecurefunc(fname, function(...)
                if active then Try(fname, fn, ...) end
            end)
        end
    end
    Hook("FCFTab_UpdateColors", function(tab, selected) UpdateTab(tab, selected) end)
    Hook("FCF_SetWindowName", function(frame)
        local tab = TabForFrame(frame)
        if tab then
            UpperTab(tab)
            UpdateTab(tab)
        end
    end)
    Hook("FCF_SetChatWindowFontSize", function(_, chatFrame)
        chatFrame = chatFrame or (FCF_GetCurrentChatFrame and FCF_GetCurrentChatFrame())
        if chatFrame and skinned[chatFrame] then ApplyChatFont(chatFrame, chatFrame:GetID()) end
    end)
    -- New whisper / pet battle / user windows: skin whatever is not skinned yet
    -- (re-skinning is idempotent, so a full pass is fine).
    Hook("FCF_OpenTemporaryWindow", SkinAll)
    Hook("FCF_OpenNewWindow", SkinAll)
    Hook("FCF_DockUpdate", function()
        for tab in pairs(tabParts) do UpdateTab(tab) end
    end)
end

local function Start()
    initialized = true
    active = true
    Try("hooks", InstallHooks)
    SkinAll()
    -- Blizzard re-applies some chat settings right after login; pass again shortly.
    if C_Timer and C_Timer.After then
        C_Timer.After(2, function() if active then Try("reskin", SkinAll) end end)
    end
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

function ns.InitChat()
    local ok, err = pcall(function()
        if not GetChatDB().enabled or initialized then return end
        Start()
    end)
    if not ok then LogError("init", err) end
end

function ns.IsChatEnabled()
    local ok, c = pcall(GetChatDB)
    return ok and c.enabled and true or false
end

local function SetEnabled(on)
    GetChatDB().enabled = on
    if on then
        if initialized then
            active = true
            Try("enable", SetOverlaysShown, true)
            Try("enable", SkinAll)
        else
            Try("enable", Start)
        end
        Print("SAO chat skin enabled.")
    else
        if active then
            active = false
            Try("disable", SetOverlaysShown, false)
            Try("disable", RestoreStripped)
            for f, wanted in pairs(hiddenFrames) do
                if wanted then pcall(f.Show, f) end
            end
            Print("SAO chat skin disabled. Type /reload to fully restore Blizzard's chat look.")
        else
            Print("SAO chat skin disabled.")
        end
    end
end

function ns.ChatSetEnabled(on)
    local ok, err = pcall(SetEnabled, on and true or false)
    if not ok then LogError("toggle", err) end
end
