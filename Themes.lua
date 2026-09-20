-- ============================================================
-- BuzzardFrames: Themes.lua
-- Predefined visual themes, applied from the Profiles > Themes tab of
-- the options panel (BuzzardFramesOptions, Pages_Profiles.lua), which
-- reads BF.THEMES and drives the BUZZARDFRAMES_APPLY_THEME popup below.
-- The "Copy Current Settings as Theme Data" tool there calls
-- BF:BuildThemeSnapshot and serializes the result itself.
--
-- SCOPE (owner-defined):
--   Raid/Party Frames — ENTIRE contents of these option sections:
--     text         (Text)
--     healthPower  (Health & Power Bars)
--     borders      (Borders & Highlights)
--     absorbs      (Absorbs & Heal Prediction)
--     icons        (Icons)
--   Plus a FILTERED subset of the two sub-categorized sections (see
--   NESTED_SECTIONS below):
--     auras        (the Buffs + Debuffs nav sections — captured/applied
--                   SEPARATELY for raid and party: data.rp.aurasRaid +
--                   data.rp.aurasParty; apply forces EVERY
--                   layouts.perLayoutToggles.auras_<subcat> key ON, since the
--                   split can only render per-layout)
--     auraText     (Aura Cooldown Text)
--   NOT themed: Frames - Size & Position (flat top-level keys), Frames -
--   Sorting (sorting), Tooltips (tooltips), Layouts, Preview & Special
--   Options, Colors, Cast Bar (castBar).
--
--   ON castBar SPECIFICALLY: it is a visual surface and would otherwise
--   be a natural theme member, but THEMED_RP_SECTIONS carries whole
--   sections with no excludeKeys support (only NESTED_SECTIONS has that).
--   Adding castBar as-is would put castBar.enabled, .overlayAnchor and
--   the showPlayer/showPets filters under theme control -- and because
--   WriteThemeSettings WIPES each flat's override for a themed section,
--   applying any theme would silently switch a user's cast bars on or
--   off and move them somewhere else. Same trap already documented for
--   showBuffs/showDebuffs in NESTED_SECTIONS.excludeKeys below.
--   Theming castBar requires teaching the flat path an excludeKeys
--   filter first; until then it stays out.
--   Custom Frame Groups — their flats get the same section treatment as
--   raid/party flats (a theme owns those sections on EVERY flat). The
--   Custom Frame Groups subtab settings (group definitions) are untouched.
--   Unit Frames — every ufDB profile key EXCEPT the Size & Position
--   surface (see UF_EXCLUDE_* below: per-unit geometry/opacity, frame
--   enable toggles, boss spacing/growth, UF layout+position storage,
--   saved detached-castbar anchors).
--   NEVER touched: Aura Customizations (acDB), Incoming Casts (icDB).
--   Because acDB is off limits, the Raid Buffs toggle and the "Global
--   Options" group on the two Preset/Filter subtabs (showRaidBuffs;
--   showSated / Deserter / Skyriding / ArcaneEmpowerment / TimeTrial) are
--   already outside a theme's reach, as are the Preset/Filter subtab
--   (acDB.profile.buffsDisplay), the Whitelist/Blacklist entries and the
--   custom buff containers (acDB.profile.customBuffContainers).
--
-- APPLY SEMANTICS
--   A theme carries FULL section tables for the five flat RP sections, a
--   FILTERED sub-category payload for auras/auraText, and a filtered
--   key/value snapshot for UF (all captured with the "Copy Current
--   Settings" tool on the Themes tab).
--   Flat RP sections apply to the GLOBAL section tables in place (table
--   identity preserved — every flat's __index fallback points at these
--   tables, see WireSectionFallback), and every raid/party flat AND CFG
--   flat gets its per-flat override for those sections WIPED (table.wipe
--   on the raw sub-table keeps the metatable wiring), so the themed look
--   is uniform. Per-flat customizations in NON-themed sections survive.
--   The two nested sections MERGE key-by-key instead, because the theme
--   only owns part of them: the global sub-category tables are filled in
--   place (BOTH tiers of table identity must survive — flat.<section>
--   __index points at the section table and flat.<section>.<subcat>
--   __index points at the sub-category table), and only the payload's
--   keys are overwritten. Un-themed sub-categories and un-themed keys
--   keep their current global values.
--   UF keys are written over ufDB.profile (tables deep-copied).
--
-- FLOWS (popup): Create New Profile = fresh defaults-based profile in
-- rpDB/cfgDB/ufDB (name-synced, disambiguated) + theme. Overwrite
-- Current Profile = theme keys only, everything else kept.
-- ============================================================
local BF = _G["BuzzardFrames"]

-- ============================================================
-- THEMED SURFACE DEFINITIONS
-- ============================================================
-- FLAT rpDB.profile section tables owned by a theme, in their entirety
-- (options tab in comment). These are one level deep: section -> key.
local THEMED_RP_SECTIONS = {
    "text",         -- Text
    "healthPower",  -- Health & Power Bars
    "borders",      -- Borders & Highlights
    "absorbs",      -- Absorbs & Heal Prediction
    "icons",        -- Icons
}

-- ============================================================
-- NESTED SECTIONS (auras, auraText) — FILTERED SURFACE
-- ============================================================
-- These two sections are one level deeper than the rest: the profile
-- stores section -> sub-category -> key (see BF.AURAS_SUBCATEGORIES /
-- BF.AURA_TEXT_SUBCATEGORIES in Core_ProfileAPI.lua). A theme owns only
-- PART of them, so both capture and apply filter by sub-category and, in
-- the auras case, by key.
--
-- `subcats`     — the sub-category tables a theme owns. Anything absent
--                 is never captured and never written, so it survives a
--                 theme apply untouched. NOTE the allowlist doubles as a
--                 legacy filter: retired sub-categories still sitting in
--                 an old profile ("important", "blizzardDebuffs") are
--                 silently dropped from the snapshot.
-- `excludeKeys` — keys inside an OWNED sub-category that the theme must
--                 not carry.
-- `keepTopLevel`— when true, non-table keys at the section root are also
--                 captured (auraText.globalAuraTextConfig lives there and
--                 is NOT inside any sub-category).
--
-- MAPPING FROM THE OPTIONS UI (owner-defined, v60+ Buffs/Debuffs split):
--   Buffs > Buff Settings        -> auras.buffs           (themed)
--   Buffs > Big Defensive        -> auras.bigDef          (themed)
--   Buffs > Preset/Filter        -> acDB.buffsDisplay     (acDB, never themed)
--   Buffs > Whitelist/Blacklist  -> acDB.customBuffContainers (never themed)
--   Buffs > container_<i>        -> acDB.customBuffContainers (never themed)
--   Buffs > Preset/Filter        -> acDB.showRaidBuffs    (acDB, never themed;
--                                   "Raid Buffs" sits on that subtab's root
--                                   page, as Debuffs' Global Options does)
--   Debuffs > Debuffs            -> auras.debuffs         (themed, minus
--                                   the Sorting & Filtering block below)
--   Debuffs > Dispellable Debuffs-> auras.dispelIndicator (themed)
--   (Debuffs > Private Auras is gone -- the sub-category was removed in v67;
--    see the note inside NESTED_SECTIONS below.)
--   Debuffs > Global Options     -> acDB.show*Debuffs     (acDB, never themed)
local NESTED_SECTIONS = {
    auras = {
        subcats = {
            buffs           = true,  -- Buffs > Buff Settings
            bigDef          = true,  -- Buffs > Big Defensive
            debuffs         = true,  -- Debuffs > Debuffs
            dispelIndicator = true,  -- Debuffs > Dispellable Debuffs
            -- v69: crowdControl is GONE -- the dedicated Crowd Control
            -- feature became a seeded custom debuff container (acDB,
            -- never themed), so the sub-category left the options UI.
            -- v67: privateAuras is GONE -- the Private Auras icon feature was
            -- 12.0.7-only and was removed outright when the addon went
            -- 12.1-only. The sub-category no longer exists in
            -- BF.AURAS_SUBCATEGORIES, so its absence here is now the trivially
            -- correct state rather than a deliberate exclusion. Kept as a
            -- comment so nobody "restores" it to the allowlist.
        },
        excludeKeys = {
            -- Master visibility toggles. They sit at the ROOT of the
            -- Buffs/Debuffs tabs, not inside Buff Settings and not inside
            -- the Debuffs body — a theme changes the look, it does not
            -- decide whether the user sees buffs or debuffs at all.
            showBuffs   = true,
            showDebuffs = true,
            -- Debuffs > "Sorting & Filtering" header block
            -- (debuffSortingHeader, order 32-38 in Options_Auras.lua).
            -- v84 (Stage 5 §9.6 + §9.10): the debuff TYPE model. Filtering
            -- and flow order are not "look", so the whole block stays out of
            -- themes exactly as debuffShowMode / enlarge*Debuffs did. The
            -- per-type SIZE sliders are excluded with them deliberately: a size
            -- is meaningless without the toggle and Order that place the group.
            debuffBaseFilter       = true,
            debuffShowOther        = true,
            debuffOtherOrder       = true,
            debuffSortOrder        = true,
            debuffDispellableMode  = true,
            debuffTypeBoss         = true,
            debuffSizeBoss         = true,
            debuffOrderBoss        = true,
            debuffTypeRole         = true,
            debuffSizeRole         = true,
            debuffOrderRole        = true,
            debuffTypeCC           = true,
            debuffSizeCC           = true,
            debuffOrderCC          = true,
            debuffTypePriority     = true,
            debuffSizePriority     = true,
            debuffOrderPriority    = true,
            debuffTypeDispellable  = true,
            debuffSizeDispellable  = true,
            debuffOrderDispellable = true,
            -- v93: the per-type Max Debuffs sliders join the block for the
            -- same reason its sizes are here -- a cap is a filtering decision
            -- that only means anything alongside the toggle and Order that
            -- place the group, and it now also governs the same type inside a
            -- container, which themes never reach.
            debuffMaxBoss          = true,
            debuffMaxRole          = true,
            debuffMaxCC            = true,
            debuffMaxDispMe        = true,
            debuffMaxDispOthers    = true,
            debuffMaxPriority      = true,
            debuffMaxOther         = true,
        },
        keepTopLevel = false,   -- auras has no keys at the section root
    },
    auraText = {
        subcats = {
            stackText    = true,  -- Stack Text
            global       = true,  -- Duration Text (unified)
            buffs        = true,
            debuffs      = true,
            bigDef       = true,
            -- v69: crowdControl is GONE here too (dedicated CC feature
            -- removed; duration text now rides the container settings).
            -- v67: privateAuras is GONE here too -- the Private Aura Duration
            -- Text subtab went with the Private Auras feature, and the
            -- sub-category is no longer in BF.AURA_TEXT_SUBCATEGORIES.
        },
        excludeKeys  = {},
        keepTopLevel = true,    -- globalAuraTextConfig
    },
}

-- Copy the themed slice of a nested section table.
local function FilteredNestedCopy(src, spec)
    local out = {}
    if type(src) ~= "table" then return out end
    for key, value in pairs(src) do
        if spec.subcats[key] then
            if type(value) == "table" then
                local sub = {}
                for k2, v2 in pairs(value) do
                    if not spec.excludeKeys[k2] then
                        sub[k2] = (type(v2) == "table") and BF:DeepCopy(v2) or v2
                    end
                end
                out[key] = sub
            end
        elseif spec.keepTopLevel and type(value) ~= "table" then
            out[key] = value
        end
    end
    return out
end

-- ufDB.profile keys a theme must NOT touch (the Size & Position surface).
local UF_EXCLUDE_TOP = {
    -- UF layout & position storage (Size & Position + Layouts system)
    ufLayouts               = true,
    ufLayoutFrames          = true,
    ufGlobalLayout          = true,
    ufRoleLayouts           = true,
    ufRoleLayoutAssignment  = true,
    ufSpecLayouts           = true,  -- (2026-08-24 sweep fix: was missing
                                     -- while its assignment table was
                                     -- excluded -- themes must not touch
                                     -- the spec-layout selections either)
    ufSpecLayoutAssignment  = true,
    activeUFLayout          = true,
    -- Master + per-frame enable toggles (live in Size & Position subtabs)
    ptfEnabled              = true,
    showPlayerFrame         = true,
    showTargetFrame         = true,
    showFocusFrame          = true,
    showTargetOfTargetFrame = true,
    showFocusTargetFrame    = true,
    showBossFrames          = true,
    showPetFrame            = true,
    -- Boss Size & Position tab
    bossGrowDirection       = true,
    bossFrameSpacing        = true,
}
-- Saved detached-castbar anchor state (runtime position, not a setting).
local UF_EXCLUDE_PATTERNS = {
    "CastBarAnchorX$", "CastBarAnchorY$", "CastBarAnchorSaved$",
}
-- Per-unit geometry/opacity keys inside the unit subtables (Size &
-- Position subtab sliders; bar heights live in per-bar tabs and ARE themed).
local UF_UNIT_SUBTABLES = {
    player = true, target = true, focus = true, boss = true,
    pet = true, targettarget = true, focustarget = true,
}
local UF_EXCLUDE_UNIT_KEYS = {
    anchorX = true, anchorY = true,
    frameWidth = true, frameScale = true, iconScale = true, frameAlpha = true,
}

local function UFKeyExcluded(key)
    if UF_EXCLUDE_TOP[key] then return true end
    for i = 1, #UF_EXCLUDE_PATTERNS do
        if key:find(UF_EXCLUDE_PATTERNS[i]) then return true end
    end
    return false
end

-- ============================================================
-- THEME DEFINITIONS
-- `data` = { rp = { <section> = <full table>, ... }, uf = { key = value } }
-- captured via the "Copy Current Settings as Theme Data" tool below.
-- >>> data = nil means "awaiting values" — the Apply button is disabled.
-- ============================================================
local THEMES = {
    square = {
        name        = "Square Theme",
        profileName = "Square",
        screenshot  = "Interface\\AddOns\\BuzzardFrames\\Media\\ThemeSquare",
        data        = nil,  -- >>> paste the captured Square snapshot here
    },
    glass = {
        name        = "Glass Theme",
        profileName = "Glass",
        screenshot  = "Interface\\AddOns\\BuzzardFrames\\Media\\ThemeGlass",
        data        = nil,  -- >>> paste the captured Glass snapshot here
    },
}
BF.THEMES = THEMES

-- ============================================================
-- SNAPSHOT (capture current settings as theme data)
-- ============================================================
-- Reads the GLOBAL rp section tables (per-layout overrides are NOT
-- captured -- flatten any per-layout customizations you want in the
-- theme into the globals before capturing) and the filtered ufDB keys.
-- Effective auras view for one flat, filtered to the themed surface:
-- the themed slice of the globals with the flat's raw per-layout
-- overrides overlaid (subcat-level key overlay). The filter is applied
-- to BOTH halves, so an un-themed sub-category or key can never reach
-- the snapshot via a per-layout override.
local function MergedAurasView(gp, flat)
    local spec = NESTED_SECTIONS.auras
    local view = FilteredNestedCopy(gp.auras, spec)
    local over = flat and rawget(flat, "auras")
    if type(over) == "table" then
        for subcat, sub in pairs(over) do  -- raw pairs: this flat's overrides only
            local target = spec.subcats[subcat] and view[subcat]
            if target and type(sub) == "table" then
                for k2, v2 in pairs(sub) do
                    if not spec.excludeKeys[k2] then
                        target[k2] = (type(v2) == "table") and BF:DeepCopy(v2) or v2
                    end
                end
            end
        end
    end
    return view
end

-- Canonical source flats for the two auras variants: the seeded
-- defaults (flat_raid40 / flat_party), else the first flat of that type.
local function FindSourceFlat(wantParty)
    local lp = BF.rpDB and BF.rpDB.profile and BF.rpDB.profile.layouts
    local fl = lp and lp.flatLayouts
    if not fl then return nil end
    local seeded = wantParty and fl.flat_party or fl.flat_raid40
    if type(seeded) == "table" then return seeded end
    for _, flat in pairs(fl) do
        if type(flat) == "table" then
            local isParty = (flat.type == "party")
            if isParty == wantParty then return flat end
        end
    end
end

function BF:BuildThemeSnapshot()
    local snap = { rp = {}, uf = {} }
    local gp = self.rpDB and self.rpDB.profile
    if gp then
        for _, section in ipairs(THEMED_RP_SECTIONS) do
            if type(gp[section]) == "table" then
                snap.rp[section] = self:DeepCopy(gp[section])
            end
        end
        -- Aura Cooldown Text: globals only, filtered slice.
        if type(gp.auraText) == "table" then
            snap.rp.auraText = FilteredNestedCopy(gp.auraText, NESTED_SECTIONS.auraText)
        end
        -- Auras: separate raid and party captures (effective views, so
        -- per-layout aura overrides on the source flats ARE included).
        snap.rp.aurasRaid  = MergedAurasView(gp, FindSourceFlat(false))
        snap.rp.aurasParty = MergedAurasView(gp, FindSourceFlat(true))
    end
    local ufp = self.ufDB and self.ufDB.profile
    if ufp then
        for key, value in pairs(ufp) do
            if type(key) == "string" and not UFKeyExcluded(key) then
                if UF_UNIT_SUBTABLES[key] and type(value) == "table" then
                    local sub = {}
                    for k2, v2 in pairs(value) do
                        if not UF_EXCLUDE_UNIT_KEYS[k2] then
                            sub[k2] = self:DeepCopy(v2)
                        end
                    end
                    snap.uf[key] = sub
                else
                    snap.uf[key] = self:DeepCopy(value)
                end
            end
        end
    end
    return snap
end

-- Iterate every flat: raid/party layouts + CFG group flats.
local function EachThemedFlat(fn)
    local lp = BF.rpDB and BF.rpDB.profile and BF.rpDB.profile.layouts
    local fl = lp and lp.flatLayouts
    if fl then
        for _, flat in pairs(fl) do
            if type(flat) == "table" then fn(flat) end
        end
    end
    local cfgp = BF.cfgDB and BF.cfgDB.profile
    local groups = cfgp and cfgp.customFrameGroups
    if groups then
        for _, group in pairs(groups) do
            if type(group) == "table" and type(group.flat) == "table" then
                fn(group.flat)
            end
        end
    end
end

-- Replace the contents of a global section table IN PLACE. Table
-- identity must be preserved: every flat's section metatable __index
-- points at this exact table (WireSectionFallback).
local function FillSectionInPlace(dst, srcCopy)
    table.wipe(dst)
    for k, v in pairs(srcCopy) do dst[k] = v end
end

-- Merge a filtered nested payload into a global nested section table.
--
-- This must NOT be FillSectionInPlace. Two reasons, both load-bearing:
--   1. The payload is a SUBSET. Wiping would delete the un-themed
--      sub-categories (auras.privateAuras, auraText.privateAuras) and the
--      un-themed keys (Sorting & Filtering, showBuffs/showDebuffs)
--      outright. AceDB copies its defaults into the profile at profile
--      creation rather than resolving them through a metatable, so a
--      deleted key reads back nil for the rest of the session — not the
--      default.
--   2. SUB-CATEGORY table identity matters as much as section identity.
--      Every flat.<section>.<subcat> carries a second-tier metatable
--      whose __index points at this exact sub-table
--      (GetOrCreateAurasSubCategory / GetOrCreateAuraTextSubCategory).
--      Replacing the sub-table with a fresh one would leave every
--      surviving per-layout override reading the orphaned old table.
--      So the sub-tables are filled in place too.
local function MergeNestedSectionInPlace(dst, payload)
    for key, value in pairs(payload) do
        if type(value) == "table" then
            local sub = rawget(dst, key)
            if type(sub) ~= "table" then
                sub = {}
                dst[key] = sub
            end
            for k2, v2 in pairs(value) do
                sub[k2] = (type(v2) == "table") and BF:DeepCopy(v2) or v2
            end
        else
            dst[key] = value   -- section-root scalar (globalAuraTextConfig)
        end
    end
end

local function WriteThemeSettings(data)
    -- RP: themed sections → globals in place + wipe per-flat overrides
    -- (table.wipe keeps each raw sub-table's metatable wiring intact;
    -- wiped auras sub-categories re-materialize lazily via
    -- GetOrCreateAurasSubCategory on the next per-layout write).
    local gp = BF.rpDB and BF.rpDB.profile
    if gp and data.rp then
        for _, section in ipairs(THEMED_RP_SECTIONS) do
            local payload = data.rp[section]
            if type(payload) == "table" and type(gp[section]) == "table" then
                FillSectionInPlace(gp[section], BF:DeepCopy(payload))
                EachThemedFlat(function(flat)
                    local t = rawget(flat, section)
                    if type(t) == "table" then table.wipe(t) end
                end)
            end
        end
        -- Aura Cooldown Text: merge the themed sub-categories into the
        -- globals; auraText.privateAuras and any retired sub-category are
        -- left exactly as they are. Per-flat overrides are wiped as with
        -- the flat sections, so every flat resolves the themed values
        -- through its first-tier fallback.
        local atPayload = data.rp.auraText
        if type(atPayload) == "table" and type(gp.auraText) == "table" then
            MergeNestedSectionInPlace(gp.auraText, atPayload)
            EachThemedFlat(function(flat)
                local t = rawget(flat, "auraText")
                if type(t) == "table" then table.wipe(t) end
            end)
        end
        -- Auras: raid variant becomes the GLOBAL auras (raid-type flats
        -- fall through to it — their overrides are wiped); party-type
        -- flats (incl. party-type CFG flats) get the party variant as a
        -- full per-flat override. The auras per-layout toggle is forced
        -- ON so the split renders (it lives in layouts.perLayoutToggles,
        -- which is otherwise un-themed — required by the raid/party
        -- split, owner-approved).
        local raidA  = data.rp.aurasRaid
        local partyA = data.rp.aurasParty
        if type(raidA) == "table" and type(gp.auras) == "table" then
            -- Merge, never wipe: auras.privateAuras, the Sorting &
            -- Filtering keys and showBuffs/showDebuffs are outside the
            -- themed surface and must keep their current global values.
            MergeNestedSectionInPlace(gp.auras, raidA)
            EachThemedFlat(function(flat)
                local t = rawget(flat, "auras")
                if flat.type == "party" and type(partyA) == "table" then
                    if type(t) == "table" then table.wipe(t) end
                    -- GetOrCreateAurasSubCategory creates flat.auras (and
                    -- wires the first tier) when missing, then creates the
                    -- sub-table and points its __index at the global
                    -- sub-category we just merged into — so only the themed
                    -- keys become per-layout overrides and the un-themed
                    -- ones still resolve through the fallback chain.
                    for subcat, sub in pairs(partyA) do
                        if type(sub) == "table" then
                            local target = BF:GetOrCreateAurasSubCategory(flat, subcat)
                            if target then
                                for k2, v2 in pairs(sub) do
                                    target[k2] = (type(v2) == "table") and BF:DeepCopy(v2) or v2
                                end
                            end
                        end
                    end
                elseif type(t) == "table" then
                    table.wipe(t)
                end
            end)
            gp.layouts = gp.layouts or {}
            gp.layouts.perLayoutToggles = gp.layouts.perLayoutToggles or {}
            -- dbVersion 65: the two group toggles became one toggle per aura
            -- sub-category (BF.AURAS_SUBCAT_TOGGLE). A theme rewrites the whole
            -- flat.auras table above, so ALL of them must be forced ON --
            -- leaving any OFF would send that sub-category's themed per-flat
            -- data unread, since aura reads resolve per sub-category.
            --
            -- Generated from the map rather than listed, so a new sub-category
            -- cannot be missed here. This reproduces the previous behavior
            -- exactly under the new key names; refining WHICH toggles a theme
            -- is entitled to force belongs to the theme rework, not here.
            for _, key in pairs(BF.AURAS_SUBCAT_TOGGLE) do
                gp.layouts.perLayoutToggles[key] = true
            end
        end
    end
    -- UF: write snapshot keys (exclusions re-checked defensively so a
    -- hand-edited data table can never touch the Size & Position surface).
    local ufp = BF.ufDB and BF.ufDB.profile
    if ufp and data.uf then
        for key, value in pairs(data.uf) do
            if type(key) == "string" and not UFKeyExcluded(key) then
                if UF_UNIT_SUBTABLES[key] and type(value) == "table" then
                    local sub = ufp[key]
                    if type(sub) ~= "table" then sub = {}; ufp[key] = sub end
                    for k2, v2 in pairs(value) do
                        if not UF_EXCLUDE_UNIT_KEYS[k2] then
                            sub[k2] = BF:DeepCopy(v2)
                        end
                    end
                else
                    ufp[key] = BF:DeepCopy(value)
                end
            end
        end
    end
end

-- Full refresh after direct profile mutation: the same arg-free
-- per-module handlers a real profile switch runs.
local function RefreshThemedModules()
    if BF.OnRPProfileChanged  then BF:OnRPProfileChanged()  end
    if BF.OnCFGProfileChanged then BF:OnCFGProfileChanged() end
    if BF.OnUFProfileChanged  then BF:OnUFProfileChanged()  end
end

local function DisambiguateThemeProfileName(baseName)
    local dbs = { BF.rpDB, BF.cfgDB, BF.ufDB }
    local function taken(name)
        for _, db in ipairs(dbs) do
            if db then
                for _, existing in ipairs(db:GetProfiles()) do
                    if existing == name then return true end
                end
            end
        end
        return false
    end
    local candidate, i = baseName, 1
    while taken(candidate) do
        i = i + 1
        candidate = baseName .. " " .. i
    end
    return candidate
end

-- Flow: overwrite the current rp/cfg/uf profiles with the theme.
function BF:ApplyThemeToCurrentProfiles(themeKey)
    if InCombatLockdown() then return end
    local theme = THEMES[themeKey]
    if not theme or not theme.data then return end
    WriteThemeSettings(theme.data)
    RefreshThemedModules()
    self:RefreshPanel("theme")
    print(string.format(
        "|cffd3ff7dBuzzardFrames:|r Applied %s to the current Raid/Party Frames, Custom Frame Groups and Unit Frames profiles.",
        theme.name))
end

-- Flow: fresh defaults-based profiles in the three DBs, then the theme.
function BF:ApplyThemeAsNewProfiles(themeKey)
    if InCombatLockdown() then return end
    local theme = THEMES[themeKey]
    if not theme or not theme.data then return end
    local name = DisambiguateThemeProfileName(theme.profileName or theme.name)
    if BF.rpDB  then BF.rpDB:SetProfile(name)  end
    if BF.cfgDB then BF.cfgDB:SetProfile(name) end
    if BF.ufDB  then BF.ufDB:SetProfile(name)  end
    WriteThemeSettings(theme.data)
    RefreshThemedModules()
    self:RefreshPanel("theme")
    print(string.format(
        "|cffd3ff7dBuzzardFrames:|r Created profile '%s' (%s) for Raid/Party Frames, Custom Frame Groups and Unit Frames. Aura Customizations and Incoming Casts were not changed.",
        name, theme.name))
end

-- ============================================================
-- APPLY POPUP
-- ============================================================
StaticPopupDialogs["BUZZARDFRAMES_APPLY_THEME"] = {
    text = "Apply the %s?\n\n|cffffd200Create New Profile|r starts from the addon defaults in a brand-new profile.\n|cffffd200Overwrite Current Profile|r keeps all your current settings and changes only the theme's settings.\n\nOnly Raid/Party Frames, Custom Frame Groups and Unit Frames are affected.",
    button1 = "Create New Profile",
    button3 = "Overwrite Current Profile",
    button2 = "Cancel",
    OnAccept = function(popup)
        BF:ApplyThemeAsNewProfiles(popup.data)
    end,
    OnAlt = function(popup)
        BF:ApplyThemeToCurrentProfiles(popup.data)
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}
