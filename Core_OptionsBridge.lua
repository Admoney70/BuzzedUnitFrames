-- ============================================================
-- BuzzardFrames: Core_OptionsBridge.lua
-- The single chokepoint between the addon and its options panel.
--
-- Runtime code must never reach for the panel directly. It calls one of
-- the functions below, and this file is the only place that knows which
-- panel implementation is behind them. That is why the swap from the old
-- dialog to the BuzzardPanel-based options (the BuzzardFramesOptions
-- addon) touched this file and none of the ~29 call sites, and why the
-- old dialog's removal was a change to this file and the .toc alone.
--
--   BF:OpenOptions()                 open the options panel
--   BF:IsOptionsShown()              is the panel open and visible?
--   BF:RefreshPanel(key)             re-read values / re-evaluate predicates
--   BF:RefreshPanelChrome(which)     refresh one piece of panel chrome
--   BF:OpenPanelAt(...)              select a page (panel must be open)
--   BF:CloseOptions()                close the panel
--   BF:PrepareOptionsSession()       reset the Modifying Layout before an open
--   BF:PrimeOptionsFonts()           touch every LSM font once before an open
--   BF:ShowTextWindow(title, text, opts)  copyable read-only text window
--
-- `key` on RefreshPanel is ADVISORY: every key today maps to a page
-- refresh (values re-read, shape re-derived), which is what each caller
-- wanted. Keep recording a key at every call site -- it is what a narrower
-- mapping would be keyed on.
--
-- BEHAVIOR NOTE (owner-approved, P-1): RefreshPanel returns early when
-- the panel is closed. A refresh of a closed panel has nothing to do; the
-- panel re-reads everything on its next open.
-- ============================================================
local BF = _G["BuzzardFrames"]

local APP = "BuzzardFrames"

-- The BuzzardPanel app, or nil until BuzzardFramesOptions has loaded and
-- declared it. Every LibStub lookup in this file is SILENT (the `true`
-- second arg): before the first open there is no app, and every query
-- below answers "closed" instead of erroring.
local function GetApp()
    local Panel = LibStub and LibStub("BuzzardPanel-1.0", true)
    return Panel and Panel.GetApp and Panel:GetApp(APP) or nil
end

local function AppShown()
    local app = GetApp()
    return (app and app:IsShown()) and true or false
end

-- ── Session prep ───────────────────────────────────────────────
-- Modifying Layout reset rule: when the user opens the options panel
-- while Setup Mode is NOT active, the panel was last closed without a
-- setup-mode edit session carrying over, so _modifyingFlat should
-- revert to the currently-active (live-rendering) flat. If Setup Mode
-- IS active, the user has an edit session still running, so leave
-- their selection alone. The panel calls this before it shows anything,
-- so its Modifying Layout dropdown picks up the new value on first build.
function BF:PrepareOptionsSession()
    if not (self.db and self.db.global and self.db.global.setupModeActive) then
        local fl = self.rpDB.profile.layouts.flatLayouts or {}
        local activeID = self:ResolveActiveFlat(self:GetActiveSlot())
        if activeID and activeID ~= "none" and fl[activeID] then
            self._modifyingFlat = activeID
        else
            self._modifyingFlat = fl.flat_party and "flat_party" or nil
        end
        self:InvalidateRaidProfileCache()
        -- Rebuild per-CFG aura caches immediately so that the preview
        -- renderer (which fires during this same open) reads a
        -- fully-populated table via GetAuraCacheForFrame rather than the
        -- empty table left by InvalidateRaidProfileCache.
        if self.UpdateAuraSizeCache then self:UpdateAuraSizeCache() end
    end
end

-- Prime the font cache the first time the options panel is opened.
-- Font pickers preview each listed font as the dropdown is built. A font
-- file the client has not loaded yet makes SetFont fail and the row
-- renders blank; the failed call kicks off the load, so the second open
-- shows it. Touching every registered font once here (via a throwaway
-- FontString) forces those loads before any picker opens, so no rows come
-- up blank. Runs one time, and only if the user actually opens options --
-- no cost for anyone who never does.
function BF:PrimeOptionsFonts()
    if self._fontsPrimed then return end
    self._fontsPrimed = true
    local LSM = LibStub("LibSharedMedia-3.0", true)
    if not LSM then return end
    local primer = self._fontPrimer
    if not primer then
        primer = UIParent:CreateFontString(nil, "BACKGROUND")
        self._fontPrimer = primer
    end
    for _, path in pairs(LSM:HashTable("font")) do
        primer:SetFont(path, 12, "")
    end
end

-- ── Opening ────────────────────────────────────────────────────
--
-- The panel and the library it is built on live in BuzzardFramesOptions, a
-- separate LOAD-ON-DEMAND addon shipped alongside this one. Neither is
-- parsed at login, and this is the only thing here that knows they exist.
--
-- Two failure modes, two messages. A reader whose copy is missing or
-- disabled and a reader who is in combat have different problems, and one
-- "could not open the panel" tells neither of them what to do.
local IsLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
local LoadIt   = (C_AddOns and C_AddOns.LoadAddOn)     or LoadAddOn

function BF:OpenOptions()
    if not IsLoaded("BuzzardFramesOptions") then
        -- An addon cannot be loaded in combat. Without this the load simply
        -- fails and the reason is buried in a return value nobody sees.
        if InCombatLockdown() then
            self:Print("BuzzardFramesOptions cannot be loaded in combat.")
            return
        end
        LoadIt("BuzzardFramesOptions")
    end
    if not BuzzardFramesOptions then
        self:Print("You need the BuzzardFramesOptions addon enabled to be "
            .. "able to configure Buzzard Frames.")
        return
    end
    -- Replace this function with one that just opens the panel: everything
    -- above is a one-time question, and re-asking it on every open can only
    -- ever produce the same answer. It is also why there is no "have I
    -- loaded it yet" flag here to fall out of step with reality.
    self.OpenOptions = function(self)
        self:PrimeOptionsFonts()
        BuzzardFramesOptions:Open()
    end
    self:OpenOptions()
end

-- ── Queries ────────────────────────────────────────────────────
function BF:IsOptionsShown()
    return AppShown()
end

-- ── Refresh ────────────────────────────────────────────────────
function BF:RefreshPanel(key)          -- luacheck: ignore key
    local app = GetApp()
    if app and app:IsShown() then app:RefreshPage() end
end

-- Panel chrome. Two runtime call sites need to poke it; they go through
-- here so they never touch the frame themselves.
--   which = "setupButton"    -- the Setup Mode button's label / state
--         = "layoutDropdown" -- the Modifying Layout dropdown's visibility
--
-- The BuzzardPanel app draws the Setup Mode and Unlock buttons in its
-- footer and, in the rail-less layout, in its status strip -- both read
-- their state on render, so a refresh of each is the whole job. Its
-- Modifying dropdowns live on the pages, so that one is a page refresh.
function BF:RefreshPanelChrome(which)
    local app = GetApp()
    if not (app and app:IsShown()) then return end
    if which == "setupButton" then
        if app.RefreshFooter    then app:RefreshFooter()    end
        if app.RefreshStatusBar then app:RefreshStatusBar() end
    elseif which == "layoutDropdown" then
        app:RefreshPage()
    end
end

-- ── Navigation ─────────────────────────────────────────────────
-- Select a page by path, e.g. BF:OpenPanelAt("raidPartyFrames", "aurasBuffs").
-- The route ids are declared in Panel.lua. Callers that need the panel
-- built first must defer themselves; see the C_Timer.After(0) in
-- Core_Notifications.lua and the comment there.
function BF:OpenPanelAt(...)
    local app = GetApp()
    if app and app:IsShown() then app:Navigate(...) end
end

function BF:CloseOptions()
    local app = GetApp()
    if app and app:IsShown() then app:Close() end
end

-- ── Copyable text window ───────────────────────────────────────
-- Export strings and diagnostics (/bf loadreport, /bf sbdiag,
-- /bf slotroster, the profile export) all want the same thing: a
-- read-only window whose contents are pre-selected for one Ctrl+C.
-- One plain frame, built on first use and reused; ESC closes it.
--
-- opts (all optional): status, label, width, height.
-- Returns true if a window was shown; false if the caller should fall
-- back to chat (only when UIParent is unavailable, which it never is in
-- practice -- kept so every caller's chat fallback stays reachable).
local textWindow

local function BuildTextWindow()
    local f = CreateFrame("Frame", "BuzzardFramesTextWindow", UIParent, "BackdropTemplate")
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:SetPoint("CENTER")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    f:SetBackdropColor(0, 0, 0, 1)
    f:SetClampedToScreen(true)

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.title:SetPoint("TOP", 0, -16)

    f.status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.status:SetPoint("BOTTOMLEFT", 20, 18)
    f.status:SetPoint("BOTTOMRIGHT", -20, 18)
    f.status:SetJustifyH("LEFT")
    f.status:SetWordWrap(false)

    f.label = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.label:SetPoint("TOPLEFT", 20, -44)
    f.label:SetPoint("TOPRIGHT", -20, -44)
    f.label:SetJustifyH("LEFT")

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -6, -6)

    local scroll = CreateFrame("ScrollFrame", "BuzzardFramesTextWindowScroll", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 20, -66)
    scroll:SetPoint("BOTTOMRIGHT", -40, 40)
    f.scroll = scroll

    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetAutoFocus(false)
    edit:SetFontObject(GameFontHighlightSmall)
    edit:SetWidth(scroll:GetWidth())
    edit:SetScript("OnEscapePressed", function() f:Hide() end)
    -- Read-only: any edit is undone, but selection and Ctrl+C still work.
    edit:SetScript("OnTextChanged", function(eb, userInput)
        if userInput and eb.bfText then eb:SetText(eb.bfText) end
    end)
    edit:SetScript("OnEditFocusGained", function(eb) eb:HighlightText() end)
    scroll:SetScrollChild(edit)
    scroll:SetScript("OnSizeChanged", function(sf, w) edit:SetWidth(w) end)
    f.edit = edit

    -- Register with the special-frames list so ESC closes it like any
    -- other panel.
    tinsert(UISpecialFrames, "BuzzardFramesTextWindow")
    return f
end

function BF:ShowTextWindow(title, text, opts)
    if not UIParent then return false end
    opts = opts or {}
    textWindow = textWindow or BuildTextWindow()
    local f = textWindow
    f:SetSize(opts.width or 820, opts.height or 560)
    f.title:SetText(title or "BuzzardFrames")
    f.status:SetText(opts.status or "Press CTRL-C to copy.")
    f.label:SetText(opts.label or "Press CTRL-C to copy.")
    f.edit.bfText = text or ""
    f.edit:SetText(text or "")
    f.edit:SetWidth(f.scroll:GetWidth())
    f:Show()
    f.scroll:SetVerticalScroll(0)
    f.edit:SetFocus()
    f.edit:HighlightText()
    return true
end
