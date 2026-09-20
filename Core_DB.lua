-- ============================================================
-- BuzzardFrames: Core_DB.lua
-- AceDB registration + one-shot migrations.
--   • Creates six AceDB root databases: BuzzardFramesDB for global
--     cross-cutting state, and one per module
--     (BuzzardFrames<UnitFrames|AuraCustomizations|CustomFrameGroups
--     |RaidPartyFrames|IncomingCasts>DB) so each module can change its
--     profile independently. Previously (pre-v18) modules lived as
--     AceDB namespaces under the parent, which only allows lockstep
--     profile switching.
--   • Runs the inline pre-dbVersion-10 migrations and dispatches
--     the versioned migration blocks (versions 10-18).
-- The individual Migrate*Profile functions live in Core_Migrations.lua.
-- Extracted from Core.lua in the Core split refactor.
-- ============================================================
local BF = _G["BuzzardFrames"]

-- Current schema version for the main AceDB. The versioned-migration
-- dispatcher below runs every block whose number is > the stored
-- p.dbVersion. Bumping this value adds a new migration; callers that need
-- to gate fresh-profile setup (e.g. OnNewProfile) read this constant so
-- they can stamp new profiles directly at the current version and skip the
-- entire dispatcher.
--
-- 51..59 ARE DELIBERATELY UNUSED. Those nine numbers were nine separate
-- aura migrations written incrementally during 12.1 PTR testing; none of
-- them ever shipped, and they have been merged into the single `ver < 60`
-- block below. The numbers are NOT reused, because `p.dbVersion` is only
-- rewritten from INSIDE `if ver < DB_VERSION` -- so a profile that somehow
-- carries a PTR stamp of 51..59 would, under a lowered DB_VERSION, fail the
-- test, never be re-stamped, and silently skip every future migration up to
-- that number. Skipping the range costs nothing and closes that hole.
-- v91 (2026-08-17): 71 = the debuff priority list (unique ranks 1..7, the
-- Dispellable by Me / by Others split, the three Combine flags, and the
-- retirement of the allDispellable container preset).
-- v92 (2026-08-20): 72 = stable containerKey ("c_<n>") on every multi-icon
-- custom buff container, the identity a Single Buff's flow anchor references.
-- 2026-08-24: 76 = sweep the retired _bf_hasSotFSpell runtime flag out of
-- acDB SavedVariables (it lives in the weak BF._containerHasSotF map now).
-- 2026-08-25: 77 = purge the two Swiftmendable health-TEXT keys (no 12.1
-- path ever existed) and seed the Swiftmendable pseudo entry in the Buff List.
local DB_VERSION = 80

function BF:RegisterDB()
    -- Is this the user's very first session with the addon? Captured HERE,
    -- before AceDB:New creates the table, because that is the only moment the
    -- answer is unambiguous. Consumed by Core_Notifications (a first-time user
    -- must not be shown "what changed since a version you never ran").
    --
    -- Deliberately NOT OnNewProfile: that also fires when an EXISTING user
    -- creates an additional profile, which is not a new install at all.
    self._freshInstall = (_G.BuzzardFramesDB == nil)

    self.db = LibStub("AceDB-3.0"):New("BuzzardFramesDB", self.defaults, true)

    -- Fresh-profile shortcut: when AceDB creates a brand-new profile (no
    -- prior SavedVariables for it), stamp dbVersion at the current schema
    -- version immediately. The dispatcher below then sees ver == DB_VERSION
    -- on first read and skips every historical migration block — there is
    -- no legacy data to fix on a profile that didn't exist a moment ago.
    -- Existing profiles are unaffected: OnNewProfile only fires for genuinely
    -- new profiles, so their stored dbVersion still drives the dispatcher.
    self.db.RegisterCallback(self, "OnNewProfile", function(_, db)
        db.profile.dbVersion = DB_VERSION
    end)

    -- dbVersion 18: each module is its own top-level AceDB rather than an
    -- AceDB namespace under self.db. AceDB child namespaces cannot change
    -- profile independently (only :RegisterDefaults and :ResetProfile are
    -- exposed on them), so independent per-module profile switching requires
    -- independent root DBs. See Docs/MODULAR_PROFILES_PLAN.md.
    --
    -- Each DB uses "Default" as the default profile (third arg = true),
    -- matching the old namespace cascade behavior for fresh installs.
    self.ufDB  = LibStub("AceDB-3.0"):New("BuzzardFramesUnitFramesDB",         self.unitFrameDefaults,          true)
    self.acDB  = LibStub("AceDB-3.0"):New("BuzzardFramesAuraCustomizationsDB", self.auraCustomizationDefaults,  true)
    self.cfgDB = LibStub("AceDB-3.0"):New("BuzzardFramesCustomFrameGroupsDB",  self.customFrameGroupDefaults,   true)
    self.rpDB  = LibStub("AceDB-3.0"):New("BuzzardFramesRaidPartyFramesDB",    self.raidPartyFrameDefaults,     true)
    self.icDB  = LibStub("AceDB-3.0"):New("BuzzardFramesIncomingCastsDB",      self.incomingCastsDefaults,      true)
    -- §L5.1: six AceDB:New calls done (defaults merge per DB). db.global
    -- exists from here on, so every mark below can be a DETAIL mark.
    self:LoadMark("init:dbCreated")

    local p = self.db.profile
    
    -- Migrate sortingMode/strictGroupLayout/unitsPerColumn/horizontalGroups from
    -- per-tier sub-tables to the global profile (they became global settings).
    do
        local tiers = { p.raid40, p.raid30, p.raid20 }
        for _, t in ipairs(tiers) do
            if t then
                if t.sortingMode      ~= nil and p.sortingMode      == nil then p.sortingMode      = t.sortingMode      end
                if t.strictGroupLayout ~= nil and p.strictGroupLayout == nil then p.strictGroupLayout = t.strictGroupLayout end
                if t.unitsPerColumn   ~= nil and p.unitsPerColumn   == nil then p.unitsPerColumn   = t.unitsPerColumn   end
                if t.horizontalGroups ~= nil and p.horizontalGroups == nil then p.horizontalGroups = t.horizontalGroups end
                t.sortingMode       = nil
                t.strictGroupLayout = nil
                t.unitsPerColumn    = nil
                t.horizontalGroups  = nil
            end
        end
        if p.layouts then
            for _, layout in pairs(p.layouts) do
                for _, tier in pairs({ layout.raid40, layout.raid30, layout.raid20 }) do
                    if tier then
                        tier.sortingMode       = nil
                        tier.strictGroupLayout = nil
                        tier.unitsPerColumn    = nil
                        tier.horizontalGroups  = nil
                    end
                end
            end
        end
    end
    
    -- Migrate old privateAuraScale settings to new privateAuraSize settings
    if p.raidPrivateAuraScale and not p.raid40.privateAuraSize then
        -- Convert scale to size: size = debuffSize * scale
        local baseSize = p.raid40.debuffSize or 12
        p.raid40.privateAuraSize = math.floor(baseSize * p.raidPrivateAuraScale + 0.5)
        p.raidPrivateAuraScale = nil  -- Remove old setting
    end
    if p.partyPrivateAuraScale and not p.partyPrivateAuraSize then
        local baseSize = p.partyDebuffSize or 14
        p.partyPrivateAuraSize = math.floor(baseSize * p.partyPrivateAuraScale + 0.5)
        p.partyPrivateAuraScale = nil  -- Remove old setting
    end
    
    -- Stamp Initialized flags on any layout tiers that already have saved data.
    -- This migration ensures existing users' customized tiers are recognized as
    -- valid donors for InitRaidTier, rather than being treated as "never enabled".
    if p.layouts then
        for _, layout in pairs(p.layouts) do
            if layout.raid40 then layout.raid40Initialized = true end
            if layout.raid30 then layout.raid30Initialized = true end
            if layout.raid20 then layout.raid20Initialized = true end
        end
    end

    -- ── Purge orphaned SavedVariables keys from v2.3.10 and earlier ──────────
    -- These keys were written by Misc > Special Options > Private Aura Testing
    -- and the old per-raid/party border/overlay options.  The settings they
    -- controlled are now handled by encounterPrivateAura / dungeonPrivateAura,
    -- so stale values in SavedVariables can no longer be read or overridden by
    -- the new code.  Nil them out once here so they don't linger forever.
    do
        local p = self.db.profile

        -- Top-level profile keys
        BF.db.global.privateAuraBorderDrawOrder     = nil
        BF.db.global.privateAuraBorderHideFirstSlot = nil
        -- Ensure private aura swipe is on by default; old SavedVars may have stored true
        if p.disablePrivateAuraSwipe == true then p.disablePrivateAuraSwipe = false end

        -- Purge old hideFirstSlot key (renamed to hideFirstSlotBorder).
        if p.encounterPrivateAura then
            for _, ep in pairs(p.encounterPrivateAura) do
                ep.hideFirstSlot = nil
            end
        end
        if p.dungeonPrivateAura then
            p.dungeonPrivateAura.hideFirstSlot = nil
        end

        -- Per-layout raid/party sub-table keys
        local function purgeLayoutProfile(lp)
            if not lp then return end
            lp.showPrivateAuraFrameBorder  = nil
            lp.privateAuraFrameBorderScale = nil
            lp.showPrivateAuraOverlay      = nil
            lp.privateAuraOverlayOffsetX   = nil
            lp.privateAuraOverlayOffsetY   = nil
            lp.privateAuraOverlayScale     = nil
        end
        for _, layout in pairs(p.layouts or {}) do
            purgeLayoutProfile(layout.raid40)
            purgeLayoutProfile(layout.raid30)
            purgeLayoutProfile(layout.raid20)
            purgeLayoutProfile(layout.party)
        end
    end

    -- v72 (perf plan L1.6 D1): a SECOND, byte-identical-minus-12-lines copy of
    -- the purge block above used to sit here and ran on every single login. It
    -- was a strict subset — same `p`, same `p.layouts`, same idempotent key-nils,
    -- lacking only the disablePrivateAuraSwipe normalization and the two
    -- hideFirstSlot nils that the block above already performs — so it could
    -- never change a stored value. Deleted; do not re-add.

    -- ── Purge old private aura customization keys (renamed in v2.4) ──────────
    -- encounterPrivateAura / dungeonPrivateAura were renamed to
    -- encounterPASettings / dungeonPASettings to force a clean slate.
    -- privateAuraBorderHideEncounterIDs was removed entirely.
    do
        local p = self.db.profile
        p.encounterPrivateAura            = nil
        p.dungeonPrivateAura              = nil
        p.privateAuraBorderHideEncounterIDs = nil
    end

    -- (Profile callbacks are registered at the end of RegisterDB, after the
    -- v18 migration block completes, so OnProfileChanged does not fire on
    -- half-migrated state. Registration targets the five module DBs rather
    -- than self.db, because under v18 profile switching happens on modules.)

    -- Always start with test mode off after a reload
    local p = self.db.profile
    BF.db.global.raid40TestMode = false
    BF.db.global.raid30TestMode = false
    BF.db.global.raid20TestMode = false
    BF.db.global.partyTestMode   = false

    -- ── One-shot: showSetupGrid relocated db.profile -> db.global ─────────
    -- The default has always been declared under `global` (Defaults.lua) and
    -- MigrateGlobalSettings hoists the saved value there, but the options
    -- widget (Preview/Options_Preview.lua) and BF:UpdateSetupGrid both read
    -- db.profile. So the hoisted value was never seen, the declared default
    -- (true) never applied, and db.profile.showSetupGrid was nil -- falsy --
    -- which silently defaulted the setup grid to OFF. Both read sites now use
    -- db.global (2026-08-15).
    --
    -- Carry across whatever the user last set at the old location so a
    -- deliberate "off" is not resurrected as "on", then clear the dead key
    -- from every profile so a profile switch cannot resurrect it.
    --
    -- Guarded by a GLOBAL sentinel rather than a dbVersion gate: the key is
    -- account-wide, so a per-profile `ver < N` test would re-run on every
    -- profile switch and clobber a value the user had since changed. Same
    -- pattern as _previewModeMigratedV63 in the migration dispatcher.
    do
        local g = BF.db.global
        if g and not g._setupGridLocationFixed then
            g._setupGridLocationFixed = true
            if p and p.showSetupGrid ~= nil then
                g.showSetupGrid = p.showSetupGrid
            end
            local sv = _G.BuzzardFramesDB
            if sv and sv.profiles then
                for _, prof in pairs(sv.profiles) do
                    if prof.showSetupGrid ~= nil then
                        prof.showSetupGrid = nil
                    end
                end
            end
        end
    end

    -- ── One-shot: previewBuffCount / previewDebuffCount db.profile -> db.global ──
    -- Same defect and same fix as showSetupGrid above (§14.3): the defaults are
    -- declared under `global` (Defaults.lua, 6 and 3), MigrateGlobalSettings
    -- hoists the saved values there, but the slider and the DummyAuras consumer
    -- both read db.profile -- masked by an inline `or 4` at each read site, so
    -- the effective default was 4 on both sliders and never the declared 6 / 3.
    -- Both read sites now use db.global and the `or 4` fallbacks are gone
    -- (2026-08-15).
    --
    -- Anyone who ran MigrateGlobalSettings has the saved value in db.global
    -- already; this carries across a value a user changed AFTER that migration
    -- ran, which would otherwise be stranded in db.profile and ignored.
    --
    -- Guarded by a GLOBAL sentinel, not a dbVersion gate, for the same reason:
    -- both keys are account-wide, so a per-profile `ver < N` test would re-run
    -- on every profile switch and clobber a value the user had since changed.
    do
        local g = BF.db.global
        if g and not g._previewCountLocationFixed then
            g._previewCountLocationFixed = true
            -- A surviving db.profile value can only have been written AFTER
            -- MigrateGlobalSettings ran, because that migration nils the
            -- profile copy of every key it hoists -- so it is always the newer
            -- of the two and wins, exactly as in the showSetupGrid block.
            -- (A nil-test on db.global would be useless here: AceDB rawsets
            -- declared defaults into the table, so the global read is never
            -- nil for either key.)
            if p then
                if p.previewBuffCount   ~= nil then g.previewBuffCount   = p.previewBuffCount   end
                if p.previewDebuffCount ~= nil then g.previewDebuffCount = p.previewDebuffCount end
            end
            local sv = _G.BuzzardFramesDB
            if sv and sv.profiles then
                for _, prof in pairs(sv.profiles) do
                    prof.previewBuffCount   = nil
                    prof.previewDebuffCount = nil
                end
            end
        end
    end

    -- ── One-shot: roll back the interim container per-Layout seed ─────────
    -- An interim dbVersion-65 dev build seeded c.perLayoutConfig = true on
    -- every custom container / Single Buff whose old section group toggle was
    -- ON (essentially all of them, since v27 forced that toggle ON for every
    -- upgrader). The owner then ruled the opposite -- per-Layout starts
    -- DISABLED for ALL containers -- and the seed was removed
    -- (_AuraMig_SeedContainerPerLayout tombstone in Core_Migrations.lua). That
    -- interim build never shipped publicly, but saved variables it touched
    -- still carry the seeded flags (and its now-dead per-profile sentinel), so
    -- old containers looked per-Layout while new ones did not. This clears
    -- both, once, across every acDB profile. ONE-SHOT under a db.global
    -- sentinel, not every-login: after the rollback, a true flag is a
    -- deliberate user choice and must never be cleared again.
    do
        local g = self.db and self.db.global
        if g and not g._containerPerLayoutSeedRolledBack then
            g._containerPerLayoutSeedRolledBack = true
            local acSV = _G.BuzzardFramesAuraCustomizationsDB
            if acSV and acSV.profiles then
                for _, acp in pairs(acSV.profiles) do
                    for _, arr in ipairs({ acp.customBuffContainers,
                                           acp.customDebuffContainers }) do
                        if type(arr) == "table" then
                            for _, c in ipairs(arr) do
                                if type(c) == "table" then c.perLayoutConfig = nil end
                            end
                        end
                    end
                    acp._containerPerLayoutSeededV65 = nil
                end
            end
        end
    end

    -- ── Purge old _pinnedPreviewFlats key from every rpDB profile ─────────
    -- The preview-pinning model was inverted: pinning is now implicit
    -- (every flat is pinned by default), and _unpinnedPreviewFlats is
    -- the explicit unpin set. Any stale _pinnedPreviewFlats entries
    -- left over from the old model would be read as empty by the new
    -- code anyway, but nilling them keeps SavedVariables tidy.
    -- Runs across every profile so switching profiles never resurrects
    -- the old key. Safe to run every login.
    do
        local rpSV = _G.BuzzardFramesRaidPartyFramesDB
        if rpSV and rpSV.profiles then
            for _, prof in pairs(rpSV.profiles) do
                if prof._pinnedPreviewFlats ~= nil then
                    prof._pinnedPreviewFlats = nil
                end
            end
        end
    end
    -- Status icon test toggles (v26): these are transient debug flags
    -- that should never persist across a reload. Runtime reads from
    -- db.global (Options_Icons.lua writes there after v26).
    BF.db.global.testReadyCheck       = false
    BF.db.global.testPhased           = false
    BF.db.global.testSummonPending    = false
    BF.db.global.testResurrectPending = false
    BF.db.global.testVehicleIcon      = false
    -- v70: previewModeBuffs/previewModeDebuffs persist across reloads
    -- intentionally (user preference); they are account-wide db.global keys and
    -- are not reset here alongside the test-mode flags above.

    -- (Phase L: the active-layout restore that lived here is gone with the
    -- pre-flat named-layout system. GetActivePartyProfile / GetRaidProfile
    -- resolve flats via ResolveActiveFlat; there is no layout ID to restore.)

    -- (UF active-layout restore has moved to AFTER the versioned
    -- migration dispatcher. Under v18, accessing self.ufDB.profile
    -- before v18 has moved data into BuzzardFramesUnitFramesDB.profiles
    -- causes AceDB to materialize an empty profile table with defaults
    -- merged in, which v18's data-move would then have to work around.
    -- Running the restore after migration ensures AceDB merges defaults
    -- into the fully-populated profile table, preserving all saved keys.)

    -- (Removed in dbVersion 17: the C_Timer.After(0.3) call to
    -- ApplyProfileAutoSwitch that used to live here.  Auto-switch is
    -- ripped out as part of the Modular Profiles rework; a modular
    -- replacement will be built as a follow-up project.  The keys
    -- enableProfileAutoSwitch / profileAutoSwitchMode /
    -- specProfileAssignment / roleProfileAssignment remain in db.global
    -- untouched so the follow-up project can consume them.)

    -- Migrate: frame lock is now a single account-wide db.global.locked.
    -- If any per-tier locked value was saved (from old code), promote the
    -- most-relevant one to db.global.locked and strip the rest so they can't conflict.
    if p.raid40.locked ~= nil or p.raid30.locked ~= nil or p.raid20.locked ~= nil then
        -- Use raid40 as the canonical source if present, otherwise keep db.global.locked
        if p.raid40.locked ~= nil then self.db.global.locked = p.raid40.locked end
        p.raid40.locked = nil
        p.raid30.locked = nil
        p.raid20.locked = nil
    end
    -- Migrate overshieldStyle: old values all map to the new "Overlay"
    if p.overshieldStyle == "OverlayBlizzard" or p.overshieldStyle == "OverlayBlizzardTest" then
        p.overshieldStyle = "Overlay"
    end
    -- Remove deprecated absorb color options
    p.absorbRightBgEnabled    = nil
    p.absorbRightBgColor      = nil
    p.absorbOverflowBgEnabled = nil
    p.absorbOverflowBgColor   = nil
    p.absorbRightFgEnabled    = nil
    p.absorbRightFgColor      = nil
    p.absorbOverflowFgEnabled = nil
    p.absorbOverflowFgColor   = nil

    -- Ensure a sane default
    if self.db.global.locked == nil then self.db.global.locked = true end

    -- ── Purge retired buff-filter keys from every acDB profile ─────────────
    -- healerBuffFilter: superseded long ago, no reader left.
    -- specBuffFilter (+ its two one-shot flags): retired 2026-08-15. v67 had
    --   already deleted its last reader; the Buffs preset system replaced it,
    --   and the intent it encoded now lives in the seeded "none" preset
    --   overrides for the HEALER role and Augmentation Evoker
    --   (EnsureBuffsPresetsSeeded, AuraCustomizations.lua).
    --
    -- Runs across every profile (not just the active one) via the RAW saved
    -- variables table, so a profile switch cannot resurrect a dead key and no
    -- AceDB metatable is activated on the way past.
    --
    -- Every-login rather than one-shot ON PURPOSE, unlike the retired UF flag:
    -- these keys have no default and nothing writes them any more, so after the
    -- first pass this loop finds nothing and costs one table walk. It stays as
    -- a guard against an IMPORTED profile carrying them back in -- import does
    -- not run migrations (see the plan's §7.5a).
    do
        local acSV = _G.BuzzardFramesAuraCustomizationsDB
        if acSV and acSV.profiles then
            for _, prof in pairs(acSV.profiles) do
                if prof.healerBuffFilter ~= nil then
                    prof.healerBuffFilter = nil
                end
                if prof.specBuffFilter ~= nil then
                    prof.specBuffFilter = nil
                end
                if prof._migratedRestoShamanWhitelist ~= nil then
                    prof._migratedRestoShamanWhitelist = nil
                end
                if prof._migratedRestoDruidWhitelist ~= nil then
                    prof._migratedRestoDruidWhitelist = nil
                end
            end
        end
    end

    -- ── Versioned migrations (Grid2 pattern: dbVersion + sequential checks) ──
    -- dbVersion is nil for profiles created before this system was added.
    -- Each migration block runs once; the version stamp at the end prevents re-runs.
    -- Fresh profiles short-circuit this entire dispatcher via the OnNewProfile
    -- callback registered above, which stamps dbVersion = DB_VERSION before
    -- the dispatcher reads it.
    -- §L5.1: everything between init:dbCreated and here is the UNGUARDED
    -- every-login migration work (§L1.0 rows 10-14).
    self:LoadMark("init:preDispatcher")
    local ver = p.dbVersion or 0
    if ver < DB_VERSION then
        if ver < 1 then
            -- Migration 1: set new default absorb / overshield colors.
            -- Old defaults were all white (#ffffff @ 100%). Overwrite only
            -- profiles still on the old defaults so users who already
            -- customised their colors keep their values.
            local function isOldWhite(c)
                return c and c.r == 1 and c.g == 1 and c.b == 1 and c.a == 1
            end
            if isOldWhite(p.absorbBaseColor) then
                p.absorbBaseColor = { r = 0.976, g = 0.953, b = 0.922, a = 1.0 }   -- #f9f3eb @ 100%
            end
            if isOldWhite(p.absorbOverlayColor) then
                p.absorbOverlayColor = { r = 1.0, g = 1.0, b = 1.0, a = 0.66 }     -- #ffffff @ 66%
            end
            if isOldWhite(p.overshieldBaseColor) then
                p.overshieldBaseColor = { r = 0.937, g = 0.941, b = 0.855, a = 0.36 } -- #eff0da @ 36%
            end
            if isOldWhite(p.overshieldOverlayColor) then
                p.overshieldOverlayColor = { r = 1.0, g = 1.0, b = 1.0, a = 0.66 }  -- #ffffff @ 66%
            end
        end
        if ver < 2 then
            -- Migration 2: showPowerBarHealersOnly -> showAllPowerBars + showPowerBarHealers.
            -- Old default was showPowerBarHealersOnly = true (only healers).
            -- New defaults: showAllPowerBars = false, showPowerBarHealers = true (same result).
            -- Treat nil (never explicitly set) as the old default of true.
            local oldVal = p.showPowerBarHealersOnly
            if oldVal == nil then oldVal = true end
            if oldVal then
                -- Was filtered to healers only -> new filtered mode with healers on
                p.showAllPowerBars = false
                p.showPowerBarHealers = true
            else
                -- Was showing all power bars -> new "show all" mode
                p.showAllPowerBars = true
            end
            p.showPowerBarHealersOnly = nil  -- remove old key
        end
        if ver < 3 then
            -- Migration 3: remove old oUF player power color keys.
            -- The oUF power bar now always uses the shared BF.PowerTypeColors
            -- table (same as raid/party frames). All per-unit color keys are
            -- deleted so they can't confuse the new system.
            local function purgeOldPowerKeys(uf)
                if not uf then return end
                uf.usePowerTypeColor = nil
                uf.powerColor        = nil
                uf.useRaidPowerColors = nil
            end
            purgeOldPowerKeys(p.player)
            purgeOldPowerKeys(p.target)
            purgeOldPowerKeys(p.focus)
            purgeOldPowerKeys(p.pet)
            purgeOldPowerKeys(p.targettarget)
            purgeOldPowerKeys(p.focustarget)
        end
        if ver < 4 then
            -- Migration 4: oUF bar text offsets.
            -- Bars now inset from the icon edge (chord-based). Text defaults
            -- are computed dynamically so all rows align at slider 0.
            -- Clear all saved text offsets so the new defaults take effect.
            -- Users will see their text snap to the new aligned positions.
            local unitKeys = { "player", "pet", "target", "focus", "targettarget", "focustarget", "boss" }
            for _, unitKey in ipairs(unitKeys) do
                local uf = p[unitKey]
                if uf then
                    uf.nameOffsetX   = nil
                    uf.healthPctPos  = nil
                    uf.healthValPos  = nil
                    uf.powerPctPos   = nil
                    uf.powerValPos   = nil
                end
            end
        end
        if ver < 5 then
            -- Migration 5: re-run the text offset reset for users who got
            -- the broken migration 4 (which subtracted old defaults instead
            -- of clearing). This ensures all users end up with nil offsets.
            local unitKeys = { "player", "pet", "target", "focus", "targettarget", "focustarget", "boss" }
            for _, unitKey in ipairs(unitKeys) do
                local uf = p[unitKey]
                if uf then
                    uf.nameOffsetX   = nil
                    uf.healthPctPos  = nil
                    uf.healthValPos  = nil
                    uf.powerPctPos   = nil
                    uf.powerValPos   = nil
                end
            end
        end
        if ver < 6 then
            -- Migration 6: reset text offsets to new defaults (x=0).
            -- The old defaults had hardcoded offsets (21, 24, -21, -24).
            -- The new system computes offsets dynamically from bar insets.
            -- We must SET the values (not nil) because AceDB merges defaults back.
            local unitKeys = { "player", "pet", "target", "focus", "targettarget", "focustarget", "boss" }
            for _, unitKey in ipairs(unitKeys) do
                local uf = p[unitKey]
                if uf then
                    uf.nameOffsetX = 0
                    if uf.healthValPos then uf.healthValPos.x = 0 end
                    if uf.powerValPos  then uf.powerValPos.x  = 0 end
                end
            end
        end
        if ver < 7 then
            -- Migration 7: same as 6 but re-runs for users whose dbVersion
            -- was already 6 before the defaults were fixed.
            local unitKeys = { "player", "pet", "target", "focus", "targettarget", "focustarget", "boss" }
            for _, unitKey in ipairs(unitKeys) do
                local uf = p[unitKey]
                if uf then
                    uf.nameOffsetX = 0
                    if uf.healthValPos then uf.healthValPos.x = 0 end
                    if uf.powerValPos  then uf.powerValPos.x  = 0 end
                end
            end
        end
        if ver < 8 then
            -- Migration 8: separate configuration per section.
            -- Existing users who already had separateRaidBySize enabled get
            -- the new per-section toggles turned on so behavior is unchanged.
            -- New users or those without separateRaidBySize get them off.
            if p.separateRaidBySize then
                if p.separateRaidAuras == nil then p.separateRaidAuras = true end
                if p.separateRaidAuraCustomizations == nil then p.separateRaidAuraCustomizations = true end
            end
        end
        if ver < 9 then
            -- Migration 9: Move flat incomingCasts* keys into p.modules.incomingCasts.
            -- Grid2 pattern: copy user's saved value → new location, nil the old key.
            -- AceDB merges defaults for the new modules.incomingCasts sub-table, so
            -- we only need to copy keys that the user explicitly changed.
            if not p.modules then p.modules = {} end
            if not p.modules.incomingCasts then p.modules.incomingCasts = {} end
            local IC_KEYS = {
                "incomingCastsEnabled",
                "incomingCastsDisplayType",
                "incomingCastsShowTimer",
                "incomingCastsShowOnPlayerFrame",
                "incomingCastsShowOnPartyFrame",
                "incomingCastsAnchorPoint",
                "incomingCastsGrowDirection",
                "incomingCastsSpacing",
                "incomingCastsOffsetX",
                "incomingCastsOffsetY",
                "incomingCastsPlayerAnchorX",
                "incomingCastsPlayerAnchorY",
                "incomingCastsPlayerGrowDirection",
                "incomingCastsPlayerSpacing",
                "incomingCastsBarWidth",
                "incomingCastsBarHeight",
                "incomingCastsIconSize",
            }
            for _, key in ipairs(IC_KEYS) do
                if p[key] ~= nil then
                    p.modules.incomingCasts[key] = p[key]
                    p[key] = nil
                end
            end
        end
        if ver < 10 then
            -- Migration 10: Move flat UnitFrames keys into the UnitFrames namespace.
            -- Grid2 pattern: RegisterNamespace creates BuzzardFramesDB.namespaces.UnitFrames.
            -- Copy user's saved values from the parent profile into the namespace profile,
            -- then nil the parent keys so they don't shadow the namespace defaults.
            self:MigrateUnitFramesProfile()
        end
        if ver < 11 then
            -- Migration 11: Re-run UF migration using raw SavedVariables.
            -- Migration 10 read from self.db.profile which only sees values that
            -- differ from (now-removed) defaults. This version reads from the raw
            -- SV table to capture all user customizations.
            self:MigrateUnitFramesProfile()
        end
        if ver < 12 then
            -- Migration 12: Move Aura Customizations keys into the
            -- AuraCustomizations namespace.
            self:MigrateAuraCustomizationsProfile()
        end
        if ver < 13 then
            -- Migration 13: Move Custom Frame Groups keys into the
            -- CustomFrameGroups namespace.
            self:MigrateCustomFrameGroupsProfile()
        end
        if ver < 14 then
            -- Migration 14: Move global settings (preview, test mode, debug,
            -- experimental, profile auto-switch, aura filter) from profile
            -- to db.global. First profile migrated wins; subsequent profiles
            -- only nil out their keys.
            self:MigrateGlobalSettings()
        end
        if ver < 15 then
            -- Migration 15: Move ~300 flat raid/party frame keys into the
            -- RaidPartyFrames namespace (rpDB.profile.<subtable>).
            -- Also moves missing raid buff keys from acDB → rpDB.profile.icons,
            -- and moves partyFramesEnabled/raidFramesEnabled/locked/hideBlizzard*
            -- to db.global.
            self:MigrateRaidPartyFramesProfile()
        end
        if ver < 16 then
            -- Migration 16: Move the 17 IncomingCasts keys from
            -- p.modules.incomingCasts into the new IncomingCasts namespace
            -- (BF.icDB.profile). Source sub-table is nil'd after copy.
            self:MigrateIncomingCastsProfile()
        end
        if ver < 18 then
            -- Migration 18: Split each module's namespace into its own
            -- top-level AceDB. v17 was an abandoned design (namespace
            -- overrides) that never worked because AceDB namespaces
            -- cannot change profile independently of their parent. v18
            -- replaces it with five genuinely-independent root DBs.
            --
            -- Work:
            --   1. Snapshot oldActive = parent DB's current profile name.
            --      This is what each module DB should come up on so the
            --      user arrives at the profile they were using pre-v18.
            --   2. Run all five per-profile migrations for EVERY profile
            --      (needed because v10..v16 only migrated the active one).
            --   3. For each module M, move SavedVariables data from
            --      BuzzardFramesDB.namespaces[M].profiles[<n>] to
            --      BuzzardFrames<M>DB.profiles[<n>], set
            --      BuzzardFrames<M>DB.profileKeys[charKey] = oldActive,
            --      and delete the old namespace entry.
            --   4. Post-migration chat message flag (skip on fresh install).
            --
            -- Callbacks are NOT detached here because they are not yet
            -- registered at this point in RegisterDB (see the comment
            -- earlier in this function). They will be registered after
            -- the migration block completes.
            local realmKey = GetRealmName()
            local charKey  = UnitName("player") .. " - " .. realmKey

            local oldActive = self.db:GetCurrentProfile()

            -- Run per-profile migrations for every profile that exists on
            -- the parent DB. v10..v16 only touched the active profile, so
            -- non-active profiles still have flat keys at p.<key> rather
            -- than inside namespace sub-tables. The Migrate*Profile
            -- functions all read from self.db.profiles[name] (raw SV) and
            -- write into the module DB's raw profiles table, so running
            -- them before the data-move below is the correct order.
            local allProfiles = {}
            for _, name in ipairs(self.db:GetProfiles()) do
                allProfiles[#allProfiles + 1] = name
            end
            for _, name in ipairs(allProfiles) do
                self:MigrateUnitFramesProfile(name)
                self:MigrateAuraCustomizationsProfile(name)
                self:MigrateCustomFrameGroupsProfile(name)
                self:MigrateRaidPartyFramesProfile(name)
                self:MigrateIncomingCastsProfile(name)
            end

            -- Move namespace data from the parent SV into each module's
            -- new top-level SV. Reference the raw SavedVariables tables
            -- by their global names so AceDB's cached .profiles accessors
            -- don't mask what's happening on disk.
            local parentSV = _G.BuzzardFramesDB
            local oldNamespaces = parentSV and parentSV.namespaces
            local moves = {
                { ns = "UnitFrames",         svName = "BuzzardFramesUnitFramesDB"         },
                { ns = "AuraCustomizations", svName = "BuzzardFramesAuraCustomizationsDB" },
                { ns = "CustomFrameGroups",  svName = "BuzzardFramesCustomFrameGroupsDB"  },
                { ns = "RaidPartyFrames",    svName = "BuzzardFramesRaidPartyFramesDB"    },
                { ns = "IncomingCasts",      svName = "BuzzardFramesIncomingCastsDB"      },
            }
            for _, m in ipairs(moves) do
                local src = oldNamespaces and oldNamespaces[m.ns] and oldNamespaces[m.ns].profiles
                local destSV = _G[m.svName]
                if src and destSV then
                    destSV.profiles = destSV.profiles or {}
                    for name, data in pairs(src) do
                        -- Install the namespace data. Because v18 is the
                        -- first time any data is placed into this new
                        -- top-level SV, and because RegisterDB now defers
                        -- every module .profile access until AFTER this
                        -- migration block completes, destSV.profiles[name]
                        -- is expected to be nil here and we can install
                        -- the table directly. If a per-profile Migrate*
                        -- call in step 1 above happened to create an
                        -- empty destination entry (it only does so when
                        -- it has keys to move), we merge into it with
                        -- namespace data winning on collision — the
                        -- namespace holds the canonical values that
                        -- v10..v16 deposited there for the active
                        -- profile.
                        local dest = destSV.profiles[name]
                        if dest == nil then
                            destSV.profiles[name] = data
                        else
                            for k, v in pairs(data) do
                                dest[k] = v
                            end
                        end
                    end
                    destSV.profileKeys = destSV.profileKeys or {}
                    destSV.profileKeys[charKey] = oldActive
                end
                -- Delete the old namespace entry unconditionally. Fresh
                -- installs have nothing to delete (oldNamespaces[m.ns] is
                -- nil), but the call is safe either way.
                if oldNamespaces then oldNamespaces[m.ns] = nil end
            end

            -- AceDB caches each DB's current profile name in db.keys.profile
            -- at :New() time from profileKeys[charKey] (or "Default" if
            -- absent). We wrote destSV.profileKeys[charKey] = oldActive
            -- above, but that only affects FUTURE sessions; the cached
            -- keys.profile in memory is still whatever AceDB picked at
            -- :New() time ("Default" on fresh install, or the existing
            -- profileKeys[charKey] if the top-level SV already existed).
            --
            -- SetProfile updates keys.profile, db.profile, and all cached
            -- accessors in one shot. It is a no-op if the current profile
            -- already matches oldActive (AceDB early-returns). Callbacks
            -- are not registered yet (registration is at end of this
            -- function), so this fires no refresh side-effects.
            for _, db in ipairs({ self.ufDB, self.acDB, self.cfgDB, self.rpDB, self.icDB }) do
                db:SetProfile(oldActive)
            end

            -- Chat message on first PLAYER_LOGIN after migration.
            -- Skip on fresh installs (ver==0) — nothing visible changed.
            if ver > 0 then
                self.db.global._postMigrationChatMessage = true
            end
        end
        if ver < 19 then
            -- Migration 19: Phase 1 of "Layouts by Instance Type" rework.
            -- Seeds rp.layouts.flatLayouts (one flat config per entry,
            -- deep-copied from the active layout's tier sub-tables) and
            -- rp.layouts.instanceLayoutAssignment (slot → flat id map)
            -- for every profile. The old rp.layouts.layouts[*] table is
            -- NOT touched — it stays as frozen source data for a future
            -- Profiles migration that will preserve per-role/per-spec
            -- settings.
            --
            -- Nothing in the render/resolver path reads these new tables
            -- yet; they are dormant until Phase 2. The old tab
            -- (separateRaidBySize, enableRaidNN, openWorld*, Role/Spec
            -- Layouts) continues to be the source of truth for rendering.
            local allProfiles = {}
            for _, name in ipairs(self.rpDB:GetProfiles()) do
                allProfiles[#allProfiles + 1] = name
            end
            for _, name in ipairs(allProfiles) do
                self:MigrateLayoutsByInstanceType(name)
            end
        end
        if ver < 20 then
            -- Migration 20: Phase 2 of "Layouts by Instance Type".
            -- Converts per-role and per-spec OLD-layout assignments
            -- (roleLayoutAssignment / specLayoutAssignment pointing into
            -- rp.layouts.layouts[*]) into per-slot flat overrides
            -- (rp.layouts.roleOverrides / specOverrides). For each
            -- referenced old layout, splits its party/raid20/raid30/raid40
            -- sub-tables into new flat layouts and wires those flats into
            -- the 11 slot keys per role/spec.
            --
            -- Idempotent per profile (guarded by _roleSpecOverridesMigrated
            -- inside the migration function). Fresh installs are no-ops.
            local allProfiles = {}
            for _, name in ipairs(self.rpDB:GetProfiles()) do
                allProfiles[#allProfiles + 1] = name
            end
            for _, name in ipairs(allProfiles) do
                self:MigrateRoleSpecToFlatOverrides(name)
            end
        end
        if ver < 21 then
            -- Migration 21: Phase 2 per-flat aura container scoping.
            -- Walks custom aura containers under acDB and remaps their
            -- per-group-type keys from old tier strings (party/raid20/
            -- raid30/raid40) to flat IDs (flat_party/flat_raid40), also
            -- remapping each container's containerEditingGroupType.
            -- raid20/raid30 entries are discarded (no flat maps to them).
            -- cfGroup_N entries are unchanged (migration 52 finishes those).
            --
            -- Idempotent per profile (guarded by
            -- _groupSettingsMigratedToFlat inside the migration function).
            -- Fresh installs are no-ops.
            local acProfiles = {}
            for _, name in ipairs(self.acDB:GetProfiles()) do
                acProfiles[#acProfiles + 1] = name
            end
            for _, name in ipairs(acProfiles) do
                self:MigrateGroupSettingsToFlatKeys(name)
            end
        end
        if ver < 22 then
            -- Migration 22: backfill missing `showGroup` on raid-typed flats.
            -- v19 deep-copied raw SV tier tables into flatLayouts; AceDB had
            -- stripped `showGroup` from any tier that matched the default
            -- (all-true), so those flats were born without the field. This
            -- crashes the Frames tab's group1..group8 toggles on AceConfig's
            -- get/set. Walks every flat in every rpDB profile and inserts
            -- a default-all-true `showGroup` on any raid flat missing it.
            --
            -- Idempotent per profile (guarded by _showGroupBackfilled inside
            -- the migration function). Fresh installs are no-ops.
            local rpProfiles = {}
            for _, name in ipairs(self.rpDB:GetProfiles()) do
                rpProfiles[#rpProfiles + 1] = name
            end
            for _, name in ipairs(rpProfiles) do
                self:MigrateBackfillFlatShowGroup(name)
            end
        end
        if ver < 23 then
            -- Migration 23: collapse flat defaults to sparse storage.
            -- Walks every flat in every rpDB profile and nils any rawkey
            -- whose value matches the CreateRaidProfile/CreatePartyProfile
            -- template for that flat's type. The four invariants
            -- (name, type, anchorX, anchorY) are preserved as rawkeys.
            -- Unmodified keys then fall through via the __index metatable
            -- wired up by BF:RehydrateFlats() at the end of RegisterDB.
            --
            -- This both fixes the v22 "missing showGroup / frameHeight=0"
            -- class of bugs (defaults are always present via fallback,
            -- never stripped by AceDB) and makes SavedVariables tiny.
            --
            -- Idempotent per profile (guarded by _flatsCollapsedToSparse
            -- inside the migration function). Fresh installs are no-ops
            -- because no flats exist yet (they're seeded by RehydrateFlats
            -- a few lines below).
            local rpProfiles = {}
            for _, name in ipairs(self.rpDB:GetProfiles()) do
                rpProfiles[#rpProfiles + 1] = name
            end
            for _, name in ipairs(rpProfiles) do
                self:MigrateCollapseFlatDefaults(name)
            end
        end
        if ver < 24 then
            -- Migration 24: two independent fixes bundled under one bump.
            --
            -- (a) MigrateTooltipsLocation: relocate the 10 aura-tooltip show
            --     keys that were being written to db.profile by the (now
            --     deleted) getTooltip_global / setTooltip_global helpers into
            --     rpDB.profile.tooltips alongside the other tooltip keys.
            --     Also relocate suppressPrivateAuraTooltip from each flat's
            --     root into rpDB.profile.tooltips (any_true merge policy).
            --     See MigrateTooltipsLocation in Core_Migrations.lua.
            --
            -- (b) MigrateWirePerLayoutSectionFallbacks: retrofit the metatable
            --     __index fallback on every flat[section] sub-table for the 9
            --     per-layout-capable sections. Pre-existing per-flat sub-tables
            --     (seeded before the metatable pattern existed) were plain
            --     deep-copied tables with no link back to defaults, so adding
            --     a new key to Defaults_RaidPartyFrames.lua left it missing
            --     from those copies. This one-time pass wires the fallback.
            --     See MigrateWirePerLayoutSectionFallbacks in Core_Migrations.lua
            --     and Docs/PHASE_3_PLAN.md Part 2.
            --
            -- Both migrations are idempotent per profile.
            local rpProfiles = {}
            for _, name in ipairs(self.rpDB:GetProfiles()) do
                rpProfiles[#rpProfiles + 1] = name
            end
            for _, name in ipairs(rpProfiles) do
                self:MigrateTooltipsLocation(name)
                self:MigrateWirePerLayoutSectionFallbacks(name)
            end
        end
        if ver < 25 then
            -- Migration 25: text-section data-location fix + font-name fix.
            --
            -- Relocates ~45 text-section scalar/toggle keys that were written
            -- to db.profile (by deps.get / Options_Text.lua's setters / the
            -- setFont helper) into rpDB.profile.text where the runtime reads
            -- them. Same bug class as the v24 tooltip relocation.
            --
            -- See MigrateTextLocation in Core_Migrations.lua for the full
            -- key list, including five font-name keys (nameFont, healthFont,
            -- statusFont, groupLabelFont, vehicleFont) and five cross-section
            -- keys owned by text but written from Options_HealthPower.lua
            -- (offlineBackgroundColor, fadeOfflineFrames, deadBackgroundColor,
            -- deadBackgroundOpacity, deadColorOORFactor).
            --
            -- Idempotent per profile (guarded by rp._textLocationMigrated).
            local rpProfiles = {}
            for _, name in ipairs(self.rpDB:GetProfiles()) do
                rpProfiles[#rpProfiles + 1] = name
            end
            for _, name in ipairs(rpProfiles) do
                self:MigrateTextLocation(name)
            end
        end
        if ver < 26 then
            -- Migration 26: icons section data-location fix + test-toggle cleanup.
            --
            -- (a) Nils the 8 missing-raid-buff keys on acDB.profile that were
            --     being written by Options_Icons.lua widgets while runtime
            --     read from rpDB.icons (strict-rpDB-wins policy: never copy
            --     acDB values into rpDB). Users who had toggled the feature
            --     on via the broken UI will need to re-toggle.
            --
            -- (b) Nils the 5 orphaned testX keys on db.profile that were
            --     moved to db.global in v14 but kept being written back by
            --     Options_Icons.lua's get=get/set=set path. Runtime reads
            --     from db.global; Core_DB.lua resets them to false on
            --     every reload (see the block above).
            --
            -- See MigrateIconsLocation in Core_Migrations.lua.
            -- Idempotent per profile (guarded by rp._iconsLocationMigrated).
            local rpProfiles = {}
            for _, name in ipairs(self.rpDB:GetProfiles()) do
                rpProfiles[#rpProfiles + 1] = name
            end
            for _, name in ipairs(rpProfiles) do
                self:MigrateIconsLocation(name)
            end
        end
        if ver < 27 then
            -- Migration 27: auras section rollout.
            --
            -- Relocates every flat-root aura-section key into a nested
            -- sub-category under flat.auras.<subcat> (buffs/debuffs/
            -- privateAuras/bigDef/important/crowdControl/dispelIndicator).
            -- Enables the per-layout toggle for auras so existing users
            -- keep their per-flat aura config as the default UX.
            -- Relocates db.profile.pvpSwapDebuffsPrivate into nested
            -- flat.auras.privateAuras.pvpSwapDebuffsPrivateBattleground
            -- (per-flat for raid flats) and rp.auras.privateAuras.pvpSwapDebuffsPrivateBattleground
            -- (global fallback).
            --
            -- Runs AFTER v23 (MigrateCollapseFlatDefaults) — any aura key
            -- that was already default-equal was stripped by v23, and the
            -- fallback chain (flat.auras -> global.auras plus each
            -- flat.auras.<subcat> -> global.auras.<subcat>) covers those
            -- un-customized keys. v27 only relocates rawkeys that are
            -- still present on the flat root.
            --
            -- See MigrateAurasToSection in Core_Migrations.lua.
            -- Idempotent per profile (guarded by rp._aurasSectionMigrated).
            local rpProfiles = {}
            for _, name in ipairs(self.rpDB:GetProfiles()) do
                rpProfiles[#rpProfiles + 1] = name
            end
            for _, name in ipairs(rpProfiles) do
                self:MigrateAurasToSection(name)
            end
        end
        if ver < 28 then
            -- Migration 28: Private Aura Border namespace migrations.
            --
            -- Relocates six private-aura-border settings into the namespaces
            -- matching their new UI locations:
            --
            --   * privateAuraBorderScale        -> rpDB.profile (global)
            --     Widget moved to Raid/Party Frames → Auras → Private Auras.
            --
            --   * privateAuraBorderAutoScale    -> acDB.profile (global)
            --   * privateAuraBorderWidthRatio   -> acDB.profile (global)
            --   * privateAuraBorderFrameLevel   -> acDB.profile (global)
            --     Widgets moved to Aura Customizations → Private Aura
            --     Customizations → Frame Border.
            --
            --   * Per-flat privateAuraFrameBorderScaleOverride ->
            --       acDB.profile.privateAuraFrameBorderScaleRaid / Party
            --     Collapsed from per-flat-per-tier to global one-value-per-scope
            --     (raid/party). First flat with a non-nil override wins.
            --
            -- Iterates ALL core-DB profiles (the migration touches db.profile
            -- and per-profile rpDB+acDB) to ensure every profile gets cleaned
            -- up, not just the currently active one.
            --
            -- See MigratePrivateAuraBorderNamespaces in Core_Migrations.lua.
            -- Idempotent per profile (guarded by rp._privateAuraBorderNamespacesMigrated).
            local dbProfiles = {}
            for _, name in ipairs(self.db:GetProfiles()) do
                dbProfiles[#dbProfiles + 1] = name
            end
            for _, name in ipairs(dbProfiles) do
                self:MigratePrivateAuraBorderNamespaces(name)
            end
        end
        if ver < 29 then
            -- Migration 29: pvpSwapDebuffsPrivate orphan repair.
            --
            -- A previous revision of v27 MigrateAurasToSection wrote the
            -- swap value to the wrong storage path
            -- (rp.auras.pvpSwapDebuffsPrivate flat) instead of the nested
            -- rp.auras.privateAuras.pvpSwapDebuffsPrivateBattleground, and
            -- set the _aurasSectionMigrated sentinel so v27 will never
            -- re-run. This repair migration reads the orphan (falling
            -- back to db.profile and db.global), writes it to the correct
            -- nested location, seeds every raid flat when the value is
            -- true, and nils all orphan sources.
            --
            -- See MigratePvpSwapOrphanRepair in Core_Migrations.lua.
            -- Idempotent per profile (guarded by rp._pvpSwapRepairedV29).
            -- Fresh installs are no-ops.
            local rpProfiles = {}
            for _, name in ipairs(self.rpDB:GetProfiles()) do
                rpProfiles[#rpProfiles + 1] = name
            end
            for _, name in ipairs(rpProfiles) do
                self:MigratePvpSwapOrphanRepair(name)
            end
        end
        if ver < 30 then
            -- Migration 30: auraText section sub-category rollout.
            --
            -- Relocates every flat-root auraText key into a nested
            -- sub-category under auraText.<subcat>.<key>
            -- (stackText/global/buffs/debuffs/bigDef/important/
            -- crowdControl/privateAuras). Direct mirror of the v27
            -- auras rollout.
            --
            -- Applies to both the global pseudo-layout
            -- (rp.profile.auraText) and every flat's per-flat cache
            -- (rp.layouts.flatLayouts[*].auraText).
            --
            -- globalAuraTextConfig stays at the top of auraText (NOT
            -- inside any sub-category) so it can be read independently
            -- of sub-category resolution.
            --
            -- Also clears pre-v15 fossil copies of every auraText key
            -- from db.profile (the core DB). Those reads had been dead
            -- since v15's MigrateKeysToSubTables relocation, but some
            -- SavedVariables may still carry default-written copies.
            -- AuraCustomizations.lua:ResolveDurationSettings and
            -- ResolveLayoutSettings had been reading from there
            -- erroneously -- that bug is fixed in the same changeset.
            --
            -- See MigrateAuraTextToSubcats in Core_Migrations.lua.
            -- Idempotent per profile (guarded by rp._auraTextSubcatMigrated).
            local rpProfiles = {}
            for _, name in ipairs(self.rpDB:GetProfiles()) do
                rpProfiles[#rpProfiles + 1] = name
            end
            for _, name in ipairs(rpProfiles) do
                self:MigrateAuraTextToSubcats(name)
            end
        end
        if ver < 31 then
            -- Migration 31: restore per-flat aura defaults for keys
            -- where the raid and party templates disagree (safe version).
            --
            -- Pre-v27, the 4 keys (buffSize, debuffSize, debuffAnchorPoint,
            -- privateAuraAnchorPoint) resolved to different values for raid
            -- vs party flats via the WireFlatDefaults template fallback.
            -- v23 stripped default-equal rawkeys; v27 enabled the auras
            -- per-layout toggle and switched reads to route through the
            -- single global rpDB.profile.auras. Result: stripped keys now
            -- resolve to the same global for all flats, erasing per-flat-
            -- type divergence.
            --
            -- This migration seeds the appropriate template default into
            -- each flat's auras.<subcat> -- but ONLY for keys that are
            -- missing as rawkeys (rawget nil). Any existing rawkey is a
            -- user customization (either pre-v27 non-default that survived
            -- v23, or post-v27 Options edit) and must not be overwritten.
            --
            -- A prior buggy revision (_V31) unconditionally overwrote these
            -- keys. The safe version uses sentinel _V31b so profiles that
            -- ran the buggy version still get the safe pass, which now
            -- preserves any customized rawkeys that survived the corruption.
            --
            -- See MigrateRestorePerFlatAuraDefaults in Core_Migrations.lua.
            -- Idempotent per profile (guarded by
            -- rp._aurasTemplateDivergenceRestoredV31b).
            local rpProfiles = {}
            for _, name in ipairs(self.rpDB:GetProfiles()) do
                rpProfiles[#rpProfiles + 1] = name
            end
            for _, name in ipairs(rpProfiles) do
                self:MigrateRestorePerFlatAuraDefaults(name)
            end
        end
        if ver < 32 then
            -- Migration 32: split Private Aura Frame Border settings into
            -- raid/party variants.
            --
            -- Three acDB keys previously applied to both raid and party
            -- frames:
            --   privateAuraBorderAutoScale
            --   privateAuraBorderWidthRatio
            --   privateAuraBorderFrameLevel
            --
            -- These have been replaced by six keys:
            --   privateAuraBorderAutoScaleRaid  / privateAuraBorderAutoScaleParty
            --   privateAuraBorderWidthRatioRaid / privateAuraBorderWidthRatioParty
            --   privateAuraBorderFrameLevelRaid / privateAuraBorderFrameLevelParty
            --
            -- For existing profiles, copy each shared value into BOTH the
            -- Raid and Party variants so behavior stays identical, then
            -- nil the shared source. The runtime reader in
            -- LayoutPrivateAuraFrameBorderContainer routes via isRaid
            -- against the new keys exclusively.
            --
            -- The existing scale split (privateAuraFrameBorderScaleRaid /
            -- privateAuraFrameBorderScaleParty) was introduced in §18.2 and
            -- is already correct; v32 does NOT touch it.
            --
            -- Iterates every acDB profile (not just the active one) so
            -- profile switches after migration land on correctly-split
            -- data across all profiles.
            local acProfiles = {}
            for _, name in ipairs(self.acDB:GetProfiles()) do
                acProfiles[#acProfiles + 1] = name
            end
            local acSV = _G.BuzzardFramesAuraCustomizationsDB
            if acSV and acSV.profiles then
                local SHARED_KEYS = {
                    "privateAuraBorderAutoScale",
                    "privateAuraBorderWidthRatio",
                    "privateAuraBorderFrameLevel",
                }
                for _, pname in ipairs(acProfiles) do
                    local prof = acSV.profiles[pname]
                    if prof then
                        for _, sharedKey in ipairs(SHARED_KEYS) do
                            local val = prof[sharedKey]
                            if val ~= nil then
                                local raidKey  = sharedKey .. "Raid"
                                local partyKey = sharedKey .. "Party"
                                -- Only copy if the target key isn't already
                                -- set — never overwrite an existing per-scope
                                -- value. (Currently impossible because the
                                -- per-scope keys are brand new, but safe to
                                -- guard.)
                                if prof[raidKey]  == nil then prof[raidKey]  = val end
                                if prof[partyKey] == nil then prof[partyKey] = val end
                                prof[sharedKey] = nil
                            end
                        end
                    end
                end
            end
        end
        if ver < 33 then
            -- Migration 33: collapse the two separate
            -- <prefix>ThresholdBorderEnabled / <prefix>Threshold2BorderEnabled
            -- toggles into a single <prefix>ColorAuraBorder toggle for
            -- global / buffs / bigDef / important, plus the per-container
            -- thresholdBorderEnabled / threshold2BorderEnabled fields into
            -- a single per-container colorAuraBorder.
            --
            -- Merge policy: new = old_primary OR old_secondary. Any user
            -- who had either pre-v33 toggle on (primary or secondary) has
            -- the new unified toggle on. Users with both off stay at the
            -- default (false / absent).
            --
            -- Two dispatcher passes: one over rpDB profiles (auraText
            -- sub-categories on both the global pseudo-layout and every
            -- per-flat cache), one over acDB profiles (custom buff
            -- containers + their per-group-type override entries).
            --
            -- Debuffs and crowd control are explicitly excluded from this
            -- migration -- deferred to a follow-up restructure per the
            -- v33 design.
            --
            -- See MigrateColorAuraBorderRP / MigrateColorAuraBorderAC in
            -- Core_Migrations.lua.
            -- Idempotent per profile (guarded by rp._colorAuraBorderMigratedV33
            -- and acp._colorAuraBorderMigratedV33 respectively).
            local rpProfiles = {}
            for _, name in ipairs(self.rpDB:GetProfiles()) do
                rpProfiles[#rpProfiles + 1] = name
            end
            for _, name in ipairs(rpProfiles) do
                self:MigrateColorAuraBorderRP(name)
            end
            local acProfiles = {}
            for _, name in ipairs(self.acDB:GetProfiles()) do
                acProfiles[#acProfiles + 1] = name
            end
            for _, name in ipairs(acProfiles) do
                self:MigrateColorAuraBorderAC(name)
            end
        end

        -- ── v34: Migrate dispelIndicatorMode + dispelDotOnlyIfReady ──────
        -- from borders section → auras.dispelIndicator section.
        -- See MigrateDispelIndicatorToAuras in Core_Migrations.lua.
        -- Idempotent per profile (guarded by rp._dispelIndicatorToAurasMigratedV34).
        if ver < 34 then
            local rpProfiles = {}
            for _, name in ipairs(self.rpDB:GetProfiles()) do
                rpProfiles[#rpProfiles + 1] = name
            end
            for _, name in ipairs(rpProfiles) do
                self:MigrateDispelIndicatorToAuras(name)
            end
        end

        -- ── v35: Migrate debuff highlight / overlay keys from borders ────
        -- section → auras.dispelIndicator sub-category. Renames
        -- privateAuraDispelOverlayMode → blizzardDispelOverlayMode along
        -- the way since the widget now drives the Blizzard-style dispel
        -- overlay in the Dispel Indicator tab.
        -- See MigrateDebuffHighlightToAuras in Core_Migrations.lua.
        -- Idempotent per profile (guarded by rp._debuffHighlightToAurasMigratedV35).
        if ver < 35 then
            local rpProfiles = {}
            for _, name in ipairs(self.rpDB:GetProfiles()) do
                rpProfiles[#rpProfiles + 1] = name
            end
            for _, name in ipairs(rpProfiles) do
                self:MigrateDebuffHighlightToAuras(name)
            end
        end

        -- ── v36: Rename showBlizzardDispelIndicator (bool) → ─────────────
        -- dispelIndicatorOverlayMode (string) under auras.dispelIndicator.
        -- The boolean master toggle was replaced by a two-option dropdown
        -- ("blizzard" / "custom"). true → "blizzard", false/nil → "custom"
        -- (left unwritten because "custom" is the default).
        -- See MigrateDispelIndicatorOverlayMode in Core_Migrations.lua.
        -- Idempotent per profile (guarded by rp._dispelIndicatorOverlayModeMigratedV36).
        if ver < 36 then
            local rpProfiles = {}
            for _, name in ipairs(self.rpDB:GetProfiles()) do
                rpProfiles[#rpProfiles + 1] = name
            end
            for _, name in ipairs(rpProfiles) do
                self:MigrateDispelIndicatorOverlayMode(name)
            end
        end

        -- ── v37: Remove pvpSwapDebuffsPrivate* feature entirely. ─────────
        -- The swap feature has been deleted. This migration nils every
        -- saved value of pvpSwapDebuffsPrivateBattleground /
        -- pvpSwapDebuffsPrivateParty / legacy pvpSwapDebuffsPrivate from
        -- every storage location across every profile. Runs AFTER v27
        -- (MigrateAurasToSection) and v29 (MigratePvpSwapOrphanRepair) so
        -- any value those migrations re-seeded from legacy SavedVariables
        -- gets nilled here. See MigrateRemovePvpSwap in Core_Migrations.lua.
        -- Idempotent per profile (guarded by rp._pvpSwapRemovedV37).
        if ver < 37 then
            local rpProfiles = {}
            for _, name in ipairs(self.rpDB:GetProfiles()) do
                rpProfiles[#rpProfiles + 1] = name
            end
            for _, name in ipairs(rpProfiles) do
                self:MigrateRemovePvpSwap(name)
            end
        end

        -- Migration 38: set aggroBorderWidth = 2 for existing blizzard-style users
        -- The old blizzard texture was a single file; now there are 2px/3px/4px variants.
        -- Existing users may have aggroBorderWidth set to 1 or 5 which has no matching
        -- blizzard texture. Reset to 2 (the new default) for anyone using blizzard style.
        if ver < 38 then
            for _, rpName in ipairs(self.rpDB:GetProfiles()) do
                local rp = self.rpDB.profiles[rpName]
                if rp then
                    local flats = rp.layouts and rp.layouts.flatLayouts
                    if flats then
                        for _, flat in pairs(flats) do
                            local borders = flat.borders
                            if borders and borders.aggroStyle == "blizzard" then
                                borders.aggroBorderWidth = 2
                            end
                        end
                    end
                end
            end
        end
        if ver < 39 then
            -- Migration 39: add partyLayoutAnchor / raidLayoutAnchor to
            -- all flats. Derive from grow direction settings so the anchor
            -- frame corner matches the old CENTER-based position.
            local PARTY_ANCHOR = {
                RIGHT = "TOPLEFT", LEFT = "TOPRIGHT",
                DOWN  = "TOPLEFT", UP   = "BOTTOMLEFT",
                HORIZONTAL = "TOPLEFT", VERTICAL = "TOPLEFT",
            }
            local function deriveRaidAnchor(primary, secondary)
                if primary == "DOWN" or primary == "UP" then
                    local sec = secondary or "RIGHT"
                    if primary == "DOWN" then
                        return (sec == "LEFT") and "TOPRIGHT" or "TOPLEFT"
                    else
                        return (sec == "LEFT") and "BOTTOMRIGHT" or "BOTTOMLEFT"
                    end
                else
                    local sec = secondary or "DOWN"
                    if primary == "RIGHT" then
                        return (sec == "UP") and "BOTTOMLEFT" or "TOPLEFT"
                    else
                        return (sec == "UP") and "BOTTOMRIGHT" or "TOPRIGHT"
                    end
                end
            end
            for _, rpName in ipairs(self.rpDB:GetProfiles()) do
                local rp = self.rpDB.profiles[rpName]
                if rp then
                    local flats = rp.layouts and rp.layouts.flatLayouts
                    local globalSort = rp.sorting
                    local perLayout = rp.layouts and rp.layouts.perLayoutToggles
                                      and rp.layouts.perLayoutToggles.sorting
                    if flats then
                        for _, flat in pairs(flats) do
                            local sp = (perLayout and flat.sorting) or globalSort
                            if flat.type == "raid" then
                                if flat.raidLayoutAnchor == nil then
                                    local gd  = (sp and sp.raidGrowDirection) or "DOWN"
                                    local sgd = sp and sp.raidSecondaryGrowDirection
                                    flat.raidLayoutAnchor = deriveRaidAnchor(gd, sgd)
                                end
                            elseif flat.type == "party" then
                                if flat.partyLayoutAnchor == nil then
                                    local gd = (sp and sp.growDirection) or "RIGHT"
                                    flat.partyLayoutAnchor = PARTY_ANCHOR[gd] or "TOPLEFT"
                                end
                            end
                            -- Clean up old unified field if present.
                            flat.layoutAnchor = nil
                        end
                    end
                end
            end
        end

        if ver < 40 then
            -- Migration 40: add cfSecondaryGrowDirection and cfgLayoutAnchor
            -- to existing Custom Frame Groups. Derive anchor from current
            -- cfGrowDirection using the same map as DeriveGroupAnchor:
            --   DOWN  -> secondary RIGHT -> TOPLEFT
            --   UP    -> secondary RIGHT -> BOTTOMLEFT
            --   RIGHT -> secondary DOWN  -> TOPLEFT
            --   LEFT  -> secondary DOWN  -> TOPRIGHT
            -- Also convert saved positions from old TOPLEFT physical-pixel
            -- format to new CENTER-relative UI coord format.
            local CFG_SECONDARY = {
                DOWN = "RIGHT", UP = "RIGHT", RIGHT = "DOWN", LEFT = "DOWN",
            }
            local CFG_ANCHOR = {
                DOWN = "TOPLEFT", UP = "BOTTOMLEFT", RIGHT = "TOPLEFT", LEFT = "TOPRIGHT",
            }
            for _, cfgName in ipairs(self.cfgDB:GetProfiles()) do
                local cfgp = self.cfgDB.profiles[cfgName]
                if cfgp and cfgp.customFrameGroups then
                    -- Build a map of groupIndex → cfgLayoutAnchor for position conversion.
                    local anchorMap = {}
                    for idx, group in pairs(cfgp.customFrameGroups) do
                        local gd = group.cfGrowDirection or "DOWN"
                        if not group.cfSecondaryGrowDirection then
                            group.cfSecondaryGrowDirection = CFG_SECONDARY[gd] or "RIGHT"
                        end
                        if not group.cfgLayoutAnchor then
                            group.cfgLayoutAnchor = CFG_ANCHOR[gd] or "TOPLEFT"
                        end
                        anchorMap[idx] = group.cfgLayoutAnchor
                        -- Remove obsolete cfSetupFrameCount; frame count is
                        -- now derived from cfUnitsPerColumn * cfMaxColumns.
                        group.cfSetupFrameCount = nil
                    end
                    -- Convert saved positions from { "TOPLEFT", physX, physY }
                    -- to { cfgLayoutAnchor, centerX, centerY }.
                    -- Old format: physX = left edge in physical pixels,
                    --             physY = negative distance from top in physical pixels.
                    -- New format: centerX/centerY = offset from UIParent:GetCenter().
                    -- Since all old positions used TOPLEFT and the new layout
                    -- anchor is also TOPLEFT for DOWN/RIGHT groups (the only
                    -- grow directions that existed before), the conversion is
                    -- just: cx = physX/s - screenW/2, cy = physY/s + screenH/2
                    -- where s = UIParent:GetEffectiveScale().
                    local positions = cfgp.customFrameGroupPositions
                    if positions then
                        local s  = UIParent and UIParent:GetEffectiveScale() or 1
                        local sw = GetScreenWidth  and GetScreenWidth()  or 1920
                        local sh = GetScreenHeight and GetScreenHeight() or 1080
                        local hw, hh = sw / 2, sh / 2
                        for posKey, pos in pairs(positions) do
                            if pos[1] == "TOPLEFT" then
                                -- Extract group index from posKey "customFrame_N"
                                local idx = tonumber(posKey:match("customFrame_(%d+)"))
                                local newAnchor = (idx and anchorMap[idx]) or "TOPLEFT"
                                local uiX = pos[2] / s   -- old: left edge in UI coords
                                local uiY = pos[3] / s   -- old: negative from top
                                -- TOPLEFT corner in CENTER-relative coords:
                                local cx = math.floor(uiX - hw + 0.5)
                                local cy = math.floor(uiY + hh + 0.5)
                                positions[posKey] = { newAnchor, cx, cy }
                            end
                        end
                    end
                end
            end
        end
        if ver < 41 then
            -- Migration 41: derive specSpellIconType from existing
            -- specSpellSolidIcons + specSpellBorderColors enabled flags.
            -- Both enabled → "BorderedSquare", only solid → "Square",
            -- neither → nil (Icon default, no entry stored).
            for _, name in ipairs(self.acDB:GetProfiles()) do
                local acp = self.acDB.profiles[name]
                if acp and acp.specSpellSolidIcons then
                    for specId, spells in pairs(acp.specSpellSolidIcons) do
                        for sid, entry in pairs(spells) do
                            if entry and entry.enabled ~= false then
                                -- Solid icon is enabled for this spell
                                local bcEntry = acp.specSpellBorderColors
                                    and acp.specSpellBorderColors[specId]
                                    and acp.specSpellBorderColors[specId][sid]
                                local borderOn = bcEntry ~= nil and bcEntry.enabled ~= false
                                if not acp.specSpellIconType then acp.specSpellIconType = {} end
                                if not acp.specSpellIconType[specId] then acp.specSpellIconType[specId] = {} end
                                if borderOn then
                                    acp.specSpellIconType[specId][sid] = "BorderedSquare"
                                else
                                    acp.specSpellIconType[specId][sid] = "Square"
                                end
                            end
                        end
                    end
                end
            end
        end
        if ver < 42 then
            -- Migration 42: move container-level cooldown text settings to per-spell.
            -- For each container that had the override enabled
            -- (containerUsesBuffDurationSettings == false), copy its duration
            -- settings to every spell assigned to that container.
            local CDT_FIELDS = {
                "showDuration", "autoScale", "timerScale", "fontSize",
                "durationFont", "durationBorder", "fontColor", "colorAuraBorder",
                "disableSwipe", "reverseSwipe", "disableSpark",
                "thresholdColorEnabled", "thresholdColorThreshold", "thresholdColor",
                "threshold2ColorEnabled", "threshold2ColorThreshold", "threshold2Color",
            }
            local function copyFields(src, dst)
                for _, field in ipairs(CDT_FIELDS) do
                    if src[field] ~= nil and dst[field] == nil then
                        local v = src[field]
                        if type(v) == "table" then
                            dst[field] = {}
                            for k2, v2 in pairs(v) do dst[field][k2] = v2 end
                        else
                            dst[field] = v
                        end
                    end
                end
            end
            for _, name in ipairs(self.acDB:GetProfiles()) do
                local acp = self.acDB.profiles[name]
                if acp and acp.customBuffContainers and acp.spellAssign then
                    for ci, container in ipairs(acp.customBuffContainers) do
                        -- containerUsesBuffDurationSettings == false means override was ON
                        if container.containerUsesBuffDurationSettings == false then
                            local ciKey = "c:" .. ci
                            -- Find all spells assigned to this container
                            for specId, assigns in pairs(acp.spellAssign) do
                                for sid, assignVal in pairs(assigns) do
                                    if assignVal == ciKey then
                                        -- Create the per-spell cooldown text entry
                                        if not acp.specSpellCooldownText then acp.specSpellCooldownText = {} end
                                        if not acp.specSpellCooldownText[specId] then acp.specSpellCooldownText[specId] = {} end
                                        if not acp.specSpellCooldownText[specId][sid] then
                                            acp.specSpellCooldownText[specId][sid] = {}
                                        end
                                        local spellEntry = acp.specSpellCooldownText[specId][sid]
                                        -- Copy top-level container settings
                                        copyFields(container, spellEntry)
                                        -- If container had separateGroupConfig, copy groupSettings too
                                        if container.separateGroupConfig and container.groupSettings then
                                            spellEntry.separateGroupConfig = true
                                            if not spellEntry.groupSettings then spellEntry.groupSettings = {} end
                                            for gKey, gs in pairs(container.groupSettings) do
                                                if not spellEntry.groupSettings[gKey] then
                                                    spellEntry.groupSettings[gKey] = {}
                                                end
                                                copyFields(gs, spellEntry.groupSettings[gKey])
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
        if ver < 43 then
            -- Migration 43: restructure Custom Frame Groups to use a
            -- flat-layout-style table (group.flat) with the same structure
            -- as raid flats. See MigrateCFGToFlatStructure for details.
            self:MigrateCFGToFlatStructure()
        end
        if ver < 44 then
            -- Migration 44: convert CFG groups from metatable-chained
            -- inheritance (baseLayoutID) to fully independent deep-copied
            -- flats. See MigrateCFGToIndependentFlats for details.
            self:MigrateCFGToIndependentFlats()
        end
        if ver < 45 then
            -- Migration 45: move health gradient colors from per-layout
            -- healthPower section to the global colors section. The
            -- useHealthGradient / useBgGradient toggles stay in healthPower.
            local rpP = self.rpDB and self.rpDB.profile
            if rpP then
                local hp = rpP.healthPower
                local cp = rpP.colors
                if hp and cp then
                    local GRADIENT_KEYS = {
                        "healthGradientHigh", "healthGradientMid", "healthGradientLow",
                        "bgGradientHigh", "bgGradientMid", "bgGradientLow",
                    }
                    for _, key in ipairs(GRADIENT_KEYS) do
                        if hp[key] ~= nil and cp[key] == nil then
                            cp[key] = hp[key]
                        end
                        hp[key] = nil  -- clean up old location
                    end
                end
                -- Also clean gradient color keys from per-flat overrides.
                -- The colors are now global; per-flat gradient color keys
                -- would be orphaned data.
                local fl = rpP.layouts and rpP.layouts.flatLayouts
                if fl then
                    for _, flat in pairs(fl) do
                        local fhp = flat and flat.healthPower
                        if fhp then
                            fhp.healthGradientHigh = nil
                            fhp.healthGradientMid  = nil
                            fhp.healthGradientLow  = nil
                            fhp.bgGradientHigh     = nil
                            fhp.bgGradientMid      = nil
                            fhp.bgGradientLow      = nil
                        end
                    end
                end
            end
        end
        if ver < 46 then
            -- Migration 46: convert old UF boolean health-color toggles to
            -- the new dropdown mode keys (globalPlayerHealthColorMode,
            -- globalNpcHealthColorMode).
            local ufp = self.ufDB and self.ufDB.profile
            if ufp then
                -- Player mode: derive from old globalUseClassColor + globalUseHealthGradient
                if ufp.globalPlayerHealthColorMode == nil then
                    if ufp.globalUseHealthGradient then
                        ufp.globalPlayerHealthColorMode = "gradient"
                    elseif ufp.globalUseClassColor == false then
                        ufp.globalPlayerHealthColorMode = "static"
                    else
                        ufp.globalPlayerHealthColorMode = "class"
                    end
                end
                -- NPC mode: derive from old classification / hostility / gradient
                -- booleans.  Priority in the old code was:
                -- classification (default on) > hostility (default on) > gradient > static
                if ufp.globalNpcHealthColorMode == nil then
                    if ufp.globalNpcClassificationColors ~= false then
                        ufp.globalNpcHealthColorMode = "classification"
                    elseif ufp.globalUseHostilityColor ~= false then
                        ufp.globalNpcHealthColorMode = "hostility"
                    elseif ufp.globalUseHealthGradient then
                        ufp.globalNpcHealthColorMode = "gradient"
                    else
                        ufp.globalNpcHealthColorMode = "static"
                    end
                end
                -- Clean up old boolean keys that are fully replaced by the
                -- mode dropdowns.  globalNpcClassificationColors is kept
                -- because the Name Colors system still reads it.
                ufp.globalUseClassColor = nil
                ufp.globalUseHealthGradient = nil
                ufp.globalUseHostilityColor = nil
            end
        end

        if ver < 47 then
            -- Migration 47: convert old UF name-color boolean toggles to
            -- dropdown mode keys (globalPlayerNameColorMode, globalNpcNameColorMode).
            local ufp = self.ufDB and self.ufDB.profile
            if ufp then
                -- Player name mode
                if ufp.globalPlayerNameColorMode == nil then
                    if ufp.globalUseClassColorName == false then
                        ufp.globalPlayerNameColorMode = "static"
                    else
                        ufp.globalPlayerNameColorMode = "class"
                    end
                end
                -- NPC name mode
                if ufp.globalNpcNameColorMode == nil then
                    if ufp.globalNpcClassificationColors ~= false then
                        ufp.globalNpcNameColorMode = "classification"
                    elseif ufp.globalUseHostilityColorName then
                        ufp.globalNpcNameColorMode = "hostility"
                    else
                        ufp.globalNpcNameColorMode = "static"
                    end
                end
                -- Clean up old boolean keys
                ufp.globalUseClassColorName = nil
                ufp.globalUseHostilityColorName = nil
                ufp.globalNpcClassificationColors = nil
            end
        end

        if ver < 48 then
            -- Migration 48: rescue the user's lock-state preference.
            -- The `locked` field is account-wide (db.global.locked) but a
            -- namespacing bug had the canonical setter and every toggle
            -- handler writing to db.profile.locked instead. The fix flips
            -- every writer/reader to db.global.locked, but does so without
            -- knowledge of what the user last toggled — that value is
            -- sitting in the dead db.profile.locked slot on the active
            -- profile. Copy it across so the user doesn't have to re-toggle.
            --
            -- Active-profile-wins policy: if the user has multiple profiles
            -- with diverging dead values, only the currently-active profile
            -- migrates. Other profiles' dead values are discarded (they
            -- weren't being read anyway). Confirmed with the user.
            --
            -- Then strip the dead key from every profile so SavedVariables
            -- doesn't carry it forever.
            local activeLocked = p.locked
            if activeLocked ~= nil then
                self.db.global.locked = activeLocked
            end
            local profiles = self.db and self.db.profiles
            if type(profiles) == "table" then
                for _, prof in pairs(profiles) do
                    if type(prof) == "table" then
                        prof.locked = nil
                    end
                end
            end
        end

        if ver < 49 then
            -- Migration 49: strip the dead openWorldSolo / openWorldRaid fields
            -- from every profile. The v18 migration moved them from db.profile.* to
            -- rpDB.profile.layouts.* as inputs for instanceLayoutAssignment seeding,
            -- after which they were supposed to be dead. But the seed in
            -- Defaults_RaidPartyFrames and a stray runtime read at BFLayout kept
            -- them in SavedVariables forever. The defaults seed and the runtime
            -- reads are now gone (see this commit); strip the SV residue too.
            local rpProfiles = self.rpDB and self.rpDB.profiles
            if type(rpProfiles) == "table" then
                for _, rp in pairs(rpProfiles) do
                    if type(rp) == "table" and type(rp.layouts) == "table" then
                        rp.layouts.openWorldSolo = nil
                        rp.layouts.openWorldRaid = nil
                    end
                end
            end
        end
        if ver < 50 then
            -- Migration 50: offline/dead bar colors moved text → healthPower.
            --
            -- Six keys (offlineBackgroundColor, offlineBackgroundOpacity,
            -- fadeOfflineFrames, deadBackgroundColor, deadBackgroundOpacity,
            -- deadColorOORFactor) used to live in the text section but their
            -- UI widgets are rendered on the Health & Power tab. Their old
            -- location meant the text per-layout toggle governed them, not
            -- the healthPower one, producing surprising party↔raid behavior
            -- (offline bar color changing on group-type switch even with the
            -- Health & Power per-layout toggle off). They now live in
            -- healthPower like every other widget on that tab.
            --
            -- See MigrateOfflineDeadColorsToHealthPower in Core_Migrations.lua.
            -- Idempotent per profile (guarded by rp._offlineDeadColorsRelocated).
            local rpProfiles = {}
            for _, name in ipairs(self.rpDB:GetProfiles()) do
                rpProfiles[#rpProfiles + 1] = name
            end
            for _, name in ipairs(rpProfiles) do
                self:MigrateOfflineDeadColorsToHealthPower(name)
            end
        end
        if ver < 60 then
            -- ── Migration 60 (v65): ONE aura migration ────────────────────
            --
            -- dbVersions 51..59 were nine separate aura migrations written
            -- incrementally across 12.1 PTR testing. None of them ever shipped
            -- -- no profile in the wild is stamped above 50 -- so they are
            -- merged into a single versioned step, plus the seven bugs they
            -- carried. See Docs/Unify_Aura_Migrations_Plan.md for the full
            -- rationale, and the DB_VERSION comment at the top of this file for
            -- why 51..59 are skipped rather than reused.
            --
            -- All nine stages now live behind BF:MigrateAurasUnified in
            -- Core_Migrations.lua, which owns the profile resolution and the
            -- two sentinels (one per database). The internal stage order is
            -- load-bearing and documented there; nothing here should reorder or
            -- reach past it.
            --
            -- Idempotent per profile. Fresh installs are no-ops -- OnNewProfile
            -- stamps new profiles straight at DB_VERSION, so they skip this
            -- dispatcher entirely; acDB profiles, which are created
            -- independently of the main db and therefore never reach this code,
            -- are covered by BF:EnsureAurasMigratedForProfile instead.
            --
            -- Driven off the UNION of the rpDB and acDB profile name lists,
            -- deduped. Each database's profile is selectable independently, so
            -- a name can exist in one and not the other -- driving each half
            -- off only its own list left such a profile half-migrated. Every
            -- stage no-ops on a database where the profile is absent.
            local names, seen = {}, {}
            for _, db in ipairs({ self.rpDB, self.acDB }) do
                for _, name in ipairs(db:GetProfiles()) do
                    if not seen[name] then
                        seen[name] = true
                        names[#names + 1] = name
                    end
                end
            end
            for _, name in ipairs(names) do
                self:MigrateAurasUnified(name)
            end
            -- Custom Frame Groups live in cfgDB, which has its own profile set,
            -- so this one walks cfgDB itself rather than being called per
            -- profile name.
            self:MigrateSplitCFGOverrideAuras()
        end

        if ver < 61 then
            -- Migration 61 (was block 56, v64): force Enable Experimental
            -- Options OFF once.
            --
            -- 12.1 reshuffled what sits behind that toggle -- most notably the
            -- Advanced container layout -- so anyone who had switched it on for
            -- some earlier experiment would silently land on a set of options
            -- they never opted into. This resets it a single time; the user is
            -- free to switch it straight back on and it stays on.
            --
            -- The setting is GLOBAL (account-wide): Defaults.lua declares it
            -- under `global` and MigrateGlobalSettings moves it there. v64 also
            -- repointed every reader and the toggle's own setter at db.global,
            -- which is what that migration always intended -- they had been
            -- reading db.profile, so the moved value was never consulted.
            --
            -- GUARDED BY ITS OWN GLOBAL FLAG, not by dbVersion alone. dbVersion
            -- is per profile, so a bare `p.dbVersion < 61` test would re-run
            -- this for every profile the user later opens -- and since the
            -- value it clears is account-wide, switching to a not-yet-upgraded
            -- profile would silently switch the toggle back off after the user
            -- had deliberately re-enabled it. Same pattern as
            -- _globalSettingsMigrated in MigrateGlobalSettings.
            local g61 = self.db.global
            if g61 and not g61._experimentalResetV64 then
                g61._experimentalResetV64 = true
                -- `false` rather than nil so the intent is visible in the saved
                -- variables; both read as off.
                g61.enableExperimentalOptions = false
            end
            -- Clear the stale per-profile copy every profile carries from the
            -- years this was read off db.profile, so nothing is left behind to
            -- suggest the value still lives there.
            p.enableExperimentalOptions = nil
        end

        if ver < 62 then
            -- ── Migration 62 (v69): Crowd Control feature → custom debuff
            -- container. Same union-of-profile-names walk as migration 60 (a
            -- name can exist in one database and not the other); the migration
            -- itself is sentinel-guarded per acDB profile, and the accessor
            -- (GetCustomDebuffContainers) seeds any acDB profile this walk
            -- never sees. See MigrateCrowdControlToContainer.
            local names62, seen62 = {}, {}
            for _, db in ipairs({ self.rpDB, self.acDB }) do
                for _, name in ipairs(db:GetProfiles()) do
                    if not seen62[name] then
                        seen62[name] = true
                        names62[#names62 + 1] = name
                    end
                end
            end
            for _, name in ipairs(names62) do
                self:MigrateCrowdControlToContainer(name)
            end
        end

        if ver < 64 then
            -- ── Migration 64: Incoming Casts per-display split. The two
            -- display sections shared all 43 appearance/behavior keys, so
            -- editing either tab changed both. The detached display now owns
            -- incomingCastsPlayer<Suffix>; seed each from the value the user
            -- already had so nothing visibly moves. Walks icDB's OWN profile
            -- list -- post-v18 each module is its own root DB -- and is
            -- sentinel-guarded per profile inside the migration.
            for _, name in ipairs(self.icDB:GetProfiles()) do
                self:MigrateIncomingCastsPerDisplay(name)
            end
        end

        if ver < 65 then
            -- ── Migration 65: the two per-Layout aura GROUP toggles
            -- (perLayoutToggles.aurasBuffs / .aurasDebuffs) split again, one
            -- toggle per aura SUB-CATEGORY, so that every aura subtab owns its
            -- own "Enable per-Layout configuration" switch:
            --
            --   aurasBuffs   -> auras_buffs   + auras_bigDef
            --   aurasDebuffs -> auras_debuffs + auras_dispelIndicator
            --
            -- NUMBERING NOTE: the design doc for this change targets
            -- "dbVersion 64" throughout, because it was written while
            -- DB_VERSION was still 63. The Incoming Casts per-display split
            -- above claimed 64 first, so this ships as 65. Anywhere the plan
            -- says 64 for THIS work, read 65. (The plan's own DB_VERSION
            -- comment at the top of this file explains why a number is never
            -- reused or lowered.)
            --
            -- Same union-of-profile-names walk as migrations 60 and 62: each
            -- database's profile set is selectable independently, so a name
            -- can exist in one and not the other, and driving each half off
            -- only its own list would leave such a profile half-migrated.
            --
            -- ONE stage per rpDB profile: _AuraMig_SplitPerLayoutToggleBySubcat
            -- is the dispatcher-time entry point for
            -- BF:NormalizeAuraPerLayoutKeys, which does the translation and
            -- nils the retired keys. The normalizer also runs at load from
            -- RehydrateFlats, which is what covers imported profiles -- those
            -- never reach this dispatcher at all, since dbVersion lives on the
            -- main db.profile and is not imported.
            --
            -- NO container seed. c.perLayoutConfig is deliberately NOT seeded
            -- from the old section toggles: owner ruling 2026-08-15,
            -- per-Layout configuration starts DISABLED for every container and
            -- Single Buff, existing and new -- the user opts in per container.
            -- groupSettings survives untouched, so enabling a container's
            -- toggle brings its old per-Layout data back. (An earlier build of
            -- this block did a union-of-names walk and handed captured b/d to
            -- _AuraMig_SeedContainerPerLayout -- see the tombstone in
            -- Core_Migrations.lua before reintroducing any of that.)
            for _, name in ipairs(self.rpDB:GetProfiles()) do
                local rp65 = self.rpDB.profiles and self.rpDB.profiles[name]
                if type(rp65) == "table" then
                    self:_AuraMig_SplitPerLayoutToggleBySubcat(rp65)
                end
            end
            -- Custom Frame Groups live in cfgDB, which has its own profile
            -- set, so this one walks cfgDB itself rather than being called per
            -- profile name -- same shape as MigrateSplitCFGOverrideAuras in
            -- the ver < 60 block above.
            --
            -- MUST run after the rename loop: it reads the paired rp profile's
            -- auras_<subcat> keys. (It calls BF:NormalizeAuraPerLayoutKeys on
            -- that profile itself as well, so it is safe either way, but the
            -- ordering is the documented one.) See MigrateSeedCFGOverrideFlags
            -- for why the flags have to be seeded at all and why it is
            -- one-shot per cfgDB profile.
            self:MigrateSeedCFGOverrideFlags()
        end

        if ver < 63 then
            -- ── Migration 63 (v70): the two account-wide preview toggles
            -- (db.global.showPreviewAuras on/off + simulateDispellableDebuff)
            -- become the per-tab "Preview" dropdown (previewModeBuffs /
            -- previewModeDebuffs). GUARDED BY A GLOBAL SENTINEL, not dbVersion
            -- alone: the source and target keys are account-wide, so a bare
            -- per-profile `ver < 63` test would re-run on every profile switch
            -- and clobber a value the user had since changed. Same pattern as
            -- _experimentalResetV64 above.
            --
            -- Mapping (old default: both keys nil == on):
            --   showPreviewAuras OFF  -> both tabs "all" (the pane-level off is
            --                            now the master showPreview toggle, so
            --                            we do not carry an auras-off state; the
            --                            dropdown always shows something).
            --   ON  + simulate ON     -> Buffs "all",  Debuffs "allDispel"
            --   ON  + simulate OFF    -> Buffs "all",  Debuffs "all"
            local g63 = self.db.global
            if g63 and not g63._previewModeMigratedV63 then
                g63._previewModeMigratedV63 = true
                -- Only synthesize values the user hasn't already set (defaults
                -- from Defaults.lua may already be present on a fresh install).
                if g63.previewModeBuffs == nil or g63.previewModeDebuffs == nil then
                    local simOn = g63.simulateDispellableDebuff ~= false
                    g63.previewModeBuffs   = g63.previewModeBuffs   or "all"
                    g63.previewModeDebuffs = g63.previewModeDebuffs or (simOn and "allDispel" or "all")
                end
                g63.showPreviewAuras          = nil
                g63.simulateDispellableDebuff = nil
            end
        end

        if ver < 66 then
            -- ── Migration 66 (v84, plan Stage 5 §9.10): the Debuffs section's
            -- "Debuffs to Show" show mode + the four Enlarge toggles become the
            -- composable debuff TYPE model (Base Filter, five typed groups with
            -- their own size/Order, and an orderable "Show Other Debuffs").
            --
            -- Owner ruling: the type rows are a UNIFORM RESET, so the migration
            -- carries NOTHING from the old Enlarge toggles -- it maps the show
            -- mode onto Base Filter / Show Other / Dispellable Mode and nils the
            -- five dead keys. See MigrateDebuffTypeModel in Core_Migrations.lua
            -- for the mapping table and the accepted deltas.
            --
            -- Walks rpDB's OWN profile list (these keys live only in
            -- rp.auras.debuffs and in the per-Layout flats under it), and cfgDB
            -- separately for Custom Frame Group flats. Both halves are
            -- sentinel-guarded per profile inside the migration.
            for _, name in ipairs(self.rpDB:GetProfiles()) do
                self:MigrateDebuffTypeModel(name)
            end
            self:MigrateDebuffTypeModelCFG()
        end

        if ver < 67 then
            -- ── Migration 67 (v84, plan Stage 5 §9.9): the per-spell Icon
            -- Effects rebuild. specSpellExpirationGlow (the threshold-driven
            -- "Glow Border" that 12.1 can never evaluate) and
            -- specSpellVisualAlert (the native 0-10 ants/flash list) collapse
            -- into one specSpellIconEffect row per (spec-or-single-buff key,
            -- spell). See MigrateIconEffects in Core_Migrations.lua for the
            -- mapping and why glow wins a collision.
            --
            -- Walks acDB's OWN profile list -- every per-spell customization
            -- table lives there, not on the main db -- and is sentinel-guarded
            -- per profile inside the migration. acDB profiles created after
            -- this dispatcher (new / copied / reset) never reach it, which is
            -- what BF:EnsureAurasMigratedForProfile exists for; a profile that
            -- misses this one simply keeps two inert legacy tables, so it is
            -- not routed through there.
            for _, name in ipairs(self.acDB:GetProfiles()) do
                self:MigrateIconEffects(name)
            end
        end

        if ver < 68 then
            -- ── Migration 68 (v85): retire three optimization kill switches.
            -- Owner ruling 2026-08-16: optimizations are not gated behind kill
            -- switches — the optimized path IS the code path. "/bf auraskip"
            -- (the v77 aura-button styling skip), "/bf dvmerge" and
            -- "/bf fxmerge" (the v84 merged dispel-visual / per-spell fx slots)
            -- are gone, and so are the branches that read their flags.
            --
            -- The three values are ACCOUNT-WIDE (db.global), so this is guarded
            -- by ITS OWN GLOBAL SENTINEL rather than by dbVersion alone: a bare
            -- per-profile test would re-run on every profile the user later
            -- opens, which is harmless for a delete but is the pattern this
            -- file already settled on for global data (see _experimentalResetV64
            -- above). Nothing reads these keys any more, so this only reclaims
            -- SavedVariables space and stops a stale value from reappearing if a
            -- key name is ever reused.
            --
            -- singleBuffSlotsDisabled is deliberately NOT touched: "/bf sbslots"
            -- still exists and still reads it.
            local g68 = self.db.global
            if g68 and not g68._killSwitchesRetiredV85 then
                g68._killSwitchesRetiredV85 = true
                g68.auraSkipDisabled     = nil
                g68.dispelMergeDisabled  = nil
                g68.fxMergeDisabled      = nil
            end
        end

        if ver < 69 then
            -- ── Migration 69: fold the frame border's separate borderOpacity
            -- scalar into borderColor.a, and retire borderOpacity. This makes
            -- the Border Color picker's alpha the single opacity control and
            -- lines the Raid/Party border model up with the Unit Frames one
            -- (whose border color already carries alpha). Container.lua now
            -- reads borderColor.a. See MigrateBorderOpacityToAlpha /
            -- MigrateBorderOpacityToAlphaCFG in Core_Migrations.lua.
            --
            -- Per-rpDB-profile (global section + every flat), sentinel-guarded
            -- (rp._borderOpacityFoldedV69). Custom Frame Groups live in cfgDB,
            -- which has its own profile set, so that half walks cfgDB itself
            -- once rather than per profile name -- same shape as
            -- MigrateSplitCFGOverrideAuras in the ver < 60 block above.
            -- Idempotent per profile; fresh installs are no-ops.
            for _, name in ipairs(self.rpDB:GetProfiles()) do
                self:MigrateBorderOpacityToAlpha(name)
            end
            self:MigrateBorderOpacityToAlphaCFG()
        end

        if ver < 70 then
            -- ── Migration 70: Grow-from-Center anchor CENTER → cross-axis EDGE.
            -- Grow-from-Center used to pin the layout by a full CENTER anchor,
            -- so anchorX/anchorY stored the block's CENTER on both axes. It now
            -- pins by the cross-axis EDGE (grow DOWN→TOP, UP→BOTTOM, RIGHT→LEFT,
            -- LEFT→RIGHT), centring only perpendicular to the grow axis. The
            -- stored grow-axis coordinate must therefore shift by half the
            -- block's grow-axis full extent so existing layouts do not move; the
            -- cross-axis coordinate is unchanged (center == center there).
            -- Per-rpDB-profile, sentinel-guarded, idempotent. Runs BEFORE
            -- RehydrateFlats, so every field read applies the same defaults
            -- UpdateSize uses (sparse flats have default-equal fields as nil).
            for _, name in ipairs(self.rpDB:GetProfiles()) do
                self:MigrateGrowFromCenterAnchorV70(name)
            end
        end

        if ver < 71 then
            -- ── Migration 71 (v91): the DEBUFF PRIORITY LIST.
            -- The four per-type Order dropdowns, debuffOtherOrder and the
            -- Dispellable Mode dropdown are replaced by ONE reorderable list of
            -- seven rows carrying UNIQUE ranks 1..7 (Boss, Role, CC, Dispellable
            -- by Me, Dispellable by Others, Priority, Other) plus three Combine
            -- checkboxes. Behavior-preserving: old orders (tie-broken by the
            -- canonical sequence) become 1..7 with the two dispel rows adjacent
            -- in Dispellable's old slot; mode "all" becomes the combined dispel
            -- row, mode "me" leaves By Others switched off; combineBossRole
            -- reproduces the retired same-size auto-merge; the old keys are
            -- pruned. See MigrateDebuffPriorityList / *CFG / *AC in
            -- Core_Migrations.lua.
            --
            -- Three halves, three profile sets -- the ver < 69 / ver < 60 shape:
            -- rpDB is walked per profile name; cfgDB (Custom Frame Groups) and
            -- acDB (custom debuff containers, where the retired allDispellable
            -- preset becomes othersDispellable + meDispellable) have their own
            -- profile sets, so those two walk themselves ONCE. All three are
            -- sentinel-guarded (_debuffPriorityListV91) and idempotent; fresh
            -- installs stamp straight at DB_VERSION and never reach this block.
            for _, name in ipairs(self.rpDB:GetProfiles()) do
                self:MigrateDebuffPriorityList(name)
            end
            self:MigrateDebuffPriorityListCFG()
            self:MigrateDebuffPriorityListAC()
        end

        if ver < 72 then
            -- ── Migration 72 (v92): STABLE MULTI-ICON CONTAINER KEYS.
            -- Every multi-icon custom BUFF container gains
            -- containerKey = "c_<n>" (first-unused-slot, like singleBuffKey and
            -- cfgFlatID). It is the identity a Single Buff's flow anchor points
            -- at as "C:<key>": the array index ci shifts on every delete and
            -- nothing renumbers it, so an index-based reference would silently
            -- repoint at the entry that inherited the slot.
            --
            -- acDB has its OWN profile set (custom containers live there), so
            -- MigrateContainerKeysAC walks itself ONCE -- no per-profile loop
            -- here, the same shape as the *AC halves of ver < 71. Single buffs
            -- are skipped (they carry singleBuffKey and are never a host), no
            -- anchor values need translating (the new sentinels only exist
            -- after v92), and the pass is sentinel-guarded per acDB profile
            -- (_containerKeysV92) and idempotent -- an entry that already has a
            -- key keeps it. Fresh installs stamp straight at DB_VERSION and
            -- never reach this block.
            self:MigrateContainerKeysAC()
        end

        if ver < 73 then
            -- ── Migration 73 (Phase L): STRIP LEGACY LAYOUT DATA.
            -- Deletes the pre-flat named-layout keys (layouts.layouts and
            -- its tier tables, activeLayout, role/specLayoutAssignment,
            -- specLayouts, enableRole/SpecLayouts, enableRaid20/30/40,
            -- separateRaidBySize, separateRaidAuras, and the legacy
            -- frameWidth/Height/Spacing trio) from every RaidPartyFrames
            -- profile, mining any unconverted profile through the v19/v20
            -- flat-model migrations first so no user data is lost. The two
            -- _*Migrated sentinels are deliberately kept. Also strips the
            -- dead raid40/30/20 buckets from every ufLayouts entry
            -- (unreachable since separateUFByGroupType was retired).
            -- See Docs/_PLAN_ExportStringSize.md Phase L (§L.6/§L.6a).
            -- Both halves are idempotent; fresh installs stamp straight at
            -- DB_VERSION and never reach this block.
            for _, name in ipairs(self.rpDB:GetProfiles()) do
                self:StripLegacyLayoutData(name)
            end
            self:StripLegacyUFLayoutBuckets()
        end

        if ver < 74 then
            -- ── Migration 74: DEAD-KEY PURGE (2026-08-24 full sweep).
            -- One consolidated removal of every verified reader-less
            -- SavedVariables key across acDB (SotF remnants,
            -- specSpellBlizzardBorders), ufDB (dead toggles, the
            -- oufAstralBar* family, legacy color modes, keys dropped from
            -- the defaults the same day), rpDB (privateAuraBorderScale)
            -- and cfgDB per-group fossils. See PurgeDeadModuleKeysV74 in
            -- Core_Migrations.lua and the sweep record in
            -- Docs/_PLAN_ExportStringSize.md. Idempotent; fresh installs
            -- stamp straight at DB_VERSION and never reach this block.
            self:PurgeDeadModuleKeysV74()
        end

        if ver < 75 then
            -- ── Migration 75: PER-SUBTAB PER-LAYOUT TOGGLES.
            -- The "Enable per-Layout Config" toggle for text / icons /
            -- borders / healthPower / absorbs moved from one key per
            -- section to one per SUBTAB (Docs/_PLAN_PerLayoutSubtabToggles
            -- .md). This walks every rpDB profile and translates the old
            -- section key onto ALL of its subtab keys (seed-only-when-nil,
            -- behavior-preserving), then nils it. The same normalizer is
            -- hooked from RehydrateFlats for the paths a dbVersion block
            -- cannot reach (import, profile copy/reset). Idempotent.
            if self.NormalizeSectionPerLayoutKeys and self.rpDB then
                for _, name in ipairs(self.rpDB:GetProfiles()) do
                    self:NormalizeSectionPerLayoutKeys(self.rpDB.profiles[name])
                end
            end
        end

        if ver < 76 then
            -- ── Migration 76: _bf_hasSotFSpell OUT OF SAVED VARIABLES.
            -- The per-container Soul of the Forest gate is a runtime cache
            -- (rebuilt on every InvalidateClaimedSpellCache) that used to be
            -- stamped onto the container tables themselves — i.e. straight
            -- into acDB SavedVariables, where inactive-spec entries kept
            -- stale copies forever (owner spotted it in an export audit,
            -- 2026-08-24). It now lives in the weak-keyed
            -- BF._containerHasSotF map (AuraCustomizations.lua); the rebuild
            -- loop lazily strips the field from ACTIVE containers, and this
            -- one-shot sweeps it from every container of every acDB profile
            -- so the inactive rest is cleaned too. Idempotent.
            if self.acDB and self.acDB.profiles then
                for _, acp in pairs(self.acDB.profiles) do
                    local containers = type(acp) == "table" and acp.customBuffContainers
                    if type(containers) == "table" then
                        for _, c in pairs(containers) do
                            if type(c) == "table" and rawget(c, "_bf_hasSotFSpell") ~= nil then
                                c._bf_hasSotFSpell = nil
                            end
                        end
                    end
                end
            end
        end

        if ver < 77 then
            -- ── Migration 77: SWIFTMENDABLE REHOMED TO THE BUFF LIST.
            -- Two parts, both in Core_Migrations.lua:
            --   (a) purge swiftmendRecolorHealthText / swiftmendHealthTextColor
            --       from every acDB profile. Health-TEXT recolor only ever
            --       existed on the pre-12.1 Lua path (BF:UpdateSwiftmendable),
            --       whose latch nothing armed; the keys were unreachable and
            --       are dropped from ProfileExport's AC_SECTIONS with this.
            --   (b) seed the "Swiftmendable" pseudo entry, the Buff List row
            --       that now hosts the feature's settings. Idempotent, and
            --       also seeded lazily by SeedPseudoSingleBuffs for profiles a
            --       dbVersion block cannot reach (import, copy, reset).
            self:MigrateSwiftmendableToBuffList()
        end

        if ver < 78 then
            -- ── Migration 78: UF ROLE/SPEC OVERRIDES BECOME ENTRIES.
            -- Unit Frame Layouts is one list of override entries now, the
            -- shape the raid Layouts section already uses, and the two
            -- enable switches are gone from the panel. This turns the old
            -- data into entries: a role earns one where its assignment was
            -- something other than "default", specs keep the presence table
            -- they already had -- and a kind whose switch was OFF earns
            -- none at all, because those assignments never resolved and
            -- carrying them would start changing layouts on login. See the
            -- long note on the body in Core_Migrations.lua.
            self:MigrateUFRoleSpecEntries()
        end

        if ver < 79 then
            -- ── Migration 79: THE raid25 SLOT.
            -- Layouts by Instance Type gained "Raid (25 Man)" for
            -- Midnight's Mythic Flex. A 25-player raid used to resolve
            -- through the raid30 slot, so raid30's assignment is what was
            -- governing those raids -- every role and spec override that
            -- had an opinion about raid30 inherits it for raid25, which
            -- makes the update invisible in game until the user chooses
            -- to split the two. The GLOBAL map is seeded by
            -- ScrubInvalidSlotAssignments on every load (Rule D-prime),
            -- which is what covers imports; this block is what covers the
            -- sparse override layers, where a per-load seeder would keep
            -- resurrecting overrides the user had cleared. Idempotent.
            self:MigrateSeedRaid25Slot()
        end

        if ver < 80 then
            -- ── Migration 80: CONTAINER-ASSIGNED SPELLS -> BUFF LIST ENTRIES.
            -- Every spellAssign "c:<i>" (the Ace panel's per-spec way of
            -- putting a spell in a multi-icon buff container) becomes ONE
            -- Buff List entry per (container, spell), anchored to that
            -- container, non-customized, with the container's own
            -- Conditions copied onto it and its old Order slot kept; the
            -- assignment is released to "default" and the selectedSpells
            -- mirror cleared. acDB has its own profile set, so the pass
            -- walks itself ONCE, sentinel-guarded per profile
            -- (_containerSpellsToBuffListV80) and idempotent. Fresh installs
            -- stamp straight at DB_VERSION and never reach this block. See
            -- MigrateContainerSpellsToBuffList in Core_Migrations.lua.
            self:MigrateContainerSpellsToBuffList()
        end

        p.dbVersion = DB_VERSION
    end
    -- §L5.1: the whole 56-block versioned dispatcher. Expected ~0 on a
    -- profile already stamped at DB_VERSION -- if it is not, the gate leaks.
    self:LoadMark("init:postDispatcher")

    -- Restore active UF layout from persisted value. (The RP-side
    -- equivalent is gone -- Phase L removed the named-layout system; the
    -- UF layout system is independent and stays.) This runs AFTER the versioned
    -- migration dispatcher so that on v18 the first access to
    -- self.ufDB.profile hits a fully-populated SV table. AceDB's
    -- metatable merges defaults into the saved data recursively on
    -- this first access, producing a complete profile without
    -- destroying any saved sub-table contents.
    do
        local ufp = self.ufDB.profile
        local savedUFID = ufp.activeUFLayout or "default"
        -- Phase L (§L.6a): seed the party bucket only -- the raid40/30/20
        -- buckets have been unreachable since separateUFByGroupType was
        -- retired (GetUFAnchor hardcodes "party" as the only live path).
        if not ufp.ufLayouts then ufp.ufLayouts = { default = { name="Default", party={} } } end
        if not ufp.ufLayouts[savedUFID] then savedUFID = "default" end
        self._ufActiveLayout = savedUFID
    end

    -- ── One-shot: remove the retired separateUFByGroupType key ─────────────
    -- 2026-08-15 (owner decision): the key is RETIRED, not parked. Its four
    -- readers in Core_UFLayout.lua are gone (the "party" arm was the only
    -- reachable one), its default is gone, and the toggle that wrote it is
    -- deleted.
    --
    -- This used to run on EVERY login, which was the wrong shape: a key that
    -- is wiped on every load is neither preserved nor removed, and the
    -- options file simultaneously claimed the value was "left untouched so
    -- the future implementation can migrate or reuse existing saved state".
    -- Those two statements could not both be true. The key is now cleared
    -- ONCE, under a global sentinel, and never touched again.
    --
    -- Placement is deliberate: after the versioned migration dispatcher, so
    -- the UF namespace relocation in MigrateUnitFramesProfile (which lists
    -- this key) has already moved any legacy copy into ufDB before it is
    -- cleared. Moving this block earlier would let that relocation put the
    -- key back after the purge had run.
    do
        local g = self.db and self.db.global
        if g and not g._separateUFByGroupTypeRemoved then
            g._separateUFByGroupTypeRemoved = true
            local ufSV = _G.BuzzardFramesUnitFramesDB
            if ufSV and ufSV.profiles then
                for _, prof in pairs(ufSV.profiles) do
                    if prof.separateUFByGroupType ~= nil then
                        prof.separateUFByGroupType = nil
                    end
                end
            end
        end
    end

    -- ── Every-login purge: retired aura sub-categories + dead keys ─────────
    -- The Important (v64), Private Auras (v67) and Crowd Control (v69)
    -- features were removed, but nothing ever nilled the data they left
    -- behind. It persists once per profile in the global pseudo-Layout, once
    -- per Layout flat and once per Custom Frame Group flat. (When this purge
    -- was written the old exporter serialised whole profile tables verbatim,
    -- so every export string also carried the dead payload into every
    -- recipient; the format-4 exporter is whitelist-driven, so today the
    -- purge is about SavedVariables hygiene and legacy-string imports.)
    --
    -- Three things about this block are load-bearing:
    --
    -- 1. PLACEMENT: after the versioned dispatcher, not before it. The
    --    precedent purge (healerBuffFilter, ~:308) sits BEFORE the dispatcher;
    --    copying that placement would run this purge before migration 62
    --    (MigrateCrowdControlToContainer) reads the very keys being deleted.
    --    It sits beside the separateUFByGroupType purge above instead, and
    --    still ahead of RehydrateFlats.
    -- 2. PATH-SCOPED, NEVER NAME-SCOPED. "important" and "crowdControl" are
    --    also LIVE acDB container-preset names (AuraCustomizations.lua's
    --    CONTAINER_PRESET_ORDER / DEBUFF_CONTAINER_PRESET_ORDER, and the
    --    `presets = { crowdControl = true }` written by migration 62). A purge
    --    written as "delete any key called crowdControl" would destroy every
    --    user's Crowd Control and Important CONTAINERS. Only the six explicit
    --    rpDB-shaped paths below are touched.
    -- 3. THE CC KEYS ARE SENTINEL-GATED. Migration 62 reads
    --    auras.crowdControl / auraText.crowdControl live, and its only
    --    dispatch route is gated `ver < 62`, so it never runs for: a user
    --    still on <= v68; an rpDB profile with no same-named acDB profile
    --    (the migration returns early WITHOUT stamping a sentinel); a reset
    --    acDB profile; or an imported profile (no dbVersion pass at all). In
    --    each of those the rpDB CC data is the only surviving record of the
    --    user's Crowd Control look. So a profile's CC keys are purged only
    --    once the paired acDB profile carries _ccContainerSeededV69, i.e.
    --    once the container that replaced them exists.
    --
    -- Everything else here is unconditional: important / privateAuras have
    -- zero surviving readers (their routing blocks are gone from
    -- AURAS_SUBCATEGORY_OF / AURA_TEXT_SUBCATEGORY_OF, so no getter, setter,
    -- theme or fallback can reach them), and the tooltip / auraText-root /
    -- db.global entries below are orphans that no code path names any more.
    --
    -- Runs on EVERY login rather than behind a dbVersion gate, and walks the
    -- RAW _G.BuzzardFrames*DB.profiles tables like the four purge precedents
    -- above it: that reaches every profile without activating AceDB
    -- metatables, so a profile switch, a profile copy or an import can never
    -- resurrect the keys.
    --
    -- NOTE: the matching defaults had to go in the same build (see
    -- Defaults_RaidPartyFrames.lua and Defaults.lua). AceDB's copyDefaults
    -- rawsets declared defaults straight back into the profile, so purging a
    -- key that is still declared is a no-op that silently reverts.
    do
        local rpSV  = _G.BuzzardFramesRaidPartyFramesDB
        local acSV  = _G.BuzzardFramesAuraCustomizationsDB
        local cfgSV = _G.BuzzardFramesCustomFrameGroupsDB

        -- Retired sub-categories under BOTH the auras and auraText sections.
        local DEAD_SUBCATS = { "important", "privateAuras" }
        -- auraText ROOT orphans: v15 hoisted these to the auraText root and
        -- v30 can no longer nest them (their keys left AURA_TEXT_SUBCATEGORY_OF
        -- with the features), so they sit at the section root forever.
        local DEAD_AURATEXT_ROOT = {
            "showImportantDuration", "importantAutoScale", "importantTimerScale",
            "importantFontSize", "importantDurationFont", "importantDurationBorder",
            "reverseImportantSwipe", "disableImportantSwipe", "disableImportantSpark",
            "showPrivateAuraDuration", "disablePrivateAuraSwipe",
        }
        -- Tooltip keys for both dead features. The CC three are unconditional
        -- despite the rule above: migration 62 does not read them -- it
        -- explicitly DROPS them, because containers follow the Debuffs tooltip
        -- settings.
        local DEAD_TOOLTIPS = {
            "showImportantTooltip", "showImportantTooltipInCombat",
            "importantTooltipPosition",
            "showCrowdControlTooltip", "showCrowdControlTooltipInCombat",
            "crowdControlTooltipPosition",
        }

        -- One "holder" is any table carrying the per-Layout sections at their
        -- normal paths: an rpDB profile (the global pseudo-Layout), a Layout
        -- flat, or a Custom Frame Group's own flat. All three have the same
        -- shape, which is why one function covers all three levels.
        -- rawget on the way in so the ACTIVE profile's live metatable chains
        -- (AceDB defaults, WireSectionFallback) cannot make us mistake an
        -- inherited table for a stored one.
        local function purgeHolder(holder, ccOK)
            if type(holder) ~= "table" then return end
            local a = rawget(holder, "auras")
            if type(a) == "table" then
                for i = 1, #DEAD_SUBCATS do a[DEAD_SUBCATS[i]] = nil end
                if ccOK then a.crowdControl = nil end
            end
            local at = rawget(holder, "auraText")
            if type(at) == "table" then
                for i = 1, #DEAD_SUBCATS do at[DEAD_SUBCATS[i]] = nil end
                if ccOK then at.crowdControl = nil end
                for i = 1, #DEAD_AURATEXT_ROOT do at[DEAD_AURATEXT_ROOT[i]] = nil end
            end
            local tt = rawget(holder, "tooltips")
            if type(tt) == "table" then
                for i = 1, #DEAD_TOOLTIPS do tt[DEAD_TOOLTIPS[i]] = nil end
            end
        end

        -- Has migration 62 finished for the acDB profile of this name? Both
        -- databases are keyed by profile name, and the aura migrations pair
        -- them by EXACT NAME (MigrateAurasUnified, MigrateCrowdControlToContainer),
        -- so the same pairing decides the CC gate here. No pair, no purge.
        local function ccSeeded(name)
            local acp = acSV and acSV.profiles and acSV.profiles[name]
            return type(acp) == "table" and acp._ccContainerSeededV69 == true
        end

        if rpSV and rpSV.profiles then
            for name, prof in pairs(rpSV.profiles) do
                local ccOK = ccSeeded(name)
                purgeHolder(prof, ccOK)
                local lay = type(prof) == "table" and rawget(prof, "layouts")
                local fl  = type(lay) == "table" and rawget(lay, "flatLayouts")
                if type(fl) == "table" then
                    for _, flat in pairs(fl) do purgeHolder(flat, ccOK) end
                end
            end
        end

        -- Custom Frame Group flats live in cfgDB and hold a full copy of the
        -- same section shape. Migration 62 never reads them (per-CFG-group CC
        -- visibility was dropped outright), but the CC half is gated on the
        -- same-named acDB profile anyway, matching the rpDB rule -- the cost
        -- of being conservative here is a few bytes on an unpaired profile.
        if cfgSV and cfgSV.profiles then
            for name, prof in pairs(cfgSV.profiles) do
                local ccOK  = ccSeeded(name)
                local groups = type(prof) == "table" and rawget(prof, "customFrameGroups")
                if type(groups) == "table" then
                    for _, grp in pairs(groups) do
                        if type(grp) == "table" then
                            purgeHolder(rawget(grp, "flat"), ccOK)
                        end
                    end
                end
            end
        end

        -- Account-wide preview toggles for the same three dead features. These
        -- are db.global, not per profile, so there is nothing to walk.
        local gDead = self.db and self.db.global
        if gDead then
            gDead.showDummyCrowdControl   = nil
            gDead.showDummyImportant      = nil
            gDead.showDummyPrivateAuras   = nil
            gDead.previewPrivateAuraCount = nil
        end
    end

    -- Seed + wire metatable defaults on every flat in the current
    -- rpDB profile. Runs AFTER the versioned migration dispatcher so
    -- v23 has already collapsed default-equal rawkeys to nil; this
    -- call then attaches the __index template so those nil lookups
    -- transparently resolve to the appropriate default value.
    -- Must also run before the callback registration block below so
    -- any immediate profile-related UI queries after login see wired
    -- flats.
    -- §L5.1: closes the every-login retired-sub-category purge (§L1.0 row 16).
    self:LoadMark("init:postPurges")
    self:RehydrateFlats()
    self:LoadMarkD("init:rehydrateFlats")
    self:RehydrateCFGFlats()

    -- One-pass scrub of the slot→flat assignment maps. Runs every load
    -- because flats can be deleted between sessions, leaving the
    -- instanceLayoutAssignment / roleOverrides / specOverrides tables
    -- pointing at non-existent IDs. Must run AFTER RehydrateFlats so
    -- the seeded defaults (flat_party / flat_raid40) are present, and
    -- AFTER the versioned migration dispatcher above so it isn't fixing
    -- data that a migration is about to overwrite. Idempotent on a clean
    -- profile (early-exits without writing). See
    -- BF:ScrubInvalidSlotAssignments in Core_Migrations.lua.
    -- §L5.1: brackets RehydrateFlats + RehydrateCFGFlats exactly (§L1.0
    -- rows 17-18); the scrub that follows gets its own detail mark.
    self:LoadMark("init:postRehydrate")
    self:ScrubInvalidSlotAssignments()
    self:LoadMarkD("init:postScrub")

    -- Register per-module profile callbacks. Each module DB routes to
    -- a dedicated handler so only that module's refresh work runs,
    -- rather than the full RefreshAll pipeline on every switch.
    -- OnProfileCopied and OnProfileReset also need the same handling.
    -- Registered here — after the v18 migration block — so the
    -- handlers do not fire on half-migrated state.
    for _, pair in ipairs({
        { self.rpDB,  "OnRPProfileChanged"  },
        { self.acDB,  "OnACProfileChanged"  },
        { self.cfgDB, "OnCFGProfileChanged" },
        { self.ufDB,  "OnUFProfileChanged"  },
        { self.icDB,  "OnICProfileChanged"  },
    }) do
        local db, handler = pair[1], pair[2]
        db.RegisterCallback(self, "OnProfileChanged", handler)
        db.RegisterCallback(self, "OnProfileCopied",  handler)
        db.RegisterCallback(self, "OnProfileReset",   handler)
    end

    -- acDB profiles are created independently of the main db, so the
    -- dbVersion-gated dispatcher above never sees a NEW one. The
    -- copied / reset / changed cases are chained from OnACProfileChanged in
    -- Core_ProfileLifecycle.lua -- registering them here too would overwrite
    -- that handler, since CallbackHandler keys on event + target.
    self.acDB.RegisterCallback(self, "OnNewProfile", "EnsureAurasMigratedForProfile")

    -- Register OnProfileShutdown on ufDB only. This fires BEFORE the
    -- profile pointer is reassigned, so we can snapshot the old values
    -- of reload-sensitive keys and compare them to the new profile in
    -- OnProfileChanged. If any differ, a reload popup is shown.
    self.ufDB.RegisterCallback(self, "OnProfileShutdown", "OnUFProfileShutdown")
    -- §L5.1: RegisterDB done. init:dbDone - init:enter is the RegisterDB
    -- half of OnInitialize; init:exit - init:dbDone is RegisterOptions.
    self:LoadMark("init:dbDone")
end

-- ============================================================
-- POST-MIGRATION CHAT MESSAGE (dbVersion 18)
-- ============================================================
-- The v18 migration block sets db.global._postMigrationChatMessage = true
-- on users who upgraded from an older version. This handler prints a
-- one-time notice on the first PLAYER_LOGIN after migration, then clears
-- the flag so it doesn't fire again.
-- Registered from Initialization.lua's OnEnable alongside the other events.
function BF:PLAYER_LOGIN()
    if self.db and self.db.global and self.db.global._postMigrationChatMessage then
        print("|cffd3ff7dBuzzardFrames:|r Your profiles have been updated for the new modular Profile system. Open /bf -> Profiles to manage per-module profiles.")
        self.db.global._postMigrationChatMessage = nil
    end
    -- One-time notifications (Core_Notifications.lua). Deferred a moment: this
    -- fires during login while Blizzard's own popups (and any pending
    -- reload/upgrade dialogs) are still settling, and a StaticPopup shown into
    -- that window can be pushed off the stack unseen.
    if self.ShowPendingNotifications then
        C_Timer.After(5, function()
            if BF.ShowPendingNotifications then BF:ShowPendingNotifications() end
        end)
    end
end

-- Perf plan §L5.1 load-time mark: 118 KB (.toc 59).
if BuzzardFrames then BuzzardFrames:LoadMark("chunk:coreDB") end
