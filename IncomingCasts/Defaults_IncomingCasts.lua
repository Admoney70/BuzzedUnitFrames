-- ============================================================
-- BuzzardFrames: IncomingCasts/Defaults_IncomingCasts.lua
-- Default values for the Incoming Casts module.
--
-- Grid2 pattern: RegisterNamespace creates a child database
-- stored in BuzzardFramesDB.namespaces.IncomingCasts. The
-- namespace automatically follows profile switches, copies,
-- and resets. Access via BF.icDB.profile.
--
-- Must be loaded before Core.lua (see .toc).
--
-- Migration: keys previously lived at p.modules.incomingCasts
-- (created by dbVersion 9 migration) and were moved here by
-- dbVersion 16 migration.
-- ============================================================
local BF = _G["BuzzardFrames"]

BF.incomingCastsDefaults = {
    profile = {
        incomingCastsEnabled             = false,
        incomingCastsDisplayType         = "castbar",
        incomingCastsShowTimer           = true,
        incomingCastsShowOnPlayerFrame   = false,
        incomingCastsShowOnPartyFrame    = true,
        incomingCastsAnchorPoint         = "AUTO",
        incomingCastsGrowDirection       = "AUTO",
        incomingCastsSpacing             = 2,
        incomingCastsOffsetX             = 0,
        incomingCastsOffsetY             = 0,
        incomingCastsPlayerAnchorX       = 0,
        incomingCastsPlayerAnchorY       = -200,
        incomingCastsPlayerGrowDirection = "DOWN",
        incomingCastsPlayerSpacing       = 2,
        incomingCastsBarWidth            = 80,
        incomingCastsBarHeight           = 12,
        incomingCastsIconSize            = 20,
        -- Icon timer text styling (independent of raid-frame debuff text)
        incomingCastsIconAutoScale       = true,
        incomingCastsIconTimerScale      = 1.0,
        incomingCastsIconTimerFontSize   = 11,
        incomingCastsIconTimerFont       = "Interface\\AddOns\\BuzzardFrames\\Media\\Fonts\\RobotoCondensed-Bold.ttf",
        incomingCastsIconTimerFontBorder = "OUTLINE",

        -- ========================================================
        -- CAST BAR APPEARANCE (display type "castbar")
        --
        -- These mirror the party/raid cast bar's castBar section
        -- (Defaults_RaidPartyFrames.lua) so both cast bars are
        -- configurable to the same degree. Two deliberate omissions:
        --
        --  * NO bar/uninterruptible color keys. Those stay shared
        --    with the Unit Frames cast bars via ufDB.profile
        --    (castBarColor / castBarUninterruptibleColor /
        --    castBarBgColor) so the two look consistent by default.
        --    The options panel links through to the Colors page.
        --  * NO empower stage pips. IncomingCasts tracks enemy casts
        --    aimed at the player; the pips feature is raid-frame only.
        -- ========================================================

        -- ========================================================
        -- SHOW ALL ENEMY CASTS
        --
        -- By default the module only reveals casts aimed at the player.
        -- Note it already CREATES a frame for every enemy nameplate cast
        -- -- the targeting filter is purely visual, applied by alpha'ing
        -- from the secret PlayerIsSpellTarget boolean. So turning this on
        -- allocates nothing extra; it just stops hiding what is there.
        --
        -- There is NO API to tell whether a cast is AoE or ground-targeted,
        -- so this cannot be narrowed to "only untargeted casts" -- it is
        -- all enemy casts or only yours.
        -- ========================================================
        incomingCastsShowAllCasts        = false,
        incomingCastsMaxBars             = 5,
        -- Tint applied to casts NOT aimed at the player. Driven by
        -- SetAlphaFromBoolean on the secret boolean, so it needs no branch.
        incomingCastsTintNotAimed        = true,
        incomingCastsNotAimedColor       = { r = 0.35, g = 0.35, b = 0.4, a = 0.75 },

        -- Bar
        incomingCastsUseCustomTexture    = false,
        incomingCastsTexture             = "Solid",
        incomingCastsOpacity             = 1.0,
        -- Cast bar fill color, independent of the Unit Frames cast bars.
        incomingCastsBarColor            = { r = 1, g = 0.84, b = 0, a = 1 },

        -- Background. Color still comes from ufDB.castBarBgColor;
        -- this only overrides its alpha.
        incomingCastsBgOpacity           = 0.6,

        -- Border. "square" = four 1px edge textures; the rounded
        -- styles use the shared nine-sliced ring + mask kit, whose
        -- band weight is baked into the art (so thickness is ignored).
        incomingCastsShowBorder          = true,
        incomingCastsBorderStyle         = "square",
        incomingCastsBorderColor         = { r = 0, g = 0, b = 0, a = 0.8 },
        incomingCastsBorderThickness     = 1,

        -- Icon
        incomingCastsShowIcon            = true,
        incomingCastsIconSide            = "LEFT",
        incomingCastsIconSizePct         = 1.0,   -- of bar height
        incomingCastsIconGap             = 1,
        incomingCastsIconXOffset         = 0,
        incomingCastsIconYOffset         = 0,

        -- Target name. Every cast this module shows is aimed at YOU
        -- (PlayerIsSpellTarget only answers for the player), so this
        -- renders your own name -- which is the one unit name that is
        -- never a secret value. Most useful together with
        -- incomingCastsShowAllCasts, where it marks which of the visible
        -- casts are actually coming at you.
        incomingCastsShowTargetName      = false,
        incomingCastsTargetNameClassColor = true,

        -- Text
        incomingCastsShowSpellName       = true,
        incomingCastsNameAlign           = "LEFT",
        incomingCastsTimerAlign          = "RIGHT",
        -- LSM font NAME (not a path) so the LSM30_Font dropdown shows the
        -- selection instead of blank. "Roboto Condensed Bold" is registered
        -- in Initialization.lua.
        incomingCastsNameFont            = "Roboto Condensed Bold",
        incomingCastsNameFontSize        = 10,
        incomingCastsNameFontBorder      = "",
        incomingCastsBarTimerFont        = "Roboto Condensed Bold",
        incomingCastsBarTimerFontSize    = 10,
        incomingCastsBarTimerFontBorder  = "",
        -- Legacy single text color; still the fallback for the two split
        -- colors below. The split keys default to nil (absent) so an old
        -- profile that customised incomingCastsTextColor keeps that color
        -- for both name and timer until it sets either new value.
        incomingCastsTextColor           = { r = 1, g = 1, b = 1, a = 1 },
        incomingCastsNameColor           = nil,
        incomingCastsTimeColor           = nil,

        -- Linger after the cast is interrupted or ends, in seconds.
        incomingCastsHoldTime            = 0,
    },
}

-- ============================================================
-- PER-DISPLAY KEYS
--
-- Incoming Casts has TWO independent displays, and every setting in the
-- options belongs to one of them:
--
--   * the bar attached to the party player frame -- owns the UNPREFIXED
--     keys, incomingCasts<Suffix>
--   * the detached "Incoming Casts Frame" -- owns incomingCastsPlayer<Suffix>
--
-- They used to share all 43 of these. Options_IncomingCasts builds both
-- sections from ONE makeOptionsArgs generator, and icGet/icSet resolve the
-- storage key from the option's own name -- so the two tabs looked
-- independent and wrote to the same place. Editing the bar width, colors,
-- fonts, borders, display type or the Show Casts filter on either tab
-- silently changed both.
--
-- Position was already per-display (incomingCastsPlayerAnchorX/Y,
-- PlayerGrowDirection, PlayerSpacing), which is where the naming convention
-- comes from; this extends it to everything else.
--
-- THIS LIST IS THE SINGLE SOURCE OF TRUTH. The standalone defaults below,
-- the dbVersion 64 migration, the options generator and the runtime
-- resolution all drive off it -- add a per-display setting here and nowhere
-- else.
--
-- Keys deliberately NOT per-display: incomingCastsEnabled (the master
-- toggle), incomingCastsShowOnPlayerFrame / incomingCastsShowOnPartyFrame
-- (they select WHICH display is on), the position keys (already split), and
-- incomingCastsTextColor (a read-only legacy fallback for the split
-- name/time colors, never written by the UI any more).
BF.incomingCastsPerDisplayKeys = {
    "DisplayType",
    "BarColor", "BarWidth", "BarHeight", "Opacity", "BgOpacity",
    "UseCustomTexture", "Texture",
    "ShowBorder", "BorderStyle", "BorderColor", "BorderThickness",
    "ShowIcon", "IconSide", "IconSize", "IconSizePct", "IconGap",
    "IconXOffset", "IconYOffset",
    "IconAutoScale", "IconTimerScale",
    "IconTimerFont", "IconTimerFontSize", "IconTimerFontBorder",
    "ShowSpellName", "NameAlign", "NameColor",
    "NameFont", "NameFontSize", "NameFontBorder",
    "ShowTimer", "TimerAlign", "TimeColor",
    "BarTimerFont", "BarTimerFontSize", "BarTimerFontBorder",
    "ShowTargetName", "TargetNameClassColor",
    -- CastFilter is the three-way replacement for the ShowAllCasts boolean
    -- ("aimed" / "all" / "notAimed"). ShowAllCasts is KEPT in this list and in
    -- the defaults: it is still the stored value for any profile that predates
    -- the filter, and BuildCfg maps it at read time rather than migrating it.
    "CastFilter", "ShowAllCasts", "MaxBars",
    "TintNotAimed", "NotAimedColor",
    "HoldTime",
}

-- Derive the standalone display's defaults from the party display's rather
-- than hand-duplicating 43 literals, which would drift the first time one
-- side is retuned. Table values are COPIED, never shared: two default keys
-- pointing at one table is exactly the bug this whole split exists to fix.
do
    local prof = BF.incomingCastsDefaults.profile
    for _, suffix in ipairs(BF.incomingCastsPerDisplayKeys) do
        local src = prof["incomingCasts" .. suffix]
        if type(src) == "table" then
            local copy = {}
            for k, v in pairs(src) do copy[k] = v end
            prof["incomingCastsPlayer" .. suffix] = copy
        else
            -- nil stays nil: NameColor / TimeColor are deliberately absent
            -- so they fall back to the legacy incomingCastsTextColor.
            prof["incomingCastsPlayer" .. suffix] = src
        end
    end
end

-- Perf plan §L5.1 load-time mark: closes the defaults block (.toc 50-54).
if BuzzardFrames then BuzzardFrames:LoadMark("chunk:defaultsDone") end
