-- ============================================================
-- BuzzardFrames: UnitFrames/Defaults_UnitFrames.lua
-- Default values for the Unit Frames module.
--
-- Grid2 pattern: Grid2Layout.defaultDB declares its own profile
-- defaults, then Grid2Layout.db is created via RegisterNamespace
-- in OnModuleInitialize. BF follows the same pattern: this file
-- declares BF.unitFrameDefaults, and Core.lua registers it as
-- a namespace so UF code reads from BF.ufDB.profile.
--
-- Must be loaded before Core.lua (see .toc).
-- ============================================================
local BF = _G["BuzzardFrames"]

BF.unitFrameDefaults = {
    profile = {
        -- ── Per-unit sub-tables ───────────────────────────────────────────
        player       = BF:CreateUnitFrameProfile(605, 375, "player"),
        target       = BF:CreateUnitFrameProfile(1285, 375, "target"),
        focus        = (function() local t = BF:CreateUnitFrameProfile(1285, 460, "focus");  t.frameScale = 0.8; return t end)(),
        targettarget = BF:CreateUnitFrameProfile(1475, 375, "target"),
        focustarget  = (function() local t = BF:CreateUnitFrameProfile(1470, 460, "target"); t.frameScale = 0.8; return t end)(),
        -- petMatchPlayer*: pet-only keys, so they are set HERE rather than in
        -- CreateUnitFrameProfile (which every unit shares). Both readers treat
        -- absent as "match" (oUF_Shared.lua `~= false`, Options `~= false`);
        -- stating it gives the options panel a default to reset to.
        pet          = (function() local t = BF:CreateUnitFrameProfile(635, 295, "player"); t.frameScale = 0.8; t.iconScale = 0.8; t.petMatchPlayerColor = true; t.petMatchPlayerNameColor = true; return t end)(),
        -- v67 BUGFIX: this was built with unit = "target", so CreateUnitFrameProfile
        -- emitted targetShowBuffs / targetBuffSize / targetMaxBuffs / ... while
        -- every boss reader and writer uses boss* keys (oUF_BossFrames.lua,
        -- Options_oUF_Other.lua, SetupMode_UnitFrames.lua). The result: boss had
        -- NO aura defaults at all -- each one fell through to an inline `or`
        -- fallback -- and the intended `MaxBuffs = 8` below was never read.
        -- Passing "boss" fixes the prefix; the profile is otherwise identical,
        -- since CreateUnitFrameProfile only branches on unit == "player".
        boss         = (function() local t = BF:CreateUnitFrameProfile(1475, 500, "boss"); t.frameScale = 0.8; t.bossMaxBuffs = 8; t.bossMaxDebuffs = 8; return t end)(),

        -- ── Master switches ───────────────────────────────────────────────
        ptfEnabled              = false,
        -- (2026-08-24 dead-key sweep: ptfFrameStyle removed -- zero readers.)
        showPlayerFrame         = true,
        showTargetFrame         = true,
        showFocusFrame          = true,
        showTargetOfTargetFrame = false,
        showFocusTargetFrame    = false,
        showBossFrames          = false,
        showPetFrame            = true,

        -- Raid-style twins: show the Player/Target/Focus/Boss frame with
        -- the active Raid/Party flat's styling while the unit is friendly.
        -- A twin is live only when BOTH the show* switch above and its
        -- *RaidStyle flag are on. Runtime relayout through
        -- ApplyOUFVisibility, so these are deliberately NOT in
        -- UF_RELOAD_KEYS (Core_ProfileLifecycle.lua) -- no reload prompt.
        playerRaidStyle         = false,
        targetRaidStyle         = false,
        focusRaidStyle          = false,
        bossRaidStyle           = false,

        -- ── UF layout system ──────────────────────────────────────────────
        activeUFLayout = "default",
        ufLayouts = {
            -- Phase L (§L.6a): the raid40/30/20 buckets are GONE -- they
            -- have been unreachable since separateUFByGroupType was retired
            -- 2026-08-15 (GetUFAnchor/SetUFAnchor hardcode "party" as the
            -- only live bucket). Do not reintroduce: AceDB materialised
            -- them into every profile on every login.
            default = {
                name   = "Default",
                party  = {},
            },
        },
        ufLayoutFrames = {
            player           = false,
            target           = false,
            focus            = false,
            pet              = false,
            targettarget     = false,
            focustarget      = false,
            playerPowerBar   = false,
            playerResourceBar = false,
        },
        -- The layout used when no Role or Spec override applies -- the
        -- Global entry of the Layout Assignments tree, and the exact
        -- counterpart of the raid section's instanceLayoutAssignment
        -- slots. Distinct from activeUFLayout, which is the RESOLVED
        -- answer: one is what the reader chose, the other is what is in
        -- use, and a resolver that wrote them both to one field could not
        -- put the choice back after an override stopped applying.
        ufGlobalLayout         = "default",
        enableUFRoleLayouts    = false,
        -- Which roles have an override ENTRY, mirroring ufSpecLayouts on the
        -- spec side. The assignment table below is an AceDB default and so
        -- always carries all three roles, which cannot say whether the user
        -- configured a role or simply never touched it; presence can, and it
        -- is what the Layouts tree lists.
        ufRoleLayouts          = {},
        -- EMPTY, not three roles pre-set to "default". An absent assignment
        -- is what "use the global setting" is stored as, the same way an
        -- absent spec assignment always was -- and a defaults table that
        -- hands back "default" for a role nobody has touched cannot say
        -- the difference between deferring to Global and choosing the
        -- layout named Default. Presence lives in ufRoleLayouts now, so
        -- nothing needs this table pre-populated to know a role exists.
        ufRoleLayoutAssignment = {},
        enableUFSpecLayouts    = false,
        ufSpecLayouts          = {},
        ufSpecLayoutAssignment = {},

        -- ── Font settings ─────────────────────────────────────────────────
        oufAdjustFonts     = true,
        oufSeparateFonts   = false,
        oufGlobalFont      = nil,
        oufNameFont        = nil,
        oufLevelFont       = nil,
        oufHealthPctFont   = nil,
        oufHealthValFont   = nil,
        oufPowerPctFont    = nil,
        oufPowerValFont    = nil,
        oufAltPowerPctFont = nil,
        oufAltPowerValFont = nil,

        -- ── Global UF colors ──────────────────────────────────────────────
        -- Player health bar: "class" | "gradient" | "static"
        globalPlayerHealthColorMode  = "class",
        globalHealthColor            = { r=0.24, g=0.78, b=0.24 },
        -- Separate player frame color override
        separatePlayerFrameColor     = false,
        playerFrameHealthColorMode   = "class",
        playerFrameHealthColor       = { r=0.24, g=0.78, b=0.24 },
        -- NPC health bar: "classification" | "hostility" | "gradient" | "static"
        globalNpcHealthColorMode     = "classification",
        globalNpcHealthColor         = { r=0.24, g=0.78, b=0.24 },
        -- Player name: "class" | "static"
        globalPlayerNameColorMode    = "class",
        globalNameColor              = { r=1.0, g=1.0, b=1.0 },
        -- Separate player frame name color override
        separatePlayerFrameNameColor = false,
        playerFrameNameColorMode     = "class",
        playerFrameNameColor         = { r=1.0, g=1.0, b=1.0 },
        -- NPC name: "classification" | "hostility" | "static"
        globalNpcNameColorMode       = "classification",
        globalNpcNameColor           = { r=1.0, g=1.0, b=1.0 },
        globalNpcBossColor           = { r=1.00, g=0.00, b=1.00 },
        globalNpcLieutenantColor     = { r=0.576, g=0.439, b=0.859 },
        globalNpcCasterColor         = { r=0.00, g=0.820, b=1.00 },
        globalNpcNeutralColor        = { r=0.90, g=0.70, b=0.00 },
        globalNpcFriendlyColor       = { r=0.00, g=0.65, b=0.00 },
        globalNpcTrivialColor        = { r=0.592, g=0.612, b=0.592 },
        globalNpcRegularColor        = { r=0.745, g=0.188, b=0.114 },

        -- ── Cast bar colors (shared) ──────────────────────────────────────
        castBarColor                = { r=1,     g=0.84,  b=0     },
        castBarUninterruptibleColor = { r=0.565, g=0.557, b=0.545 },
        castBarBgColor              = { r=0,     g=0,     b=0, a=0.6 },

        -- ── Icon / shape settings ─────────────────────────────────────────
        iconSize                       = 56,
        iconOpacity                    = 1.0,
        iconShape                      = "circular",
        iconOffsetX                    = 0,
        iconOffsetY                    = 0,
        playerShowClassIcon            = true,
        iconStyle                      = "classicon",
        iconLocation                   = "outer",
        -- (2026-08-24 dead-key sweep: classIconPosition removed -- zero readers.)
        classIconBorderEnabled         = true,
        classIconBorderColor           = { r = 0.85, g = 0.65, b = 0.1 },
        classIconBorderThickness       = 2,
        classIconBorderUseHealthColor  = false,
        showEliteDragonBorder          = true,
        iconIgnoreClickBinds           = false,

        -- ── Target cast bar ───────────────────────────────────────────────
        targetShowCastBar            = true,
        targetCastBarPosition        = "below",
        targetCastBarDetached        = false,
        targetCastBarWidth           = 156,
        targetCastBarGap             = 0,
        targetCastBarHeight          = 16,
        targetCastBarBorderEnabled   = false,
        targetCastBarBorderThickness = 1,
        targetCastBarBorderColor     = { r=0, g=0, b=0, a=1 },
        targetCastBarShowIcon        = true,
        targetCastBarIconSide        = "left",
        targetCastBarIconSize        = 18,
        targetCastBarIconGap         = 2,
        targetCastBarAvoidAuras      = true,

        -- ── Focus cast bar ────────────────────────────────────────────────
        focusShowCastBar            = true,
        focusCastBarPosition        = "below",
        focusCastBarDetached        = false,
        focusCastBarWidth           = 156,
        focusCastBarGap             = 0,
        focusCastBarHeight          = 16,
        focusCastBarBorderEnabled   = false,
        focusCastBarBorderThickness = 1,
        focusCastBarBorderColor     = { r=0, g=0, b=0, a=1 },
        focusCastBarShowIcon        = true,
        focusCastBarIconSide        = "left",
        focusCastBarIconSize        = 18,
        focusCastBarIconGap         = 2,
        focusCastBarAvoidAuras      = true,

        -- ── Boss cast bar ─────────────────────────────────────────────────
        bossShowCastBar            = true,
        bossCastBarPosition        = "below",
        bossCastBarGap             = 0,
        bossCastBarHeight          = 14,
        -- Bar width for the Left / Right positions only (Below / Above /
        -- Bottom bars span the frame).
        bossCastBarWidth           = 150,
        bossCastBarFontSize        = 10,
        bossCastBarBorderEnabled   = false,
        bossCastBarBorderThickness = 1,
        bossCastBarBorderColor     = { r=0, g=0, b=0, a=1 },
        bossCastBarShowIcon        = true,
        bossCastBarIconSide        = "left",
        bossCastBarIconSize        = 16,
        bossCastBarIconGap         = 2,
        -- (2026-08-24 dead-key sweep: bossCastBarAvoidAuras removed -- the
        -- p[uk .. "CastBarAvoidAuras"] read only ever runs for target/focus.)

        -- ── Blizzard frame hiding (per unit frame) ────────────────────────
        hideBlizzardPlayerFrame         = false,
        hideBlizzardTargetFrame         = false,
        hideBlizzardFocusFrame          = false,
        hideBlizzardPetFrame            = false,
        hideBlizzardTargetOfTargetFrame = false,
        hideBlizzardBossFrames          = false,
        hideBlizzardPlayerCastBar       = false,

        -- ── Resource bar (oUF) ────────────────────────────────────────────
        oufResourceBarEnabled      = true,
        oufResourceBarDetached     = false,
        oufResourceBarAnchorX      = 2,
        oufResourceBarAnchorY      = -100,
        oufResourceBarWidth        = 250,
        oufResourceBarHeight       = 14,
        oufResourceBarGap          = 0,
        oufResourceBarPipGap       = 2,
        oufResourceBarShowBg       = true,
        oufResourceBarBgColor      = { r=0.08, g=0.08, b=0.08, a=0.6 },
        oufResourceBarUseTypeColor = true,
        oufResourceBarColor        = { r=1.0, g=0.61, b=0.04 },
        oufResourceBarShowEmpty    = true,
        oufResourceBarEmptyDim     = 0.1,
        oufResourceBarPartialFill  = true,

        -- ── Border mode (v59 rounded borders) ─────────────────────────────
        -- "square" (default 4-edge boxes) | "rounded" | "rounded_thick".
        -- Rounded modes draw one nine-sliced ring around the composite
        -- block (name+health+alt+power) tinted by frameBorderColor, with
        -- the bar content masked to the corner radius; standalone bars
        -- (detached power/alt, castbars, resource bar) each get their own
        -- ring from the same art. Same art/geometry as the raid-frame
        -- borderStyle (Indicators/Container.lua).
        oufBorderMode                   = "square",
        -- Optional horizontal separators between the name/health/power
        -- bars in rounded modes (band-matched thickness, ring color).
        oufRoundedSeparators            = false,
        -- Bar Separator STYLE (v85 dropdown, rounded modes only):
        --   "rings" — per-bar full rounded borders, shared edges
        --             overlapped so no boundary ever reads double.
        --   "lines" — one composite outline + straight band-matched
        --             single-thickness divider lines (the v63 look).
        oufSeparatorStyle               = "rings",

        -- ── Ping Indicator (Global > Icons/Indicators) ────────────────────
        -- oUF PingIndicator element (ping-pin branch): shows the ping
        -- pin atlas on unit frames via UNIT_PING_PIN_ADDED/REMOVED.
        oufShowPingIndicator            = true,
        -- "CLASSICON" (requires class icon shown; falls back to center),
        -- "LEFT", "CENTER", "RIGHT".
        oufPingIndicatorPosition        = "CENTER",

        -- ── Per-bar border controls ───────────────────────────────────────
        -- (2026-08-24 dead-key sweep: frameBorderEnabled/Thickness removed --
        -- UF_BORDER_BARS is {name, health, power}; only frameBorderColor is live.)
        frameBorderColor                = { r = 0.851, g = 0.851, b = 0.851, a = 1 },
        -- The three box colors: ApplyBox (oUF_Shared.lua) and the options
        -- both fell back to this exact table inline. Stated once instead.
        healthBorderEnabled             = true,
        healthBorderThickness           = 1,
        healthBorderColor               = { r=0, g=0, b=0, a=1 },
        powerBorderEnabled              = true,
        powerBorderThickness            = 1,
        powerBorderColor                = { r=0, g=0, b=0, a=1 },
        nameBorderEnabled               = false,
        nameBorderThickness             = 1,
        nameBorderColor                 = { r=0, g=0, b=0, a=1 },
        -- (2026-08-24 dead-key sweep: nameDividerEnabled/Thickness removed -- zero readers.)
        oufResourceBarBorderEnabled     = false,
        oufResourceBarBorderThickness   = 1,
        oufResourceBarBorderColor       = { r=0, g=0, b=0, a=1 },
        oufResourceBarPipBorderEnabled  = true,
        oufResourceBarPipBorderThickness = 1,
        oufResourceBarPipBorderColor    = { r=0, g=0, b=0, a=1 },
        -- nil meant 1 in both readers (oUF_PowerBar.lua skips SetAlpha when
        -- absent; the option getter returned 1). Stated so reset has a target.
        -- NOTE: oufPowerBarWidth/Height stay ABSENT on purpose -- nil there
        -- means "inherit the frame's width/height", not "use a default".
        oufPowerBarOpacity              = 1,

        -- ── Raid target / combat indicator (oUF) ──────────────────────────
        oufShowRaidTarget      = true,
        oufShowCombatIndicator = true,
        oufCombatIndicatorSize = 18,
        oufRaidTargetSize      = 20,
        oufRaidTargetOffsetX   = 0,
        oufRaidTargetOffsetY   = 7,
        oufRaidTargetLocation  = "center",

        -- ── Boss frame spacing ────────────────────────────────────────────
        bossFrameSpacing = 4,
        bossGrowDirection = "DOWN",
        -- Migration sentinel (2026-09-12): true once this profile's boss
        -- anchors mean boss1's TOPLEFT for every grow direction (they used
        -- to mark the column's far corner for Up / Left). Set by
        -- BF:MigrateBossAnchorToBoss1 on the profile's first boss layout;
        -- differs from the default once set, so it travels with exports
        -- and an already-migrated profile is never shifted twice.
        bossAnchorIsBoss1 = false,

        -- ── UF aura settings ──────────────────────────────────────────────
        auraShowDuration = false,
        -- The swipe trio. auraReverseSwipe = true is the CooldownFrameTemplate's
        -- own SetReverse(true), which oUF_Shared.lua preserves via `~= false`;
        -- the Ace getter read `== true` and so drew the box unticked while the
        -- swipe was in fact reversed. Stating the default settles both.
        auraShowSwipe    = true,
        auraShowSpark    = true,
        auraReverseSwipe = true,
        -- (2026-08-24 dead-key sweep: auraFont removed -- zero readers; auraFontSize is live.)
        auraFontSize     = 9,

        -- ── UF aura stack text ────────────────────────────────────────────
        -- Unit Frames > Global > Auras > Stack Text. Mirrors the raid/party
        -- Aura Text > Stack Text set key-for-key (BF:ApplyStackTextSpec /
        -- Options_AuraText.lua) so both subsystems render identically on
        -- stock settings; oufStackFont holds an LSM display name, nil = the
        -- bundled Roboto Condensed Bold.
        oufStackShow       = true,
        oufStackAutoScale  = false,
        oufStackScale      = 1.0,
        oufStackFont       = nil,
        oufStackFontBorder = "OUTLINE",
        oufStackFontSize   = 9,
        oufStackAnchor     = "BOTTOMRIGHT",
        oufStackX          = 4,
        oufStackY          = -3,

        -- ── Tooltips (oUF_Shared.lua OnEnter gate) ────────────────────────
        -- showUnitTooltip gates the entire tooltip OnEnter path in
        -- BluzzardStyle (both unit-frame and iconFrame hooks).
        -- showUnitTooltipInCombat gates that same path while in combat.
        -- UI: Unit Frames → Global → Tooltips.
        showUnitTooltip         = true,
        showUnitTooltipInCombat = true,

        -- ── UF alt power bar ──────────────────────────────────────────────
        showAltPowerBar       = true,
        altPowerBarHeight     = 3,
        altPowerBarDetached   = false,
        altPowerBarDruidSpecs = { restoration = true, guardian = false, balance = true, feral = false },
        oufAltPowerBarWidth   = 156,
        altPowerShowPct       = false,
        altPowerShowPctSymbol = true,
        altPowerShowVal       = false,
        altPowerFontSize      = 7,
        altPowerPctPos        = { point = "RIGHT", x = -3, y = 0 },
        altPowerValPos        = { point = "LEFT",  x = 3,  y = 0 },

        -- ── Power bar detach (dynamically created) ────────────────────────
        -- oufPowerBarAnchorX/Y intentionally omitted: nil means "no saved position".
        oufPowerBarDetached = false,

        -- ── Health bar opacity ───────────────────────────────────────────
        oufHealthBarOpacity = 1,
        -- Per-frame opacity for the player frame, used when
        -- separatePlayerFrameColor is enabled.
        playerFrameHealthBarOpacity = 1,

        -- ── Health bar background ────────────────────────────────────────
        oufUseCustomBackgroundColor = false,
        oufBackgroundColorMode      = "static",
        oufBackgroundColor          = { r=0.08, g=0.08, b=0.08 },
        oufBackgroundAlpha          = 0.6,
        oufBgClassDarken            = 0,

        -- ── Power bar background ────────────────────────────────────────
        -- Alpha defaults to 0.6, matching the value BluzzardStyle hardcoded
        -- before these keys existed, so enabling the toggle without touching
        -- the slider leaves the frames looking exactly as they did. (The
        -- raid-frame equivalent defaults its opacity to 1.0 -- deliberately
        -- NOT mirrored here for that reason.)
        oufUseCustomPowerBarBgColor = false,
        oufPowerBarBgColor          = { r=0.08, g=0.08, b=0.08 },
        oufPowerBarBgAlpha          = 0.6,

        -- ── Bar textures ────────────────────────────────────────────────
        oufUseCustomHealthBarTexture = false,
        oufHealthBarTexture = "Blizzard Raid Bar",
        oufUseCustomPowerBarTexture = false,
        oufPowerBarTexture = "Blizzard Raid Bar",

        -- ── Aura border style (v60, defaults seeded v67) ──────────────────
        -- Legacy SHARED keys — kept for backward compat with profiles that
        -- predate the per-kind split. GetOUFAuraBorderStyle falls back to
        -- these when the per-kind key is nil.
        oufAuraBorderStyle        = "flat",
        oufAuraUseBlizzardBorders = false,
        oufAuraBorderColor       = { r = 0, g = 0, b = 0, a = 0.8 },
        oufAuraBorderThickness   = 2,

        -- ── Per-kind aura border keys (v68) ─────────────────────────────
        -- Separate buff and debuff border settings, matching the
        -- Global Styles > Auras structure.  Global Styles writes these
        -- via UF_AURA_BORDER_MAP; the UF > Global > Auras options panel
        -- reads/writes them directly.  BOTH *Style and *UseBlizzardBorders
        -- must move together (same rule as the legacy shared keys).
        oufBuffBorderStyle           = "flat",
        oufBuffUseBlizzardBorders    = false,
        oufBuffBorderColor           = { r = 0, g = 0, b = 0, a = 0.8 },
        oufBuffBorderThickness       = 2,
        oufDebuffBorderStyle         = "flat",
        oufDebuffUseBlizzardBorders  = false,
        oufDebuffBorderColor         = { r = 0, g = 0, b = 0, a = 0.8 },
        oufDebuffBorderThickness     = 2,

        -- Stealable/purgeable buff border on target/focus/boss buffs
        -- (engine-driven via the 12.1 stealableFilter; restores the
        -- pre-12.1 stealable glow).
        oufAuraShowStealable     = true,
    },
}
