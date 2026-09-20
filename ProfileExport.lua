-- ============================================================
-- BuzzardFrames: ProfileExport.lua
--
-- Phase E steps 1-2 (Docs/_PLAN_ExportStringSize.md §E.3):
--
--   step 1 (§E.3.1/§E.3.2) — the declarative export-module registry,
--     the sparse portable builders, the whitelist completeness audit,
--     and the Phase 0 per-module size measurement.
--   step 2 (§E.3.3/§E.3.4) — the "!4!" envelope (AceSerializer +
--     LibDeflate + EncodeForPrint), its decoder with the per-module
--     schema gate, the §3.3 deep merge that applies imported data, and
--     the §3.9.1 reconstruction-marker guard. See the section header
--     further down for the string layout.
--
-- The Export button runs BF:ExportProfileString from here; the Import
-- tab in Options_Profiles.lua routes "!4!" strings to
-- BF:DecodeProfileString and everything else to its frozen flat-era
-- decoder, then applies BOTH through BF:DeepMergeProfile.
--
-- Design rules implemented here (owner-ratified in the plan):
--   * WHITELIST, not blacklist (§E.3.2): a portable table is BUILT
--     from each module's registered sections. Runtime caches and
--     migration sentinels are excluded by construction. The audit
--     below is the safety net for unregistered keys.
--   * SPARSE BY CONSTRUCTION (§3 as a build requirement): any value
--     deep-equal to the module's current default is omitted. Flats
--     are stripped against a fresh CreateRaidProfile /
--     CreatePartyProfile template of their own type (§3.4), keeping
--     the four invariants (+ cfgFlatID) as real keys — EXCEPT the
--     per-Layout section sub-tables, which strip against the
--     exporter's GLOBAL section because that is the receiver's
--     WireSectionFallback base, and only ONE LEVEL deep (each
--     section key whole-or-omitted; see BuildSparseFlat's DEPTH
--     RULE — receivers read flat sub-tables wholesale, so a
--     partially stripped nested table would read broken).
--   * §3.3 diff rules, total over every table shape: recurse ONLY
--     into tables whose keys are all strings; everything else is
--     one atomic value, identical or kept wholesale.
--   * Serializer is AceSerializer (owner, 2026-08-24: LibSerialize
--     was considered and explicitly rejected).
--
-- Key-classification convention (audit contract):
--   * whitelisted            -> exported (sparse)
--   * "_"-prefixed, unknown  -> assumed migration/bookkeeping state:
--                               excluded, reported as info only.
--                               Real features never use "_" names.
--   * anything else unknown  -> AUDIT WARNING. Either register it or
--                               add it to the module's `excluded`
--                               list — never leave it unclassified.
-- ============================================================
local BF = _G["BuzzardFrames"]

-- Runtime caches that may sit on flats / sections / containers —
-- excluded by construction here. Superset of the legacy ScrubProfile
-- skip set (Options_Profiles.lua RUNTIME_PROFILE_KEYS): keep the two
-- lists in sync when adding entries.
local RUNTIME_KEYS = {
    _auraCache    = true,
    _sectionCache = true,
    _stash        = true,
    -- Retired runtime flag (2026-08-24): the per-container SotF gate now
    -- lives in the weak BF._containerHasSotF map and migration 76 sweeps
    -- the saved copies; excluded here so a not-yet-swept profile can
    -- never export it.
    _bf_hasSotFSpell = true,
}

-- ── §3.3 primitives ─────────────────────────────────────────────

local function IsPureStringMap(t)
    for k in pairs(t) do
        if type(k) ~= "string" then return false end
    end
    return true
end

local function DeepEqual(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k, v in pairs(a) do
        if not DeepEqual(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

-- Deep copy of raw keys. Serializable values only: userdata /
-- function / thread values are dropped (the same degradation the
-- legacy ScrubProfile chose — a runtime stamp we have not thought
-- of becomes a missing key, never a hard error on Export).
local function DeepCopy(v, seen)
    local vt = type(v)
    if vt == "string" or vt == "number" or vt == "boolean" then return v end
    if vt ~= "table" then return nil end
    seen = seen or {}
    if seen[v] then return nil end   -- cut cycles
    seen[v] = true
    local out = {}
    for k, sv in pairs(v) do
        local kt = type(k)
        if not RUNTIME_KEYS[k] and (kt == "string" or kt == "number") then
            local c = DeepCopy(sv, seen)
            if c ~= nil then out[k] = c end
        end
    end
    seen[v] = nil
    return out
end

-- BuildSparse(live, defaults): sparse deep copy of `live`, omitting
-- everything deep-equal to `defaults`. Returns nil when nothing
-- differs (callers omit the whole key). §3.3 recursion rule: only a
-- pure-string-map on BOTH sides recurses; any other shape is atomic.
local function BuildSparse(live, defaults)
    if type(live) ~= "table" then
        if live == defaults then return nil end
        return live
    end
    if type(defaults) ~= "table" then
        -- No default counterpart: the whole subtree is user data.
        local c = DeepCopy(live)
        if defaults == nil and c ~= nil and next(c) == nil then
            -- Empty dynamically-created table: absence means the same
            -- thing on the receiving end (AceDB returns nil) — omit.
            return nil
        end
        return c
    end
    if not (IsPureStringMap(live) and IsPureStringMap(defaults)) then
        -- Atomic shape (array / mixed / numeric keys): identical or
        -- kept wholesale.
        if DeepEqual(live, defaults) then return nil end
        return DeepCopy(live)
    end
    local out
    for k, v in pairs(live) do
        if not RUNTIME_KEYS[k] then
            local kept = BuildSparse(v, defaults[k])
            if kept ~= nil then
                out = out or {}
                out[k] = kept
            end
        end
    end
    return out
end

-- ── Flat stripping (§3.4) ───────────────────────────────────────
-- A flat's un-customized keys already resolve through its
-- WireFlatDefaults __index template, and pairs() sees rawkeys only —
-- but rawkeys that EQUAL the template value can still be present
-- (the template cannot strip them the way AceDB strips defaults).
-- Strip those here; the receiving end re-wires the template via
-- RehydrateFlats / RehydrateCFGFlats (Options_Profiles.lua already
-- documents this expectation for sparse imports).

local FLAT_INVARIANTS = {
    name = true, type = true, anchorX = true, anchorY = true,
    -- CFG flat identity (aura scope keys point at it — §E.2).
    cfgFlatID = true,
}

-- Per-Layout section sub-tables are the EXCEPTION to template
-- stripping (owner ruling, 2026-08-24). WireSectionFallback wires
-- flat.<section>'s __index at the GLOBAL section
-- (rpDB.profile[section]) on both the exporting and the receiving
-- end — raid/party flats via RehydrateFlats, CFG flats via
-- RehydrateCFGFlats — so a rawkey missing from the flat resolves
-- from the receiver's GLOBAL section, not from the type template.
-- Stripping these against the template would corrupt the receiver's
-- view whenever the exporter's global section was customized: a flat
-- rawkey equal to the template default (but different from the
-- global) would be dropped, and the receiver would read the imported
-- global's customized value instead. Strip against the exporter's
-- own global section instead: a rawkey equal to the global is
-- exactly the redundancy the fallback reconstructs (the globals
-- travel in the same export), while anything else must stay a real
-- key. Split (per-subtab) sections read through GetMergedSectionView,
-- which overlays flat rawkeys over the same global — the same strip
-- base is correct there too.
--
-- DEPTH RULE — one level, whole-or-omitted (2026-08-24 in-game
-- crash fix). Every receiver-side read of a flat section resolves
-- fallbacks at the TOP LEVEL of the section only: the
-- WireSectionFallback __index covers missing section KEYS, and
-- GetMergedSectionView overlays `view[k] = rawget(flat_section, k)`
-- wholesale. A nested table that travels PARTIALLY stripped (say
-- borders.aggroColor3 = { b = 0 } with r/g stripped as
-- default-equal) therefore shadows the complete global table and
-- its missing components read nil — which is exactly the imported
-- SetVertexColor crash in SetHighlightBorder. So inside a flat's
-- per-Layout section, each key is either OMITTED (deep-equal to the
-- strip base) or kept WHOLE via deep copy — never recursed into.
-- The same top-level-only logic applies to the flat itself
-- (WireFlatDefaults' __index covers flat KEYS only), so non-section
-- table values on the flat are likewise atomic against the
-- template. This forgoes some sparseness inside auras/auraText
-- sub-categories (their second-tier fallback could support deeper
-- stripping) — correctness over size; step 3's measurements will
-- say whether that ever mattered.
local perLayoutSectionSet
local function IsPerLayoutSectionKey(k)
    if not perLayoutSectionSet then
        local list = BF._perLayoutSections
        if type(list) ~= "table" then return false end
        perLayoutSectionSet = {}
        for i = 1, #list do perLayoutSectionSet[list[i]] = true end
    end
    return perLayoutSectionSet[k] == true
end

-- One-level sparse for a flat's per-Layout section sub-table (see
-- the DEPTH RULE above): every key is either omitted (deep-equal to
-- the strip base) or deep-copied WHOLE. Never recurses.
local function BuildSparseSectionOneLevel(sec, base)
    local out
    local baseIsTable = type(base) == "table"
    for k, v in pairs(sec) do
        if not RUNTIME_KEYS[k] then
            local bv = baseIsTable and base[k] or nil
            if not DeepEqual(v, bv) then
                local c = DeepCopy(v)
                if c ~= nil then
                    out = out or {}
                    out[k] = c
                end
            end
        end
    end
    return out
end

local function BuildSparseFlat(flat)
    if type(flat) ~= "table" then return nil end
    local ftype = rawget(flat, "type")
    local template
    if ftype == "raid" then
        template = BF:CreateRaidProfile(rawget(flat, "anchorX"), rawget(flat, "anchorY"))
    elseif ftype == "party" then
        template = BF:CreatePartyProfile()
    else
        -- Unknown type: no template to strip against — export the
        -- whole flat rather than guess (RehydrateFlats repairs type
        -- on the receiving end for seeded IDs).
        return DeepCopy(flat)
    end
    local out = {}
    for k, v in pairs(flat) do
        if RUNTIME_KEYS[k] then
            -- excluded by construction
        elseif FLAT_INVARIANTS[k] then
            out[k] = DeepCopy(v)
        elseif type(v) == "table" then
            if IsPerLayoutSectionKey(k) then
                -- Strip base is the GLOBAL section (see the block
                -- comment above). Template fallback only if rpDB is
                -- somehow not up yet — then this degrades to a larger
                -- but still whole-or-omitted export.
                local gp = BF.rpDB and BF.rpDB.profile
                local g = gp and gp[k]
                local base = (type(g) == "table") and g or template[k]
                local kept = BuildSparseSectionOneLevel(v, base)
                if kept ~= nil then out[k] = kept end
            else
                -- Non-section table on the flat: atomic against the
                -- template (the flat's __index covers top-level keys
                -- only, so a partial nested table would read broken).
                if not DeepEqual(v, template[k]) then
                    local c = DeepCopy(v)
                    if c ~= nil then out[k] = c end
                end
            end
        else
            -- Scalar: strip when it equals the template value.
            if v ~= template[k] then out[k] = v end
        end
    end
    return out
end

-- ── Per-module section whitelists ───────────────────────────────
-- THE CONTRACT: every top-level profile key a module stores is in
-- exactly one of `sections` (exported) or `excluded` (known, never
-- exported). Unknown "_" keys are treated as bookkeeping (info);
-- unknown plain keys are audit warnings. When you add a feature
-- that stores a new top-level key, REGISTER IT HERE — the audit
-- (/bf exportaudit, and the test suite once Phase E lands) exists
-- to make forgetting loud instead of silent.

-- RaidPartyFrames. `layouts` is handled specially below.
local RP_SECTIONS = {
    layouts = true, sorting = true, auras = true, auraText = true,
    borders = true, healthPower = true, absorbs = true, castBar = true,
    icons = true, text = true, tooltips = true, colors = true,
    -- Preview preferences: persistent per-profile user choices
    -- (pinned preview flats etc.). "_"-prefixed but deliberately
    -- exported — the one exception to the bookkeeping convention,
    -- preserved from the legacy exporter's behavior.
    _hiddenCFPreviewSlots = true,
    _previewUnitsByFlat   = true,
    _unpinnedPreviewFlats = true,
}
-- Sub-whitelist for rpDB.profile.layouts (post-Phase-L shape).
local RP_LAYOUTS_KEYS = {
    flatLayouts = true,           -- special: per-flat template strip
    instanceLayoutAssignment = true,
    roleOverrides = true, specOverrides = true,
    perLayoutToggles = true,
    scaleRaidToFit = true, scaleRaidToFitMaxWidth = true,
    showLayoutAnnounce = true,
}
-- (Every "_" key on layouts — _flatLayoutsMigrated,
-- _roleSpecOverridesMigrated, _flatsCollapsedToSparse,
-- _perLayoutSectionFallbacksWired, _showGroupBackfilled — is
-- migration bookkeeping and falls under the info convention.)

-- AuraCustomizations. Owner charter (plan §E.2): containers + their
-- settings + single-buff customizations + custom Single Buffs; the
-- global aura visibility/filter toggles stay here by owner ruling.
local AC_SECTIONS = {
    -- customBuffContainers is EXPORTED, but since AC schema 2 it travels
    -- transformed — as the sbPortable curated-diff shape (§E.7c), not as
    -- this profile key. It stays whitelisted here so the audit counts it
    -- as covered rather than warning on it.
    customBuffContainers = true, customDebuffContainers = true,
    debuffFilter = true,
    showSatedDebuffs = true, showDeserterDebuffs = true,
    showSkyridingDebuffs = true, showArcaneEmpowermentDebuffs = true,
    showTimeTrialDebuffs = true, showRaidBuffs = true,
    buffsDisplay = true,
    -- Per-spec / per-spell customization tables (created dynamically;
    -- no defaults entries — exported whole when present).
    spellAssign = true,
    specSpellColors = true, specSpellBorders = true,
    specSpellBorderColors = true, specSpellOverlays = true,
    specSpellSolidIcons = true, specSpellOrdering = true,
    specSpellIconEffect = true, specSpellIconType = true,
    specSpellCooldownText = true, specSpellBounce = true,
    specSpellCustomized = true,
    specBuffsBorder = true, specBuffsBorderColor = true,
    specBuffsOverlay = true, specBuffsSolidIcon = true,
    -- swiftmendHealthTextColor / swiftmendRecolorHealthText REMOVED: health
    -- TEXT recolor never had a 12.1 path (only the name mirror and the
    -- hc/bd/ov fx kinds do) and both keys are purged by migration.
    swiftmendFx = true, swiftmendNameColor = true,
    swiftmendRecolorName = true,
    -- 2026-08-24 dead-key sweep: live "un-hide restores previous
    -- container" state (Options_AuraCustomizations.lua:1093-1102).
    specSpellPrevAssign = true,
}
local AC_EXCLUDED = {
    -- Seed guards: belong to the receiving install —
    -- EnsureSpellCustomizedSeeded / MigrateContainerLayoutFields
    -- re-derive their state from the imported entries, which is the
    -- correct post-import behavior.
    spellCustomizedSeeded = true,
    containerLayoutFieldsMigrated = true,
    -- Retired features/keys (nilled by migrations; exporting them
    -- would resurrect dead state on the receiving end):
    nonHealerBuffFilter = true, specBuffFilter = true,
    specSpellExpirationGlow = true, specSpellVisualAlert = true,
    separateRaidAuraCustomizations = true,
    privateAuraBorderAutoScale = true, privateAuraBorderWidthRatio = true,
    privateAuraBorderFrameLevel = true,
    privateAuraFrameBorderScaleRaid = true,
    privateAuraFrameBorderScaleParty = true,
    -- 2026-08-24 dead-key sweep additions (all verified reader-less;
    -- purged from SavedVariables by migration 74 where an existing
    -- migration did not already nil them):
    sotfGlowEnabled = true, sotfGlowRejuv = true, sotfGlowRegrowth = true,
    sotfGlowType = true, sotfRejuvColor = true, sotfGerminationColor = true,
    sotfRegrowthColor = true, sotfConvokeAsEmpowered = true,
    specSpellBlizzardBorders = true,
    healerBuffFilter = true,
    enablePrivateAuraCustomizations = true, enableGlobalPAOverrides = true,
    globalPASettings = true, encounterPASettings = true,
    dungeonPASettings = true,
    privateAuraBorderAutoScaleRaid = true, privateAuraBorderAutoScaleParty = true,
    privateAuraBorderWidthRatioRaid = true, privateAuraBorderWidthRatioParty = true,
    privateAuraBorderFrameLevelRaid = true, privateAuraBorderFrameLevelParty = true,
    privateAuraFrameBorderScaleOverride = true, privateAuraBorderScale = true,
    -- acDB copies of the missing-raid-buff block (live copies are
    -- rpDB.profile.icons.*; these were nilled by MigrateIconsLocation):
    showMissingRaidBuff = true, showMissingRaidBuffInCombat = true,
    showMissingSymbiotic = true, missingRaidBuffAnchor = true,
    missingRaidBuffOffsetX = true, missingRaidBuffOffsetY = true,
    missingRaidBuffSize = true, missingRaidBuffShowGlow = true,
}

-- CustomFrameGroups. `customFrameGroups` is handled specially below
-- (each group's flat gets the template strip).
local CFG_SECTIONS = {
    customFramesEnabled = true,
    customFrameGroups = true,
    customFrameGroupPositions = true,
    cfgBaseLayoutID = true,   -- declared rpDB-flat reference (§E.4)
}
local CFG_EXCLUDED = {
    _baseLayouts = true,      -- legacy import shim key; never live data
}

-- UnitFrames: the defaults keys plus the known dynamically-created
-- ones. ufLayouts is exported as-is minus the dead raid buckets.
local UF_DYNAMIC = {
    -- Written by options but absent from Defaults_UnitFrames.lua
    -- (verified by write-grep, 2026-08-24).
    --
    -- Eleven entries were removed on 2026-08-31: auraReverseSwipe,
    -- auraShowSpark, auraShowSwipe, oufPowerBarOpacity, bossGrowDirection,
    -- healthBorderColor, powerBorderColor, nameBorderColor,
    -- oufResourceBarBorderColor and the two *CastBarAvoidAuras keys now
    -- HAVE defaults, so SectionsFromDefaults sees them on its own and
    -- listing them here said nothing. That also makes their export sparse
    -- for the first time -- a value equal to the default is now omitted.
    --
    -- Only the deliberately default-less keys remain: nil in
    -- oufPowerBarWidth/Height means "inherit the frame's width/height"
    -- (oUF_PowerBar.lua:331), not "use a default", so they must never gain
    -- one.
    oufPowerBarHeight = true, oufPowerBarWidth = true,
    -- 2026-08-24 dead-key sweep: the font keys are declared `= nil` in
    -- the defaults file, which creates NO table entry -- so they are
    -- invisible to SectionsFromDefaults and must be registered here:
    oufGlobalFont = true, oufNameFont = true, oufLevelFont = true,
    oufHealthPctFont = true, oufHealthValFont = true,
    oufPowerPctFont = true, oufPowerValFont = true,
    oufAltPowerPctFont = true, oufAltPowerValFont = true,
    oufStackFont = true,
    -- Position keys deliberately absent from defaults (nil = "no saved
    -- position"), written by SetUFAnchor's global fallback:
    oufPowerBarAnchorX = true, oufPowerBarAnchorY = true,
    oufResourceBarAnchorX = true, oufResourceBarAnchorY = true,
    playerAltPowerBar = true,
    -- Detached target/focus castbar position + one-time-seed guards
    -- (user state, not migration sentinels -- they travel):
    targetCastBarAnchorX = true, targetCastBarAnchorY = true,
    focusCastBarAnchorX = true, focusCastBarAnchorY = true,
    targetCastBarAnchorSaved = true, focusCastBarAnchorSaved = true,
}

-- 2026-08-24 dead-key sweep: ufDB keys with NO live reader anywhere.
-- Never exported; migration 74 purges them from SavedVariables (except
-- the two *CastBarFontSize legacy-fallback forms, which keep a reader).
local UF_EXCLUDED = {
    iconIgnoreClickBindsOOC = true, iconIgnoreClickBindsOOCOnly = true,
    iconOverrideLeftClick = true, iconOverrideRightClick = true,
    separateUFByGroupType = true,
    customPowerColors = true,   -- tombstone copy; live is rpDB.healthPower
    globalUseClassColor = true, globalUseHostilityColor = true,
    globalUseClassColorName = true, globalUseHostilityColorName = true,
    globalNpcClassificationColors = true, globalUseHealthGradient = true,
    -- the oufAstralBar* family: a relocation migration preserves them
    -- into ufDB and nothing has ever read them:
    oufAstralBarEnabled = true, oufAstralBarUseTypeColor = true,
    oufAstralBarColor = true, oufAstralBarBgColor = true,
    oufAstralBarBorderEnabled = true, oufAstralBarBorderThickness = true,
    oufAstralBarBorderColor = true, oufAstralBarShowPct = true,
    oufAstralBarShowVal = true, oufAstralBarFontSize = true,
    oufAstralBarPctPos = true, oufAstralBarValPos = true,
    -- removed from the defaults 2026-08-24 (zero readers):
    auraFont = true, bossCastBarAvoidAuras = true, classIconPosition = true,
    frameBorderEnabled = true, frameBorderThickness = true,
    nameDividerEnabled = true, nameDividerThickness = true,
    ptfFrameStyle = true,
    -- top-level legacy fallback forms (reader exists at
    -- oUF_Castbar.lua:809 but nothing writes them; per-unit keys are
    -- the live storage) -- excluded, NOT purged:
    targetCastBarFontSize = true, focusCastBarFontSize = true,
    -- 2026-08-31: playerShowClassIcon is the live key for EVERY unit frame
    -- (44 readers); targetShowClassIcon was a per-unit leftover that two
    -- setters mirrored into and nothing ever read. Both writes are gone, so
    -- it is dead. Excluded from export from now on. Stale copies survive in
    -- existing SavedVariables until a future dbVersion purge picks them up --
    -- migration 74 has already run for anyone at DB_VERSION 77.
    targetShowClassIcon = true,
}

-- IncomingCasts. Most incomingCastsPlayer* keys are GENERATED into the
-- defaults at load (Defaults_IncomingCasts.lua builds one per suffix in
-- BF.incomingCastsPerDisplayKeys), so SectionsFromDefaults sees them.
-- The four below are invisible to it: CastFilter has no generated
-- default (nil), and NameColor/TimeColor are declared `= nil`.
-- NOTE (2026-08-24 sweep): incomingCastsPlayerCastFilter is LIVE -- key
-- names are constructed as prefix..suffix (ResolveKeyName /
-- BuildCfg), so literal greps miss it. Do not classify it dead again.
local IC_DYNAMIC = {
    incomingCastsCastFilter = true,
    incomingCastsPlayerCastFilter = true,
    incomingCastsNameColor = true,
    incomingCastsTimeColor = true,
}

-- Build a sections set from a defaults profile table + extras.
local function SectionsFromDefaults(defaultsProfile, extras)
    local t = {}
    for k in pairs(defaultsProfile) do t[k] = true end
    if extras then for k in pairs(extras) do t[k] = true end end
    return t
end

-- ── Per-module builders ─────────────────────────────────────────

local function BuildGeneric(profile, defaultsProfile, sections)
    local out = {}
    for key in pairs(sections) do
        local kept = BuildSparse(profile[key], defaultsProfile and defaultsProfile[key])
        if kept ~= nil then out[key] = kept end
    end
    return out
end

local function BuildRaidPartyFrames(profile)
    local dp = BF.raidPartyFrameDefaults.profile
    local out = {}
    for key in pairs(RP_SECTIONS) do
        if key ~= "layouts" then
            local kept = BuildSparse(profile[key], dp[key])
            if kept ~= nil then out[key] = kept end
        end
    end
    local lp = profile.layouts
    if type(lp) == "table" then
        local dl = dp.layouts or {}
        local ol = {}
        for key in pairs(RP_LAYOUTS_KEYS) do
            if key == "flatLayouts" then
                if type(lp.flatLayouts) == "table" then
                    local fl = {}
                    for id, flat in pairs(lp.flatLayouts) do
                        fl[id] = BuildSparseFlat(flat)
                    end
                    ol.flatLayouts = fl
                end
            else
                local kept = BuildSparse(lp[key], dl[key])
                if kept ~= nil then ol[key] = kept end
            end
        end
        out.layouts = ol
    end
    return out
end

local function BuildCustomFrameGroups(profile)
    local dp = BF.customFrameGroupDefaults.profile
    local out = {}
    for key in pairs(CFG_SECTIONS) do
        if key ~= "customFrameGroups" then
            local kept = BuildSparse(profile[key], dp[key])
            if kept ~= nil then out[key] = kept end
        end
    end
    if type(profile.customFrameGroups) == "table" then
        local groups = {}
        for i, grp in ipairs(profile.customFrameGroups) do
            if type(grp) == "table" then
                local g = {}
                for k, v in pairs(grp) do
                    if k == "flat" then
                        g.flat = BuildSparseFlat(v)
                    elseif not RUNTIME_KEYS[k] then
                        local c = DeepCopy(v)
                        if c ~= nil then g[k] = c end
                    end
                end
                groups[i] = g
            end
        end
        out.customFrameGroups = groups
    end
    return out
end

local function BuildUnitFrames(profile)
    local dp = BF.unitFrameDefaults.profile
    local sections = SectionsFromDefaults(dp, UF_DYNAMIC)
    local out = BuildGeneric(profile, dp, sections)
    -- Belt-and-braces (§L.6a): the dead raid buckets never travel,
    -- even if a stale profile still carries one.
    if type(out.ufLayouts) == "table" then
        for _, layout in pairs(out.ufLayouts) do
            if type(layout) == "table" then
                layout.raid40, layout.raid30, layout.raid20 = nil, nil, nil
            end
        end
    end
    return out
end

-- ── Curated single-buff portable (§E.7c, AC schema 2) ───────────
-- The owner's observation that forced this (2026-08-24): most Single
-- Buff entries are MACHINE-SEEDED — _AuraMig_CuratedSpells mints one
-- per BF.SPEC_SPELLS row on every new/copied/reset acDB profile — so
-- an entry still in its seeded state is pure reconstructable weight,
-- IDENTITY INCLUDED (name, key, spell ID), and identity is exactly
-- the part deflate cannot remove. So customBuffContainers no longer
-- travels as a whole array:
--
--   * a curated entry equal to its canonical mint shape travels as
--     NOTHING (the receiver's own mint recreates it);
--   * a modified curated entry travels as { spec, sid, d } — an
--     ADDITIVE deep diff over the canonical shape;
--   * everything else (hand-added entries, multi-icon containers,
--     curated entries whose state a pure-additive diff cannot
--     express) travels WHOLE, with its original array index.
--
-- OWNER RULING (2026-08-24): an entry ABSENT from the export — same
-- state whether the exporter never touched it or deliberately DELETED
-- it — is re-minted in default state on the receiving profile.
-- Deletions of curated defaults do not propagate; an imported profile
-- is never missing a default Single Buff.
--
-- THE CANONICAL SHAPE IS CONTEXT-FREE: computed with an EMPTY
-- spellAssign (universe = live specs + healer order, hidden = the
-- SPEC_SPELLS untracked flag, spec condition = only the minting
-- spec). That is precisely what the receiver's mint produces at
-- SetProfile time — OnNewProfile fires BEFORE any imported data
-- lands, so the fresh profile's spellAssign is empty there too. Every
-- exporter-side deviation (assignment-driven hidden flags, edited
-- conditions, renames) lands in the diff by construction. The shape
-- literal mirrors _AuraMig_CuratedSpells (Core_Migrations.lua) —
-- KEEP THE TWO IN SYNC — and the shared rules (universe / fail-open
-- coverage / key minting / positional c:N repointing) come from
-- BF._CuratedSBHelpers, exposed by that same file.
--
-- POSITIONAL c:N ASSIGNMENTS: the legacy whole-array replacement
-- preserved spellAssign's "c:<index>" container references by
-- accident. This scheme rebuilds the array, so ApplySingleBuffPortable
-- remaps every c:N from the exporter's index to the entry's new index
-- (a dangling reference falls back to "default", the same choice
-- removeContainerAt makes), then sweeps receiver-minted entries whose
-- spell ends up covered by another entry or assigned to a container —
-- the mint's own candidacy guards, re-evaluated against the FINAL
-- imported state.

local function CanonicalCuratedEntry(specId, def, universe, H)
    -- Mirrors the _AuraMig_CuratedSpells literal with an empty
    -- spellAssign context. No singleBuffKey: the receiver mints its own.
    return {
        singleBuff        = true,
        maxBuffs          = 1,
        singleBuffSpellID = def.id,
        selectedSpells    = {},
        name              = H.spellName(def.id, def.name),
        autoNamed         = false,
        loadSpec          = true,
        loadSpecTypes     = H.onlySpec(universe, specId),
        anchorPoint       = "BUFFS",
        sbRelativeOrder   = "BEFORE",
        singleBuffCustomized = false,
        singleBuffHidden  = def.untracked and true or nil,
        containerUsesBuffSettings = true,
    }
end

-- Additive deep diff of a curated entry over its canonical shape.
-- Returns:  nil   -> pristine (nothing travels)
--           table -> the diff
--           false -> not expressible additively (a canonical key is
--                    absent from the entry — DeepMergeProfile cannot
--                    delete, so the entry must travel whole instead).
-- Canonical keys whose ABSENCE on a stored entry reads identically to
-- the seeded value, each verified against its reader:
--   sbRelativeOrder — GetSingleBuffRelativeOrder normalizes with
--   `v == "AFTER" and "AFTER" or "BEFORE"` and the options getter
--   defaults nil to "BEFORE".
--   containerUsesBuffSettings — resolver ends `useBuff = useBuff ~=
--   false` ("nil == inherit"), so nil ≡ the minted true.
--   autoNamed — every reader is a truthiness test, so nil ≡ false.
--   selectedSpells — every reader guards `type(...) == "table"` /
--   plain truthiness, so nil ≡ the minted empty table.
-- NOT in this table, deliberately: singleBuffCustomized (nil means
-- "Show (Customized Buff)", false means Default — documented as
-- distinct at the create site) and loadSpec (nil = condition off,
-- true = spec-gated).
local NIL_EQUALS_SEEDED = {
    sbRelativeOrder = "BEFORE",
    containerUsesBuffSettings = true,
    autoNamed = false,
    selectedSpells = {},
}

-- Semantic (fail-open) equality of a stored spec map with the canonical
-- "only this spec ON" shape. The stored map was densified with the
-- EXPORTER's universe AT MINT TIME (API specs + that day's spellAssign
-- keys); the canonical map uses today's. Byte equality would drag the
-- whole dense map into every diff the moment those key sets drift
-- (stale junk keys in old spellAssign, spec-list changes), so compare
-- MEANING instead: ON for `specId`, OFF — explicitly, or via a key that
-- is not a live spec — for everything else. Absence of a LIVE spec key
-- is fail-open ON and therefore NOT equal.
local function SpecMapEqualsOnly(t, specId, universe)
    if type(t) ~= "table" then return false end
    if t[specId] == false then return false end
    for id in pairs(universe) do
        if id ~= specId and t[id] ~= false then return false end
    end
    for id, v in pairs(t) do
        if id ~= specId and v ~= false then return false end
    end
    return true
end

-- `ctx` carries the claim's identity: spec, universe, and the accepted
-- alternate names. `name` is not byte-derivable across cache states —
-- the mint stamped SpellDisplayName(sid, def.name) at PROFILE-CREATION
-- time, when the spell may not have been cached yet (leaving the
-- def.name fallback), while canon evaluates it at EXPORT time — so any
-- of the derivable spellings counts as "not renamed" (review finding:
-- pinning the stale spelling into the diff would overwrite the
-- receiver's correctly-resolved minted name).
local function DiffOverCanonical(entry, canon, ctx)
    local d
    for k, v in pairs(entry) do
        if RUNTIME_KEYS[k] or k == "singleBuffKey" or k == "singleBuffSpellID" then
            -- key is re-minted, sid is the diff's address, runtime never travels
        elseif k == "name" and ctx and ctx.altNames and ctx.altNames[v] then
            -- any derivable spelling ≡ not renamed
        elseif k == "loadSpecTypes" and ctx
               and SpecMapEqualsOnly(v, ctx.spec, ctx.universe) then
            -- semantically the canonical "only this spec ON" map
        elseif not DeepEqual(v, canon[k]) then
            local c = DeepCopy(v)
            if c ~= nil then
                d = d or {}
                d[k] = c
            end
        end
    end
    for k, v in pairs(canon) do
        if v ~= nil and k ~= "singleBuffKey" and entry[k] == nil
           and not (NIL_EQUALS_SEEDED[k] ~= nil and DeepEqual(v, NIL_EQUALS_SEEDED[k])) then
            -- e.g. singleBuffCustomized stored as nil where the mint wrote
            -- false — semantically distinct states, and an additive merge
            -- cannot erase the minted value.
            return false
        end
    end
    return d
end

-- Deterministic mint order over BF.SPEC_SPELLS: sorted spec ids, list
-- order within a spec — the same order _AuraMig_CuratedSpells walks.
local function ForEachCuratedRow(specSpells, fn)
    local specIDs = {}
    for specId in pairs(specSpells) do
        if type(specId) == "number" then specIDs[#specIDs + 1] = specId end
    end
    table.sort(specIDs)
    for si = 1, #specIDs do
        local specId = specIDs[si]
        local list = specSpells[specId]
        if type(list) == "table" then
            for li = 1, #list do
                local def = list[li]
                if type(def) == "table" and type(def.id) == "number" then
                    fn(specId, def)
                end
            end
        end
    end
end

-- The alreadyHeld PREDICATE for one entry (fail-open coverage — the
-- rule alreadyHeld applies per entry, mirrored from Core_Migrations).
local function EntryCoversSpec(c, sid, specId)
    if not (type(c) == "table" and c.singleBuff and c.singleBuffSpellID == sid) then
        return false
    end
    local t = c.loadSpecTypes
    return (not c.loadSpec) or type(t) ~= "table" or t[specId] ~= false
end

local function BuildSingleBuffPortable(profile)
    local containers = profile.customBuffContainers
    if type(containers) ~= "table" then return nil end
    local H = BF._CuratedSBHelpers
    local specSpells = BF.SPEC_SPELLS
    if not (H and type(specSpells) == "table") then return nil end

    local universe = H.universe(nil)

    -- Claim pass: in mint order, each curated (spec, sid) row claims the
    -- FIRST unclaimed entry that would have suppressed its mint — the
    -- exact alreadyHeld walk, so classification matches what the mint
    -- itself would have decided.
    local claimed = {}
    ForEachCuratedRow(specSpells, function(specId, def)
        for i = 1, #containers do
            local c = containers[i]
            if not claimed[c] and EntryCoversSpec(c, def.id, specId) then
                claimed[c] = { spec = specId, def = def }
                break
            end
        end
    end)

    local whole, diffs = {}, {}
    for i = 1, #containers do
        local c = containers[i]
        local cl = type(c) == "table" and claimed[c] or nil
        local asWhole = true
        if cl then
            local canon = CanonicalCuratedEntry(cl.spec, cl.def, universe, H)
            local ctx = {
                spec     = cl.spec,
                universe = universe,
                altNames = {
                    [canon.name or ""]        = true,
                    [cl.def.name or ""]       = true,
                    [tostring(cl.def.id)]     = true,
                },
            }
            local d = DiffOverCanonical(c, canon, ctx)
            if d == nil then
                -- Pristine: vanishes — with one exception (review finding
                -- 6). If the exporter ALSO has this spell container-
                -- assigned, the receiver's candidacy sweep would remove
                -- the minted row as a double-render guard even though the
                -- exporter still HAS its row. Ship an empty diff as a
                -- PRESENCE MARKER: it merges nothing, but it marks the
                -- minted row as imported so the sweep leaves it — the
                -- receiver ends in exactly the exporter's state. A spell
                -- that is c:N-assigned WITHOUT a row stays marker-less,
                -- and the sweep removes the receiver's minted row: also
                -- exactly the exporter's state (and what a fresh mint
                -- would have produced).
                local assigns = profile.spellAssign and profile.spellAssign[cl.spec]
                local a = assigns and assigns[cl.def.id]
                if type(a) == "string" and a:find("^c:%d+$") then
                    diffs[#diffs + 1] = { spec = cl.spec, sid = cl.def.id, d = {} }
                end
                asWhole = false
            elseif d ~= false then
                diffs[#diffs + 1] = { spec = cl.spec, sid = cl.def.id, d = d }
                asWhole = false
            end
        end
        if asWhole then
            local e = DeepCopy(c)
            if e ~= nil then
                whole[#whole + 1] = { idx = i, entry = e }
            end
        end
    end
    return { whole = whole, diffs = diffs }
end

-- The apply half. `acp` is the freshly-created target profile (its
-- curated entries already minted by OnNewProfile -> MigrateAurasUnified;
-- the explicit call below closes any ordering hole), AFTER the rest of
-- the module — spellAssign included — has been deep-merged onto it.
function BF:ApplySingleBuffPortable(acp, portable, profileName)
    if type(acp) ~= "table" or type(portable) ~= "table" then return end
    local H = BF._CuratedSBHelpers
    if not H then
        error("BuzzardFrames: curated single-buff helpers unavailable — cannot apply the imported Single Buffs")
    end
    -- 1. Ensure the curated mint ran for this profile (idempotent — the
    --    per-profile sentinel makes this free when OnNewProfile got there
    --    first, which it normally does).
    if self.MigrateAurasUnified then
        self:MigrateAurasUnified(profileName)
    end
    local containers = acp.customBuffContainers
    if type(containers) ~= "table" then
        containers = {}
        acp.customBuffContainers = containers
    end

    -- Everything in the array right now is receiver-minted state.
    local mintedUntouched = {}
    for i = 1, #containers do
        if type(containers[i]) == "table" then mintedUntouched[containers[i]] = true end
    end

    -- 2. Diffs onto their minted rows. ALL targets are resolved against
    --    the PRE-APPLY minted state, each row consumable at most once,
    --    BEFORE any diff is merged (review BLOCKER: resolving in
    --    sequence let an earlier diff that widened loadSpecTypes onto a
    --    second spec steal that spec's own diff — the later merge then
    --    overwrote the first entry and the sweep deleted the real one).
    local targets, consumedRow = {}, {}
    for di = 1, #(portable.diffs or {}) do
        local rec = portable.diffs[di]
        for i = 1, #containers do
            local c = containers[i]
            if type(c) == "table" and c.singleBuff and not consumedRow[c]
               and c.singleBuffSpellID == rec.sid
               and type(c.loadSpecTypes) == "table"
               and c.loadSpecTypes[rec.spec] == true then
                targets[di] = c
                consumedRow[c] = true
                break
            end
        end
    end
    for di = 1, #(portable.diffs or {}) do
        local rec = portable.diffs[di]
        local target = targets[di]
        if target then
            self:DeepMergeProfile(rec.d, target)
            mintedUntouched[target] = nil
        else
            -- No minted row (curated list drift within the same schema —
            -- rare). Rebuild canonical + diff and append; never drop the
            -- user's customization silently.
            local def
            local list = BF.SPEC_SPELLS and BF.SPEC_SPELLS[rec.spec]
            if type(list) == "table" then
                for li = 1, #list do
                    if type(list[li]) == "table" and list[li].id == rec.sid then
                        def = list[li]
                        break
                    end
                end
            end
            local canon = CanonicalCuratedEntry(rec.spec, def or { id = rec.sid },
                                                H.universe(nil), H)
            self:DeepMergeProfile(rec.d, canon)
            canon.singleBuffKey = H.mintKey(containers, rec.sid)
            containers[#containers + 1] = canon
        end
    end

    -- 3. Whole entries appended; old exporter index -> new index.
    -- singleBuffKey is re-minted when the exporter's key is nil OR
    -- already taken (review finding: the receiver has minted its own
    -- keys for the same spell ids, and a duplicate key makes one of the
    -- two entries unreachable in FindSingleBuffByKey and the options
    -- tree).
    local function KeyTaken(key)
        for i = 1, #containers do
            local c = containers[i]
            if type(c) == "table" and c.singleBuffKey == key then return true end
        end
        return false
    end
    -- v94: containerKey collisions. Until now ONLY singleBuffKey was re-minted
    -- here; a multi-icon container's containerKey arrived VERBATIM. Both
    -- namespaces are minted first-unused-slot PER PROFILE (BF:NewContainerKey),
    -- so an exporter holding one container ships "c_1" straight onto a receiver
    -- that already owns a DIFFERENT "c_1". BuildContainerKeyIndex keeps only
    -- the last entry per key, so BF:FindBuffContainerByKey then answers with
    -- whichever won and every "C:<key>" Single Buff anchor pointing at either
    -- one follows it to the wrong container. Same treatment as singleBuffKey:
    -- re-mint on collision, then repoint the anchors that traveled with it.
    local function ContainerKeyTaken(key)
        for i = 1, #containers do
            local c = containers[i]
            if type(c) == "table" and c.containerKey == key then return true end
        end
        return false
    end
    local idxMap     = {}
    local appended   = {}   -- entries THIS import added, for the anchor pass
    local keyRemap   = {}   -- exporter containerKey -> re-minted containerKey
    local arrivedKey = {}   -- exporter containerKey -> true (dangling detection)
    for _, w in ipairs(portable.whole or {}) do
        if type(w) == "table" and type(w.entry) == "table" then
            local e = DeepCopy(w.entry)
            if e.singleBuff and (e.singleBuffKey == nil or KeyTaken(e.singleBuffKey)) then
                e.singleBuffKey = H.mintKey(containers, e.singleBuffSpellID)
            end
            if not e.singleBuff and type(e.containerKey) == "string" then
                arrivedKey[e.containerKey] = true
                if ContainerKeyTaken(e.containerKey) then
                    local old = e.containerKey
                    -- Minted against `containers` as it stands, i.e. including
                    -- everything appended so far by this loop, so two INCOMING
                    -- containers cannot collide with each other either.
                    e.containerKey = BF:NewContainerKey(containers)
                    keyRemap[old] = e.containerKey
                end
            end
            containers[#containers + 1] = e
            appended[#appended + 1] = e
            if type(w.idx) == "number" then idxMap[w.idx] = #containers end
        end
    end

    -- Anchor repoint, deliberately AFTER every append: a Single Buff early in
    -- the list can be anchored to a container that arrives later. Only the
    -- entries this import appended are touched -- their "C:<key>" values were
    -- written in the EXPORTER's key namespace, the receiver's own entries in
    -- the receiver's. A key that never arrived is NOT left alone: it would
    -- resolve against the receiver's identically-named container, which is
    -- exactly the mix-up above, so it falls back to the general Buffs anchor.
    for i = 1, #appended do
        local e = appended[i]
        if e.singleBuff and type(e.anchorPoint) == "string" then
            local key = e.anchorPoint:match("^C:(.+)$")
            if key then
                if keyRemap[key] then
                    e.anchorPoint = "C:" .. keyRemap[key]
                elseif not arrivedKey[key] then
                    e.anchorPoint = "BUFFS"
                end
            end
        end
    end

    -- 4. Remap positional container references. The imported spellAssign
    --    still points at EXPORTER array indices; whole entries are the
    --    only importable c:N targets (curated rows are single buffs, which
    --    c:N never references). A dangling reference falls back to
    --    "default", matching removeContainerAt.
    if type(acp.spellAssign) == "table" then
        for _, assigns in pairs(acp.spellAssign) do
            if type(assigns) == "table" then
                for sid, val in pairs(assigns) do
                    local n = type(val) == "string" and tonumber(val:match("^c:(%d+)$"))
                    if n then
                        assigns[sid] = idxMap[n] and ("c:" .. idxMap[n]) or "default"
                    end
                end
            end
        end
    end

    -- 5. Candidacy sweep over minted rows the import did not touch: the
    --    mint's own guards, re-evaluated against the FINAL state. A row
    --    whose spell is now assigned to a container, or covered by an
    --    applied/appended entry, would double-render — remove it (via the
    --    renumber-aware remover, which repoints c:N on shift). A row that
    --    is merely ABSENT from the export stays: that is the owner's
    --    deletions-do-not-propagate ruling.
    local doomed = {}
    for i = 1, #containers do
        local c = containers[i]
        if mintedUntouched[c] and type(c) == "table" and c.singleBuff then
            local sid = c.singleBuffSpellID
            local t = c.loadSpecTypes
            local spec, nOn
            if type(t) == "table" then
                nOn = 0
                for id, v in pairs(t) do
                    if v == true then nOn = nOn + 1; spec = id end
                end
            end
            if sid and spec and nOn == 1 then
                local assigns = acp.spellAssign and acp.spellAssign[spec]
                local val = assigns and assigns[sid]
                local inContainer = type(val) == "string" and val:find("^c:%d+$") ~= nil
                local covered = false
                if not inContainer then
                    for j = 1, #containers do
                        local other = containers[j]
                        if other ~= c and not mintedUntouched[other]
                           and EntryCoversSpec(other, sid, spec) then
                            covered = true
                            break
                        end
                    end
                end
                if inContainer or covered then
                    doomed[#doomed + 1] = i
                end
            end
        end
    end
    -- Descending, so earlier doomed indices stay valid through removals.
    --
    -- NOT H.removeAt (review finding): removeContainerAt also drops the
    -- doomed entry's Order mirror from acp.specSpellOrdering — right for
    -- a USER deletion, wrong here, because the merge above just wrote
    -- the EXPORTER's specSpellOrdering and the row being removed is one
    -- the receiver minted, not one the exporter's data owns. The
    -- exporter's own profile keeps its ordering for these spells, so the
    -- receiver must too. This private remover does only the array
    -- removal and the positional c:N repoint (same rules as
    -- removeContainerAt's repoint block: exact match falls back to
    -- "default", higher indices decrement).
    local function RemoveRowKeepOrdering(index)
        table.remove(containers, index)
        if type(acp.spellAssign) == "table" then
            for _, assigns in pairs(acp.spellAssign) do
                if type(assigns) == "table" then
                    for sid, val in pairs(assigns) do
                        local n = type(val) == "string" and tonumber(val:match("^c:(%d+)$"))
                        if n then
                            if n == index then
                                assigns[sid] = "default"
                            elseif n > index then
                                assigns[sid] = "c:" .. (n - 1)
                            end
                        end
                    end
                end
            end
        end
    end
    for i = #doomed, 1, -1 do
        RemoveRowKeepOrdering(doomed[i])
    end
end

-- ── The registry (§E.3.1) ───────────────────────────────────────
-- One entry per live module. `schema` is the per-module shape
-- version carried in the Phase E envelope (step 2); bump it when a
-- module's portable shape changes. `build(profile)` returns the
-- sparse portable table. `sections` / `excluded` drive the audit.
-- apply() / references() land in step 2.
BF.ExportRegistry = {
    {
        key      = "RaidPartyFrames",
        label    = "Raid/Party Frames",
        db       = function() return BF.rpDB end,
        schema   = 1,
        sections = RP_SECTIONS,
        -- privateAuraBorderScale: dead (a legacy migration writes it, a
        -- later one nils it); purged by migration 74.
        excluded = { privateAuraBorderScale = true },
        build    = BuildRaidPartyFrames,
    },
    {
        key      = "AuraCustomizations",
        -- §E.5: named for what it IS under the current options tree
        -- (the old top-level section is hidden; every widget lives
        -- under Raid/Party Frames -> Buffs / Debuffs).
        label    = "Buffs & Debuffs — Containers, Single Buffs & Spell Customizations",
        db       = function() return BF.acDB end,
        -- schema 2 (§E.7c): customBuffContainers travels as sbPortable
        -- (curated diffs + whole non-curated entries) instead of a whole
        -- array. Older installs refuse schema-2 strings at the gate;
        -- schema-1 strings still carry the whole array and import through
        -- the plain deep merge unchanged.
        schema   = 2,
        sections = AC_SECTIONS,
        excluded = AC_EXCLUDED,
        build    = function(profile)
            local portable = BuildSingleBuffPortable(profile)
            local out
            if portable then
                -- Build every section EXCEPT the container array…
                local sections = {}
                for k in pairs(AC_SECTIONS) do
                    if k ~= "customBuffContainers" then sections[k] = true end
                end
                out = BuildGeneric(profile, BF.auraCustomizationDefaults.profile, sections)
                out.sbPortable = portable
            else
                -- …falling back to the schema-1 whole-array shape when the
                -- shared helpers or SPEC_SPELLS are unavailable (load-order
                -- accident): larger but always correct.
                out = BuildGeneric(profile, BF.auraCustomizationDefaults.profile, AC_SECTIONS)
            end
            return out
        end,
    },
    {
        key      = "CustomFrameGroups",
        label    = "Custom Frame Groups",
        db       = function() return BF.cfgDB end,
        schema   = 1,
        sections = CFG_SECTIONS,
        excluded = CFG_EXCLUDED,
        build    = BuildCustomFrameGroups,
    },
    {
        key      = "UnitFrames",
        label    = "Unit Frames",
        db       = function() return BF.ufDB end,
        schema   = 1,
        sections = nil,   -- derived from defaults at audit/build time
        excluded = UF_EXCLUDED,
        build    = BuildUnitFrames,
    },
    {
        key      = "IncomingCasts",
        label    = "Incoming Casts",
        db       = function() return BF.icDB end,
        schema   = 1,
        sections = nil,   -- derived from defaults
        excluded = {},
        build    = function(profile)
            local dp = BF.incomingCastsDefaults.profile
            return BuildGeneric(profile, dp, SectionsFromDefaults(dp, IC_DYNAMIC))
        end,
    },
}

local function ResolveSections(entry)
    if entry.sections then return entry.sections end
    if entry.key == "UnitFrames" then
        return SectionsFromDefaults(BF.unitFrameDefaults.profile, UF_DYNAMIC)
    elseif entry.key == "IncomingCasts" then
        return SectionsFromDefaults(BF.incomingCastsDefaults.profile, IC_DYNAMIC)
    end
    return {}
end

-- ── Copyable report window ──────────────────────────────────────
-- Both debug commands print far too much for the chat frame, so the
-- report opens in a copyable window (BF:ShowTextWindow, the same one as
-- /bf loadreport and the Export string frame), pre-highlighted so a
-- single Ctrl+C grabs it. Plain text, no color codes -- it is made
-- to be pasted. Falls back to chat only if no window can be shown.
local function ShowCopyableReport(title, text)
    -- P-1: routed through the bridge (Core_OptionsBridge.lua) so the
    -- window's implementation lives in one place. Falls back to chat
    -- exactly as before when no window can be shown.
    if not BF:ShowTextWindow(title, text, {
        status = "Ctrl+C to copy",
        label  = "",
        layout = "Fill",
        width  = 700,
        height = 520,
    }) then
        print(text)
    end
end

-- ── Completeness audit (§E.3.2) ─────────────────────────────────
-- Walks every module's LIVE profile and classifies each top-level
-- key. Returns a table of problems; when `show` is truthy the report
-- opens in the copyable window (owner request 2026-08-24 -- the
-- audit output is made to be pasted, so there is no chat variant).
-- The test suite runs this on the returned table with failOnWarn
-- semantics; interactively it is /bf exportaudit.
function BF:AuditExportCompleteness(show)
    local problems = {}
    local function note(level, moduleKey, key, msg)
        problems[#problems + 1] = { level = level, module = moduleKey, key = key, msg = msg }
    end
    for _, entry in ipairs(BF.ExportRegistry) do
        local db = entry.db()
        local profile = db and db.profile
        if profile then
            local sections = ResolveSections(entry)
            for k in pairs(profile) do
                if sections[k] or entry.excluded[k] or RUNTIME_KEYS[k] then
                    -- classified
                elseif type(k) == "string" and k:sub(1, 1) == "_" then
                    note("info", entry.key, k, "assumed bookkeeping — excluded from export")
                else
                    note("WARN", entry.key, tostring(k),
                        "UNREGISTERED top-level key — will NOT export. Register it in ProfileExport.lua.")
                end
            end
            -- RP: audit the layouts sub-table with its own whitelist.
            if entry.key == "RaidPartyFrames" and type(profile.layouts) == "table" then
                for k in pairs(profile.layouts) do
                    if RP_LAYOUTS_KEYS[k] or RUNTIME_KEYS[k] then
                        -- classified
                    elseif type(k) == "string" and k:sub(1, 1) == "_" then
                        note("info", entry.key, "layouts." .. k,
                            "assumed bookkeeping — excluded from export")
                    else
                        note("WARN", entry.key, "layouts." .. tostring(k),
                            "UNREGISTERED layouts key — will NOT export. Register it in ProfileExport.lua.")
                    end
                end
            end
        end
    end
    if show then
        local warns = 0
        local lines = {}
        -- WARN lines first -- they are the actionable ones.
        for _, p in ipairs(problems) do
            if p.level == "WARN" then
                warns = warns + 1
                lines[#lines + 1] = string.format("[WARN] %s.%s — %s", p.module, p.key, p.msg)
            end
        end
        if warns > 0 and #problems > warns then lines[#lines + 1] = "" end
        for _, p in ipairs(problems) do
            if p.level ~= "WARN" then
                lines[#lines + 1] = string.format("[%s] %s.%s — %s", p.level, p.module, p.key, p.msg)
            end
        end
        lines[#lines + 1] = ""
        lines[#lines + 1] = string.format("export audit: %d finding(s), %d warning(s).", #problems, warns)
        ShowCopyableReport("BuzzardFrames — Export Audit", table.concat(lines, "\n"))
        print(string.format("|cffd3ff7dBuzzardFrames:|r export audit: %d finding(s), %d warning(s) — see window.",
            #problems, warns))
    end
    return problems
end

-- ── Phase 0 measurement ─────────────────────────────────────────
-- Per-module serialized size, RAW (legacy-scrub shape) vs SPARSE
-- (registry build). AceSerializer for both, so the comparison is
-- apples-to-apples with the shipping exporter. Debug-gated via the
-- chat command's DEBUG_CMDS entry.
function BF:ReportModuleExportSizes()
    local Serializer = LibStub("AceSerializer-3.0")
    local totalRaw, totalSparse = 0, 0
    local lines = {
        "per-module export sizes (AceSerializer bytes, uncompressed):",
        "",
        string.format("%-24s %10s %10s %8s", "module", "raw", "sparse", "saved"),
    }
    for _, entry in ipairs(BF.ExportRegistry) do
        local db = entry.db()
        local profile = db and db.profile
        if profile then
            local rawCopy = DeepCopy(profile)           -- legacy-equivalent scrub
            local sparse  = entry.build(profile)
            local rawLen    = #Serializer:Serialize(rawCopy)
            local sparseLen = #Serializer:Serialize(sparse)
            totalRaw    = totalRaw + rawLen
            totalSparse = totalSparse + sparseLen
            lines[#lines + 1] = string.format("%-24s %10d %10d %7d%%",
                entry.key, rawLen, sparseLen,
                rawLen > 0 and math.floor((1 - sparseLen / rawLen) * 100 + 0.5) or 0)
        end
    end
    lines[#lines + 1] = string.format("%-24s %10d %10d %7d%%",
        "TOTAL", totalRaw, totalSparse,
        totalRaw > 0 and math.floor((1 - totalSparse / totalRaw) * 100 + 0.5) or 0)
    ShowCopyableReport("BuzzardFrames — Export Sizes", table.concat(lines, "\n"))
end

-- ============================================================
-- PHASE E STEP 2 — ENVELOPE, DECODER, APPLY MERGE
-- (plan §E.3.3 / §E.3.4, with §3.3 / §3.5 / §3.9.1)
-- ============================================================
-- Everything below is the NEW pipeline. The legacy encoder/decoder in
-- Options_Profiles.lua is frozen, not extended: it keeps handling the
-- flat-era formats (hex `_format 2`, `!2!` `_format 2/3` + the v93 flat
-- delta) and hands its output to the SAME apply merge defined here, so
-- BF:DeepMergeProfile is the only writer of imported profile data.
--
-- WHAT THE NEW STRING LOOKS LIKE:
--
--   [=== <name> profile ===]      <- unchanged human header, so the
--   !4!                              receiving ExtractProfileName keeps
--   <printable body, 64-char lines>  working verbatim; the version rides
--   ...                              in the body marker where it cannot
--   [=== <name> profile ===]         collide with a profile name.
--
-- and the body is
--     LibDeflate:EncodeForPrint(
--       LibDeflate:CompressDeflate(
--         AceSerializer:Serialize({
--           _format       = 4,
--           dbVersion     = <BF.db.profile.dbVersion>,
--           modules       = { [key] = { schema = <n>, data = <portable> } },
--           _globalColors = <rpDB.profile.colors, deep-copied>,
--         })))
--
-- ONE encoder, not three (owner, 2026-08-24): LibDeflate's own
-- EncodeForPrint replaces the hand-rolled hex and Base64 encoders. Its
-- alphabet is letters + digits + "(" + ")", so the bracketed header, the
-- "!4!" marker and the line breaks are all outside it and the decoder can
-- strip them the way the legacy decoders always have.
--
-- NO DELTA IN THIS FORMAT. The portable tables are SPARSE FULL FLATS —
-- every flat carries its own (default-stripped) keys and nothing is
-- reconstructed from a base. Whether base+diff still pays for itself on
-- top of sparse flats is re-measured in step 3 (§3.6/§3.8); until then a
-- `!4!` string has no reconstruction step at all, which is also why the
-- §3.9.1 marker guard below can only ever fire on legacy input.

local NEW_FORMAT        = 4
local NEW_FORMAT_MARKER = "!4!"
local BODY_WRAP         = 64

-- Exposed so the import UI can detect a new-format paste without
-- duplicating the literal.
BF.EXPORT_FORMAT        = NEW_FORMAT
BF.EXPORT_FORMAT_MARKER = NEW_FORMAT_MARKER

-- The header the legacy encoder writes, character for character.
-- ExtractProfileName reads it with a %[(.-)%] capture on the first 64
-- bytes, so the format is load-bearing: do not "tidy" it.
local function ProfileHeader(title)
    return string.format("[=== %s profile ===]", title or "")
end

local function EntryByKey(key)
    for _, entry in ipairs(BF.ExportRegistry) do
        if entry.key == key then return entry end
    end
end

-- ── §3.3 deep merge — the §3.5 fix (§E.3.4) ─────────────────────
-- The single writer of imported data, used by BOTH the new format and
-- the frozen legacy adapter.
--
-- WHY THIS EXISTS: the import flow is db:SetProfile(finalName) followed
-- by a merge. SetProfile hands back a profile with the CURRENT defaults
-- materialised into it; the old MoveTableKeys then assigned each root
-- key wholesale, so a sparse imported sub-table replaced the fully
-- defaulted one and every key it did not carry read nil for the rest of
-- the session. That was survivable while exports were full copies. It is
-- data loss the moment exports are sparse, which is exactly what step 1
-- made them.
--
-- THE RULE (§3.3, total over every table shape): recurse only when BOTH
-- sides are tables whose keys are all strings; assign leaves; replace
-- every other shape -- arrays, sparse arrays, mixed array/map tables,
-- numeric-keyed tables -- wholesale, via a deep copy so the merged
-- profile never aliases the decoded string's tables.
--
-- rawget ON THE DESTINATION IS DELIBERATE. Flats carry a __index
-- template (WireFlatDefaults) and the profile change fired by SetProfile
-- can re-wire them before this runs. A plain dst[k] read would hand back
-- the TEMPLATE's sub-table, and recursing into that would write the
-- user's values into a metatable that SavedVariables never stores --
-- silently losing them at logout. Reading raw keeps every write on the
-- profile table itself.
function BF:DeepMergeProfile(src, dst)
    if type(src) ~= "table" or type(dst) ~= "table" then return end
    for k, v in pairs(src) do
        if not RUNTIME_KEYS[k] then
            if type(v) == "table" then
                local cur = rawget(dst, k)
                if type(cur) == "table" and IsPureStringMap(v) and IsPureStringMap(cur) then
                    BF:DeepMergeProfile(v, cur)
                else
                    dst[k] = DeepCopy(v)
                end
            else
                dst[k] = v
            end
        end
    end
end

-- ── §3.9.1 reconstruction guard ─────────────────────────────────
-- Delta expansion happens at DECODE time, for every module in the
-- string, before the include filter -- that is what makes subset imports
-- correct. Nothing structurally ENFORCES the ordering, so the apply step
-- asserts it instead of assuming it: if a reconstruction marker is still
-- anywhere in a module's table, reconstruction did not run for it and
-- the data is half-formed. The caller aborts that module rather than
-- writing partial data; the user still has the string and no profile has
-- been touched.
--
-- New-format strings never carry these keys (no delta -- see the header
-- note), so in practice this fires only on a legacy string whose
-- DeltaDecodeFlats did not run.
local RECONSTRUCTION_MARKERS = {
    _flatBase   = true,
    _flatBaseID = true,
    _flatDiffs  = true,
}

function BF:FindReconstructionMarker(t, seen)
    if type(t) ~= "table" then return nil end
    seen = seen or {}
    if seen[t] then return nil end
    seen[t] = true
    for k, v in pairs(t) do
        if RECONSTRUCTION_MARKERS[k] then return k end
        if type(v) == "table" then
            local found = BF:FindReconstructionMarker(v, seen)
            if found then return found end
        end
    end
    return nil
end

-- ── Export (§E.3.3) ─────────────────────────────────────────────
-- `include` is keyed by registry key with boolean values (the Export
-- tab's ResolveExportInclude output). `name` is the header title; blank
-- falls back to the parent profile name, as the legacy exporter did.
function BF:ExportProfileString(include, name)
    local Serializer = LibStub("AceSerializer-3.0")
    local Deflate    = LibStub("LibDeflate")
    include = include or {}

    local modules = {}
    for _, entry in ipairs(BF.ExportRegistry) do
        if include[entry.key] then
            local db      = entry.db()
            local profile = db and db.profile
            if profile then
                modules[entry.key] = {
                    schema = entry.schema,
                    data   = entry.build(profile),
                }
            end
        end
    end

    local envelope = {
        _format   = NEW_FORMAT,
        dbVersion = BF.db and BF.db.profile and BF.db.profile.dbVersion,
        modules   = modules,
    }

    -- _globalColors: KEEP AS THEY ARE (owner, 2026-08-24). Always
    -- bundled, straight from rpDB.profile.colors, even when the
    -- RaidPartyFrames module is included and already carries them -- the
    -- duplication is accepted so that a colors-only recipient (a
    -- UF-only import, say) still receives the exporter's gradient /
    -- class / power colors. DeepCopy is the scrub: same key skipping,
    -- same drop of unserializable values, same cycle cut as the legacy
    -- ScrubProfile performed here.
    local colors = BF.rpDB and BF.rpDB.profile and BF.rpDB.profile.colors
    if colors then envelope._globalColors = DeepCopy(colors) end

    -- level 9 (step 3, owner-approved 2026-08-24): LibDeflate's default
    -- level measured ~22% WORSE than its maximum on a real profile
    -- (26,321 vs 20,635 deflated bytes on the owner's SavedVariables).
    -- Decoding is level-agnostic, so only the encoder names a level.
    -- The one-off cost on a ~100KB serialized payload is milliseconds,
    -- paid on an explicit Export click.
    local body = Deflate:EncodeForPrint(
        Deflate:CompressDeflate(Serializer:Serialize(envelope), { level = 9 }))

    local title
    if name and not name:match("^%s*$") then
        title = name
    else
        title = BF.db:GetCurrentProfile()
    end

    local header = ProfileHeader(title)
    local out    = { header, "\n", NEW_FORMAT_MARKER, "\n" }
    for i = 1, #body, BODY_WRAP do
        out[#out + 1] = string.sub(body, i, i + BODY_WRAP - 1)
        out[#out + 1] = "\n"
    end
    out[#out + 1] = header
    return table.concat(out)
end

-- ── Decode (§E.3.3) ─────────────────────────────────────────────
-- Returns (true, decoded) or (false, userFacingMessage). `decoded` is
-- flattened into the shape the rest of the import flow already expects:
-- decoded[moduleKey] = <portable data>, plus decoded._globalColors and
-- the _format stamp. The envelope's per-module wrapper (schema/data)
-- exists only to be validated here.
function BF:DecodeProfileString(data)
    if type(data) ~= "string" then
        return false, "Decode failed: expected a string."
    end
    local Serializer = LibStub("AceSerializer-3.0")
    local Deflate    = LibStub("LibDeflate")

    -- Strip the bracketed header(s), the format marker and all
    -- whitespace, exactly as the legacy decoders do. None of those
    -- characters exist in EncodeForPrint's alphabet, so this cannot eat
    -- payload.
    local body = data:gsub("%[.-%]", ""):gsub(NEW_FORMAT_MARKER, ""):gsub("%s+", "")
    if #body == 0 then
        return false, "Decode failed: the export string has no body."
    end

    local raw = Deflate:DecodeForPrint(body)
    if not raw then
        return false, "Decode failed: the export string is damaged or incomplete (invalid character in the body)."
    end
    local decompressed = Deflate:DecompressDeflate(raw)
    if not decompressed then
        return false, "Decode failed: the export string is damaged or incomplete (decompression failed)."
    end
    local ok, envelope = Serializer:Deserialize(decompressed)
    if not ok then
        return false, "Decode failed: " .. tostring(envelope or "unknown error")
    end
    if type(envelope) ~= "table" then
        return false, "Decode failed: expected a table, got " .. type(envelope) .. "."
    end
    if envelope._format ~= NEW_FORMAT then
        return false, "This export string is from an older BuzzardFrames version and is no longer supported. Please re-export from the new version."
    end
    if type(envelope.modules) ~= "table" then
        return false, "Decode failed: the export string carries no modules table."
    end

    -- Per-module schema gate. The envelope versions each module
    -- independently, so a string is rejected only for the module that is
    -- actually too new -- but the rejection is whole-string, because a
    -- partial import of a profile the user asked for in full is the
    -- silent-half-data failure this whole design exists to avoid.
    local decoded = { _format = NEW_FORMAT }
    for key, mod in pairs(envelope.modules) do
        local entry = EntryByKey(key)
        if entry and type(mod) == "table" then
            if type(mod.schema) ~= "number" then
                return false, string.format(
                    "This export string's %s data is malformed (no schema number) and cannot be imported.",
                    entry.label)
            end
            if mod.schema > entry.schema then
                return false, string.format(
                    "This export string's %s data is from a NEWER BuzzardFrames version and is not supported by this one. Please update BuzzardFrames, then import it again.",
                    entry.label)
            end
            if type(mod.data) == "table" then
                decoded[key] = mod.data
            end
        end
        -- An unknown module key is IGNORED, not an error: a future
        -- version adding a sixth module must not make its strings
        -- un-importable here for the five modules this build does know.
    end

    if type(envelope._globalColors) == "table" then
        decoded._globalColors = envelope._globalColors
    end
    return true, decoded
end
