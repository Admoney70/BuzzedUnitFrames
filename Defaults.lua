-- ============================================================
-- LOAD-TIME HARNESS ORIGIN  (perf plan §L5.1)
-- Replaces the temporary 4d parse timer: same mechanism (one raw
-- debugprofilestop at the top of the first BF core file), but the value
-- now feeds LoadTiming.lua's mark buffer and `/bf loadreport` instead of
-- printing a single unattributed number.
--
-- This has to be a bare global table, not a BF field: BF does not exist
-- yet on the next line, and db.global (which gates everything else) does
-- not exist until RegisterDB. Cost is one table, one number.
--
-- KNOWN GAP: UnitFrames\oUFElements\{healthprediction,pingindicator}.lua
-- (19 KB) parse before this line. They are vendored-verbatim salvaged oUF
-- elements and are deliberately left untouched, so their parse is the only
-- BF chunk time the report cannot see.
-- ============================================================
BuzzardFrames_LoadTiming = { t0 = debugprofilestop(), marks = {} }
do
    local m = BuzzardFrames_LoadTiming.marks
    m[1] = { "chunk:origin", 0 }
end

-- ============================================================
-- BuzzardFrames: Defaults.lua
-- Creates the BF addon object and defines profile constructors,
-- default values, and spec data.
-- Must be loaded first (before Core.lua and Options.lua).
-- ============================================================
local addonName = "BuzzardFrames"

local BF = LibStub("AceAddon-3.0"):NewAddon(addonName,
    "AceEvent-3.0",
    "AceConsole-3.0"
)
_G["BuzzardFrames"] = BF

-- ── Client flavor / capability detection ────────────────────────
-- Set before anything else so every later file can branch on it.
--
-- BF.isRetail            true on Mainline (the addon's primary target).
-- BF.canCompileSnippets  true when the restricted environment can compile
--                        an `initialConfigFunction` attribute STRING into a
--                        secure snippet. On Classic builds that ship
--                        Blizzard_RestrictedAddOnEnvironment without an
--                        untainted loadstring, RestrictedExecution.lua
--                        errors with "attempt to call a nil value" the
--                        moment a SecureGroupHeader creates its first
--                        child. BFLayout.lua uses the Lua-side child
--                        configuration path instead when this is false.
-- BF.hasSpecializations  true when GetSpecialization/GetSpecializationInfo
--                        exist (absent on Classic Era -- no talent specs).
BF.isRetail = (not WOW_PROJECT_ID) or (WOW_PROJECT_ID == (WOW_PROJECT_MAINLINE or -1))
BF.canCompileSnippets = BF.isRetail
BF.hasSpecializations = (type(_G.GetSpecialization) == "function")
    and (type(_G.GetSpecializationInfo) == "function")

-- No-op stubs for the §L5 load/switch harness. LoadTiming.lua (the very
-- next file in the .toc) replaces every one of them with the real
-- collector. They exist so that the ~90 mark call sites scattered through
-- the addon can call `self:LoadMark(...)` unguarded and still be safe if
-- LoadTiming.lua is ever dropped from the .toc -- an instrumentation file
-- must never be able to break the addon.
do
    local function noop() end
    for _, k in ipairs({
        "LoadMark", "LoadMarkD", "LoadMarkDv", "LoadUASCTag", "LoadUASCBegin",
        "LoadUASCEnd", "LoadOUFCounts", "SealLoadReport", "ArmLoadReportSeal",
        "SwitchBegin", "SwitchMark", "SwitchCountLayouts", "SwitchPendingTail",
        "SwitchFlush", "SwitchSecureSwallow",
    }) do
        BF[k] = noop
    end
end

-- ── ENGINE GATE (REMOVED v67) ─────────────────────────────────────────────
-- BF._useAuraContainers was a feature-detect of AuraContainerSortMethod (a
-- 12.1+ export) that let one build serve both 12.1 and 12.0.7. The addon is
-- 12.1-only from v67, so the flag is permanently true and every branch on it
-- has been collapsed to its 12.1 arm.
--
-- Do NOT reintroduce it. The AuraContainer engine is now assumed
-- unconditionally: aura rendering, the oUF aura path and the default profiles
-- below all depend on it, and there is no surviving 12.0.7 code for a gate to
-- select. The .toc is `## Interface: 120100`.

-- Deep copy a table recursively
function BF:DeepCopy(orig)
    local copy = {}
    for k, v in pairs(orig) do
        copy[k] = type(v) == "table" and self:DeepCopy(v) or v
    end
    return copy
end

-- Helper: create a player/target unit frame profile sub-table
-- anchorX/anchorY are absolute BOTTOMLEFT screen coords (GetLeft/GetBottom on 1920x1080).
-- unit: "player" or "target" (controls default text anchor sides)
function BF:CreateUnitFrameProfile(anchorX, anchorY, unit)
    local isPlayer = (unit == "player")
    return {
        -- Position / visibility
        anchorX             = anchorX or 0,
        anchorY             = anchorY or -300,
        frameScale          = 1.0,
        frameAlpha          = 1.0,
        -- Bar dimensions
        frameWidth          = 150,
        nameBarHeight       = 12,
        healthBarHeight     = 22,
        powerBarHeight      = 12,
        -- Icon
        iconSize            = 56,
        iconScale           = 1.0,
        iconBorderThickness = 3,
        -- Health text
        showHealthPct       = true,
        showHealthPctSymbol = true,
        showHealthVal       = true,
        healthFontSize      = 10,
        -- Player: pct RIGHT, val LEFT.  Target: pct LEFT, val RIGHT.
        -- Val text x=0 means "aligned with other bars" (dynamic compensation
        -- from the circular icon inset is added at layout time).
        healthPctPos        = isPlayer and { point = "RIGHT", x = -3,  y = 0 } or { point = "LEFT",  x = 3,   y = 0 },
        healthValPos        = isPlayer and { point = "LEFT",  x = 0,   y = 0 } or { point = "RIGHT", x = 0,   y = 0 },
        -- Power bar visibility (per-frame). Alpha-only: fades the bar
        -- StatusBar + border to 0 so the bar disappears visually but
        -- the layout, chord insets, and bar positions stay unchanged.
        -- When BOTH showPowerBar AND showPowerText are false the oUF
        -- Power element is DisableElement'd (events unregistered, zero
        -- CPU). See _ApplyOUFPowerElementState in oUF_Shared.lua.
        showPowerBar        = true,
        -- Power text master switch (per-frame). When false, both Pct and
        -- Val text hide regardless of showPowerPct / showPowerVal. When
        -- BOTH showPowerBar AND showPowerText are false, the oUF Power
        -- element is DisableElement'd (events unregistered, zero CPU).
        showPowerText       = true,
        -- Power text (individual gates under showPowerText)
        showPowerPct        = true,
        showPowerPctSymbol  = true,
        showPowerVal        = true,
        powerFontSize       = 10,
        powerPctPos         = isPlayer and { point = "RIGHT", x = -3,  y = 0 } or { point = "LEFT",  x = 3,   y = 0 },
        powerValPos         = isPlayer and { point = "LEFT",  x = 0,   y = 0 } or { point = "RIGHT", x = 0,   y = 0 },
        -- Name bar visibility (per-frame). Alpha-only: fades the strip
        -- background + border to 0 so the strip disappears visually but
        -- the layout, chord insets, and bar positions stay unchanged.
        -- See _ApplyOUFNameBarState in oUF_Shared.lua.
        showNameBar         = true,
        -- Name bar text master switch (per-frame). When false, name +
        -- level + raid-group text all hide regardless of their
        -- individual showName / showLevel / showRaidGroup toggles.
        showNameBarText     = true,
        -- Name bar text
        showName            = true,
        showLevel           = true,
        hideLevelAtMax      = false,
        nameFontSize        = 11,
        levelFontSize       = 10,
        -- Cast bar font size. Target and Focus are the only units with a
        -- cast bar, but the key is emitted for every unit profile so the
        -- options panel has ONE default to read and reset to. Absent until
        -- now, which is why the Ace getter's `or 8` was reachable while
        -- oUF_Castbar.lua rendered at `or 10` -- the panel said 8 and the
        -- frame drew 10 on every untouched profile.
        castBarFontSize     = 10,
        -- Player: name LEFT-anchored, level RIGHT-anchored. Target: mirrored.
        -- nameOffsetX=0 means "aligned with val text" (dynamic compensation added at layout time).
        nameOffsetX         = 0,
        nameOffsetY         = 0,
        levelOffsetX        = isPlayer and -4  or 4,
        levelOffsetY        = 0,
        -- Colors
        useClassColor       = true,
        healthColor         = { r = 0.24, g = 0.78, b = 0.24 },
        usePowerTypeColor   = true,
        powerColor          = { r = 0.0, g = 0.44, b = 0.87 },
        useClassColorName   = false,
        nameColor           = { r = 1.0,  g = 1.0,  b = 1.0  },
        levelColor          = { r = 1.0,  g = 0.82, b = 0.0  },
        useHostilityColor     = not isPlayer,
        useHostilityColorName = not isPlayer,
        npcNameColor        = { r = 1.0,  g = 1.0,  b = 1.0  },
        -- Auras (player defaults to hidden; target/focus default to shown)
        -- Keys are prefixed with the unit name so _ApplyOUFRightFrameLayout
        -- can look them up generically as pf[unit.."ShowBuffs"] etc.
        [unit.."ShowBuffs"]     = not isPlayer,
        [unit.."BuffSize"]      = 18,
        [unit.."BuffsPerRow"]   = 8,
        -- v67: 32 -> 16. Boss overrides this to 8 in Defaults_UnitFrames.lua --
        -- boss frames stack vertically and their overhead maths
        -- (oUF_BossFrames.lua) derives the aura block from icon SIZE only, never
        -- from max/per-row, so anything that wraps past one row overlaps the
        -- frame below.
        [unit.."MaxBuffs"]      = 16,
        [unit.."BuffSpacing"]   = isPlayer and 2 or 1,
        [unit.."BuffOffsetX"]   = 0,
        [unit.."BuffOffsetY"]   = isPlayer and 0 or -1,
        [unit.."ShowDebuffs"]   = not isPlayer,
        [unit.."DebuffSize"]    = 18,
        [unit.."DebuffsPerRow"] = 8,
        [unit.."MaxDebuffs"]    = 16,   -- v67, see MaxBuffs above
        [unit.."DebuffSpacing"] = 2,
        [unit.."DebuffOffsetX"] = 0,
        [unit.."DebuffOffsetY"] = 0,
        -- Raid Group indicator (player frame only)
        showRaidGroup       = isPlayer and true or nil,
        raidGroupNumberOnly = isPlayer and false or nil,
        raidGroupFontSize   = isPlayer and 11 or nil,
        raidGroupOffsetX    = isPlayer and 0 or nil,
        raidGroupOffsetY    = isPlayer and 0 or nil,
        raidGroupColor      = isPlayer and { r = 1, g = 1, b = 1 } or nil,
    }
end

-- Helper: create a raid profile sub-table with default settings
--
-- Aura-section keys are nested in the `auras` sub-table (v27 rollout).
-- Readers must use BF:GetAurasSubcatProfile(subcat, flat) to resolve them --
-- never read them off the flat root, and never via
-- GetSectionProfile("auras", flat), which errors as of v60 (the section's two
-- halves have independent per-Layout toggles, so no whole-section answer is
-- correct for both). auraText/tooltip/AC-owned keys
-- stay at the flat root where they historically lived; their runtime
-- readers already route through those sections' own getters and the
-- flat-root copies are nilled by prior migrations (v15 auraText,
-- v24 suppressPrivateAuraTooltip).
function BF:CreateRaidProfile(anchorX, anchorY)
    return {
        frameWidth = 65,
        frameHeight = 50,
        enableFrameScale = false,
        frameScale = 1.0,
        scaleIndicators = true,
        frameSpacingH = 0,
        frameSpacingV = 0,
        anchorX = anchorX or -120,
        anchorY = anchorY or -80,
        raidLayoutAnchor = "TOPLEFT",
        showGroup = { true, true, true, true, true, true, true, true },
        -- Auto Hide Groups by Instance Size. When true, showGroup is not
        -- consulted at all and group visibility follows the instance's own
        -- capacity instead -- see BF:GetGroupVisibilityRule (Core_ProfileAPI).
        -- The user's showGroup entries are left untouched underneath, so
        -- turning this back off restores exactly what they had.
        autoHideGroupsByInstance = false,
        testMode = false,
        -- Pet frames
        showPetFrames    = false,
        petFrameWidth    = 65,
        petFrameHeight   = 30,
        petFrameSpacing  = 0,
        petFrameAnchorX  = 0,
        petFrameAnchorY  = -300,
        petMaxColumns    = 2,   -- raid default: 2 columns × 5 = 10 pets
        petUnitsPerColumn = 5,

        -- ── Aura-section keys (v27: nested under `auras`) ─────────────
        auras = {
            -- Buffs
            showBuffs                   = true,
            buffSize                    = 12,
            buffsPerRow                 = 3,
            maxBuffs                    = 6,
            buffGrowDirection           = "LEFT_UP",
            buffAnchorPoint             = "BOTTOMRIGHT",
            buffOffsetX                 = 0,
            buffOffsetY                 = 0,
            buffSpacing                 = 1,
            buffRowSpacing              = 0,
            buffBorderColor             = { r = 0, g = 0, b = 0, a = 0.8 },
            -- v67: kept in lockstep with the authoritative copy in
            -- Defaults_RaidPartyFrames.lua. This flat-keyed template is
            -- vestigial for auras (reads resolve through
            -- GetAurasSubcatProfile, which needs a nested auras[subcat]
            -- table and so always falls through to the rpDB globals), but
            -- it is a real second source of these numbers -- letting the
            -- two drift is how a future reader ends up trusting the wrong
            -- one. "flat" is the Square literal; see the note there.
            buffBorderThickness         = 2,
            buffBorderStyle             = "flat",
            buffBlizzardBorders         = false,
            -- Debuffs
            showDebuffs                 = true,
            debuffSize                  = 12,
            debuffsPerRow               = 3,
            maxDebuffs                  = 3,
            -- v65: raid debuffs anchor BOTTOMLEFT, matching party. The grow
            -- direction moves with it: BOTTOMLEFT's default is RIGHT_UP
            -- (BF.GROW_DEFAULT_FOR_ANCHOR), and leaving RIGHT_DOWN against a
            -- bottom-anchored point would grow the rows downward, off the
            -- frame.
            -- v67: 12.0.7 branch removed (addon is 12.1-only).
            debuffGrowDirection         = "RIGHT_UP",
            debuffAnchorPoint           = "BOTTOMLEFT",
            debuffOffsetX               = 0,
            debuffOffsetY               = 0,
            debuffSpacing               = 1,
            debuffRowSpacing            = 0,
            debuffBorderColor           = { r = 0, g = 0, b = 0, a = 0.8 },
            debuffDispelBorderThickness = 2,
            -- v71: color the whole border by the aura's dispel type (default on);
            -- typeless debuffs keep the configured Border Color.
            debuffColorBorderByDispel   = true,
            -- v71: dispel-type corner icon (off by default; % of icon size).
            showDebuffDispelTypeIcon    = false,
            debuffDispelTypeIconScale   = 40,
            debuffBorderThickness       = 2,   -- v67, see buffs above
            debuffBorderStyle           = "flat",
            debuffBlizzardBorders       = false,
            -- Private Auras
            -- Big Def
            showBigDef                  = true,
            bigDefSize                  = 18,
            bigDefAnchor                = "CENTER",
            bigDefOffsetX               = 0,
            bigDefOffsetY               = 0,
            bigDefMaxCount              = 1,
            bigDefGrowDirection         = "RIGHT_DOWN",
            bigDefIconsPerRow           = 5,
            bigDefSpacing               = 1,
            bigDefRowSpacing            = 1,
            bigDefShowGlow              = false,
            bigDefBorderColor           = { r = 0, g = 0, b = 0, a = 0.8 },
            bigDefBorderThickness       = 2,   -- v67, see buffs above
            bigDefBorderStyle           = "flat",
            bigDefBlizzardBorders       = false,
            -- v69: the Crowd Control block was removed with the feature. This
            -- is a WireFlatDefaults __index template, not saved data, and it
            -- had no reader left -- dropped alongside the real defaults in
            -- Defaults_RaidPartyFrames.lua so the two copies do not drift.
            -- Dispel Indicator
            showDispelIndicator         = true,
            dispelIndicatorSize         = 14,
            dispelIndicatorPosition     = "TOPRIGHT",
            dispelIndicatorOffsetX      = 0,
            dispelIndicatorOffsetY      = 0,
            dispelIndicatorStyle        = "icon",
        },

        -- ── auraText-section keys (live in rpDB.profile.auraText at runtime) ──
        -- v15 migration moved the authoritative copies into rpDB.profile.auraText.
        -- These flat-root copies are retained for sparse-storage / template
        -- symmetry but are not read at runtime.
        showBuffDuration         = true,
        buffTimerScale           = 1.0,
        reverseBuffSwipe         = false,
        disableBuffSwipe         = false,
        disableBuffSpark         = false,
        showDebuffDuration       = true,
        debuffTimerScale         = 1.0,
        reverseDebuffSwipe       = false,
        disableDebuffSwipe       = false,
        disableDebuffSpark       = false,
        showBigDefDuration       = false,
        bigDefTimerScale         = 1.0,
        -- v69: showCrowdControlDuration / crowdControlTimerScale removed with
        -- the Crowd Control feature (template copies, never read).

        -- tooltips-section (v24 migration moved to rpDB.profile.tooltips)

        -- AuraCustomizations territory -- stays flat-root
        customBuffContainers     = {},
        customDebuffContainers   = {},
    }
end

-- Helper: create a party profile sub-table with default settings
function BF:CreatePartyProfile()
    return {
        frameWidth    = 100,
        frameHeight   = 70,
        enableFrameScale = false,
        frameScale    = 1.0,
        scaleIndicators = true,
        frameSpacing  = 0,
        -- growDirection moved to rpDB.profile.sorting.growDirection in the
        -- Frames - Sorting section refactor. Do not re-add here.
        testMode      = false,
        anchorX       = -260,
        anchorY       = -200,
        partyLayoutAnchor = "TOPLEFT",
        -- Pet frames
        showPetFrames    = false,
        petShowSolo      = false,
        petFrameWidth    = 100,
        petFrameHeight   = 50,
        petFrameSpacing  = 0,
        petFrameAnchorX  = 0,
        petFrameAnchorY  = -300,
        petMaxColumns    = 1,   -- party: 1 column of 5 (max 5 pets)
        petUnitsPerColumn = 5,
        -- Buffs
        showBuffs          = true,
        buffSize           = 14,
        buffsPerRow        = 3,
        maxBuffs           = 6,
        buffGrowDirection  = "LEFT",
        buffAnchorPoint    = "BOTTOMRIGHT",
        buffOffsetX        = 0,
        buffOffsetY        = 0,
        buffSpacing        = 1,
        buffRowSpacing     = 0,
        showBuffDuration   = true,
        buffTimerScale     = 1.0,
        reverseBuffSwipe   = false,
        disableBuffSwipe   = false,
        disableBuffSpark   = false,
        -- Debuffs
        showDebuffs         = true,
        debuffSize          = 14,
        debuffsPerRow       = 3,
        maxDebuffs          = 3,
        debuffGrowDirection = "RIGHT",
        debuffAnchorPoint   = "BOTTOMLEFT",
        debuffOffsetX       = 0,
        debuffOffsetY       = 0,
        debuffSpacing       = 1,
        debuffRowSpacing    = 0,
        showDebuffDuration  = true,
        debuffTimerScale    = 1.0,
        reverseDebuffSwipe  = false,
        disableDebuffSwipe  = false,
        disableDebuffSpark  = false,
        -- Private Auras
        -- Big Def
        showBigDef           = true,
        bigDefSize           = 18,
        bigDefAnchor         = "CENTER",
        bigDefOffsetX        = 0,
        bigDefOffsetY        = 0,
        bigDefMaxCount       = 1,
        bigDefGrowDirection  = "RIGHT",
        bigDefIconsPerRow    = 5,
        bigDefSpacing        = 1,
        bigDefRowSpacing     = 1,
        showBigDefDuration   = false,
        bigDefTimerScale     = 1.0,
        bigDefShowGlow       = false,
        -- v69: the Crowd Control block was removed with the feature (legacy
        -- flat-root template copy, no reader).
        -- Group Ordering
        customGroupOrdering = false,
        -- groupOrderingMode moved to rpDB.profile.sorting.groupOrderingMode
        -- in the Frames - Sorting section refactor. Do not re-add here.
        -- Dispel Indicator
        showDispelIndicator     = true,
        dispelIndicatorSize     = 14,
        dispelIndicatorPosition = "TOPRIGHT",
        dispelIndicatorOffsetX  = 0,
        dispelIndicatorOffsetY  = 0,
        dispelIndicatorStyle    = "icon",
        -- Custom Buff Containers
        customBuffContainers    = {},
        -- Custom Debuff Containers (separate, preset-only, HARMFUL)
        customDebuffContainers  = {},
    }
end

-- Helper: create a flat layout seeded from CreatePartyProfile.
-- Used by Defaults_RaidPartyFrames.lua for fresh-install flatLayouts
-- entries ("Layouts by Instance Type" Phase 1). The returned table has
-- the party profile keys at the top level plus a `name` field — it is
-- NOT wrapped in a party/raidNN sub-table.
function BF:CreateFlatPartyLayout(name)
    local t = self:CreatePartyProfile()
    t.name = name
    t.type = "party"
    return t
end

-- Helper: create a flat layout seeded from CreateRaidProfile.
-- Same shape as CreateFlatPartyLayout but for raid defaults.
function BF:CreateFlatRaidLayout(name, anchorX, anchorY)
    local t = self:CreateRaidProfile(anchorX or -260, anchorY or -200)
    t.name = name
    t.type = "raid"
    return t
end

BF.defaults = {
    global = {
        minimapIcon = { hide = false },
        -- Dev-only: print layout-reload timings (per-layout section toggle,
        -- and LoadLayout's deferred tail) to the chat frame.
        -- UI: Preview & Special Options > Experimental Options >
        --     Print Layout Timings (needs Enable Experimental Options).
        -- Or: /run BuzzardFrames.db.global.debugTiming = true
        debugTiming = false,
        -- Perf plan §L5.1: collect the FINE-GRAINED login marks (per
        -- Build*Options, per RegisterDB step, per aura-cache pass) as well
        -- as the always-on phase boundaries. Needs a /reload to take
        -- effect -- most of what it gates runs before you can type.
        -- Read by `/bf loadreport`; debugTiming implies it.
        debugLoadReport = false,
        optionsPanelWidth = nil,  -- persisted panel width; nil = use default (820)

        -- ── Options panel / UI chrome ─────────────────────────────────────
        _optionsPanelW = nil,
        _optionsPanelH = nil,
        minimapPos = 200,
        enableExperimentalOptions = false,
        tinyHandle = false,
        -- Kill switch for rebuilding aura displays live inside an active
        -- keystone (restricted, out of combat) instead of deferring the
        -- restyle to key end. Each rebuild leaks its old pooled buttons until
        -- /reload (capped). "/bf recreate on|off|status". See
        -- BF:IsAuraRecreateWindow in Auras/ContainerFactory.lua.
        auraRecreateInKey = true,

        -- ── Preview / setup mode ──────────────────────────────────────────
        -- v70: the old showPreviewAuras (on/off) + simulateDispellableDebuff
        -- toggles are replaced by a per-tab "Preview" dropdown. Two independent
        -- account-wide values: the Buffs tab's dropdown and the Debuffs tab's
        -- dropdown. Whichever aura tab is being viewed decides what the preview
        -- shows (BF:GetActivePreviewMode resolves the active tab). Values:
        -- "all", "allDispel", "buffs", "debuffs", "debuffsDispel" (see
        -- BF.PREVIEW_MODE_MAP in DummyAuras.lua). Owner ruling 2026-08-15:
        -- each tab defaults to previewing ITS OWN aura kind -- Buffs tab shows
        -- buffs only, Debuffs tab shows debuffs with the dispellable
        -- simulation active. (The original defaults were "all"/"allDispel",
        -- preserving the pre-v70 both-shown behavior.)
        previewModeBuffs        = "buffs",
        previewModeDebuffs      = "debuffsDispel",
        -- Aura Cooldown Text: both kinds, since its settings cover both.
        previewModeAuraText     = "all",
        previewBuffCount        = 6,
        previewDebuffCount      = 3,
        showDummyBuffs          = true,
        showDummyDebuffs        = true,
        showDummyBigDef         = true,
        -- v69: showDummyCrowdControl removed with the Crowd Control feature.
        -- It had no reader left, but it was still DECLARED here -- and AceDB's
        -- copyDefaults rawsets declared defaults straight back into the table,
        -- so the load-time purge in Core_DB could not have removed it durably
        -- while this line stood. (showDummyImportant / showDummyPrivateAuras /
        -- previewPrivateAuraCount were never declared, so purging those is
        -- durable on its own.)
        showSetupGrid           = true,
        showPreview             = true,
        -- Boss frame preview (Unit Frames > Boss Frames > Preview): shown
        -- whenever the options panel is open, like showPreview; per-slot
        -- Enemy / Friendly. Global, so neither travels with a profile.
        showBossPreview         = false,
        bossPreviewFriendly     = { false, false, false, true, true },
        setupFrameColor         = { r = 0.15, g = 0.35, b = 0.7 },

        -- ── Setup mode ────────────────────────────────────────────────────
        -- New single-boolean setup mode flag. Replaces the four legacy
        -- tier-specific flags below. See Docs/SETUP_MODE_MIGRATION.md.
        setupModeActive = false,

        -- ── Legacy test mode flags (kept for rollback) ────────────────────
        -- No longer read at runtime. A one-shot login bridge in
        -- Initialization.lua:OnEnable flips setupModeActive on when any of
        -- these are true on first login after migration, so users in setup
        -- mode at the time of upgrade resume correctly. Scheduled for
        -- removal in a future MigrateSetupModeCleanup pass.
        partyTestMode = false,
        raid40TestMode = false,
        raid30TestMode = false,
        raid20TestMode = false,

        -- ── Test / debug toggles ──────────────────────────────────────────
        testAggroHighlight   = false,
        testReadyCheck       = false,
        testPhased           = false,
        testSummonPending    = false,
        testResurrectPending = false,
        testVehicleIcon      = false,
        testHealPrediction   = false,
        testHealAbsorb       = false,
        testAbsorb           = false,
        testAbsorbSize       = "medium",
        testReducedMaxHealth = false,
        testCyrillicNames    = false,

        -- ── Experimental / gated settings ─────────────────────────────────
        privateAuraBorderHideFirstSlot = false,
        privateAuraBorderDrawOrder     = "first",
        -- privateAuraBorderScale, privateAuraBorderWidthRatio, and
        -- privateAuraBorderFrameLevel relocated out of db.profile. See
        -- Docs/PHASE_3_PLAN.md §18 for the new namespace split
        -- (rpDB for Icon Border Scale, acDB for the Frame Border widgets).

        -- ── Profile auto-switch ───────────────────────────────────────────
        enableProfileAutoSwitch = false,
        profileAutoSwitchMode   = "spec",
        specProfileAssignment   = {},
        roleProfileAssignment   = {
            HEALER  = nil,
            TANK    = nil,
            DAMAGER = nil,
        },

        -- ── Aura filter / behavior (not part of exportable modules) ───────
        nonHealerBuffFilter    = "player_raid_combat",  -- LEGACY: kept for users who haven't run AC migration yet
        debuffFilter           = "HARMFUL",       -- LEGACY: kept for users who haven't run AC migration yet
        -- pvpSwapDebuffsPrivate relocated to rpDB.profile.auras.privateAuras.pvpSwapDebuffsPrivateBattleground
        -- (and the per-flat equivalent on raid flats). See Docs/PHASE_3_PLAN.md §17.6.
        reverseBuffs           = false,

        -- ── Raid/Party Frames root-level (not part of exportable module) ──
        partyFramesEnabled = true,
        raidFramesEnabled  = true,
        locked             = true,
        hideBlizzardParty  = true,
        hideBlizzardRaid   = true,
        hideBlizzardRaidManager = false,
    },
    profile = {
        -- ══════════════════════════════════════════════════════════════════
        -- Most raid/party frame keys have been MIGRATED to the
        -- RaidPartyFrames namespace (Defaults_RaidPartyFrames.lua)
        -- as of dbVersion 15. The canonical defaults live there.
        --
        -- Other modules:
        --   UnitFrames        → UnitFrames/Defaults_UnitFrames.lua
        --   AuraCustomizations → AuraCustomizations/Defaults_AuraCustomizations.lua
        --   CustomFrameGroups  → CustomFrameGroups/Defaults_CustomFrameGroups.lua
        --   IncomingCasts      → IncomingCasts/Defaults_IncomingCasts.lua
        --
        -- Global settings (test mode, preview, debug, profile auto-switch,
        -- aura filters, enable/lock/hide toggles) live in db.global above.
        -- ══════════════════════════════════════════════════════════════════

        -- Legacy per-tier sub-tables kept as empty {} so migration code
        -- that reads p.raid40.locked etc. doesn't nil-error on old profiles.
        raid40 = {},
        raid30 = {},
        raid20 = {},
    }
}

-- ============================================================
-- SPEC / ROLE FILTER DATA  (WoW 12.0 specializations)
-- ============================================================
-- Each entry:
--   { id=specID, name="Display Name", icon="Interface\\Icons\\...",
--     role="HEALER"|"TANK"|"DAMAGER", class="UPPERCASE_CLASS_TOKEN" }
--
-- ARRAY ORDER IS ALPHABETICAL BY DISPLAY NAME and load-bearing: several option
-- surfaces render this list in array order (Options_Layouts, Options_UFLayouts,
-- the Single Buffs Conditions spec list). Add new specs in their alphabetical
-- slot; do NOT regroup this table by class. Anything that wants class grouping
-- builds its own index off the `class` field.
--
-- `class` matches CLASS_SORT_ORDER / SecureGroupHeaderTemplate tokens, so it
-- keys straight into RAID_CLASS_COLORS and LOCALIZED_CLASS_NAMES_MALE. It is
-- the SINGLE source of the spec->class mapping -- CustomFrameGroups\CustomFrames.lua
-- used to carry a second hardcoded copy and now reads this field instead.
BF.specData = {
    { id=265, name="Affliction",     icon="Interface\\Icons\\Spell_Shadow_DeathCoil",                role="DAMAGER", class="WARLOCK" },
    { id=62,  name="Arcane",         icon="Interface\\Icons\\Spell_Holy_MagicalSentry",              role="DAMAGER", class="MAGE" },
    { id=71,  name="Arms",           icon="Interface\\Icons\\Ability_Warrior_SavageBlow",            role="DAMAGER", class="WARRIOR" },
    { id=259, name="Assassination",  icon="Interface\\Icons\\Ability_Rogue_DeadlyBrew",              role="DAMAGER", class="ROGUE" },
    { id=1473, name="Augmentation",  icon="Interface\\Icons\\ClassIcon_Evoker_Augmentation",         role="DAMAGER", class="EVOKER" },
    { id=102, name="Balance",        icon="Interface\\Icons\\Spell_Nature_StarFall",                 role="DAMAGER", class="DRUID" },
    { id=253, name="Beast Mastery",  icon="Interface\\Icons\\Ability_Hunter_BeastMastery",           role="DAMAGER", class="HUNTER" },
    { id=250, name="Blood",          icon="Interface\\Icons\\Spell_DeathKnight_BloodPresence",       role="TANK", class="DEATHKNIGHT" },
    { id=268, name="Brewmaster",     icon="Interface\\Icons\\Monk_Stance_DrunkenOx",                 role="TANK", class="MONK" },
    { id=266, name="Demonology",     icon="Interface\\Icons\\Spell_Shadow_Metamorphosis",            role="DAMAGER", class="WARLOCK" },
    { id=267, name="Destruction",    icon="Interface\\Icons\\Spell_Shadow_RainOfFire",               role="DAMAGER", class="WARLOCK" },
    { id=1467, name="Devastation",   icon="Interface\\Icons\\ClassIcon_Evoker_Devastation",          role="DAMAGER", class="EVOKER" },
    { id=1480, name="Devourer",      icon="Interface\\Icons\\Classicon_demonhunter_void",            role="DAMAGER", class="DEMONHUNTER" },
    { id=256, name="Discipline",     icon="Interface\\Icons\\Spell_Holy_PowerWordShield",            role="HEALER", class="PRIEST" },
    { id=262, name="Elemental",      icon="Interface\\Icons\\Spell_Nature_Lightning",                role="DAMAGER", class="SHAMAN" },
    { id=263, name="Enhancement",    icon="Interface\\Icons\\Spell_Nature_LightningShield",          role="DAMAGER", class="SHAMAN" },
    { id=103, name="Feral",          icon="Interface\\Icons\\Ability_Druid_CatForm",                 role="DAMAGER", class="DRUID" },
    { id=63,  name="Fire",           icon="Interface\\Icons\\Spell_Fire_FireBolt02",                 role="DAMAGER", class="MAGE" },
    { id=251, name="Frost DK",       icon="Interface\\Icons\\Spell_Deathknight_FrostPresence",       role="DAMAGER", class="DEATHKNIGHT" },
    { id=64,  name="Frost Mage",     icon="Interface\\Icons\\Spell_Frost_FrostBolt02",               role="DAMAGER", class="MAGE" },
    { id=72,  name="Fury",           icon="Interface\\Icons\\Ability_Warrior_InnerRage",             role="DAMAGER", class="WARRIOR" },
    { id=104, name="Guardian",       icon="Interface\\Icons\\Ability_Racial_BearForm",               role="TANK", class="DRUID" },
    { id=577, name="Havoc",          icon="Interface\\Icons\\Ability_DemonHunter_SpecDPS",           role="DAMAGER", class="DEMONHUNTER" },
    { id=65,  name="Holy Paladin",   icon="Interface\\Icons\\Spell_Holy_HolyBolt",                   role="HEALER", class="PALADIN" },
    { id=257, name="Holy Priest",    icon="Interface\\Icons\\Spell_Holy_GuardianSpirit",             role="HEALER", class="PRIEST" },
    { id=254, name="Marksmanship",   icon="Interface\\Icons\\Ability_Hunter_FocusedAim",             role="DAMAGER", class="HUNTER" },
    { id=270, name="Mistweaver",     icon="Interface\\Icons\\Monk_Stance_WiseSerpent",               role="HEALER", class="MONK" },
    { id=260, name="Outlaw",         icon="Interface\\Icons\\Ability_Rogue_Waylay",                  role="DAMAGER", class="ROGUE" },
    { id=1468, name="Preservation",  icon="Interface\\Icons\\ClassIcon_Evoker_Preservation",         role="HEALER", class="EVOKER" },
    { id=66,  name="Protection Paladin", icon="Interface\\Icons\\Ability_Paladin_ShieldOfTheTemplar", role="TANK", class="PALADIN" },
    { id=73,  name="Protection Warrior", icon="Interface\\Icons\\Ability_Warrior_DefensiveStance",   role="TANK", class="WARRIOR" },
    { id=105, name="Restoration Druid", icon="Interface\\Icons\\Spell_Nature_HealingTouch",          role="HEALER", class="DRUID" },
    { id=264, name="Restoration Shaman", icon="Interface\\Icons\\Spell_Nature_MagicImmunity",        role="HEALER", class="SHAMAN" },
    { id=70,  name="Retribution",    icon="Interface\\Icons\\Spell_Holy_AuraOfLight",                role="DAMAGER", class="PALADIN" },
    { id=258, name="Shadow",         icon="Interface\\Icons\\Spell_Shadow_ShadowWordPain",           role="DAMAGER", class="PRIEST" },
    { id=261, name="Subtlety",       icon="Interface\\Icons\\Ability_Stealth",                       role="DAMAGER", class="ROGUE" },
    { id=255, name="Survival Hunter",icon="Interface\\Icons\\Ability_Hunter_Camouflage",             role="DAMAGER", class="HUNTER" },
    { id=252, name="Unholy",         icon="Interface\\Icons\\Spell_DeathKnight_UnholyPresence",      role="DAMAGER", class="DEATHKNIGHT" },
    { id=581, name="Vengeance",      icon="Interface\\Icons\\Ability_DemonHunter_SpecTank",          role="TANK", class="DEMONHUNTER" },
    { id=269, name="Windwalker",     icon="Interface\\Icons\\Spell_Monk_Windwalker_Spec",            role="DAMAGER", class="MONK" }

}

-- Build a lookup table: specID -> specData entry
BF.specByID = {}
for _, s in ipairs(BF.specData) do
    BF.specByID[s.id] = s
end