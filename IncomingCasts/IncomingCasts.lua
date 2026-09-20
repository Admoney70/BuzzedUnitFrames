-- ============================================================
-- BuzzardFrames: IncomingCasts.lua
-- Tracks enemy nameplate casts targeting the player and
-- renders cast bar or icon overlays on the player's party frame.
--
-- Uses PlayerIsSpellTarget for target resolution (works for
-- the player only). Party member targeting is blocked by
-- Blizzard's secret value restrictions in Midnight.
-- ============================================================

local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

local UnitExists          = UnitExists
local UnitCanAttack       = UnitCanAttack
local UnitInParty         = UnitInParty
local UnitAffectingCombat = UnitAffectingCombat
local UnitCastingInfo     = UnitCastingInfo
local UnitChannelInfo     = UnitChannelInfo
local UnitCastingDuration = UnitCastingDuration
local UnitGUID            = UnitGUID
local UnitChannelDuration = UnitChannelDuration
local C_Spell             = C_Spell
local GetTime             = GetTime
local IsInGroup           = IsInGroup
local GetInstanceInfo     = GetInstanceInfo
local rawget              = rawget
local pairs               = pairs
local ipairs              = ipairs
local next                = next
local table_insert        = table.insert
local table_remove        = table.remove
local table_wipe          = table.wipe
-- 12.1: sizes and positions read off a frame parented into the unit-frame
-- chain come back SECRET, and a secret cannot be compared or used in
-- arithmetic. Localised with the addon's usual fallback.
local issecretvalue       = issecretvalue or function() return false end
local pcall               = pcall

local IC = {}
BF.IncomingCasts = IC

-- castingUnit -> entry { frame, spellId, startTime }
local activeCasts = {}

-- ONE POOL PER DISPLAY TYPE, not one shared pool.
--
-- AcquireFrame used to pop the last entry of a single pool and, when it was
-- the wrong type, hand it straight back and build a new frame. While both
-- displays were forced to the same type that only misfired right after a
-- type change -- and IC:Refresh wipes the pool anyway -- so it was latent.
--
-- Now the two displays choose their type independently, and the dance is
-- pathological: the wrong-type frame is pushed back onto the END of the pool
-- and popped again next time, so the pool never converges. Simulated over 200
-- casts with one display on Cast Bar and the other on Icon, it created 201
-- frames and reused none. A pool keyed by type cannot hand back the wrong
-- thing, so the acquire-then-fix dance is gone entirely.
--
-- ...and, since the per-display split, ONE POOL PER DISPLAY within each type.
--
-- ApplyCastBarStyle refuses its fast path when a frame was last styled for
-- the OTHER display (`_styleDisplay ~= _display`), and a pool shared by both
-- displays could not honor that: ReleaseCastsForUnit pushes the party frame
-- and then the player frame, the next reposition pops for the party display
-- FIRST and gets the player-styled frame, then the player display gets the
-- party-styled one -- so with both displays on, EVERY cast start paid two
-- full style passes on the combat path. Keying the pool by display means a
-- frame only ever goes back to the display it was styled for, and the
-- generation guard holds. The keys are the DISPLAY_* values ("party" /
-- "player"), which are declared just below.
local framePools = {
    castbar = { party = {}, player = {} },
    icon    = { party = {}, player = {} },
}
local layoutBarPool = {}

-- SetParent relinks the frame hierarchy and invalidates the whole subtree's
-- rects, so repeating it when nothing changed is pure waste -- and it ran for
-- EVERY entry on EVERY reposition, which fires on every cast start, every cast
-- end and every nameplate removal.
--
-- `_bf_parent` caches the last parent we set. EVERY SetParent in this file
-- must go through here: a direct call would leave the cache stale and strand
-- a frame on the wrong parent, which is far worse than the call it saves.
-- Returns true when it actually reparented, so callers can re-assert the
-- things a reparent disturbs.
local function SetFrameParent(frame, parent)
    if frame._bf_parent == parent then return false end
    frame:SetParent(parent)
    frame._bf_parent = parent
    return true
end

-- Forward declarations (defined after POSITIONING section)
local SetupCastFrame
local EnsurePlayerAnchor

-- ============================================================
-- SETTINGS
-- ============================================================

local function GetSettings()
    return BF.icDB and BF.icDB.profile
end
local function IsEnabled() local ic = GetSettings(); return ic and ic.incomingCastsEnabled end

-- ============================================================
-- PER-DISPLAY CONFIG
--
-- Incoming Casts has two INDEPENDENT displays and every appearance /
-- behavior setting belongs to one of them (43 of them; the list lives at
-- BF.incomingCastsPerDisplayKeys in Defaults_IncomingCasts.lua, which is the
-- single source of truth). The party display owns the unprefixed profile
-- keys; the detached "Incoming Casts Frame" owns incomingCastsPlayer<Suffix>.
--
-- NOTE the naming reads backwards: "Player" is the DETACHED frame, not the
-- party player frame. That is the convention the position keys
-- (incomingCastsPlayerAnchorX/Y, PlayerGrowDirection, PlayerSpacing) already
-- established.
--
-- Each display's 43 values are resolved into a flat table ONCE and reused,
-- so a runtime read is a single table lookup with no string concatenation on
-- the cast path. Settings only change through IC:Refresh / IC:OnSettingChanged
-- (verified: all 51 options setters reach one of them), which invalidate it.
--
-- Color values are stored by REFERENCE into the profile's own tables. Read
-- only -- never mutate a resolved value.
local DISPLAY_PARTY  = "party"
local DISPLAY_PLAYER = "player"

-- Cast filter modes. Declared here because BuildCfg below maps the legacy
-- ShowAllCasts boolean onto them; the calls that USE them are further down.
local FILTER_AIMED     = "aimed"
local FILTER_ALL       = "all"
local FILTER_NOT_AIMED = "notAimed"

local KEY_PREFIX = {
    [DISPLAY_PARTY]  = "incomingCasts",
    [DISPLAY_PLAYER] = "incomingCastsPlayer",
}

local cfgCache = { [DISPLAY_PARTY] = {}, [DISPLAY_PLAYER] = {} }
local cfgValid = false

-- Layout snapshot validity (the snapshot machinery itself lives just above
-- RepositionPlayerCasts, which is its only consumer). Declared here so the
-- two invalidators below can reach it: every path that invalidates the cfg
-- flats or the party grow direction ALSO invalidates the snapshots, because
-- both feed them.
local snapValid    = false
local snapPartyDir = nil

local function InvalidateCfg()
    cfgValid  = false
    snapValid = false
end

local function BuildCfg()
    cfgValid = true
    local ic   = BF.icDB and BF.icDB.profile
    local keys = BF.incomingCastsPerDisplayKeys
    if not (ic and keys) then return end

    for display, prefix in pairs(KEY_PREFIX) do
        local t = cfgCache[display]
        table_wipe(t)
        for i = 1, #keys do
            local suffix = keys[i]
            t[suffix] = ic[prefix .. suffix]
        end

        -- Legacy read-time mapping, never a migration: the old per-display
        -- boolean ShowAllCasts becomes the three-way CastFilter. An untouched
        -- profile has no CastFilter, so derive it and leave the saved data
        -- alone. (House rule -- legacy values are mapped at read time.)
        if t.CastFilter == nil then
            t.CastFilter = t.ShowAllCasts and FILTER_ALL or FILTER_AIMED
        end
    end
end

-- display defaults to the party display; pass DISPLAY_PLAYER for the
-- detached one. Never returns nil.
function IC:GetCfg(display)
    if not cfgValid then BuildCfg() end
    return cfgCache[display] or cfgCache[DISPLAY_PARTY]
end

local function GetDisplayType(display)
    local c = IC:GetCfg(display)
    return c.DisplayType or "castbar"
end

-- ============================================================
-- CAST FILTER
--
-- Per display, one of three modes:
--   "aimed"    -- only casts aimed at the player   (the default)
--   "all"      -- every tracked cast
--   "notAimed" -- every tracked cast EXCEPT those aimed at the player
--
-- `targets` is the SECRET PlayerIsSpellTarget boolean. It is never read --
-- only handed to engine calls that accept a secret and do the branching
-- themselves. "notAimed" is therefore free: SetAlphaFromBoolean already
-- takes the if-true and if-false values as two arguments, so inverting is
-- just passing them the other way round (the not-aimed tint has always done
-- this). There is no SetShownFromBoolean, so hidden entries sit at alpha 0
-- rather than being :Hide()n -- see the note above PositionOnFrame.
--
-- Consequence worth knowing: nothing can COUNT the visible entries in the
-- "aimed" or "notAimed" modes, so "hide the display when it is empty" is not
-- expressible.
-- Frame visibility for a display's filter. `opacity` is the user's opacity,
-- folded into the shown arm because this call OWNS the frame's alpha (a
-- plain SetAlpha would be overwritten on the next reposition).
local function ApplyFilterAlpha(frame, filter, targets, opacity)
    if filter == FILTER_ALL or targets == nil then
        frame:SetAlpha(opacity)
    elseif filter == FILTER_NOT_AIMED then
        frame:SetAlphaFromBoolean(targets, 0, opacity)
    else
        frame:SetAlphaFromBoolean(targets, opacity, 0)
    end
end

-- The same decision for a layout bar's fill VALUE, which is what makes a
-- filtered-out entry collapse to zero size in the anchor chain instead of
-- leaving a gap.
local function ApplyFilterLayoutValue(layoutBar, filter, targets)
    if filter == FILTER_ALL or targets == nil then
        layoutBar:SetValue(1)
    elseif filter == FILTER_NOT_AIMED then
        layoutBar:SetValue(C_CurveUtil.EvaluateColorValueFromBoolean(targets, 0, 1))
    else
        layoutBar:SetValue(C_CurveUtil.EvaluateColorValueFromBoolean(targets, 1, 0))
    end
end

-- Change-guarded wrappers for the two calls above.
--
-- These were the only two unguarded calls in PositionOnFrame's loop, on the
-- reasoning that a secret cannot be compared. It still cannot -- but the
-- secret is never what changes. `targets` is captured once per cast and the
-- frame / layout bar belongs to that cast until it is released, so the ONLY
-- inputs that can move between repositions are `filter` and `opacity`, both
-- plain settings scalars. Stamping those is enough: an unchanged stamp means
-- the engine already holds the right value. The stamps are cleared wherever
-- the object changes hands (ReleaseFrame, PoolLayoutBar, the hold-time
-- freeze), so a recycled frame always re-applies once.
--
-- Worth more than two skipped calls: SetValue on layout bar i resizes its
-- fill texture, and every later bar and cast frame in the chain is anchored
-- to it, so each redundant SetValue re-dirtied the whole tail of the chain --
-- O(N^2) rect invalidation per reposition, on nearly every render frame of a
-- pull.
--
-- A nil filter never guards (BuildCfg always resolves one; this is a
-- backstop so a nil stamp can never match a nil filter and skip the first
-- apply).
local function ApplyFilterLayoutValueGuarded(layoutBar, filter, targets)
    if filter ~= nil and layoutBar._bf_lvFilter == filter then return end
    ApplyFilterLayoutValue(layoutBar, filter, targets)
    layoutBar._bf_lvFilter = filter
end

local function ApplyFilterAlphaGuarded(frame, filter, targets, opacity)
    if filter ~= nil and frame._bf_afFilter == filter
        and frame._bf_afOpacity == opacity
    then
        return
    end
    ApplyFilterAlpha(frame, filter, targets, opacity)
    frame._bf_afFilter, frame._bf_afOpacity = filter, opacity
end

-- All three default to the PARTY display; pass DISPLAY_PLAYER for the
-- detached one.
local function GetCastBarWidth(display)  local c = IC:GetCfg(display); return c.BarWidth  or 80 end
local function GetCastBarHeight(display) local c = IC:GetCfg(display); return c.BarHeight or 12 end
local function GetIconSize(display)      local c = IC:GetCfg(display); return c.IconSize  or 20 end

-- Party frame position settings
--
-- The party grow direction is MEMOISED with a short time bound, because
-- resolving it is by far the most expensive read on the reposition path.
-- BF:GetActivePartyProfile is the one uncached member of its family (contrast
-- BF:GetRaidProfile, which memoises): every call walks GetActiveSlot ->
-- ResolveActiveFlat, costing two or three GetInstanceInfo calls, two
-- UnitGroupRolesAssigned calls, a couple of tostring allocations and a fresh
-- table or two. It ran once per reposition, and a reposition lands on nearly
-- every render frame during a pull.
--
-- A PERMANENT memo would be wrong. The answer moves without anything telling
-- this module, in at least four ways:
--
--   * an options edit writes sorting.growDirection and calls ReloadLayout;
--   * an rpDB profile switch goes through RefreshAll -> ApplyProfile;
--   * the per-layout "sorting" toggle re-points where the value is read from;
--   * a spec change or role reassignment re-resolves the active flat with no
--     setting having changed at all.
--
-- None of those reach BF.IncomingCasts, and there is no addon-wide
-- layout-changed callback to subscribe to -- the nearest thing is hooking
-- RefreshProfileCache, which still misses the first and third.
--
-- So the memo is bounded by wall time instead. IC:Refresh and
-- IC:RebindContext clear it outright, covering the settings and zone paths;
-- the TTL is the backstop for the rest. Call rate drops from once a frame to
-- four times a second, and the worst case is that bars spawned in the next
-- quarter-second grow the old way after a layout edit -- an edit that happens
-- out of combat, where repositions are rare enough that the memo has usually
-- expired before the next one anyway.
local PARTY_DIR_TTL = 0.25
local partyDirCache, partyDirExpiry = nil, 0

local function InvalidatePartyDir()
    partyDirCache, partyDirExpiry = nil, 0
    -- The party snapshot bakes in the anchor/grow tables derived from this
    -- direction, so it cannot outlive the memo.
    snapValid = false
end

local function GetPartyGrowDir()
    local now = GetTime()
    if partyDirCache and now < partyDirExpiry then return partyDirCache end
    -- "RIGHT" is the same fallback the uncached version used, and it is now
    -- also substituted for a nil growDirection. Both callers already mapped
    -- nil and "RIGHT" to the same answer, so this is not a behavior change --
    -- it just means the memo never has to cache a nil.
    local dir = "RIGHT"
    if BF.GetActivePartyProfile then
        local pp = BF:GetActivePartyProfile()
        local sp = BF:GetSectionProfile("sorting", pp)
        if sp and sp.growDirection then dir = sp.growDirection end
    end
    partyDirCache  = dir
    partyDirExpiry = now + PARTY_DIR_TTL
    return dir
end
-- `partyDir` is the already-resolved GetPartyGrowDir(). Optional, but the
-- reposition path always supplies it: resolving it walks
-- GetActivePartyProfile -> GetActiveSlot -> ResolveActiveFlat, a full
-- profile precedence chain, and this and GetGrowDirection below were each
-- calling it independently on every reposition.
local function GetAnchorPoint(partyDir)
    local ic = GetSettings(); local v = ic and ic.incomingCastsAnchorPoint
    if v == "AUTO" or v == nil then
        local dir = partyDir or GetPartyGrowDir()
        if dir == "RIGHT" or dir == "LEFT" then return "BOTTOM" end
        if dir == "UP"    then return "BOTTOMRIGHT" end
        if dir == "DOWN"  then return "TOPRIGHT" end
        return "BOTTOM"
    end
    return v
end
local function GetGrowDirection(partyDir)
    local ic = GetSettings(); local v = ic and ic.incomingCastsGrowDirection
    if v == "AUTO" or v == nil then
        local dir = partyDir or GetPartyGrowDir()
        if dir == "RIGHT" or dir == "LEFT" then return "DOWN" end
        if dir == "UP"    then return "UP" end
        if dir == "DOWN"  then return "DOWN" end
        return "DOWN"
    end
    return v
end
local function GetSpacing()  local ic = GetSettings(); return ic and ic.incomingCastsSpacing  or 2  end
local function GetOffsetX()  local ic = GetSettings(); return ic and ic.incomingCastsOffsetX  or 0  end
local function GetOffsetY()  local ic = GetSettings(); return ic and ic.incomingCastsOffsetY  or 0  end

-- Player frame position settings (detached, CENTER-relative like other UFs)
local function GetPlayerAnchorX() local ic = GetSettings(); return ic and ic.incomingCastsPlayerAnchorX or 0 end
local function GetPlayerAnchorY() local ic = GetSettings(); return ic and ic.incomingCastsPlayerAnchorY or -200 end
local function GetPlayerGrowDirection()
    local ic = GetSettings(); local v = ic and ic.incomingCastsPlayerGrowDirection
    if v == "AUTO" or v == nil then return "DOWN" end
    return v
end
local function GetPlayerSpacing() local ic = GetSettings(); return ic and ic.incomingCastsPlayerSpacing or 2 end

-- ============================================================
-- FRAME CREATION
-- ============================================================

local durationFormatter = nil
local function GetDurationFormatter()
    if durationFormatter then return durationFormatter end
    if not C_StringUtil or not C_StringUtil.CreateNumericRuleFormatter then return nil end
    durationFormatter = C_StringUtil.CreateNumericRuleFormatter()
    durationFormatter:SetBreakpoints({
        { threshold = 0, rounding = Enum.NumericRuleFormatRounding.Nearest, format = "%.1f", step = 0.1 },
        { threshold = 3, rounding = Enum.NumericRuleFormatRounding.Nearest, format = "%d" },
    })
    return durationFormatter
end

-- Engine-driven timer text. Built once per frame; the formatter and the
-- font string binding never change, only the duration object per cast.
--
-- This REPLACES a 10 Hz OnUpdate that was attached at construction and
-- never cleared, so it ran on every live frame for the whole of that
-- frame's life. Two things made that worse than it looks:
--
--   * The frames whose cast is not aimed at the player sit at alpha 0
--     but are still :Show()n, because PlayerIsSpellTarget is a SECRET
--     boolean and there is no SetShownFromBoolean to hide them
--     properly. Hidden frames skip OnUpdate; alpha-0 frames do not.
--   * It ticked with incomingCastsShowTimer OFF as well -- the font
--     string was hidden, the formatting work happened anyway.
--
-- The engine now owns the text, so the per-rendered-frame script cost
-- of this feature is zero. Same shape as Indicators/CastBar.lua.
-- Which formatter the engine's DurationTextBinding will actually take.
--
-- The NumericRuleFormatter above is what the old OnUpdate fed to
-- DurationObject:FormatRemainingDuration, and it is what produces the
-- current "2.5" / "4" look, so it is the one to keep if the binding
-- accepts it. But every PROVEN binding pairing -- Indicators/CastBar.lua
-- and Libs/oUF/elements/castbar.lua alike -- uses a SecondsFormatter,
-- and the API docs do not say which formatter types SetFormatter takes.
--
-- So probe once per session instead of guessing. If the rule formatter is
-- rejected we fall back to the same SecondsFormatter the party/raid cast
-- bar uses, which at least makes the two bars' timers match.
--
-- Caveat worth knowing: this catches a hard REJECTION. If SetFormatter
-- silently accepts a type it cannot use, the probe passes and the text
-- comes out wrong -- so the format is a PTR-verify item either way.
local bindingFormatter, bindingFormatterResolved

local function GetBindingFormatter()
    if bindingFormatterResolved then return bindingFormatter end
    bindingFormatterResolved = true

    if not (C_DurationUtil and C_DurationUtil.CreateDurationTextBinding) then
        return nil
    end

    local rule = GetDurationFormatter()
    if rule then
        local probe = C_DurationUtil.CreateDurationTextBinding()
        if pcall(probe.SetFormatter, probe, rule) then
            bindingFormatter = rule
            return bindingFormatter
        end
    end

    if C_StringUtil and C_StringUtil.CreateSecondsFormatter then
        local secs = C_StringUtil.CreateSecondsFormatter()
        secs:SetDefaultAbbreviation(Enum.SecondsFormatterAbbreviation.OneLetter)
        secs:SetMinInterval(Enum.SecondsFormatterInterval.Seconds)
        secs:SetMillisecondsThreshold(60)
        bindingFormatter = secs
    end
    return bindingFormatter
end

-- Fixed width for the cast bar's timer text.
--
-- The timer changes WIDTH as it counts down: the formatter switches to one
-- decimal below the 3-second breakpoint, so "4" becomes "2.9" and gains a
-- character. The spell name is anchored to the timer's LEFT edge, so that
-- edge moving mid-cast made a spell name that had been fitting suddenly
-- truncate -- and flip back a moment later. Reserving the widest string the
-- formatter can produce pins the edge, so the name's width is constant for
-- the whole cast.
--
-- The trade: the name is permanently about one digit shorter than its
-- best case, instead of intermittently much shorter. Stable beats maximal.
--
-- MEASURED, not guessed -- an em-fraction constant is wrong for any font
-- whose digits have different metrics. The measuring font string lives on
-- UIParent and is never parented into the unit-frame chain, so
-- GetStringWidth is safe to read here; on a frame inside that chain it
-- would come back a SECRET number and the arithmetic would hard-error.
--
-- "88.8" is the upper bound: below the breakpoint the format is one decimal
-- (at most "2.9"), above it plain integers, and a period plus three digits
-- is wider than any three digits alone.
local timerWidthCache, measureFS = {}, nil

local function GetTimerReserve(fontPath, fontSize, flags)
    if not fontPath then return nil end
    local key = fontPath .. "|" .. tostring(fontSize) .. "|" .. tostring(flags)
    local w = timerWidthCache[key]
    if w then return w end

    if not measureFS then
        measureFS = UIParent:CreateFontString(nil, "BACKGROUND")
        measureFS:Hide()
    end
    if not measureFS:SetFont(fontPath, fontSize, flags) then return nil end
    measureFS:SetText("88.8")

    w = measureFS:GetStringWidth()
    if not w or w <= 0 then return nil end
    w = w + 1                      -- a hair of slack for rounding
    timerWidthCache[key] = w
    return w
end

-- Binding enabled-state, change-guarded.
--
-- SetEnabled is not free: it starts or stops an engine-side ticker and
-- re-renders the font string. It used to be written from exactly two places,
-- both of which ran once per cast, so an unconditional call was fine. The
-- reposition path now toggles it per entry -- a frame parked past a chain's
-- cap has nothing to count down -- and that runs on nearly every render frame
-- during a pull, so the state has to be cached.
--
-- EVERY SetEnabled on a _timeBinding in this file must come through here. A
-- direct call would leave `_bf_bindOn` stale and strand a frame with a frozen
-- timer, which is precisely the failure the note in ApplyCastBarPerCastState
-- describes. Tolerates a nil binding (preview frames, and clients without
-- C_DurationUtil) so callers do not each need the guard.
local function SetBindingEnabled(f, on)
    if f._bf_bindOn == on then return end
    f._bf_bindOn = on
    local b = f._timeBinding
    if b then b:SetEnabled(on) end
end

local function AttachTimerBinding(f)
    if not f.timerText then return end
    if not (C_DurationUtil and C_DurationUtil.CreateDurationTextBinding) then return end
    local binding = C_DurationUtil.CreateDurationTextBinding()
    local fmt = GetBindingFormatter()
    if fmt then binding:SetFormatter(fmt) end
    binding:SetFontString(f.timerText)
    -- Match the cadence the old OnUpdate used (it self-throttled to 0.1s)
    -- rather than relying on an undocumented default. Cheap: the engine
    -- does the ticking, this only says how often to re-render the text.
    if binding.SetUpdateInterval then binding:SetUpdateInterval(0.1) end
    -- Assign BEFORE enabling: SetBindingEnabled reads f._timeBinding.
    f._timeBinding = binding
    SetBindingEnabled(f, true)
end

local function MakeEdge(parent)
    local t = BF.Texture(parent, nil, "OVERLAY", nil, 1)
    t:SetColorTexture(0, 0, 0, 1)
    return t
end

-- ============================================================
-- CAST BAR APPEARANCE
--
-- One styling pass shared by the LIVE frames (CreateCastBarFrame ->
-- pooled, repositioned per cast) and the OPTIONS PREVIEW frames
-- (CreatePreviewCastBar). Those two used to build their widgets
-- independently and had already drifted -- the preview never drew the
-- bar border at all. Every appearance option therefore lives here and
-- nowhere else, so the two cannot diverge again.
--
-- Color is the one exception: bar / uninterruptible / background
-- colors stay in the Unit Frames namespace (ufDB.profile) so the
-- Incoming Casts bars match the unit frame cast bars by default. See
-- SetupCastFrame and the note in Defaults_IncomingCasts.lua.
-- ============================================================

-- Icon metrics, derived once and used by BOTH the styling pass and the
-- layout chain in PositionOnFrame (which has to know how far the icon
-- overhangs the bar so the first frame in the chain lines up with the
-- anchor point). Returns 0,0 when the icon is off.
-- Player name + class color for the target-name text.
--
-- Both are static for the session and neither is secret: UnitName is a
-- plain string ONLY for the player (every other unit's is a secret value
-- on 12.1), and UnitClass on your own unit is likewise always readable.
-- So this resolves once and caches. The cache is cleared by IC:Refresh,
-- which runs on every settings change, so custom class colors from the
-- Colors page are picked up.
local playerNameCache, playerColorCache

local function ClearPlayerIdentityCache()
    playerNameCache, playerColorCache = nil, nil
end

-- Public, cheap. Called by BF:ApplyCustomClassColors so a class-color
-- edit is picked up. Deliberately NOT IC:Refresh -- that wipes the frame
-- pool and releases every live cast, and ApplyCustomClassColors also runs
-- from the RefreshProfileCache hook on every context change.
function IC:InvalidatePlayerIdentity()
    ClearPlayerIdentityCache()
    -- The target-name color is derived from the cached identity, so a
    -- class-color edit has to invalidate the style generation too --
    -- otherwise the cast-start fast path keeps the old color forever.
    IC._styleGen = (IC._styleGen or 1) + 1
end

local function GetPlayerIdentity()
    if not playerNameCache then
        playerNameCache = UnitName("player") or ""
        local _, className = UnitClass("player")
        local src = (className and BF.classColors and BF.classColors[className])
                 or (className and RAID_CLASS_COLORS and RAID_CLASS_COLORS[className])
        playerColorCache = src and { r = src.r, g = src.g, b = src.b }
                           or { r = 1, g = 1, b = 1 }
    end
    return playerNameCache, playerColorCache
end

-- `display` selects which display's icon settings to measure; defaults to
-- the party display. The icon lives OUTSIDE the bar frame, so its reserve
-- feeds the layout chain as well as the styling pass -- see PositionOnFrame.
function IC:GetCastBarIconMetrics(barH, display)
    local ic = self:GetCfg(display)
    if not ic or ic.ShowIcon == false then return 0, 0 end
    local size = barH * (ic.IconSizePct or 1)
    if size < 1 then size = 1 end
    local gap = ic.IconGap or 1
    return size, size + gap
end

-- `barH` is the bar height in UI units. It MUST be passed in (or fall
-- back to the profile) and must never be read off the frame.
--
-- 12.1: f:GetHeight() returns a SECRET number once the frame has been
-- parented into the unit-frame chain, and comparing a secret hard-errors
-- ("attempt to compare local 'barH' (a secret number value)"). The frame
-- is sized from the display's BarHeight in the first place, so the
-- profile is both the safe source and the authoritative one.
-- Style generation.
--
-- ApplyCastBarStyle is the expensive pass: it re-resolves the bar texture,
-- rebuilds the rounded border kit and its mask, re-applies the icon border
-- and does three ResolveFontPath + SetFont calls. NONE of that varies per
-- CAST -- only per SETTINGS change -- yet it ran on every cast start via
-- SetupCastFrame. (The same realisation already produced
-- IC:RestampCastBarLevel for the reposition path; cast start was never
-- given the same treatment.)
--
-- A frame records the generation it was last fully styled at, and anything
-- that can change what a full pass would produce bumps the counter:
-- IC:Refresh (reached by every options setter -- setAndRefresh,
-- setAndReposition and icColorSet all call it), IC:OnSettingChanged, and
-- IC:InvalidatePlayerIdentity (a custom class-color edit feeds the
-- target-name color, and that path deliberately does NOT call Refresh).
--
-- A counter rather than a boolean: Refresh currently wipes the frame pool,
-- so a stale-styled frame cannot come back today -- but a counter stays
-- correct if that ever stops being true.
IC._styleGen = 1

-- The two per-CAST pieces of the styling pass. Both are secret-boolean
-- alphas driven by _targets, which changes with every cast, plus the timer
-- binding's enabled state. All of it must run even when the settings-derived
-- pass is skipped. Kept in ONE place and called from ApplyCastBarStyle's
-- fast and full paths alike -- duplicating it is exactly the drift
-- ApplyCastBarStyle exists to stop.
function IC:ApplyCastBarPerCastState(f)
    local ic = self:GetCfg(f._display)
    if not ic then return end

    -- The timer binding's ENABLED state is per-cast, not per-settings.
    --
    -- ReleaseFrame disables it so the blanked text sticks while the frame
    -- sits in the pool. Re-enabling it used to happen in the settings pass
    -- below -- but the generation guard now SKIPS that pass on every reuse,
    -- so a pooled frame came back permanently disabled. SetDuration then
    -- wrote the opening value once and the timer never ticked again: frozen
    -- at its starting number. It has to be re-asserted here, on the path
    -- that runs for every cast.
    --
    -- Through SetBindingEnabled, not directly: the reposition path writes this
    -- state too now (it switches the binding off for a frame parked past a
    -- chain's cap and back on when the frame returns to view), and the two
    -- must share one cache or they will fight over it.
    SetBindingEnabled(f, ic.ShowTimer ~= false)

    -- Only meaningful in show-all mode -- with the default filter every
    -- visible cast is aimed at the player, so the tint would never fire
    -- anyway. Parked at 0 otherwise so a pooled frame can't carry a stale
    -- tint back in.
    if f._notAimedTint then
        -- The tint marks the casts NOT aimed at you, so it is only
        -- meaningful in "all" mode. In "aimed" every visible bar is aimed at
        -- you; in "notAimed" every visible bar is not, so tinting them all
        -- would just be a second bar color. Parked at 0 in both, which also
        -- stops a pooled frame carrying a stale tint back in.
        local wantTint = (ic.CastFilter == FILTER_ALL)
                         and ic.TintNotAimed ~= false
        if wantTint and f._targets ~= nil then
            f._notAimedTint:SetAlphaFromBoolean(f._targets, 0, 1)
        elseif wantTint and f._isPreviewFrame then
            -- Preview frames have no _targets, so the tint would never be
            -- visible and the color swatch would look inert. Show it so
            -- the user can actually see what they are picking.
            f._notAimedTint:SetAlpha(1)
        else
            f._notAimedTint:SetAlpha(0)
        end
    end

    -- Only mark the casts actually aimed at the player. `_targets`
    -- (PlayerIsSpellTarget) is a SECRET boolean: fed straight to the
    -- engine, never read. Preview frames have no _targets and stay visible.
    if f.targetText and ic.ShowTargetName then
        if f._targets ~= nil then
            f.targetText:SetAlphaFromBoolean(f._targets, 1, 0)
        else
            f.targetText:SetAlpha(1)
        end
    end
end

-- `force` skips the generation guard. The options preview passes it: that
-- path is cold (the panel is open), its frames are rebuilt when the display
-- type flips, and always doing the full pass there removes a whole class of
-- preview-goes-stale bug for no measurable cost.
function IC:ApplyCastBarStyle(f, barH, force)
    if not f or not f._isCastBar then return end
    local ic = self:GetCfg(f._display)
    if not ic then return end

    -- Already styled at the current generation FOR THIS DISPLAY: only the
    -- per-cast state needs re-applying. This is the cast-start fast path.
    --
    -- `_styleDisplay` is not optional. The frame pools are now keyed by
    -- display as well as by type (see framePools), so in the steady state a
    -- frame always comes back to the display it was styled for and this
    -- test passes. It stays as the guard of record: without it a frame that
    -- did cross displays would keep the generation match and skip the whole
    -- settings pass -- texture, border, icon geometry, fonts, the
    -- shown-states and the text anchor chain -- rendering the OTHER
    -- display's appearance.
    if not force and f._styleGen == IC._styleGen and f._styleDisplay == f._display then
        self:ApplyCastBarPerCastState(f)
        return
    end
    f._styleGen     = IC._styleGen
    f._styleDisplay = f._display
    -- The full pass below can build or rebuild the rounded border kit, whose
    -- host frame level is stamped from the bar's level AT STYLE TIME. The
    -- reposition path only re-stamps it when it changes the frame level
    -- itself, so tell it that this frame needs one regardless.
    --
    -- Load-bearing since IC:Refresh stopped wiping the pools: a frame can now
    -- be styled at one generation, pooled, re-styled at another by the
    -- pre-warm, and handed back out without its frame level ever moving.
    f._bf_needRestamp = true

    barH = barH or GetCastBarHeight(f._display)

    local bar = f.bar

    -- ---- Bar texture + opacity ----------------------------------
    local tex = ic.UseCustomTexture
                and BF:ResolveBarTexture(ic.Texture)
                or "Interface\\Buttons\\WHITE8X8"
    bar:SetStatusBarTexture(tex)

    -- Re-anchor the not-aimed tint: SetStatusBarTexture replaces the
    -- texture object, so a stale SetAllPoints target would leave the tint
    -- pinned to a dead region.
    if f._notAimedTint then
        f._notAimedTint:SetAllPoints(bar:GetStatusBarTexture())
        local nac = ic.NotAimedColor or { r = 0.35, g = 0.35, b = 0.4, a = 0.75 }
        f._notAimedTint:SetColorTexture(nac.r, nac.g, nac.b, (nac.a ~= nil) and nac.a or 0.75)
        -- Its ALPHA is per-cast and lives in ApplyCastBarPerCastState.
    end

    -- NOTE: opacity is NOT a plain SetAlpha on the frame. The frame's
    -- alpha is owned by the secret-value path -- PositionOnFrame drives
    -- it with SetAlphaFromBoolean(entry._targets, 1, 0) so that casts
    -- not aimed at this unit collapse invisibly. Setting alpha here
    -- would be overwritten on the next reposition. The user's opacity
    -- is instead folded into the "true" argument of that call (see
    -- IC:GetCastOpacity), and applied directly only on preview frames,
    -- which never go through the secret path.
    if f._isPreviewFrame then
        f:SetAlpha(ic.Opacity or 1)
    end

    -- ---- Border --------------------------------------------------
    local style      = ic.BorderStyle or "square"
    local rounded    = BF.IsRoundedBorderStyle and BF.IsRoundedBorderStyle(style)
    local wantBorder = ic.ShowBorder ~= false
    local bc         = ic.BorderColor or { r = 0, g = 0, b = 0, a = 0.8 }

    if BF.ApplyUFBarRoundBorder then
        local didRound = wantBorder and rounded and BF:ApplyUFBarRoundBorder(
            bar,
            -- The not-aimed tint must be masked too, or it renders as a
            -- square patch overhanging the rounded corners.
            { bar:GetStatusBarTexture(), f.bg, f._notAimedTint },
            -- The kit is built on `bar`, which is a child of `f` and so
            -- sits at f+1. Passing f's level would put the ring host BELOW
            -- the bar and the fill would cover it.
            bar:GetFrameLevel(),
            nil, nil,
            { mode = style, color = bc }
        )
        if not didRound and bar._bfRoundKit then
            bar._bfRoundKit.ring:Hide()
            bar._bfRoundKit.mask:Hide()
        end
    end

    local e = f._edges
    if e then
        if wantBorder and not rounded then
            local w = ic.BorderThickness or 1
            for _, t in pairs(e) do t:SetColorTexture(bc.r, bc.g, bc.b, (bc.a ~= nil) and bc.a or 0.8) end
            e.top:ClearAllPoints()
            e.top:SetPoint("TOPLEFT", f, "TOPLEFT", -w, w)
            e.top:SetPoint("TOPRIGHT", f, "TOPRIGHT", w, w)
            e.top:SetHeight(w)
            e.bottom:ClearAllPoints()
            e.bottom:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", -w, -w)
            e.bottom:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", w, -w)
            e.bottom:SetHeight(w)
            e.left:ClearAllPoints()
            e.left:SetPoint("TOPLEFT", f, "TOPLEFT", -w, w)
            e.left:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", -w, -w)
            e.left:SetWidth(w)
            e.right:ClearAllPoints()
            e.right:SetPoint("TOPRIGHT", f, "TOPRIGHT", w, w)
            e.right:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", w, -w)
            e.right:SetWidth(w)
            for _, t in pairs(e) do t:Show() end
        else
            for _, t in pairs(e) do t:Hide() end
        end
    end

    -- ---- Icon ----------------------------------------------------
    local iconFrame = f._iconFrame
    if iconFrame then
        local showIcon = ic.ShowIcon ~= false
        if showIcon then
            local iconSize, reserve = self:GetCastBarIconMetrics(barH, f._display)
            local gap = reserve - iconSize
            local xo  = ic.IconXOffset or 0
            local yo  = ic.IconYOffset or 0
            iconFrame:SetSize(iconSize, iconSize)
            iconFrame:ClearAllPoints()
            if ic.IconSide == "RIGHT" then
                iconFrame:SetPoint("LEFT", bar, "RIGHT", gap + xo, yo)
            else
                iconFrame:SetPoint("RIGHT", bar, "LEFT", -gap + xo, yo)
            end
            -- The icon takes the same border style and color as the bar,
            -- via the shared kit in PixelPerfect.lua.
            if BF.ApplyIconBorder then
                BF:ApplyIconBorder(iconFrame, f.icon, style, bc,
                                   ic.BorderThickness, wantBorder)
            end
            iconFrame:Show()
        else
            iconFrame:Hide()
        end
    end

    -- ---- Text ----------------------------------------------------
    -- Two independent colors: the name color drives the spell name and
    -- the (non class-colored) target name, the time color drives the
    -- timer. Fall back to the legacy single incomingCastsTextColor so old
    -- profiles keep their color until they touch either new setting.
    -- incomingCastsTextColor is the one read here that is NOT per-display:
    -- it is a read-only legacy fallback for profiles predating the split
    -- name/time colors, and the UI has not written it for a long time. It
    -- therefore comes off the raw profile, not the resolved config.
    local prof     = BF.icDB and BF.icDB.profile
    local legacyTc = (prof and prof.incomingCastsTextColor) or { r = 1, g = 1, b = 1, a = 1 }
    local nameC = ic.NameColor or legacyTc
    local timeC = ic.TimeColor or legacyTc
    if f.text then
        f.text:SetFont(BF:ResolveFontPath(ic.NameFont),
                       ic.NameFontSize or 10,
                       ic.NameFontBorder or "")
        f.text:SetJustifyH(ic.NameAlign or "LEFT")
        f.text:SetTextColor(nameC.r, nameC.g, nameC.b, nameC.a or 1)
        f.text:SetShown(ic.ShowSpellName ~= false)
    end
    -- Target name. Uses the NAME font so it reads as part of the same
    -- label, but takes the player's class color by default.
    if f.targetText then
        local show = ic.ShowTargetName and true or false
        if show then
            local pname, pcolor = GetPlayerIdentity()
            -- Both halves are plain strings -- the spell name comes from
            -- C_Spell.GetSpellName and the player's own name is the one
            -- unit name that is never secret -- so this concatenation is
            -- safe. It would NOT be for any other unit.
            local prefix = (ic.ShowSpellName ~= false) and "> " or ""
            f.targetText:SetText(prefix .. pname)
            f.targetText:SetFont(BF:ResolveFontPath(ic.NameFont),
                                 ic.NameFontSize or 10,
                                 ic.NameFontBorder or "")
            if ic.TargetNameClassColor ~= false and pcolor then
                f.targetText:SetTextColor(pcolor.r, pcolor.g, pcolor.b, 1)
            else
                f.targetText:SetTextColor(nameC.r, nameC.g, nameC.b, nameC.a or 1)
            end
            f.targetText:Show()
            -- Its ALPHA is per-cast and lives in ApplyCastBarPerCastState.
        else
            f.targetText:Hide()
        end
    end

    if f.timerText then
        local tFont  = BF:ResolveFontPath(ic.BarTimerFont)
        local tSize  = ic.BarTimerFontSize or 10
        local tFlags = ic.BarTimerFontBorder or ""
        f.timerText:SetFont(tFont, tSize, tFlags)
        f.timerText:SetJustifyH(ic.TimerAlign or "RIGHT")
        -- Pin the width so the spell name's right edge cannot move when the
        -- timer gains its decimal. See GetTimerReserve.
        local reserve = GetTimerReserve(tFont, tSize, tFlags)
        if reserve then f.timerText:SetWidth(reserve) end
        f.timerText:SetTextColor(timeC.r, timeC.g, timeC.b, timeC.a or 1)
        -- Also set here, not just in SetupCastFrame: preview frames never
        -- go through SetupCastFrame, so without this the preview showed a
        -- timer with the option off.
        -- Shown-state here; the binding's ENABLED state is per-cast and
        -- lives in ApplyCastBarPerCastState (preview frames have no binding
        -- and keep writing their literal sample text with SetText).
        f.timerText:SetShown(ic.ShowTimer ~= false)
    end

    -- ---- Text chain --------------------------------------------------
    -- Left to right: spell name | target name | timer.
    --
    -- Each right-hand element is sized to its own text; the spell name
    -- takes whatever is left, so a long spell name truncates rather than
    -- pushing the player's name off the end of the bar. Anchored here
    -- rather than in SetupCastFrame so the options preview -- which never
    -- reaches SetupCastFrame -- lays out identically.
    local rightOf = nil
    if f.timerText and ic.ShowTimer ~= false then
        rightOf = f.timerText
    end
    if f.targetText and ic.ShowTargetName then
        f.targetText:ClearAllPoints()
        if rightOf then
            f.targetText:SetPoint("RIGHT", rightOf, "LEFT", -3, 0)
        else
            f.targetText:SetPoint("RIGHT", f.bar, "RIGHT", -2, 0)
        end
        rightOf = f.targetText
    end
    if f.text then
        f.text:ClearAllPoints()
        f.text:SetPoint("LEFT", f.bar, "LEFT", 2, 0)
        if rightOf then
            f.text:SetPoint("RIGHT", rightOf, "LEFT", -2, 0)
        else
            f.text:SetPoint("RIGHT", f.bar, "RIGHT", -2, 0)
        end
    end

    self:ApplyCastBarPerCastState(f)
end

-- Settings-derived styling for an ICON display frame, generation-guarded
-- exactly like ApplyCastBarStyle.
--
-- Until now the icon type had no fast path at all: SetupCastFrame re-ran the
-- font resolve (an LSM lookup), SetFont, SetScale and the shown-state on
-- EVERY acquire, for every display -- paying per cast what the cast bar only
-- pays per settings change. Same guard, same fields (`_styleGen`,
-- `_styleDisplay`), so the pre-warm's restyle sweep covers icons too.
--
-- Per-cast state -- texture, duration, the binding's enabled state -- stays
-- in SetupCastFrame. `force` is for the options preview, as above.
function IC:ApplyIconStyle(f, force)
    if not f or f._isCastBar then return end
    local ic = self:GetCfg(f._display)
    if not ic then return end
    if not force and f._styleGen == IC._styleGen and f._styleDisplay == f._display then
        return
    end
    f._styleGen     = IC._styleGen
    f._styleDisplay = f._display

    local showTimer = ic.ShowTimer
    if showTimer == nil then showTimer = true end
    if f.timerText then
        f.timerText:SetShown(showTimer)
        local fp = BF:ResolveFontPath(ic.IconTimerFont)
        local fb = ic.IconTimerFontBorder or "OUTLINE"
        local fs, sc
        if ic.IconAutoScale then
            local iconSize   = ic.IconSize or 20
            local timerScale = ic.IconTimerScale or 1.0
            fs = 11
            sc = iconSize / 12 * timerScale
        else
            fs = ic.IconTimerFontSize or 11
            sc = 1.0
        end
        f.timerText:SetFont(fp, fs, fb)
        f.timerText:SetScale(sc)
    end
    if f.cooldown then f.cooldown:SetHideCountdownNumbers(true) end
end

-- Cheap per-reposition fixup.
--
-- PositionOnFrame used to run the whole of ApplyCastBarStyle on every
-- frame on every reposition -- and a reposition happens on every cast
-- start, every cast end and every nameplate removal. That meant
-- re-resolving textures, rebuilding the rounded border kit and two
-- SetFont calls per frame per event (twice over with the player frame
-- on). Invisible with one or two bars; not with a dozen.
--
-- The only thing that genuinely must re-run after a reposition is the
-- rounded border kit's host level, because SetParent resets frame levels.
-- Everything else is settings-derived and is applied by ApplyCastBarStyle
-- when the frame is set up or when settings change.
-- `parentScale` is the effective scale of the frame we were just
-- reparented onto. It must be supplied by the caller, NOT read back off
-- the bar: once parented into the unit-frame chain GetEffectiveScale is a
-- secret number.
function IC:RestampCastBarLevel(f, k)
    if not f or not f._isCastBar then return end
    local bar = f.bar
    local kit = bar and bar._bfRoundKit
    if not (kit and kit.host) then return end

    kit.host:SetFrameLevel(bar:GetFrameLevel())
    -- v86 piece kit: the edge/cap host is a separate unscaled frame.
    if kit.edgeHost then kit.edgeHost:SetFrameLevel(bar:GetFrameLevel()) end

    -- The kit's pixel host was scaled by ApplyUFBarRoundBorder using the
    -- bar's effective scale AT STYLE TIME, while the frame was still on
    -- UIParent. Reparenting onto a unit frame can change that scale, which
    -- would put the ring off the pixel grid. Re-stamp from the parent's
    -- scale, which the caller can still read safely.
    -- `k` is now computed ONCE per chain by the caller and passed in --
    -- it derives purely from the loop-invariant parent scale and a cached
    -- global, so recomputing it per entry was pure repetition.
    if k and k > 0 then
        if kit.host._bf_k ~= k then
            kit.host:SetScale(k)
            kit.host._bf_k = k
        end
    end
end

-- User opacity, folded into the "shown" arm of SetAlphaFromBoolean.
function IC:GetCastOpacity(display)
    local ic = self:GetCfg(display)
    local o = ic and ic.Opacity
    if o == nil then return 1 end
    if o < 0 then return 0 elseif o > 1 then return 1 end
    return o
end

local function CreateCastBarFrame()
    local f = CreateFrame("Frame", nil, UIParent)
    f:SetFrameStrata("MEDIUM")
    f:SetFrameLevel(100)

    local bar = BF.StatusBar(nil, f)
    bar:SetAllPoints(f)
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0)
    bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    f.bar = bar

    local bg = BF.Texture(bar, nil, "BACKGROUND")
    bg:SetAllPoints(bar)
    f.bg = bg

    -- "Not aimed at you" tint. Laid over the fill and alpha'd from the
    -- SECRET PlayerIsSpellTarget boolean -- INVERTED, so it shows on the
    -- casts that are NOT coming at you. An overlay rather than a color
    -- swap because picking between two bar colors would mean reading the
    -- boolean, which is forbidden; this way the engine does the choosing.
    -- Anchored to the fill texture so it tracks it for free.
    local naTint = BF.Texture(bar, nil, "ARTWORK", nil, 2)
    naTint:SetAllPoints(bar:GetStatusBarTexture())
    naTint:SetAlpha(0)
    f._notAimedTint = naTint

    -- Spell icon (outside the bar; side/size/gap/offsets are styled by
    -- IC:ApplyCastBarStyle).
    local iconFrame = CreateFrame("Frame", nil, f)
    f._iconFrame = iconFrame
    local icon = BF.Texture(iconFrame, nil, "ARTWORK")
    icon:SetAllPoints(iconFrame)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    f.icon = icon

    -- Icon border is built and styled on demand by BF:ApplyIconBorder
    -- (PixelPerfect.lua) so it follows the bar's border style and color.
    -- Previously four hardcoded 1px black edge textures.

    -- Spell name text
    local text = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("LEFT", bar, "LEFT", 2, 0)
    text:SetJustifyH("LEFT")
    text:SetWordWrap(false)
    f.text = text

    -- Target name ("> YourName"). Sits between the spell name and the
    -- timer; anchored and shown by IC:ApplyCastBarStyle.
    local targetText = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    targetText:SetJustifyH("LEFT")
    targetText:SetWordWrap(false)
    targetText:Hide()
    f.targetText = targetText

    -- Timer text
    local timerText = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    timerText:SetPoint("RIGHT", bar, "RIGHT", -2, 0)
    timerText:SetJustifyH("RIGHT")
    f.timerText = timerText

    text:SetPoint("RIGHT", timerText, "LEFT", -2, 0)

    -- Bar border: four edge textures, replacing the single solid
    -- backdrop this used to draw. The old version baked its thickness
    -- into a -1/+1 anchor pair and had no style concept, so it could not
    -- express the border options. Styled by IC:ApplyCastBarStyle.
    f._edges = {
        top    = MakeEdge(f),
        bottom = MakeEdge(f),
        left   = MakeEdge(f),
        right  = MakeEdge(f),
    }
    for _, t in pairs(f._edges) do t:Hide() end

    f._isCastBar = true
    AttachTimerBinding(f)
    f:Hide()
    return f
end

local function CreateIconDisplayFrame()
    local f = CreateFrame("Frame", nil, UIParent)
    f:SetFrameStrata("MEDIUM")
    f:SetFrameLevel(100)

    local icon = BF.Texture(f, nil, "ARTWORK")
    icon:SetAllPoints(f)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    f.icon = icon

    local cd = CreateFrame("Cooldown", nil, f, "CooldownFrameTemplate")
    cd:SetAllPoints(f)
    cd:SetDrawEdge(false)
    cd:SetDrawBling(false)
    cd:SetHideCountdownNumbers(false)
    cd:SetReverse(true)
    f.cooldown = cd

    -- Timer text (centered inside the icon)
    local timerText = f:CreateFontString(nil, "OVERLAY")
    timerText:SetDrawLayer("OVERLAY", 7)
    timerText:SetPoint("CENTER", f, "CENTER", 0, 0)
    timerText:SetJustifyH("CENTER")
    f.timerText = timerText

    -- Border
    local border = BF.Texture(f, nil, "OVERLAY")
    border:SetPoint("TOPLEFT", f, -1, 1)
    border:SetPoint("BOTTOMRIGHT", f, 1, -1)
    border:SetColorTexture(0, 0, 0, 0.8)
    border:SetDrawLayer("BACKGROUND", -1)

    f._isCastBar = false
    AttachTimerBinding(f)
    f:Hide()
    return f
end

-- `wantCB` and `display` are both required: the caller always knows which
-- display it is building for, and a typed, per-display pool must not guess.
-- Stamps `_display` so the styling guards see the acquiring display.
local function AcquireFrame(wantCB, display)
    local pools = wantCB and framePools.castbar or framePools.icon
    local f = table_remove(pools[display] or pools[DISPLAY_PARTY])
    if not f then
        f = wantCB and CreateCastBarFrame() or CreateIconDisplayFrame()
    end
    f._display = display
    return f
end

local function ReleaseFrame(f)
    f:Hide()
    SetFrameParent(f, UIParent)
    f:ClearAllPoints()
    if f.bar then f.bar:SetValue(0) end
    if f.cooldown then f.cooldown:Clear() end
    f._duration = nil
    -- The binding owns timerText while enabled, so release it before
    -- blanking the text. SetupCastFrame re-enables per display type.
    SetBindingEnabled(f, false)
    -- Drop the secret targeting boolean. Every path that re-styles a
    -- pooled frame currently re-assigns it first, so this is belt and
    -- braces -- but a stale one would silently mis-mark the target name
    -- and the not-aimed tint, which is a hard failure to spot.
    f._targets = nil
    -- PositionOnFrame's size cache. Other paths call SetSize directly, so the
    -- cache is only trustworthy while the frame is in use by one chain --
    -- clear it here and the next reposition re-sizes once, unconditionally.
    f._bf_w, f._bf_h = nil, nil
    -- PositionOnFrame's other change guards. The Hide, the SetParent and the
    -- ClearAllPoints above have just invalidated every one of them, and a
    -- pooled frame handed to a different chain must re-assert the lot.
    f._bf_shown, f._bf_level, f._bf_needRestamp, f._bf_k = nil, nil, nil, nil
    f._bf_ap, f._bf_ar, f._bf_at, f._bf_ax, f._bf_ay = nil, nil, nil, nil, nil
    -- The filter stamps (see ApplyFilterAlphaGuarded): the next owner of this
    -- frame has a different secret, so it must re-apply once.
    f._bf_afFilter, f._bf_afOpacity = nil, nil
    if f.timerText then f.timerText:SetText("") end
    -- Back to the pool of the display it is styled for -- never the other one.
    local pools = f._isCastBar and framePools.castbar or framePools.icon
    table_insert(pools[f._display] or pools[DISPLAY_PARTY], f)
end

-- ============================================================
-- POSITIONING
--
-- Each entry gets a hidden "layout bar" (StatusBar) that forms
-- the anchor chain. The layout bar's value is driven by the
-- secret boolean from PlayerIsSpellTarget via SetValueFromBoolean:
--   targeting player -> value 1 -> fill texture has full size
--   not targeting    -> value 0 -> fill texture has zero size
-- Each layout bar anchors to the previous bar's fill texture,
-- so invisible entries collapse to zero size in the chain and
-- don't take up space. The visible cast frame is parented on
-- top of its layout bar's fill texture.
-- ============================================================

local GROW = {
    DOWN  = { x = 0, y = -1 },
    UP    = { x = 0, y =  1 },
    LEFT  = { x = -1, y = 0 },
    RIGHT = { x =  1, y = 0 },
}

local ANCH = {
    TOP         = { point = "BOTTOMLEFT",  relPoint = "TOPLEFT" },
    BOTTOM      = { point = "TOPLEFT",     relPoint = "BOTTOMLEFT" },
    LEFT        = { point = "TOPRIGHT",    relPoint = "LEFT" },
    RIGHT       = { point = "TOPLEFT",     relPoint = "RIGHT" },
    TOPLEFT     = { point = "TOPRIGHT",    relPoint = "TOPLEFT" },
    TOPRIGHT    = { point = "TOPLEFT",     relPoint = "TOPRIGHT" },
    BOTTOMLEFT  = { point = "BOTTOMRIGHT", relPoint = "BOTTOMLEFT" },
    BOTTOMRIGHT = { point = "BOTTOMLEFT",  relPoint = "BOTTOMRIGHT" },
}

-- Grow direction -> StatusBar orientation + anchor points for chaining
local GROW_LAYOUT = {
    DOWN  = { orientation = "VERTICAL",   reverse = false, origin = "TOP",   rel = "BOTTOM" },
    UP    = { orientation = "VERTICAL",   reverse = true,  origin = "BOTTOM", rel = "TOP" },
    LEFT  = { orientation = "HORIZONTAL", reverse = true,  origin = "RIGHT", rel = "LEFT" },
    RIGHT = { orientation = "HORIZONTAL", reverse = false, origin = "LEFT",  rel = "RIGHT" },
}

local function CreateLayoutBar()
    local bar = BF.StatusBar(nil, UIParent)
    bar:SetMinMaxValues(0, 1)
    bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    bar:SetStatusBarColor(0, 0, 0, 0)
    return bar
end

local function EnsureLayoutBar(entry)
    if entry._layoutBar then return entry._layoutBar end
    local bar = table_remove(layoutBarPool) or CreateLayoutBar()
    bar:SetValue(1)
    entry._layoutBar = bar
    return bar
end

-- The physical return-to-pool for ONE layout bar.
--
-- Four call sites used to inline this dance for the DETACHED display's bar
-- (only the party display's went through ReleaseLayoutBar), and the change
-- guards PositionOnFrame now keeps gave every one of them a fifth thing to
-- remember. One place instead: a site that forgot the guard reset would
-- strand a recycled bar believing it was still anchored and shown.
local function PoolLayoutBar(bar)
    if not bar then return end
    bar:Hide()
    bar:ClearAllPoints()
    SetFrameParent(bar, UIParent)
    bar:SetValue(0)
    bar._bf_shown = nil
    bar._bf_ap, bar._bf_ar, bar._bf_at, bar._bf_ax, bar._bf_ay = nil, nil, nil, nil, nil
    -- The filter stamp (ApplyFilterLayoutValueGuarded): the next entry to
    -- own this bar has a different secret, so it must re-apply once.
    bar._bf_lvFilter = nil
    table_insert(layoutBarPool, bar)
end

local function ReleaseLayoutBar(entry)
    local bar = entry._layoutBar
    if not bar then return end
    PoolLayoutBar(bar)
    entry._layoutBar = nil
end

-- Park a cast frame without releasing it: the cast is still live and the
-- frame reappears if an earlier one finishes. Keeps PositionOnFrame's shown
-- guard honest, and switches the timer binding off -- the engine keeps
-- re-rendering a DurationTextBinding's font string whether or not the frame
-- is visible, and in the default filter most parked frames are ones the
-- player could never have seen anyway.
local function HideCastFrame(f)
    if not f then return end
    if f._bf_shown ~= false then
        f:Hide()
        f._bf_shown = false
    end
    SetBindingEnabled(f, false)
end

local function HideLayoutBar(bar)
    if not bar then return end
    if bar._bf_shown ~= false then
        bar:Hide()
        bar._bf_shown = false
    end
end

-- `display` picks which display's settings this chain uses -- its cast
-- filter, opacity and icon geometry. `maxBars` caps THIS chain only; the
-- entry list is shared between the two displays, so trimming it would cap
-- both.
--
-- IC-dot function (not a file local) so Profiler.lua can wrap it; every
-- call site goes through IC. so the wrap actually intercepts. Same for
-- RepositionPlayerCasts, ReleaseCastsForUnit and ProcessCast below.
--
-- `snap` is the display's resolved layout snapshot (see
-- ResolveDisplaySnapshot below RepositionPlayerCasts's registry): every
-- settings-derived input this function used to re-derive per call — cfg
-- reads, opacity clamp, grow-layout lookup, icon metrics — arrives
-- pre-resolved. The snapshot is rebuilt only when settings or the party
-- grow direction actually change.
function IC.PositionOnFrame(parentFrame, entries, snap)
    if not parentFrame or #entries == 0 then return end

    local filter    = snap.filter
    local opacity   = snap.opacity
    local showTimer = snap.showTimer
    local m         = snap.m
    local sp        = snap.sp
    local ox, oy    = snap.ox, snap.oy
    local fw, fh    = snap.fw, snap.fh
    local maxBars   = snap.maxBars

    local gl = snap.gl
    local isHorizontal = (gl.orientation == "HORIZONTAL")

    -- isCB stays FRAME-derived, not snapshot-derived: it gates per-frame
    -- work (pixel restamp, icon offsets) and must describe the frames
    -- actually in the chain. The two can only disagree in the window
    -- between a display-type settings change and IC:Refresh's
    -- ReleaseAllCasts, which tears the old frames down.
    --
    -- iconReserve/iconOverhang (see the snapshot resolver for what they
    -- mean) are settings-derived and ride in the snapshot.
    local isCB = entries[1] and entries[1].frame and entries[1].frame._isCastBar
    local iconReserve, iconOverhang = 0, 0
    if isCB then
        iconReserve  = snap.iconReserve
        iconOverhang = snap.iconOverhang
    end

    -- Loop-invariant: parentFrame is the same for every entry in the chain,
    -- so its scale is resolved once instead of per entry. Readable here
    -- because it is the frame we anchor TO, not a reparented child of it.
    local parentScale, pixelK
    if isCB and parentFrame.GetEffectiveScale then
        parentScale = parentFrame:GetEffectiveScale()
        if issecretvalue(parentScale) then parentScale = nil end
        if parentScale and parentScale > 0 then
            pixelK = BF:GetPixelSize() / parentScale
        end
    end

    local prevBarTex = nil
    for i = 1, #entries do
        local entry = entries[i]
        local cf = entry.frame
        if not cf then break end

        -- Past this chain's cap: park EVERY remaining entry and stop.
        --
        -- This used to hide the first over-cap entry and break, which was safe
        -- only because a frame fresh out of the pool starts hidden -- a
        -- property of ReleaseFrame, not of this loop. The two displays share
        -- one entry list and can be capped differently, and ProcessCast now
        -- bounds that list at the LARGER of the two caps, so the shorter chain
        -- routinely sees several over-cap entries at once and every one of
        -- them has to be parked.
        --
        -- Hidden, not released: the cast is still live and reappears if an
        -- earlier one finishes.
        if maxBars and i > maxBars then
            for j = i, #entries do
                local over = entries[j]
                if over then
                    HideCastFrame(over.frame)
                    HideLayoutBar(over._layoutBar)
                end
            end
            break
        end

        local layoutBar = EnsureLayoutBar(entry)
        -- Size includes spacing so the chain gap is built into the bar.
        -- iconReserve, not just fw: the icon lives outside the bar frame, so
        -- a horizontal chain stepping by fw alone would run each bar over its
        -- neighbor's icon.
        --
        -- All four of these are identical for every entry in the chain and
        -- unchanged between repositions unless a setting moved, so they are
        -- change-guarded -- same idiom as SetFrameParent. SetOrientation in
        -- particular re-lays-out the fill texture, and the fill texture is
        -- what the next layout bar and the cast frame anchor to, so a
        -- redundant call cascades rect invalidation down the whole chain.
        local lw, lh
        if isHorizontal then
            lw, lh = fw + iconReserve + sp, fh
        else
            lw, lh = fw, fh + sp
        end
        if layoutBar._bf_w ~= lw or layoutBar._bf_h ~= lh then
            layoutBar:SetSize(lw, lh)
            layoutBar._bf_w, layoutBar._bf_h = lw, lh
        end
        -- Strata only needs re-asserting when we actually reparent: nothing
        -- else touches it while the bar is chained.
        if SetFrameParent(layoutBar, parentFrame) then
            layoutBar:SetFrameStrata("HIGH")
            -- A reparent can strand a point that referenced the OLD parent,
            -- so the anchor guard below must not trust its cache.
            layoutBar._bf_ap = nil
        end
        if layoutBar._bf_orient ~= gl.orientation then
            layoutBar:SetOrientation(gl.orientation)
            layoutBar._bf_orient = gl.orientation
        end
        if layoutBar._bf_reverse ~= gl.reverse then
            layoutBar:SetReverseFill(gl.reverse)
            layoutBar._bf_reverse = gl.reverse
        end

        -- Anchor, change-guarded.
        --
        -- ClearAllPoints + SetPoint ran unconditionally for every entry, and
        -- this chain is a SERIAL dependency -- each layout bar anchors to the
        -- PREVIOUS bar's fill texture -- so re-pointing all N in order made
        -- the engine re-resolve the tail of the chain once per entry. With a
        -- reposition landing on nearly every render frame during a pull, that
        -- was the most expensive thing this function did.
        --
        -- Five field compares rather than one composite key: building a key
        -- would allocate a string per entry per frame, which is exactly the
        -- cost this is here to remove.
        local ap, ar, at, ax, ay
        if prevBarTex == nil then
            -- Compensate for the cast icon that extends left of the bar frame.
            -- When the bar's left edge is the anchor, shift right so the icon's
            -- left edge sits at the anchor point instead.
            local adjX = ox
            if isCB then
                local pt = m.point
                if pt == "TOPLEFT" or pt == "BOTTOMLEFT" or pt == "LEFT" then
                    adjX = adjX + iconOverhang
                end
            end
            ap, ar, at, ax, ay = m.point, m.relPoint, parentFrame, adjX, oy
        else
            ap, ar, at, ax, ay = gl.origin, gl.rel, prevBarTex, 0, 0
        end
        if layoutBar._bf_ap ~= ap or layoutBar._bf_ar ~= ar
            or layoutBar._bf_at ~= at
            or layoutBar._bf_ax ~= ax or layoutBar._bf_ay ~= ay
        then
            layoutBar:ClearAllPoints()
            layoutBar:SetPoint(ap, at, ar, ax, ay)
            layoutBar._bf_ap, layoutBar._bf_ar, layoutBar._bf_at = ap, ar, at
            layoutBar._bf_ax, layoutBar._bf_ay = ax, ay
        end

        -- Drive the layout bar fill from the display's filter. A filtered-out
        -- entry gets value 0 -> its fill texture has zero size -> the next bar
        -- chains onto it with no gap, so invisible entries take no space.
        --
        -- Change-guarded on the FILTER, not the value: the value is derived
        -- from the SECRET targeting boolean and comparing a secret is the one
        -- thing that is forbidden, but the secret is fixed for the life of
        -- this entry's bar -- see ApplyFilterLayoutValueGuarded.
        ApplyFilterLayoutValueGuarded(layoutBar, filter, entry._targets)
        if layoutBar._bf_shown ~= true then
            layoutBar:Show()
            layoutBar._bf_shown = true
        end

        -- Position cast frame on top of the layout bar's fill texture
        local tex = layoutBar:GetStatusBarTexture()
        if cf._bf_w ~= fw or cf._bf_h ~= fh then
            cf:SetSize(fw, fh)
            cf._bf_w, cf._bf_h = fw, fh
        end
        if SetFrameParent(cf, parentFrame) then
            cf:SetFrameStrata("HIGH")
            -- SetParent RESETS frame levels and can strand a cross-parent
            -- point, so neither guard below may trust its cache.
            cf._bf_level = nil
            cf._bf_ap    = nil
        end
        -- Arithmetic on the parent's level, so if it could ever come back
        -- SECRET the pre-existing `+ 10` would already have thrown; comparing
        -- it adds no new exposure.
        local lvl = layoutBar:GetFrameLevel() + 10
        if cf._bf_level ~= lvl then
            cf:SetFrameLevel(lvl)
            cf._bf_level = lvl
            -- The rounded border kit's host has to follow the bar's level, so
            -- the re-stamp below is only owed when this actually fired.
            cf._bf_needRestamp = true
        end
        -- Point and relative point are both gl.origin here and the offsets are
        -- always 0, so two compares cover the whole anchor.
        if cf._bf_ap ~= gl.origin or cf._bf_at ~= tex then
            cf:ClearAllPoints()
            cf:SetPoint(gl.origin, tex, gl.origin)
            cf._bf_ap, cf._bf_at = gl.origin, tex
        end
        -- AFTER SetParent/SetFrameLevel: SetParent resets frame levels, so
        -- the rounded border kit's host has to be re-stamped. Deliberately
        -- NOT a full ApplyCastBarStyle -- see IC:RestampCastBarLevel.
        --
        -- Only when the level moved or the pixel scale changed, though. The
        -- unguarded version cost two SetFrameLevel calls per cast bar per
        -- reposition to re-assert a level that had not moved since the last
        -- one.
        if isCB and (cf._bf_needRestamp or cf._bf_k ~= pixelK) then
            cf._bf_needRestamp = nil
            cf._bf_k = pixelK
            IC:RestampCastBarLevel(cf, pixelK)
        end

        -- Visibility. This call OWNS the frame's alpha -- a plain SetAlpha
        -- elsewhere would be overwritten here on the next reposition -- so
        -- the user's opacity rides in it. `entry._targets` is a SECRET
        -- boolean, only ever handed to the engine, never inspected. Guarded
        -- on (filter, opacity), for the same reason as the layout value above.
        ApplyFilterAlphaGuarded(cf, filter, entry._targets, opacity)
        if cf._bf_shown ~= true then
            cf:Show()
            cf._bf_shown = true
        end
        -- A frame parked past this chain's cap had its timer binding switched
        -- off; coming back into view has to switch it on again. Guarded
        -- inside SetBindingEnabled, so the steady state costs one compare.
        SetBindingEnabled(cf, showTimer)

        prevBarTex = tex
    end
end

-- Hard ceiling on live entries in the DEFAULT (targeted-only) mode, where
-- the user's incomingCastsMaxBars cannot be applied. See the note at the
-- trim loop below. Not exposed in the options by design.
local DEFAULT_MODE_ENTRY_CAP = 20

-- ============================================================
-- ACTIVE CAST REGISTRY
--
-- `activeCasts` maps a nameplate token to its entry; `activeOrder` holds the
-- SAME entries oldest-first. Both are maintained together by AddActiveCast /
-- RemoveActiveCast, which are the ONLY places either is mutated -- keeping
-- them in step anywhere else would be a standing desync bug.
--
-- The order array replaces a pairs() walk plus a table_sort on every
-- reposition. `startTime` is GetTime(), which is monotonic, so a new cast can
-- only ever belong at the tail: appending IS sorting. Removal is a linear
-- scan, but N is a handful of live casts and it runs once per cast END rather
-- than once per reposition.
--
-- Entry TABLES are pooled. Recycling happens ONLY at a terminal point -- after
-- the frames are released and the entry is out of BOTH activeCasts and
-- holdingCasts. A lingering entry still owns its frame, so recycling one early
-- is a use-after-free.
local activeOrder = {}
local entryPool   = {}

local function AcquireEntry()
    local e = table_remove(entryPool)
    if e then return e end
    return {}
end

local function RecycleEntry(entry)
    if not entry then return end
    table_wipe(entry)
    entryPool[#entryPool + 1] = entry
end

local function AddActiveCast(unit, entry)
    activeCasts[unit] = entry
    activeOrder[#activeOrder + 1] = entry
end

local function RemoveActiveCast(unit)
    local entry = activeCasts[unit]
    if not entry then return nil end
    activeCasts[unit] = nil
    for i = 1, #activeOrder do
        if activeOrder[i] == entry then
            table_remove(activeOrder, i)
            break
        end
    end
    return entry
end

-- Scratch tables reused across repositions.
--
-- RepositionPlayerCasts runs on every cast start, every cast end and every
-- nameplate removal, and used to allocate a fresh entries table, a fresh
-- sort comparator CLOSURE and -- with the player frame on -- a `saved`
-- table plus one sub-table PER ENTRY, every single time. That is a lot of
-- garbage on the combat path for tables whose contents never outlive the
-- call.
--
-- Safe to share because this function is not re-entrant: it is only ever
-- called from the three event entry points, nothing it calls re-enters it,
-- and Lua is single-threaded here.
--
-- savedFrames / savedLayoutBars are PARALLEL arrays rather than one array
-- of {frame=, layoutBar=} pairs, and are walked with numeric loops rather
-- than ipairs: a layout bar is legitimately nil, which would truncate an
-- ipairs walk at the first hole.
local savedFrames       = {}
local savedLayoutBars   = {}

-- A chain's bar cap. Only "all" mode can honor the user's number, because
-- only there is every entry visible -- see the note in RepositionPlayerCasts.
local function ResolveMaxBars(cfg)
    if cfg.CastFilter == FILTER_ALL then
        return cfg.MaxBars or 5
    end
    return DEFAULT_MODE_ENTRY_CAP
end

-- ============================================================
-- DISPLAY LAYOUT SNAPSHOTS
--
-- Every reposition used to re-derive the same ~15 settings-scalar inputs:
-- anchor/grow tables, spacing, offsets, bar size, caps, filter, opacity,
-- timer toggle and the cast-bar icon metrics. None of them depend on the
-- live casts — they are pure functions of the cfg flats plus the party
-- grow direction — so they are resolved ONCE into two pooled tables and
-- reused until either input moves. Validity is two compares per
-- reposition: snapValid (cleared by InvalidateCfg / InvalidatePartyDir,
-- i.e. every settings, profile and zone path) and the party direction
-- value itself (which the TTL memo can legitimately change under us).
--
-- iconReserve -- total extra width the cast-bar icon occupies outside the
--                bar frame; counts toward the step between entries.
-- iconOverhang - how far the icon sticks out past the bar's LEFT edge;
--                only non-zero for a left-side icon, used to shift the
--                first entry so the icon starts at the anchor point.
-- ============================================================
local snapCache = {
    [DISPLAY_PARTY]  = {},
    [DISPLAY_PLAYER] = {},
}

-- The detached display's anchor never varies; hoisted so the snapshot
-- rebuild allocates nothing (this table used to be built per reposition).
local PLAYER_ANCHOR_M = { point = "TOPLEFT", relPoint = "TOPLEFT" }

local function ResolveDisplaySnapshot(display, partyDir)
    local s   = snapCache[display]
    local cfg = IC:GetCfg(display)
    local isCB = (cfg.DisplayType or "castbar") == "castbar"
    s.isCB      = isCB
    s.fw        = isCB and (cfg.BarWidth  or 80) or (cfg.IconSize or 20)
    s.fh        = isCB and (cfg.BarHeight or 12) or (cfg.IconSize or 20)
    s.maxBars   = ResolveMaxBars(cfg)
    s.filter    = cfg.CastFilter
    s.opacity   = IC:GetCastOpacity(display)
    s.showTimer = cfg.ShowTimer ~= false

    local growDir
    if display == DISPLAY_PARTY then
        growDir = GetGrowDirection(partyDir)
        s.m  = ANCH[GetAnchorPoint(partyDir)] or ANCH["BOTTOM"]
        s.sp = GetSpacing()
        s.ox, s.oy = GetOffsetX(), GetOffsetY()
    else
        growDir = GetPlayerGrowDirection()
        s.m  = PLAYER_ANCHOR_M
        s.sp = GetPlayerSpacing()
        s.ox, s.oy = 0, 0
    end
    -- growDir arrives RESOLVED: GetGrowDirection and GetPlayerGrowDirection
    -- both map "AUTO" to a concrete direction. The fallback still catches
    -- anything unrecognized.
    s.gl = GROW_LAYOUT[growDir] or GROW_LAYOUT["DOWN"]

    s.iconReserve, s.iconOverhang = 0, 0
    if isCB then
        local _, reserve = IC:GetCastBarIconMetrics(s.fh, display)
        s.iconReserve = reserve
        if cfg.IconSide ~= "RIGHT" then
            s.iconOverhang = reserve
        end
    end
end

local function GetDisplaySnapshots()
    local partyDir = GetPartyGrowDir()
    if not snapValid or partyDir ~= snapPartyDir then
        ResolveDisplaySnapshot(DISPLAY_PARTY,  partyDir)
        ResolveDisplaySnapshot(DISPLAY_PLAYER, partyDir)
        snapPartyDir = partyDir
        snapValid    = true
    end
    return snapCache[DISPLAY_PARTY], snapCache[DISPLAY_PLAYER]
end

-- ============================================================
-- PARTY PLAYER-FRAME MEMO
--
-- The frame the party chain anchors to only changes on roster, profile
-- and layout events, so the bucket walk is memoized. SELF-VALIDATING
-- rather than event-invalidated: the cached frame is trusted only while
-- it is still IN the "player" bucket with unit == "player", so a frame
-- that was retired or re-pointed under us can never be returned stale --
-- no invalidation hook to forget.
-- ============================================================
local partyFrameCache = nil

local function GetPartyPlayerFrame()
    local bucket = BF.frames_of_unit and rawget(BF.frames_of_unit, "player")
    if not bucket then partyFrameCache = nil; return nil end
    local f = partyFrameCache
    if f and bucket[f] and f.unit == "player" then return f end
    partyFrameCache = nil
    for frame in next, bucket do
        if frame.unit == "player" then partyFrameCache = frame; break end
    end
    return partyFrameCache
end

function IC.RepositionPlayerCasts()
    -- Oldest-first by construction (see the registry above): no gather, no
    -- sort, and no scratch copy that could fall out of step.
    --
    -- Tested FIRST. The frame memo and the settings reads cost nothing
    -- useful when there is nothing to lay out, and this function is called
    -- from three event paths.
    local entries = activeOrder
    if #entries == 0 then return end

    local ic = GetSettings()
    local showOnPlayer = ic and ic.incomingCastsShowOnPlayerFrame
    local showOnParty  = ic and ic.incomingCastsShowOnPartyFrame
    if showOnParty == nil then showOnParty = true end

    local partySnap, playerSnap = GetDisplaySnapshots()

    local partyFrame = showOnParty and GetPartyPlayerFrame() or nil

    local showPlayerIC = showOnPlayer and IsEnabled()

    -- The entry list is SHARED by the two displays, so it is no longer
    -- trimmed here -- each chain caps itself in PositionOnFrame. ResolveMaxBars
    -- says what that cap is:
    --
    --   "all" mode      -- every entry is visible, so the user's MaxBars means
    --                      exactly what it says.
    --   "aimed" mode    -- the filtered-out entries collapse to nothing, and
    --   "notAimed" mode   there is NO way to tell which is which: `_targets` is
    --                      the secret PlayerIsSpellTarget boolean and reading it
    --                      is the one thing that is forbidden. Capping the list
    --                      would drop bars the user can see while keeping bars
    --                      they cannot, so these get DEFAULT_MODE_ENTRY_CAP --
    --                      a hard backstop set high enough that it can only bite
    --                      on a pull already big enough to hurt.
    --
    -- That backstop is deliberately NOT a user setting. It is not a display
    -- preference, it is the ceiling on how many frames this feature may render
    -- at once, and exposing it would invite raising it back into the
    -- pathological case it exists to prevent. Frames past a cap are HIDDEN, not
    -- released: the cast is still live and reappears if an earlier one finishes.
    if partyFrame then
        local isCB = partySnap.isCB
        local fw, fh = partySnap.fw, partySnap.fh

        -- Build a frame for every entry this chain can actually DRAW, and no
        -- more. ProcessCast used to build one for EVERY caster, uncapped; see
        -- the note there. Same shape as the detached display's loop below,
        -- which has always been lazy.
        --
        -- Lazy rather than refused: an entry that starts out of range keeps
        -- its slot, so when an earlier cast finishes it shifts up and is built
        -- here, on that reposition. That is what stops the chain sitting below
        -- its own cap for the rest of a pull.
        local partyMax = partySnap.maxBars
        for i = 1, #entries do
            if i > partyMax then break end
            local entry = entries[i]
            if not entry.frame then
                -- Typed, per-display pool: it cannot hand back the wrong kind
                -- of frame, nor one styled for the other display.
                local cf = AcquireFrame(isCB, DISPLAY_PARTY)
                entry.frame = cf
                -- Size BEFORE styling. ApplyUFBarRoundBorder reads the bar's
                -- width and height for its tiny-bar nine-slice cap and
                -- change-guards the result, so styling a 0x0 frame latches the
                -- wrong scale for that frame's life. PositionOnFrame sizes it
                -- again later, but by then the guard has set.
                cf:SetSize(fw, fh)
                -- Stash the secret boolean BEFORE styling: SetupCastFrame uses
                -- it to alpha the target-name text.
                cf._targets = entry._targets
                SetupCastFrame(cf, entry._texture, entry._spellName, entry._duration,
                               entry._isChannel, entry._notInterruptible)
                -- Secret-safe visibility via SetAlphaFromBoolean. User opacity
                -- rides in the "shown" arm -- see the note in PositionOnFrame.
                -- Through the guarded wrapper so PositionOnFrame, a moment
                -- later, sees the stamp and does not apply it a second time.
                ApplyFilterAlphaGuarded(cf, partySnap.filter, entry._targets,
                                        partySnap.opacity)
            end
        end

        IC.PositionOnFrame(partyFrame, entries, partySnap)
    else
        for _, entry in ipairs(entries) do
            HideCastFrame(entry.frame)
            HideLayoutBar(entry._layoutBar)
        end
    end

    if showPlayerIC then
        local anchor = EnsurePlayerAnchor()

        -- This chain's OWN snapshot: the two displays choose independently,
        -- so one can be a cast bar while the other is an icon.
        local isCB = playerSnap.isCB
        local fw, fh = playerSnap.fw, playerSnap.fh

        -- Ensure each entry this chain can actually DRAW has its own frame.
        -- The party loop above is now the same shape; this one always was,
        -- bar the cap.
        --
        -- The cap is what keeps PositionOnFrame's `if not cf then break end`
        -- safe on both chains. Entries are appended at the tail and only ever
        -- shift DOWN in index as older ones finish, so the entries holding a
        -- frame are always a PREFIX of the list -- the loop can never break
        -- out early and leave a live frame further along unparked.
        local playerMax = playerSnap.maxBars
        for i = 1, #entries do
            if i > playerMax then break end
            local entry = entries[i]
            if not entry._playerFrame then
                -- Typed, per-display pool: it cannot hand back the wrong kind
                -- of frame, nor one styled for the other display.
                local cf = AcquireFrame(isCB, DISPLAY_PLAYER)
                entry._playerFrame = cf
                -- Size before styling -- see the note in ProcessCast.
                cf:SetSize(fw, fh)
                -- Populate ONCE, on creation. The cast's spell, duration
                -- and target boolean are fixed for its lifetime, so
                -- re-running SetupCastFrame (and with it a full
                -- ApplyCastBarStyle) on every reposition was pure waste --
                -- and repositions fire on every cast start, cast end and
                -- nameplate removal.
                cf._targets = entry._targets
                SetupCastFrame(cf, entry._texture, entry._spellName, entry._duration,
                               entry._isChannel, entry._notInterruptible)
                ApplyFilterAlphaGuarded(cf, playerSnap.filter, entry._targets,
                                        playerSnap.opacity)
            end
        end

        -- Swap frames/layout bars for PositionOnFrame. Numeric loops, not
        -- ipairs: savedLayoutBars can legitimately hold nil.
        local count = #entries
        for i = 1, count do
            local entry = entries[i]
            savedFrames[i]     = entry.frame
            savedLayoutBars[i] = entry._layoutBar
            entry.frame        = entry._playerFrame
            entry._layoutBar   = entry._playerLayoutBar
        end

        IC.PositionOnFrame(anchor, entries, playerSnap)

        for i = 1, count do
            local entry = entries[i]
            entry._playerLayoutBar = entry._layoutBar
            entry.frame            = savedFrames[i]
            entry._layoutBar       = savedLayoutBars[i]
            -- Drop the references so a shorter later reposition cannot
            -- leave this table holding a released frame alive.
            savedFrames[i]     = nil
            savedLayoutBars[i] = nil
        end
    end
end

-- Repositions are COALESCED to one per frame.
--
-- RepositionPlayerCasts rebuilds the entire anchor chain, and it was called
-- synchronously from three event paths. Events arrive in bursts: 15 enemies
-- starting to cast means cast #1 repositions 1 entry, #2 repositions 2 ... #15
-- repositions 15 -- and an AoE wipe lands 15 STOPs in one or two frames and
-- does it again. That is O(N^2) frame work compressed into a couple of render
-- frames, which is exactly what a pull-start hitch looks like.
--
-- FlushReposition is a hoisted function, not a closure built per call, so the
-- only allocation is C_Timer's own ticker -- once per burst instead of once
-- per event. A reposition landing a frame late is imperceptible; the bars are
-- already alpha-driven by the engine.
local repositionPending = false

local function FlushReposition()
    repositionPending = false
    -- Via IC. so a profiler wrap on RepositionPlayerCasts sees this call.
    IC.RepositionPlayerCasts()
end

local function QueueReposition()
    if repositionPending then return end
    repositionPending = true
    C_Timer.After(0, FlushReposition)
end

-- ============================================================
-- DETACHED PLAYER ANCHOR (mover frame for player IC display)
--
-- Mirrors the UF test frame pattern from SetupModeUnlockMode.lua:
-- invisible 1×1 anchor at saved TOPLEFT position, visible drag
-- handle shown when frames are unlocked.
-- ============================================================

-- Which corner of the cast-bar STACK sits on the player anchor point.
--
-- PositionOnFrame lays the player chain out with m = { point = "TOPLEFT" }
-- against a 1x1 anchor, then chains each subsequent entry off the previous
-- one in the grow direction. So the anchor point is always the stack's
-- leading corner, and which corner that is depends on which way it grows:
--
--   DOWN  -> TOPLEFT      (default; stack extends down + right)
--   UP    -> BOTTOMLEFT   (stack extends up)
--   RIGHT -> TOPLEFT      (stack extends right)
--   LEFT  -> TOPRIGHT     (stack extends left)
--
-- Shared by the Unlock-mode drag handle and the Setup Mode overlay so the
-- two cannot disagree about where the casts actually appear -- they did,
-- because the overlay was centered on the point while the handle sat on its
-- top-left.
function IC:GetPlayerStackOrigin()
    local dir = GetPlayerGrowDirection()
    if dir == "UP" then return "BOTTOMLEFT" end
    if dir == "LEFT" then return "TOPRIGHT" end
    return "TOPLEFT"
end

EnsurePlayerAnchor = function()
    if IC._playerAnchor then return IC._playerAnchor end

    local anchor = CreateFrame("Frame", "BuzzardFrames_ICPlayerAnchor", UIParent)
    anchor:SetSize(1, 1)
    anchor:SetFrameStrata("MEDIUM")
    anchor:SetFrameLevel(109)
    anchor:SetMovable(true)
    anchor:SetClampedToScreen(true)
    anchor:EnableMouse(false)
    anchor:SetPoint("CENTER", UIParent, "CENTER", GetPlayerAnchorX(), GetPlayerAnchorY())

    -- Visual drag handle: same style as _BuildDragHandle (blue bar above anchor)
    local handle = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    handle:SetFrameStrata("MEDIUM")
    handle:SetFrameLevel(110)
    handle:SetBackdrop({
        bgFile   = "Interface\\Buttons\\White8x8",
        edgeFile = "Interface\\Buttons\\White8x8",
        edgeSize = 1,
    })
    handle:SetBackdropColor(0.1, 0.3, 0.6, 0.8)
    handle:SetBackdropBorderColor(0.2, 0.5, 0.9, 1)
    handle:EnableMouse(true)
    handle:SetMovable(false)
    handle:RegisterForDrag("LeftButton")
    handle:Hide()

    local label = handle:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("CENTER")
    label:SetText("Incoming Casts")
    label:SetTextColor(1, 1, 1)
    handle._label = label

    -- Snap handle above anchor (matches _BuildDragHandle pattern)
    local function SnapHandleToAnchor()
        handle:ClearAllPoints()
        if BF.db and BF.db.global and BF.db.global.tinyHandle then
            handle:SetSize(5, 5)
            handle:SetPoint("BOTTOMLEFT", anchor, "TOPLEFT", 0, 2)
            if handle._label then handle._label:Hide() end
        else
            -- Size to represent 3 stacked incoming casts
            -- The drag handle sizes the DETACHED display's stack.
            local isCB = GetDisplayType(DISPLAY_PLAYER) == "castbar"
            local fw = isCB and GetCastBarWidth(DISPLAY_PLAYER) or GetIconSize(DISPLAY_PLAYER)
            local fh = isCB and GetCastBarHeight(DISPLAY_PLAYER) or GetIconSize(DISPLAY_PLAYER)
            -- Same reserve the real layout uses; was hardcoded fh + 1, so
            -- the drag handle mis-sized for any non-default icon size or
            -- gap, and stayed too wide with the icon turned off.
            local totalItemW = fw
            if isCB then
                local _, reserve = IC:GetCastBarIconMetrics(fh, DISPLAY_PLAYER)
                totalItemW = totalItemW + reserve
            end
            local sp = GetPlayerSpacing()
            local growDir = GetPlayerGrowDirection()
            local count = 3
            local handleW, handleH
            if growDir == "LEFT" or growDir == "RIGHT" then
                handleW = totalItemW * count + sp * (count - 1)
                handleH = fh
            else
                handleW = totalItemW
                handleH = fh * count + sp * (count - 1)
            end
            handle:SetSize(math.max(handleW, 40), 14)
            -- Sit just above the TOP edge of the stack, on the same side
            -- the stack grows from. For an UP-growing stack the anchor is
            -- the BOTTOM of it, so lift the handle clear by the stack's
            -- height.
            local origin = IC:GetPlayerStackOrigin()
            local liftY = (origin == "BOTTOMLEFT") and (handleH + 2) or 2
            if origin == "TOPRIGHT" then
                handle:SetPoint("BOTTOMRIGHT", anchor, "TOPRIGHT", 0, liftY)
            else
                handle:SetPoint("BOTTOMLEFT", anchor, "TOPLEFT", 0, liftY)
            end
            if handle._label then handle._label:Show() end
        end
    end
    anchor.SnapHandle = SnapHandleToAnchor

    handle:SetScript("OnDragStart", function()
        anchor:StartMoving()
        anchor:SetScript("OnUpdate", SnapHandleToAnchor)
    end)
    handle:SetScript("OnDragStop", function()
        anchor:StopMovingOrSizing()
        anchor:SetScript("OnUpdate", nil)
        SnapHandleToAnchor()
        -- Save position (CENTER-relative)
        local cx, cy = anchor:GetCenter()
        local ux, uy = UIParent:GetCenter()
        if cx and ux then
            local nx = math.floor(cx - ux + 0.5)
            local ny = math.floor(cy - uy + 0.5)
            anchor:ClearAllPoints()
            anchor:SetPoint("CENTER", UIParent, "CENTER", nx, ny)
            local ic = BF.icDB and BF.icDB.profile
            if ic then
                ic.incomingCastsPlayerAnchorX = nx
                ic.incomingCastsPlayerAnchorY = ny
            end
            BF:RefreshPanel("incomingCasts")
        end
    end)

    anchor._handle = handle
    IC._playerAnchor = anchor
    return anchor
end

function IC:UpdatePlayerAnchorPosition()
    local anchor = self._playerAnchor
    if not anchor then return end
    anchor:ClearAllPoints()
    anchor:SetPoint("CENTER", UIParent, "CENTER", GetPlayerAnchorX(), GetPlayerAnchorY())
    if anchor.SnapHandle then anchor.SnapHandle() end
end

function IC:ShowPlayerMover()
    local anchor = EnsurePlayerAnchor()
    if anchor._handle then
        anchor:EnableMouse(true)
        anchor._handle:Show()
        if anchor.SnapHandle then anchor.SnapHandle() end
    end
end

function IC:HidePlayerMover()
    local anchor = self._playerAnchor
    if not anchor then return end
    anchor:EnableMouse(false)
    if anchor._handle then anchor._handle:Hide() end
end

-- ============================================================
-- PARTY FRAME PREVIEW (dummy cast bars/icons on preview frame)
-- ============================================================

local PREVIEW_SPELL_ICONS = {
    136197,  -- Shadow Bolt
    136231,  -- Polymorph
    136175,  -- Chain Lightning
}

local function CreatePreviewCastBar(parentFrame)
    local f = CreateFrame("Frame", nil, parentFrame)
    f:SetFrameStrata("DIALOG")
    f:SetFrameLevel(130)

    local bar = BF.StatusBar(nil, f)
    bar:SetAllPoints(f)
    bar:SetMinMaxValues(0, 1)
    bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    f.bar = bar

    local bg = BF.Texture(bar, nil, "BACKGROUND")
    bg:SetAllPoints(bar)
    f.bg = bg

    -- "Not aimed at you" tint. Laid over the fill and alpha'd from the
    -- SECRET PlayerIsSpellTarget boolean -- INVERTED, so it shows on the
    -- casts that are NOT coming at you. An overlay rather than a color
    -- swap because picking between two bar colors would mean reading the
    -- boolean, which is forbidden; this way the engine does the choosing.
    -- Anchored to the fill texture so it tracks it for free.
    local naTint = BF.Texture(bar, nil, "ARTWORK", nil, 2)
    naTint:SetAllPoints(bar:GetStatusBarTexture())
    naTint:SetAlpha(0)
    f._notAimedTint = naTint

    -- Icon (outside the bar; side/size/gap/offsets styled by
    -- IC:ApplyCastBarStyle, same as the live frames)
    local iconFrame = CreateFrame("Frame", nil, f)
    f._iconFrame = iconFrame
    local icon = BF.Texture(iconFrame, nil, "ARTWORK")
    icon:SetAllPoints(iconFrame)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    f.icon = icon

    -- Icon border: same shared kit as the live frames, applied by
    -- IC:ApplyCastBarStyle. (This path used to build its own four edge
    -- textures with a private MakeEdge local.)

    -- Spell name
    local text = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("LEFT", bar, "LEFT", 2, 0)
    text:SetJustifyH("LEFT")
    text:SetWordWrap(false)
    f.text = text

    -- Target name (see the live constructor)
    local targetText = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    targetText:SetJustifyH("LEFT")
    targetText:SetWordWrap(false)
    targetText:Hide()
    f.targetText = targetText

    -- Timer
    local timerText = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    timerText:SetPoint("RIGHT", bar, "RIGHT", -2, 0)
    timerText:SetJustifyH("RIGHT")
    f.timerText = timerText
    text:SetPoint("RIGHT", timerText, "LEFT", -2, 0)

    -- Bar border. The preview used to have NO bar border at all while the
    -- live frames did -- exactly the kind of drift IC:ApplyCastBarStyle
    -- exists to prevent. Same four-edge kit as the live frames.
    f._edges = {
        top    = MakeEdge(f),
        bottom = MakeEdge(f),
        left   = MakeEdge(f),
        right  = MakeEdge(f),
    }
    for _, t in pairs(f._edges) do t:Hide() end

    f._isCastBar = true
    -- Preview frames never go through the secret-boolean visibility path,
    -- so ApplyCastBarStyle can set their alpha directly.
    f._isPreviewFrame = true
    return f
end

local function CreatePreviewIcon(parentFrame)
    local f = CreateFrame("Frame", nil, parentFrame)
    f:SetFrameStrata("DIALOG")
    f:SetFrameLevel(130)

    local icon = BF.Texture(f, nil, "ARTWORK")
    icon:SetAllPoints(f)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    f.icon = icon

    local function MakeEdge(par)
        local t = BF.Texture(par, nil, "OVERLAY", nil, 1)
        t:SetColorTexture(0, 0, 0, 1)
        return t
    end
    local e
    e = MakeEdge(f); e:SetPoint("TOPLEFT", f, -1, 1); e:SetPoint("TOPRIGHT", f, 1, 1); e:SetHeight(1)
    e = MakeEdge(f); e:SetPoint("BOTTOMLEFT", f, -1, -1); e:SetPoint("BOTTOMRIGHT", f, 1, -1); e:SetHeight(1)
    e = MakeEdge(f); e:SetPoint("TOPLEFT", f, -1, 1); e:SetPoint("BOTTOMLEFT", f, -1, -1); e:SetWidth(1)
    e = MakeEdge(f); e:SetPoint("TOPRIGHT", f, 1, 1); e:SetPoint("BOTTOMRIGHT", f, 1, -1); e:SetWidth(1)

    f._isCastBar = false
    return f
end

local function ShowPartyPreviewOnFrame(pf, previewFrames, isCB, fw, fh, castBarColor, castBarBgColor)
    local ufp = BF.ufDB and BF.ufDB.profile
    local icp = BF.icDB and BF.icDB.profile
    local pcfg = IC:GetCfg(DISPLAY_PARTY)
    castBarColor   = castBarColor   or pcfg.BarColor or { r = 0.3, g = 0.3, b = 0.9 }
    castBarBgColor = castBarBgColor or (ufp and ufp.castBarBgColor) or { r = 0.15, g = 0.15, b = 0.15 }

    for i = 1, 3 do
        local frame = previewFrames[i]
        if not frame or frame._isCastBar ~= isCB then
            if frame then frame:Hide() end
            if isCB then
                frame = CreatePreviewCastBar(pf)
            else
                frame = CreatePreviewIcon(pf)
            end
            previewFrames[i] = frame
        end

        frame:SetSize(fw, fh)
        -- Icon geometry, border, fonts and text color all come from the
        -- shared styling pass -- the same one the live frames use.
        if isCB then IC:ApplyCastBarStyle(frame, fh, true) end

        local iconTex = PREVIEW_SPELL_ICONS[i]
        if frame.icon then frame.icon:SetTexture(iconTex) end
        if frame.bar then
            frame.bar:SetValue(0.3 + i * 0.2)
            frame.bar:SetStatusBarColor(castBarColor.r, castBarColor.g, castBarColor.b, castBarColor.a or 1)
        end
        if frame.bg then
            local icp = BF.icDB and BF.icDB.profile
            local bgA = (pcfg.BgOpacity ~= nil) and pcfg.BgOpacity
                        or castBarBgColor.a or 0.8
            frame.bg:SetColorTexture(castBarBgColor.r, castBarBgColor.g, castBarBgColor.b, bgA)
        end
        if frame.text then frame.text:SetText("Spell " .. i) end
        if frame.timerText then frame.timerText:SetText(string.format("%.1f", 1.0 + i * 0.5)) end
    end

    local anchorPt = GetAnchorPoint()
    local growDir  = GetGrowDirection()
    local m = ANCH[anchorPt] or ANCH["BOTTOM"]
    local g = GROW[growDir] or GROW["DOWN"]
    local sp = GetSpacing()
    local ox, oy = GetOffsetX(), GetOffsetY()

    -- Mirrors the live chain in PositionOnFrame: the reserve only shifts
    -- the anchor when the icon is on the LEFT, but it always widens the
    -- per-entry step.
    local totalW = fw
    local iconOverhang = 0
    if isCB then
        local icp = BF.icDB and BF.icDB.profile
        local _, reserve = IC:GetCastBarIconMetrics(fh, DISPLAY_PARTY)
        totalW = fw + reserve
        if pcfg.IconSide ~= "RIGHT" then
            iconOverhang = reserve
        end
    end

    for i, frame in ipairs(previewFrames) do
        frame:ClearAllPoints()
        if i == 1 then
            local adjX = ox
            if isCB then
                local pt = m.point
                if pt == "TOPLEFT" or pt == "BOTTOMLEFT" or pt == "LEFT" then
                    adjX = adjX + iconOverhang
                end
            end
            frame:SetPoint(m.point, pf, m.relPoint, adjX, oy)
        else
            local prev = previewFrames[i - 1]
            local stepX = g.x * (totalW + sp)
            local stepY = g.y * (fh + sp)
            frame:SetPoint(m.point, prev, m.point, stepX, stepY)
        end
        frame:Show()
    end
end

function IC:ShowPartyPreview()
    if not self._partyPreviewFramesByFlat then
        self._partyPreviewFramesByFlat = {}
    end

    -- The party preview previews the PARTY display.
    local isCB = GetDisplayType(DISPLAY_PARTY) == "castbar"
    local fw = isCB and GetCastBarWidth(DISPLAY_PARTY) or GetIconSize(DISPLAY_PARTY)
    local fh = isCB and GetCastBarHeight(DISPLAY_PARTY) or GetIconSize(DISPLAY_PARTY)
    local ufp = BF.ufDB and BF.ufDB.profile
    local icp = BF.icDB and BF.icDB.profile
    local castBarColor   = IC:GetCfg(DISPLAY_PARTY).BarColor or { r = 0.3, g = 0.3, b = 0.9 }
    local castBarBgColor = ufp and ufp.castBarBgColor or { r = 0.15, g = 0.15, b = 0.15 }

    local fl = BF.rpDB and BF.rpDB.profile and BF.rpDB.profile.layouts
               and BF.rpDB.profile.layouts.flatLayouts or {}

    local shown = false
    if BF._preview and BF._preview.ComputeActivePreviewSet then
        local order = BF._preview.ComputeActivePreviewSet()
        for _, flatID in ipairs(order) do
            local flat = fl[flatID]
            if flat and flat.type == "party" then
                local pf = BF._previewFrames and BF._previewFrames[flatID]
                if pf then
                    if not self._partyPreviewFramesByFlat[flatID] then
                        self._partyPreviewFramesByFlat[flatID] = {}
                    end
                    ShowPartyPreviewOnFrame(pf, self._partyPreviewFramesByFlat[flatID],
                        isCB, fw, fh, castBarColor, castBarBgColor)
                    shown = true
                end
            end
        end
    end

    -- Hide preview frames for any flat no longer in the active set
    for flatID, frames in pairs(self._partyPreviewFramesByFlat) do
        local pf = BF._previewFrames and BF._previewFrames[flatID]
        if not pf or not pf:IsShown() then
            for _, frame in ipairs(frames) do frame:Hide() end
        end
    end

    self._partyPreviewShown = shown
end

function IC:HidePartyPreview()
    if self._partyPreviewFramesByFlat then
        for _, frames in pairs(self._partyPreviewFramesByFlat) do
            for _, frame in ipairs(frames) do
                frame:Hide()
            end
        end
    end
    self._partyPreviewShown = false
end

-- ============================================================
-- CAST FRAME SETUP
-- ============================================================

-- `texture` and `name` are resolved ONCE per cast in ProcessCast and carried
-- on the entry, rather than looked up again here for each display. (`spellId`
-- and `npUnit` used to be parameters: spellId only ever fed these two lookups,
-- and npUnit was never read at all.)
-- Cast-bar fill colors as ColorMixin objects, per display.
--
-- SetupCastFrame built two of these with CreateColor on EVERY cast (a table
-- plus a mixin copy each) purely to hand them to EvaluateColorFromBoolean.
-- Both derive from settings only, so they are rebuilt when their source
-- r/g/b actually move -- a value compare rather than the style generation,
-- because the uninterruptible color lives in ufDB and a Unit Frames color
-- edit does not bump _styleGen.
local DEFAULT_BAR_COLOR = { r = 1, g = 0.84, b = 0 }
local DEFAULT_NI_COLOR  = { r = 0.565, g = 0.557, b = 0.545 }
local castColorCache = { [DISPLAY_PARTY] = {}, [DISPLAY_PLAYER] = {} }

local function GetCastColorObjects(display, cc, nic)
    local c = castColorCache[display] or castColorCache[DISPLAY_PARTY]
    if not c.nc or c.r ~= cc.r or c.g ~= cc.g or c.b ~= cc.b then
        c.nc = CreateColor(cc.r, cc.g, cc.b, 1)
        c.r, c.g, c.b = cc.r, cc.g, cc.b
    end
    if not c.ni or c.nr ~= nic.r or c.ng ~= nic.g or c.nb ~= nic.b then
        c.ni = CreateColor(nic.r, nic.g, nic.b, 1)
        c.nr, c.ng, c.nb = nic.r, nic.g, nic.b
    end
    return c.nc, c.ni
end

SetupCastFrame = function(cf, texture, name, duration, isChannel, notInterruptible)

    if cf._isCastBar then
        if texture then cf.icon:SetTexture(texture) end
        if name then cf.text:SetText(name) end
        cf._isChannel = isChannel
        cf._duration = duration

        local ic = IC:GetCfg(cf._display)
        -- Cast bar fill color is now an IncomingCasts option
        -- (incomingCastsBarColor), independent of the Unit Frames cast bars.
        -- The uninterruptible tint still reads UF's color (no IC option for
        -- it); background color handling is unchanged below.
        local ufp = BF.ufDB and BF.ufDB.profile
        local cc  = (ic and ic.BarColor) or DEFAULT_BAR_COLOR
        local nic = ufp and ufp.castBarUninterruptibleColor or DEFAULT_NI_COLOR

        -- Background COLOR is shared with the Unit Frames cast bars
        -- (ufDB.castBarBgColor); only its opacity is an IncomingCasts
        -- option, so the two bars stay visually consistent by default.
        local bgA = (ic and ic.BgOpacity ~= nil) and ic.BgOpacity or 0.6
        local bgc = ufp and ufp.castBarBgColor
        if bgc then
            cf.bg:SetColorTexture(bgc.r, bgc.g, bgc.b, bgA)
        else
            cf.bg:SetColorTexture(0, 0, 0, bgA)
        end

        -- Fonts, colors, border, icon geometry: one shared pass, also
        -- used by the options preview so the two cannot drift.
        IC:ApplyCastBarStyle(cf)

        -- Fill color AFTER the style pass, never before: ApplyCastBarStyle's
        -- full path calls SetStatusBarTexture, which installs a new texture
        -- object and drops the vertex color written to the old one -- so a
        -- color set earlier survived the fast path but was lost on the first
        -- cast after any settings change. CastBar.lua:408-413 orders it this
        -- way for the same reason.
        if notInterruptible ~= nil then
            local nc, ni = GetCastColorObjects(cf._display, cc, nic)
            if issecretvalue(notInterruptible) then
                -- Secret: the engine picks. This allocates the evaluated
                -- color, unavoidably.
                local r, g, b, a = C_CurveUtil.EvaluateColorFromBoolean(notInterruptible, ni, nc):GetRGBA()
                cf.bar:SetStatusBarColor(r, g, b, a)
            else
                -- Plain boolean: pick in Lua and allocate nothing.
                local col = notInterruptible and ni or nc
                cf.bar:SetStatusBarColor(col.r, col.g, col.b, 1)
            end
        else
            cf.bar:SetStatusBarColor(cc.r, cc.g, cc.b, 1)
        end

        -- Text visibility and the whole anchor chain live in
        -- IC:ApplyCastBarStyle (called just above), so the preview frames
        -- -- which never reach SetupCastFrame -- lay out identically.

        -- `~= nil`, not a truth-test: the duration object rides alongside the
        -- secret returns of the info calls, so a boolean coercion could throw.
        -- Same rule the party/raid cast bar states at CastBar.lua:814-816.
        if duration ~= nil then
            local dir = isChannel
                and Enum.StatusBarTimerDirection.RemainingTime
                or  Enum.StatusBarTimerDirection.ElapsedTime
            cf.bar:SetMinMaxValues(0, 1)
            cf.bar:SetTimerDuration(duration, nil, dir)
            -- Engine-driven text. ApplyCastBarStyle (called above) has
            -- already set the binding's enabled state from
            -- incomingCastsShowTimer, so only the duration is fed here.
            if cf._timeBinding then cf._timeBinding:SetDuration(duration) end
        end
    else
        if texture then cf.icon:SetTexture(texture) end
        cf._duration = duration
        if cf.cooldown and duration ~= nil then
            cf.cooldown:SetCooldownFromDurationObject(duration)
        end

        -- Fonts, scale, shown-state: generation-guarded, so a pooled frame
        -- already styled at this generation for this display skips the LSM
        -- lookup and SetFont entirely. This is the icon cast-start fast path.
        IC:ApplyIconStyle(cf)

        -- Per-cast: the binding's enabled state and the duration it counts.
        -- The icon path never reaches ApplyCastBarPerCastState, so it owns
        -- its own binding state. Don't leave the engine formatting into a
        -- hidden font string.
        if cf.timerText then
            local ic = IC:GetCfg(cf._display)
            local showTimer = ic and ic.ShowTimer
            if showTimer == nil then showTimer = true end
            SetBindingEnabled(cf, showTimer and true or false)
            if cf._timeBinding and duration ~= nil then
                cf._timeBinding:SetDuration(duration)
            end
        end
    end
end

-- ============================================================
-- UNIT FILTERING
-- ============================================================

-- Interned token set rather than string_sub(unit, 1, 9).
--
-- The nine registered events are GLOBAL, so they fire for every unit with a
-- token in range -- party members, their pets, target/focus/boss and every
-- nameplate. This is the most-executed line in the file, and for the majority
-- of dispatches (a party member's own cast) the prefix test IS the entire cost
-- before the bail. A pointer-keyed lookup on an already-interned string beats
-- building a 9-byte temporary and hashing it.
local NAMEPLATE_UNIT = {}
for i = 1, 40 do NAMEPLATE_UNIT["nameplate" .. i] = true end

local function IsRelevantCaster(unit)
    if not unit or not NAMEPLATE_UNIT[unit] then return false end
    if not UnitExists(unit) then return false end
    if not UnitCanAttack("player", unit) then return false end
    if UnitInParty(unit) then return false end
    -- Out-of-combat casters are NEVER tracked. Owner ruling 2026-08-14:
    -- "I never want out of combat mobs included."
    --
    -- This is UNCONDITIONAL. It used to apply only in "show all" mode, on
    -- the reasoning that the default mode is already gated on the cast
    -- targeting the player and that a mob can open on you fractionally
    -- before it registers as in combat -- so gating that path too risked
    -- dropping the first cast of a pull. That trade is accepted: the
    -- documented false-negatives are proximity-aggro and out-of-range or
    -- other-zone units, and a caster mob that has aggroed is flagged in
    -- combat before its cast starts.
    --
    -- It is also what makes the two displays' "show all" settings
    -- INDEPENDENT: the entry set is shared between them, so a filter that
    -- keyed off one display's mode could only ever apply when BOTH agreed.
    -- Keying off nothing removes that coupling entirely.
    --
    -- And it is a straight win on frame count: in the default mode an idle
    -- caster used to produce a full entry -- frame, layout bar, styling --
    -- that was then hidden at alpha 0 because it was not aimed at you.
    --
    -- UnitAffectingCombat is a true combat check and works on NPCs and
    -- enemy players alike. It does NOT say WHO the unit is fighting, so a
    -- mob engaged with an unrelated group still passes -- rare next to the
    -- idle-trash case this exists to kill.
    --
    -- Not UnitThreatSituation: that is threat-table membership, not combat.
    -- It returns nil unless the PLAYER personally acted on the mob (pet
    -- damage explicitly does not count), so a healer or a DPS working
    -- another pack would see nothing, and enemy players have no threat
    -- table at all.
    if not UnitAffectingCombat(unit) then return false end
    return true
end

local function IsTrackedNameplate(unit)
    return unit ~= nil and NAMEPLATE_UNIT[unit] == true
end

-- ============================================================
-- RELEASE
-- ============================================================

-- Hold-after-cast linger.
--
-- With incomingCastsHoldTime > 0 the frames stay on screen for a moment
-- after the cast ends, so a fast interrupt or a canceled cast is still
-- readable. The entry is removed from activeCasts immediately (so a new
-- cast from the same unit is never blocked) and only the FRAME release
-- is deferred, via a one-shot C_Timer rather than an OnUpdate countdown.
--
-- The timer is stored on the entry so ReleaseAllCasts and a UI reload can
-- cancel it -- releasing a frame twice would return it to the pool twice.
-- Entries whose frames are lingering. They are NO LONGER in activeCasts, so
-- ReleaseAllCasts would not see them, and a surviving hold timer would fire
-- against an entry teardown believes it has already finished with -- releasing
-- its frame a second time and pushing it into the pool twice. Tracked here so
-- teardown can reach them.
local holdingCasts = {}

local function TearDownEntryFrames(entry)
    -- nil when the party display is off, when the entry sits past that
    -- display's cap, and for the frame or so between ProcessCast and the
    -- reposition that builds it -- see the note in ProcessCast.
    if entry.frame then ReleaseFrame(entry.frame) end
    ReleaseLayoutBar(entry)
    if entry._playerFrame then
        ReleaseFrame(entry._playerFrame)
        entry._playerFrame = nil
    end
    if entry._playerLayoutBar then
        PoolLayoutBar(entry._playerLayoutBar)
        entry._playerLayoutBar = nil
    end
end

local function CancelHoldTimer(entry)
    if entry and entry._holdTimer then
        entry._holdTimer:Cancel()
        entry._holdTimer = nil
        holdingCasts[entry] = nil
    end
end

-- Cancel every pending linger and tear its frames down now.
local function FlushHoldingCasts()
    for entry in pairs(holdingCasts) do
        if entry._holdTimer then
            entry._holdTimer:Cancel()
            entry._holdTimer = nil
        end
        TearDownEntryFrames(entry)
        RecycleEntry(entry)
    end
    table_wipe(holdingCasts)
end

function IC.ReleaseCastsForUnit(castingUnit, skipHold)
    local entry = activeCasts[castingUnit]
    if not entry then return false end

    local ic = BF.icDB and BF.icDB.profile
    -- The linger applies to entry.frame, which is the PARTY display's bar
    -- (the detached duplicate is released outright below), so it takes the
    -- party display's hold time.
    -- Gated on entry.frame: the linger only ever applies to the PARTY
    -- display's bar (the detached duplicate has no independent anchor once
    -- its layout bar is returned, so it is released outright below). With the
    -- party display off there is nothing to linger, and entering the branch
    -- only to bail on the nil check below is wasted work.
    local hold = entry.frame and (IC:GetCfg(DISPLAY_PARTY).HoldTime or 0) or 0
    if hold > 0 and not skipHold and not entry._holdTimer then
        -- Free the slot now so a new cast from the same unit is never
        -- blocked; defer only the visual teardown.
        -- Detach from the live chain BEFORE lingering. Ending a cast
        -- triggers a reposition, which re-chains the surviving entries into
        -- the slot this one just vacated -- so a frame still anchored to
        -- its old layout bar would sit on top of a live bar for the whole
        -- hold. Freeze it where it currently is, on UIParent, and give its
        -- layout bar back so the chain closes up cleanly.
        --
        -- 12.1: GetLeft/GetBottom return SECRET numbers once the frame is
        -- parented into the unit-frame chain, and a secret cannot be
        -- compared or used in arithmetic. There is no safe way to read the
        -- position back, so when it is unreadable we skip the linger for
        -- this frame and tear it down now -- a missed linger is a far
        -- better outcome than an error or a bar frozen over a live one.
        local cf = entry.frame
        local l, b, scale
        if cf then
            l, b = cf:GetLeft(), cf:GetBottom()
            scale = cf:GetEffectiveScale()
            if issecretvalue and (issecretvalue(l) or issecretvalue(b) or issecretvalue(scale)) then
                l, b = nil, nil
            end
        end
        if not (cf and l and b and scale and scale > 0) then
            CancelHoldTimer(entry)
            RemoveActiveCast(castingUnit)
            TearDownEntryFrames(entry)
            RecycleEntry(entry)
            return true
        end

        -- Out of activeCasts but deliberately NOT recycled: the entry still
        -- owns the lingering frame until its hold timer fires.
        RemoveActiveCast(castingUnit)
        holdingCasts[entry] = true

        local uiScale = UIParent:GetEffectiveScale()
        SetFrameParent(cf, UIParent)
        cf:SetFrameStrata("HIGH")
        cf:ClearAllPoints()
        cf:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT",
                    l * scale / uiScale, b * scale / uiScale)
        -- Size from the profile, never from GetWidth/GetHeight (secret).
        -- Type-aware: an icon frame resized to bar dimensions renders as a
        -- stretched, squashed icon for the whole hold.
        if cf._isCastBar then
            cf:SetSize(GetCastBarWidth(DISPLAY_PARTY), GetCastBarHeight(DISPLAY_PARTY))
        else
            local s = GetIconSize(DISPLAY_PARTY)
            cf:SetSize(s, s)
        end
        -- The reparent, re-anchor and resize just above have invalidated every
        -- one of PositionOnFrame's change guards on this frame.
        --
        -- Harmless today: the entry is out of activeCasts and activeOrder, so
        -- no reposition can reach the frame, and its only exit is ReleaseFrame,
        -- which clears the lot. Cleared here regardless, because "safe only
        -- because nothing currently looks" is the exact trap PoolLayoutBar was
        -- extracted to close -- a future path that puts a lingering frame back
        -- into a chain would otherwise strand it at the wrong level, anchored
        -- to a layout bar that has already gone back to the pool.
        cf._bf_w, cf._bf_h = nil, nil
        cf._bf_level, cf._bf_needRestamp, cf._bf_k = nil, nil, nil
        cf._bf_ap, cf._bf_ar, cf._bf_at, cf._bf_ax, cf._bf_ay = nil, nil, nil, nil, nil
        cf._bf_afFilter, cf._bf_afOpacity = nil, nil

        ReleaseLayoutBar(entry)
        if entry._playerLayoutBar then
            PoolLayoutBar(entry._playerLayoutBar)
            entry._playerLayoutBar = nil
        end
        -- The duplicate player-frame has no independent anchor once its
        -- layout bar is gone; drop it now rather than lingering twice.
        if entry._playerFrame then
            ReleaseFrame(entry._playerFrame)
            entry._playerFrame = nil
        end

        entry._holdTimer = C_Timer.NewTimer(hold, function()
            entry._holdTimer = nil
            holdingCasts[entry] = nil
            TearDownEntryFrames(entry)
            RecycleEntry(entry)
        end)
        return true
    end

    CancelHoldTimer(entry)
    if entry.frame then ReleaseFrame(entry.frame) end
    ReleaseLayoutBar(entry)
    if entry._playerFrame then
        ReleaseFrame(entry._playerFrame)
        entry._playerFrame = nil
    end
    if entry._playerLayoutBar then
        PoolLayoutBar(entry._playerLayoutBar)
        entry._playerLayoutBar = nil
    end
    RemoveActiveCast(castingUnit)
    RecycleEntry(entry)
    return true
end

local function ReleaseAllCasts()
    -- Lingering entries first: they are not in activeCasts any more, so
    -- without this their hold timers outlive the teardown and return
    -- already-released frames to the pool a second time.
    FlushHoldingCasts()
    for _, entry in pairs(activeCasts) do
        CancelHoldTimer(entry)
        if entry.frame then ReleaseFrame(entry.frame) end
        ReleaseLayoutBar(entry)
        if entry._playerFrame then
            ReleaseFrame(entry._playerFrame)
        end
        if entry._playerLayoutBar then
            PoolLayoutBar(entry._playerLayoutBar)
            entry._playerLayoutBar = nil
        end
    end
    table_wipe(activeCasts)
    for i = #activeOrder, 1, -1 do
        RecycleEntry(activeOrder[i])
        activeOrder[i] = nil
    end
end

-- ============================================================
-- CORE: PROCESS A CAST TARGETING THE PLAYER
-- ============================================================

local DELAY = 0.1

function IC.ProcessCast(castingUnit, spellId, isChannel)
    if not IsEnabled() then return end
    if not IsInGroup() then return end

    -- Release previous cast from this caster
    IC.ReleaseCastsForUnit(castingUnit)

    -- Check if this cast targets the player
    local targets = PlayerIsSpellTarget(castingUnit)
    -- PlayerIsSpellTarget returns a secret boolean; use SetAlphaFromBoolean
    -- to show/hide the frame without inspecting the value.

    -- Duration and interruptibility belong to the ENTRY, not to either
    -- display, so read them before any frame work.
    local duration, notInterruptible
    if isChannel then
        duration = UnitChannelDuration(castingUnit)
        local _, _, _, _, _, _, ni = UnitChannelInfo(castingUnit)
        notInterruptible = ni
    else
        duration = UnitCastingDuration(castingUnit)
        local _, _, _, _, _, _, _, ni = UnitCastingInfo(castingUnit)
        notInterruptible = ni
    end

    -- Spell art, resolved once for the whole cast. Both displays render the
    -- same spell, so looking it up per frame was doing this twice. Stored on
    -- the entry rather than a module-level cache: C_Spell.GetSpellTexture
    -- follows the player's spec override chain, so a cache that outlived the
    -- cast could serve the wrong icon after a spec change.
    local texture   = spellId and C_Spell.GetSpellTexture(spellId)
    local spellName = spellId and C_Spell.GetSpellName(spellId)

    -- NEITHER display's frame is built here.
    --
    -- An ENTRY is a pooled table and a handful of field writes. A FRAME is an
    -- acquire, a full SetupCastFrame and a full ApplyCastBarStyle -- and, when
    -- the pool is dry, three CreateFrames, seven textures, three font strings,
    -- a duration binding and a border kit with two BLOCKING mask loads. Those
    -- two costs differ by orders of magnitude, so they must not be decided
    -- together.
    --
    -- This function used to build the party bar unconditionally, for every
    -- caster, with no cap of any kind -- the caps lived in PositionOnFrame and
    -- only governed what was DRAWN. On a pull with more casters than the cap
    -- (up to 40 nameplates are in range) every surplus caster bought a fully
    -- styled bar that the very next reposition hid. That is the bulk of what a
    -- pull-start hitch was made of.
    --
    -- Frames are now built lazily by RepositionPlayerCasts, per display,
    -- capped at that display's OWN ResolveMaxBars -- which is what the
    -- detached display already did. Capping construction rather than tracking
    -- is what keeps this correct: an entry that starts out of range still
    -- holds its slot, so when an earlier cast finishes it shifts up and gets
    -- its frame on that reposition. Refusing to TRACK the cast instead would
    -- have dropped it for good -- nothing re-scans -- and the display would
    -- then sit below its own cap for the rest of the pull.
    --
    -- `entry.frame` is therefore nil until a chain draws it, and nil for good
    -- when the party display is off. Every consumer already guards for that.
    local entry = AcquireEntry()
    entry.startTime         = GetTime()
    entry._texture          = texture
    entry._spellName        = spellName
    entry._targets          = targets
    entry._duration         = duration
    entry._isChannel        = isChannel
    entry._notInterruptible = notInterruptible
    AddActiveCast(castingUnit, entry)
    QueueReposition()
end

-- ============================================================
-- EVENT ENTRY POINTS
-- ============================================================

-- Nameplate unit TOKENS are recycled: nameplate5 can belong to a different
-- mob by the time a deferred callback runs. Capture the caster's GUID up front
-- and re-check it at fire time.
--
-- GUIDs can themselves be secret, and comparing two secrets throws -- so test
-- secrecy FIRST and, when either side is unreadable, ACCEPT rather than drop.
-- Same shape as BF:UNIT_PET's guard (Initialization.lua ~1080) and the same
-- ruling as castID: a missed guard beats a dropped cast.
local function SameCaster(guidAtSchedule, unit)
    local now = UnitGUID(unit)
    if guidAtSchedule == nil or now == nil then return false end
    if issecretvalue(guidAtSchedule) or issecretvalue(now) then return true end
    return guidAtSchedule == now
end

function IC:OnSpellcastStart(unit, castGuid, spellId)
    if not IsRelevantCaster(unit) then return end
    local guid = UnitGUID(unit)
    C_Timer.After(DELAY, function()
        if not SameCaster(guid, unit) then return end
        -- "is this unit still casting", asked a legal way.
        --
        -- This used to be `if not UnitCastingInfo(unit)`, which truncates to
        -- return 1 -- the spell NAME -- and truth-tests it. Only isTradeskill,
        -- castBarID and delayTimeMs are documented NeverSecret, so the name can
        -- come back secret on a hostile nameplate, and testing a secret's
        -- truthiness throws. Comparing against nil is the one inspection that
        -- is always permitted.
        --
        -- oUF's castbar does the same truth-test (castbar.lua:200/216/337) --
        -- it is NOT a precedent here. It drives player/target/party frames
        -- where names are not secret; this path runs on hostile nameplates,
        -- which is exactly the secret-identity case.
        if UnitCastingDuration(unit) == nil then return end
        IC.ProcessCast(unit, spellId, false)
    end)
end

function IC:OnSpellcastChannelStart(unit, castGuid, spellId)
    if not IsRelevantCaster(unit) then return end
    local guid = UnitGUID(unit)
    C_Timer.After(DELAY, function()
        if not SameCaster(guid, unit) then return end
        -- See OnSpellcastStart: nil-compare, never a truth-test.
        if UnitChannelDuration(unit) == nil then return end
        IC.ProcessCast(unit, spellId, true)
    end)
end

function IC:OnSpellcastEnd(unit)
    if not IsTrackedNameplate(unit) then return end
    if IC.ReleaseCastsForUnit(unit) then
        QueueReposition()
    end
end

function IC:OnNameplateRemoved(unit)
    if IC.ReleaseCastsForUnit(unit) then
        QueueReposition()
    end
end

function IC:OnNameplateAdded(unit)
    if not IsRelevantCaster(unit) then return end
    local isChannel = false
    local _, _, _, _, _, _, _, _, spellId = UnitCastingInfo(unit)
    if spellId == nil then
        _, _, _, _, _, _, _, spellId = UnitChannelInfo(unit)
        isChannel = true
    end
    -- ~= nil rather than a truth-test: spellID is not documented NeverSecret,
    -- and the nil-compare is free either way.
    if spellId ~= nil then
        IC.ProcessCast(unit, spellId, isChannel)
    end
end

function IC:OnGroupRosterUpdate()
    ReleaseAllCasts()
end

-- ============================================================
-- CONTEXT GATE
--
-- Incoming Casts is a dungeon / delve feature. Anywhere else the
-- CAST_EVENTS below are NEVER REGISTERED, which costs exactly nothing
-- -- the same shape as the cast bar's partyOnly / pvpOnly gates, and
-- for the same reason: filtering per cast still pays the event
-- dispatch, filtering at registration does not. Enemy nameplate casts
-- cannot be RegisterUnitEvent'd (the tokens are dynamic), so these are
-- global registrations and the zone gate is the only thing that bounds
-- them.
--
-- Dungeon is instanceType "party" -- one test covering Normal (1),
-- Heroic (2), Mythic (23) and Mythic Keystone (8).
--
-- Delve is instanceType "scenario" AND difficultyID 208. The bare
-- "scenario" type is much broader than Delves (Torghast, Visions,
-- Warfronts and ordinary scenarios all report it), so the difficulty
-- check is what makes this Delves-only. Note this is deliberately
-- STRICTER than the "delve" layout slot in Core_ProfileAPI, which
-- accepts any scenario -- that slot's own label says
-- "Scenario / Delve / Torghast".
--
-- Neither call is combat-protected and neither returns a secret value.
local DELVE_DIFFICULTY_ID = 208

function IC:ContextAllows()
    local _, instanceType, difficultyID = GetInstanceInfo()
    if instanceType == "party" then return true end
    if instanceType == "scenario" and difficultyID == DELVE_DIFFICULTY_ID then
        return true
    end
    return false
end

-- ============================================================
-- POOL PRE-WARM
--
-- Coalescing repositions fixed the burst of LAYOUT work at a pull; it did
-- nothing about the burst of CREATION work, which is what actually stalls.
--
-- At the start of a pull the pools are empty, and because every deferred cast
-- handler fires DELAY seconds after its event, N simultaneous casts all land
-- in ONE frame. Each one needs a cast frame (3 CreateFrames, ~7 textures, 3
-- font strings, a duration binding), a layout bar (another CreateFrame), and a
-- full ApplyCastBarStyle whose icon border kit creates 4 more textures. At 8
-- casters with both displays on that is ~32 CreateFrame calls and ~150 regions
-- in a single frame.
--
-- So build them BEFORE the pull. Enable() runs from the zone gate on
-- PLAYER_ENTERING_WORLD / ZONE_CHANGED_NEW_AREA -- out of combat, with time to
-- spare -- and the building is itself spread a few objects per frame so the
-- warm-up cannot hitch either.
--
-- Frames are also SIZED and STYLED here, not just created: the first style
-- pass is the expensive half, and a pre-styled frame whose _styleDisplay
-- happens to match its eventual acquirer takes ApplyCastBarStyle's fast path.
-- When it does not match, the full pass simply runs as it would have anyway --
-- pre-warming can never make a cast slower than not pre-warming.
--
-- The per-display target is the display's own RENDER CAP, not a fixed
-- number. It was 10 against a default-mode cap of 20, so any pull with more
-- than ten casters ran the pool dry and paid full construction on the combat
-- path -- and "full construction" includes a style pass whose rounded border
-- kit loads two BLOCKING mask textures. Now that ProcessCast refuses to build
-- past its own display's cap, partyCap + playerCap IS the steady-state
-- working set, so the pool covers it exactly rather than overshooting:
-- nothing is stocked that a pull could not legitimately demand.
--
-- Self-limiting in "all" mode too, where a display's cap is the user's
-- MaxBars (default 5) rather than DEFAULT_MODE_ENTRY_CAP.
--
-- One case still exceeds it: with HoldTime > 0 a finished cast keeps its
-- frame for the linger while its slot is already refilled, so in-flight
-- frames can run a generation ahead of the caps. The pool absorbs that on
-- first use and never shrinks, so it costs one pull's worth of construction
-- once rather than every pull.
local PREWARM_PER_TICK = 3

local prewarmPending = false
local QueuePrewarm

local function PrewarmMakeStyled(display, wantCB)
    local cfg = IC:GetCfg(display)
    local f
    if wantCB then
        f = CreateCastBarFrame()
        f._display = display
        -- Size BEFORE styling, same reason as ProcessCast: the rounded border
        -- helper change-guards off the bar's size, so styling a 0x0 frame
        -- latches the wrong scale for that frame's life.
        f:SetSize(cfg.BarWidth or 80, cfg.BarHeight or 12)
        IC:ApplyCastBarStyle(f)
    else
        f = CreateIconDisplayFrame()
        f._display = display
        local sz = cfg.IconSize or 20
        f:SetSize(sz, sz)
        -- Icons are generation-guarded too now (ApplyIconStyle), so they are
        -- pre-styled for the same reason the cast bars are.
        IC:ApplyIconStyle(f)
    end
    f:Hide()
    -- A pooled frame must not tick. AttachTimerBinding enables the binding at
    -- construction and ApplyCastBarStyle's per-cast pass re-enables it, so a
    -- freshly warmed frame would sit in the pool formatting text into a hidden
    -- font string until something acquired it. SetupCastFrame turns it back on
    -- at acquire, which is the only moment it is wanted.
    SetBindingEnabled(f, false)
    return f
end

-- Re-style ONE stale pooled frame. Returns true if it did work.
--
-- IC:Refresh bumps _styleGen and now KEEPS the pools rather than wiping them,
-- so after any settings change every pooled frame carries the old generation
-- and will take the FULL style pass when acquired. The stocking loop below
-- counts frames, not generations, and ReleaseAllCasts has just put the live
-- ones back -- so it would find the pools at target and stop on its first
-- tick, leaving twenty stale frames to be fully re-styled inside a single
-- coalesced reposition on the next pull. That is the very hitch the pre-warm
-- exists to prevent, and worse than the wipe it replaced.
--
-- The cursor is CIRCULAR, one per pool, and is never reset -- not even when
-- the generation moves. Resetting it looks right and is a trap: an options
-- slider fires setAndRefresh on every drag step, each bump lands a fresh
-- generation, and a cursor that restarted at 1 each time would re-style the
-- first PREWARM_PER_TICK frames over and over for the whole drag while the
-- rest of the pool stayed stale -- hundreds of full passes, border-kit
-- rebuilds and all, achieving nothing. Wrapping keeps the same three-per-tick
-- budget but makes it walk, so a bump storm sweeps the pool round-robin.
--
-- The per-frame generation test is what decides the work; the cursor only says
-- where to look next. One lap of every pool finding nothing stale ends the
-- sweep.
--
-- Cast bars AND icons: since ApplyIconStyle, icon frames carry a generation
-- as well, so a stale pooled icon would otherwise pay its font pass at
-- acquire.
local restyleCursors = {}

local function RestylePool(pool, display, wantCB)
    local n = #pool
    if n == 0 then return false end
    local cursor = restyleCursors[pool] or 0
    if cursor > n then cursor = 0 end
    -- At most one lap, so this terminates whether or not anything is stale.
    for _ = 1, n do
        cursor = cursor + 1
        if cursor > n then cursor = 1 end
        local f = pool[cursor]
        if f and f._styleGen ~= IC._styleGen then
            restyleCursors[pool] = cursor
            -- The pool IS the display, but pin _display regardless: the
            -- style pass records _styleDisplay from it.
            f._display = display
            local cfg = IC:GetCfg(display)
            -- Size before styling, same reason as PrewarmMakeStyled; taken
            -- from the config rather than left as-is, because the size may be
            -- exactly what the settings change altered.
            if wantCB then
                f:SetSize(cfg.BarWidth or 80, cfg.BarHeight or 12)
                f._bf_w, f._bf_h = nil, nil
                IC:ApplyCastBarStyle(f)
                -- ApplyCastBarStyle ends in the per-cast pass, which re-enables
                -- the binding. Still pooled, so switch it back off.
                SetBindingEnabled(f, false)
            else
                local sz = cfg.IconSize or 20
                f:SetSize(sz, sz)
                f._bf_w, f._bf_h = nil, nil
                IC:ApplyIconStyle(f)
            end
            return true
        end
    end
    restyleCursors[pool] = cursor
    return false
end

local function PrewarmRestyleOne()
    return RestylePool(framePools.castbar[DISPLAY_PARTY],  DISPLAY_PARTY,  true)
        or RestylePool(framePools.castbar[DISPLAY_PLAYER], DISPLAY_PLAYER, true)
        or RestylePool(framePools.icon[DISPLAY_PARTY],     DISPLAY_PARTY,  false)
        or RestylePool(framePools.icon[DISPLAY_PLAYER],    DISPLAY_PLAYER, false)
end

-- Stocking targets, resolved once per tick into a reused table: how many
-- frames each display wants in its OWN pool (nil when that display is off),
-- and the shared layout-bar total. Each display's pool holds frames of that
-- display's CURRENT type, styled for that display -- which is what makes the
-- acquire fast path hold with both displays on. Before the per-display split
-- every warmed cast bar was styled for whichever display came first, so half
-- of them took the full pass at first acquire anyway.
local PREWARM_DISPLAYS = { DISPLAY_PARTY, DISPLAY_PLAYER }
local prewarmWant = {}

local function ResolvePrewarmTargets()
    prewarmWant[DISPLAY_PARTY], prewarmWant[DISPLAY_PLAYER] = nil, nil
    local ic = BF.icDB and BF.icDB.profile
    if not ic then return 0 end
    local showParty = ic.incomingCastsShowOnPartyFrame
    if showParty == nil then showParty = true end
    local showPlayer = ic.incomingCastsShowOnPlayerFrame and true or false
    local bars = 0
    if showParty then
        local n = ResolveMaxBars(IC:GetCfg(DISPLAY_PARTY))
        prewarmWant[DISPLAY_PARTY] = n
        bars = bars + n
    end
    if showPlayer then
        local n = ResolveMaxBars(IC:GetCfg(DISPLAY_PLAYER))
        prewarmWant[DISPLAY_PLAYER] = n
        bars = bars + n
    end
    return bars
end

-- Build ONE frame for the first display whose pool is under target.
-- Returns true if it built one.
local function PrewarmBuildOne()
    for i = 1, #PREWARM_DISPLAYS do
        local display = PREWARM_DISPLAYS[i]
        local want = prewarmWant[display]
        if want then
            local wantCB = GetDisplayType(display) == "castbar"
            local pool = wantCB and framePools.castbar[display]
                         or framePools.icon[display]
            if #pool < want then
                table_insert(pool, PrewarmMakeStyled(display, wantCB))
                return true
            end
        end
    end
    return false
end

local function PrewarmStep()
    prewarmPending = false
    if not IC._enabled then return end
    if not (BF.icDB and BF.icDB.profile) then return end

    local wantBars = ResolvePrewarmTargets()

    for _ = 1, PREWARM_PER_TICK do
        if PrewarmBuildOne() then
            -- one frame built; spend the rest of the tick the same way
        elseif #layoutBarPool < wantBars then
            table_insert(layoutBarPool, CreateLayoutBar())
        elseif not PrewarmRestyleOne() then
            return                      -- fully stocked AND fully styled
        end
    end
    QueuePrewarm()                      -- more to build, continue next frame
end

QueuePrewarm = function()
    if prewarmPending then return end
    prewarmPending = true
    C_Timer.After(0, PrewarmStep)
end

-- ============================================================
-- ENABLE / DISABLE
-- ============================================================

function IC:Enable()
    self._enabled = true
    self:RegisterCastEvents()
    -- Stock the pools now, while we are almost certainly out of combat --
    -- see the POOL PRE-WARM note. Idempotent: a stocked pool stops on the
    -- first tick.
    QueuePrewarm()
end

function IC:Disable()
    if not self._enabled then return end
    self._enabled = nil
    self:UnregisterCastEvents()
    ReleaseAllCasts()
end

-- Re-evaluate the setting AND the context together. This is the single
-- entry point for "should the feature be live right now" -- the options
-- toggle, profile changes and zone changes all land here.
function IC:RebindContext()
    -- Reached on PLAYER_ENTERING_WORLD and ZONE_CHANGED_NEW_AREA, which is
    -- exactly when the active slot -- and with it the party grow direction --
    -- can change under us. Cheap, and it covers the zone path outright rather
    -- than leaving it to the memo's TTL.
    InvalidatePartyDir()
    if IsEnabled() and self:ContextAllows() then
        self:Enable()
    else
        self:Disable()
    end
end

function IC:Refresh()
    -- Every options setter reaches here, so this is where a settings change
    -- invalidates the cast-start fast path in ApplyCastBarStyle.
    IC._styleGen = (IC._styleGen or 1) + 1
    -- Custom class colors live in the Colors page and can change between
    -- calls; drop the cached player name/color so the next style pass
    -- re-resolves them.
    ClearPlayerIdentityCache()
    -- Per-display settings feed every runtime read; drop the resolved tables
    -- so the next read rebuilds them.
    InvalidateCfg()
    -- The party grow direction memo is time-bounded, but a settings change is
    -- the one moment we KNOW it is wrong, so do not make the user wait out
    -- the TTL for it.
    InvalidatePartyDir()
    ReleaseAllCasts()
    -- The pools are KEPT, where this used to table_wipe all three.
    --
    -- Wiping them never destroyed anything: a WoW frame cannot be freed, so
    -- each wipe permanently stranded the entire pool -- a cost repeated for
    -- every one of the fifty-odd options setters that reach here, and one the
    -- raised prewarm targets would have multiplied.
    --
    -- Nothing needed the wipe. `_styleGen` was bumped above, so any pooled
    -- frame handed out afterwards MISSES ApplyCastBarStyle's generation guard
    -- and takes the full settings pass -- which is precisely the case the note
    -- above that counter says it was made a counter for. Layout bars hold no
    -- settings-derived state that PositionOnFrame does not re-assert from its
    -- own change guards.
    --
    -- Restock: a cap may have grown, and -- more to the point -- the pooled
    -- frames are all a generation behind now. PrewarmRestyleOne sweeps them
    -- back up to date a few per frame, so the next pull acquires frames that
    -- take ApplyCastBarStyle's fast path instead of paying the full pass for
    -- every bar inside one coalesced reposition.
    if self._enabled then QueuePrewarm() end
end

function IC:Init()
    self:RebindContext()
end

function IC:OnSettingChanged()
    -- Belt-and-braces: the master Enable toggle calls this WITHOUT calling
    -- Refresh, and profile switches land here too.
    IC._styleGen = (IC._styleGen or 1) + 1
    InvalidateCfg()
    self:RebindContext()
end

-- ============================================================
-- EVENT FRAME (registered at file load time)
-- ============================================================
-- UNIT_SPELLCAST_SUCCEEDED is deliberately NOT here. Per the wiki it
-- "fires whenever a spellcast is completed server end, regardless of
-- whether it is instant or cast" -- so it fired for every instant from
-- every unit in range, by far the highest-volume of the set, purely to
-- learn that a cast had ended. STOP / CHANNEL_STOP cover the normal
-- completion and INTERRUPTED / FAILED_QUIET cover the rest, which is
-- exactly the split Libs/oUF/elements/castbar.lua and BFStatus.lua's
-- castbar status both use -- neither registers SUCCEEDED for this.
-- v86 (event refactor stage 4): each entry now carries its unit scope.
-- "any" throughout the cast events is deliberate and load-bearing: this
-- feature tracks casts from arbitrary enemies via nameplates, so unlike
-- almost everything else in the addon it genuinely wants every unit the
-- event delivers. Spelling it out means a future reader sees a decision
-- rather than an omission.
local CAST_EVENTS = {
    { "UNIT_SPELLCAST_START",         "any" },
    { "UNIT_SPELLCAST_CHANNEL_START", "any" },
    { "UNIT_SPELLCAST_STOP",          "any" },
    { "UNIT_SPELLCAST_CHANNEL_STOP",  "any" },
    { "UNIT_SPELLCAST_INTERRUPTED",   "any" },
    { "UNIT_SPELLCAST_FAILED_QUIET",  "any" },
    { "NAME_PLATE_UNIT_ADDED",        "any" },
    { "NAME_PLATE_UNIT_REMOVED",      "any" },
    { "GROUP_ROSTER_UPDATE",          "unitless" },
}

-- The owner exists at file load but holds NOTHING. Subscription is owned by
-- Enable / Disable so that a disqualifying zone -- or the feature simply
-- being switched off -- costs zero event dispatch. Previously these were
-- registered at load and never unregistered, so the handler ran for every
-- spellcast in the session even with the feature disabled.
--
-- v86 (event refactor stage 4): UnsubAll is scoped to this owner, so unlike
-- the old frame:UnregisterAllEvents it cannot reach anything else.
do
    local castEvents = BF:EventOwner("incomingCasts")

    local function OnCastEvent(_, event, ...)
        if not IC._enabled then return end
        if event == "UNIT_SPELLCAST_START" then
            IC:OnSpellcastStart(...)
        elseif event == "UNIT_SPELLCAST_CHANNEL_START" then
            IC:OnSpellcastChannelStart(...)
        elseif event == "UNIT_SPELLCAST_STOP"
            or event == "UNIT_SPELLCAST_CHANNEL_STOP"
            or event == "UNIT_SPELLCAST_INTERRUPTED"
            or event == "UNIT_SPELLCAST_FAILED_QUIET"
        then
            local unit = ...
            IC:OnSpellcastEnd(unit)
        elseif event == "NAME_PLATE_UNIT_ADDED" then
            IC:OnNameplateAdded(...)
        elseif event == "NAME_PLATE_UNIT_REMOVED" then
            IC:OnNameplateRemoved(...)
        elseif event == "GROUP_ROSTER_UPDATE" then
            IC:OnGroupRosterUpdate()
        end
    end

    function IC:RegisterCastEvents()
        if self._eventsRegistered then return end
        self._eventsRegistered = true
        for _, e in ipairs(CAST_EVENTS) do
            -- lint:scope-from-table (CAST_EVENTS carries the scope per entry)
            castEvents:Sub(e[1], OnCastEvent, e[2])
        end
    end

    function IC:UnregisterCastEvents()
        if not self._eventsRegistered then return end
        self._eventsRegistered = nil
        castEvents:UnsubAll()
    end
end
