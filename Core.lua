-- ============================================================
-- BuzzardFrames: Core.lua
-- Entry point. Keeps the small handful of things that truly
-- belong here:
--   \u2022 Font constants (used everywhere)
--   \u2022 Cyrillic detection / transliteration helpers
--   \u2022 Header iteration helpers (cross-cutting)
--   \u2022 AceAddon OnInitialize entry point
-- Everything else has been split into sibling Core_*.lua files.
-- BF addon object is created in Defaults.lua (loaded first).
-- The options panel is the BuzzardFramesOptions addon (Core_OptionsBridge.lua).
-- ============================================================
local BF = _G["BuzzardFrames"]

-- Safe fallback for pre-Midnight clients where issecretvalue doesn't exist.
local issecretvalue = issecretvalue or function() return false end

-- ============================================================
-- DEBUG OUTPUT GATE
-- Every developer/diagnostic chat line (profiling, warm-up telemetry,
-- /bf debug* dumps, ...) routes through BF:DebugPrint, which stays
-- SILENT unless BOTH toggles are on:
--   NOTE: the red "…error:" pcall notices are deliberately NOT gated —
--   they stay visible so users can still report real errors.
--   • "Enable Experimental Options" -> db.global.enableExperimentalOptions
--   • "Show Debug Outputs in chat"   -> db.global.showDebugOutput
-- Both live in Preview & Special Options -> Experimental Options.
-- Both default off, so normal users never see debug output. Genuine
-- user-facing messages (Layout Applied, Setup Mode, profile-migration
-- notice, /bf sbslots) keep using plain print and are unaffected.
-- ============================================================
-- The one answer to "is Enable Experimental Options on?". Every gate --
-- the debug output below, the options pages that hide experimental
-- widgets in both panels -- asks through here rather than reaching into
-- db.global itself, so the key is named in one place.
function BF:IsExperimentalEnabled()
    local g = self.db and self.db.global
    return (g and g.enableExperimentalOptions) and true or false
end

-- The developer-only Panel Config section of the options panel is behind
-- db.global.devPanelConfig, flipped by `/bf dev panelconfig`
-- (Core_ChatCommands.lua). A chat command rather than a switch on a page:
-- these are the panel's own knobs, not addon settings, and a reader who
-- has not been told the command has no reason to see them. Persists with
-- the rest of db.global.
function BF:IsDevPanelConfigEnabled()
    local g = self.db and self.db.global
    return (g and g.devPanelConfig) and true or false
end

function BF:SetDevPanelConfigEnabled(on)
    local g = self.db and self.db.global
    if not g then return end
    g.devPanelConfig = on and true or nil
end

-- ============================================================
-- POSITION SLIDER BOUNDS
-- Half-screen dimensions, read live (GetScreenWidth/Height can be wrong
-- early at login before the UI is laid out), so every X/Y position slider
-- in the options panel shares one range.
-- ============================================================
function BF:GetPositionHalfW()
    return math.floor(GetScreenWidth() / 2)
end

function BF:GetPositionHalfH()
    return math.floor(GetScreenHeight() / 2)
end

function BF:IsDebugOutputEnabled()
    local g = self.db and self.db.global
    return (self:IsExperimentalEnabled() and g and g.showDebugOutput) and true or false
end

function BF:DebugPrint(...)
    if self:IsDebugOutputEnabled() then
        print(...)
    end
end

-- ============================================================
-- ADDON FONT
-- Default font used across all BuzzardFrames text elements.
-- ============================================================
BF.font = "Interface\\AddOns\\BuzzardFrames\\Media\\Fonts\\PTSansNarrow.ttf"

-- Cyrillic fallback: a font shipped with every WoW client that covers
-- Cyrillic (U+0400–U+04FF). Used when a unit name contains Cyrillic
-- characters that the primary font can't render.
BF.cyrillicFont = BF.font  -- PTSansNarrow supports Cyrillic; use the same primary font

-- Returns true if the UTF-8 string contains any Cyrillic characters.
-- Cyrillic block U+0400–U+04FF encodes as two bytes: lead byte 0xD0 or 0xD1
-- (decimal 208–209), followed by a continuation byte (0x80–0xBF, decimal 128–191).
-- Uses decimal escapes (\ddd) because WoW runs Lua 5.1 which does not support \x hex escapes.
function BF:HasCyrillic(str)
    if not str or issecretvalue(str) then return false end
    return str:find("[\208\209\210\211][\128-\191]") ~= nil
end

-- Transliterates Cyrillic characters in a string to Latin equivalents.
-- Uses the same mapping as Grid2 (GridUtils.lua strCyr2Lat).
-- Guards against secret values — returns the original string unchanged if secret.
-- gsub with ".." matches every 2-byte sequence; the table only contains Cyrillic
-- keys so non-Cyrillic 2-byte sequences pass through unchanged.
do
    local gsub = string.gsub
    local _Cyr2Lat = {
        ["А"]="A",  ["а"]="a",  ["Б"]="B",  ["б"]="b",  ["В"]="V",  ["в"]="v",
        ["Г"]="G",  ["г"]="g",  ["Д"]="D",  ["д"]="d",  ["Е"]="E",  ["е"]="e",
        ["Ё"]="e",  ["ё"]="e",  ["Ж"]="Zh", ["ж"]="zh", ["З"]="Z",  ["з"]="z",
        ["И"]="I",  ["и"]="i",  ["Й"]="Y",  ["й"]="y",  ["К"]="K",  ["к"]="k",
        ["Л"]="L",  ["л"]="l",  ["М"]="M",  ["м"]="m",  ["Н"]="N",  ["н"]="n",
        ["О"]="O",  ["о"]="o",  ["П"]="P",  ["п"]="p",  ["Р"]="R",  ["р"]="r",
        ["С"]="S",  ["с"]="s",  ["Т"]="T",  ["т"]="t",  ["У"]="U",  ["у"]="u",
        ["Ф"]="F",  ["ф"]="f",  ["Х"]="Kh", ["х"]="kh", ["Ц"]="Ts", ["ц"]="ts",
        ["Ч"]="Ch", ["ч"]="ch", ["Ш"]="Sh", ["ш"]="sh", ["Щ"]="Shch", ["щ"]="shch",
        ["Ъ"]="",   ["ъ"]="",   ["Ы"]="Y",  ["ы"]="y",  ["Ь"]="",   ["ь"]="",
        ["Э"]="E",  ["э"]="e",  ["Ю"]="Yu", ["ю"]="yu", ["Я"]="Ya", ["я"]="ya",
    }
    function BF:TransliterateCyrillic(str)
        if not str or issecretvalue(str) then return str end
        return gsub(str, "..", _Cyr2Lat)
    end
end

-- ============================================================
-- HEADER ITERATION HELPERS
-- Works for both strict mode (self.groupHeaders table) and
-- single-header mode (self.mainHeader).
-- ============================================================

-- Call func(header) for every active raid header.
function BF:IterateHeaders(func)
    if self.groupHeaders then
        for i = 1, 8 do
            if self.groupHeaders[i] then func(self.groupHeaders[i]) end
        end
    elseif self.mainHeader then
        func(self.mainHeader)
    end
end

-- Call func(frame) for every child frame across all active raid headers.
function BF:IterateHeaderChildren(func)
    self:IterateHeaders(function(header)
        local i = 1
        while true do
            local frame = header:GetAttribute("child" .. i)
            if not frame then break end
            func(frame)
            i = i + 1
        end
    end)
end

-- ============================================================
-- OPTION-WIDGET REFRESH DEBOUNCE
-- Continuous-fire widgets (range sliders and color pickers) call
-- their AceConfig setter on EVERY drag tick; running a frame-walking
-- refresh per tick stutters the client. This coalesces the refresh to
-- a trailing edge, keyed so independent refresh targets each land.
-- The PROFILE WRITE must stay in the setter (immediate) — only the
-- refresh goes through here; the last scheduled run then reads the
-- final value. Combat is re-checked in the callback (a drag can cross
-- into combat), matching the Options_Frames resize-timer pattern this
-- generalizes.
-- ============================================================
local _optionDebounceTimers = {}
function BF:DebounceOption(key, fn, delay)
    local t = _optionDebounceTimers[key]
    if t then t:Cancel() end
    _optionDebounceTimers[key] = C_Timer.NewTimer(delay or 0.15, function()
        _optionDebounceTimers[key] = nil
        if InCombatLockdown() then return end
        fn()
    end)
end

-- v76 (owner ruling): MOUSE-UP-GATED variant, for setters whose refresh is
-- heavy enough that even the trailing debounce hurts — the aura-container
-- walks. A slider fires its setter on every drag notch, and DebounceOption
-- still ran the refresh MID-DRAG whenever the user paused for the delay;
-- with a container walk behind it, that hitches the drag itself.
--
-- This variant does NO work while the left button is held. AceConfigDialog
-- registers range controls' ActivateSlider for OnMouseUp as well as
-- OnValueChanged (AceConfigDialog-3.0.lua:1230-1231), so the setter fires
-- one final time on release — that call lands here with the button up and
-- runs fn IMMEDIATELY, on the final value. Non-drag input runs immediately
-- too: toggle/dropdown clicks fire on mouse-up by default, and editbox /
-- mouse-wheel input holds no button.
--
-- The held-button branch arms a trailing timer purely as a FALLBACK for
-- drag sources that deliver no final released-button setter call (the
-- color-picker wheel): it RE-ARMS while the button is still held, so it
-- can only ever fire after the drag ends — never mid-drag. The immediate
-- path cancels any pending fallback first, so fn cannot run twice for one
-- gesture. Shares DebounceOption's timer table so the two variants used on
-- the same key coalesce instead of racing.
function BF:MouseUpOption(key, fn, delay)
    local t = _optionDebounceTimers[key]
    if t then t:Cancel(); _optionDebounceTimers[key] = nil end
    if IsMouseButtonDown("LeftButton") then
        _optionDebounceTimers[key] = C_Timer.NewTimer(delay or 0.25, function()
            _optionDebounceTimers[key] = nil
            BF:MouseUpOption(key, fn, delay)
        end)
        return
    end
    if InCombatLockdown() then return end
    fn()
end

-- ============================================================
-- ENTRY POINT
-- AceAddon calls this once at ADDON_LOADED.
-- ============================================================
function BF:OnInitialize()
    -- §L5.1: ADDON_LOADED boundary. Everything before this mark is file
    -- parse + SavedVariables deserialisation; the delta from chunk:end is
    -- exactly the SV load the /reload path pays differently to a cold login.
    self:LoadMark("init:enter")
    self:RegisterDB()
    self:RegisterChatCommand("bf", "OnChatCommand")
    self:RegisterChatCommand("buzzard", "OnChatCommand")
    self:RegisterChatCommand("buzzardframes", "OnChatCommand")
    -- One-shot cleanup of orphan SavedVariables left over from the
    -- Phase 4 discrepancy logger (deleted in Phase 5 of the missing-
    -- raid-buff redesign). Safe to remove this line after a release
    -- cycle when all users have loaded once post-cleanup.
    if BuzzardFramesDB then
        BuzzardFramesDB.missingRaidBuffDiscrepancyLog = nil
    end
    self:LoadMark("init:exit")
end
