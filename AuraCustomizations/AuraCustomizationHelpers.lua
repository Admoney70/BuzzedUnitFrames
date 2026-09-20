-- ============================================================
-- BuzzardFrames: AuraCustomizations/AuraCustomizationHelpers.lua
-- AC-specific lookup functions for per-spec spell color,
-- border color, and solid icon overrides.
--
-- Extracted from Auras/AuraConfig.lua. All reads come from the
-- AuraCustomizations namespace (BF.acDB.profile).
--
-- Must be loaded after AuraConfig.lua (needs BF.playerSpecID).
-- ============================================================
local BF = _G["BuzzardFrames"]

local canaccessvalue = canaccessvalue or function(val) return true end

-- v43 master customize flag: every per-spell lookup is gated on
-- specSpellCustomized[specId][sid]. Unflagged spells behave as if they
-- have no customizations at all (both engines; preview included).
--
-- v62 OWNER DECISION: the curated (Aura Customizations section) per-spell
-- settings drive 12.0.7 ONLY. On 12.1 per-spell visuals exist solely as
-- Single Buff entries, read through the sbC branches of the getters below.
-- Every curated per-spell getter routes through this predicate, so failing
-- it on 12.1 is the single choke point that inactivates them there -- for
-- live frames AND for the options previews, which use the same getters and
-- must show what 12.1 live shows.
--
-- v64: STILL TRUE OF VISUALS, no longer true of the feature as a whole. Order
-- was split out and is now live on 12.1: an ordered spell gets its own
-- per-spell group (GetContainerBuffConfig in AuraCustomizations.lua), because
-- layoutIndex orders groups and no sort comparator takes a user rank. That
-- group is styled by DeriveSpellButtonSpec, which starts from the plain
-- BuffButtonSpec and only layers overrides where a getter returns something --
-- so with this predicate still closed, a promoted spell is ordered but looks
-- like any other buff. That is deliberate and is the whole shape of the
-- deferral.
--
-- Un-gating THIS is what turns per-spell visuals back on for 12.1 containers,
-- and is the future "group type" dropdown. Two things must move with it, or
-- the result is inconsistent: the direct (non-helper) per-spell visual-alert
-- read in DeriveSpellButtonSpec, and the options UI that currently offers only
-- Display Type + Order per assigned spell. See
-- Docs/Per_Spell_Settings_In_Container_Subtabs_Plan.md.
--
-- v67: 12.0.7 branch removed (addon is 12.1-only). The flag is permanently
-- true, so this predicate is permanently FALSE and the curated per-spell
-- lookup below it (specSpellCustomized[specId][spellId]) is unreachable --
-- it is deleted rather than left dangling because Lua requires `return` to
-- end its block. Un-gating per-spell visuals for containers means restoring
-- that lookup here; see the note above.
local function IsCust(specId, spellId)
    return false
end

-- ============================================================
-- v62 (plan 3.67 slice 2): SINGLE-BUFF VISUAL STORE
--
-- A single buff owns its per-entry visuals, because two entries of the same
-- spell must be able to look different -- which acDB.profile.specSpell*
-- [specId][spellId] cannot express. The options side writes them through a
-- STORAGE ACCESSOR (Options_AuraCustomizations.lua) whose only difference from
-- the curated one is where the family tables live and what the first key is:
--
--   curated spell -> acDB.profile[family][<specID>][spellID]
--   single buff   -> container.sbVisuals[family]["sb"][spellID]
--
-- The specSpell* families are NOT re-keyed. This is a second source alongside
-- them; every getter below takes an OPTIONAL single-buff container and reads
-- that source instead when one is supplied. Passing nil (every pre-existing
-- caller) is byte-for-byte the old behavior, so nothing on a per-aura path
-- changes: the branch only exists where the caller already knows it is styling
-- a single buff's container, which is settings/Layout time by construction.
--
-- The master-customize flag has no analogue here. A single buff's own Display
-- Type dropdown plays that role: "Show (Default Buff)" sets
-- singleBuffCustomized = false, which nils out the store below so the icon
-- falls back to the container's own settings.
-- ============================================================
local SB_KSPEC = "sb"

-- The store root for a single-buff container, or nil (not a single buff / not
-- in Customized mode / nothing configured).
local function SBRoot(c)
    if type(c) ~= "table" or not c.singleBuff then return nil end
    if c.singleBuffCustomized == false then return nil end
    return c.sbVisuals
end
BF.GetSingleBuffVisualRoot = SBRoot

-- One family's entry for `spellId` on a single-buff container, or nil.
local function SBEntry(c, family, spellId)
    local root = SBRoot(c)
    local fam  = root and root[family]
    local map  = fam and fam[SB_KSPEC]
    return map and map[spellId] or nil
end
BF.GetSingleBuffVisualEntry = SBEntry

-- ============================================================
-- SOLID ICON OVERRIDE HELPER
-- Returns the solid color table {r,g,b} for a spellId if configured,
-- or nil to use the normal icon texture.
-- ============================================================
-- v62: `sbC` is an optional single-buff CONTAINER. When present the entry comes
-- from that container's own store and the spec / master-flag gates do not apply
-- (a single buff has neither).
local function GetSolidIconColor(spellId, sbC)
    if not spellId or not canaccessvalue(spellId) then return nil end
    if sbC then
        local e = SBEntry(sbC, "specSpellSolidIcons", spellId)
        if not e or e.enabled == false then return nil end
        return e
    end
    local specId = BF.playerSpecID
    if not specId then return nil end
    if not IsCust(specId, spellId) then return nil end
    local p = BF.acDB and BF.acDB.profile
    local si = p and p.specSpellSolidIcons and p.specSpellSolidIcons[specId]
    local entry = si and si[spellId]
    if entry and entry.enabled == false then return nil end
    return entry
end
BF.GetSolidIconColor = GetSolidIconColor

-- v67: BF.GetBuffsSolidIconColor removed. It was the blanket "any buff visible"
-- solid icon color, a 12.0.7-only AC setting; with that client gone the stub
-- returned nil unconditionally, so every caller's fallback branch was dead.
-- Callers must drop the fallback rather than nil-guard the missing function.

-- Returns the custom border color table {r,g,b} for a spellId if configured,
-- or nil to use the default border.
local function GetSpellBorderColor(spellId, sbC)
    if not spellId or not canaccessvalue(spellId) then return nil end
    if sbC then
        local e = SBEntry(sbC, "specSpellBorderColors", spellId)
        if not e or e.enabled == false then return nil end
        return e
    end
    local specId = BF.playerSpecID
    if not specId then return nil end
    if not IsCust(specId, spellId) then return nil end
    local p = BF.acDB and BF.acDB.profile
    local bc = p and p.specSpellBorderColors and p.specSpellBorderColors[specId]
    local entry = bc and bc[spellId]
    if entry and entry.enabled == false then return nil end
    return entry
end
BF.GetSpellBorderColor = GetSpellBorderColor

-- v67: BF.GetBuffsBorderColor removed, for the same reason as
-- GetBuffsSolidIconColor above -- a 12.0.7-only blanket setting whose stub
-- returned nil unconditionally.

-- Returns the STORED icon type string for a spellId if configured:
-- "Square"; nil for default ("Icon"). Legacy saved values may still be
-- "BorderedSquare" (v69: replaced by Square + the solid entry's
-- showBorder flag) or "SquareDuration" (v69: merged into Square — the
-- glyph render path follows the entry's thresholdEnabled flag instead).
-- Consumers map both legacy values at READ time rather than migrating
-- them (profile copies dodge numbered migrations).
local function GetSpellIconType(spellId, sbC)
    if not spellId or not canaccessvalue(spellId) then return nil end
    if sbC then
        return SBEntry(sbC, "specSpellIconType", spellId)
    end
    local specId = BF.playerSpecID
    if not specId then return nil end
    if not IsCust(specId, spellId) then return nil end
    local p = BF.acDB and BF.acDB.profile
    local it = p and p.specSpellIconType and p.specSpellIconType[specId]
    return it and it[spellId]
end
BF.GetSpellIconType = GetSpellIconType

-- ============================================================
-- Per-spell BORDER SHAPE override (v87).
-- Returns the specSpellSolidIcons entry that carries the shared
-- border fields (useBuffsBorder / showBorder / borderStyle /
-- borderThickness), or nil when none is configured.
--
-- Unlike GetSolidIconColor this IGNORES the entry's `enabled`
-- flag: `enabled == false` only means the SOLID COLOR (Square
-- fill) is off — it is set false whenever the icon type is Icon
-- (the icon-type setter, Options_AuraCustomizations.lua). The
-- border fields on that same entry stay valid for an Icon-type
-- buff, which is exactly the case this accessor serves. The
-- render side (DeriveSpellButtonSpec) reads it ONLY on the Icon
-- path, so it never competes with the Square path's own read.
-- ============================================================
local function GetSpellBorderShape(spellId, sbC)
    if not spellId or not canaccessvalue(spellId) then return nil end
    if sbC then
        return SBEntry(sbC, "specSpellSolidIcons", spellId)
    end
    local specId = BF.playerSpecID
    if not specId then return nil end
    if not IsCust(specId, spellId) then return nil end
    local p = BF.acDB and BF.acDB.profile
    local si = p and p.specSpellSolidIcons and p.specSpellSolidIcons[specId]
    return si and si[spellId]
end
BF.GetSpellBorderShape = GetSpellBorderShape

-- Resolve "Use Buffs Border" for a border-shape entry (v87). Stored as an
-- explicit boolean once the user touches it; when ABSENT the default is
-- per-type: Icon inherits the container border (true), Square draws its own
-- (false, preserving the pre-v87 bare square). The options side
-- (Options_AuraCustomizations.lua useBuffsBorderOn) resolves identically —
-- keep the two in lockstep.
local function UseBuffsBorderOn(entry, isSquare)
    local v = entry and entry.useBuffsBorder
    if v == true then return true end
    if v == false then return false end
    return not isSquare
end
BF.UseBuffsBorderOn = UseBuffsBorderOn

-- ============================================================
-- SOLID ICON COLOR CURVE (remaining-time thresholds)
-- Builds and caches a Step color curve per spellId from the
-- threshold settings in specSpellSolidIcons. Returns the curve
-- object or nil if thresholds are not enabled.
--
-- Grid2 pattern (IndicatorIcon.lua): Step curve with AddPoint
-- at each threshold. Evaluated via EvaluateRemainingDuration.
-- ============================================================
BF._solidIconColorCurveCache = BF._solidIconColorCurveCache or {}

local function GetSolidIconColorCurve(spellId, sbC)
    if not spellId or not canaccessvalue(spellId) then return nil end
    local entry, cacheKey
    if sbC then
        entry    = SBEntry(sbC, "specSpellSolidIcons", spellId)
        -- Per-ENTRY cache key: two single buffs of one spell may hold different
        -- threshold colors, and the spellId-keyed cache would alias them.
        cacheKey = "sb:" .. tostring(sbC.singleBuffKey) .. ":" .. spellId
    else
        local specId = BF.playerSpecID
        if not specId then return nil end
        if not IsCust(specId, spellId) then return nil end
        local p = BF.acDB and BF.acDB.profile
        local si = p and p.specSpellSolidIcons and p.specSpellSolidIcons[specId]
        entry    = si and si[spellId]
        cacheKey = spellId
    end
    if not entry or entry.enabled == false or not entry.thresholdEnabled then return nil end

    local t1 = entry.thresholdSecs or 8
    local t2Enabled = entry.secondaryEnabled
    local t2 = entry.secondarySecs or 4
    -- 2026-09-11: the key is the curve's INPUTS, not just the entry, so the
    -- function is pure like BuildThresholdColorCurve (Auras/AuraConfig.lua):
    -- a settings edit mints a new key, unchanged settings return the SAME
    -- object -- and nothing ever needs to wipe this cache. It used to be
    -- wiped wholesale by RefreshAllCustomContainersWithRebuild in the load
    -- tail, so the first Layout after load saw a fresh curve address for
    -- identical settings; ButtonSpecSig / the style snapshot compare curves
    -- by identity, and inside a keystone that miss is a rebuilt container.
    cacheKey = cacheKey .. "|" .. tostring(t1) .. "|" .. tostring(t2Enabled and true or false)
        .. "|" .. tostring(t2)
        .. "|" .. tostring(entry.r) .. "," .. tostring(entry.g) .. "," .. tostring(entry.b) .. "," .. tostring(entry.a)
        .. "|" .. tostring(entry.thresholdR) .. "," .. tostring(entry.thresholdG) .. "," .. tostring(entry.thresholdB) .. "," .. tostring(entry.thresholdA)
        .. "|" .. tostring(entry.secondaryR) .. "," .. tostring(entry.secondaryG) .. "," .. tostring(entry.secondaryB) .. "," .. tostring(entry.secondaryA)

    -- Return cached curve if available
    local cache = BF._solidIconColorCurveCache
    if cache[cacheKey] then return cache[cacheKey] end

    -- Build step curve directly (Grid2 IndicatorIcon.lua pattern).
    -- Can't reuse BuildThresholdColorCurve because it hardcodes alpha=1
    -- for the above-threshold color, but solid icon color needs to
    -- preserve the user's Icon Color alpha on every poll tick.
    if not (C_CurveUtil and C_CurveUtil.CreateColorCurve and Enum and Enum.LuaCurveType) then return nil end
    -- Bounded: a color-picker drag can mint many distinct keys.
    local n = 0
    for _ in pairs(cache) do n = n + 1; if n > 256 then table.wipe(cache); break end end
    local curve = C_CurveUtil.CreateColorCurve()
    curve:SetType(Enum.LuaCurveType.Step)
    if t2Enabled and t2 < t1 then
        curve:AddPoint(0,  CreateColor(entry.secondaryR or 1, entry.secondaryG or 0, entry.secondaryB or 0, entry.secondaryA or 1))
        curve:AddPoint(t2, CreateColor(entry.thresholdR or 1, entry.thresholdG or 0.5, entry.thresholdB or 0, entry.thresholdA or 1))
        curve:AddPoint(t1, CreateColor(entry.r or 0, entry.g or 0.7, entry.b or 1, entry.a or 1))
    else
        curve:AddPoint(0,  CreateColor(entry.thresholdR or 1, entry.thresholdG or 0.5, entry.thresholdB or 0, entry.thresholdA or 1))
        curve:AddPoint(t1, CreateColor(entry.r or 0, entry.g or 0.7, entry.b or 1, entry.a or 1))
    end
    if curve then cache[cacheKey] = curve end
    return curve
end
BF.GetSolidIconColorCurve = GetSolidIconColorCurve

-- ============================================================
-- PER-SPELL COOLDOWN TEXT OVERRIDE
-- Returns the per-spell cooldown text settings table for a spellId,
-- or nil if no override is configured (enabled == false or absent).
--
-- When the entry has separateGroupConfig == true and a groupTypeKey
-- is provided, the returned table is the group-type-specific
-- sub-table (with fallback reads delegated to the caller).
-- The raw entry is always available as the second return value so
-- callers can implement field-level fallback (gs field → entry field).
--
-- Storage: acDB.profile.specSpellCooldownText[specId][spellId]
-- ============================================================
local function GetSpellCooldownText(spellId, groupTypeKey, sbC)
    if not spellId or not canaccessvalue(spellId) then return nil, nil end
    local entry
    if sbC then
        entry = SBEntry(sbC, "specSpellCooldownText", spellId)
    else
        local specId = BF.playerSpecID
        if not specId then return nil, nil end
        if not IsCust(specId, spellId) then return nil, nil end
        local p = BF.acDB and BF.acDB.profile
        local ct = p and p.specSpellCooldownText and p.specSpellCooldownText[specId]
        entry = ct and ct[spellId]
    end
    if not entry then return nil, nil end
    -- Per-layout resolution: when separateGroupConfig is on, the enabled
    -- flag lives on the groupSettings sub-table, not on the entry itself.
    if entry.separateGroupConfig and groupTypeKey then
        local gs = entry.groupSettings and entry.groupSettings[groupTypeKey]
        if not gs or gs.enabled == false then return nil, nil end
        return gs, entry
    end
    -- Global (non-per-layout): check entry.enabled
    if entry.enabled == false then return nil, nil end
    return entry, entry
end
BF.GetSpellCooldownText = GetSpellCooldownText

-- ============================================================
-- v84 (Stage 5 §9.9) PER-SPELL ICON EFFECT
-- Returns the per-spell Icon Effects settings table for a spellId, or nil
-- when nothing is configured.
--
-- Storage: acDB.profile.specSpellIconEffect[specId][spellId]
-- Entry shape:
--   { effect    = "none"|"glow"|"ants"|"flash",
--     glowStyle = "steady"|"pulse",          -- glow only
--     color     = { r, g, b, a },            -- Effect Color
--     pandemic  = boolean, pandemicColor = { r, g, b, a },
--     desaturate = boolean,
--     recolor   = boolean, recolorColor = { r, g, b, a } }
--
-- Same shape and same gates as the retired per-spell Expiration Glow
-- resolver it replaced (removed with ExpirationGlow.lua):
-- single hash lookup on the hot path, the master customize flag applies to
-- curated spec spells, and `sbC` (a single-buff container) routes to that
-- entry's own store where neither the spec nor the flag exists.
-- ============================================================
local function GetSpellIconEffect(spellId, sbC)
    if not spellId or not canaccessvalue(spellId) then return nil end
    if sbC then
        local e = SBEntry(sbC, "specSpellIconEffect", spellId)
        if not e or e.enabled == false then return nil end
        return e
    end
    local specId = BF.playerSpecID
    if not specId then return nil end
    if not IsCust(specId, spellId) then return nil end
    local p = BF.acDB and BF.acDB.profile
    local sg = p and p.specSpellIconEffect and p.specSpellIconEffect[specId]
    local entry = sg and sg[spellId]
    if not entry or entry.enabled == false then return nil end
    return entry
end
BF.GetSpellIconEffect = GetSpellIconEffect

-- Fold a resolved Icon Effects entry onto a button spec. One place, so the
-- live container path, the single-buff slot path and the preview painters
-- cannot drift apart on what a stored entry means.
--
-- SINGLE PASS by contract: resolve everything, apply once at the tail. A
-- teardown-then-reapply restarts the animations visibly.
function BF.ApplyIconEffectToSpec(spec, e)
    if not (spec and e) then return end
    local fx = e.effect
    local c  = e.color
    if fx == "glow" then
        -- Glow rides the existing presence-glow ring (spec.showGlow), so one
        -- owner draws it; glowPulse picks Steady vs Pulsing.
        spec.showGlow  = true
        spec.glowPulse = (e.glowStyle == "pulse")
        spec.glowColor = c and { c.r or 1, c.g or 0.82, c.b or 0.25, c.a or 1 }
            or { 1, 0.82, 0.25, 1 }
    elseif fx == "ants" or fx == "flash" then
        spec.iconEffect = fx
        spec.iconEffectColor = c and { c.r or 1, c.g or 0.82, c.b or 0.25, c.a or 1 }
            or { 1, 0.82, 0.25, 1 }
    end
    if e.desaturate then spec.iconDesaturate = true end
    if e.recolor then
        spec.iconRecolor = true
        spec.iconRecolorColor = e.recolorColor
    end
    if e.pandemic then
        spec.pandemic = true
        -- v92: COPY, never alias. `spec` is retained (it is the button spec the
        -- container keeps and re-signs), while `e` may be a resolver's return --
        -- BF:ResolveContainerIconEffect hands back an INTERNED default table
        -- when the container leaves Pandemic Color unset, so aliasing would put
        -- one shared table on every such spec. Every other color here is
        -- already built fresh; this was the one that was not.
        --
        -- RECORD shape {r,g,b,a}, not the array shape used for glowColor /
        -- iconEffectColor: both consumers read it by field name --
        -- ContainerFactory's pandemic texture applier (pc.r/g/b/a) and
        -- ButtonSpecSig's pandemic fold. The `or` defaults are that applier's,
        -- restated so a sparse stored color signs and paints identically.
        local pc = e.pandemicColor
        spec.pandemicColor = {
            r = pc and pc.r or 0.239216,
            g = pc and pc.g or 1,
            b = pc and pc.b or 0.254902,
            a = pc and pc.a or 0.15,
        }
    end
end

-- ============================================================
-- PER-SPELL BOUNCE (REMOVED)
--
-- v66: bounce does nothing on 12.1 -- the engine owns the icon's position, so
-- the animation has nothing to move. Its options are hidden there, and the
-- runtime getter was reduced to an unconditional `return nil` gate.
--
-- v67: BF.GetSpellBounce / BF.ResolveSpellBounce removed with the 12.0.7
-- client. Storage (acDB.profile.specSpellBounce[specId][spellId], entry shape
-- { enabled?, threshold = <secs>, showMode = "always"|"threshold" }) is left
-- untouched in saved variables. Restoring the feature means restoring the
-- getter here plus the sbC / curated lookups the other getters above model.
-- ============================================================
