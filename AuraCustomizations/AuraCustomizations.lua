-- ============================================================
-- BuzzardFrames: CustomAuras.lua
-- Custom per-spell aura injection into the standard debuff display,
-- and management / display of custom buff containers.
-- ============================================================
local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

-- v67: the GetUnitAuras / UnitIsVisible / GetActiveHeroTalentSpec upvalues were
-- removed with BF:FetchBuffData and the secret-detection resolution -- nothing
-- in this file scans auras per unit any more.
local GetUnitAuraBySpellID    = C_UnitAuras.GetUnitAuraBySpellID
local GetPlayerAuraBySpellID  = C_UnitAuras.GetPlayerAuraBySpellID
local math_floor   = math.floor
local math_max     = math.max
local ipairs, pairs = ipairs, pairs
local canaccessvalue = canaccessvalue or function(v) return true end
local IsPlayerSpell = IsPlayerSpell

-- ============================================================
-- PREVIEW STATE API
-- Centralised preview mode for Aura Customizations options.
-- Replaces scattered BF._previewing* flags with a single state
-- table and explicit setters. Modes:
--   nil              — no special preview (general auras tab)
--   "containerMgmt"  — Container Management tab is open
--   "spell"          — Per-spell settings page is open
--   "buffList"       — the Auras > Buffs > Buff List subtab is open
--
-- v94: the "buffList" mode. Unlike the other two it does NOT narrow the
-- preview to one thing: it carries the subtab's Filter by Spec value plus the
-- tree's selected entry key, and the row assemblers in DummyAuras.lua merge
-- every MATCHING single buff into the row its anchor names. Only the FRAME
-- effects are keyed to the selection (see _PLAN_BuffListPreview.md §1.1).
--
-- specFilter 0 is the dropdown's "All": too many entries to draw at once, so
-- that value previews only the selected entry, and nothing at all when there
-- is no selection. sbKey is a singleBuffKey (the stable string identity every
-- option closure resolves through BF:FindSingleBuffByKey), never an index.
-- ============================================================
local _pvState = {
    mode = nil, containerIndex = nil, spellID = nil, specID = nil,
    sbFilter = nil, sbKey = nil,
}

--- Enter container management preview (clears any spell preview).
--- @param containerIndex number|nil  which container tab is active
function BF:SetContainerPreview(containerIndex)
    _pvState.mode = "containerMgmt"
    if containerIndex then _pvState.containerIndex = containerIndex end
    _pvState.spellID = nil
    _pvState.specID  = nil
    _pvState.sbFilter, _pvState.sbKey = nil, nil
end

--- Enter spell preview (clears any container preview).
--- @param spellID number
--- @param specID  number
function BF:SetSpellPreview(spellID, specID)
    local prevSid = _pvState.spellID
    _pvState.mode           = "spell"
    _pvState.spellID        = spellID
    _pvState.specID         = specID
    _pvState.containerIndex = nil
    _pvState.sbFilter, _pvState.sbKey = nil, nil
    -- Spell changed: tear down preview-only effects from the previous
    -- spell so we don't leave stale glow/bounce on icons that may now
    -- be rendering a different spell (or no spell at all if untracked).
    -- The follow-up render+apply on the new spell starts fresh.
    if prevSid ~= spellID and BF.PreviewIconEffects_ClearAll then
        BF:PreviewIconEffects_ClearAll()
    end
end

--- Enter Buff List preview. Change-guarded by the caller's own feed, but the
--- icon-effect teardown below has to run on the EDGE, so the compare is here.
--- @param specFilter number|nil  the subtab's Filter by Spec (0 = All)
--- @param sbKey      string|nil  singleBuffKey of the selected tree entry
function BF:SetBuffListPreview(specFilter, sbKey)
    local prevMode   = _pvState.mode
    local prevFilter = _pvState.sbFilter
    local prevKey    = _pvState.sbKey
    _pvState.mode           = "buffList"
    _pvState.sbFilter       = tonumber(specFilter) or 0
    _pvState.sbKey          = sbKey
    _pvState.containerIndex = nil
    _pvState.spellID        = nil
    _pvState.specID         = nil
    -- Same reasoning as SetSpellPreview: the set of icons carrying preview-only
    -- fx changes when the selection or the filter moves (or when we arrive from
    -- another mode), and ApplyPreviewFx never tears down on its own (it would
    -- restart the animations). Anything not repainted by the pass that follows
    -- would keep a glow it no longer owns.
    if (prevMode ~= "buffList" or prevFilter ~= _pvState.sbFilter or prevKey ~= sbKey)
       and BF.PreviewIconEffects_ClearAll then
        BF:PreviewIconEffects_ClearAll()
    end
end

--- Clear all preview state (section exit / entering non-preview tab).
function BF:ClearAuraPreview()
    _pvState.mode           = nil
    _pvState.containerIndex = nil
    _pvState.spellID        = nil
    _pvState.specID         = nil
    _pvState.sbFilter       = nil
    _pvState.sbKey          = nil
    -- Tear down any preview-only icon effects (glow/bounce) currently
    -- attached to preview frames. Lives in PreviewIconEffects.lua —
    -- see notes there. Live frames are never touched by this path.
    if BF.PreviewIconEffects_ClearAll then
        BF:PreviewIconEffects_ClearAll()
    end
end

--- Read helpers (used by DummyAuras.lua dispatcher and ShowDummy*).
function BF:IsPreviewingContainerMgmt() return _pvState.mode == "containerMgmt" end
function BF:GetPreviewContainerIndex()  return _pvState.containerIndex end
function BF:IsPreviewingSpell()         return _pvState.mode == "spell" end
function BF:GetPreviewSpellID()         return _pvState.spellID end
function BF:GetPreviewSpecID()          return _pvState.specID end
function BF:IsPreviewingBuffList()      return _pvState.mode == "buffList" end
function BF:GetBuffListPreviewFilter()  return _pvState.sbFilter or 0 end
function BF:GetBuffListPreviewKey()     return _pvState.sbKey end

-- Resto Druid swiftmendable spell IDs (spec 105). Shared with CustomContainers.lua.
local SWIFTMENDABLE_IDS = { [774]=true, [8936]=true, [48438]=true, [155777]=true }
BF.SWIFTMENDABLE_IDS = SWIFTMENDABLE_IDS
-- Verdant Infusion talent: Swiftmend no longer requires a HoT, so every
-- unit is always swiftmendable — the whole feature is moot. Gates the 12.1
-- cfg build below; re-evaluated via InvalidateClaimedSpellCache on
-- PLAYER_TALENT_UPDATE / TRAIT_CONFIG_UPDATED.
local VERDANT_INFUSION = 392410

-- v33: container-side default border color resolver.
-- Mirrors BF.GetDefaultBorderColorFor in AuraConfig.lua but reads from a
-- specific container (and its group-type override) instead of AuraCache.
-- When the container's effective colorAuraBorder is on, the default border
-- is the container's Font Color at alpha 0.8; otherwise it's the legacy
-- black (0, 0, 0, 0.8). Used by every container-side stamp site so that
-- toggling Color Aura Border on/off affects the icon border even when no
-- custom per-spell color is set.
--
-- c:  the container table (from GetActiveCustomBuffContainers()[ci])
-- gs: the group-type override table for this container/groupType (may be nil)
-- Returns: r, g, b, a
local function GetContainerDefaultBorderColor(c, gs)
    local s = gs or c
    local colorBorder = s.colorAuraBorder
    if colorBorder == nil then colorBorder = c.colorAuraBorder end
    if not colorBorder then
        return 0, 0, 0, 0.8
    end
    local fc = s.fontColor
    if fc == nil and s ~= c then fc = c.fontColor end
    if not fc then
        return 1, 1, 1, 0.8  -- no fontColor set: fall back to white border
    end
    return fc.r or 1, fc.g or 1, fc.b or 1, 0.8
end
BF.GetContainerDefaultBorderColor = GetContainerDefaultBorderColor

-- v67: the CLASS RAID BUFF INJECTION helpers (FetchClassRaidBuff plus its
-- GetRaidBuffSpellName / raidBuffSpellNames name cache) removed -- they existed
-- only to append the player's class raid buff to the deleted per-unit scan's
-- scratch result. The showRaidBuffs FEATURE is unaffected: on 12.1 it renders
-- from its own out-of-combat raidbuffs aura group, and GetContainerBuffConfig
-- still excludes BF.SPEC_RAID_BUFF_IDS from the general group so the two do not
-- both claim the aura. BF.GetRaidBuffLookupID is still live for that path.

-- Derived lookup tables built from BF.SPEC_SPELLS.
-- SPEC_TRACK_LIST[specId][spellId] = true  for non-untracked spells.
-- DEFAULT_UNTRACKED_BY_SPEC[specId][spellId] = true  for untracked spells.
local SPEC_TRACK_LIST         = {}
local DEFAULT_UNTRACKED_BY_SPEC = {}
for specId, spells in pairs(BF.SPEC_SPELLS) do
    local track     = {}
    local untracked = {}
    for _, s in ipairs(spells) do
        if s.untracked then
            untracked[s.id] = true
        else
            -- v70: no secretDetection exclusion — the 12.0.7-era secret
            -- detection machinery is gone; every tracked curated spell
            -- matches by plain spell ID on 12.1.
            track[s.id] = true
        end
    end
    SPEC_TRACK_LIST[specId] = track
    if next(untracked) then
        DEFAULT_UNTRACKED_BY_SPEC[specId] = untracked
    end
end

-- v70: BF._secretDetectionIDs / BF._secretDetectionAllowSelf /
-- BF._secretDetectionRICIDs DELETED (owner decision). They were the last
-- remnants of the 12.0.7-era "secret detection" machinery (elimination by
-- filter fingerprint, hero-tree sentinel resolution, Holy Bulwark aliased
-- onto Holy Armaments) — v67 had already removed the runtime elimination
-- pass, leaving only settings-time bookkeeping: excluding the sentinel
-- ids from the trackList and special-casing them in the container gate.
-- On 12.1 these auras match by plain spell ID like every other aura, so
-- their curated rows are now ordinary rows (each with its own id,
-- including Sacred Weapon 432502 and Holy Bulwark 432496 as separate
-- entries) and both special cases are gone. Do not reintroduce the
-- flags; TrackedAuras.lua rows carry no secretDetection fields anymore.

-- Returns the set of spell IDs to fetch from HELPFUL for this spec.
-- Includes base track list + any DEFAULT_UNTRACKED spells the user has
-- set to "default" or assigned to a container.
-- Returns nil for specs with no track list.
--
-- The merged result is cached per-spec and reused across all UNIT_AURA calls
-- (up to 40/tick in a 40-man raid). The cache is invalidated by
-- InvalidateTrackListCache(), which is called from InvalidateClaimedSpellCache
-- on every spec change, talent change, and spellAssign edit -- the only events
-- that can change what GetTrackList returns.
local trackListCache    = {}   -- specId -> merged table (or false = use base)
local trackListCacheKey = {}   -- specId -> assign-table reference used to build it

local function InvalidateTrackListCache()
    table.wipe(trackListCache)
    table.wipe(trackListCacheKey)
end

local function GetTrackList(specId)
    local base = SPEC_TRACK_LIST[specId]
    if not base then return nil end
    local p = BF.db and BF.db.profile
        local acp = BF.acDB and BF.acDB.profile
    local assign = acp and acp.spellAssign and acp.spellAssign[specId]
    if not assign then return base end

    -- Return the cached merged table when assign hasn't changed.
    if trackListCacheKey[specId] == assign and trackListCache[specId] ~= nil then
        return trackListCache[specId] or base
    end

    -- v70: no sentinel exclusion — the secret-detection machinery is gone
    -- and every assigned spell may enter the trackList (plain spell-ID
    -- matching on 12.1).
    local merged = nil
    for sid, val in pairs(assign) do
        if val ~= "untracked" then
            if not merged then
                merged = {}
                for s in pairs(base) do merged[s] = true end
            end
            merged[sid] = true
        end
    end
    -- Store merged (or false as sentinel meaning "no merge needed") so the
    -- next call skips the pairs() loop entirely.
    trackListCache[specId]    = merged or false
    trackListCacheKey[specId] = assign
    return merged or base
end
BF.GetTrackListForSpec = GetTrackList  -- exposed for Auras.lua whitelisted-spec check

function BF.GetSpecRaidBuffIDs(specId)
    return specId and BF.SPEC_RAID_BUFF_IDS[specId]
end

function BF.GetClassRaidBuffIDs()
    local playerClass = UnitClassBase and UnitClassBase("player")
    return playerClass and BF.CLASS_RAID_BUFF[playerClass]
end

-- Returns the spell ID to pass to GetUnitAuraBySpellID for the given unit,
-- based on the player's class raid buff. Handles Evoker's per-class variants.
-- Returns nil if the player class has no raid buff or the unit class is unknown.
function BF.GetRaidBuffLookupID(unit)
    local playerClass = UnitClassBase and UnitClassBase("player")
    local classBuff   = playerClass and BF.CLASS_RAID_BUFF[playerClass]
    if not classBuff then return nil end
    if type(classBuff) == "number" then
        return classBuff
    else
        -- Evoker: return the variant that applies to this unit's class.
        -- 12.1: UnitClassBase returns a secret for identity-secret units —
        -- a secret cannot be truth-tested or used as a table key, so bail
        -- (no raid-buff lookup for that unit).
        local unitClass = UnitClassBase and UnitClassBase(unit)
        if unitClass == nil or issecretvalue(unitClass) then return nil end
        return BF.EVOKER_BUFF_BY_CLASS[unitClass]
    end
end

-- ============================================================
-- AURA FILTER HELPERS
--
-- Long-term auras (raid buffs, sated, deserter, skyriding) are always hidden
-- in combat (they're noise during a fight) and shown out of combat only when
-- the corresponding setting is enabled.
-- spellId is only compared after canaccessvalue() confirms it's readable.
-- ============================================================
local function ShouldFilterBuff(sid, p)
    if not sid or not canaccessvalue(sid) then return false end
    local specBuffs = BF.playerSpecID and BF.SPEC_RAID_BUFF_IDS[BF.playerSpecID]
    if not specBuffs or not specBuffs[sid] then return false end
    -- This is a spec-specific raid buff: hide in combat always, hide out of combat if setting is off
    if InCombatLockdown() then return true end
    local _acp = BF.acDB and BF.acDB.profile; return not (_acp and _acp.showRaidBuffs)
end
BF.ShouldFilterBuff = ShouldFilterBuff  -- exposed for Auras.lua

local function ShouldFilterDebuff(sid, p)
    if not sid or not canaccessvalue(sid) then return false end
    -- Long-term debuffs: hide in combat always, hide out of combat if setting is off
    if BF.SATED_SPELL_IDS[sid] then
        if InCombatLockdown() then return true end
        local _acp = BF.acDB and BF.acDB.profile; return not (_acp and _acp.showSatedDebuffs)
    end
    if BF.DESERTER_SPELL_IDS[sid] then
        if InCombatLockdown() then return true end
        local _acp = BF.acDB and BF.acDB.profile; return not (_acp and _acp.showDeserterDebuffs)
    end
    if BF.SKYRIDING_SPELL_IDS[sid] then
        if InCombatLockdown() then return true end
        local _acp = BF.acDB and BF.acDB.profile; return not (_acp and _acp.showSkyridingDebuffs)
    end
    if BF.ARCANE_EMPOWERMENT_SPELL_IDS[sid] then
        if InCombatLockdown() then return true end
        local _acp = BF.acDB and BF.acDB.profile; return not (_acp and _acp.showArcaneEmpowermentDebuffs)
    end
    if BF.TIME_TRIAL_SPELL_IDS[sid] then
        if InCombatLockdown() then return true end
        local _acp = BF.acDB and BF.acDB.profile; return not (_acp and _acp.showTimeTrialDebuffs)
    end
    return false
end

-- Expose for Statuses/Auras.lua (Debuffs:GetIcons)
BF.ShouldFilterDebuff = ShouldFilterDebuff

-- ============================================================
-- AURA MATCH CACHE
--
-- Built in UNIT_AURA (clean context) where spellId is a plain number.
-- Produces ready-to-display ordered aura lists for buffFrames and each
-- custom container, keyed by unit. Readers take these lists directly using
-- only auraInstanceID — never spellId.
--
-- BF.auraMatchCache[unit] = {
--   buffFrames        = { aura, aura, ... },   -- tracked, not claimed
--   containers        = { [ci] = { aura, ... }, ... },  -- per container index
--   allTracked        = { aura, aura, ... },   -- all tracked (for health colors)
--   allHelpful        = { aura, aura, ... },   -- all HELPFUL (for untracked color)
--   debuffFrames      = { aura, aura, ... },   -- HARMFUL (all debuffs)
--   dispelDebuffFrames = { aura, aura, ... },  -- HARMFUL|RAID_PLAYER_DISPELLABLE
-- }
-- ============================================================
BF.auraMatchCache = BF.auraMatchCache or {}
-- Keep old name as alias so Auras.lua Path A still compiles during transition
BF.trackedInstanceIDCache = BF.auraMatchCache  -- legacy alias, unused now

-- Reusable scratch table for spellId->containerIndex mapping.
-- Rebuilt by EnsureFetchBuffSettings when settings change.
local spellToContainer = {}

-- ============================================================
-- CACHED SETTINGS FOR THE CONTAINER CONFIG BUILD
-- These are derived from profile + spec and don't change between units.
-- Rebuilt on InvalidateClaimedSpellCache (spec change, settings change).
--
-- v67: the fields that existed only to feed the deleted per-unit scan
-- (BF:FetchBuffData) were removed with it: _fbsClaimed, _fbsUseRaid,
-- _fbsHasOrdering, the secret-detection set (_fbsHasSecretDet /
-- _fbsSentinelID / _fbsSecretAllowSelf / _fbsSecretNeedsRaidScan and the
-- RAID_IN_COMBAT quartet _fbsSentinelRIC_ID / _fbsSecretRICNeedsScan /
-- _fbsSecretRICAllowSelf / _fbsSentinelRICAliases), the per-spec display
-- sub-tables (_fbsSpellBorderColors / _fbsSpellSolidIcons / _fbsSpellIconType
-- and the BuffMatch trio _fbsBmSpellColors / _fbsBmSpellBorders /
-- _fbsBmSpellOverlays), the legacy single-buff routing tables
-- (_fbsSingleRoutes / _fbsHasSingleRoutes / _fbsSingleInline /
-- _fbsHasSingleInline), and _fbsNoGeneral. Every one of them was write-only
-- once that function was gone. (v70: the container-claim pass no longer
-- consults sentinel tables — the secret-detection machinery is deleted and
-- its spells sit in the trackList like every other curated spell.)
-- ============================================================
local _fbsValid        = false  -- true when cache is current
local _fbsTrackList    = nil    -- GetTrackList(specId) result
-- v79: _fbsFilterMode / _fbsAuraFilter DELETED. They resolved the retired
-- Filter Mode dropdowns into a filter string for the `buffs` container's main
-- group. main is now the WHITELIST BUCKET (permissive filter + includeSpellIDs
-- -- see Docs/Buffs_Row_Architecture.md §2) and the preset group takes its
-- filter straight from BUFFS_PRESETS[pkey].filter, so the whole chain had no
-- consumer left. Do not reintroduce: the preset key IS the filter source.
-- v45: current-spec hidden spells (Display Type = Hide): explicit
-- "untracked" assignment, or a default-untracked SPEC_SPELLS entry never
-- promoted. The CONTAINER path excludes these from the general buff
-- group (the legacy engine hides them via the claimed set).
local _fbsHiddenSpells      = {}
-- v45: settings generation. Bumped on every _fbs rebuild; consumers
-- (ApplyBuffFilters) use it to force the engine's UpdateAllAuras rebuild
-- exactly once per settings change after re-applying candidate filters
-- (option setters don't re-evaluate existing aura assignments).
local _fbsGeneration        = 0
-- True iff at least one spell in the current spec's trackList is assigned
-- to a custom container (via spellToContainer). When false, no buff on any
-- unit can ever route to any container for this spec, so the unified
-- BuffsAndContainers indicator can skip every container group's runtime
-- work (Perf). Rebuilt alongside spellToContainer in EnsureFetchBuffSettings;
-- invalidated by InvalidateFetchBuffSettings (called from
-- InvalidateClaimedSpellCache on spec change, talent change, spellAssign
-- edit, container edit).
local _fbsHasActiveContainerSpells = false

-- Per-container parallel of _fbsHasActiveContainerSpells: keyed by ci,
-- true iff that container has at least one current-spec spell assigned.
-- Used by BF:GetActiveAuraGroups to omit containers with no current-spec
-- spells from frame._bf_activeGroups entirely.
local _fbsContainersWithSpecSpells = {}

-- v62 SINGLE BUFFS (plan 3.67): a single buff carries its own spell on the
-- container (c.singleBuffSpellID) and does NOT participate in spellAssign /
-- selectedSpells / spellToContainer, so its spell set needs a source of its
-- own. Both tables are rebuilt by EnsureFetchBuffSettings and hold ONLY single
-- buffs whose Spec condition passes for the current spec, so every consumer
-- gets the spec gate for free from a settings-time table. That holds for all
-- THREE of them, including the hidden set -- see the spec check on the hidden
-- write below, which exists to keep it true.
--
--   _fbsSingleBuffSpell[ci]  = spellID   -- per-container include set
--   _fbsSingleBuffHeld[sid]  = true      -- "at least one single buff shows it"
--   _fbsSingleBuffHidden[sid] = true     -- Display Type = Hide
--
-- _fbsSingleBuffHeld is deliberately NOT the reverse map: two single buffs may
-- hold the SAME spellID (owner requirement; two AuraContainers whitelisting one
-- spellID populate independently on 12.1), so a sid -> ci map would be the same
-- 1:1 trap spellToContainer is.
--
-- _fbsSingleBuffHidden is a SEPARATE set from _fbsHiddenSpells, not a reuse of
-- it. That one is also read at the per-spell customization and frame-effect
-- sites below, so folding single-buff hides into it would silently kill a
-- curated spell's per-spell effects whenever some unrelated single buff for the
-- same spellID happened to be hidden.
local _fbsSingleBuffSpell  = {}
local _fbsSingleBuffHeld   = {}
local _fbsSingleBuffHidden = {}

-- Per-container per-spec cooldown-text override flag: keyed by ci, true
-- iff the container has at least one spell with per-spell cooldown-text
-- overrides configured for the current spec. Used by GetContainerGroupConfig
-- to set perSpellOverrides = "spec" or false (skip ResolveSpellCooldownText
-- in the render loop when no overrides exist).
local _fbsContainerHasSpecOverrides = {}

-- Returns the current group type key for the main frames context.
-- Used by GetClaimedSpells and EnsureFetchBuffSettings to determine
-- which containers should be skipped (hidden + showInRegularBuffs).
local function GetCurrentContainerGroupTypeKey()
    local rpp = BF.rpDB and BF.rpDB.profile
    local lp = rpp and rpp.layouts
    if not lp or not lp.instanceLayoutAssignment then return "flat_party" end
    local flatID = BF:ResolveActiveFlat(BF:GetActiveSlot())
    if not flatID or flatID == "none" then return "flat_party" end
    return flatID
end

-- v65: THE per-Layout predicate for custom aura containers. Every reader of
-- container.groupSettings routes its gate through here so they cannot drift
-- apart -- runtime geometry, runtime visibility, the claimed-spell skip, the
-- groupConfig anchor, and the options editing source.
--
-- ── THE TWO-GATE MODEL ────────────────────────────────────────────────────
-- Two independent dimensions, either of which switches the per-Layout tier on:
--
--   1. LAYOUT axis  -- the CONTAINER's own c.perLayoutConfig flag. True means
--      "this container keeps a separate copy of its settings per scope",
--      whatever page is looking at it. Tri-state on purpose (true / explicit
--      false / nil == never seeded); reads treat false and nil identically.
--   2. GROUP axis   -- a Custom Frame Group's own per-subtab override flag
--      (BF.AURAS_GROUP_CFG_FLAG[<group>]), a property of the GROUP, not of the
--      container. It only ever applies to a CFG scope key.
--
-- Either ON => true. They are NOT redundant: with the container flag OFF a CFG
-- override still gives that one group its own container settings while every
-- Layout keeps sharing the container top level -- "one shared definition across
-- all my Layouts, overridden on this one Custom Frame Group", which a single
-- flag cannot express. Conversely the container flag answers for BOTH scope
-- kinds, which is what lets a raid/party key skip the group scan entirely.
--
-- STORAGE IS UNCHANGED -- container.groupSettings[<scope key>] is still the
-- per-scope override table, still sparse, still falling back field-by-field to
-- the container top level. Only the gate moved.
--
-- The container flag is tested FIRST, before the namespace test, because it is
-- one field read and it short-circuits the CFG scan in the common case.
--
-- Classification: a scope key is a flat ID from ONE key space (see
-- BF:ResolveGroupTypeKey). Raid/party flat IDs are the "flat_*" namespace
-- (Options_Layouts.lua newFlatID, plus the seeded flat_party / flat_raidNN);
-- CFG flat IDs are the disjoint "cfg_flat_*" namespace (newCFGFlatID in
-- Options_CustomFrames.lua). The namespace test therefore settles which axis
-- is left to consult, and only CFG keys pay for the scan over a handful of
-- groups. A cached answer would need invalidating on three independent inputs
-- (every container's flag, each group's flag, and the group list itself) for no
-- measurable gain on a settings-time path.
--
-- A key in the CFG namespace that no live group owns belongs to a deleted
-- group: there is no flag to consult, so the answer is "no per-Layout tier",
-- which collapses the read to the shared container top level.
-- InvalidateContainerSettingsCacheCFGOnly classifies the same way, via the
-- same BF:ResolveCFGGroupByFlatID scan.
--
-- c: the container record itself (required -- the Layout axis lives on it).
-- subcat (optional, default "buffs"): pass "debuffs" for custom debuff
-- containers so the GROUP axis follows the Debuffs override flag (Buffs and
-- Debuffs override independently). Resolved through AURAS_SUBCAT_GROUP +
-- AURAS_GROUP_CFG_FLAG rather than a local subcat->group ternary, so this is
-- not a third independent copy of that map.
function BF:IsContainerPerLayoutActive(groupTypeKey, c, subcat)
    if type(groupTypeKey) ~= "string" then return false end
    if type(c) ~= "table" then return false end
    -- Container's own flag first: it answers for BOTH scope kinds and lets a
    -- CFG key skip the group scan below in the common case.
    if c.perLayoutConfig == true then return true end
    if groupTypeKey:find("^flat_") then return false end
    local grp = self.ResolveCFGGroupByFlatID
        and self:ResolveCFGGroupByFlatID(groupTypeKey)
    if not grp then return false end
    local grpKey = BF.AURAS_SUBCAT_GROUP[subcat or "buffs"] or "aurasBuffs"
    local flag   = BF.AURAS_GROUP_CFG_FLAG and BF.AURAS_GROUP_CFG_FLAG[grpKey]
    return (flag and grp[flag]) and true or false
end

-- Returns true if a container should be skipped for the current group type
-- (hidden with showInRegularBuffs enabled, so spells go to regular buffs).
local function ShouldSkipContainerForGroupType(c, groupTypeKey)
    -- v65: gated by the two-gate model -- this container's own perLayoutConfig
    -- flag, or (for a CFG scope) that group's Buffs override flag.
    -- No subcat argument on purpose: all three callers of this function iterate
    -- BF:GetActiveCustomBuffContainers() / GetCustomBuffContainers(), so every
    -- container that reaches it is a BUFF container and the "buffs" default is
    -- the right group axis. A debuff caller would have to pass "debuffs".
    if not c.groupSettings then return false end
    if not BF:IsContainerPerLayoutActive(groupTypeKey, c) then return false end
    local gs = c.groupSettings[groupTypeKey]
    if not gs then return false end
    -- v63: showInRegularBuffs is not consulted for single buffs. That toggle
    -- routes a container's ASSIGNED spells back to the regular row, and single
    -- buffs have no assignments -- so it was removed from their subtab. Reading
    -- it here anyway would strand any entry that happens to carry a stored
    -- `false` from before the removal: the container hides, the spell stays
    -- claimed, and the buff disappears with no widget left to bring it back.
    -- Disabled for this Layout means "fall through to the regular row", full
    -- stop.
    if c.singleBuff then return gs.showForGroupType == false end
    return gs.showForGroupType == false and gs.showInRegularBuffs == true
end

local function InvalidateFetchBuffSettings()
    _fbsValid = false
end

-- ============================================================
-- v43 MASTER CUSTOMIZE FLAG (specSpellCustomized[specId][sid] = true)
-- A spell's per-spell customizations (icon type / solid color / border
-- color / cooldown text / position / effects) are active ONLY when this
-- flag is set. On the 12.1 container path a flagged spell gets its own
-- dedicated aura group (flowing with the general buffs, ordered ahead of
-- them); unflagged spells stay in the main group and cost nothing.
-- Seeded once per profile: any spell with a pre-existing customization
-- entry is auto-flagged so no user loses settings.
-- ============================================================
local CUSTOMIZATION_TABLES = {
    "specSpellIconType", "specSpellSolidIcons", "specSpellBorderColors",
    "specSpellCooldownText", "specSpellOrdering",
    "specSpellExpirationGlow", "specSpellBounce",
    "specSpellColors", "specSpellBorders", "specSpellOverlays",
    "specSpellVisualAlert",  -- v49 Blizzard native visual alerts (retired v84)
    "specSpellIconEffect",   -- v84 Icon Effects (Stage 5 §9.9)
}
-- Seeding version 3: a spell counts as "previously customized" when it
-- has ANY per-spell entry at all — any record in any customization
-- table (including disabled ones), any explicit non-default assignment,
-- or membership in any container's selectedSpells set. Maximal by
-- owner decision: no pre-existing customization may end up hidden
-- behind an unchecked master toggle. Version bumps re-run the full
-- pass; flags are only ever ADDED (unchecking afterwards sticks until
-- the next version bump).
function BF:EnsureSpellCustomizedSeeded()
    local p = BF.acDB and BF.acDB.profile
    if not p or p.spellCustomizedSeeded == 3 then return end
    p.spellCustomizedSeeded = 3
    p.specSpellCustomized = p.specSpellCustomized or {}
    local function flag(specId, sid)
        local set = p.specSpellCustomized[specId]
        if not set then set = {}; p.specSpellCustomized[specId] = set end
        set[sid] = true
    end
    -- Any entry in any per-spell customization table.
    for _, tname in ipairs(CUSTOMIZATION_TABLES) do
        local t = p[tname]
        if type(t) == "table" then
            for specId, spells in pairs(t) do
                if type(spells) == "table" then
                    for sid, v in pairs(spells) do
                        if v ~= nil then
                            flag(specId, sid)
                        end
                    end
                end
            end
        end
    end
    -- Any explicit non-default assignment (container / untracked): the
    -- assignment UI is gated behind the master toggle, so an unflagged
    -- assigned spell would have an active but invisible assignment.
    if type(p.spellAssign) == "table" then
        for specId, assigns in pairs(p.spellAssign) do
            if type(assigns) == "table" then
                for sid, val in pairs(assigns) do
                    if val ~= nil and val ~= "default" then
                        flag(specId, sid)
                    end
                end
            end
        end
    end
    -- Belt: container-side selectedSpells sets (kept in sync with
    -- spellAssign, but seed from both in case they ever diverged).
    -- selectedSpells has no spec dimension — flag the spell for every
    -- spec whose SPEC_SPELLS list contains it.
    if type(p.customBuffContainers) == "table" and BF.SPEC_SPELLS then
        local sidToSpecs
        for _, c in ipairs(p.customBuffContainers) do
            if type(c.selectedSpells) == "table" and next(c.selectedSpells) then
                if not sidToSpecs then
                    sidToSpecs = {}
                    for specId, spells in pairs(BF.SPEC_SPELLS) do
                        for _, s in ipairs(spells) do
                            local list = sidToSpecs[s.id]
                            if not list then list = {}; sidToSpecs[s.id] = list end
                            list[#list + 1] = specId
                        end
                    end
                end
                for sid, on in pairs(c.selectedSpells) do
                    local specs = on and sidToSpecs[sid]
                    if specs then
                        for i = 1, #specs do
                            flag(specs[i], sid)
                        end
                    end
                end
            end
        end
    end
end
function BF.IsSpellCustomized(specId, sid)
    local p = BF.acDB and BF.acDB.profile
    local t = p and p.specSpellCustomized
    local s = t and t[specId]
    return (s and s[sid] == true) or false
end

-- v44: perRow / spacing / rowSpacing became PER-FIELD (nil = inherit
-- from the buff settings, independent of the size override toggle).
-- Containers that were INHERITING never used their stored defaults for
-- these three fields (buffsPerRow=3 / spacing=1 / rowSpacing=0 were
-- written at creation but ignored by ResolveLayoutSettings), so they are
-- safely nilled — the container keeps looking exactly the same and now
-- inherits per-field. Overriding containers keep their values.
function BF:MigrateContainerLayoutFields()
    local p = BF.acDB and BF.acDB.profile
    if not p or p.containerLayoutFieldsMigrated then return end
    p.containerLayoutFieldsMigrated = true
    local containers = p.customBuffContainers
    if type(containers) ~= "table" then return end
    local function scrub(t, inheriting)
        if inheriting then
            t.buffsPerRow = nil
            t.spacing     = nil
            t.rowSpacing  = nil
        end
    end
    for _, c in ipairs(containers) do
        local cInherit = c.containerUsesBuffSettings ~= false
        scrub(c, cInherit)
        if type(c.groupSettings) == "table" then
            for _, gs in pairs(c.groupSettings) do
                if type(gs) == "table" then
                    local gsUseBuff = gs.containerUsesBuffSettings
                    if gsUseBuff == nil then gsUseBuff = c.containerUsesBuffSettings end
                    scrub(gs, gsUseBuff ~= false)
                end
            end
        end
    end
end

-- (v49 note: BF renders its Visual Alerts itself via animation groups
-- on the container buttons — see ContainerFactory ApplyVisualAlert. An
-- earlier revision also pushed C_UnitAuras.SetGroupBuffVisualAlerts,
-- but that registry is SHARED with Blizzard's edit-mode raid frame
-- settings and the push clobbered them; it has no effect on our own
-- rendering, so it was removed — BF and Blizzard settings stay fully
-- separate.)

local function EnsureFetchBuffSettings()
    if _fbsValid then return end
    _fbsValid = true
    _fbsGeneration = _fbsGeneration + 1
    BF:EnsureSpellCustomizedSeeded()
    BF:MigrateContainerLayoutFields()

    local specId    = BF.playerSpecID
    _fbsTrackList   = specId and GetTrackList(specId)
    -- v67: _fbsClaimed (BF:GetClaimedSpells()) removed -- its only reader was
    -- the deleted per-unit scan. GetClaimedSpells itself is still live; the
    -- container path expresses the same claim as cfg.generalExclude.

    -- Rebuild spellToContainer from containers.
    -- v65: when the per-Layout tier is active for this container + the current
    -- scope (see BF:IsContainerPerLayoutActive -- the container's own
    -- perLayoutConfig flag, or the group's override flag on a CFG scope) and
    -- the container is hidden for it with
    -- showInRegularBuffs enabled, skip its spells so they fall through to the
    -- regular buff display.
    table.wipe(spellToContainer)
    table.wipe(_fbsContainersWithSpecSpells)
    table.wipe(_fbsContainerHasSpecOverrides)
    -- v62: single buffs source their spell from the container, not from here.
    table.wipe(_fbsSingleBuffSpell)
    table.wipe(_fbsSingleBuffHeld)
    table.wipe(_fbsSingleBuffHidden)
    local containers = BF:GetActiveCustomBuffContainers() or {}
    local currentGroupTypeKey = GetCurrentContainerGroupTypeKey()
    -- Pre-fetch per-spec cooldown-text override table for the per-container
    -- override flag below. Reads from acDB.profile.specSpellCooldownText[specId].
    local _acp = BF.acDB and BF.acDB.profile
    local _specCT = _acp and _acp.specSpellCooldownText and _acp.specSpellCooldownText[specId]
    -- v64 OWNER CORRECTION: "Show (Default Buff)" does NOT mean "leave the
    -- container and go back to the regular buff row" for a buff that lives in a
    -- container. The buff STAYS with its container, keeping that container's
    -- anchor and position, and Default only means "no per-buff customized
    -- settings, render from the container's own settings". That is already
    -- exactly what Display Type means for a Single Buff entry (containers plan
    -- §3.67 slice 2: singleBuffCustomized = false -> the visual subtabs hide and
    -- the icon renders from container settings only), so the two agree.
    --
    -- A container-assigned spell therefore ALWAYS routes to its container; the
    -- master customize flag is purely a visual switch. That is also what puts an
    -- ORDERED-but-not-customized spell's per-spell group in the right place: the
    -- promotion block in GetContainerBuffConfig reads spellToContainer[sid] and
    -- falls back to key "buffs" when it is nil, so a skipped spell would have
    -- grown its group in the GENERAL buffs flow instead of inside its container.
    --
    -- v67: 12.0.7 branch removed (addon is 12.1-only). The v45 flag-gated skip
    -- (build the current spec's spell-id set, then drop unflagged current-spec
    -- spells from spellToContainer) was 12.0.7-only; it is gone together with
    -- the _specSids / _custSet locals it needed and its test in the loop below.
    for ci, c in ipairs(containers) do
        -- v69: a globally disabled container (c.enabled == false, never set on
        -- single buffs) releases its spell claims — the spells fall back to the
        -- regular buff row exactly as if the container had been removed. This
        -- differs from the per-Layout hide (which keeps the claim so the spell
        -- vanishes unless showInRegularBuffs opts it back in) on purpose:
        -- Enabled is a global "this container does not exist right now".
        if c.enabled ~= false
            and not ShouldSkipContainerForGroupType(c, currentGroupTypeKey)
            and c.selectedSpells then
            local hasSpecSpell = false
            local hasSpecOverride = false
            -- v70: no sentinel special cases — the former secret-detection
            -- spells sit in the trackList like every other curated spell
            -- now, so the plain trackList test covers them.
            for spellId, on in pairs(c.selectedSpells) do
                if on and type(spellId) == "number" then
                    spellToContainer[spellId] = ci
                    if _fbsTrackList and _fbsTrackList[spellId] then
                        hasSpecSpell = true
                    end
                    if _specCT and _specCT[spellId] then
                        hasSpecOverride = true
                    end
                end
            end
            if hasSpecSpell then
                _fbsContainersWithSpecSpells[ci] = true
            end
            if hasSpecOverride then
                _fbsContainerHasSpecOverrides[ci] = true
            end
        end
    end

    -- ── v62 SINGLE BUFFS (plan 3.67) ────────────────────────────────────────
    -- Second, separate pass rather than a branch inside the loop above: the two
    -- kinds have nothing in common on this path. A single buff's spell comes
    -- from the container (c.singleBuffSpellID), its spec gate is its own Spec
    -- condition (BF:IsSingleBuffSpecMet) instead of "is this spell in the
    -- current spec's trackList", and it never touches spellToContainer -- so it
    -- shares none of the flag-gated / sentinel / trackList logic above.
    --
    -- NO trackList test on purpose. A curated spell only routes to a MULTI
    -- container while its master customize flag is set, and only spec spells
    -- can be assigned at all; a single buff accepts any spell ID the user typed
    -- and its Spec condition is the only gate it has.
    for ci, c in ipairs(containers) do
        if not ShouldSkipContainerForGroupType(c, currentGroupTypeKey) then
            local sbSid = BF:GetSingleBuffSpellID(c)
            -- v62 (plan 3.67 slice 2): Display Type = Hide. Gated HERE, in the
            -- settings-time pass, so the entry contributes no include-set spell
            -- rather than being rendered empty.
            --
            -- It must STILL claim the spell out of the general buff row.
            -- Dropping the claim as well (the original behavior) meant Hide
            -- did not hide anything: nothing added the spell to
            -- cfg.generalExclude and the icon simply reappeared in the regular
            -- buff display. _fbsSingleBuffHidden is what GetContainerBuffConfig
            -- reads to add that exclude.
            --
            -- The Spec condition is checked HERE TOO, not just on the shown
            -- path below. A hidden entry whose Spec condition excludes the
            -- current spec is inert on that spec -- claiming its spell out of
            -- the regular row anyway would hide a buff on a spec the user
            -- explicitly told the entry to stay out of, break the
            -- "spec-gated for free" invariant these tables document, and put
            -- the 12.1 path back out of step with the legacy one (whose
            -- GetClaimedSpells is spec-gated).
            if sbSid and c.singleBuffHidden then
                if BF:IsSingleBuffSpecMet(c) then
                    _fbsSingleBuffHidden[sbSid] = true
                end
                sbSid = nil
            end
            if sbSid and BF:IsSingleBuffSpecMet(c) then
                _fbsSingleBuffSpell[ci] = sbSid
                -- v65: STAYS SET for a Buffs-anchored entry, and it is load-
                -- bearing there. GetContainerBuffConfig reads it as
                -- `elseif _fbsSingleBuffHeld[sid] then eligible = false` when
                -- deciding whether a spell also earns an "sp<sid>" group. A
                -- Buffs-anchored entry mirrors its Order into specSpellOrdering,
                -- and an Order is exactly what promotes a spell -- so without
                -- this the same spell would get BOTH an sp<sid> group and its
                -- sb<key> group: two icons for one aura.
                _fbsSingleBuffHeld[sbSid] = true

                -- v65: a Buffs-anchored entry has no container of its own, so it
                -- does not get a container group -- its aura is served by the
                -- sb<key> group inside the general buffs container instead
                -- (ApplySingleBuffGroups).
                --
                -- v67: the legacy routing half of this branch (_fbsSingleRoutes /
                -- _fbsSingleInline, both read only by the deleted per-unit scan)
                -- is gone; what is left is the anchored/not-anchored gate on the
                -- container group, so the test is inverted rather than split.
                --
                -- v92: ANY flow host, not just Buffs. A bigDef- or
                -- container-anchored entry has no container of its own either --
                -- its aura is served by the sb<key> group inside that host -- so
                -- claiming a container group for it would both render a second
                -- icon and, through _fbsHasActiveContainerSpells, keep the whole
                -- container-group path awake for a spec that needs none of it.
                if BF:GetSingleBuffAnchorHost(c, currentGroupTypeKey) == nil then
                    -- Feeds BF:ContainerHasSpecSpells, i.e. whether
                    -- BF:GetActiveAuraGroups renders this container's group at all.
                    _fbsContainersWithSpecSpells[ci] = true
                end
                if _specCT and _specCT[sbSid] then
                    _fbsContainerHasSpecOverrides[ci] = true
                end
            end
        end
    end

    -- Compute _fbsHasActiveContainerSpells: does any spell in this spec's
    -- trackList route to a container? If not, no UNIT_AURA on any unit
    -- can ever produce a container match for this spec. The unified
    -- BuffsAndContainers indicator uses this to skip every container
    -- group in the common case of "no containers configured for this
    -- spec".
    --
    -- Derived from _fbsContainersWithSpecSpells which was populated
    -- alongside spellToContainer in the loop above. True iff any
    -- container has at least one current-spec spell assigned.
    _fbsHasActiveContainerSpells = next(_fbsContainersWithSpecSpells) ~= nil

    -- v45: rebuild the hidden-spell set for the current spec (Display
    -- Type = Hide semantics — mirrors getAssignedContainerForSpell's
    -- "untracked" resolution incl. default-untracked promotion).
    table.wipe(_fbsHiddenSpells)
    if specId and BF.SPEC_SPELLS and BF.SPEC_SPELLS[specId] then
        local assign = _acp and _acp.spellAssign and _acp.spellAssign[specId]
        for _, s in ipairs(BF.SPEC_SPELLS[specId]) do
            local a = assign and assign[s.id]
            if a == "untracked" or (s.untracked and a == nil) then
                _fbsHiddenSpells[s.id] = true
            end
        end
    end

    -- v79: the filter-mode resolution + filter-string pre-build that lived here
    -- is DELETED (see the note at the _fbsAuraFilter declaration). It read
    -- BF:ResolveBuffsPreset() into _fbsFilterMode and mapped that to a token
    -- string; both outputs are now unconsumed. The preset itself is still
    -- resolved -- by ApplyPresetGroups, at Layout time, from the same accessor.

    -- v67: three settings-time blocks removed here (12.1-only; all three
    -- produced values read ONLY by the deleted per-unit scan BF:FetchBuffData):
    --   * secret detection (_fbsHasSecretDet / _fbsSentinelID /
    --     _fbsSecretAllowSelf / _fbsSecretNeedsRaidScan) and the RAID_IN_COMBAT
    --     sentinel resolution (_fbsSentinelRIC_ID / _fbsSecretRICNeedsScan /
    --     _fbsSecretRICAllowSelf / _fbsSentinelRICAliases). The 12.1 engine
    --     DISPLAYS secret auras that match a container filter, so no
    --     sentinel/elimination machinery is needed. (v70 finished the job:
    --     the sentinel LOOKUP tables and the container-claim pass's reads of
    --     them are gone too — the former secret-detection spells are plain
    --     trackList rows now.)
    --   * _fbsHasOrdering ("any custom ordering configured"), which gated the
    --     legacy ApplyCustomOrdering pass. 12.1 ordering is expressed as
    --     per-spell groups -- see the _custPromote block in
    --     GetContainerBuffConfig, which reads specSpellOrdering itself.
    --   * the per-spec display sub-tables built by the filteredSub helper
    --     (_fbsSpellBorderColors / _fbsSpellSolidIcons / _fbsSpellIconType and
    --     the BuffMatch trio _fbsBmSpellColors / _fbsBmSpellBorders /
    --     _fbsBmSpellOverlays), which only ever fed
    --     BF:PreResolveAuraDisplayArrays.
    -- The custSet / p2 locals they needed went with them.
end

-- ============================================================
-- 12.1 CONTAINER PATH: expose the buff-routing configuration derived
-- from the _fbs settings cache. Consumed by
-- Indicators/BuffsAndContainers.lua to build container filters and
-- candidateFilters. The returned table is REUSED across calls — the
-- container engine securecopies candidateFilters on Set, so passing the
-- shared tables is safe; callers must not retain them.
--
-- Routing model:
--   * general group: mode filter + category negations. (v67: the
--     whitelist-mode include set is gone with that filter mode; the
--     general group carries no includeSpellIDs at all now.)
--   * container-claimed spells: excludeSpellIDs on the general group
--     (helpful-on-friendly spellID filters are permitted).
--   * per-container include sets from spellToContainer.
-- ============================================================
-- Helper: resolve ordering entry to a slot number.
-- Supports both legacy plain-number format and new {slot=N} table format.
-- Returns nil if the entry is disabled or absent.
--
-- v64: hoisted here from below ApplyCustomOrdering. It is now also the
-- "does this spell have an Order" predicate that drives per-spell group
-- promotion on 12.1 (GetContainerBuffConfig below), so the 12.0.7 pin
-- semantics and the 12.1 promotion rule cannot drift apart. In particular
-- `enabled == false` -- a pin the user explicitly switched OFF under the old
-- pin toggle -- still means "no Order", so those spells are NOT promoted.
local function resolveSlot(entry)
    if not entry then return nil end
    if type(entry) == "number" then return entry end  -- legacy format
    if type(entry) == "table" then
        if entry.enabled == false then return nil end
        return entry.slot
    end
    return nil
end

-- v64: scratch promotion set for the 12.1 Order-driven path below. Rebuilt in
-- place per config build, like the other _cbc scratch tables -- never retained.
local _custPromote = {}

-- v92 (Perf): GetContainerBuffConfig memo. The body below re-derives the
-- exclude/include/customized/frameFx sets from acDB on every call, but every
-- input it reads is invalidated through InvalidateClaimedSpellCache ->
-- InvalidateFetchBuffSettings (options refreshes, spec/talent changes,
-- profile swaps), which forces the next EnsureFetchBuffSettings to bump
-- _fbsGeneration. A built config is therefore valid exactly as long as the
-- generation doesn't move. BuffsAndContainers calls this twice per frame per
-- Layout, so a full-roster Layout pass paid the whole rebuild ~2x40 times
-- for a single generation; now only the first call per generation builds.
local _cbcBuiltGen = nil

local _cbc = {
    -- v67: `whitelistInclude` scratch set removed with the whitelist filter mode.
    generalExclude = {}, containerSpells = {},
    -- v43 per-spell customized routing: customized.buffs / customized[ci]
    -- = arrays of pooled { sid, slot, name } entries, sorted by
    -- (slot asc, name asc, sid asc). Consumed by BuffsAndContainers to
    -- build the per-spell aura groups.
    customized = {}, _custEntryPool = {},
    -- v46 per-spell frame effects: frameFx[sid] = pooled { hc?, bd?, ov? }
    -- (health color / frame border / overlay entries). Consumed by
    -- BuffsAndContainers' slot visuals.
    frameFx = {}, _fxPool = {},
}
local function CustomizedSortLess(a, b)
    if a.slot ~= b.slot then return a.slot < b.slot end
    if a.name ~= b.name then return a.name < b.name end
    return a.sid < b.sid
end
function BF:GetContainerBuffConfig()
    EnsureFetchBuffSettings()
    local cfg = _cbc
    cfg.generation = _fbsGeneration
    if _cbcBuiltGen == _fbsGeneration then return cfg end
    -- v79: cfg.filter / cfg.filterMode DELETED -- zero live readers. The
    -- |!BIG_DEFENSIVE|!EXTERNAL_DEFENSIVE negations they carried now live at
    -- the two sites that actually need them (the `main` group's permissive
    -- filter and the per-spell group filter, both in BuffsAndContainers.lua).

    -- v67: the whitelist include set (trackList + secret-detection sentinels /
    -- aliases, plus the broad "HELPFUL|..." filter it paired with) removed
    -- (12.1-only). It was gated on _fbsFilterMode == "whitelist", and that mode
    -- can no longer be resolved -- see the preset note in EnsureFetchBuffSettings.
    -- cfg.includeSpellIDs is therefore never populated here; the per-spell and
    -- per-container groups build their own include sets in BuffsAndContainers.

    -- Exclude container-claimed spells from the general group; build the
    -- per-container include sets.
    table.wipe(cfg.generalExclude)
    for ci in pairs(cfg.containerSpells) do
        table.wipe(cfg.containerSpells[ci])
    end
    local haveExclude = false
    for spellId, ci in pairs(spellToContainer) do
        cfg.generalExclude[spellId] = true
        haveExclude = true
        -- v67: the paired "also drop the sid from cfg.includeSpellIDs" belt was
        -- removed with the whitelist include set (v62 FIX: PTR-observed that
        -- include membership beats excludeSpellIDs on the engine side, so a sid
        -- in both kept displaying). The exclude alone is now the whole claim --
        -- it is what always covered the non-whitelist modes, where there was no
        -- include set to remove from. If a general-group include set is ever
        -- reintroduced, this site and the three below need the belt back.
        local set = cfg.containerSpells[ci]
        if not set then set = {}; cfg.containerSpells[ci] = set end
        set[spellId] = true
    end
    -- v62 SINGLE BUFFS (plan 3.67): their include set comes from the
    -- container's own spell, NOT from spellToContainer -- that map is 1:1, and
    -- two single buffs are allowed to hold the same spellID. Building each one
    -- independently is what lets both populate (owner-confirmed: two
    -- AuraContainers whitelisting one spellID do fill independently, so nothing
    -- here needs to de-duplicate).
    --
    -- The spell is also excluded from the general buffs group: a single buff
    -- CLAIMS its spell out of the regular display, exactly as a container
    -- assignment used to. Only single buffs whose Spec condition passes are in
    -- _fbsSingleBuffSpell, so the claim lifts automatically on a spec the
    -- condition excludes.
    for ci, sid in pairs(_fbsSingleBuffSpell) do
        cfg.generalExclude[sid] = true
        haveExclude = true
        local set = cfg.containerSpells[ci]
        if not set then set = {}; cfg.containerSpells[ci] = set end
        set[sid] = true
    end
    -- v45: hidden spells (Display Type = Hide) are excluded from the
    -- general group in EVERY filter mode (covers non-whitelist modes,
    -- where the mode filter would otherwise show them).
    for sid in pairs(_fbsHiddenSpells) do
        cfg.generalExclude[sid] = true
        haveExclude = true
    end
    -- Single buffs set to Display Type = Hide. Like the _fbsSingleBuffSpell loop
    -- above it excludes the spell from the general group, minus the
    -- containerSpells entry -- the point is that nothing renders it at all.
    for sid in pairs(_fbsSingleBuffHidden) do
        cfg.generalExclude[sid] = true
        haveExclude = true
    end

    -- ── v43: route master-flagged (customized) spells to dedicated
    -- per-spell groups. Each is REMOVED from its home group's include
    -- set / excluded from the general group (its own group displays it),
    -- and listed in cfg.customized under its home container key
    -- ("buffs" for the general group, ci for custom containers), sorted
    -- by (Position slot, spell name, spellID). In whitelist mode a
    -- flagged spell must be tracked or container-assigned to display —
    -- untracked flagged spells get no group.
    for key, list in pairs(cfg.customized) do
        for i = #list, 1, -1 do list[i] = nil end
    end
    local specId2 = BF.playerSpecID
    local acP = BF.acDB and BF.acDB.profile
    -- v62 OWNER DECISION (PARTIALLY REVERSED in v64 -- read both halves):
    -- v62 scoped the Aura Customizations per-spell settings to 12.0.7 ONLY, so
    -- no curated per-spell groups were built on the container path at all.
    --
    -- v64 splits that decision in two, because it conflated two separate
    -- things:
    --   * per-spell VISUALS (icon type, colors, cooldown text, effects) --
    --     still 12.0.7 only. The choke point is IsCust() in
    --     AuraCustomizationHelpers.lua, which still returns false on 12.1, so
    --     DeriveSpellButtonSpec layers no overrides and a promoted spell
    --     renders as a plain buff button. Un-gating that is the future
    --     "group type" dropdown.
    --   * per-spell ORDER -- now live on BOTH engines. layoutIndex orders
    --     GROUPS, not auras within a group, and none of the nine
    --     AuraContainerSortMethod comparators takes a user-supplied rank
    --     (AuraContainer_API_Reference_12.1.md:57-60, :172-174). So "buff 1 is
    --     always to the right of buff 2" is only expressible as one group per
    --     spell -- which is exactly what this block builds.
    --
    -- Promotion rule: an ORDER promotes, and nothing else. A spell with no
    -- Order flows in its container's main group under the engine's Default
    -- sort and costs no group at all.
    --
    -- MIGRATION: none needed, and none should be added. Order reads the same
    -- acP.specSpellOrdering[specId][sid] the 12.0.7 Position always wrote, so a
    -- Position set on 12.0.7 IS an Order on 12.1. resolveSlot honors the
    -- legacy `enabled == false` (pin explicitly switched off), so those spells
    -- correctly do NOT promote.
    --
    -- The routing half of AC storage (spellAssign / trackList / untracked /
    -- hidden) stays live on both engines regardless.
    local ordering = acP and specId2 and acP.specSpellOrdering
        and acP.specSpellOrdering[specId2] or nil
    -- v67: 12.0.7 branch removed (addon is 12.1-only). An ORDER promotes, and
    -- nothing else; the 12.0.7 master-customize-flag promotion set
    -- (acP.specSpellCustomized[specId2]) is gone.
    --
    -- Rebuilt in place; `nil` when nothing is ordered so the whole block
    -- is skipped and no container pays for the feature (cf. Grid2, which
    -- registers a condition's machinery only when something uses it).
    local custSet
    table.wipe(_custPromote)
    if ordering then
        for sid, e in pairs(ordering) do
            if resolveSlot(e) then _custPromote[sid] = true end
        end
    end
    custSet = next(_custPromote) and _custPromote or nil
    if custSet then
        for sid, flagged in pairs(custSet) do
            -- v65: _fbsSingleBuffHidden is a DIFFERENT set from _fbsHiddenSpells
            -- (that one is AC "untracked"), and it has to be tested here too.
            -- A hidden entry has its sbSid nil'd before _fbsSingleBuffHeld is
            -- stamped, so the "a single buff already shows this" guard below
            -- never fires for it -- while the Order this entry mirrors into
            -- specSpellOrdering still promotes the spell on 12.1. Without this,
            -- setting an Order and then Display Type = Hide rebuilt the buff as
            -- an sp<sid> group: the user hid it and it came back.
            if flagged == true and not _fbsHiddenSpells[sid]
               and not _fbsSingleBuffHidden[sid] then
                local ci = spellToContainer[sid]
                local eligible
                if ci then
                    eligible = true
                    -- v67: the `elseif _fbsFilterMode == "whitelist"` arm below
                    -- (eligible only when the spell is in _fbsTrackList) was
                    -- removed with the whitelist filter mode -- it can no longer
                    -- be resolved, so every non-held spell now takes the plain
                    -- `else eligible = true` arm.
                elseif _fbsSingleBuffHeld[sid] then
                    -- v62: a single buff already displays this spell from its
                    -- own container group, and the spell is excluded from the
                    -- general group above. Without this branch a master-flagged
                    -- spell held ONLY by a single buff would fall through to
                    -- key "buffs" and grow a second, duplicate per-spell group
                    -- in the general buffs flow -- spellToContainer no longer
                    -- resolves it to the container that owns it.
                    eligible = false
                else
                    eligible = true
                end
                if eligible then
                    -- v64: one definition of "what slot is this" (resolveSlot),
                    -- shared with the promotion test above and the legacy pin
                    -- path. Default 1 covers the 12.0.7 case of a flagged spell
                    -- with no Order at all; on 12.1 promotion implies an Order,
                    -- so the fallback is unreachable there.
                    local slot = (ordering and resolveSlot(ordering[sid])) or 1
                    local e = cfg._custEntryPool[sid]
                    if not e then e = {}; cfg._custEntryPool[sid] = e end
                    e.sid  = sid
                    e.slot = slot
                    e.name = (C_Spell and C_Spell.GetSpellName
                              and C_Spell.GetSpellName(sid)) or tostring(sid)
                    local key = ci or "buffs"
                    local list = cfg.customized[key]
                    if not list then list = {}; cfg.customized[key] = list end
                    list[#list + 1] = e
                    -- Remove from the home group's own include set...
                    -- (v67: the `elseif cfg.includeSpellIDs` arm went with the
                    -- whitelist include set; the general group has none now.)
                    if ci then
                        local set = cfg.containerSpells[ci]
                        if set then set[sid] = nil end
                    end
                    -- ...and exclude from the general group (covers every
                    -- filter mode and engine dedup-precedence unknowns).
                    cfg.generalExclude[sid] = true
                    haveExclude = true
                end
            end
        end
        for _, list in pairs(cfg.customized) do
            if #list > 1 then table.sort(list, CustomizedSortLess) end
        end
    end

    -- v50 belt: keep the MAIN group from claiming the spec's raid-buff
    -- ids via container auto-dedup while the OOC raidbuffs group owns
    -- their display.
    if acP and acP.showRaidBuffs and specId2
       and BF.SPEC_RAID_BUFF_IDS and BF.SPEC_RAID_BUFF_IDS[specId2] then
        for sid in pairs(BF.SPEC_RAID_BUFF_IDS[specId2]) do
            cfg.generalExclude[sid] = true
            haveExclude = true
        end
    end

    cfg.excludeSpellIDs = haveExclude and cfg.generalExclude or nil

    -- ── v46: per-spell frame effects (health color / frame border /
    -- overlay). Consumed by BuffsAndContainers' slot visuals — engine-driven,
    -- zero combat Lua.
    --
    -- v62 OWNER DECISION: the curated (AC-section) frame-effect entries are
    -- 12.0.7-only. Frame effects come solely from the single-buff projection
    -- below (and the Swiftmendable feature, which is deliberately 12.1-only).
    --
    -- v67: 12.0.7 branch removed (addon is 12.1-only). The curated feed from
    -- the master-flag-filtered BuffMatch tables (_fbsBmSpellColors / Borders /
    -- Overlays) never ran here, so it and its `fxSource` helper are gone. Those
    -- tables are still built and are still read by the BuffMatch path below.
    for sid in pairs(cfg.frameFx) do cfg.frameFx[sid] = nil end

    -- ── v62 (plan 3.67 slice 2): single-buff Frame Effects ──────────────────
    -- The Frame Effects subtab on a single-buff tree entry writes to that
    -- ENTRY's own store, so it needs projecting into cfg.frameFx here -- the
    -- entry's spell is not in specSpell*[specId], which is what _fbsBm* is
    -- built from.
    --
    -- frameFx stays keyed by spellID and is NOT re-keyed per container, because
    -- these three effects (health tint, frame border, frame overlay) are
    -- properties of the FRAME, not of an icon: the unit has one health bar, so
    -- two entries of one spell cannot render two different tints regardless of
    -- what they store. When two same-spell entries both configure an effect the
    -- LOWER container index wins, which is the order this loop walks.
    --
    -- Settings-time, bounded by the number of single buffs; ApplySpellFx and
    -- every slot-visual restamp downstream are unchanged.
    if BF.GetSingleBuffVisualEntry then
        local sbContainers = BF:GetActiveCustomBuffContainers() or {}
        for ci, sid in pairs(_fbsSingleBuffSpell) do
            local c = sbContainers[ci]
            if c and not _fbsHiddenSpells[sid] then
                local hc = BF.GetSingleBuffVisualEntry(c, "specSpellColors",   sid)
                local bd = BF.GetSingleBuffVisualEntry(c, "specSpellBorders",  sid)
                local ov = BF.GetSingleBuffVisualEntry(c, "specSpellOverlays", sid)
                if hc and hc.enabled == false then hc = nil end
                if bd and bd.enabled == false then bd = nil end
                if ov and ov.enabled == false then ov = nil end
                if hc or bd or ov then
                    local e = cfg._fxPool[sid]
                    if not e then e = {}; cfg._fxPool[sid] = e end
                    if not cfg.frameFx[sid] then
                        e.hc, e.bd, e.ov = nil, nil, nil
                        -- Carry the WINNING entry's Applied By onto the fx
                        -- entry ("mine" | "notme" | "any"; lower container
                        -- index wins, same as the effects themselves).
                        -- ApplySpellFx maps it to the fx slot's filter string
                        -- so an effect obeys the same caster scope as its
                        -- entry's icon — the slots used to ship a bare
                        -- "HELPFUL" and lit up on ANYONE's cast of the spell
                        -- (e.g. another Priest's Atonement recoloring health
                        -- bars despite the entry saying Applied by Me Only).
                        e.scope = BF.GetContainerCasterScope
                            and BF.GetContainerCasterScope(c) or "mine"
                        cfg.frameFx[sid] = e
                    end
                    if hc and not e.hc then e.hc = hc end
                    if bd and not e.bd then e.bd = bd end
                    if ov and not e.ov then e.ov = ov end
                end
            end
        end
    end

    -- ── v53: Swiftmendable (Resto Druid) — frame effects + name recolor
    -- driven by the 4 swiftmendable HoT ids through the same slot-visual
    -- machinery. Entries reuse the per-spell shapes (hc/bd/ov) so the
    -- BuffsAndContainers restamps consume them unchanged.
    cfg.swiftmendFx   = nil
    cfg.swiftmendName = nil
    if specId2 == 105 and acP and not IsPlayerSpell(VERDANT_INFUSION) then
        local sm = acP.swiftmendFx
        if sm then
            local hc = sm.hc; if hc and hc.enabled == false then hc = nil end
            local bd = sm.bd; if bd and bd.enabled == false then bd = nil end
            local ov = sm.ov; if ov and ov.enabled == false then ov = nil end
            if hc or bd or ov then
                local e = cfg._smFxPool
                if not e then e = {}; cfg._smFxPool = e end
                e.hc, e.bd, e.ov = hc, bd, ov
                cfg.swiftmendFx = e
            end
        end
        if acP.swiftmendRecolorName then
            cfg.swiftmendName = acP.swiftmendNameColor or true
        end
    end

    _cbcBuiltGen = _fbsGeneration
    return cfg
end

-- Scratch result table for the per-unit buff scan (allocated once, reused).
-- Counter-based indexing instead of #table+1: each array has a corresponding
-- _n* count field, consumers iterate for i = 1, n* and never read past the
-- count. Stale entries beyond the count are harmless -- this eliminates
-- table.wipe calls on the hot arrays (valid range is 1..i).
--
-- v67 STATUS: the only writer, BF:FetchBuffData, was deleted with the 12.0.7
-- render path, so nothing populates this table any more and WipeBuffResult
-- below has no callers. It is left standing ONLY because two files this pass
-- does not own still reach it -- Statuses/Auras.lua (`return BF._buffResult`)
-- and Auras/RenderAuraGroup.lua (reads `buffData._groupData`) -- and both are
-- being reworked in parallel. When they are done, this table, WipeBuffResult,
-- ensureGroupSlot and BF:PreResolveAuraDisplayArrays should all go.
local _buffResult = {
    buffFrames       = {},
    nBuffFrames      = 0,
    generalBuffs     = {},
    nGeneralBuffs    = 0,
    nonWhitelistedBuffs = {},
    nNonWhitelisted  = 0,
    -- Pre-merged tracked + general buffs, already deduped against BigDef/
    -- Important (N4 optimization). Path A iterates this; Path B holds the
    -- deduped nonWhitelistedBuffs.
    displayBuffs     = {},
    nDisplayBuffs    = 0,
    -- Unified per-group parallel arrays. _groupData[0] = default buff group;
    -- _groupData[ci] = container ci. Each entry has parallel arrays plus a
    -- count `n`. Allocated lazily by PreResolveAuraDisplayArrays.
    _groupData       = {},
    -- Pre-computed BuffMatch results (A3 optimization: fold per-spell matching
    -- into main loop, eliminating second iteration over allHelpful).
    _bmMatchedColor   = nil,  -- matched spellColors config table or nil
    _bmMatchedBorder  = nil,  -- matched spellBorders config table or nil
    _bmMatchedOverlay = nil,  -- matched spellOverlays config table or nil
    _bmColorAuraIID   = nil,  -- auraInstanceID of color-matching aura
    _bmOverlayAuraIID = nil,  -- auraInstanceID of overlay-matching aura
    containers       = {},
    nContainers      = {},  -- [ci] -> count
    allTracked       = {},
    nAllTracked      = 0,
    allHelpful       = {},
    nAllHelpful      = 0,
    helpfulBySpellID = {},
    missingRaidBuff  = nil,
    -- Count of "real" regular buffs across buffFrames + generalBuffs +
    -- nonWhitelistedBuffs. Incremented by the main filter loops at every
    -- append site, but NOT by the class raid buff injection. It existed so a
    -- unit with only an injected raid buff did not trigger the "any buff
    -- visible" blanket color/border/overlay rules. (v67: both the writer and
    -- the reader are gone -- see the note on this scratch table above.)
    _regularBuffCount = 0,
}
local function WipeBuffResult()
    -- Counter-based arrays: just reset counts. Stale entries past the
    -- count are never read (Grid2 pattern). Saves 6 table.wipe calls.
    _buffResult.nBuffFrames     = 0
    _buffResult.nGeneralBuffs   = 0
    _buffResult.nNonWhitelisted = 0
    _buffResult.nDisplayBuffs   = 0
    _buffResult.nAllTracked     = 0
    _buffResult.nAllHelpful     = 0
    for ci in pairs(_buffResult.nContainers) do _buffResult.nContainers[ci] = 0 end
    -- Reset per-group counters; readers (RenderAuraGroup) only walk 1..n.
    for gi, gd in pairs(_buffResult._groupData) do gd.n = 0 end
    -- helpfulBySpellID is a hash table keyed by spellID, not an array —
    -- must wipe (but only populated out of combat, so cost is bounded).
    table.wipe(_buffResult.helpfulBySpellID)
    _buffResult.missingRaidBuff = nil
    _buffResult._regularBuffCount = 0
    _buffResult._bmMatchedColor   = nil
    _buffResult._bmMatchedBorder  = nil
    _buffResult._bmMatchedOverlay = nil
    _buffResult._bmColorAuraIID   = nil
    _buffResult._bmOverlayAuraIID = nil
end

-- v67: _scratchRoutedIDs (secret-detection dedup set) and the CUSTOM ORDERING
-- HELPER (ApplyCustomOrdering plus its remainingTime / _pinned / _unpinned
-- support) removed -- all four were used only by the deleted per-unit scan
-- BF:FetchBuffData. 12.1 expresses a user Order as a dedicated per-spell aura
-- group (layoutIndex orders groups; no sort comparator takes a user rank) --
-- see the _custPromote promotion block in GetContainerBuffConfig above, which
-- reads specSpellOrdering through the same resolveSlot predicate this pass did.

-- ============================================================
-- BF:PreResolveAuraDisplayArrays
-- Populates result._groupData[gi] with parallel arrays for the
-- supplied aura list. Replaces the duplicated displayBuffs and
-- per-container pre-resolve loops.
--
-- Arguments:
--   unit, n, sourceList — what to iterate
--   result              — _buffResult-like scratch table; result._groupData[gi] populated
--   gi                  — group key (0 for default, ci for container)
--   opts                — { captureDummy, useTrackList, blanketSolid, showStacks }
--
-- opts.captureDummy   true = write isDummy[i] = aura._isDummy
-- opts.useTrackList   true = Path A (per-spell border first, blanket fallback)
--                     false = Path B (blanket border only)
-- opts.blanketSolid   pre-resolved blanket solid color or nil/false
-- opts.showStacks     gate the stackCounts lookup (false → nil out)
-- ============================================================
local function ensureGroupSlot(result, gi)
    local gd = result._groupData[gi]
    if not gd then
        gd = {
            textures = {}, instanceIDs = {}, expirations = {},
            durations = {}, spellIDs = {}, borderColors = {},
            stackCounts = {}, solidColors = {}, iconTypes = {},
            isDummy = {}, n = 0,
        }
        result._groupData[gi] = gd
    end
    return gd
end

function BF:PreResolveAuraDisplayArrays(unit, n, sourceList, result, gi, opts)
    local gd = ensureGroupSlot(result, gi)
    gd.n = n
    if n == 0 then return gd end

    local captureDummy = opts.captureDummy
    local useTrackList = opts.useTrackList
    local blanketSolid = opts.blanketSolid
    local showStacks   = opts.showStacks
    -- Pre-resolved per-spec sub-tables (populated by EnsureFetchBuffSettings,
    -- passed by the caller). When nil, the corresponding per-spell lookup is
    -- skipped — same semantics as the old `if Helper then Helper(asid) end`
    -- guard but without the per-aura BF.* hash lookup.
    --
    -- Layout:
    --   borderColorsBySpell[spellId] -> { r, g, b, [a], enabled? }
    --   solidIconsBySpell[spellId]   -> { r, g, b, enabled? }
    --   iconTypeBySpell[spellId]     -> "Square"|"BorderedSquare"
    -- The `enabled == false` filter is applied inline below; only entries
    -- that pass it produce a per-spell value.
    local borderColorsBySpell = opts.borderColorsBySpell
    local solidIconsBySpell   = opts.solidIconsBySpell
    local iconTypeBySpell     = opts.iconTypeBySpell
    -- v67: the hoisted blanket border color is gone with
    -- BF.GetBuffsBorderColor (a 12.0.7-only AC setting). Per-spell border
    -- colors are the only source now, so an aura with no per-spell entry gets
    -- `false` rather than a blanket fallback.
    local blanketBorder = nil

    local tex  = gd.textures
    local iid  = gd.instanceIDs
    local exp  = gd.expirations
    local dur  = gd.durations
    local sid  = gd.spellIDs
    local brd  = gd.borderColors
    local stk  = gd.stackCounts
    local sol  = gd.solidColors
    local typ  = gd.iconTypes
    local dmy  = gd.isDummy

    for i = 1, n do
        local a = sourceList[i]
        local asid = a._bf_spellId or a.spellId
        tex[i] = a.icon
        iid[i] = a.auraInstanceID
        exp[i] = a.expirationTime
        dur[i] = a.duration
        sid[i] = asid

        -- Taint gate: canaccessvalue(asid) must run BEFORE we use asid as
        -- a table index. Indexing any table with a secret value throws
        -- "attempted to index a table that cannot be indexed with secret
        -- keys" in WoW's tainted-Lua sandbox. Previously this check was
        -- lazy (inside the per-branch `if e and e.enabled` block), but
        -- that meant the `borderColorsBySpell[asid]` / `solidIconsBySpell[asid]`
        -- lookups already threw before the check could run.
        local sidUsable
        if asid then
            sidUsable = canaccessvalue(asid)
        end

        -- Border color: per-spell first (when track-list applies), blanket fallback.
        -- Per-spell lookup uses the pre-resolved sub-table directly (one hash
        -- lookup + enabled filter) instead of calling the BF.GetSpellBorderColor
        -- helper (which would re-walk BF.acDB.profile.specSpellBorderColors[specId]
        -- on every iteration).
        if useTrackList then
            local bc
            if sidUsable and borderColorsBySpell then
                local e = borderColorsBySpell[asid]
                if e and e.enabled ~= false then
                    bc = e
                end
            end
            brd[i] = bc or blanketBorder or false
        else
            brd[i] = blanketBorder or false
        end

        -- Solid color: per-spell first, blanket fallback.
        local sc
        if sidUsable and solidIconsBySpell then
            local e = solidIconsBySpell[asid]
            if e and e.enabled ~= false then
                sc = e
            end
        end
        sol[i] = sc or blanketSolid or false

        -- Icon type: "Square" / "BorderedSquare" / false. v69: the ARRAY
        -- vocabulary is Square/BorderedSquare ("square with a border") —
        -- the stored type plus the solid entry's Show Border flag map
        -- INTO it here, so the render path draws the border without
        -- learning the flag. Legacy stored "SquareDuration" collapses to
        -- Square (static solid stand-in either way); legacy
        -- "BorderedSquare" passes through unchanged.
        local it
        if sidUsable and iconTypeBySpell then
            local e = iconTypeBySpell[asid]
            if e then
                it = e
            end
        end
        if it == "SquareDuration" then it = "Square" end
        if it == "Square" and sc and sc.showBorder then
            it = "BorderedSquare"
        end
        typ[i] = it or false

        -- isDummy: only for container groups (preview support).
        if captureDummy then
            dmy[i] = a._isDummy
        else
            dmy[i] = nil
        end

        -- Stack count: gated by showStacks.
        if showStacks and a.auraInstanceID then
            stk[i] = C_UnitAuras.GetAuraApplicationDisplayCount(unit, a.auraInstanceID, 2, 99)
        else
            stk[i] = nil
        end
    end
    return gd
end

-- v67: BF:FetchBuffData removed (12.1-only; the legacy per-unit aura scan).
-- Its only caller was Buffs:GetIcons in Statuses/Auras.lua, which the 12.1
-- AuraContainer engine replaced -- BuffsAndContainers now drives every buff
-- group from GetContainerBuffConfig instead. The /bf debugric dump that also
-- called it went with it (Core_ChatCommands.lua).

-- Expose the scratch result table for the buffs status to stash per-unit
BF._buffResult = _buffResult

-- Perf: public accessor for the BuffsAndContainers fast-path.
-- Returns true iff the current spec has at least one spell that can route
-- to any custom container. When false, the container half of that indicator
-- can skip its entire body (nothing can produce a container match). The
-- underlying flag is computed by EnsureFetchBuffSettings and invalidated
-- on every spec / talent / assignment / container edit via
-- InvalidateClaimedSpellCache -> InvalidateFetchBuffSettings.
function BF:HasActiveContainerSpellsForCurrentSpec()
    EnsureFetchBuffSettings()
    return _fbsHasActiveContainerSpells
end

-- Perf: per-container spec gate. True iff container `ci` has at least one
-- current-spec spell assigned (and is not hidden with fall-through routing).
-- Used by BF:GetActiveAuraGroups to omit empty containers from the runtime
-- render loop entirely.
function BF:ContainerHasSpecSpells(ci)
    EnsureFetchBuffSettings()
    return _fbsContainersWithSpecSpells[ci] == true
end

-- Perf: per-container per-spec cooldown-text override gate. True iff the
-- container has at least one spell with per-spell cooldown-text overrides
-- configured for the current spec. Used by GetContainerGroupConfig to
-- set perSpellOverrides ("spec" or false). When false, RenderContainerIcons
-- skips ResolveSpellCooldownText entirely for this group's icons.
function BF:ContainerHasSpecOverrides(ci)
    EnsureFetchBuffSettings()
    return _fbsContainerHasSpecOverrides[ci] == true
end

-- RebuildBigDefCache, RebuildImportantCache, RebuildCrowdControlCache
-- REMOVED — these eager cache rebuilds have been replaced by lazy fetch
-- methods on the BigDef, Important, and CrowdControl statuses
-- (Statuses/Auras.lua). Data is now fetched live at display time via
-- status:GetIcons(), matching Grid2's pattern for all aura statuses.

-- ============================================================
-- CUSTOM BUFF CONTAINERS — DATA HELPERS
-- ============================================================

function BF:GetCustomBuffContainers()
    local acp = self.acDB.profile
    -- v92: accessor-side late-curated seed (dual-caller pattern, see
    -- SeedCrowdControlContainer): mints Single Buff entries for curated
    -- spells added to SPEC_SPELLS after migration 59 shipped (currently
    -- Holy Bulwark / Holy Paladin). One sentinel field read steady-state.
    if self.SeedLateCuratedSingleBuffs then
        self:SeedLateCuratedSingleBuffs(acp)
    end
    if not acp.customBuffContainers then
        acp.customBuffContainers = {}
    end
    return acp.customBuffContainers
end

-- Custom DEBUFF containers are a separate array from the buff containers.
-- They are preset-only (no assigned spells) and scan HARMFUL auras. See
-- BF.DEBUFF_CONTAINER_PRESETS and the dbc<ci> render path in DebuffIcons.lua.
--
-- Retired preset keys are pruned lazily, once per array identity (weak-keyed
-- set, so a profile switch re-prunes the new profile's array and nothing is
-- written into saved variables). A stored key with no def would otherwise be
-- invisible in the options tree (nodes build from DEBUFF_CONTAINER_PRESETS)
-- yet linger in the saved data forever. Currently: nonDispellable (removed
-- 2026-08-14 — see the note above BF.DEBUFF_CONTAINER_PRESETS) and
-- allDispellable (v91, retired 2026-08-17 in favour of the by-Me / by-Others
-- split).
--
-- v91: allDispellable is MIGRATED before it is pruned, so a container that was
-- showing every dispellable debuff keeps doing so. Rule (owner ruling
-- 2026-08-17, and the same one Core_Migrations applies to saved profiles):
-- the holder gains othersDispellable, PLUS meDispellable if no other container
-- already holds it — a preset lives in exactly one container, so if
-- meDispellable is taken elsewhere the holder gets only othersDispellable and
-- the by-me subset keeps rendering where it already was.
local RETIRED_DEBUFF_PRESETS = { "nonDispellable", "allDispellable" }
local _dbcPruned = setmetatable({}, { __mode = "k" })
function BF:GetCustomDebuffContainers()
    local acp = self.acDB.profile
    -- v69: accessor-side Crowd Control container seed (dual-caller pattern,
    -- see EnsureBuffsPresetsSeeded): new/copied/reset acDB profiles never
    -- reach the dbVersion dispatcher. Self-guarded on acp._ccContainerSeededV69;
    -- no carry table = the factory CC look, disabled.
    if self.SeedCrowdControlContainer then
        self:SeedCrowdControlContainer(acp)
    end
    if not acp.customDebuffContainers then
        acp.customDebuffContainers = {}
    end
    local arr = acp.customDebuffContainers
    if not _dbcPruned[arr] then
        _dbcPruned[arr] = true
        -- v91: who already holds meDispellable? Resolved BEFORE the walk so the
        -- answer cannot depend on what this pass writes (a container migrated
        -- earlier in the array must not block a later one from... nothing:
        -- allDispellable also lives in exactly one container, so at most one
        -- migration fires — but the pre-scan keeps that independent of order).
        local meTaken = false
        for i = 1, #arr do
            local presets = arr[i].presets
            if presets and presets.meDispellable then meTaken = true; break end
        end
        for i = 1, #arr do
            local presets = arr[i].presets
            if presets then
                if presets.allDispellable then
                    presets.othersDispellable = true
                    -- Carry the old preset's Relative Size onto both heirs
                    -- (never stomping a value the user already set).
                    local rs = arr[i].presetRelativeSize
                    local pct = rs and rs.allDispellable
                    if not meTaken then
                        presets.meDispellable = true
                        meTaken = true
                        if pct and rs.meDispellable == nil then rs.meDispellable = pct end
                    end
                    if pct and rs.othersDispellable == nil then
                        rs.othersDispellable = pct
                    end
                    if rs then rs.allDispellable = nil end
                end
                for j = 1, #RETIRED_DEBUFF_PRESETS do
                    presets[RETIRED_DEBUFF_PRESETS[j]] = nil
                end
            end
        end
    end
    return arr
end

-- ============================================================
-- v62 SINGLE BUFFS -- SPELL SOURCE, IDENTITY, SPEC CONDITION (plan 3.67)
--
-- A "single buff" is an ordinary entry in customBuffContainers with
-- c.singleBuff = true and maxBuffs = 1, holding exactly ONE spell. That spell
-- lives on the container as c.singleBuffSpellID; a single buff does NOT
-- participate in spellAssign / selectedSpells / spellToContainer at all.
--
-- WHY it left that mechanism rather than extending it: the spell->container
-- relation is 1:1 at three independent levels -- spellAssign[specId][sid] is a
-- single scalar "c:N" string, the options assign path clears the spell off
-- every OTHER container before setting it on the target, and the runtime
-- spellToContainer map is one ci per spellId. The owner requires the SAME spell
-- to be addable more than once as separate entries with their own conditions,
-- which none of those three can express. Not using the mechanism removes the
-- constraint without touching any of its existing consumers.
--
-- Consequence for spec handling: a single buff has no per-spec assignment left,
-- so its own Spec condition (c.loadSpec / c.loadSpecTypes, semantics copied
-- from the Buzzard Auras tracker load conditions) is the ONLY spec mechanism it
-- has. Absent condition = shows on every spec.
-- ============================================================

-- The spell a single buff holds, or nil if `c` is not a single buff (or has no
-- valid spell yet). ONE accessor so no caller re-derives it.
function BF:GetSingleBuffSpellID(c)
    if type(c) ~= "table" or not c.singleBuff then return nil end
    -- PSEUDO ENTRIES (c.pseudoKind) report NO spell. They are Buff List rows
    -- that host a feature's settings rather than an aura -- Swiftmendable is
    -- the first -- and they must never reach the aura engine. This accessor is
    -- the ONE choke point every runtime consumer already guards with
    -- `if sid then` (flow collection, slot creation, claim/exclude sets, pool
    -- preallocation, preview painting, Order lookup), so returning nil here
    -- makes the entry inert everywhere without a single new guard downstream.
    -- The options UI reads c.singleBuffSpellID directly for icon and name.
    if c.pseudoKind then return nil end
    local sid = c.singleBuffSpellID
    if type(sid) ~= "number" or sid <= 0 then return nil end
    return sid
end

-- The spell ID a Buff List row DISPLAYS (icon, name, tree label, key mint).
-- Same as GetSingleBuffSpellID for a real single buff; for a pseudo entry it
-- is the feature's face spell, which GetSingleBuffSpellID deliberately hides.
function BF:GetSingleBuffDisplaySpellID(c)
    if type(c) ~= "table" or not c.singleBuff then return nil end
    local sid = c.singleBuffSpellID
    if type(sid) ~= "number" or sid <= 0 then return nil end
    return sid
end

-- Mint a stable per-entry identity "<spellID>_<n>" (owner-specified shape).
-- FIRST-UNUSED-SLOT rule, copied from newCFGFlatID (Options_CustomFrames.lua):
-- scan the live single buffs for that spellID, take the lowest free n. A live
-- key is never reused and nothing is renumbered when an entry is deleted, so a
-- saved options nav path stays valid across unrelated deletions.
--
-- `containers` is optional and exists for migrations, which mint against a
-- NON-active profile's container array rather than the live one.
function BF:NewSingleBuffKey(spellID, containers)
    spellID = tonumber(spellID)
    if not spellID then return nil end
    containers = containers or self:GetCustomBuffContainers()
    local used = {}
    if type(containers) == "table" then
        for _, c in ipairs(containers) do
            if type(c) == "table" and type(c.singleBuffKey) == "string" then
                -- Parse both halves instead of building a pattern from the
                -- spell ID: no pattern-escaping question, and a malformed key
                -- simply fails to match instead of matching too much.
                local keySid, keyN = c.singleBuffKey:match("^(%d+)_(%d+)$")
                if keySid and tonumber(keySid) == spellID then
                    used[tonumber(keyN)] = true
                end
            end
        end
    end
    local n = 1
    while used[n] do n = n + 1 end
    return spellID .. "_" .. n
end

-- The single buff carrying `key`, plus its index in customBuffContainers.
-- Single buffs still occupy slots in that array, so the INDEX shifts when an
-- earlier container is deleted -- which is exactly why the options tree keys on
-- singleBuffKey and resolves the index through here instead of storing it.
function BF:FindSingleBuffByKey(key)
    if type(key) ~= "string" then return nil end
    local all = self:GetCustomBuffContainers()
    for i, c in ipairs(all) do
        if type(c) == "table" and c.singleBuff and c.singleBuffKey == key then
            return c, i
        end
    end
    return nil
end

-- ── v92: STABLE MULTI-ICON CONTAINER KEYS ──────────────────────────────────
-- Mint a stable per-container identity "c_<n>" for a MULTI-ICON buff container.
-- Single buffs keep singleBuffKey and never carry one; debuff containers need
-- no key at all -- nothing anchors TO a debuff container.
--
-- FIRST-UNUSED-SLOT, the same rule as BF:NewSingleBuffKey / newCFGFlatID /
-- NextCustomContainerName: take the lowest free n over the live keys. A live key
-- is never renumbered, which is the entire reason a Single Buff anchored at
-- "C:<key>" references a KEY and not the array index ci -- ci shifts on every
-- delete and RemoveCustomBuffContainer deliberately renumbers nothing.
--
-- `containers` is MANDATORY and is deliberately never fetched here: the dbVersion
-- 72 migration mints against a NON-active acDB profile's array, and a fetch
-- fallback would silently scan the LIVE profile instead and hand out keys that
-- are already taken in the profile being walked.
function BF:NewContainerKey(containers)
    local used = {}
    if type(containers) == "table" then
        for _, c in ipairs(containers) do
            -- Single buffs are scanned too rather than skipped: they never carry
            -- the field, so the match simply fails and the extra test would only
            -- restate that.
            if type(c) == "table" and type(c.containerKey) == "string" then
                local n = tonumber(c.containerKey:match("^c_(%d+)$"))
                if n then used[n] = true end
            end
        end
    end
    local n = 1
    while used[n] do n = n + 1 end
    return "c_" .. n
end

-- key -> index memo for BF:FindBuffContainerByKey, plus the interned host
-- descriptors BF:GetSingleBuffAnchorHost hands out for "C:<key>" anchors.
--
-- Both are cleared together by InvalidateContainerKeyIndex below, because both
-- carry a ci and a delete shifts every ci after it. They exist because the
-- resolver runs per frame per pass on the render path: a linear scan per call
-- (the FindSingleBuffByKey shape, which is settings-time only) and a fresh host
-- table per call are both unaffordable there.
local _containerKeyIndex  = nil
local _containerHostCache = nil

local function InvalidateContainerKeyIndex()
    _containerKeyIndex  = nil
    _containerHostCache = nil
end

local function BuildContainerKeyIndex(all)
    local idx = {}
    if type(all) == "table" then
        for i, c in ipairs(all) do
            if type(c) == "table" and type(c.containerKey) == "string" then
                idx[c.containerKey] = i
            end
        end
    end
    return idx
end

-- The multi-icon buff container carrying `key`, plus its index in
-- customBuffContainers. Same index-is-not-identity reasoning as
-- BF:FindSingleBuffByKey, memoised (see above).
--
-- Once the map is built, an ABSENT key answers "no such container" without a
-- rescan; a key that resolves to an entry no longer carrying it (an edit that
-- somehow skipped the invalidator) rebuilds once and answers from the fresh map
-- rather than returning the entry that inherited that index.
function BF:FindBuffContainerByKey(key)
    if type(key) ~= "string" then return nil end
    local all = self:GetCustomBuffContainers()
    local idx = _containerKeyIndex
    if not idx then
        idx = BuildContainerKeyIndex(all)
        _containerKeyIndex = idx
    end
    local ci = idx[key]
    if ci == nil then return nil end
    local c = all[ci]
    if type(c) == "table" and c.containerKey == key then return c, ci end
    idx = BuildContainerKeyIndex(all)
    _containerKeyIndex = idx
    ci = idx[key]
    c  = ci and all[ci]
    if type(c) == "table" then return c, ci end
    return nil
end

-- Spec condition gate. Semantics copied EXACTLY from the Buzzard Auras tracker
-- load condition (../BuzzardAuras/Tracker.lua LoadSpecMet), including its
-- fail-open conventions, because that pattern is deliberate there:
--   * condition off                -> show
--   * current spec unknown         -> show
--   * loadSpecTypes absent         -> show
--   * otherwise                    -> loadSpecTypes[spec] ~= false
-- i.e. [specID] = false marks a spec OFF; absent or true means ON.
--
-- Settings-time only. Every caller resolves it into a cache (the _fbs tables,
-- frame._bf_bfcVisible, frame._bf_activeGroups); nothing consults it per frame
-- or per UNIT_AURA.
function BF:IsSingleBuffSpecMet(c)
    if type(c) ~= "table" then return true end
    -- 2026-09-14 (owner ruling): a MULTI-ICON container has no Spec condition
    -- of its own any more. Its content is Buff List entries anchored to it
    -- (plus presets), and each entry carries its own condition -- so "is this
    -- container wanted on this spec" is answered by BuildContainerRelevance
    -- from the entries, not by a stored gate the panel no longer shows. The
    -- v64 widening below (a container-level loadSpec) is retired; migration 80
    -- clears the keys, and a stray one is ignored here.
    if not c.singleBuff then return true end
    if not c.loadSpec then return true end
    local spec = self.playerSpecID
    if spec == nil then return true end  -- unknown spec: fail open
    local t = c.loadSpecTypes
    if t == nil then return true end
    return t[spec] ~= false
end

-- Convenience for the visibility resolvers: false for a container whose Spec
-- condition excludes the current spec, or for a single buff whose own Display
-- Type is Hide (c.singleBuffHidden -- v62 plan 3.67 slice 2).
--
-- v64: the Spec condition now applies to EVERY container, not just single
-- buffs. It used to early-return true for anything without c.singleBuff, which
-- made the condition inert on a multi-icon container -- and Basic containers
-- now expose it on their own Conditions subtab.
--
-- Safe to widen with no migration: loadSpec was only ever settable from the
-- single-buff Conditions tab, and migration 54's container copy lists
-- loadSpec / loadSpecTypes in its SKIP set, so no existing multi-icon
-- container carries either field. The widening is inert until someone sets it.
--
-- BEHAVIOR when the condition excludes: the container is hidden and its buffs
-- do NOT fall back to the regular buff row. That deliberately matches the other
-- container-level gate, showForGroupType ("Enabled for this Layout"), rather
-- than the single-buff Spec condition, which DOES fall back -- a single buff
-- has one spell and no container of its own to hide, so falling back is the
-- only sensible reading there. "Show assigned spells in default buff container"
-- remains the opt-in for wanting them in the regular row.
--
-- The name still says SingleBuff for call-site compatibility; it is now a
-- container-wide predicate.
function BF:IsSingleBuffVisibleForSpec(c)
    if type(c) ~= "table" then return true end
    if c.singleBuff and c.singleBuffHidden then return false end
    return self:IsSingleBuffSpecMet(c)
end

-- Cached reference to the active containers table. The table identity is
-- stable between InvalidateClaimedSpellCache calls (the profile only swaps
-- on explicit profile changes, which also invalidate). Readers in the hot
-- path avoid the GetCustomBuffContainers method dispatch + nil-check.
local _activeContainersCache = nil
-- Parallel cache for the separate debuff-container array. Same stability
-- contract as the buff cache: invalidated whenever the buff cache is.
local _activeDebuffContainersCache = nil

function BF:GetActiveCustomBuffContainers()
    if _activeContainersCache then return _activeContainersCache end
    _activeContainersCache = self:GetCustomBuffContainers()
    return _activeContainersCache
end

function BF:GetActiveCustomDebuffContainers()
    if _activeDebuffContainersCache then return _activeDebuffContainersCache end
    _activeDebuffContainersCache = self:GetCustomDebuffContainers()
    return _activeDebuffContainersCache
end

local function InvalidateActiveContainersCache()
    _activeContainersCache = nil
    _activeDebuffContainersCache = nil
    -- v92: the containerKey memo + its host descriptors carry array INDEXES,
    -- so they go stale on exactly the same events these two do.
    InvalidateContainerKeyIndex()
end

-- BF:IsSwiftmendEnabled + its cache REMOVED (Swiftmendable pseudo-buff pass).
-- They belonged to the pre-12.1 Lua recolor path (BF:UpdateSwiftmendable,
-- removed with them): nothing ever set frame._bf_swiftmendable, so the
-- predicate had no callers. The live feature is the fxSM slot built from
-- cfg.swiftmendFx / cfg.swiftmendName above, which needs no cached predicate.

-- ============================================================
-- PER-CONTAINER SOUL OF THE FOREST GATE
--
-- Three cached flags, rebuilt on every InvalidateClaimedSpellCache:
--
--   BF._containerHasSotF[container]   (per container, weak map)
--       true iff the container has Rejuvenation (774), Regrowth (8936),
--       or Germination (155777) in its selectedSpells. Container display
--       paths use this to skip _sotfUnit stamping and ApplySotFGlow
--       calls for containers that can never hold an empowerable aura.
--
--   _anyContainerHasSotFSpell    (file-local)
--       true iff at least one container has an empowerable spell.
--       Gates container-pool walks in SoulOfTheForest.lua (removal sweep,
--       disable sweep) so non-Druids / users without SotF-assigned
--       containers pay zero cost for those walks.
--
--   BF._sotfSkipRegularBuffs     (exposed on BF)
--       true iff every empowerable spell is either out of the spec's
--       trackList OR claimed (by container, untracked, or default-untracked
--       without a "default" override). When true, BuffIcons can never
--       display an empowerable aura, so regular buff SotF work can be
--       skipped entirely.
--
-- These gate only the SotF code path. All three are only consulted when
-- BF._sotfGlowActive is already true (the outer gate: Resto Druid +
-- SotF talented + sotfGlowEnabled). Non-Druids never enter the code paths
-- these flags guard.
-- ============================================================
local _anyContainerHasSotFSpell = false
BF._sotfSkipRegularBuffs = false
-- Exposed to SoulOfTheForest.lua for the UNIT_AURA removal sweep gate.
-- Mirrors the file-local _anyContainerHasSotFSpell value — kept in sync
-- by RebuildContainerSotFFlags. Consumers outside this file should read
-- BF._anyContainerHasSotFSpell.
BF._anyContainerHasSotFSpell = false

-- Per-container SotF flag, keyed by the container TABLE in a weak map
-- (owner request 2026-08-24). This used to be stamped onto the container
-- itself as c._bf_hasSotFSpell — but the container table IS the saved
-- profile table, so AceDB persisted a value that is recomputed from
-- scratch on every InvalidateClaimedSpellCache, and the rebuild loop only
-- walks the ACTIVE containers, so inactive-spec entries kept stale flags
-- in SavedVariables forever. The weak map has the exact lifetime the
-- cache needs (dies with the container table / profile switch), touches
-- no saved data, and dbVersion 76 sweeps the legacy field out of
-- existing profiles. Consumers: RenderContainerIcons ctx.sotfCheck
-- (below) and AuraGroupHelpers cfg.sotFEligible.
BF._containerHasSotF = setmetatable({}, { __mode = "k" })

-- Recomputed from InvalidateClaimedSpellCache. Consults BF._SotF_EMPOWERABLE_IDS
-- which is defined in SoulOfTheForest.lua (loads after this file — don't read
-- at module scope, only at call time).
--
-- Transition handling: if a gate flag goes from "do work" to "skip work",
-- any glow currently running on the newly-skipped icons will never be
-- stopped by the display path. We detect transitions against the previous
-- rebuild's flags and sweep the affected icons here.
local function RebuildContainerSotFFlags(self)
    local empowerable = BF._SotF_EMPOWERABLE_IDS
    if not empowerable then
        -- SotF module not loaded yet (shouldn't happen post-PLAYER_LOGIN).
        -- Leave flags at their safe defaults (false) so callers do full work.
        _anyContainerHasSotFSpell = false
        BF._anyContainerHasSotFSpell = false
        BF._sotfSkipRegularBuffs  = false
        return
    end

    -- Snapshot previous state so we can detect "gate closes" transitions.
    local prevAnyContainer = _anyContainerHasSotFSpell
    local prevSkipRegular  = BF._sotfSkipRegularBuffs

    local containers = _activeContainersCache or self:GetActiveCustomBuffContainers()
    local anyHas = false
    -- Per-container transition bookkeeping: list of containers whose flag
    -- just went from true to false. Walked after the loop to stop orphan glows.
    local closedContainers = nil
    if containers then
        for _, c in ipairs(containers) do
            local has = false
            local sel = c.selectedSpells
            if sel then
                for sid in pairs(empowerable) do
                    if sel[sid] then has = true; break end
                end
            end
            -- v62: a single buff's spell lives on the container, not in
            -- selectedSpells, so it needs its own probe or a single buff holding
            -- Rejuvenation would never get the SotF glow.
            if not has then
                local sbSid = self:GetSingleBuffSpellID(c)
                if sbSid and empowerable[sbSid] then has = true end
            end
            local prev = BF._containerHasSotF[c]
            if prev and not has then
                closedContainers = closedContainers or {}
                closedContainers[#closedContainers + 1] = c
            end
            BF._containerHasSotF[c] = has
            -- Lazy cleanup of the legacy SAVED copy of this flag (see the
            -- weak-map comment above): active containers shed it here, the
            -- v76 migration sweeps the inactive rest.
            if rawget(c, "_bf_hasSotFSpell") ~= nil then
                c._bf_hasSotFSpell = nil
            end
            if has then anyHas = true end
        end
    end
    _anyContainerHasSotFSpell = anyHas
    BF._anyContainerHasSotFSpell = anyHas

    -- BF._sotfSkipRegularBuffs: true iff every empowerable spell is
    -- excluded from the regular buff display. Excluded means either:
    --   (a) not in the current spec's trackList, OR
    --   (b) claimed (in-container OR untracked OR default-untracked)
    --
    -- Reuses the freshly-rebuilt GetClaimedSpells / GetTrackList results.
    -- InvalidateClaimedSpellCache wipes both caches just before calling
    -- this rebuild, so the next GetClaimedSpells / GetTrackList call
    -- recomputes from current settings.
    local specId = self.playerSpecID
    local claimed = self:GetClaimedSpells() or {}
    local trackList = specId and GetTrackList(specId)
    local allExcluded = true
    for sid in pairs(empowerable) do
        local inTrackList = trackList and trackList[sid]
        if inTrackList and not claimed[sid] then
            -- This spell CAN appear in regular buffs. Can't skip.
            allExcluded = false
            break
        end
    end
    BF._sotfSkipRegularBuffs = allExcluded

    -- ── Transition sweeps ───────────────────────────────────────────────────────────────────────
    -- Only run if BF._sotfGlowActive (no glows could exist otherwise).
    if BF._sotfGlowActive then
        local needSweep = (closedContainers ~= nil)
                       or (prevAnyContainer and not anyHas)
                       or (not prevSkipRegular and allExcluded)
        if needSweep and self.registeredFrames then
            -- Inline stop for the "border" style, which restores the
            -- original border color. (Non-border styles were LibCustomGlow
            -- effects; the library was removed along with the SotF glow
            -- module, so only the border restore remains.) Icons must
            -- already have the _sotfGlow flag set — otherwise this loop
            -- skips them.
            --
            -- v33: when the SotF glow style is "border" and no original color
            -- was saved (shouldn't normally happen, defensive), restore to the
            -- caller-provided default (defR..defA) instead of hardcoded black,
            -- so regular buff icons get the per-feature default and container
            -- icons get their per-container default.
            local function stopGlow(icon, defR, defG, defB, defA)
                if not icon._sotfGlow then return end
                local gt = icon._sotfGlowType or "button"
                if gt == "border" then
                    local orig = icon._sotfOrigBorderColor
                    if orig and BF.SetIconBorderColor then
                        BF.SetIconBorderColor(icon, orig[1], orig[2], orig[3], orig[4])
                    elseif BF.SetIconBorderColor then
                        BF.SetIconBorderColor(icon, defR, defG, defB, defA)
                    end
                    icon._sotfOrigBorderColor = nil
                    icon._sotfBorderActive = nil
                end
                icon._sotfGlow = false
                icon._sotfGlowType = nil
                icon._sotfGlowColor = nil
            end

            -- Regular buff sweep: only when regular-buffs-skip just turned on.
            local sweepBuffs = (not prevSkipRegular) and allExcluded
            -- Per-container sweep plan:
            --   * closedContainers (each): stop glows in that container's pool.
            --   * _anyContainerHasSotFSpell: false now, true before: stop all
            --     container pools. (closedContainers already covers individual
            --     containers, so this only matters if containers were removed
            --     entirely — their pools may still have glowing icons.)
            local sweepAllContainers = prevAnyContainer and not anyHas

            for _, frame in next, self.registeredFrames do
                if sweepBuffs and frame.buffFrames then
                    -- v33: regular buff default uses the buff AuraCache flag.
                    local brR, brG, brB, brA = BF.GetDefaultBorderColorFor("buff")
                    for i = 1, #frame.buffFrames do
                        local icon = frame.buffFrames[i]
                        if icon then stopGlow(icon, brR, brG, brB, brA) end
                    end
                end
                local pools = frame.SF_CustomContainerIcons
                if pools then
                    if sweepAllContainers then
                        for poolCI, pool in pairs(pools) do
                            -- v33: resolve the per-container default once per
                            -- pool iteration.
                            local cc = containers and containers[poolCI]
                            local cR, cG, cB, cA
                            if cc then
                                cR, cG, cB, cA = GetContainerDefaultBorderColor(cc, nil)
                            else
                                cR, cG, cB, cA = 0, 0, 0, 0.8
                            end
                            for i = 1, #pool do
                                local icon = pool[i]
                                if icon then stopGlow(icon, cR, cG, cB, cA) end
                            end
                        end
                    elseif closedContainers then
                        -- Sweep only the pools for containers that just lost
                        -- their SotF flag. Container indices match pool keys.
                        for _, c in ipairs(closedContainers) do
                            local ci = nil
                            -- Find container's index in the active containers list.
                            if containers then
                                for idx, cc in ipairs(containers) do
                                    if cc == c then ci = idx; break end
                                end
                            end
                            local pool = ci and pools[ci]
                            if pool then
                                -- v33: resolve once per closed-container pool.
                                local cR, cG, cB, cA = GetContainerDefaultBorderColor(c, nil)
                                for i = 1, #pool do
                                    local icon = pool[i]
                                    if icon then stopGlow(icon, cR, cG, cB, cA) end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

-- seed (optional): a flat table of field overrides applied AFTER the creation
-- defaults, so a caller can stamp a container's identity in one shot.
--
-- v61: added for the "Add Container -> Single Buff" creation form
-- (Options/Options_Auras.lua), which seeds maxBuffs = 1,
-- containerUsesBuffSettings = false, singleBuff = true and a spell-derived
-- name. A seed rather than a second creator, because every other field here --
-- the auraText inheritance in particular -- must stay identical for both
-- container kinds; a parallel creator would have to be kept in step by hand.
--
-- A seeded `name` must come with `autoNamed = false` (the callers do): the
-- delete-renumbering loop in RemoveCustomBuffContainer rewrites the name of
-- every auto-named container that shifts down, which would clobber a
-- spell-derived name.
-- Auto-name for a NEW custom container: "Custom <n>", lowest unused n.
--
-- Counts ONLY real containers. The old scheme was tostring(#containers + 1),
-- which counted the whole array -- and since every curated spell now has a
-- Single Buff entry in that same array, a user with one container was offered
-- "48" for their second.
--
-- FIRST-UNUSED-SLOT, not a running count, matching BF:NewSingleBuffKey and
-- newCFGFlatID: a name is never reused while it is live and nothing is
-- renumbered when a container is deleted, so an auto-name stays put.
function BF.NextCustomContainerName(containers)
    local used = {}
    if type(containers) == "table" then
        for _, c in ipairs(containers) do
            if type(c) == "table" and not c.singleBuff and type(c.name) == "string" then
                local n = tonumber(c.name:match("^Custom (%d+)$"))
                if n then used[n] = true end
            end
        end
    end
    local n = 1
    while used[n] do n = n + 1 end
    return "Custom " .. n
end

function BF:CreateCustomBuffContainer(seed)
    local containers = self:GetCustomBuffContainers()
    local defaultFont = "Interface\\AddOns\\BuzzardFrames\\Media\\Fonts\\RobotoCondensed-Bold.ttf"
    -- v30: seed creation-time defaults from the auraText section of the
    -- currently-modifying flat (or the global pseudo-layout when the
    -- per-layout auraText toggle is OFF). Pre-v30 this read from
    -- self.db.profile, which had been returning nil for every auraText
    -- key since the v15 namespace split (a latent fossil bug -- new
    -- containers were seeded with `or`-defaults instead of the user's
    -- actual Aura Text tab values).
    local atForSeed = self:GetSectionProfile("auraText", self:GetModifyingProfile()) or {}
    local atGlobal  = atForSeed.global or {}
    local atBuffs   = atForSeed.buffs  or {}
    -- Inherit duration settings from global or buff settings at creation time
    local useGlobal = atForSeed.globalAuraTextConfig ~= false
    local initShowDur, initAutoScale, initTimerScale, initFontSize, initFont, initBorder
    local initRevSwipe, initDisSwipe, initDisSpark, initFontColor
    if useGlobal then
        initShowDur   = atGlobal.globalDurationShow ~= false
        initAutoScale = atGlobal.globalAutoScale == true
        initTimerScale = atGlobal.globalTimerScale or 1.0
        initFontSize  = atGlobal.globalFontSize or 11
        initFont      = BF:ResolveFontPathOr(atGlobal.globalDurationFont, defaultFont)
        initBorder    = atGlobal.globalDurationBorder or "OUTLINE"
        initRevSwipe  = atGlobal.globalReverseSwipe == true
        initDisSwipe  = atGlobal.globalDisableSwipe or false
        initDisSpark  = atGlobal.globalDisableSpark or false
        initFontColor = atGlobal.globalFontColor
    else
        initShowDur   = atBuffs.showBuffDuration ~= false
        initAutoScale = atBuffs.buffAutoScale == true
        initTimerScale = atBuffs.buffTimerScale or 1.0
        initFontSize  = atBuffs.buffFontSize or 11
        initFont      = BF:ResolveFontPathOr(atBuffs.buffDurationFont, defaultFont)
        initBorder    = atBuffs.buffDurationBorder or "OUTLINE"
        initRevSwipe  = atBuffs.reverseBuffSwipe == true
        initDisSwipe  = atBuffs.disableBuffSwipe or false
        initDisSpark  = atBuffs.disableBuffSpark or false
        initFontColor = atBuffs.buffFontColor
    end
    -- Deep-copy the inherited font color so the new container doesn't share
    -- a table reference with the source auraText sub-category. Without this
    -- the container's Font Color picker would mutate the global setting too.
    local seedFontColor = {
        r = initFontColor and initFontColor.r or 1,
        g = initFontColor and initFontColor.g or 1,
        b = initFontColor and initFontColor.b or 1,
    }

    local defaults = {
        autoNamed                         = true,  -- cleared when user renames
        containerUsesBuffSettings         = true,
        containerUsesBuffDurationSettings = true,
        buffSize               = 12,
        maxBuffs               = 8,
        buffsPerRow            = 3,
        showDuration           = initShowDur,
        autoScale              = true,
        timerScale             = initTimerScale,
        fontSize               = initFontSize or 11,
        durationFont           = initFont,
        durationBorder         = initBorder,
        fontColor              = seedFontColor,
        reverseSwipe           = initRevSwipe,
        disableSwipe           = initDisSwipe,
        disableSpark           = initDisSpark,
        -- v33: colorAuraBorder replaces thresholdBorderEnabled +
        -- threshold2BorderEnabled. Single toggle controls whether the
        -- border uses Font Color (thresholds off) or the threshold curve
        -- (thresholds on) instead of the default black border.
        colorAuraBorder          = false,
        thresholdColorEnabled    = false,
        thresholdColorThreshold  = 8,
        thresholdColor           = BF.DEFAULT_THRESHOLD_COLOR,
        threshold2ColorEnabled   = false,
        threshold2ColorThreshold = 5,
        threshold2Color          = BF.DEFAULT_THRESHOLD2_COLOR,
        anchorPoint   = "TOP",
        offsetX       = 0,
        offsetY       = 0,
        growDirection = "RIGHT",
        spacing       = 1,
        rowSpacing    = 0,
        -- v65: no perLayoutConfig seed -- a new container starts SHARED and the
        -- user opts in from its own "Enable per-Layout configuration for this
        -- Container" toggle. nil is the third state of that tri-state flag
        -- ("never seeded"), which is exactly right here and is why the seed is
        -- absent rather than an explicit false: the dbVersion 65 seed-when-nil
        -- pass may still legitimately claim this container.
        --
        -- perLayoutConfig is a DIFFERENT KEY from the v61-retired
        -- separateGroupConfig, deliberately. That name is nil'd by
        -- _AuraMig_ContainersFollowSection, which still runs for new / copied /
        -- reset acDB profiles, so reusing it would erase the flag on the next
        -- profile copy.
        selectedSpells = {},
    }

    defaults.name = BF.NextCustomContainerName(containers)
    -- v61: seed overrides land last so they win over every default above,
    -- including the auto-name just assigned.
    if type(seed) == "table" then
        for k, v in pairs(seed) do defaults[k] = v end
    end
    -- v92: the stable containerKey, minted AFTER the seed merge and BEFORE the
    -- insert. Both halves of that ordering matter:
    --   * after the seed, because whether this is a MULTI-ICON container is the
    --     seed's call -- CreateSingleBuffContainer creates single buffs through
    --     this same path with singleBuff = true, and a single buff must never
    --     carry a containerKey (it has singleBuffKey, and it is not a host).
    --   * before the insert, because the first-unused-slot scan must not see the
    --     entry it is minting for; it has no key yet, so it would not be counted
    --     anyway, but the array is also the argument NewContainerKey requires.
    if not defaults.singleBuff and defaults.containerKey == nil then
        defaults.containerKey = self:NewContainerKey(containers)
    end
    table.insert(containers, defaults)
    -- The new key has to be visible to FindBuffContainerByKey before the next
    -- InvalidateClaimedSpellCache: an already-built memo answers "no such
    -- container" for an absent key without rescanning (see the note there).
    InvalidateContainerKeyIndex()
    return defaults, #containers
end

function BF:RemoveCustomBuffContainer(index)
    local containers = self:GetCustomBuffContainers()
    if not containers[index] then return end
    -- v65: drop the doomed entry's legacy Order mirror BEFORE the remove.
    --
    -- A Buffs-anchored single buff mirrors its Order into the curated
    -- acp.specSpellOrdering[spec][sid] so the 12.0.7 ordering pass can read it.
    -- That store outlives the container, and an orphaned Order is not inert: on
    -- 12.1 an Order is precisely what promotes a spell into its own sp<sid>
    -- group, and _fbsSingleBuffHeld -- the guard that suppressed that promotion
    -- -- disappears with the entry. Deleting a single buff would therefore have
    -- left its spell pinned in the regular buff row forever, with no widget
    -- left anywhere to clear it.
    --
    -- Only mirrored entries are cleaned, and only on the one spec they wrote
    -- (see singleBuffMirrorSpec in the options file): a multi-spec or
    -- unconditional entry never wrote a mirror, and the curated Position it
    -- would otherwise clobber belongs to the Aura Customizations spec tab.
    local doomed = containers[index]
    if doomed and doomed.singleBuff and doomed.loadSpec then
        local sid = self:GetSingleBuffSpellID(doomed)
        local t   = doomed.loadSpecTypes
        if sid and type(t) == "table" then
            local acp0 = self.acDB and self.acDB.profile
            local order = BF.HEALER_SPEC_ORDER or {}
            local only, ambiguous = nil, false
            for i = 1, #order do
                local id = order[i].id
                if t[id] ~= false then
                    if only then ambiguous = true end
                    only = id
                end
            end
            if ambiguous then only = nil end
            local m = only and acp0 and acp0.specSpellOrdering
                and acp0.specSpellOrdering[only]
            if m then m[sid] = nil end
        end
    end
    table.remove(containers, index)
    -- NO renumbering pass. It used to rewrite every auto-named container that
    -- shifted down to `tostring(i)` -- its ARRAY INDEX -- which is precisely the
    -- number the "Custom <n>" scheme exists to avoid, and which the Single Buff
    -- entries sharing this array made meaningless anyway. Auto-names are now
    -- first-unused-slot and stable across deletions, like singleBuffKey and
    -- cfgFlatID: the freed name is simply available to the next container.
    -- Rewrite all spellAssign "c:N" references so they reflect the shifted indices.
    -- Entries pointing at the removed container are reset to default;
    -- entries pointing at a higher-numbered container are decremented by one.
    local acp = self.acDB and self.acDB.profile
    if acp and acp.spellAssign then
        for _, assigns in pairs(acp.spellAssign) do
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
    -- v92 DELETE FALLBACK: every Single Buff whose Anchor Point flowed INTO the
    -- container just deleted falls back to the Buffs anchor (owner decision --
    -- no index remapping, and no silently-orphaned reference).
    --
    -- Unlike the spellAssign remap above, this walks the per-Layout
    -- groupSettings copies too. It has to: the anchor is a per-Layout field, so
    -- an entry can point at this container on raid only, and a reference left
    -- in a groupSettings copy would resolve to nothing on that Layout forever.
    -- That the spellAssign loop CANNOT walk them (they are not spell
    -- assignments) is exactly why container references are keys, not indexes.
    --
    -- The runtime resolver carries the same fallback (GetSingleBuffAnchorHost
    -- answers "buffs" for an unresolvable key) for references this pass cannot
    -- reach -- a profile imported from another character, say. Belt and braces:
    -- this one rewrites the DB so the options dropdown agrees with the render.
    local doomedKey = doomed and (not doomed.singleBuff) and doomed.containerKey
    if type(doomedKey) == "string" then
        local sentinel = "C:" .. doomedKey
        for _, sc in ipairs(containers) do
            if type(sc) == "table" and sc.singleBuff then
                if sc.anchorPoint == sentinel then sc.anchorPoint = "BUFFS" end
                if type(sc.groupSettings) == "table" then
                    for _, gs in pairs(sc.groupSettings) do
                        if type(gs) == "table" and gs.anchorPoint == sentinel then
                            gs.anchorPoint = "BUFFS"
                        end
                    end
                end
            end
        end
    end
    -- Every ci after `index` just shifted; the key memo and its host descriptors
    -- carry indexes. (InvalidateClaimedSpellCache does this too, but the caller
    -- is not required to reach it before something resolves a key.)
    InvalidateContainerKeyIndex()
end

-- ============================================================
-- CUSTOM DEBUFF CONTAINERS — DATA HELPERS
--
-- A debuff container is a preset-only display of HARMFUL auras. Unlike a
-- buff container it holds NO assigned spells (c.selectedSpells), no single-buff
-- variant, and no spellAssign wiring -- its content comes entirely from the
-- presets the user adds (c.presets, keyed into BF.DEBUFF_CONTAINER_PRESETS).
-- Container-own geometry reuses the buffSize/maxBuffs/buffsPerRow/spacing/
-- rowSpacing field names so the kind-aware resolvers (ResolveContainerGeometry
-- /Border/Duration) differ only in which AuraCache baseline they inherit from.
-- ============================================================
function BF:CreateCustomDebuffContainer(seed)
    local containers = self:GetCustomDebuffContainers()
    local defaultFont = "Interface\\AddOns\\BuzzardFrames\\Media\\Fonts\\RobotoCondensed-Bold.ttf"

    local defaults = {
        autoNamed                           = true,  -- cleared when user renames
        containerUsesDebuffSettings         = true,
        containerUsesDebuffBorder           = true,
        containerUsesDebuffDurationSettings = true,
        buffSize               = 12,
        maxBuffs               = 8,
        buffsPerRow            = 3,
        -- Duration/threshold value fields are intentionally left unseeded:
        -- both the resolver (ResolveContainerDuration) and the options widgets
        -- read them with an effective-baseline fallback to ac.debuff*, and the
        -- "Use Debuffs Duration Settings" toggle populates them on first
        -- disable (mirroring the per-spell Cooldown Text subtab).
        autoScale                = true,
        fontColor                = { r = 1, g = 1, b = 1 },
        colorAuraBorder          = false,
        thresholdColorEnabled    = false,
        thresholdColorThreshold  = 8,
        thresholdColor           = BF.DEFAULT_THRESHOLD_COLOR,
        threshold2ColorEnabled   = false,
        threshold2ColorThreshold = 5,
        threshold2Color          = BF.DEFAULT_THRESHOLD2_COLOR,
        anchorPoint   = "TOP",
        offsetX       = 0,
        offsetY       = 0,
        growDirection = "RIGHT",
        spacing       = 1,
        rowSpacing    = 0,
        -- v65: no perLayoutConfig seed here either -- same reasoning as
        -- CreateCustomBuffContainer above (new containers start shared).
    }

    defaults.name = BF.NextCustomContainerName(containers)
    if type(seed) == "table" then
        for k, v in pairs(seed) do defaults[k] = v end
    end
    table.insert(containers, defaults)
    return defaults, #containers
end

function BF:RemoveCustomDebuffContainer(index)
    local containers = self:GetCustomDebuffContainers()
    if not containers[index] then return end
    -- Preset-only: no single-buff Order mirror and no spellAssign references to
    -- rewrite. Auto-names are first-unused-slot, so no renumbering pass either.
    table.remove(containers, index)
end

-- v61 BUGFIX: this used to run Update ONLY, which never re-applied container
-- geometry. Every container geometry setter (anchor point, offsets, icon size,
-- spacing) routes its debounced refresh through here, but ContainerGeo and
-- ApplyAuraGridGeometry run exclusively in BuffsAndContainers:Layout — so the
-- value was written to acDB and nothing pushed it to the engine container. The
-- symptom was an edit that appeared to do nothing until some UNRELATED setting
-- happened to call RefreshAllCustomContainersWithRebuild (which forces
-- RefreshAllAuras, and that does reach Layout), at which point the pending
-- change suddenly applied.
--
-- Layout is called before Update, mirroring RefreshBuffsOnly. It is affordable
-- on this path because the callers debounce (see DebounceOption
-- "acCustomContainers", which coalesces slider drag ticks) and because Layout's
-- expensive work is already change-guarded: ApplyAuraGridGeometry compares
-- against _bf_curButtonSize / maxChanged, and ApplyBuffFilters gates the engine
-- UpdateAllAuras rebuild on cfg.generation. A geometry-only edit therefore
-- re-anchors, it does not rebuild.
function BF:RefreshAllCustomContainers()
    -- Vehicle defer (see Auras.lua): even the LIGHT path re-pushes group
    -- layout tables, and ANY group-config re-application while the player is
    -- in a vehicle corrupts candidate-table group assignment (owner-repro'd
    -- with an anchor change in a vehicle). Deferred work flushes on exit.
    if self.DeferAuraRefreshInVehicle and self:DeferAuraRefreshInVehicle() then return end
    self:InvalidateClaimedSpellCache()
    -- Rebuild the aura size cache BEFORE the per-frame Layout below. This is
    -- required for a container that INHERITS the Buffs size
    -- (containerUsesBuffSettings, the creation default): ResolveContainerGeometry
    -- then reads ac.buffSize / ac._roundedBuffSize, which are written solely by
    -- UpdateAuraSizeCache (which also bumps ac._cacheGen). A container with its
    -- OWN size reads s.buffSize live and does not depend on this, but the call
    -- is cheap-once (debounced callers) and keeps both cases on one path.
    -- Ordered before Layout, matching RefreshBuffsOnly.
    if self.UpdateAuraSizeCache then self:UpdateAuraSizeCache() end
    if self.registeredFrames then
        local primary = self:GetIndicatorByName("buffsAndContainers")
        -- v68: custom DEBUFF containers (dbc<ci>) are built by the debuffIcons
        -- indicator's Layout, which the buff-only walk never reached. Lay it out
        -- too so debuff-container geometry/preset edits apply on the light path.
        -- DebuffIcons:Layout is change-guarded and its dbc pass no-ops when the
        -- debuff-container array is empty, so this is free for profiles without
        -- any debuff containers.
        local debuffPrimary = self:GetIndicatorByName("debuffIcons")
        -- Grid2 rule: Layout every registered frame (spares included),
        -- Update the ones holding a unit.
        for _, frame in next, self.registeredFrames do
            if frame and not frame._isPreviewFrame then
                if primary then primary:Layout(frame) end
                if debuffPrimary then debuffPrimary:Layout(frame) end
                if frame.unit then self:UpdateFrameIndicators(frame, frame.unit) end
            end
        end
        if self.FlushDeferredIndicatorUpdates then self:FlushDeferredIndicatorUpdates() end
    end
    if self.RefreshPreviewDummyAuras and not InCombatLockdown() then
        self:RefreshPreviewDummyAuras()
    end
end

-- Call this when spell assignments change (container/untracked/default).
-- Wipes and rebuilds the aura match cache so spells move to the right
-- container immediately without waiting for the next UNIT_AURA.
function BF:RefreshAllCustomContainersWithRebuild()
    -- Vehicle defer — same rationale as RefreshAllCustomContainers above.
    -- (The RefreshAllAuras at this function's tail is guarded on its own,
    -- but the per-frame UpdateFrameIndicators/Layout walk BEFORE it is not.)
    if self.DeferAuraRefreshInVehicle and self:DeferAuraRefreshInVehicle() then return end
    self:InvalidateClaimedSpellCache()
    -- (2026-09-11: the solid icon color curve cache is no longer wiped here --
    -- GetSolidIconColorCurve is keyed by its inputs now, so a settings or
    -- spec change produces a new key by itself, and a wipe only forced a
    -- fresh curve address for unchanged settings, which the style snapshots
    -- compare by identity.)
    -- Rebuild per-spell border curves and container _expiringBorderCurve so
    -- that changes to custom border colors / threshold border settings are
    -- picked up by the next indicator Update pass.
    self:RebuildExpiringColorCurves()
    -- Refresh the AuraCache fast-path gate flags. A user toggling on
    -- "Change Health Color" / frame border / overlay for a spell writes the
    -- config to specSpellColors etc., and those derived gates are otherwise
    -- only recomputed on profile / spec changes.
    if self.UpdateAuraSizeCache then self:UpdateAuraSizeCache() end
    -- Invalidate the buffs status' per-unit GetIcons cache, if it still has
    -- one, so nothing serves aura lists built against the old
    -- spellToContainer mapping to units that have not seen a fresh UNIT_AURA.
    local buffsStatus = self.statuses and self.statuses.buffs
    if buffsStatus and buffsStatus.InvalidateGetIconsCache then
        buffsStatus:InvalidateGetIconsCache()
    end
    -- Update all active frames immediately. Hide container icons first so
    -- that stale icons from a prior assignment state don't persist when
    -- BuffsAndContainers' fast-path gate skips its container work
    -- (e.g. last container spell for this spec was reassigned to Default).
    -- UpdateFrameIndicators will re-render any containers that should still
    -- be visible via the normal indicator path.
    if not self.activeFrames then return end
    for frame in pairs(self.activeFrames) do
        if frame and frame.unit and frame:IsShown() then
            -- Inline HideAllContainerPools (defined later in file, not yet
            -- visible as a local at this point).
            if frame.SF_CustomContainerIcons then
                for ci, pool in pairs(frame.SF_CustomContainerIcons) do
                    for idx = 1, #pool do
                        local icon = pool[idx]
                        if icon and icon:IsShown() then icon:Hide() end
                    end
                end
            end
            self:UpdateFrameIndicators(frame, frame.unit)
        end
    end
    if self.FlushDeferredIndicatorUpdates then self:FlushDeferredIndicatorUpdates() end
    -- v43 (12.1 container path): AC edits change container group
    -- composition — per-spell groups, include/exclude sets, flow order —
    -- and those are applied in the indicators' LAYOUT (ApplyBuffFilters),
    -- which the Update-only loop above never reaches. Run a full Layout
    -- pass so assignment/customize/position edits apply live.
    -- v67: 12.0.7 branch removed (addon is 12.1-only). The legacy arm ran
    -- RefreshAllPrivateAuraDispelOverlays on its own because the full
    -- RefreshAllAuras pass below (whose tail IS that aggregate private-aura
    -- re-registration sweep) never ran there.
    if self.RefreshAllAuras then
        self:RefreshAllAuras()
    end
    -- Also refresh preview frames so color/setting changes are visible
    -- immediately in the options panel without toggling settings.
    if self.RefreshPreviewDummyAuras and not InCombatLockdown() then
        self:RefreshPreviewDummyAuras()
    end
end

-- ============================================================
-- DEBOUNCED OPTION-SETTER REFRESH WRAPPERS
--
-- Custom-container option setters used to call the refresh functions above
-- SYNCHRONOUSLY on every change. A color picker or slider fires its setter on
-- every drag tick, so each tick ran a full per-frame relayout (and, for the
-- WithRebuild variant, a whole-UI aura rebuild). Across a large pre-created
-- frame pool that stutters the client for the length of the drag.
--
-- These wrappers coalesce the engine walk under a single debounce key (the
-- VALUE write in the setter stays immediate; only the visible refresh is
-- deferred ~0.15s and re-checks combat in the callback). Callers keep doing
-- their own immediate NotifyChangeSafe()/RefreshPreviewDummyAuras() so the
-- OPTIONS PANEL updates without lag -- it is only the per-frame ENGINE refresh
-- that is debounced.
--
-- Two tiers:
--   RefreshContainersDebounced         -> the LIGHT path. Sufficient for edits
--     whose value is resolved live at Layout time (container geometry, anchor,
--     offsets, spacing, and the container's own border style/color/thickness,
--     which ResolveContainerBorder reads straight from config). No cache
--     rebuild is needed for these, so the light per-indicator relayout applies
--     them fully.
--   RefreshContainersWithRebuildDebounced -> the HEAVY path, debounced. Used by
--     everything not yet proven safe for the light path (spell assignment /
--     order / presets / per-spell color curves). Same cost as before per
--     COMMITTED change, but drag ticks no longer each pay it.
-- Both tiers share one debounce key so a rapid mix of edits collapses to a
-- single refresh. They must not lose the heavier work, though: if a heavy
-- refresh is already pending when a light edit arrives, the coalesced refresh
-- stays heavy. _containersPendingRebuild latches that and is cleared when the
-- timer fires. (DebounceOption re-checks combat before running fn.)
local _containersRefreshKey   = "acContainersRefresh"
local _containersPendingRebuild = false
-- v76 (owner ruling): the engine walk is MOUSE-UP-GATED, not time-debounced.
-- The 0.15s trailing debounce still ran the full container walk MID-DRAG
-- whenever the user paused a slider for 0.15s -- a visible hitch inside the
-- drag. MouseUpOption does no work while the left button is held; the range
-- setter's final mouse-up call (AceConfigDialog fires it) runs the walk
-- immediately on the final value. Click-type widgets (toggles, dropdowns,
-- buttons) fire on mouse-up already and refresh immediately.
function BF:RefreshContainersDebounced()
    self:MouseUpOption(_containersRefreshKey, function()
        local heavy = _containersPendingRebuild
        _containersPendingRebuild = false
        if heavy then
            BF:RefreshAllCustomContainersWithRebuild()
        else
            BF:RefreshAllCustomContainers()
        end
    end)
end
function BF:RefreshContainersWithRebuildDebounced()
    _containersPendingRebuild = true
    self:MouseUpOption(_containersRefreshKey, function()
        _containersPendingRebuild = false
        BF:RefreshAllCustomContainersWithRebuild()
    end)
end

-- ============================================================
-- CLAIMED SPELL LOOKUP
--
-- Returns the set of spell IDs to suppress from BuffIcons indicator's
-- regular buff output. A spell is claimed if:
--   - it is assigned to a custom container, OR
--   - it is set to "untracked", OR
--   - it is in DEFAULT_UNTRACKED_BY_SPEC and not set to "default"
-- ============================================================
local claimedSpellCache    = nil
local claimedSpellCacheKey = nil

-- Container offset cache (defined here so InvalidateClaimedSpellCache can reference it).
-- Populated lazily by CalcContainerOffsets; wiped when settings change.
local containerOffsetCache = {}
local function InvalidateContainerOffsetCache()
    table.wipe(containerOffsetCache)
end

-- Forward declaration: defined later, near the container settings cache.
local InvalidateContainerSettingsCache

-- Wipe per-icon identity/position caches on all active frames so that
-- the next UpdateCustomBuffContainers call re-applies all visual properties.
-- Called when settings change (font, size, duration display, etc.).
local function InvalidateContainerIconCaches()
    local function wipeFrameIcons(frame)
        if frame and frame.SF_CustomContainerIcons then
            for _, pool in pairs(frame.SF_CustomContainerIcons) do
                for _, icon in ipairs(pool) do
                    icon.auraInstanceID = nil
                    icon.SF_LastIndex   = nil
                    icon.cachedSize     = nil
                    -- Dirty the per-spell stamp guard so RenderContainerIcons
                    -- re-stamps colorCurveObject from the new sct/ctx on
                    -- the next Update (settings change = new curve objects).
                    -- Use a sentinel (true) rather than nil so the
                    -- "elseif cd._bf_sctSpell" restore-defaults branch in
                    -- RenderContainerIcons still fires — that branch
                    -- restores SetDrawSwipe, SetReverse, font, scale,
                    -- text color/alpha, and curve from ctx. Setting nil
                    -- would skip it and fall to the else branch which
                    -- only restores the curve, leaving stale cooldown
                    -- properties (reverse swipe, hidden text, etc.).
                    if icon.cooldown then
                        icon.cooldown._bf_sctSpell = true
                    end
                    -- Restore backdrop if it was removed by Square mode,
                    -- so the next display pass can set a border color.
                    if icon._bf_borderless then
                        local bs = BF:PixelsToUI(1)
                        BF.SetFrameBackdrop(icon, BF.GetBackdropTable(bs))
                        icon:SetBackdropColor(0, 0, 0, 0)
                        icon.Icon:ClearAllPoints()
                        icon.Icon:SetPoint("TOPLEFT", bs, -bs)
                        icon.Icon:SetPoint("BOTTOMRIGHT", -bs, bs)
                    end
                    icon._bf_borderless = nil
                end
            end
        end
        -- Clear highlight change-guard flags so the border / overlay / dot
        -- highlight indicators run fully on the next indicator pass.
        if frame then
            frame._bf_borderClear = nil
            frame._bf_overlayClear = nil
            frame._bf_dotClear = nil
            frame._bf_bhClear = nil
            -- Header-derived caches (groupTypeKey, isCustom/Raid/Party flags,
            -- containerHidden, activeGroups). Centralised in the helper so
            -- BFLayout.lua's header Reset() can use the same hook.
            if BF.ClearFrameHeaderDerivedCaches then
                BF:ClearFrameHeaderDerivedCaches(frame)
            end
            -- Dirty _bf_sctSpell on default buff icons too (same sentinel
            -- approach as container icons above).
            if frame.buffFrames then
                for _, icon in ipairs(frame.buffFrames) do
                    if icon.cooldown then
                        icon.cooldown._bf_sctSpell = true
                    end
                end
            end
        end
    end
    -- EVERY header child, not only BF.activeFrames. The per-frame state wiped
    -- here (groupTypeKey memo, activeGroups, containerHidden, icon identity)
    -- is stamped at frame BUILD time on spare children too (BuzzardFrame_Init
    -- runs frame:Layout() eagerly), so a spare that came into service after a
    -- settings edit kept the pre-edit state (same class as the header Reset()
    -- early-break bug in BFLayout.lua). Each wipe is a handful of field nils,
    -- so the whole pool costs less than one container rebuild. activeFrames
    -- is still walked for frames that are not header children (twins).
    local seen = {}
    if BF.groupsUsed then
        for _, header in ipairs(BF.groupsUsed) do
            for _, child in ipairs(header) do
                seen[child] = true
                wipeFrameIcons(child)
            end
        end
    end
    if BF.activeFrames then
        for frame in pairs(BF.activeFrames) do
            if not seen[frame] then wipeFrameIcons(frame) end
        end
    end
    -- Also wipe preview frames so position/size changes are applied immediately.
    -- Preview frames live in BF._previewFrames (keyed by flatID) and
    -- BF._previewCFFrames (array of CF group slots). The old code swept
    -- _previewPartyFrame / _previewRaidFrames which never existed, so
    -- _bf_containerHidden[ci] on preview frames was never cleared when
    -- showForGroupType / showOnParty / etc. changed.
    if BF._previewFrames then
        for _, f in pairs(BF._previewFrames) do wipeFrameIcons(f) end
    end
    if BF._previewCFFrames then
        for _, cf in ipairs(BF._previewCFFrames) do wipeFrameIcons(cf) end
    end
end
BF.InvalidateContainerIconCaches = InvalidateContainerIconCaches

-- CFG-scoped variant: only wipes container icon state on frames whose
-- parent header has isCustomFrame == true, plus CFG preview frames.
-- Main/RP frames are left completely untouched.
local function InvalidateContainerIconCachesCFGOnly()
    local function wipeFrameIcons(frame)
        if frame and frame.SF_CustomContainerIcons then
            for _, pool in pairs(frame.SF_CustomContainerIcons) do
                for _, icon in ipairs(pool) do
                    icon.auraInstanceID = nil
                    icon.SF_LastIndex   = nil
                    icon.cachedSize     = nil
                    -- Dirty the per-spell stamp guard (same sentinel as
                    -- the main InvalidateContainerIconCaches above) so
                    -- RenderContainerIcons re-stamps font / timer-scale /
                    -- color / curve from the rebuilt ctx on the next pass.
                    -- Without this, container icons with no per-spell
                    -- override never get their cooldown text scale
                    -- re-applied after a settings change (the no-override
                    -- branch in RenderContainerIcons doesn't restamp).
                    if icon.cooldown then
                        icon.cooldown._bf_sctSpell = true
                    end
                    if icon._bf_borderless then
                        local bs = BF:PixelsToUI(1)
                        BF.SetFrameBackdrop(icon, BF.GetBackdropTable(bs))
                        icon:SetBackdropColor(0, 0, 0, 0)
                        icon.Icon:ClearAllPoints()
                        icon.Icon:SetPoint("TOPLEFT", bs, -bs)
                        icon.Icon:SetPoint("BOTTOMRIGHT", -bs, bs)
                    end
                    icon._bf_borderless = nil
                end
            end
        end
        if frame then
            frame._bf_borderClear = nil
            frame._bf_overlayClear = nil
            frame._bf_dotClear = nil
            frame._bf_bhClear = nil
            if BF.ClearFrameHeaderDerivedCaches then
                BF:ClearFrameHeaderDerivedCaches(frame)
            end
        end
    end

    local function isCFGFrame(frame)
        local h = frame._bf_parentHeader or frame:GetParent()
        return h and h.isCustomFrame
    end

    -- Every child of every CFG header (see InvalidateContainerIconCaches for
    -- why spares are included), plus any CFG frame in activeFrames that is not
    -- a header child.
    local seen = {}
    if BF.groupsUsed then
        for _, header in ipairs(BF.groupsUsed) do
            if header.isCustomFrame then
                for _, child in ipairs(header) do
                    seen[child] = true
                    wipeFrameIcons(child)
                end
            end
        end
    end
    if BF.activeFrames then
        for frame in pairs(BF.activeFrames) do
            if not seen[frame] and isCFGFrame(frame) then
                wipeFrameIcons(frame)
            end
        end
    end
    -- CFG preview frames only
    if BF._previewCFFrames then
        for _, cf in ipairs(BF._previewCFFrames) do wipeFrameIcons(cf) end
    end
end
BF.InvalidateContainerIconCachesCFGOnly = InvalidateContainerIconCachesCFGOnly

-- Version counter for spell color settings. Incremented whenever specSpellColors
-- changes so the aura indicators know to re-evaluate even when
-- the claimed-spell-set key hasn't changed.
local _spellColorVersion = 0
function BF:InvalidateSpellColorCache()
    _spellColorVersion = _spellColorVersion + 1
end

-- Symbiotic Relationship talent state. Read by EnsureMissingSymbioticTracker
-- to decide whether to register/unregister the symbiotic tracker. Refreshed
-- on PEW, spec change, and talent change by RebuildMissingRaidBuffCaches.
BF._symbioticRelationshipTalented = false  -- true when 474750 is talented

-- ============================================================
-- Single-Aura Tracker registration (Phase 2 of the missing-raid-buff
-- redesign, Docs/MISSING_RAID_BUFF_REDESIGN_PLAN.md).
--
-- Trackers register whenever the player's class supports a raid buff
-- (independent of the showMissingRaidBuff toggle). The indicator
-- (Indicators/MissingRaidBuff.lua) gates visible rendering on the
-- runtime toggle. This avoids re-registering trackers on every
-- toggle change AND lets the tracker silently maintain s.idx[unit]
-- so when the user flips the toggle on, the icon state is correct
-- immediately rather than needing the next UA per unit to populate.
--
-- Symbiotic tracker registers only when player is Druid AND talented.
-- Unregisters cleanly when talent flips false (s:Unregister sequence
-- in Statuses/SingleAuraTrackers.lua dispatches HideAll on every
-- frame so the icon hides immediately, no protected APIs).
--
-- Class change (e.g. /reload after class change): tracker.spellIds is
-- bound at register time, so on class change we unregister the existing
-- tracker and re-register a new one for the new class. The unregister
-- sequence wipes s.idx and dispatches HideAll; the new register's
-- backfill (UpdateAllAuras equivalent in the framework) sets s.idx
-- correctly for the new class buff across all roster units.
-- ============================================================
BF._missingRaidBuffTracker  = nil   -- SingleAuraTracker instance or nil
BF._missingSymbioticTracker = nil

-- Returns the class currently used to scope the missing-raid-buff
-- tracker. nil for classes with no raid buff (Death Knight, Demon Hunter,
-- Monk, Hunter, Paladin, Rogue, Warlock). When this changes, both
-- trackers must be torn down and rebuilt.
local function GetTrackedPlayerClass()
    local playerClass = UnitClassBase and UnitClassBase("player")
    if not playerClass then return nil end
    if not BF.CLASS_RAID_BUFF[playerClass] then return nil end
    return playerClass
end

-- Walks the global pseudo-layout AND every per-flat icons section, returning
-- true if `predicate` matches any of them. Mirrors RebindAbsorbStatuses's
-- anyFlatHas pattern at BFStatus.lua:1832. Used to gate tracker registration
-- on toggle state: a user with the feature off in every flat profile pays
-- zero per-UA cost, matching the v4.4.4 baseline.
local function AnyFlatHasIconToggle(self, predicate)
    local rpp = self.rpDB and self.rpDB.profile
    if not rpp then return false end
    -- Global pseudo-layout.
    local ip = rpp.icons
    if ip and predicate(ip) then return true end
    -- Per-flat overrides, only when per-layout-icons is on.
    local lp = rpp.layouts
    -- 2026-08-24: icons toggles are per-subtab now; the coarse alias is
    -- the right gate (false positive only costs the scan).
    if BF:IsPerLayoutSection("icons") then
        local fl = lp.flatLayouts
        if fl then
            for _, flat in pairs(fl) do
                local fip = type(flat) == "table" and rawget(flat, "icons")
                if fip and predicate(fip) then return true end
            end
        end
    end
    return false
end

local function EnsureMissingRaidBuffTracker(self, playerClass)
    -- Toggle gate: register only when at least one flat has the feature on.
    -- Without this, every Druid/Priest/Mage/Warrior/Shaman/Evoker paid for
    -- the per-UA scan even with the feature globally off -- a real regression
    -- vs v4.4.4 where the cache maintenance block in Buffs:UNIT_AURA bailed
    -- early on `not (showMissingRaidBuff or showMissingSymbiotic)`.
    local wantTracker = playerClass and AnyFlatHasIconToggle(self, function(ip)
        return ip.showMissingRaidBuff and true or false
    end)

    -- Tear down if class changed OR if the toggle is now off everywhere.
    if self._missingRaidBuffTracker and (
        self._missingRaidBuffTracker._bf_class ~= playerClass
        or not wantTracker
    ) then
        self._missingRaidBuffTracker:Unregister()
        self._missingRaidBuffTracker = nil
    end

    if not wantTracker then return end
    if self._missingRaidBuffTracker then return end  -- already registered for this class
    if not BF.SingleAuraTracker then return end      -- framework not loaded (shouldn't happen)

    local classBuff = BF.CLASS_RAID_BUFF[playerClass]
    local tracker = BF.SingleAuraTracker:new("missingRaidBuff")
    tracker._bf_class = playerClass  -- private: track which class this was built for
    tracker:AddSpellId(classBuff)    -- AddSpellId accepts number or table of numbers
    -- Bind the indicator. May not exist yet at very early load -- if so,
    -- the indicator's RegisterIndicator call later won't notify the tracker;
    -- we look up by name now and bind once. Indicator is registered at
    -- Indicators/MissingRaidBuff.lua:199 (before this code runs at PEW).
    local indicator = BF.indicators and BF.indicators.missingRaidBuff
    if indicator then tracker:BindIndicator(indicator) end
    tracker:Register()
    self._missingRaidBuffTracker = tracker
end

local function EnsureMissingSymbioticTracker(self)
    -- Symbiotic tracker exists only when:
    --   1. Player is a talented Druid (BF._symbioticRelationshipTalented), AND
    --   2. At least one flat profile has showMissingSymbiotic on.
    -- The toggle gate matches the main raid-buff tracker: users with the
    -- feature off pay zero per-UA cost.
    local wantTracker = self._symbioticRelationshipTalented
                    and AnyFlatHasIconToggle(self, function(ip)
                        return ip.showMissingSymbiotic and true or false
                    end)

    if self._missingSymbioticTracker and not wantTracker then
        -- Talent loss OR toggle flipped off: unregister cleanly. The
        -- framework's Unregister sequence wipes s.idx, removes from the
        -- Trackers list, then dispatches the bound indicator on every
        -- frame currently showing the player so the icon hides immediately
        -- without waiting for the next UA. Combat-safe.
        self._missingSymbioticTracker:Unregister()
        self._missingSymbioticTracker = nil
        return
    end

    if not wantTracker then return end
    if self._missingSymbioticTracker then return end
    if not BF.SingleAuraTracker then return end

    local tracker = BF.SingleAuraTracker:new("missingSymbiotic")
    tracker.personalOnly = true           -- player-only scan/dispatch
    tracker:AddSpellId(474754)            -- Symbiotic Relationship buff
    local indicator = BF.indicators and BF.indicators.missingRaidBuff
    if indicator then tracker:BindIndicator(indicator) end
    tracker:Register()
    self._missingSymbioticTracker = tracker
end

-- Public: re-sync both trackers against current class + talent + toggle state.
-- Idempotent. Safe to call from PEW, spec change, talent change, option-
-- toggle flips, or any other state-shift point. Combat-safe (no protected
-- APIs in the register/unregister paths).
function BF:EnsureMissingRaidBuffTrackers()
    local playerClass = GetTrackedPlayerClass()
    EnsureMissingRaidBuffTracker(self, playerClass)
    EnsureMissingSymbioticTracker(self)
end

-- Refresh symbiotic talent state and (re)sync the trackers. Called on PEW,
-- spec change, and PLAYER_TALENT_UPDATE. The tracker framework handles
-- texture-deferred registration internally via SPELLS_CHANGED retry.
local function RebuildMissingRaidBuffCaches(self)
    local playerClass = UnitClassBase and UnitClassBase("player")
    if playerClass == "DRUID" then
        self._symbioticRelationshipTalented = IsPlayerSpell and IsPlayerSpell(474750) or false
    else
        self._symbioticRelationshipTalented = false
    end
    BF:EnsureMissingRaidBuffTrackers()
end
BF.RebuildMissingRaidBuffCaches = RebuildMissingRaidBuffCaches  -- exposed for talent handler

function BF:OnPlayerSpecChanged()
    local specIndex = GetSpecialization()
    if specIndex then
        local id, _, _, _, role = GetSpecializationInfo(specIndex)
        self.playerSpecID   = id
        self.playerSpecRole = role
    else
        self.playerSpecID   = nil
        self.playerSpecRole = nil
    end
    self:InvalidateClaimedSpellCache()
    RebuildMissingRaidBuffCaches(self)
    -- Rebuild the AuraCache so per-spec cached state reflects the new spec.
    -- Without this the render path keeps reading the previous spec's values.
    -- The previously-reported symptom -- health color / border / overlay stop
    -- working after respec until the options panel is opened -- is exactly this
    -- case: opening options triggers UpdateAuraSizeCache and recomputes.
    --
    -- v93 OPEN QUESTION: the flag this comment used to name,
    -- hasBuffHighlightConfigs, was deleted (no reader anywhere). It was the only
    -- read of BF.playerSpecID in Auras/AuraConfig.lua, so it may have been the
    -- only spec-derived field in the aura cache -- in which case this rebuild
    -- may no longer be needed. NOT removed: per-indicator UpdateDB methods read
    -- acDB directly and may carry spec-derived state of their own. Verify before
    -- touching.
    -- Spec change affects spec-derived state on every flat. Mark all flat caches dirty so the next pass rebuilds.
    if self.InvalidateAllFlatAuraCaches then self:InvalidateAllFlatAuraCaches() end
    if self.UpdateAuraSizeCache then self:UpdateAuraSizeCache() end
end

local function iterSelectedSpells(c, fn)
    if not c.selectedSpells then return end
    for spellId, on in pairs(c.selectedSpells) do
        if type(spellId) == "number" then fn(spellId, on) end
    end
end

local function buildClaimedCacheKey(containers, assign, defaultUntracked)
    local parts = {}
    for i, c in ipairs(containers) do
        iterSelectedSpells(c, function(spellId, on)
            if on then parts[#parts + 1] = "c" .. i .. ":" .. spellId end
        end)
        -- v62: single buffs contribute their own spell (see GetClaimedSpells).
        -- Only when their Spec condition passes, so the key changes -- and the
        -- claim lifts -- the moment the condition stops matching.
        local sbSid = BF:GetSingleBuffSpellID(c)
        if sbSid and BF:IsSingleBuffSpecMet(c) then
            -- v65: the Buffs anchor must be IN the key. GetClaimedSpells now
            -- decides whether to claim this spell partly from that flag, so a
            -- key that ignored it would keep serving a memoised claim set from
            -- before the anchor changed -- the buff would stay suppressed from
            -- the regular row (or stay duplicated in it) until some unrelated
            -- edit happened to move the key.
            --
            -- v92: same reasoning, widened from the boolean to the resolved
            -- HOST token. Routing is no longer "Buffs or not" -- an entry can
            -- move between Big Defensive and any named container without its
            -- Buffs-anchored flag ever changing, and each of those is a
            -- different set of icons the regular row must or must not leave
            -- alone. The token is the container key when there is one (stable
            -- across deletions, unlike ci) and the host kind otherwise.
            local h = BF:GetSingleBuffAnchorHost(c,
                GetCurrentContainerGroupTypeKey())
            parts[#parts + 1] = "s" .. i .. ":" .. sbSid
                .. (h and (":" .. (h.key or h.kind)) or "")
        end
    end
    if assign then
        for sid, val in pairs(assign) do
            parts[#parts + 1] = "a:" .. sid .. ":" .. val
        end
    end
    table.sort(parts)
    return table.concat(parts, "|")
end

-- ============================================================
-- v74 CONTAINER CREATION RELEVANCE (Grid2 suspend pattern)
--
-- Grid2 statuses carry load conditions (playerClassSpec); SuspendStatus
-- (GridStatusLoad.lua:84) marks excluded statuses suspended so they do no
-- work, and RefreshStatuses re-evaluates them on Grid_PlayerSpecChanged.
-- This is BF's creation-time analogue: an engine AuraContainer that can
-- have no content under the current spec is never BUILT at all -- which
-- matters because the engine pre-creates each group's full styled button
-- pool eagerly at AddAuraGroup, on every unit frame.
--
-- WHY SPEC-DERIVED INPUTS ARE SAFE TO GATE CREATION ON WHERE "Enabled for
-- this Layout" IS NOT: creation is combat-restricted and AuraContainers
-- can never be destroyed, so the v72 rule is "anything a frame might need
-- in combat must exist before combat". Group type CAN flip mid-combat
-- (party->raid conversion), so showForGroupType stays visibility-only.
-- The player's spec CANNOT change in combat, and the other inputs below
-- (assignment / whitelist / preset edits) are options writes -- every one
-- funnels through this invalidator, out of combat.
--
-- Relevance:
--   buff container:  Spec condition passes AND (single buff (one spell by
--     construction) OR whitelist entry (selectedSpells, spec-independent)
--     OR a spell assigned to it under the CURRENT spec OR a preset token).
--   debuff container: preset/whitelist content only. NO spec term: debuff
--     containers have no Conditions tab (buildContainerMgmtOptions gates
--     it `not isDebuff`) and the debuff runtime never consults
--     IsSingleBuffSpecMet, so a spec term here would invent a gate the
--     rest of the addon does not honor.
--
-- NO VISIBLE DIFFERENCE vs today: a spec-excluded buff container is
-- already parked-not-rendering (IsSingleBuffVisibleForSpec ->
-- _bf_bfcVisible) with its claims deliberately standing (v64 "no
-- fallback" rule), and a zero-content container renders nothing. Skipping
-- creation preserves both, and skips the engine container + its
-- pre-created button pool.
--
-- REBUILD ON CHANGE: recomputed eagerly in InvalidateClaimedSpellCache
-- below. When the relevance set CHANGES, every real frame's
-- _bf_auraContainersBuilt latch is cleared
-- (InvalidateBuiltFrameContainerLatches, ContainerFactory.lua):
-- in-service frames rebuild on their next Update via the v72 first-render
-- safety net, spares via the v73 warm-up re-arm -- both through the one
-- true creation path, which only ever ADDS what is missing, so a frame's
-- already-applied state never regresses.
-- ============================================================
local _containerRelevance    = nil  -- { buff = {ci=bool}, debuff = {ci=bool} }
local _containerRelevanceKey = nil  -- last computed signature, for change detection

local function ContainerHasWhitelist(c)
    local sel = c.selectedSpells
    if sel then
        for _, on in pairs(sel) do
            if on then return true end
        end
    end
    return false
end

-- v92: the set of container keys a Single Buff's Anchor Point flows INTO
-- ("C:<key>"), plus a stable signature of that set. A container whose only
-- content is anchored entries has no assigned spells, no whitelist and no
-- presets, so without this term it would be classified irrelevant, never
-- created, and every entry anchored to it would render nothing.
--
-- LAYOUT-AGNOSTIC on purpose: the per-Layout groupSettings copies are UNIONED
-- in rather than resolved through ResolveGroupSource. Creation is
-- combat-restricted and the group type can flip mid-combat (party -> raid), so
-- the v72 rule applies -- anything a frame might need in combat must EXIST
-- before combat. Resolving only the current Layout would leave the host
-- uncreated for the other one. Visibility stays per-Layout, as always.
--
-- Spec-gated by IsSingleBuffSpecMet, the same gate the entry's own relevance
-- term uses below: an entry excluded on this spec renders nothing, so it
-- cannot be the reason a container exists.
local function CollectAnchoredContainerKeys(containers)
    local set, list = nil, nil
    local function take(v)
        local k = type(v) == "string" and v:match("^C:(.+)$")
        if k then
            set = set or {}
            if not set[k] then
                set[k] = true
                list = list or {}
                list[#list + 1] = k
            end
        end
    end
    for _, c in ipairs(containers) do
        if type(c) == "table" and c.singleBuff and BF:IsSingleBuffSpecMet(c) then
            take(c.anchorPoint)
            if type(c.groupSettings) == "table" then
                for _, gs in pairs(c.groupSettings) do
                    if type(gs) == "table" then take(gs.anchorPoint) end
                end
            end
        end
    end
    if not list then return nil, "" end
    -- Sorted: groupSettings is a hash, so the walk order is not stable and an
    -- unsorted signature would flap between passes with no input change.
    table.sort(list)
    return set, table.concat(list, ",")
end

local function BuildContainerRelevance(self)
    -- 2026-09-14 (owner ruling): the legacy per-spec assignment model
    -- (acp.spellAssign "c:<ci>" / c.selectedSpells) no longer makes a BUFF
    -- container relevant. Migration 80 turned every such assignment into a
    -- Buff List entry anchored to the container, so a buff container is
    -- relevant on this spec exactly when it has a preset or an anchored entry
    -- whose own Spec condition is met -- the derived gate, with no stored
    -- container-level condition behind it. Debuff containers keep their
    -- whitelist term below.
    local rel = { buff = {}, debuff = {} }
    local parts = {}
    local buffContainers = self:GetActiveCustomBuffContainers() or {}
    -- v92: one pre-pass, not one scan per container (see the collector above).
    local anchoredKeys, anchoredSig = CollectAnchoredContainerKeys(buffContainers)
    for ci, c in ipairs(buffContainers) do
        local r
        if type(c) ~= "table" then
            r = true  -- corrupt entry: fail open, matching IsSingleBuffSpecMet
        elseif not self:IsSingleBuffSpecMet(c) then
            r = false
        elseif c.singleBuff then
            r = true
        else
            -- Presets, or "some Single Buff whose Spec condition is met on
            -- this spec flows into me" (CollectAnchoredContainerKeys is
            -- spec-gated per entry). Nothing else: a container with no
            -- content for the player's spec is not built and does no work.
            r = ((c.presets and next(c.presets) ~= nil)
                or (anchoredKeys and c.containerKey
                    and anchoredKeys[c.containerKey])) and true or false
        end
        rel.buff[ci] = r
        parts[#parts + 1] = r and "b1" or "b0"
    end
    -- v92: the referenced-key set rides in the signature. Belt and braces --
    -- an anchor edit that flips a container's relevance already moves the
    -- b1/b0 run above, but one that repoints an entry between two containers
    -- that are BOTH relevant for other reasons would not, and the change
    -- detector in InvalidateClaimedSpellCache is the only thing that clears the
    -- built-container latches. Anchor edits arrive through the heavy refresh
    -- anyway, so the extra latch clear costs nothing steady-state.
    parts[#parts + 1] = "|a:" .. anchoredSig
    for ci, c in ipairs(self:GetActiveCustomDebuffContainers() or {}) do
        local r
        if type(c) ~= "table" then
            r = true  -- corrupt entry: fail open
        else
            r = ((c.presets and next(c.presets) ~= nil)
                or ContainerHasWhitelist(c)) and true or false
        end
        rel.debuff[ci] = r
        parts[#parts + 1] = r and "d1" or "d0"
    end
    return rel, table.concat(parts)
end

-- kind: "buff" | "debuff". Fail-open for an unknown index (a container
-- appended after the last invalidation is created normally; the very next
-- invalidation classifies it).
function BF:IsContainerCreationRelevant(kind, ci)
    local rel = _containerRelevance
    if not rel then
        rel, _containerRelevanceKey = BuildContainerRelevance(self)
        _containerRelevance = rel
    end
    local t = rel[kind]
    local r = t and t[ci]
    if r == nil then return true end
    return r
end

function BF:InvalidateClaimedSpellCache()
    claimedSpellCacheKey = nil
    claimedSpellCache    = nil
    -- Talent / spell-assignment / container edits change which buffs are
    -- claimed by which spec, which feeds into the spec-derived flags
    -- baked into every flat's _auraCache. Mark all flat caches dirty;
    -- UpdateAuraSizeCache callers
    -- downstream pick this up on their next pass.
    if self.InvalidateAllFlatAuraCaches then self:InvalidateAllFlatAuraCaches() end
    InvalidateContainerOffsetCache()
    InvalidateContainerIconCaches()
    InvalidateContainerSettingsCache()
    InvalidateTrackListCache()
    InvalidateFetchBuffSettings()
    InvalidateActiveContainersCache()
    -- v74: recompute container creation relevance (block comment above).
    -- Eager, not lazy: change detection must run HERE, because this
    -- invalidator is the one funnel every relevance input flows through
    -- (spec change via OnPlayerSpecChanged, assignment / whitelist /
    -- preset / condition edits via the options refreshes). After
    -- InvalidateActiveContainersCache so the container arrays are fresh.
    do
        local newRel, newKey = BuildContainerRelevance(self)
        local changed = _containerRelevanceKey ~= nil
            and newKey ~= _containerRelevanceKey
        _containerRelevance, _containerRelevanceKey = newRel, newKey
        if changed and self.InvalidateBuiltFrameContainerLatches then
            self:InvalidateBuiltFrameContainerLatches()
        end
    end
    -- Rebuild SotF per-container + regular-buffs-skip flags. Must run
    -- after InvalidateActiveContainersCache (so GetActiveCustomBuffContainers
    -- returns fresh data) and relies on GetTrackList / GetClaimedSpells
    -- to lazily rebuild their caches on first call below.
    RebuildContainerSotFFlags(self)

    if self.Bounce_Sync then self:Bounce_Sync() end

    -- Re-run container pool pre-allocation so the out-of-combat icon pool
    -- absorbs any growth in assigned spells for this spec. Out-of-combat
    -- only (mid-combat spec change is impossible, and options edits that
    -- might add a spell are blocked in combat anyway).
    if not InCombatLockdown() and self.PreallocateContainerPools then
        if self.registeredFrames then
            for _, frame in next, self.registeredFrames do
                if not frame._isPreviewFrame then self:PreallocateContainerPools(frame) end
            end
        end
        -- Preview frames: mirror InvalidateContainerIconCaches iteration.
        -- Preview frames live in self._previewFrames (hash keyed by flatID) and
        -- self._previewCFFrames (array of CF group slots). The old code referenced
        -- self._previewPartyFrame / self._previewRaidFrames, which never existed,
        -- so preview frame pools were never grown on spec / assignment changes.
        if self._previewFrames then
            for _, f in pairs(self._previewFrames) do
                self:PreallocateContainerPools(f)
            end
        end
        if self._previewCFFrames then
            for _, cf in ipairs(self._previewCFFrames) do
                self:PreallocateContainerPools(cf)
            end
        end
    end
end

function BF:GetClaimedSpells()
    local containers = self:GetActiveCustomBuffContainers()
    local p = self.db and self.db.profile
    local acp = self.acDB and self.acDB.profile
    local specId = self.playerSpecID
    local assign = acp and acp.spellAssign and specId and acp.spellAssign[specId]
    local defaultUntracked = DEFAULT_UNTRACKED_BY_SPEC[specId]

    local key = buildClaimedCacheKey(containers, assign, defaultUntracked)
    if key == claimedSpellCacheKey and claimedSpellCache then
        return claimedSpellCache
    end

    local set = {}

    -- Container-assigned spells (skip containers hidden with showInRegularBuffs)
    local groupTypeKey = GetCurrentContainerGroupTypeKey()
    for _, c in ipairs(containers) do
        if not ShouldSkipContainerForGroupType(c, groupTypeKey) then
            iterSelectedSpells(c, function(spellId, on)
                if on then set[spellId] = true end
            end)
            -- v62: a single buff's spell is not in selectedSpells any more, but
            -- it is still CLAIMED -- the buff renders in the single buff's own
            -- container, so it must not also appear in the regular buff display
            -- (the 12.1 mirror of this is cfg.generalExclude in
            -- GetContainerBuffConfig). Spec-gated, so on a spec the condition
            -- excludes the spell falls back to the regular display.
            --
            -- Deliberately does NOT read _fbsSingleBuffSpell: this function is
            -- called from outside EnsureFetchBuffSettings and must not depend on
            -- that table being built, so it evaluates the gate from the
            -- container itself.
            --
            -- v65: a single buff's spell is ALWAYS claimed on 12.1 -- the aura
            -- is served by a dedicated sb<key> group inside the buffs
            -- container, so the general "main" group must be told to keep its
            -- hands off it or the same aura matches twice. (On 12.0.7 a
            -- Buffs-anchored entry was exempt, because there the regular row
            -- was where it rendered.)
            --
            -- v67: 12.0.7 branch removed (addon is 12.1-only). The claim test
            -- was `singleBuffHidden or <flag> or not IsSingleBuffBuffsAnchored`,
            -- i.e. unconditionally true here, so both the hidden-entry override
            -- and the Buffs-anchored exemption are gone.
            local sbSid = BF:GetSingleBuffSpellID(c)
            if sbSid and BF:IsSingleBuffSpecMet(c) then
                set[sbSid] = true
            end
        end
    end

    -- Spells explicitly set to untracked
    if assign then
        for sid, val in pairs(assign) do
            if val == "untracked" then set[sid] = true end
        end
    end

    -- DEFAULT_UNTRACKED spells not promoted to "default"
    if defaultUntracked then
        for sid in pairs(defaultUntracked) do
            if not assign or assign[sid] ~= "default" then
                set[sid] = true
            end
        end
    end

    claimedSpellCache    = set
    claimedSpellCacheKey = key
    return set
end

-- ============================================================
-- ICON POOL  (one pool per container index, keyed on frame)
-- ============================================================

local function ensureContainerIconPool(frame, containerIndex, count)
    if not frame.SF_CustomContainerIcons then
        frame.SF_CustomContainerIcons = {}
    end
    local pool = frame.SF_CustomContainerIcons[containerIndex]
    if not pool then
        pool = {}
        frame.SF_CustomContainerIcons[containerIndex] = pool
    end

    -- +223: the v56 "+200 native-overlay lift" band (dot+grids +223) — the
    -- text/icon band sits at +216..221 on every client, so aura icons must
    -- ride the lifted band too. This creator was missed by v56 (stayed +23),
    -- burying custom-container icons under text/status icons.
    local level = frame:GetFrameLevel() + 223

    -- MakeIcon (~90 lines, mostly duplicating CreateAuraIcon) was deleted as
    -- part of the per-indicator aura-icon refactor. Container icons now use
    -- the shared BF.BuildAuraIconFrame helper, with the container-specific
    -- default border color stamped after construction. Tooltip wiring uses
    -- the buffsAndContainers indicator's EnableFrameTooltips method (custom
    -- containers inherit buff tooltip settings — matches pre-refactor
    -- ApplyAuraTooltips:332-344 behavior).
    if #pool + 1 <= count then
        local buffsInd = BF.indicators and BF.indicators.buffsAndContainers
        local atp = BF:GetSectionProfileForFrame("tooltips", frame)
        local enabled = BF.AuraCache.showBuffTooltip or false
        local combat  = BF.AuraCache.showBuffTooltipInCombat or false
        local pos     = atp and atp.buffTooltipPosition or "default"
        local c = BF:GetActiveCustomBuffContainers()[containerIndex]
        for i = #pool + 1, count do
            local icon = BF.BuildAuraIconFrame(frame, level)
            -- Container-specific default border color (matches pre-refactor
            -- MakeIcon behavior — fresh icons don't briefly flash black before
            -- the first display pass re-stamps the border).
            if c then
                BF.SetIconBorderColor(icon, GetContainerDefaultBorderColor(c, nil))
            end
            pool[i] = icon
            if buffsInd then
                buffsInd:EnableFrameTooltips(icon, enabled, combat, pos)
            end
        end
    end

    return pool
end

-- ============================================================
-- CONTAINER POOL PRE-ALLOCATION
--
-- Pre-creates container icon frames out of combat so the display-time
-- growth path in ensureContainerIconPool never runs mid-combat. Pool
-- size is (assignedSpells + 2) per container for the current spec, where
-- assignedSpells = entries in acp.spellAssign[specId] whose value matches
-- "c:<ci>". The +2 pad covers quick reassignments that don't yet flow
-- through InvalidateClaimedSpellCache.
--
-- Called from:
--   1. BuzzardFrame_Init (BFLayout.lua) after frame:CreateIndicators
--      runs the per-indicator :Create methods (BuffsAndContainers,
--      DebuffIcons, etc.). Handles per-frame initial allocation.
--   2. BF:InvalidateClaimedSpellCache (below). Re-runs on spec change,
--      settings edits, and spellAssign edits to cover pools that grew
--      their assigned-count.
--
-- Mirrors Grid2's IndicatorIcons Icon_Layout pattern: build the full
-- icon set during the out-of-combat Layout pass, never during Update.
-- ============================================================
function BF:PreallocateContainerPools(frame)
    if not frame then return end
    if InCombatLockdown() then return end
    local specId = self.playerSpecID
    if not specId then return end
    local containers = self:GetActiveCustomBuffContainers()
    if not containers or #containers == 0 then return end

    -- 2026-09-14 (owner ruling): a multi-icon buff container's content is the
    -- Buff List entries ANCHORED to it, so its pool is sized from those --
    -- the entries whose Spec condition is met, counted under every anchor
    -- the entry carries (the shared tier and each per-Layout tier), the same
    -- layout-agnostic read CollectAnchoredContainerKeys makes. The legacy
    -- spellAssign "c:<ci>" count is gone with the assignment model.
    local byKey = {}
    local function countInto(v)
        local k = type(v) == "string" and v:match("^C:(.+)$")
        if k then byKey[k] = (byKey[k] or 0) + 1 end
    end
    for i = 1, #containers do
        local sb = containers[i]
        if type(sb) == "table" and sb.singleBuff
           and self:GetSingleBuffSpellID(sb) and self:IsSingleBuffSpecMet(sb) then
            countInto(sb.anchorPoint)
            if type(sb.groupSettings) == "table" then
                for _, gs in pairs(sb.groupSettings) do
                    if type(gs) == "table" then countInto(gs.anchorPoint) end
                end
            end
        end
    end

    for ci = 1, #containers do
        local c = containers[ci]
        local count = 0
        if type(c) == "table" and not c.singleBuff and c.containerKey then
            count = byKey[c.containerKey] or 0
        end
        -- v62: a single buff has no spellAssign entry, so the count above is
        -- always 0 for one. It holds exactly one spell by construction.
        if count == 0 and self:GetSingleBuffSpellID(containers[ci]) then
            count = 1
        end
        -- v74: skip the BF-side icon pool too for a creation-irrelevant
        -- container (e.g. a spec-excluded single buff). Same predicate the
        -- engine-container creation sites use, so both pools agree.
        if count > 0 and self:IsContainerCreationRelevant("buff", ci) then
            -- A single-buff container displays exactly ONE icon by
            -- construction (c.singleBuff → engine maxIcons clamped to 1 in
            -- ResolveContainerGeometry since v74; reassignment only changes
            -- WHICH spell renders into pool[1]). The +2 pad below exists for
            -- multi-spell containers, whose displayed set can outrun a stale
            -- spellAssign count mid-edit — padding a single buff allocated 2
            -- unreachable widgets per container per frame. The display-time
            -- ensureContainerIconPool call remains the growth backstop.
            if containers[ci].singleBuff then
                ensureContainerIconPool(frame, ci, 1)
            else
                ensureContainerIconPool(frame, ci, count + 2)
            end
        end
    end
end

-- ============================================================
-- OFFSET CALCULATION
-- ============================================================
-- containerOffsetCache and InvalidateContainerOffsetCache are declared above
-- (near CLAIMED SPELL LOOKUP) so that InvalidateClaimedSpellCache can reference them.

local function CalcContainerOffsets(size, spacing, rowSpacing, perRow, growDir, anchor)
    -- v61 BUGFIX: normalize to the two-axis form BEFORE anything else.
    --
    -- This function used to compare growDir against the single-axis strings
    -- "RIGHT"/"LEFT"/"UP"/"DOWN" by exact equality. But the container Grow
    -- Direction dropdown offers ONLY two-axis values ("RIGHT_DOWN",
    -- "DOWN_LEFT", ...), and the Anchor Point setter writes
    -- BF.GROW_DEFAULT_FOR_ANCHOR[anchor], also two-axis. So any container whose
    -- grow direction or anchor had ever been changed matched none of the four
    -- tests, got stepX = stepY = 0, and drew every icon on top of slot 1. Only
    -- an untouched new container worked, because creation seeds the single-axis
    -- "RIGHT". The two-axis rollout reached the regular buff offsets and never
    -- reached this copy.
    --
    -- Normalizing is appearance-preserving for the single-axis values that DID
    -- work: NormalizeGrowDirection derives the secondary axis with the same
    -- anchor rule the wrap branch below used to apply inline (TOP anchors wrap
    -- down, others up; RIGHT anchors wrap left, others right).
    --
    -- Normalize before building the cache key so "LEFT" and "LEFT_UP" collapse
    -- to one entry instead of caching the same geometry twice.
    growDir = BF.NormalizeGrowDirection(growDir or "RIGHT_DOWN", anchor) or "RIGHT_DOWN"
    if not perRow or perRow < 1 then perRow = 1 end
    local key = size .. "|" .. spacing .. "|" .. rowSpacing .. "|" .. perRow .. "|" .. growDir .. "|" .. anchor
    local cached = containerOffsetCache[key]
    if cached then return cached end

    local function AnchorNudge(a)
        local pm = BF:PixelsToUI(1)
        local x = a:find("LEFT") and pm or a:find("RIGHT") and -pm or 0
        local y = a:find("TOP")  and -pm or a:find("BOTTOM") and pm or 0
        return x, y
    end

    local offsets = {}
    local rSize    = BF:PixelRound(size)
    local rSpacing = BF:PixelRound(spacing)
    local rRowSp   = BF:PixelRound(rowSpacing)
    local primaryStep = rSize + rSpacing
    local wrapStep    = rSize + rRowSp
    -- Primary axis fills the row/column; secondary axis is where the next
    -- row/column goes. Same derivation as the regular buff offsets.
    local prim, sec = growDir:match("^(%u+)_(%u+)$")
    if not prim then prim, sec = "RIGHT", "DOWN" end
    local stepX = (prim == "RIGHT" and primaryStep) or (prim == "LEFT" and -primaryStep) or 0
    local stepY = (prim == "UP"    and primaryStep) or (prim == "DOWN" and -primaryStep) or 0
    local wrapX = (sec == "RIGHT" and wrapStep) or (sec == "LEFT" and -wrapStep) or 0
    local wrapY = (sec == "UP"    and wrapStep) or (sec == "DOWN" and -wrapStep) or 0
    local nx, ny = AnchorNudge(anchor)
    for i = 1, 10 do
        local slot  = i - 1
        local major = slot % perRow
        local minor = math_floor(slot / perRow)
        offsets[i] = {
            x = major * stepX + minor * wrapX + nx,
            y = major * stepY + minor * wrapY + ny,
        }
    end
    containerOffsetCache[key] = offsets
    return offsets
end

-- ============================================================
-- DISPLAY: UPDATE CUSTOM BUFF CONTAINERS FOR ONE FRAME
-- ============================================================
local canaccessvalue = canaccessvalue or function(v) return true end

-- Resolve duration/font/swipe settings for a container.
-- Returns a flat table of resolved values. Called once per container per frame.
local DEFAULT_FONT = "Interface\\AddOns\\BuzzardFrames\\Media\\Fonts\\RobotoCondensed-Bold.ttf"
local DEFAULT_FONT_COLOR = { r = 1, g = 1, b = 1 }
-- v42: Duration settings are now per-spell, not per-container. This
-- function always returns the global/buff baseline from AuraCache.
-- Per-spell overrides are resolved in ResolveSpellCooldownText() and
-- applied in SetupNewIcon.
local function ResolveDurationSettings(auraCache)
    local ac = auraCache or BF.AuraCache
    return ac.showBuffDuration,
           ac.buffAutoScale,
           ac.buffTimerScale or 1.0,
           ac.buffFontSize or 11,
           ac.buffDurationFont or DEFAULT_FONT,
           ac.buffDurationBorder or "OUTLINE",
           ac.disableBuffSwipe,
           ac.disableBuffSpark,
           ac.reverseBuffSwipe,
           ac.buffFontColor or DEFAULT_FONT_COLOR
end

-- ============================================================
-- PER-SPELL COOLDOWN TEXT RESOLUTION (v42)
-- Resolves and caches per-spell cooldown text overrides. Returns
-- a table with the resolved duration fields + threshold curve,
-- or nil if no per-spell override is active for this spell.
-- Called from SetupNewIcon and the same-aura fast path.
-- ============================================================
-- Forward-declared here; the authoritative wipe lives in
-- InvalidateContainerSettingsCache (defined later).
local _spellCooldownTextCache = {}  -- [sid][groupTypeKey or 0] = result|false

-- v62 (plan 3.67 slice 2): `sbC` is an optional single-buff CONTAINER. Passed
-- only from the Layout-time styling of that container's own group, never from a
-- per-aura path. The cache key becomes the ENTRY's stable identity rather than
-- the spell ID, because two single buffs of one spell may hold different
-- cooldown-text settings and a spellId-keyed cache would alias them.
local function ResolveSpellCooldownText(sid, groupTypeKey, ac, sbC)
    if not sid or not BF.GetSpellCooldownText or not canaccessvalue(sid) then return nil end
    local gKey = groupTypeKey or 0  -- 0 sentinel for nil groupTypeKey
    local cacheKey = sbC and ("sb:" .. tostring(sbC.singleBuffKey) .. ":" .. sid) or sid
    local sidCache = _spellCooldownTextCache[cacheKey]
    if sidCache then
        local cached = sidCache[gKey]
        if cached ~= nil then
            return cached ~= false and cached or nil
        end
    else
        sidCache = {}
        _spellCooldownTextCache[cacheKey] = sidCache
    end

    local gs, entry = BF.GetSpellCooldownText(sid, groupTypeKey, sbC)
    if not entry then
        sidCache[gKey] = false
        return nil
    end

    -- Resolve fields with gs → entry → AuraCache baseline fallback.
    -- "ac" provides the same global/buff values that ResolveDurationSettings
    -- returns, so any field the user hasn't explicitly set on this spell
    -- inherits the baseline rather than a hardcoded default. The ac
    -- parameter (stamped on ctx by BuildAuraGroupCtx / EnsureContainerSettings)
    -- routes CFG frames to their per-CFG _auraCache, so CFG-only baseline
    -- overrides apply correctly. Falls back to BF.AuraCache for safety
    -- (e.g. preview-render call paths that don't pass an ac).
    local s = gs or entry
    ac = ac or BF.AuraCache

    local function boolField(field, acVal)
        local v = s[field]
        if v == nil and s ~= entry then v = entry[field] end
        if v ~= nil then return v end
        return acVal
    end

    local showDur = boolField("showDuration", ac.showBuffDuration)
    local autoSc  = boolField("autoScale",    ac.buffAutoScale)
    local swipeDis  = boolField("disableSwipe", ac.disableBuffSwipe)
    local sparkDis  = boolField("disableSpark", ac.disableBuffSpark)
    local revSwipe  = boolField("reverseSwipe", ac.reverseBuffSwipe)
    local colorAuraBorder = boolField("colorAuraBorder", ac.buffColorAuraBorder)

    local timerScale     = s.timerScale or entry.timerScale or ac.buffTimerScale or 1.0
    local fontSize       = s.fontSize or entry.fontSize or ac.buffFontSize or 11
    local rawFont        = s.durationFont or entry.durationFont or ac.buffDurationFont
    local durationFont   = BF:ResolveFontPathOr(rawFont, DEFAULT_FONT)
    local durationBorder = s.durationBorder or entry.durationBorder or ac.buffDurationBorder or "OUTLINE"
    local fontColor      = s.fontColor or entry.fontColor or ac.buffFontColor or DEFAULT_FONT_COLOR

    -- Build threshold curve
    local expCurve, colorBorder, curveHides
    local hideAbove1Min = boolField("hideDurationAbove1Min", false)
    local threshEn = s.thresholdColorEnabled
    if threshEn == nil and s ~= entry then threshEn = entry.thresholdColorEnabled end
    if threshEn then
        local t1 = s.thresholdColorThreshold or entry.thresholdColorThreshold or 8
        local c1 = s.thresholdColor or entry.thresholdColor or BF.DEFAULT_THRESHOLD_COLOR
        local t2En = s.threshold2ColorEnabled
        if t2En == nil and s ~= entry then t2En = entry.threshold2ColorEnabled end
        t2En = t2En == true
        -- v92: fallback 4, NOT 5 -- it must match what the Cooldown Text
        -- subtab's Secondary Threshold slider DISPLAYS when nothing is
        -- stored (Options_AuraCustomizations.lua shows `or 4`). AceConfig
        -- only writes on change, so a user who enables the secondary
        -- threshold and keeps the shown value never stores it; with the
        -- old 5 here the text turned red one second before the slider
        -- said it would. (The container-level Duration Text tier keeps
        -- its 5 -- its widgets and seeds both say 5, so it is
        -- self-consistent.)
        local t2 = s.threshold2ColorThreshold or entry.threshold2ColorThreshold or 4
        local c2 = s.threshold2Color or entry.threshold2Color or BF.DEFAULT_THRESHOLD2_COLOR
        if BF._BuildThresholdColorCurve then
            expCurve = BF._BuildThresholdColorCurve(t1, c1, t2En, t2, c2, fontColor, hideAbove1Min)
        end
        colorBorder = colorAuraBorder == true
        curveHides = hideAbove1Min
    elseif hideAbove1Min then
        -- No threshold coloring, but hideAbove1Min is on: build a minimal curve
        -- that hides text above 60s using the font color below.
        -- v86 PERF: was an inline CreateColorCurve, i.e. a fresh object every
        -- call. ButtonSpecSig folds tostring(spec.durationCurve) into the
        -- button-spec signature, so a fresh address meant the signature could
        -- never match and the restyle walk ran every pass. The memoised
        -- builder returns the same object for the same color.
        expCurve = BF._BuildHideAbove1MinCurve and BF._BuildHideAbove1MinCurve(fontColor)
        if expCurve then curveHides = true end
    end

    local result = {
        showDur        = showDur ~= false,
        autoScale      = autoSc == true,
        timerScale     = timerScale,
        fontSize       = fontSize,
        durationFont   = durationFont,
        durationBorder = durationBorder,
        swipeDis       = swipeDis == true,
        sparkDis       = sparkDis == true,
        revSwipe       = revSwipe == true,
        fontColor      = fontColor,
        colorAuraBorder = colorAuraBorder == true,
        expCurve       = expCurve,
        colorBorder    = colorBorder or false,
        curveHides     = curveHides or false,
        needsCurve     = expCurve ~= nil,
    }
    sidCache[gKey] = result
    return result
end
-- Expose for BuffIcons (default container) per-spell cooldown text support.
BF.ResolveSpellCooldownText = ResolveSpellCooldownText

-- Resolve the effective settings source for a container + group type.
-- When the per-Layout tier is active for this scope and a groupSettings
-- entry exists for the given groupTypeKey, fields from that entry take
-- priority over the container top-level fields. This runs once per cache
-- miss, not per frame.
--
-- v65: the gate is BF:IsContainerPerLayoutActive, the two-gate model -- this
-- container's own perLayoutConfig flag (the Layout axis) OR, for a CFG scope,
-- that group's per-subtab override flag (the group axis).
-- subcat (optional, default "buffs"): pass "debuffs" for custom debuff
-- containers. It selects the GROUP axis only -- a debuff container on a CFG
-- scope must consult overrideAurasDebuffs, so reading it through the Buffs
-- flag here would make every per-Layout debuff edit silently inert whenever
-- the two override flags disagree.
local function ResolveGroupSource(c, groupTypeKey, subcat)
    if groupTypeKey and BF:IsContainerPerLayoutActive(groupTypeKey, c, subcat) then
        local gs = c.groupSettings and c.groupSettings[groupTypeKey]
        if gs then return gs end
    end
    return nil
end

-- ── v92: THE FLOW-ANCHOR SENTINEL PREDICATE ────────────────────────────────
-- An anchorPoint that is NOT a frame point but "flow inside that host's icons".
-- Four values: "BUFFS" (the regular buff row), "BIGDEF" (Big Defensive),
-- "C:<containerKey>" (any multi-icon buff container) and "DEBUFFS" (a debuff
-- container inside the regular debuff row).
--
-- ONE predicate so no site re-lists the sentinels: any of these reaching
-- SetPoint is the crash class this exists to prevent (see the note below).
-- A plain function, not a method -- it takes no state and options closures call
-- it as BF.IsFlowAnchorValue(v).
function BF.IsFlowAnchorValue(v)
    if v == "BUFFS" or v == "BIGDEF" or v == "DEBUFFS" then return true end
    return type(v) == "string" and v:find("^C:") ~= nil
end

-- Interned host descriptors. The two fixed hosts are shared singletons and the
-- "C:<key>" ones are cached per key (below), so the resolver allocates NOTHING
-- steady-state -- it runs per frame per pass.
--
-- Callers READ these; nothing may mutate a returned descriptor.
local HOST_BUFFS  = { kind = "buffs"  }
local HOST_BIGDEF = { kind = "bigDef" }

-- ── v65 / v92: THE flow-anchor resolver ────────────────────────────────────
-- "BUFFS" was the tenth value of a Single Buff's Anchor Point dropdown and is
-- not a frame anchor at all: it means "do not position independently; flow
-- inside the regular Buffs display". v92 generalizes that to any HOST -- Big
-- Defensive or a named multi-icon buff container -- so the question stopped
-- being a boolean and became "which host, if any".
--
-- Returns nil (the entry positions itself), or a host descriptor:
--   { kind = "buffs"  }
--   { kind = "bigDef" }
--   { kind = "bfc", key = "c_3", ci = <index in customBuffContainers> }
--
-- Resolution is per-Layout, through the same ResolveGroupSource tier
-- ResolveContainerGeometry uses, so an entry can flow into Big Defensive on
-- raid and float on party -- unchanged from how "BUFFS" has always worked.
--
-- Deliberately NOT folded into ResolveContainerGeometry's anchor return: that
-- value is handed to SetPoint, and none of these are points. Callers must test
-- this FIRST and skip the geometry path entirely.
--
-- Engine-agnostic by design. On 12.0.7 a Buffs-anchored entry resolves just the
-- same, and the two callers there use it to STAND ASIDE -- see the note in
-- EnsureFetchBuffSettings.
--
-- An unresolvable "C:<key>" answers HOST_BUFFS rather than nil or a crash: the
-- delete path rewrites those references in the DB (RemoveCustomBuffContainer),
-- so this only catches a reference that never passed through it -- a profile
-- imported from another character, say -- and the Buffs row is the one host
-- that always exists.
function BF:GetSingleBuffAnchorHost(c, groupTypeKey)
    if type(c) ~= "table" or not c.singleBuff then return nil end
    local gs = ResolveGroupSource(c, groupTypeKey)
    local v  = (gs and gs.anchorPoint ~= nil) and gs.anchorPoint or c.anchorPoint
    if v == "BUFFS"  then return HOST_BUFFS  end
    if v == "BIGDEF" then return HOST_BIGDEF end
    local key = type(v) == "string" and v:match("^C:(.+)$")
    if not key then return nil end
    local _, ci = self:FindBuffContainerByKey(key)
    if not ci then return HOST_BUFFS end
    local cache = _containerHostCache
    if not cache then
        cache = {}
        _containerHostCache = cache
    end
    local h = cache[key]
    if h then
        -- The cached table outlives a ci shift only because the memo it was
        -- built from is invalidated on the same events; refresh the field
        -- anyway rather than hand back a stale index for one pass.
        h.ci = ci
        return h
    end
    h = { kind = "bfc", key = key, ci = ci }
    cache[key] = h
    return h
end

-- v92 back-compat wrapper. Behavior is IDENTICAL to the v65 boolean: true only
-- for "BUFFS", so a "BIGDEF" / "C:<key>" entry answers FALSE -- which is why
-- every v65 call site was converted to the resolver individually rather than
-- left on this: "not Buffs-anchored" and "positions itself" stopped being the
-- same statement the moment a second host existed.
--
-- No in-tree caller is left after that conversion. Kept deliberately (plan
-- §0.3): it is the exact question the Buffs row itself asks -- "is this entry
-- MINE" -- and the cheapest correct spelling of it for anything added later.
function BF:IsSingleBuffBuffsAnchored(c, groupTypeKey)
    local h = self:GetSingleBuffAnchorHost(c, groupTypeKey)
    return (h ~= nil and h.kind == "buffs")
end

-- ── v92: THE Debuffs-anchor predicate (the debuff twin) ────────────────────
-- "DEBUFFS" on a custom DEBUFF container means "do not position independently;
-- flow inside the regular Debuffs display", at each claimed preset's Debuff
-- Category Priority position. Same v65 contract as the buff side: the value is
-- NOT a frame point, ResolveContainerGeometry returns it raw, and every caller
-- must test THIS FIRST and skip the geometry path entirely -- reaching SetPoint
-- with it is the crash class BF.IsFlowAnchorValue exists to name.
--
-- Deliberately NOT routed through GetSingleBuffAnchorHost: that resolver hard-
-- gates on c.singleBuff (a debuff container is never one) and resolves the
-- BUFFS subcat. The per-Layout tier here must pass subcat "debuffs" --
-- IsContainerPerLayoutActive reads overrideAurasDebuffs on a CFG scope, so
-- asking through the Buffs flag would make every per-Layout debuff anchor edit
-- silently inert whenever the two override flags disagree (the same trap
-- ResolveGroupSource's own comment documents).
--
-- There is one host and no key, so this stays a BOOLEAN -- no host descriptor,
-- nothing to intern, nothing to invalidate.
function BF:IsDebuffContainerDebuffsAnchored(c, groupTypeKey)
    if type(c) ~= "table" then return false end
    -- Defensive: single buffs live in the BUFF array and can never be handed to
    -- this, but "DEBUFFS" must never resolve true for one if they are.
    if c.singleBuff then return false end
    local gs = ResolveGroupSource(c, groupTypeKey, "debuffs")
    if gs and gs.anchorPoint ~= nil then return gs.anchorPoint == "DEBUFFS" end
    return c.anchorPoint == "DEBUFFS"
end

-- The entry's Order (rank among Buffs-anchored single buffs), or nil for None.
--
-- Read straight from c.sbVisuals rather than through GetSingleBuffVisualEntry:
-- that accessor returns nil when singleBuffCustomized == false, which is the
-- right gate for VISUALS but not for flow position. An entry in "Show (Default
-- Buff)" mode still occupies a place in the row and the user still set it.
function BF:GetSingleBuffOrder(c)
    if type(c) ~= "table" then return nil end
    local sid = self:GetSingleBuffSpellID(c)
    if not sid then return nil end
    local fam = c.sbVisuals and c.sbVisuals.specSpellOrdering
    local map = fam and fam[BF.SINGLE_BUFF_VISUAL_KSPEC or "sb"]
    local e   = map and map[sid]
    if e == nil then return nil end
    if type(e) == "number" then return e end          -- legacy plain-number shape
    if type(e) == "table" then
        if e.enabled == false then return nil end
        return e.slot
    end
    return nil
end

-- "BEFORE" (default) or "AFTER", through the per-Layout tier.
function BF:GetSingleBuffRelativeOrder(c, groupTypeKey)
    if type(c) ~= "table" then return "BEFORE" end
    local gs = ResolveGroupSource(c, groupTypeKey)
    local v = (gs and gs.sbRelativeOrder) or c.sbRelativeOrder
    return v == "AFTER" and "AFTER" or "BEFORE"
end

-- v61: THE single container-geometry resolver. Everything that needs a
-- container's effective size / icon count / spacing / anchor reads it
-- through here, so the per-Layout override lookup and the
-- inherit-from-Buffs toggle live in exactly ONE place. They used to be
-- re-derived at four sites with three different scopes, and the 12.1
-- indicator's copy never consulted groupSettings at all -- per-Layout
-- container GEOMETRY was silently dropped on that engine path while the
-- legacy path always honored it (see Docs/Containers_Into_Buffs_Section_Plan.md
-- sections 0.5 and 0.6).
--
-- Fallback order per field: groupSettings[groupTypeKey] -> container top
-- level -> the Buffs baseline on the caller's aura cache -> hard default.
-- The per-Layout tier is gated by ResolveGroupSource, which as of v65 asks
-- BF:IsContainerPerLayoutActive -- the CONTAINER's own perLayoutConfig flag on
-- either scope kind, plus that group's own override flag for Custom Frame
-- Group frames. Either one on means the tier is active.
--
-- containerUsesBuffSettings (nil == true) governs size, maxIcons, spacing
-- and rowSpacing: when it is on, those four come straight from the Buffs
-- baseline. perRow is ALWAYS per-field inherit -- nil means "follow the
-- Buffs value" whatever the toggle says.
--
-- Returns multiple values and allocates nothing: this runs once per
-- container per frame Layout, and once per EnsureContainerSettings cache
-- miss. It must never be reached from BuffsAndContainers:Update.
--
-- growDirection is returned RAW and with no Buffs tier. The two engine
-- paths disagree about normalization (the 12.1 grid wants the two-axis
-- form, the legacy CalcContainerOffsets matches single-axis strings), so
-- normalizing here would change one of them; each caller does its own.
-- kind (optional, default "buff"): "debuff" makes the inherit branch read the
-- Debuffs baseline (ac.debuff*) and the containerUsesDebuffSettings toggle
-- instead of the Buffs baseline. Container-own fields keep the buffSize/
-- maxBuffs/buffsPerRow/spacing/rowSpacing names for both kinds -- only the
-- inherited baseline differs (see CreateCustomDebuffContainer).
function BF:ResolveContainerGeometry(c, groupTypeKey, ac, kind)
    ac = ac or BF.AuraCache
    local isDebuff = (kind == "debuff")
    -- Kind-appropriate Buffs/Debuffs baseline off the aura cache.
    local baseRounded  = isDebuff and ac._roundedDebuffSize or ac._roundedBuffSize
    local baseSize     = isDebuff and ac.debuffSize     or ac.buffSize
    local baseMax      = isDebuff and ac.maxDebuffs     or ac.maxBuffs
    local baseSpacing  = isDebuff and ac.debuffSpacing  or ac.buffSpacing
    local baseRowSpace = isDebuff and ac.debuffRowSpacing or ac.buffRowSpacing
    local basePerRow   = isDebuff and ac.debuffsPerRow  or ac.buffsPerRow
    local baseAnchor   = isDebuff and ac.debuffAnchor   or ac.buffAnchor
    local baseOffX     = isDebuff and ac.debuffOffsetX  or ac.buffOffsetX
    local baseOffY     = isDebuff and ac.debuffOffsetY  or ac.buffOffsetY
    local hardAnchor   = isDebuff and "BOTTOMLEFT" or "BOTTOMRIGHT"
    local hardGrow     = isDebuff and "RIGHT" or "LEFT"
    local gs = ResolveGroupSource(c, groupTypeKey, isDebuff and "debuffs" or nil)
    local s  = gs or c
    local useBuff
    if isDebuff then
        useBuff = s.containerUsesDebuffSettings
        if useBuff == nil then useBuff = c.containerUsesDebuffSettings end
    else
        useBuff = s.containerUsesBuffSettings
        if useBuff == nil then useBuff = c.containerUsesBuffSettings end
    end
    useBuff = useBuff ~= false  -- nil == inherit from the section settings
    -- v65: a single buff in "Show (Default Buff)" mode has NO size of its own.
    -- Default means "draw like an ordinary buff", and an icon that inherits
    -- everything except its size is not that. Its Icon subtab -- where the size
    -- control lives -- is hidden in this mode for the same reason.
    --
    -- Enforced HERE, at the one resolver every engine and both preview paths
    -- read geometry through, rather than by rewriting stored data: switching
    -- back to Show (Customized Buff) then restores whatever size the entry had,
    -- instead of silently discarding it the first time Default was selected.
    -- That also repairs entries created before the Buffs anchor existed, which
    -- were seeded containerUsesBuffSettings = false.
    if c.singleBuff and c.singleBuffCustomized == false then
        useBuff = true
    end
    local size, maxIcons, spacing, rowSpacing
    if useBuff then
        -- _roundedBuffSize/_roundedDebuffSize is the section size already
        -- pixel-snapped by UpdateDB — reuse it rather than re-round.
        size       = baseRounded or BF:PixelRound(baseSize or 12)
        maxIcons   = baseMax or 8
        spacing    = baseSpacing or 1
        rowSpacing = baseRowSpace or 0
    else
        size       = BF:PixelRound(s.buffSize or c.buffSize or baseSize or 12)
        maxIcons   = s.maxBuffs   or c.maxBuffs   or baseMax       or 8
        spacing    = s.spacing    or c.spacing    or baseSpacing    or 1
        rowSpacing = s.rowSpacing or c.rowSpacing or baseRowSpace or 0
    end
    -- v74 PERF: a single buff holds exactly ONE spell by construction, but a
    -- "Show (Default Buff)" entry inherits the section's Max Buffs (typically
    -- 8) as its maxIcons -- and the engine pre-creates that many fully-styled
    -- AuraButtons per frame at AddAuraGroup. Clamp at THIS resolver so every
    -- consumer agrees automatically: the creation site (EnsureBuffContainers)
    -- and the per-Layout re-push (ApplyAuraGridGeometry's unconditional
    -- SetAuraGroupMaxFrameCount, which would otherwise stomp a creation-only
    -- clamp straight back to geo.maxIcons) both flow through geo.maxIcons.
    -- The sb<key> single-buff GROUPS already use maxFrameCount = 1 -- this
    -- makes the single-buff CONTAINER match them.
    if c.singleBuff then maxIcons = 1 end
    return size, maxIcons, spacing, rowSpacing,
           s.buffsPerRow   or c.buffsPerRow   or basePerRow or 3,
           s.anchorPoint   or c.anchorPoint   or baseAnchor  or hardAnchor,
           s.offsetX       or c.offsetX       or baseOffX or 0,
           s.offsetY       or c.offsetY       or baseOffY or 0,
           s.growDirection or c.growDirection or hardGrow
end

-- ── v93: per-preset MAX DEBUFFS ──────────────────────────────────────────
-- Every debuff TYPE owns its icon cap, and owns it wherever its icons render:
-- the main Debuffs row, or a container that claimed it. One slider per row on
-- the Debuff Preset/Filter subtab (owner ruling 2026-08-20); the container-
-- level "Max Icons" slider was removed from debuff containers in the same
-- ruling, because a container is only ever those same types.
--
-- Stored in the DEBUFFS profile alongside the row's Show and Relative Size
-- (debuffMax<Row>), mirrored into the aura cache by both UpdateDB blocks.
BF.DEBUFF_TYPE_MAX_DEFAULT = 3

-- Priority-list row id -> its profile key. The row ids are DEBUFF_TYPES' ids
-- plus "other" (the primary group), which is the row list exactly.
local DEBUFF_TYPE_MAX_KEY = {
    boss       = "debuffMaxBoss",
    role       = "debuffMaxRole",
    cc         = "debuffMaxCC",
    dispMe     = "debuffMaxDispMe",
    dispOthers = "debuffMaxDispOthers",
    priority   = "debuffMaxPriority",
    other      = "debuffMaxOther",
}

-- Container PRESET key -> the same row. A debuff container holds nothing but
-- the types on the Preset/Filter tab (owner, 2026-08-20: "the containers only
-- contain the debuff types listed on the preset/filter tab"), so a container's
-- preset group is that type rendered somewhere else -- and takes that type's
-- Max Debuffs with it, exactly as Relative Size and Maximum Duration already
-- travel. That is why removing the container-level Max Icons slider loses
-- nothing: this is where its cap comes from now.
BF.DEBUFF_PRESET_TO_TYPE = {
    meDispellable     = "dispMe",
    othersDispellable = "dispOthers",
    priority          = "priority",
    boss              = "boss",
    role              = "role",
    crowdControl      = "cc",
}

-- ac is the aura cache (both mirror blocks stamp these keys); passing it in
-- keeps this off BF.AuraCache when a caller holds a per-frame cache.
--
-- v95 (owner ruling 2026-08-25): the ENGINE never sees 0. A stored Max of 0
-- is BF's own "this group is off" sentinel (Simple Mode, Dispellable by Me),
-- consumed by ResolveDebuffShape through DebuffTypeMaxIsOff below; every
-- engine-facing consumer of this function (group creation, the own-max
-- re-point, container preset caps) gets the value clamped to 1 so a parked
-- group still carries a legal, non-zero maxFrameCount.
function BF:ResolveDebuffTypeMax(ac, id)
    local key = id and DEBUFF_TYPE_MAX_KEY[id]
    if not key then return BF.DEBUFF_TYPE_MAX_DEFAULT end
    ac = ac or BF.AuraCache
    local v = ac and ac[key]
    if v == nil then return BF.DEBUFF_TYPE_MAX_DEFAULT end
    if v < 1 then return 1 end
    return v
end

-- The raw stored Max for a type, nil when unset. The sentinel test lives on
-- this, never on ResolveDebuffTypeMax (which clamps).
function BF:DebuffTypeMaxIsOff(ac, id)
    local key = id and DEBUFF_TYPE_MAX_KEY[id]
    if not key then return false end
    ac = ac or BF.AuraCache
    return (ac and ac[key]) == 0
end

-- The container-preset entry point (ApplyPresetGroups' presetMaxPerCategory).
function BF:ResolveDebuffPresetMax(ac, pkey)
    return self:ResolveDebuffTypeMax(ac, pkey and BF.DEBUFF_PRESET_TO_TYPE[pkey])
end

-- ── v64: container PRESETS ────────────────────────────────────────────────
-- A preset is a container entry backed by a Blizzard FILTER TOKEN rather than
-- a spell ID: "show whatever the server classifies as Important here". Stored
-- as a set on the container, c.presets[key] = true.
--
-- These are real server-side categories with no client-side aura property to
-- test (Docs/CLAUDE.md), so each one can only be expressed as its own aura
-- group with its own filter string -- which is exactly how the Important and
-- Big Defensive FEATURES already work (ImportantIcons.lua, BigDefIcons.lua
-- ship token-only groups with no candidateFilters at all). That is the
-- existence proof that this shape is legal on 12.1.
--
-- Labels follow Grid2's, which exposes the same tokens
-- (Grid2Options StatusAuras.lua BuffsTranslate) -- with ONE deliberate
-- divergence: Grid2 calls PLAYER "Casted by me" and reserves "Applied by me"
-- for RAID. Owner chose the label "Applied by Me" for the PLAYER token.
--
-- v65: RAID_IN_COMBAT is now offered, per the note this comment used to carry.
-- It is the token the Buffs display has always run on -- nonHealerBuffFilter
-- defaults to "player_raid_combat" == "HELPFUL|PLAYER|RAID_IN_COMBAT" -- so
-- exposing it as a preset is what lets the Buffs display's own filter be
-- expressed in the same vocabulary as everything else, rather than by a
-- separate dropdown two nav sections away. Grid2 calls it "Relevant for your
-- Class"; the label here names the tokens it is built from instead, because it
-- sits next to a plain "Applied by Me" and the difference between the two has
-- to be readable at a glance.
-- v70: `previewIcon` is a representative texture used ONLY by the options
-- preview painter (BF:GetContainerPreviewIcon) so a preset-only container shows
-- a recognizable placeholder icon. It never touches the live render path, which
-- resolves real auras from the server via the filter token.
BF.CONTAINER_PRESETS = {
    important   = { name = "Important",          filter = "HELPFUL|IMPORTANT",           previewIcon = "Interface\\Icons\\Spell_Holy_PowerWordShield" },
    bigdef      = { name = "Big Defensive",      filter = "HELPFUL|BIG_DEFENSIVE",       previewIcon = "Interface\\Icons\\Spell_Holy_PainSupression" },
    externaldef = { name = "External Defensive", filter = "HELPFUL|EXTERNAL_DEFENSIVE",  previewIcon = "Interface\\Icons\\Spell_Holy_GuardianSpirit" },
    appliedbyme = { name = "Applied by Me",      filter = "HELPFUL|PLAYER",              previewIcon = "Interface\\Icons\\Spell_Nature_Rejuvenation" },
}
-- Display order, and the order presets flow in within the container.
BF.CONTAINER_PRESET_ORDER = { "important", "bigdef", "externaldef", "appliedbyme" }

-- ── Custom DEBUFF container presets ────────────────────────────────────────
-- The Add Preset list for debuff containers. Every filter leads with HARMFUL
-- (a bare token like DISPELLABLE is invalid -- the engine requires a polarity
-- base). Dispel semantics are per Blizzard's 12.1 definitions:
--   DISPELLABLE             = the aura has a dispel type of any kind, regardless
--                             of whether anyone can actually dispel it.
--   RAID (with HARMFUL)     = the aura the PLAYER can dispel ("dispellable by
--                             me"). v71: was RAID_PLAYER_DISPELLABLE, which is
--                             actually "someone in the RAID can dispel" (wrong).
--   RAID_PLAYER_DISPELLABLE = the aura someone in the player's RAID can dispel
--                             (NOT me specifically) -- not used for meDispellable.
--   !DISPELLABLE            = the aura has no dispel type.
--
-- Priority/Boss/Role are NOT filter tokens -- they are candidateFilters boolean
-- flags applied to the aura group (the same isPriorityAura/isBossAura/
-- isRoleAura mechanism the main Debuffs display uses for its enlarged groups).
-- nonDispellable ("Regular Debuffs (Non-dispellable)", HARMFUL|!DISPELLABLE)
-- was REMOVED (owner, 2026-08-14). It cannot participate in the claim system:
-- the engine treats opposing filter tokens as an OR-mask, not an AND (the
-- PTR-confirmed HELPFUL|HARMFUL note in ContainerFactory.lua — that "parked"
-- filter matched EVERYTHING), so appending |DISPELLABLE to a main filter that
-- another claim gave |!DISPELLABLE widens it to all debuffs instead of
-- emptying it. A container of it therefore always duplicated the main row.
-- The same view is had by ELIMINATION: claim the dispellable categories into
-- containers and the main Debuffs row is left showing exactly the regular,
-- non-dispellable remainder. GetCustomDebuffContainers prunes the stale
-- preset key from saved profiles.
-- v70: previewIcon — see the note on BF.CONTAINER_PRESETS above. Options
-- preview painter only.
-- v91 (owner ruling 2026-08-17): allDispellable is RETIRED in favour of
-- othersDispellable, mirroring the main row's Dispellable by Me / by Others
-- split. "All dispellable" is now expressible as the two presets side by side,
-- and the split is what lets a container take exactly the arm the user means.
-- GetCustomDebuffContainers migrates + prunes the stale key (see
-- RETIRED_DEBUFF_PRESETS above), the same lazy treatment the removed
-- nonDispellable preset gets.
BF.DEBUFF_CONTAINER_PRESETS = {
    -- v91: both dispel presets share the DISPELLABLE token; the arm is a
    -- CANDIDATE (include/excludeDispelTypes = BF:MyDispelTypes / its
    -- complement), resolved at runtime by ApplyPresetGroups. def.filter is the
    -- fallback/preview value only -- kept in sync.
    meDispellable     = { name = "Dispellable by Me",     filter = "HARMFUL|DISPELLABLE", previewIcon = "Interface\\Icons\\Spell_Shadow_CurseOfTounges" },
    othersDispellable = { name = "Dispellable by Others", filter = "HARMFUL|DISPELLABLE", previewIcon = "Interface\\Icons\\Spell_Frost_FrostBolt02" },
    priority       = { name = "Priority Auras",                     filter = "HARMFUL", candidateFilters = { isPriorityAura = true }, previewIcon = "Interface\\Icons\\Ability_Creature_Poison_06" },
    boss           = { name = "Boss Auras",                         filter = "HARMFUL", candidateFilters = { isBossAura = true },     previewIcon = "Interface\\Icons\\Achievement_Boss_Lichking" },
    role           = { name = "Role Auras",                         filter = "HARMFUL", candidateFilters = { isRoleAura = true },     previewIcon = "Interface\\Icons\\Spell_Shadow_Shadowbolt" },
    -- v69: the old dedicated Crowd Control feature, refolded as a preset. The
    -- CROWD_CONTROL token is the same one the retired CrowdControlIcons
    -- indicator filtered on; the claim (|!CROWD_CONTROL on the main Debuffs
    -- filters) replaces the showCrowdControl-driven noCC append.
    crowdControl   = { name = "Crowd Control",                      filter = "HARMFUL|CROWD_CONTROL",           previewIcon = "Interface\\Icons\\Spell_Nature_Polymorph" },
}
BF.DEBUFF_CONTAINER_PRESET_ORDER = {
    "meDispellable", "othersDispellable", "priority", "boss", "role", "crowdControl",
}

-- ── v65: the BUFFS DISPLAY's own preset list ──────────────────────────────
-- A SEPARATE table from CONTAINER_PRESETS, deliberately. These are the values
-- of the retired Filter Mode dropdowns -- healer (specBuffFilter) and
-- non-healer (nonHealerBuffFilter) offered the same five, the healer one plus
-- a "whitelist" mode -- carried over so the Buffs display can express exactly
-- what those dropdowns could. Owner decision: whitelist is NOT carried over;
-- it has no meaning in a global, non-per-spec model.
--
-- Not merged into CONTAINER_PRESETS because they are a different KIND of
-- thing. A container preset picks a server-side CATEGORY of buff ("show what
-- the game calls Important here"); these restate the Buffs display's own
-- filter. Offering them on a container would be noise, and offering Important
-- / Big Defensive here would blur what this list is.
--
-- KEYED BY THE OLD STORED VALUES ("player_raid_combat" and friends) rather
-- than by invented names: the key IS the old setting, so the seed in
-- EnsureBuffsPresetsSeeded is literally the value nonHealerBuffFilter
-- defaulted to, and anyone reading a saved variable sees the same token they
-- saw before. LABELS are the old dropdown's labels, verbatim.
-- `none` has NO filter and builds no aura group at all. It means "show nothing
-- here", so the Buffs display falls back to the only other things that render
-- in it: Single Buffs anchored to Buffs, and the per-spell groups. It exists so
-- "deliberately empty" is a state you can SEE in the list and attach a Spec
-- condition to, instead of being indistinguishable from "not set up yet".
BF.BUFFS_PRESETS = {
    none                = { name = "No Preset - Whitelist Only",         filter = nil },
    helpful_player      = { name = "Helpful | Player",                   filter = "HELPFUL|PLAYER" },
    player_raid         = { name = "Helpful | Player | Raid",            filter = "HELPFUL|PLAYER|RAID" },
    player_raid_combat  = { name = "Helpful | Player | Raid_In_Combat",  filter = "HELPFUL|PLAYER|RAID_IN_COMBAT" },
    helpful_raid        = { name = "Helpful | Raid",                     filter = "HELPFUL|RAID" },
    helpful_raid_combat = { name = "Helpful | Raid_In_Combat",           filter = "HELPFUL|RAID_IN_COMBAT" },
}
BF.BUFFS_PRESET_ORDER = {
    "none",
    "helpful_player", "player_raid", "player_raid_combat",
    "helpful_raid", "helpful_raid_combat",
}

-- ── v65: ONE global preset, with ROLE and SPEC overrides ──────────────────
-- Deliberately the same shape as Role/Spec Layouts (Options_Layouts.lua +
-- BF:ResolveActiveFlat), because it answers the same question and users should
-- only have to learn it once:
--
--     buffsDisplay.globalPreset            = "<preset key>"
--     buffsDisplay.roleOverrides["TANK"]   = { preset = "<key>", _present = true }
--     buffsDisplay.specOverrides["264"]    = { preset = "<key>", _present = true }
--
-- `_present` marks "this entry exists in the UI" independently of whether it
-- has a value yet -- exactly as the Layouts overrides use it -- so an override
-- can be added and then configured. Spec keys are STRINGS, matching
-- specOverrides.
--
-- PRECEDENCE: spec beats role beats global. Same order as ResolveActiveFlat,
-- and the reason that function is the reference rather than something new.
--
-- Exactly ONE preset applies at a time. That is the change from the earlier
-- set-of-presets model: a filter is a single choice, and combining several was
-- expressive but had no way to say "this one instead of that one on this spec".
BF.BUFFS_DEFAULT_PRESET = "player_raid_combat"

function BF:GetBuffsGlobalPreset()
    local t = self:GetBuffsPresetContainer()
    local k = t and t.globalPreset
    if k and BF.BUFFS_PRESETS[k] then return k end
    return BF.BUFFS_DEFAULT_PRESET
end

-- The preset key in force right now, walking spec -> role -> global.
-- An override with no `preset` set yet falls through, so adding one and not
-- configuring it changes nothing.
function BF:ResolveBuffsPreset()
    local t = self:GetBuffsPresetContainer()
    if not t then return BF.BUFFS_DEFAULT_PRESET end

    local specIDStr = self.playerSpecID and tostring(self.playerSpecID)
    if specIDStr and t.specOverrides then
        local e = t.specOverrides[specIDStr]
        if type(e) == "table" and e._present and e.preset
           and BF.BUFFS_PRESETS[e.preset] then
            return e.preset
        end
    end

    -- Same role resolution as ResolveActiveFlat, including its fallback to the
    -- spec's own role when the group has not assigned one.
    local role = UnitGroupRolesAssigned and UnitGroupRolesAssigned("player") or "NONE"
    if role == "NONE" or role == "" then role = self.playerSpecRole or "NONE" end
    if t.roleOverrides then
        local e = t.roleOverrides[role]
        if type(e) == "table" and e._present and e.preset
           and BF.BUFFS_PRESETS[e.preset] then
            return e.preset
        end
    end

    return self:GetBuffsGlobalPreset()
end

-- ── v65: the BUFFS DISPLAY as a pseudo-container ──────────────────────────
-- The Buffs display is not an entry in customBuffContainers -- it is the
-- engine's own "buffs" container -- so it has no container table to hang
-- c.presets on. It gets a standalone one instead.
--
-- That is all ApplyPresetGroups needs: it reads c.presets off its argument and
-- nothing else, so handing it this table makes preset groups work on the Buffs
-- display with ZERO changes to that function.
--
-- Storage is acDB.profile, i.e. ONE set for the whole profile -- not
-- per-Layout and not per-spec. Owner decision: the Buffs filter is a global
-- setting. (Contrast every geometry field on the Buffs tab, which IS
-- per-Layout. The options UI says so where the presets are edited.)
--
-- Deliberately NOT a real container: adding it to customBuffContainers would
-- shift every container index, and index shifts are what spellAssign "c:N",
-- the bfc<ci> engine keys and the delete-renumbering loop are all keyed on.

-- Seed the default preset ONCE per profile.
--
-- Lives here, in the accessor's path, rather than only in migration 58,
-- because the dbVersion dispatcher is the one route that does NOT cover every
-- profile: Core_DB's OnNewProfile stamps a brand-new profile straight at
-- DB_VERSION so the whole dispatcher is skipped. A migration-only seed would
-- therefore leave every profile created from here on with no presets -- and on
-- 12.1 that means a completely empty buff row, because the "everything else"
-- group is parked. Profile copy and reset have the same hole.
--
-- One mechanism, one flag, every route: new profiles, resets, copies and
-- upgrades all seed exactly once. After that first pass the flag is what makes
-- "the user deliberately removed every preset" survive -- without it, an empty
-- list would be re-seeded on the next access and a preset could never be
-- removed.
--
-- The seed OVERWRITES whatever is there, rather than only filling an empty
-- list. That is what applies the new default to everyone, including profiles
-- carrying keys from an earlier build of this feature -- those keys are no
-- longer in BF.BUFFS_PRESETS, so they render nothing and would otherwise leave
-- the display permanently empty with no way back.
--
-- The flag NAME is therefore load-bearing: bump it whenever the default has to
-- be re-applied to profiles that already ran an older seed.
--
-- NOT an AceDB default: defaults re-merge on every load, so a removed preset
-- would come back.
-- 2026-08-15: TWO independent seeds, each with its OWN flag. They must not
-- share one, because bumping a shared flag to deliver the second seed would
-- re-run the first and reset every user's chosen Global Preset.
local function EnsureBuffsPresetsSeeded(p)
    if not p then return end
    local t = p.buffsDisplay
    if type(t) ~= "table" then t = {}; p.buffsDisplay = t end

    -- Seed 1 (v65): the Global Preset itself.
    if not p._buffsPresetsV65b then
        p._buffsPresetsV65b = true
        -- Literally the value nonHealerBuffFilter defaulted to. The Buffs preset
        -- keys ARE the old Filter Mode values, so the default is a straight
        -- carry-over of the previous one rather than a translation of it.
        t.globalPreset = BF.BUFFS_DEFAULT_PRESET
        -- Retired shapes from earlier builds of this feature, cleared so nothing
        -- reads them later: `presets` was a SET of simultaneously-active presets
        -- before the model became one global value plus overrides.
        t.presets = nil
        p._buffsPresetsSeededV65 = nil
    end

    -- Seed 2 (2026-08-15): healers and Augmentation default to the "none"
    -- preset, which makes the Whitelist the source of truth for those specs.
    --
    -- This replaces the retired per-spec filter key. That key stored a Filter
    -- Mode per healer/aug spec and forced Resto Shaman and Resto Druid to
    -- "whitelist", because HELPFUL|PLAYER|RAID_IN_COMBAT does not return weapon
    -- imbues or passive buffs. Selecting the "none" preset expresses the same
    -- intent for every one of those specs, through the mechanism that is
    -- actually still read.
    --
    -- TWO entries, not nine (owner decision): the HEALER role override covers
    -- all seven healer specs, and Augmentation Evoker needs its own spec
    -- override because its role is DAMAGER, so the role arm never sees it.
    -- Known gap, accepted: ResolveBuffsPreset resolves the role from
    -- UnitGroupRolesAssigned("player") (falling back to the spec's own role),
    -- so a healer ASSIGNED to a DPS slot in a group falls through the role
    -- override to the Global Preset.
    --
    -- Seeded only where the user has no entry of their own -- an existing table
    -- means a deliberate choice, including one deliberately set to something
    -- other than "none". `_present` is what makes an override visible and
    -- editable in the overrides tree, so both entries show up in the UI.
    if not p._buffsHealerNoneOverridesSeeded then
        p._buffsHealerNoneOverridesSeeded = true
        t.roleOverrides = t.roleOverrides or {}
        if type(t.roleOverrides.HEALER) ~= "table" then
            t.roleOverrides.HEALER = { preset = "none", _present = true }
        end
        t.specOverrides = t.specOverrides or {}
        -- 1473 = Augmentation Evoker. String key: ResolveBuffsPreset indexes
        -- specOverrides with tostring(playerSpecID), and the options tree
        -- writes string keys too.
        if type(t.specOverrides["1473"]) ~= "table" then
            t.specOverrides["1473"] = { preset = "none", _present = true }
        end
    end
end
BF.EnsureBuffsPresetsSeeded = EnsureBuffsPresetsSeeded

function BF:GetBuffsPresetContainer()
    local p = self.acDB and self.acDB.profile
    if not p then return nil end
    EnsureBuffsPresetsSeeded(p)
    local t = p.buffsDisplay
    if type(t) ~= "table" then t = {}; p.buffsDisplay = t end
    return t
end

-- ── v64: per-container BORDER ─────────────────────────────────────────────
-- Same shape and the same two tiers as ResolveContainerGeometry above: read
-- the per-Layout groupSettings source when that tier is active, else the
-- container top level, and fall back to the Buffs section's cache.
--
-- containerUsesBuffBorder (nil == true) is a SIBLING of
-- containerUsesBuffSettings, not an extension of it. That toggle is labeled
-- "Use Buffs Icon Size/Spacing" and governs exactly size / maxIcons / spacing /
-- rowSpacing; widening it to cover border too would silently re-point four
-- existing settings for anyone who had turned it off. Direct polarity, like its
-- sibling: true or absent means inherit.
--
-- Before v64 a container's border was ALWAYS the Buffs section's, with no
-- opt-out -- BuffButtonSpec reads ac.buff* and takes no container argument at
-- all. Inheriting by default preserves that exactly.
--
-- Returns style, color, thickness, blizzardBorders. `blizzardBorders` is
-- derived from the style rather than stored separately, matching BorderStyleOf
-- in ContainerFactory: the two-key representation (style + boolean) only exists
-- in the aura sections for backwards compatibility with pre-style profiles.
-- kind (optional, default "buff"): "debuff" reads the containerUsesDebuffBorder
-- toggle and the Debuffs border baseline (ac.debuffBorder*).
function BF:ResolveContainerBorder(c, groupTypeKey, ac, kind)
    ac = ac or BF.AuraCache
    local isDebuff = (kind == "debuff")
    -- Explicit branch, NOT `isDebuff and X or Y`: that idiom falls through to
    -- the BUFF value whenever the debuff one is false or nil (debuffBlizzardBorders
    -- = false, debuffBorderStyle/Color unset), silently cross-wiring the kinds.
    local baseStyle, baseColor, baseThick, baseBlizz
    if isDebuff then
        baseStyle, baseColor, baseThick, baseBlizz =
            ac.debuffBorderStyle, ac.debuffBorderColor,
            ac.debuffBorderThickness, ac.debuffBlizzardBorders
    else
        baseStyle, baseColor, baseThick, baseBlizz =
            ac.buffBorderStyle, ac.buffBorderColor,
            ac.buffBorderThickness, ac.buffBlizzardBorders
    end
    local gs = ResolveGroupSource(c, groupTypeKey, isDebuff and "debuffs" or nil)
    local s  = gs or c
    local useBuff
    if isDebuff then
        useBuff = s.containerUsesDebuffBorder
        if useBuff == nil then useBuff = c.containerUsesDebuffBorder end
    else
        useBuff = s.containerUsesBuffBorder
        if useBuff == nil then useBuff = c.containerUsesBuffBorder end
    end
    if useBuff ~= false then
        return baseStyle, baseColor, baseThick, baseBlizz
    end
    local style = s.borderStyle or c.borderStyle
    local color = s.borderColor or c.borderColor or baseColor
    -- `or` chain is safe for thickness despite 0 being a valid value: 0 is
    -- truthy in Lua, so an explicit 0 wins and only nil falls through.
    local thick = s.borderThickness
    if thick == nil then thick = c.borderThickness end
    if thick == nil then thick = baseThick end
    return style, color, thick, (style == "blizzard")
end

-- ── v68: per-container DURATION TEXT ──────────────────────────────────────
-- The third inherit toggle alongside ResolveContainerGeometry /
-- ResolveContainerBorder. Returns the SAME result-table shape that
-- ResolveSpellCooldownText returns (so ApplyContainerDuration can stamp it onto
-- a button spec identically), but sourced from the container's own duration
-- fields instead of a per-spell entry.
--
-- WHY container-level duration exists at all: pre-v42 containers carried their
-- own duration fields; migration 42 relocated them to a per-spell store. But on
-- 12.1 the per-spell store is gated by IsCust(), which returns false, so per-
-- spell duration is dead for ordinary container auras -- their text came ONLY
-- from the section baseline, with no per-container control. This resolver
-- revives the container's own duration fields (still seeded on every container)
-- as a live layer sitting UNDER the (currently-dead) per-spell tier and OVER the
-- section baseline. When the per-spell tier revives, it still wins via the
-- ResolveSpellCooldownText call that runs after this in the spec builder.
--
-- containerUsesBuffDurationSettings / containerUsesDebuffDurationSettings
-- (nil == inherit) gates it. When INHERITING this returns nil: the base spec
-- (BuffButtonSpec / the debuff container base spec) already carries the section
-- baseline duration, so there is nothing to override and the inherit path -- the
-- default for every existing container -- stays a guaranteed no-op. When NOT
-- inheriting, unset container fields still fall back to the section baseline
-- (effective-baseline pattern), matching the per-spell Cooldown Text subtab so
-- untouched fields track the section live.
--
-- kind (optional, default "buff"): "debuff" reads the debuff toggle + baseline.
function BF:ResolveContainerDuration(c, groupTypeKey, ac, kind)
    ac = ac or BF.AuraCache
    local isDebuff = (kind == "debuff")

    local gs = ResolveGroupSource(c, groupTypeKey, isDebuff and "debuffs" or nil)
    local s  = gs or c
    local useBase
    if isDebuff then
        useBase = s.containerUsesDebuffDurationSettings
        if useBase == nil then useBase = c.containerUsesDebuffDurationSettings end
    else
        useBase = s.containerUsesBuffDurationSettings
        if useBase == nil then useBase = c.containerUsesBuffDurationSettings end
    end
    -- nil == inherit: leave the base spec's duration untouched.
    if useBase ~= false then return nil end

    -- Section baseline field set (by kind), used as the per-field fallback for
    -- any container duration field the user never explicitly set.
    -- Explicit branch, NOT `isDebuff and X or Y`: half of these are booleans
    -- (showDebuffDuration = false would have read showBuffDuration) and the
    -- rest are nilable (an unset debuff font would have read the buff font).
    local bShow, bAuto, bTimer, bSize, bFont, bBorder, bColor, bSwipe, bSpark, bRev
    if isDebuff then
        bShow, bAuto   = ac.showDebuffDuration, ac.debuffAutoScale
        bTimer, bSize  = ac.debuffTimerScale, ac.debuffFontSize
        bFont, bBorder = ac.debuffDurationFont, ac.debuffDurationBorder
        bColor         = ac.debuffFontColor
        bSwipe, bSpark, bRev = ac.disableDebuffSwipe, ac.disableDebuffSpark, ac.reverseDebuffSwipe
    else
        bShow, bAuto   = ac.showBuffDuration, ac.buffAutoScale
        bTimer, bSize  = ac.buffTimerScale, ac.buffFontSize
        bFont, bBorder = ac.buffDurationFont, ac.buffDurationBorder
        bColor         = ac.buffFontColor
        bSwipe, bSpark, bRev = ac.disableBuffSwipe, ac.disableBuffSpark, ac.reverseBuffSwipe
    end

    -- Own settings: read the container field (per-Layout source, then top level)
    -- with an effective-baseline fallback for any field the user never set.
    local function ownBool(field, baseVal)
        local v = s[field]
        if v == nil and s ~= c then v = c[field] end
        if v ~= nil then return v end
        return baseVal
    end
    local function ownVal(field, baseVal)
        local v = s[field]
        if v == nil and s ~= c then v = c[field] end
        if v == nil then return baseVal end
        return v
    end

    local showDur   = ownBool("showDuration", bShow)
    local autoSc    = ownBool("autoScale",    bAuto)
    local swipeDis  = ownBool("disableSwipe", bSwipe)
    local sparkDis  = ownBool("disableSpark", bSpark)
    local revSwipe  = ownBool("reverseSwipe", bRev)
    local colorAB   = ownBool("colorAuraBorder", false)
    local timerScale   = ownVal("timerScale", bTimer) or 1.0
    local fontSize     = ownVal("fontSize", bSize) or 11
    local rawFont      = ownVal("durationFont", bFont)
    local durationFont = BF:ResolveFontPathOr(rawFont, DEFAULT_FONT)
    local durationBdr  = ownVal("durationBorder", bBorder) or "OUTLINE"
    local fontColor    = ownVal("fontColor", bColor) or DEFAULT_FONT_COLOR

    -- Threshold color curve, built from the container's own threshold fields.
    local expCurve, colorBorder, curveHides
    local hideAbove1Min = ownBool("hideDurationAbove1Min", false) == true
    local threshEn = s.thresholdColorEnabled
    if threshEn == nil and s ~= c then threshEn = c.thresholdColorEnabled end
    if threshEn then
        local t1  = ownVal("thresholdColorThreshold", 8) or 8
        local c1  = ownVal("thresholdColor", BF.DEFAULT_THRESHOLD_COLOR)
        local t2En = s.threshold2ColorEnabled
        if t2En == nil and s ~= c then t2En = c.threshold2ColorEnabled end
        t2En = t2En == true
        local t2  = ownVal("threshold2ColorThreshold", 5) or 5
        local c2  = ownVal("threshold2Color", BF.DEFAULT_THRESHOLD2_COLOR)
        if BF._BuildThresholdColorCurve then
            expCurve = BF._BuildThresholdColorCurve(t1, c1, t2En, t2, c2, fontColor, hideAbove1Min)
        end
        colorBorder = colorAB == true
        curveHides = hideAbove1Min
    elseif hideAbove1Min then
        -- v86 PERF: was an inline CreateColorCurve, i.e. a fresh object every
        -- call. ButtonSpecSig folds tostring(spec.durationCurve) into the
        -- button-spec signature, so a fresh address meant the signature could
        -- never match and the restyle walk ran every pass. The memoised
        -- builder returns the same object for the same color.
        expCurve = BF._BuildHideAbove1MinCurve and BF._BuildHideAbove1MinCurve(fontColor)
        if expCurve then curveHides = true end
    end

    return {
        showDur        = showDur ~= false,
        autoScale      = autoSc == true,
        timerScale     = timerScale,
        fontSize       = fontSize,
        durationFont   = durationFont,
        durationBorder = durationBdr,
        swipeDis       = swipeDis == true,
        sparkDis       = sparkDis == true,
        revSwipe       = revSwipe == true,
        fontColor      = fontColor,
        colorAuraBorder = colorAB == true,
        expCurve       = expCurve,
        colorBorder    = colorBorder or false,
        curveHides     = curveHides or false,
        needsCurve     = expCurve ~= nil,
    }
end

-- ── v71: per-container DISPEL-TYPE ICON ───────────────────────────────────
-- Returns (nil) when inheriting -- the caller keeps the section baseline already
-- on the spec. Otherwise returns (on, scale): the container's own toggle + size %.
-- v89: no longer its own inherit toggle. It now follows the container's BORDER
-- inherit flag (containerUsesDebuffBorder, "Use Debuffs Border"), so one toggle
-- governs border style/color/thickness AND the dispel-type icon + dispel border
-- color together. Debuff-only (no buff analogue).
function BF:ResolveContainerDispelTypeIcon(c, groupTypeKey, ac)
    ac = ac or BF.AuraCache
    local gs = ResolveGroupSource(c, groupTypeKey, "debuffs")
    local s  = gs or c
    local useBase = s.containerUsesDebuffBorder
    if useBase == nil then useBase = c.containerUsesDebuffBorder end
    if useBase ~= false then return nil end  -- inherit: keep the section baseline
    local on = s.dispelTypeIcon
    if on == nil then on = c.dispelTypeIcon end
    if on == nil then on = ac.showDebuffDispelTypeIcon == true end
    local scale = s.dispelTypeIconScale
    if scale == nil then scale = c.dispelTypeIconScale end
    if scale == nil then scale = ac.debuffDispelTypeIconScale or 40 end
    return on and true or false, scale
end

-- ── v71: per-container COLOR BORDER BY DISPEL TYPE ────────────────────────
-- Returns nil when inheriting (caller keeps the section baseline), else the
-- container's own boolean. v89: follows the container's BORDER inherit flag
-- (containerUsesDebuffBorder, "Use Debuffs Border") rather than a toggle of its
-- own. Debuff-only.
function BF:ResolveContainerColorBorderByDispel(c, groupTypeKey, ac)
    ac = ac or BF.AuraCache
    local gs = ResolveGroupSource(c, groupTypeKey, "debuffs")
    local s  = gs or c
    local useBase = s.containerUsesDebuffBorder
    if useBase == nil then useBase = c.containerUsesDebuffBorder end
    if useBase ~= false then return nil end  -- inherit: keep the section baseline
    local on = s.colorBorderByDispel
    if on == nil then on = c.colorBorderByDispel end
    if on == nil then on = ac.debuffColorBorderByDispel ~= false end
    return on and true or false
end

-- ── v92: per-container EFFECTS (debuff containers) ────────────────────────
-- Two resolvers behind the container's "Effects" group, both the same two-tier
-- read as ResolveContainerBorder / ResolveContainerDuration / the two dispel
-- resolvers above: the per-Layout groupSettings source when that tier is active
-- (subcat "debuffs" -- a debuff container on a CFG scope must consult
-- overrideAurasDebuffs, see ResolveGroupSource), then the container top level,
-- then the documented default. READ-ONLY: nothing here creates or writes a
-- groupSettings entry.
--
-- Storage is sparse and nil-based like every other container field -- nil means
-- "never set", which is why each field falls through rather than being seeded.
--
-- Defaults are interned module tables holding the SAME VALUES as the Icon
-- Effects options page's own literals (IE_DEFAULT_COLOR / IE_DEFAULT_PANDEMIC,
-- file-locals in Options_AuraCustomizations.lua) -- separate tables, not shared
-- references; the two files never see each other's locals. Keep the numbers in
-- step by hand if either moves.
--
-- Color tables come back BY REFERENCE, exactly as ResolveContainerBorder
-- returns its color: callers READ them, copy what they need onto a spec, and
-- never mutate. An interned default reaching a retained spec by reference is
-- the bug class this contract exists to prevent -- see the copy in
-- BF.ApplyIconEffectToSpec (AuraCustomizationHelpers.lua).
local CFX_DEFAULT_COLOR    = { r = 1, g = 0.82, b = 0.25, a = 1 }
local CFX_DEFAULT_PANDEMIC = { r = 0.239216, g = 1, b = 0.254902, a = 0.15 }
-- No dispel color to inherit for a whole container (the section's dispel
-- colors are per debuff TYPE), so the frame effect starts at plain red.
local CFX_DEFAULT_FRAME_COLOR = { r = 1, g = 0, b = 0, a = 0.5 }

-- The container's Icon Effect, in EXACTLY the shape BF.ApplyIconEffectToSpec
-- consumes (AuraCustomizationHelpers.lua) -- so the container path stamps a
-- spec through the same one function the per-spell path does and the two
-- cannot drift on what a stored entry means.
--
-- nil when the effect is none or unset, which is the common case and the cheap
-- one: the caller then touches the spec at all only when there IS an effect.
--
-- desaturate / recolor are deliberately absent: they are per-spell concerns
-- (ApplyIconEffectToSpec simply skips them when the fields are nil).
--
-- The returned table is FRESH per call and belongs to the caller, matching
-- ResolveContainerDuration -- a resolver on the spec-build path, not the
-- per-frame render path.
function BF:ResolveContainerIconEffect(c, groupTypeKey)
    if type(c) ~= "table" then return nil end
    local gs = ResolveGroupSource(c, groupTypeKey, "debuffs")
    local s  = gs or c
    local fx = s.containerIconEffect
    if fx == nil then fx = c.containerIconEffect end
    if fx == nil or fx == "none" then return nil end
    local style = s.containerIconEffectGlowStyle
    if style == nil then style = c.containerIconEffectGlowStyle end
    local color = s.containerIconEffectColor or c.containerIconEffectColor
    -- v93: the container-level Pandemic tint is RETIRED (owner ruling
    -- 2026-08-20) and its two options are gone. Pinned false rather than left
    -- reading the stored key: with no widget left, a profile that had it on
    -- could never turn it off again. containerIconEffectPandemic /
    -- ...PandemicColor stay in SavedVariables and are simply never read --
    -- harmless, and it keeps a downgrade working. The per-SPELL pandemic tint
    -- (ApplyIconEffectToSpec, e.pandemic) is a different feature: untouched.
    return {
        effect        = fx,
        -- nil == steady, so anything that is not "pulse" resolves to steady
        -- rather than being passed through unvalidated.
        glowStyle     = (style == "pulse") and "pulse" or "steady",
        color         = color or CFX_DEFAULT_COLOR,
        pandemic      = false,
    }
end

-- The container's Frame Effect -- the whole-frame counterpart of the icon
-- effect: None / Change Health Color / Show Frame Border / Show Overlay, in one
-- Effect Color.
--
-- nil when none or unset (same cheap common case). Otherwise a fresh
-- { kind, color, borderWidth, overlayHeight, overlayFillOnly } with every
-- default applied, so the consumer never re-derives one.
--
-- borderWidth / overlayHeight fall back to the DISPEL section's effective
-- values (ac.debuffBorderWidth / ac.debuffOverlayHeight) before their literal
-- defaults, the same inherit-then-default chain ResolveContainerDispelTypeIcon
-- uses for its scale. On a factory profile that is exactly 2 and 0.7; on a
-- profile whose dispel border/overlay was resized the container effect matches
-- it instead of standing out at a hardcoded size.
--
-- overlayFillOnly does NOT inherit debuffOverlayFillOnly (which ships true):
-- a container effect the user just switched on should draw the full overlay
-- unless they ask for fill-only, so nil == false.
function BF:ResolveContainerFrameEffect(c, groupTypeKey, ac)
    if type(c) ~= "table" then return nil end
    ac = ac or BF.AuraCache or {}
    local gs = ResolveGroupSource(c, groupTypeKey, "debuffs")
    local s  = gs or c
    local kind = s.containerFrameEffect
    if kind == nil then kind = c.containerFrameEffect end
    if kind == nil or kind == "none" then return nil end
    local color = s.containerFrameEffectColor or c.containerFrameEffectColor
    local w = s.containerFrameEffectBorderWidth
    if w == nil then w = c.containerFrameEffectBorderWidth end
    if w == nil then w = ac.debuffBorderWidth or 2 end
    -- `or` chains are unsafe for the height (0 is a legal value AND truthy, so
    -- it wins correctly, but nil must fall through) -- explicit nil tests, like
    -- ResolveContainerBorder's thickness.
    local h = s.containerFrameEffectOverlayHeight
    if h == nil then h = c.containerFrameEffectOverlayHeight end
    if h == nil then h = ac.debuffOverlayHeight or 0.7 end
    local fillOnly = s.containerFrameEffectOverlayFillOnly
    if fillOnly == nil then fillOnly = c.containerFrameEffectOverlayFillOnly end
    return {
        kind            = kind,
        color           = color or CFX_DEFAULT_FRAME_COLOR,
        borderWidth     = w,
        overlayHeight   = h,
        overlayFillOnly = fillOnly == true,
    }
end

-- Solid icon color poll has been merged into the unified threshold
-- poll in AuraConfig.lua (Grid2 single-timer pattern). Text, border,
-- and solid icon color all share one poll tick per cooldown frame.

-- SetupNewIcon and ApplyExpiringCurves have been removed. All per-icon
-- rendering is now handled by the unified RenderContainerIcons function
-- in Auras/RenderContainerIcons.lua, which uses UpdateCooldownDisplay
-- (with change-guards) instead of bespoke inline cooldown code.

-- Hide icons in a container pool from startIdx onwards (count-based,
-- matches the BuffIcons HideUnusedSlots pattern). Falls back to 1 when
-- startIdx is nil or omitted (hides the entire pool).
-- Exposed on BF as _HideContainerPool for AuraGroupHelpers / RenderAuraGroup.
local function HideContainerPool(frame, ci, clearCaches, startIdx)
    if not frame.SF_CustomContainerIcons then return end
    local pool = frame.SF_CustomContainerIcons[ci]
    if not pool then return end
    local UnregBounce = BF.UnregisterIconForBounce
    local n = #pool
    for idx = (startIdx or 1), n do
        local icon = pool[idx]
        if icon then
            if icon:IsShown() then
                if UnregBounce then UnregBounce(icon) end
                icon:Hide()
            end
            if clearCaches then
                icon.auraInstanceID = nil
                icon.SF_LastIndex   = nil
                icon.cachedSize     = nil
            end
        end
    end
end

-- Hide all container icon pools on a frame.
local function HideAllContainerPools(frame)
    if not frame.SF_CustomContainerIcons then return end
    for ci, pool in pairs(frame.SF_CustomContainerIcons) do
        local n = #pool
        for idx = 1, n do
            local icon = pool[idx]
            if icon and icon:IsShown() then icon:Hide() end
        end
    end
end

-- Expose pool helpers to AuraGroupHelpers + RenderAuraGroup.
BF._HideContainerPool      = HideContainerPool
BF._HideAllContainerPools  = HideAllContainerPools

-- Pooled ctx tables per container index — avoids allocating a new table
-- on every UpdateCustomBuffContainers call. Wiped and repopulated each use.
local _ctxPool = {}

-- Per-container resolved settings cache. Computed once per display cycle
-- (first call after invalidation), reused for all subsequent frames.
-- Invalidated by InvalidateContainerSettingsCache() which is called from
-- InvalidateClaimedSpellCache (spec change, settings change, etc.).
-- Cache key is "ci:groupTypeKey" to support per-group-type container settings.
local _containerSettingsCache = {}  -- [ci][groupTypeKey] = { size, perRow, anchor, ... , ctx = {} }
local _containerSettingsValid = false

InvalidateContainerSettingsCache = function()
    table.wipe(_containerSettingsCache)
    table.wipe(_ctxPool)
    table.wipe(_spellCooldownTextCache)
    _containerSettingsValid = false
    -- Also wipe the per-(ci, groupTypeKey) groupConfig pool used by
    -- the unified BuffsAndContainers indicator. Its canLiftAboveBar
    -- depends on ac.aurasAbovePowerBar and the resolved per-group
    -- anchor, both of which are affected by the same settings that
    -- invalidate _containerSettingsCache.
    if BF.InvalidateAuraGroupConfigPools then
        BF:InvalidateAuraGroupConfigPools()
    end
end
-- Exposed for Options_AuraCustomizations.lua's DebouncedCCRefresh, which
-- uses the minimal invalidation set (this + InvalidateContainerIconCaches)
-- for threshold/color slider + picker edits. Those edits only affect the
-- resolved curves + defaultBorder cached on the ctx, both of which live
-- in _containerSettingsCache and _ctxPool. Wiping these two caches is
-- sufficient to force a re-render with the new values; the other six
-- caches wiped by InvalidateClaimedSpellCache (claimedSpellCache,
-- containerOffsetCache, trackListCache, fetchBuffSettings,
-- activeContainersCache, swiftmendEnabledCache) are not affected by
-- threshold/color edits and wiping them runs PreallocateContainerPools
-- across every active + preview frame, which is what caused slider drag
-- to freeze.
BF.InvalidateContainerSettingsCache = InvalidateContainerSettingsCache

-- CFG-scoped variant: only wipes container settings cache entries belonging to
-- a Custom Frame Group. Main/RP entries (keyed by flat IDs like "flat_party",
-- "flat_raid40") are left intact.
--
-- v61: the key used to be the positional string "cfGroup_<index>", so a
-- `find("^cfGroup_")` was enough to classify it. CFG scopes are now keyed by
-- the CFG flat's opaque cfgFlatID (a stable ID, immune to the index shifting
-- that table.remove causes on group deletion), so classification has to be a
-- real lookup against the group list.
local function InvalidateContainerSettingsCacheCFGOnly()
    -- Two-level tables: [ci][groupTypeKey] for settings/ctx,
    -- [sid][groupTypeKey] for spell cooldown text. Remove only
    -- entries whose groupTypeKey resolves to a CFG flat.
    --
    -- Keys that no longer resolve to any group (its group was deleted) are
    -- also wiped: they can only have come from a CFG frame, and a dead cache
    -- entry is exactly what we want gone.
    local isCFGKey = {}  -- memo per call; the same gKey recurs across ci/sid
    local function classify(gKey)
        local v = isCFGKey[gKey]
        if v ~= nil then return v end
        v = (BF.ResolveCFGFlatByID and BF:ResolveCFGFlatByID(gKey)) and true or false
        if not v then
            -- No live group owns it. RP flat IDs are the "flat_*" namespace and
            -- must survive; anything else in this key space can only have been
            -- minted for a CFG flat whose group has since been deleted, so the
            -- entry is dead and wiping it is correct.
            v = (gKey:find("^flat_") == nil)
        end
        isCFGKey[gKey] = v
        return v
    end
    local function wipeCFGKeys(tbl)
        for outerKey, inner in pairs(tbl) do
            if type(inner) == "table" then
                for gKey in pairs(inner) do
                    if type(gKey) == "string" and classify(gKey) then
                        inner[gKey] = nil
                    end
                end
            end
        end
    end
    wipeCFGKeys(_containerSettingsCache)
    wipeCFGKeys(_ctxPool)
    wipeCFGKeys(_spellCooldownTextCache)
    _containerSettingsValid = false
end
BF.InvalidateContainerSettingsCacheCFGOnly = InvalidateContainerSettingsCacheCFGOnly

local function EnsureContainerSettings(ci, c, buffProfile, groupTypeKey)
    local gKey = groupTypeKey or 0  -- 0 sentinel for nil groupTypeKey
    local ciCache = _containerSettingsCache[ci]
    if not ciCache then
        ciCache = {}
        _containerSettingsCache[ci] = ciCache
    end
    local cached = ciCache[gKey]
    -- Freshness check: the cached entry was built against a specific `ac`
    -- (stamped as cached._ac below). If the caller passes a different
    -- buffProfile, we rebuild. Mirrors the freshness check in
    -- GetContainerGroupConfig (AuraGroupHelpers.lua:266) so a cache key
    -- can't outlive its source aura cache. Self-heals if a prior caller
    -- ever populated the entry with the wrong `ac`.
    if cached and cached._ac == (buffProfile or BF.AuraCache) then
        return cached
    end

    -- v61: one shared resolver (BF:ResolveContainerGeometry) — the
    -- per-Layout lookup and the inherit-from-Buffs toggle used to be
    -- re-derived here on top of ResolveLayoutSettings, which resolved
    -- them already.
    --
    -- Resolution stays at cache-build time rather than per-call: the cache
    -- key [ci][groupTypeKey] already distinguishes CFG frames (each gets a
    -- unique key -- its cfgFlatID as of v61, formerly the positional
    -- "cfGroup_N" -- with its own buffProfile), so one resolve per key
    -- serves every frame in that scope. This is what keeps PixelRound and
    -- the CalcContainerOffsets string-key build off the per-frame path.
    local size, maxIcons, spacing, rowSpacing, perRow, anchor, offX, offY, growDir
        = BF:ResolveContainerGeometry(c, groupTypeKey, buffProfile)
    local showDur, autoScale, timerScale, fontSize, durationFont, durationBorder,
          swipeDis, sparkDis, revSwipe, fontColor = ResolveDurationSettings(buffProfile)
    local baseScale = autoScale and (size / 12 * timerScale) or 1.0

    -- v42: threshold curves are now per-spell (resolved in
    -- ResolveSpellCooldownText). Container baseline uses the buff
    -- curves from the per-frame aura cache (CFG or global).
    local ac = buffProfile or BF.AuraCache
    local expCurve    = ac.expiringCurveBuff
    local colorBorder = ac.buffColorAuraBorder == true

    local ctxCi = _ctxPool[ci]
    if not ctxCi then ctxCi = {}; _ctxPool[ci] = ctxCi end
    local ctx = ctxCi[gKey]
    if not ctx then ctx = {}; ctxCi[gKey] = ctx end
    ctx.expiringCurve    = expCurve
    ctx.colorBorder = colorBorder
    ctx.showDur          = showDur
    ctx.durationFont     = durationFont
    ctx.durationBorder   = durationBorder
    ctx.computedFontSize = autoScale and 11 or fontSize
    ctx.computedFontScale= autoScale and baseScale or 1.0
    ctx.autoScale        = autoScale
    ctx.timerScale       = timerScale
    ctx.fontColor        = fontColor
    ctx.swipeDis         = swipeDis
    ctx.sparkDis         = sparkDis
    ctx.revSwipe         = revSwipe
    ctx.showStacks       = ac.showStackText ~= false
    ctx.stackAutoScale   = ac.stackAutoScale
    ctx.stackTimerScale  = ac.stackTimerScale or 1.0
    ctx.groupTypeKey     = groupTypeKey
    -- v42: default border color always from global/buff baseline.
    do
        local dR, dG, dB, dA = BF.GetDefaultBorderColorFor("buff")
        ctx.defaultBorderR = dR
        ctx.defaultBorderG = dG
        ctx.defaultBorderB = dB
        ctx.defaultBorderA = dA
    end
    -- Per-container SotF gate: true iff this container has an empowerable
    -- spell assigned. Used by RenderContainerIcons (via ctx.sotfCheck) and
    -- the fast path to skip all SotF work for containers that can never
    -- hold an empowerable aura.
    -- Flag is rebuilt by RebuildContainerSotFFlags on every
    -- InvalidateClaimedSpellCache (which also wipes _ctxPool), so the
    -- cached ctx value cannot go stale.
    ctx.sotfCheck        = BF._sotfGlowActive and BF._containerHasSotF[c] == true
    ctx.bounceCheck      = BF._bounceActive == true
    ctx.hasPerSpellOverrides = true  -- custom containers always have per-spell settings
    -- Stamp the aura cache reference so per-spell override resolvers can
    -- pick the right baseline per frame. For custom containers `ac` is
    -- `buffProfile or BF.AuraCache` (see top of EnsureContainerSettings).
    ctx._ac = ac

    local offsets = CalcContainerOffsets(size, spacing, rowSpacing, perRow, growDir, anchor)

    cached = {
        size = size,
        perRow = perRow, anchor = anchor,
        offX = offX, offY = offY, growDir = growDir,
        spacing = spacing, rowSpacing = rowSpacing, maxIcons = maxIcons,
        expCurve = expCurve, colorBorder = colorBorder,
        showDur = showDur,
        ctx = ctx, offsets = offsets,
        _ac = ac,  -- freshness check key for next call (matches top guard)
    }
    ciCache[gKey] = cached
    return cached
end

-- Expose for RenderAuraGroup / AuraGroupHelpers.
BF._GetCachedContainerSettings = EnsureContainerSettings
BF._EnsureContainerIconPool    = ensureContainerIconPool

-- ============================================================
-- BF._LayoutDefaultBuffGroup: stamp font + cooldown config on
-- frame.buffFrames. Replaces the old BuffIcons:Layout body so
-- the unified pipeline calls one entry point per group kind.
-- ============================================================
function BF._LayoutDefaultBuffGroup(frame)
    if not frame.buffFrames then return end
    local ac = BF:GetAuraCacheForFrame(frame)
    for i = 1, #frame.buffFrames do
        local icon = frame.buffFrames[i]
        icon.SF_LastIndex = nil
        if icon.cooldown then
            local cd = icon.cooldown
            -- LOAD-BEARING: dirty the per-spell stamp guard before
            -- writing the baseline cooldown state below.
            --
            -- The baseline writes that follow (SetHideCountdownNumbers,
            -- SetDrawSwipe, font, color, etc.) unconditionally overwrite
            -- whatever the render loop previously stamped for the
            -- spell in this slot. The render loop's per-spell override
            -- branch (RenderContainerIcons.lua, look for
            --   `if cd._bf_sctSpell ~= sid then`)
            -- only re-stamps the override when the spell ID changes,
            -- as an optimization to avoid re-stamping every frame.
            --
            -- Setting `cd._bf_sctSpell = true` (sentinel value, not a
            -- valid spell ID) forces the comparator to fire on the
            -- next render regardless of whether the same spell stays
            -- in the slot. Without it, ANY refresh path that runs
            -- _LayoutDefaultBuffGroup (RefreshBuffsOnly, RefreshAllAuras,
            -- and historically RefreshAllPrivateAuraIcons before it
            -- was scoped) silently corrupts per-spell cooldown-text
            -- overrides: e.g. Renewing Mist's hide-duration-text
            -- override gets clobbered by `not ac.showBuffDuration` and
            -- the comparator's "same spell" guard prevents recovery.
            --
            -- This line is an invariant of the per-spell override
            -- system, NOT a transitional patch. Keep it permanently.
            cd._bf_sctSpell = true
            cd:SetDrawSwipe(not ac.disableBuffSwipe)
            cd:SetDrawEdge(not ac.disableBuffSpark)
            cd:SetReverse(ac.reverseBuffSwipe or false)
            cd:SetHideCountdownNumbers(not ac.showBuffDuration)
            if ac.showBuffDuration and not cd.timerText then
                cd.timerText = cd:GetCountdownFontString()
            end
            local tt = cd.timerText
            if tt then
                local fontPath = ac.buffDurationFont or "Interface\\AddOns\\BuzzardFrames\\Media\\Fonts\\RobotoCondensed-Bold.ttf"
                local autoScale = ac.buffAutoScale
                local bSize = ac._roundedBuffSize or 12
                local fontSize = autoScale and 11 or (ac.buffFontSize or 11)
                local fontBorder = ac.buffDurationBorder or "OUTLINE"
                local timerScale = autoScale and (bSize / 12 * (ac.buffTimerScale or 1.0)) or 1.0
                cd._bf_font   = fontPath
                cd._bf_size   = fontSize
                cd._bf_border = fontBorder
                cd._bf_scale  = timerScale
                tt:SetFont(fontPath, fontSize, fontBorder)
                tt:SetScale(timerScale)
                tt:ClearAllPoints()
                tt:SetPoint("CENTER", cd, "CENTER", 0, 0)
                local fc = ac.buffFontColor
                if fc then
                    cd._bf_textR = fc.r or 1
                    cd._bf_textG = fc.g or 1
                    cd._bf_textB = fc.b or 1
                    cd._bf_textA = fc.a or 1
                    tt:SetTextColor(fc.r or 1, fc.g or 1, fc.b or 1, fc.a or 1)
                else
                    cd._bf_textR = 1
                    cd._bf_textG = 1
                    cd._bf_textB = 1
                    cd._bf_textA = 1
                    tt:SetTextColor(1, 1, 1, 1)
                end
            end
            icon.colorCurveObject = ac.expiringCurveBuff
            icon.colorCurveText   = tt
            icon.colorCurveBorder = (ac.buffColorAuraBorder == true) and true or nil
        end
    end
end

-- ============================================================
-- BF._LayoutContainerGroup: ensure container settings + pool size
-- are ready for the frame. Layout-time entry point invoked by
-- BF:LayoutAuraGroup.
-- ============================================================
function BF._LayoutContainerGroup(frame, groupConfig)
    local ac = BF:GetAuraCacheForFrame(frame)
    local groupTypeKey = BF:ResolveGroupTypeKey(frame)
    local cs = EnsureContainerSettings(groupConfig.containerIndex,
                                       groupConfig.configSource,
                                       ac, groupTypeKey)
    -- Pre-grow the pool to the container's maxIcons so the runtime path
    -- never has to lazy-build inside an Update.
    if cs and cs.maxIcons then
        ensureContainerIconPool(frame, groupConfig.containerIndex, cs.maxIcons)
    end
end

-- BF:UpdateCustomBuffContainers has been removed. Its three external
-- callers (ShowDummyContainerAuras, HideDummyContainerAuras,
-- ShowSingleSpellPreview) now use BF:RenderContainerGroupWithAuras /
-- BF:HideAuraGroup directly. The two indicator callers
-- (BuffIcons, CustomContainers) have been replaced by the unified
-- BuffsAndContainers indicator. See Auras/RenderAuraGroup.lua,
-- Indicators/BuffsAndContainers.lua, and Auras/AuraGroupHelpers.lua.

-- ============================================================
-- SPEC SPELL HEALTH COLORS
-- ============================================================
-- UpdateSpecSpellHealthColors has been removed. All buff-triggered visual
-- effects (health color, border, overlay) are now handled by the unified
-- UpdateBuffHighlight function in LayoutFrame.lua, called once from
-- UpdateStandardAuras after aura display.

-- ============================================================
-- ShowContainerPreviewOnAllFrames
-- Called directly by the Container Management tab trackers.
-- Bypasses the monolithic ShowDummyAuras dispatcher and directly
-- applies container icons to every visible preview frame.
-- ============================================================
function BF:ShowContainerPreviewOnAllFrames()
    if not self._previewContainer or not self._previewContainer:IsShown() then return end
    if not self.db or not self.db.global.showPreview then return end

    local rpDB = self.rpDB
    local fl = rpDB and rpDB.profile and rpDB.profile.layouts
               and rpDB.profile.layouts.flatLayouts or {}

    -- Container Management tab path: fallback ON. The user is explicitly
    -- viewing a container's settings; show its contents using a spec that
    -- has assignments even if their current spec doesn't.
    if self._previewFrames then
        for flatID, f in pairs(self._previewFrames) do
            if f:IsShown() then
                local flat = fl[flatID]
                local isRaid = (flat and flat.type == "raid") or false
                f._bf_containerGroupTypeKey = flatID
                if isRaid then
                    self:ShowDummyContainerAuras(f, true, flat, nil, true)
                else
                    self:ShowDummyContainerAuras(f, false, nil, flat, true)
                end
            end
        end
    end
    if self._previewCFFrames then
        for _, cf in ipairs(self._previewCFFrames) do
            if cf and cf:IsShown() then
                -- v61: stamp the scope key, as the _previewFrames loop above
                -- does. Without it the renderer falls through to
                -- ResolveGroupTypeKey, which finds no isCustomFrame parent
                -- header on a preview frame (its parent is the preview
                -- container), resolves an RP flat ID instead -- and MEMOIZES
                -- it. ClearFrameHeaderDerivedCaches deliberately never clears
                -- the key on preview frames, so that wrong scope stuck until a
                -- full preview refresh happened to overwrite it, making the CF
                -- preview show the active raid/party geometry rather than this
                -- group's.
                cf._bf_containerGroupTypeKey = cf._cfgFlat and cf._cfgFlat.cfgFlatID
                self:ShowDummyContainerAuras(cf, true, cf._cfgFlat, nil, true)
            end
        end
    end
end

-- ============================================================
-- ShowSpellPreviewOnAllFrames
-- Called directly by the per-spell settings tab tracker.
-- Bypasses the monolithic ShowDummyAuras dispatcher and directly
-- applies the single spell preview to every visible preview frame.
-- ============================================================
function BF:ShowSpellPreviewOnAllFrames()
    if not self._previewContainer or not self._previewContainer:IsShown() then return end
    if not self.db or not self.db.global.showPreview then return end

    local rpDB = self.rpDB
    local fl = rpDB and rpDB.profile and rpDB.profile.layouts
               and rpDB.profile.layouts.flatLayouts or {}

    if self._previewFrames then
        for flatID, f in pairs(self._previewFrames) do
            if f:IsShown() then
                local flat = fl[flatID]
                local isRaid = (flat and flat.type == "raid") or false
                f._bf_containerGroupTypeKey = flatID
                if isRaid then
                    self:ShowSingleSpellPreview(f, true, flat, nil)
                else
                    self:ShowSingleSpellPreview(f, false, nil, flat)
                end
            end
        end
    end
    if self._previewCFFrames then
        for _, cf in ipairs(self._previewCFFrames) do
            if cf and cf:IsShown() then
                -- v61: stamp the scope key -- see the matching note in
                -- ShowContainerPreviewOnAllFrames. An unstamped CF preview
                -- frame memoizes an RP flat ID that is never cleared.
                cf._bf_containerGroupTypeKey = cf._cfgFlat and cf._cfgFlat.cfgFlatID
                self:ShowSingleSpellPreview(cf, true, cf._cfgFlat, nil)
            end
        end
    end

    -- If the user is on the Icon Effects subtab, re-apply the dedicated
    -- preview-only glow/bounce to the freshly-rendered icons. The applier
    -- never touches live frames — it walks _previewFrames / _previewCFFrames
    -- only. Live render path knows nothing about this flag.
    if BF._previewIconEffectsActive and BF.PreviewIconEffects_ApplyToAllFrames then
        BF:PreviewIconEffects_ApplyToAllFrames()
    end
end

-- ============================================================
-- DUMMY CONTAINER AURAS FOR SETUP MODE
-- Builds fake aura objects from spellAssign for the current spec
-- and feeds them to UpdateCustomBuffContainers so containers render
-- in setup/test mode with the right icons, position, and duration settings.
-- ============================================================
-- `allowSpecFallback` controls what happens when the current player spec
-- has no container assignments matching the previewing container:
--   true  → fall back to the first healer spec that does have assignments
--           (used by the Container Management tab, which is explicitly
--           a "show me what this container looks like" preview regardless
--           of which spec the player is currently on).
--   false → render nothing for containers (used by the general-auras
--           preview, which should reflect only the current spec's auras
--           — if the spec has no container assignments, no containers
--           should appear in the dummy preview either).
function BF:ShowDummyContainerAuras(frame, isRaid, raidProfile, overridePartyProfile, allowSpecFallback)
    if not frame then if BF._debugContainerPreview then print("|cffff0000[BF ContainerPreview]|r frame is nil") end return end

    local p = self.db and self.db.profile
    local acp = self.acDB and self.acDB.profile
    if BF._debugContainerPreview then
        print("|cff00ff00[BF ContainerPreview]|r ShowDummyContainerAuras called, isRaid=", isRaid, "acp=", acp and "yes" or "NO", "overridePartyProfile=", overridePartyProfile and "yes" or "nil", "allowSpecFallback=", tostring(allowSpecFallback))
    end
    local containers = self:GetActiveCustomBuffContainers()
    if #containers == 0 then if BF._debugContainerPreview then print("|cffff0000[BF ContainerPreview]|r no containers") end return end

    -- Only preview the container the user is currently viewing
    local previewCI = self:GetPreviewContainerIndex()
    if BF._debugContainerPreview then
        print("|cff00ff00[BF ContainerPreview]|r containers=", #containers, "previewCI=", tostring(previewCI), "playerSpecID=", tostring(self.playerSpecID))
    end

    -- Determine which spec to preview. The current player spec is always
    -- preferred. If it has no assignments and the caller permits fallback,
    -- pick the first healer spec that does. If fallback is disallowed and
    -- the current spec has nothing, hide containers entirely.
    local function specHasContainerSpells(sid)
        local assign = acp and acp.spellAssign and acp.spellAssign[sid]
        if not assign then return false end
        for _, val in pairs(assign) do
            if type(val) == "string" then
                local ci = tonumber(val:match("^c:(%d+)$"))
                if ci and (not previewCI or ci == previewCI) then return true end
            end
        end
        return false
    end
    -- v62: single buffs carry their spell on the container and have NO
    -- spellAssign entry, so the spec probe above is structurally blind to them.
    -- Without this a profile whose only in-scope container is a single buff
    -- would bail out and the options preview would show nothing at all.
    -- The spec gate is applied only on the no-fallback path, whose documented
    -- job is "reflect what the current spec would really display"; the
    -- fallback path is explicitly a "show me this container" preview.
    -- `not c.singleBuffHidden` sits OUTSIDE the allowSpecFallback `or`: Hide is
    -- not spec-conditional, so the "show me this container anyway" preview must
    -- respect it too. Without this the options preview was the one place Hide
    -- visibly did nothing -- and the Position subtab drives that very preview,
    -- so it is what the user is looking at when they pick Hide.
    local hasSingleBuffInScope = false
    for ci, c in ipairs(containers) do
        if (not previewCI or ci == previewCI) and self:GetSingleBuffSpellID(c)
           and not c.singleBuffHidden
           and (allowSpecFallback or self:IsSingleBuffSpecMet(c)) then
            hasSingleBuffInScope = true
            break
        end
    end
    local specId = self.playerSpecID
    if not specId or not specHasContainerSpells(specId) then
        if not allowSpecFallback then
            -- General-auras preview path: do not borrow another spec's
            -- containers just to show something. The preview should match
            -- what the current spec would actually display on live frames.
            if not hasSingleBuffInScope then
                if BF._debugContainerPreview then print("|cffff0000[BF ContainerPreview]|r current spec has no container spells; fallback disallowed, hiding") end
                if self.HideDummyContainerAuras then self:HideDummyContainerAuras(frame) end
                return
            end
        else
            specId = nil
            local HEALER_SPECS = BF.HEALER_SPEC_ORDER
            if HEALER_SPECS then
                for _, spec in ipairs(HEALER_SPECS) do
                    if specHasContainerSpells(spec.id) then
                        specId = spec.id
                        break
                    end
                end
            end
        end
    end
    if not specId and not hasSingleBuffInScope then
        -- No spec has spells for this container; clear all container icons
        if BF._debugContainerPreview then print("|cffff0000[BF ContainerPreview]|r no spec has container spells, playerSpec=", tostring(self.playerSpecID)) end
        if self.HideDummyContainerAuras then self:HideDummyContainerAuras(frame) end
        return
    end
    if BF._debugContainerPreview then print("|cff00ff00[BF ContainerPreview]|r using specId=", specId) end

    local spellAssign = acp and acp.spellAssign and acp.spellAssign[specId]

    -- Build a lookup: spellId -> containerIndex from spellAssign for this spec.
    -- When previewing a specific container, only include that container's spells.
    local spellToCI = {}
    if spellAssign then
        for sid, val in pairs(spellAssign) do
            local ci = tonumber(type(val) == "string" and val:match("^c:(%d+)$"))
            if ci and (not previewCI or ci == previewCI) then
                spellToCI[sid] = ci
            end
        end
    end

    if BF._debugContainerPreview then
        local ct = 0; for _ in pairs(spellToCI) do ct = ct + 1 end
        print("|cff00ff00[BF ContainerPreview]|r spellToCI count=", ct)
    end

    -- Build per-container aura lists.
    local fakeDur = 30
    local fakeNow = GetTime()
    local specSpells = BF.SPEC_SPELLS and BF.SPEC_SPELLS[specId] or {}
    local spellEntry = {}
    for _, s in ipairs(specSpells) do
        spellEntry[s.id] = s
    end

    local auraLists = {}
    for ci = 1, #containers do
        auraLists[ci] = {}
    end
    for sid, ci in pairs(spellToCI) do
        if auraLists[ci] then
            local entry = spellEntry[sid]
            local iconPath = (entry and entry.icon)
                or (C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(sid))
            if iconPath then
                local dur = (entry and entry.noDuration) and 0 or fakeDur
                auraLists[ci][#auraLists[ci] + 1] = {
                    spellId        = sid,
                    icon           = iconPath,
                    expirationTime = dur > 0 and (fakeNow + dur) or 0,
                    duration       = dur,
                    auraInstanceID = sid,
                    applications   = 0,
                    _isDummy       = true,
                }
            end
        end
    end

    -- v62: single buffs, from the container's own spell. A separate pass because
    -- spellToCI is a 1:1 sid -> ci map and two single buffs may hold the SAME
    -- spellID -- feeding them through it would silently drop one of the two.
    for ci, c in ipairs(containers) do
        local sbSid = self:GetSingleBuffSpellID(c)
        -- Hide gate outside the allowSpecFallback `or` -- see the matching
        -- note on hasSingleBuffInScope above.
        if sbSid and auraLists[ci] and (not previewCI or ci == previewCI)
           and not c.singleBuffHidden
           and (allowSpecFallback or self:IsSingleBuffSpecMet(c)) then
            local entry = spellEntry[sbSid]
            local iconPath = (entry and entry.icon)
                or (C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(sbSid))
            if iconPath then
                local dur = (entry and entry.noDuration) and 0 or fakeDur
                auraLists[ci][#auraLists[ci] + 1] = {
                    spellId        = sbSid,
                    icon           = iconPath,
                    expirationTime = dur > 0 and (fakeNow + dur) or 0,
                    duration       = dur,
                    auraInstanceID = sbSid,
                    applications   = 0,
                    _isDummy       = true,
                }
            end
        end
    end

    -- Render via the unified primitive. ac comes from the frame (preview
    -- frames stamp _bf_auraCache directly so it already carries the
    -- correct preview-profile geometry).
    local ac = self:GetAuraCacheForFrame(frame)
    local groupTypeKey = frame._bf_containerGroupTypeKey or self:ResolveGroupTypeKey(frame)
    for ci, c in ipairs(containers) do
        local groupConfig = self:GetContainerGroupConfig(c, ci, ac, groupTypeKey)
        local list = auraLists[ci]
        -- v65: a Buffs-anchored single buff has NO container preview -- it
        -- renders inside the regular buff row, which the preview draws from the
        -- Buffs section, not from here.
        --
        -- This is not cosmetic. "BUFFS" is not a frame point, and this path
        -- reaches SetPoint with it: RenderContainerGroupWithAuras ->
        -- RenderAuraGroup (container branch, anchor straight from
        -- ResolveContainerGeometry) -> RenderContainerIcons' icon:SetPoint.
        -- CalcContainerOffsets survives the string (it only does a `find`), so
        -- the error surfaces at SetPoint -- and it fires the instant the user
        -- picks "Buffs" on the Position subtab, because that subtab is what
        -- drives this preview and previewCI is the entry being edited.
        --
        -- v92: the test is ANY flow host, not just Buffs. "BIGDEF" and
        -- "C:<key>" are not frame points either, and they reach this exact
        -- SetPoint the same way -- from the very subtab that offers them.
        -- Whether the host itself previews the entry inline is a separate
        -- question (a later phase's); standing aside here is what keeps the
        -- sentinel out of SetPoint.
        if BF:GetSingleBuffAnchorHost(c, groupTypeKey) ~= nil then
            self:HideAuraGroup(frame, groupConfig)
        elseif list and #list > 0 then
            self:RenderContainerGroupWithAuras(frame, groupConfig, list, specId)
        else
            self:HideAuraGroup(frame, groupConfig)
        end
    end

    -- Attach setup mode tooltips to the visible container icons.
    if BF.SetDummyTooltip and frame.SF_CustomContainerIcons then
        for ci, c in ipairs(containers) do
            local pool = frame.SF_CustomContainerIcons[ci]
            if pool then
                local label = "Setup Mode: Container " .. (c.name or tostring(ci))
                local n = (auraLists[ci] and #auraLists[ci]) or 0
                for idx, icon in ipairs(pool) do
                    if idx <= n then
                        BF.SetDummyTooltip(icon, label)
                    else
                        BF.SetDummyTooltip(icon, nil)
                    end
                end
            end
        end
    end
end

function BF:HideDummyContainerAuras(frame)
    if not frame then return end
    if not frame.SF_CustomContainerIcons then return end
    -- Remove tooltips from all container icons before clearing.
    if BF.SetDummyTooltip then
        for _, pool in pairs(frame.SF_CustomContainerIcons) do
            for _, icon in ipairs(pool) do
                BF.SetDummyTooltip(icon, nil)
            end
        end
    end
    -- Hide every container group's pool via the new primitive.
    local ac = self:GetAuraCacheForFrame(frame)
    local groupTypeKey = frame._bf_containerGroupTypeKey or self:ResolveGroupTypeKey(frame)
    local containers = self:GetActiveCustomBuffContainers()
    for ci, c in ipairs(containers) do
        local groupConfig = self:GetContainerGroupConfig(c, ci, ac, groupTypeKey)
        self:HideAuraGroup(frame, groupConfig)
    end
end

-- ============================================================
-- SINGLE SPELL PREVIEW FOR AURA CUSTOMIZATIONS
-- When the user is viewing a specific spell's settings page in
-- Aura Customizations, show just that one spell on the preview
-- frames. Respects: container assignment, solid icon color,
-- custom border color, buff health bar color, buff frame border,
-- buff overlay, and custom ordering (pin to slot).
-- ============================================================
-- ============================================================
-- v94: PREVIEW FRAME-LEVEL EFFECTS -- the shared painter.
--
-- Extracted verbatim from the tail of ShowSingleSpellPreview, which was the
-- ONLY preview painter for the three frame effects (health tint, frame border,
-- frame overlay) and read the curated acDB tables inline. A single buff stores
-- the same three families in its own container (see the single-buff visual
-- store note in AuraCustomizationHelpers.lua), so the read is now a callback
-- and the painting is shared rather than duplicated.
--
-- `getCfg(family)` returns the config table for "specSpellColors",
-- "specSpellBorders" or "specSpellOverlays", or nil for "no effect of this
-- kind" -- which drives the else-branches that hide the widgets. The CALLER
-- owns every gate (enabled flags, customization checks), because those differ:
-- curated spells gate on IsSpellCustomized, a single buff on its own Display
-- Type via SBRoot.
--
-- `opts.keepDispelBorder` suppresses the border's clear-to-zero. frame.
-- dispelDebuffBorder is SHARED with the dispel simulation (preview frames
-- carry one border widget), and _ShowDummyDispelBorders paints it BEFORE this
-- runs. Without this flag, previewing a buff with no border of its own would
-- blank a dispel highlight the user had deliberately switched on in the Aura
-- Preview dropdown. A configured buff border still wins -- it is painted in
-- the branch above, last.
-- ============================================================
function BF:ApplyPreviewSpellFrameEffects(frame, getCfg, opts)
    if not frame or type(getCfg) ~= "function" then return end
    local keepDispelBorder = opts and opts.keepDispelBorder or false
    -- ── Frame-level effects (buff health bar color, frame border, overlay) ──
    -- These apply regardless of container/default/untracked assignment.

    -- Health bar color tint — always reset to default first, then apply tint
    if frame.healthBar and self.ResetPreviewHealthColor then
        self:ResetPreviewHealthColor(frame)
    end
    local healthColor = getCfg("specSpellColors")
    if healthColor and frame.healthBar then
        local overlay = frame.buffColorOverlay
        if not overlay then
            overlay = BF.Texture(frame.healthBar, nil, "OVERLAY", nil, 0)
            frame.buffColorOverlay = overlay
            -- Rounded border style: clip to the frame's rounded shape.
            BF:AttachFrameRoundMask(frame, overlay)
        end
        -- Match RestampFxHealth: tint a copy of the frame's own health
        -- bar texture rather than laying a flat color block over it, so
        -- a custom bar texture keeps its shading while the tint is up.
        local hp = BF:GetSectionProfileForFrame("healthPower", frame)
        local hbTex = (hp and hp.useCustomHealthBarTexture)
            and BF:ResolveBarTexture(hp.healthBarTexture)
            or "Interface\\Buttons\\WHITE8x8"
        overlay:SetTexture(hbTex)
        overlay:SetVertexColor(healthColor.r, healthColor.g, healthColor.b,
            healthColor.a or 1)
        local hFill = frame.healthBar:GetStatusBarTexture()
        overlay:ClearAllPoints()
        if hFill then
            overlay:SetPoint("TOPLEFT", hFill, "TOPLEFT", 0, 0)
            overlay:SetPoint("BOTTOMRIGHT", hFill, "BOTTOMRIGHT", 0, 0)
        else
            overlay:SetPoint("TOPLEFT", frame.healthBar, "TOPLEFT", 0, 0)
            overlay:SetPoint("BOTTOMRIGHT", frame.healthBar, "BOTTOMRIGHT", 0, 0)
        end
        overlay:Show()
    elseif frame.buffColorOverlay then
        frame.buffColorOverlay:Hide()
    end

    -- Buff frame border
    -- Preview reuses frame.dispelDebuffBorder as the widget for the buff border
    -- (preview frames only have one border widget, and it's repurposed for
    -- whichever aura is being previewed). Apply the per-spell thickness the
    -- same way the live buff-highlight path does for real frames:
    -- resolved thickness = borderCfg.thickness → p.buffBorderWidth → 2.
    --
    -- Without this, preview frames kept whatever thickness the debuff highlight
    -- path or ApplyPreviewHighlights had last applied — typically debuffBorderWidth —
    -- so the user saw the buff border at the debuff thickness regardless of
    -- the per-spell thickness slider.
    --
    -- No local cache here: DebuffHighlight:Layout and ApplyPreviewHighlights
    -- both write to the same widget unconditionally, so a cache on this side
    -- would go stale. ShowSingleSpellPreview runs only on preview refresh
    -- (not per frame), so four SetHeight/SetWidth calls are negligible.
    local borderCfg = getCfg("specSpellBorders")
    if borderCfg and frame.dispelDebuffBorder then
        local pp = self.db and self.db.profile
        local thicknessPx = borderCfg.thickness or (pp and pp.buffBorderWidth) or 2
        local dh = frame.dispelDebuffBorder
        local t = self:PixelsToUI(thicknessPx)
        if dh.top    then dh.top:SetHeight(t)    end
        if dh.bottom then dh.bottom:SetHeight(t) end
        if dh.left   then dh.left:SetWidth(t)    end
        if dh.right  then dh.right:SetWidth(t)   end
        local c = borderCfg.color or { r = 0, g = 1, b = 0 }
        -- Rounded-aware (v54 highlight pattern): ring at the per-spell
        -- thickness when the frame's border style is rounded.
        self:SetHighlightBorder(frame.dispelDebuffBorder, frame, c.r, c.g, c.b, c.a or 1, thicknessPx)
    elseif frame.dispelDebuffBorder and not keepDispelBorder then
        self:SetHighlightBorder(frame.dispelDebuffBorder, frame, 0, 0, 0, 0)
    end

    -- Buff overlay
    -- Mirrors Indicators/BuffsAndContainers.lua RestampFxOverlay: the strip
    -- anchors to the Gradient Direction's strong edge and grows away from it
    -- (vertical directions size by Overlay Height, horizontal by Overlay
    -- Width), and the fill is the direction's baked ramp asset.
    -- Using frame.buffOverlay -- not frame.dispelDebuffOverlay -- so the
    -- preview matches the live render exactly. Reusing dispelDebuffOverlay
    -- here (as we used to) gave a top-down gradient that didn't match.
    local overlayCfg = getCfg("specSpellOverlays")
    if overlayCfg and frame.buffOverlay and frame.healthBar then
        local ov  = frame.buffOverlay
        local hb  = frame.healthBar
        local oc  = overlayCfg.color or { r = 0, g = 1, b = 0 }
        local alpha = BF.FxOverlayAlpha and BF.FxOverlayAlpha(overlayCfg, oc)
            or ((oc and oc.a) or overlayCfg.alpha or 0.5)
        local style = overlayCfg.style or "gradient"
        local dir   = overlayCfg.gradientDir or "topToBottom"
        local horizontal = (dir == "leftToRight" or dir == "rightToLeft")
        local frac = horizontal and (overlayCfg.width or 0.7)
            or (overlayCfg.height or 0.7)
        -- Mirrors RestampFxOverlay: per-direction ramp asset (or the flat
        -- fill for Solid), anchored to the direction's strong edge.
        if BF.ApplyFxFill then
            BF.ApplyFxFill(ov, style, dir, oc.r, oc.g, oc.b, alpha)
        else
            ov:SetVertexColor(oc.r, oc.g, oc.b, 1)
            ov:SetAlpha(alpha)
        end
        local anchorTo = hb
        if overlayCfg.fillOnly then
            anchorTo = hb:GetStatusBarTexture() or hb
        end
        ov:ClearAllPoints()
        if horizontal then
            local edge = (dir == "rightToLeft") and "RIGHT" or "LEFT"
            ov:SetPoint("TOP" .. edge,    anchorTo, "TOP" .. edge,    0, 0)
            ov:SetPoint("BOTTOM" .. edge, anchorTo, "BOTTOM" .. edge, 0, 0)
            ov:SetWidth(hb:GetWidth() * frac)
        else
            local edge = (dir == "bottomToTop") and "BOTTOM" or "TOP"
            ov:SetPoint(edge .. "LEFT",  anchorTo, edge .. "LEFT",  0, 0)
            ov:SetPoint(edge .. "RIGHT", anchorTo, edge .. "RIGHT", 0, 0)
            ov:SetHeight(hb:GetHeight() * frac)
        end
        ov:Show()
    elseif frame.buffOverlay then
        frame.buffOverlay:Hide()
    end
end

function BF:ShowSingleSpellPreview(frame, isRaid, raidProfile, overridePartyProfile)
    if not frame then return end
    local sid    = self:GetPreviewSpellID()
    local specId = self:GetPreviewSpecID()
    if not sid or not specId then
        -- No spell being previewed; clear any lingering frame-level effects
        -- from a previous spell preview, then fall back to normal containers.
        if frame.buffColorOverlay then frame.buffColorOverlay:Hide() end
        if frame.buffOverlay      then frame.buffOverlay:Hide() end
        if frame.dispelDebuffBorder then
            self:SetHighlightBorder(frame.dispelDebuffBorder, frame, 0, 0, 0, 0)
        end
        if frame.healthBar and self.ResetPreviewHealthColor then
            self:ResetPreviewHealthColor(frame)
        end
        -- ShowSingleSpellPreview with no selected spell: fall back to
        -- showing containers as a placeholder. Fallback ON since the user
        -- is in the Custom Auras subtree and the preview should illustrate
        -- container layout even when their current spec has none.
        if self.ShowDummyContainerAuras then
            self:ShowDummyContainerAuras(frame, isRaid, raidProfile, overridePartyProfile, true)
        end
        return
    end

    local p = self.db and self.db.profile
    local acp = self.acDB and self.acDB.profile
    if not p then return end

    -- Look up the spell entry from SPEC_SPELLS for the icon
    local specSpells = self.SPEC_SPELLS and self.SPEC_SPELLS[specId] or {}
    local spellEntry
    for _, s in ipairs(specSpells) do
        if s.id == sid then spellEntry = s; break end
    end

    -- Resolve icon texture
    local iconPath
    if spellEntry and spellEntry.icon then
        iconPath = spellEntry.icon
    else
        iconPath = C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(sid)
    end
    if not iconPath then
        -- Can't resolve an icon; hide containers and bail
        if self.HideDummyContainerAuras then self:HideDummyContainerAuras(frame) end
        return
    end

    -- Determine assignment: container, default, or untracked
    local assign = acp.spellAssign and acp.spellAssign[specId] and acp.spellAssign[specId][sid]
    local containerIndex = nil
    local isUntracked = false
    if assign == "untracked" then
        isUntracked = true
    elseif assign and type(assign) == "string" then
        local n = tonumber(assign:match("^c:(%d+)$"))
        if n then containerIndex = n end
    end
    -- Check DEFAULT_UNTRACKED if no explicit assignment
    if not assign then
        for _, s in ipairs(specSpells) do
            if s.id == sid and s.untracked then
                isUntracked = true
                break
            end
        end
    end

    local fakeNow = GetTime()
    local isPermaBuff = spellEntry and spellEntry.noDuration
    local fakeDur = isPermaBuff and 0 or 30

    -- Build the fake aura object
    local fakeAura = {
        icon           = iconPath,
        duration       = fakeDur,
        expirationTime = isPermaBuff and 0 or (fakeNow + fakeDur),
        applications   = 0,
        auraInstanceID = sid,
        spellId        = sid,
        _isDummy       = true,
    }

    -- The previously-required buffProfile (size, perRow, spacing, etc.)
    -- is no longer built here: preview frames stamp _bf_auraCache directly
    -- (handled by GetAuraCacheForFrame below) so the unified primitive
    -- reads geometry from the same path real frames use. The
    -- raidProfile / overridePartyProfile / isRaid arguments are retained
    -- for signature compatibility with the all-frames dispatcher but are
    -- intentionally unused in this body now.

    local ac = self:GetAuraCacheForFrame(frame)
    local groupTypeKey = frame._bf_containerGroupTypeKey or self:ResolveGroupTypeKey(frame)
    local containers = self:GetActiveCustomBuffContainers()

    if containerIndex then
        -- ── Container-assigned spell ─────────────────────────────────
        -- Hide any previous buff slot icons from a prior default-assigned
        -- preview so we don't leave stale icons behind.
        if frame.buffFrames then
            for _, bf in ipairs(frame.buffFrames) do
                if bf:IsShown() then bf:Hide() end
            end
        end
        -- Hide every container EXCEPT the matching one.
        for ci, c in ipairs(containers) do
            if ci ~= containerIndex then
                local gc = self:GetContainerGroupConfig(c, ci, ac, groupTypeKey)
                self:HideAuraGroup(frame, gc)
            end
        end
        -- Render the previewed spell in its container. The previewSpecId
        -- argument routes per-spell lookups through the preview spec
        -- instead of BF.playerSpecID, eliminating the post-render
        -- re-stamping block that lived here before.
        local matched = containers[containerIndex]
        if matched then
            local gc = self:GetContainerGroupConfig(matched, containerIndex, ac, groupTypeKey)
            self:RenderContainerGroupWithAuras(frame, gc, { fakeAura }, specId)
        end

    elseif not isUntracked then
        -- ── Default-assigned spell ───────────────────────────────────
        -- Single-spell preview: render at slot 1. The pin position
        -- (specSpellOrdering) is ignored — pins only matter when other
        -- auras compete for slots, which never happens with one aura.
        if self.HideDummyContainerAuras then self:HideDummyContainerAuras(frame) end

        if not frame._auraSlotsReady then
            -- Single-spell preview only needs buff slots (renders into slot 1).
            -- BuildAuraIconFrame replaces the deleted CreateAuraSlots; no
            -- tooltip wiring (preview frame, not in BF.activatedFrames).
            frame.buffFrames = frame.buffFrames or {}
            -- +223: v56 lift band (see the custom-container creator above);
            -- missed by v56, buried single-spell preview icons under text.
            local level = frame:GetFrameLevel() + 223
            for i = 1, BF.MAX_BUFFS do
                if not frame.buffFrames[i] then
                    frame.buffFrames[i] = BF.BuildAuraIconFrame(frame, level)
                end
            end
            frame._auraSlotsReady = true
        end

        local gc = self:GetDefaultBuffGroupConfig(ac, groupTypeKey)
        self:RenderContainerGroupWithAuras(frame, gc, { fakeAura }, specId)

        -- Tooltip on the rendered icon.
        if self.SetDummyTooltip and frame.buffFrames then
            local icon = frame.buffFrames[1]
            if icon then
                self.SetDummyTooltip(icon, "Preview: " .. (spellEntry and spellEntry.name or tostring(sid)))
            end
        end

        -- Hide all other buff slots.
        if frame.buffFrames then
            for idx = 2, self.MAX_BUFFS do
                local other = frame.buffFrames[idx]
                if other and other:IsShown() then other:Hide() end
            end
        end

    else
        -- ── Untracked spell ──────────────────────────────────────────
        -- No aura icon; frame-level effects below still apply.
        if self.HideDummyContainerAuras then self:HideDummyContainerAuras(frame) end
        if frame.buffFrames then
            for _, bf in ipairs(frame.buffFrames) do
                if bf:IsShown() then bf:Hide() end
            end
        end
    end

    -- ── Frame-level effects (buff health bar color, frame border, overlay) ──
    -- These apply regardless of container/default/untracked assignment.
    -- v94: the painting lives in BF:ApplyPreviewSpellFrameEffects (above); this
    -- getter is the curated-spell read it used to do inline, gates included, so
    -- this path is behaviorally unchanged.
    self:ApplyPreviewSpellFrameEffects(frame, function(family)
        local t = acp[family] and acp[family][specId] and acp[family][specId][sid]
        if t and t.enabled == false then return nil end
        if t and not BF.IsSpellCustomized(specId, sid) then return nil end
        return t
    end)
end

-- ============================================================
-- SWIFTMENDABLE COLOR UPDATE (REMOVED)
-- BF:UpdateSwiftmendable applied name / health-text recoloring in Lua from
-- frame._bf_swiftmendable. On 12.1 aura presence is secret, so that latch was
-- never armed and the function had no callers. The live feature is the fxSM
-- slot (Indicators/BuffsAndContainers.lua): an engine-driven name MIRROR
-- FontString plus the hc / bd / ov fx kinds. Health-TEXT recolor had no 12.1
-- path at all and its two settings were purged with this removal.
-- ============================================================

-- ============================================================
-- HOOK (REMOVED)
-- RunCustomPasses has been replaced by the unified BuffsAndContainers
-- indicator (Indicators/BuffsAndContainers.lua), which owns container
-- rendering and the Swiftmendable detection (Resto Druid spec 105).
-- The hook on UpdateStandardAuras is no longer needed because
-- indicators are called synchronously via UpdateIndicators.
-- ============================================================
