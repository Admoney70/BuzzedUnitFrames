--[[
BuzzardFrames: Indicators/DebuffIcons.lua
Debuff icon indicator — renders HARMFUL debuff icons.

Grid2 pattern: indicator bound to the debuffs status. When debuffs'
UNIT_AURA handler calls self:UpdateIndicators(unit), this indicator's
Update method runs.

v67 (12.1-only): :Update no longer scans auras in Lua. It resolves the
show gate from the aura cache + the parent header's module toggle and
hands off to BF:SyncAuraGridContainer(frame, "debuffs", unit, show) —
the engine AuraContainer tracks, filters and renders natively.

The old description of this file is dead and has been removed: there is
no Debuffs:GetIcons call (deleted from Statuses/Auras.lua), no
CrowdControl:GetIcons cross-status dedup pass, and no
Dispel:SetLastDebuffAuras stash — the DebuffHighlight consumer that
needed it is gone too.

Icon pool is pre-allocated by ApplyAuraGeometry (AuraConfig.lua).
]]

local BF  = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

local ipairs           = ipairs
local math_floor       = math.floor
local issecretvalue    = issecretvalue  or function() return false end
local canaccessvalue   = canaccessvalue or function() return true  end
local UnitIsVisible    = UnitIsVisible

local SetIconBorderColor    = BF.SetIconBorderColor
local MAX_DEBUFFS           = BF.MAX_DEBUFFS

-- Scratch table for CC exclusion set (reused every call, avoids GC churn)
local _ccExcludeScratch = {}

-- v67: file-local _debuffStatus / _ccStatus upvalues removed (12.1-only).
-- Their only readers were the deleted Debuffs:GetIcons render pass and the
-- CrowdControl:GetIcons dedup pass; both grepped to zero references here.

-- ============================================================
-- v91 (owner ruling 2026-08-17): THE DISPEL-TYPE-SET MODEL
--
-- "Dispellable by me" is no longer the engine's RAID token. It is the player's
-- current set of dispellable TYPES, resolved from a per-spec table and fed to
-- the engine as includeDispelTypes / excludeDispelTypes CANDIDATE filters.
--
-- Why the token had to go: RAID is a single boolean arm, so "by me" and "by
-- others" could only ever be RAID and !RAID -- and opposing tokens of one axis
-- OR-mask (the PTR-confirmed HELPFUL|HARMFUL trap), which made some rank
-- permutations inexpressible. includeDispelTypes/excludeDispelTypes are
-- candidate filters: they AND cleanly, they are NOT identity-carve-out-gated
-- (so they keep working in combat under 12.1 aura secrecy), and every
-- permutation of the priority list becomes expressible. It also dissolves the
-- v71 warlock special case (Singe Magic -> Magic) into an ordinary table row.
--
-- Vocabulary = auraData.dispelName on HARMFUL auras. v91 FIX (owner report
-- 2026-08-17, second ruling): the BLEED type key is "Bleed" -- the "" guess
-- did not match live bleed auras, and "Bleed" is what the rest of the addon
-- already keys on (DISPEL_COLOR_MAP, the RaidFrame-Icon-DebuffBleed asset
-- map). Non-dispellable auras carry dispelName = nil, which is what makes
-- them pass every excludeDispelTypes map untouched. PTR-VERIFY: bleed auras
-- report dispelName == "Bleed" and the DISPELLABLE token matches them.
local ALL_DISPEL_TYPES = {
    Magic = true, Curse = true, Disease = true, Poison = true, Bleed = true,
}
BF.ALL_DISPEL_TYPES = ALL_DISPEL_TYPES
-- Canonical key order -> byte-stable signatures (filter/candidate change
-- guards key off them).
local DISPEL_TYPE_ORDER = { "Magic", "Curse", "Disease", "Poison", "Bleed" }

-- Per specID, three layers (see Docs: MyDispelTypes_By_Spec.md rev 3):
--   base     always-on types for the spec
--   talents  spell-keyed layers from dispel talents. "Only when talented" ON
--            (default) IsPlayerSpell-gates each layer; OFF folds them ALL in
--            unconditionally (owner ruling: OFF = go by the spec list).
--   longCd   spell-keyed layers from long-cooldown dispels. Counted only when
--            "Include Long-Cooldown Dispels" is ON, and ALWAYS IsPlayerSpell-
--            gated regardless of the first toggle.
-- Talent/spell IDs are addon-maintained truth (the same class of table
-- Statuses/DispelCooldown.lua carries) -- PTR-verify on every content patch.
local DISPEL_TYPES_BY_SPEC = {
    [256] = { base = { Magic = true },
              talents = { [390632] = { Disease = true } },             -- Improved Purify
              longCd  = { [32375]  = { Magic = true } } },             -- Mass Dispel
    [257] = { base = { Magic = true },
              talents = { [390632] = { Disease = true } },
              longCd  = { [32375]  = { Magic = true } } },
    [258] = { talents = { [213634] = { Disease = true } },             -- Purify Disease
              longCd  = { [32375]  = { Magic = true } } },             -- Mass Dispel (Shadow's Magic access)
    [65]  = { base = { Magic = true },
              talents = { [393024] = { Poison = true, Disease = true } } }, -- Improved Cleanse
    [66]  = { talents = { [213644] = { Poison = true, Disease = true } } }, -- Cleanse Toxins
    [70]  = { talents = { [213644] = { Poison = true, Disease = true } } },
    [262] = { talents = { [51886]  = { Curse = true } },               -- Cleanse Spirit
              longCd  = { [383013] = { Poison = true } } },            -- Poison Cleansing Totem
    [263] = { talents = { [51886]  = { Curse = true } },
              longCd  = { [383013] = { Poison = true } } },
    [264] = { base = { Magic = true },
              talents = { [383016] = { Curse = true } },               -- Improved Purify Spirit
              longCd  = { [383013] = { Poison = true } } },
    [102] = { talents = { [2782]   = { Curse = true, Poison = true } } }, -- Remove Corruption
    [103] = { talents = { [2782]   = { Curse = true, Poison = true } } },
    [104] = { talents = { [2782]   = { Curse = true, Poison = true } } },
    [105] = { base = { Magic = true },
              talents = { [392378] = { Curse = true, Poison = true } } }, -- Improved Nature's Cure
    [268] = { talents = { [218164] = { Poison = true, Disease = true } } }, -- Detox (non-heal)
    [269] = { talents = { [218164] = { Poison = true, Disease = true } } },
    [270] = { base = { Magic = true },
              talents = { [388874] = { Poison = true, Disease = true } } }, -- Improved Detox
    [62]  = { talents = { [475]    = { Curse = true } } },             -- Remove Curse
    [63]  = { talents = { [475]    = { Curse = true } } },
    [64]  = { talents = { [475]    = { Curse = true } } },
    [1467] = { base = { Poison = true },                               -- Expunge
               longCd = { [374251] = { Bleed = true, Curse = true, Disease = true } } },
    [1468] = { base = { Magic = true, Poison = true },                 -- Naturalize
               longCd = { [374251] = { Bleed = true, Curse = true, Disease = true } } },
    [1473] = { base = { Poison = true },
               longCd = { [374251] = { Bleed = true, Curse = true, Disease = true } } },
    [265] = { base = { Magic = true } },                               -- Singe Magic (Imp pet)
    [266] = { base = { Magic = true } },
    [267] = { base = { Magic = true } },
    -- DK / DH / Hunter / Rogue / Warrior: no entry -> empty set.
}
BF.DISPEL_TYPES_BY_SPEC = DISPEL_TYPES_BY_SPEC

-- Resolved cache. Keyed by "<specID>:<talented>:<longCd>", wiped whenever the
-- spec or the talent build changes (the DispelCooldown.lua refresh hooks --
-- login / PLAYER_SPECIALIZATION_CHANGED / talent change), because
-- IsPlayerSpell answers move under both.
local _myDispelCache = {}
local _myDispelSpecID = nil

-- v91 FIX: BF.MyDispelGen -- a monotonic counter bumped every time the resolved
-- type set can have moved for reasons that are NOT in any settings cache (spec
-- swap, talent change, the first login pass that finally resolves the spec).
-- Callers on hot per-update paths cannot afford BF:MyDispelTypes just to learn
-- "did it move?" -- that call builds a cache key string (an allocation) and the
-- sig it returns is a string compare. This counter is an integer they can fold
-- into an arithmetic change guard for free. It deliberately does NOT cover the
-- two By-Me toggles: those live in the aura cache, so a guard reads them
-- straight off `ac` (see BF:SyncDispelVisualSlots, Auras/ContainerFactory.lua).
BF.MyDispelGen = 0

local function ResolveMySpecID()
    local idx = GetSpecialization and GetSpecialization()
    if not idx then return nil end
    return GetSpecializationInfo and select(1, GetSpecializationInfo(idx)) or nil
end

local function FoldDispelLayer(out, layer)
    for k in pairs(layer) do out[k] = true end
end

-- BF:MyDispelTypes(ac) -> (typesMap, sig)
-- typesMap is SHARED and must never be mutated by a caller (copy before
-- merging into a candidate table). sig is a byte-stable string folded into
-- every shape / presence signature, so a spec or talent change re-applies
-- every dispel-derived filter, candidate and claim.
function BF:MyDispelTypes(ac)
    local talented = not (ac and ac.debuffDispMeTalented == false)  -- default ON
    local longCd   = (ac and ac.debuffDispMeLongCd) == true         -- default OFF
    if _myDispelSpecID == nil then _myDispelSpecID = ResolveMySpecID() or false end
    local key = tostring(_myDispelSpecID) .. ":" .. (talented and "1" or "0")
        .. ":" .. (longCd and "1" or "0")
    local hit = _myDispelCache[key]
    if hit then return hit.types, hit.sig end

    local out = {}
    local def = _myDispelSpecID and DISPEL_TYPES_BY_SPEC[_myDispelSpecID]
    if def then
        if def.base then FoldDispelLayer(out, def.base) end
        if def.talents then
            for sid, layer in pairs(def.talents) do
                if (not talented) or (IsPlayerSpell and IsPlayerSpell(sid)) then
                    FoldDispelLayer(out, layer)
                end
            end
        end
        if longCd and def.longCd then
            for sid, layer in pairs(def.longCd) do
                -- Long-cd layers are IsPlayerSpell-gated ALWAYS (owner ruling
                -- 2026-08-17) -- "Only when talented" does not loosen them.
                if IsPlayerSpell and IsPlayerSpell(sid) then
                    FoldDispelLayer(out, layer)
                end
            end
        end
    end
    local sig = "dt:"
    for i = 1, #DISPEL_TYPE_ORDER do
        sig = sig .. (out[DISPEL_TYPE_ORDER[i]] and "1" or "0")
    end
    _myDispelCache[key] = { types = out, sig = sig }
    return out, sig
end

-- allTypes MINUS myTypes -- the "By Others" arm. Fresh table per call (small,
-- built at Layout time only), so no caller can alias the cached myTypes.
function BF:OtherDispelTypes(myTypes)
    local out = {}
    for i = 1, #DISPEL_TYPE_ORDER do
        local k = DISPEL_TYPE_ORDER[i]
        if not myTypes[k] then out[k] = true end
    end
    return out
end

-- v91: refresh hooks, mirroring Statuses/DispelCooldown.lua's lifecycle
-- (login / spec change / talent change). Own event frame rather than a hook
-- into Initialization.lua's dispatcher so this file is self-contained; the
-- handler only wipes a small cache and asks for the LIGHT container refresh,
-- whose per-frame DebuffIcons:Layout re-resolves the shape (its signature
-- folds the myTypes sig, so unchanged builds cost one string compare).
do
    -- v86 (event refactor stage 2): was a private CreateFrame whose handler
    -- took (_, event) and dropped the unit entirely.
    --
    -- PLAYER_SPECIALIZATION_CHANGED is NOT player-only: it carries a unit and
    -- fires once for every GROUP MEMBER as the client resolves their spec.
    -- Joining a 24-man raid produced 20 of them, ~125 ms apart, and each ran
    -- this whole body -- wiping the PLAYER's dispel cache, bumping
    -- MyDispelGen (which invalidates every downstream signature guard), and
    -- calling RefreshAllCustomContainers, which re-Layouts DebuffIcons AND
    -- BuffsAndContainers on every frame. Measured on one join: 578
    -- buffsAndContainers:Layout calls where the layout reload itself needed
    -- 55, and 4604 ApplyAuraGridGroupButtonSpec calls costing 1.5 s -- most
    -- of a 6.6 s stall. Another player's spec cannot change ResolveMySpecID
    -- (GetSpecialization is the player's own) or any IsPlayerSpell answer, so
    -- there was never anything here for a foreign unit to do.
    --
    -- The scope is now declared per subscription instead of hand-tested:
    -- PLAYER_SPECIALIZATION_CHANGED is "player" and filtered by the engine,
    -- while the other three carry no unit and stay "unitless".
    local owner = BF:EventOwner("debuffIconsDispel")

    local function OnDispelRefresh(_, event)
        _myDispelSpecID = ResolveMySpecID() or false
        wipe(_myDispelCache)
        -- v91 FIX: bump alongside the wipe -- the two are the same event
        -- ("everything resolved from IsPlayerSpell / the spec just moved").
        -- Bumped on PLAYER_ENTERING_WORLD too, even though PEW returns below
        -- without a container refresh: the FIRST PEW is where _myDispelSpecID
        -- stops being nil, so slots created before it (spec unknown -> empty
        -- type set) must see a changed generation on their next update.
        BF.MyDispelGen = (BF.MyDispelGen or 0) + 1
        -- v91 FIX: no container refresh from PLAYER_ENTERING_WORLD. The first
        -- PEW fires BEFORE the aura indicators register their UpdateDB passes,
        -- so RefreshAllCustomContainers -> UpdateAuraSizeCache rebuilt an
        -- EMPTY cache (_roundedBuffSize nil -> pixel-glow nil-index error at
        -- login), and later PEWs (zone transitions) change nothing dispel-wise
        -- anyway -- the cache wipe above is all PEW needs; the normal login /
        -- zone Layout flow re-resolves shapes on its own. Spec/talent events
        -- DO reshape myTypes, and only fire on a fully initialized session;
        -- the activeFrames gate is a cheap belt-and-braces for those.
        if event == "PLAYER_ENTERING_WORLD" then return end
        if not (BF.activeFrames and next(BF.activeFrames)) then return end
        if BF.RefreshAllCustomContainers then BF:RefreshAllCustomContainers() end
    end

    owner:Sub("PLAYER_ENTERING_WORLD",         OnDispelRefresh, "unitless")
    owner:Sub("PLAYER_SPECIALIZATION_CHANGED", OnDispelRefresh, "player")
    owner:Sub("PLAYER_TALENT_UPDATE",          OnDispelRefresh, "unitless")
    owner:Sub("TRAIT_CONFIG_UPDATED",          OnDispelRefresh, "unitless")
end

-- v91: "Dispellable by me" as (filterString, includeDispelTypesMap). Kept as
-- the ONE resolver every non-shape caller routes through -- the dispel VISUALS
-- (BF.DispelVisualFilterFor, ContainerFactory.lua) and the meDispellable
-- container preset (ApplyPresetGroups). Reimplemented on the type-set model:
-- always DISPELLABLE + an include map, for every class. A spec with no dispel
-- returns an EMPTY map, which the engine reads as "no dispelName is in the
-- map" -> the group/slot shows nothing, the honest answer.
function BF:MeDispelFilterParts(ac)
    local myTypes = self:MyDispelTypes(ac)
    return "HARMFUL|DISPELLABLE", myTypes
end

local DebuffIcons = BF.indicatorPrototype:new("debuffIcons")

-- Per-indicator Create: build the debuff icon pool.
-- :CanCreate returns false for preview frames so MakePreviewFrame's
-- indicator-walk doesn't eagerly allocate; DummyAuras builds preview
-- icons via BF.BuildAuraIconFrame directly when it needs them.
function DebuffIcons:CanCreate(parent) return not parent._isPreviewFrame end
-- Container path: the container is the indicator's widget (Layout
-- dispatch loops gate on GetFrame — see BuffsAndContainers:GetFrame).
function DebuffIcons:GetFrame(parent)
    return parent.debuffFrames
        or (parent._bf_auraContainers and parent._bf_auraContainers.debuffs)
end

-- ============================================================
-- 12.1 CONTAINER PATH
-- ============================================================

-- ============================================================
-- v84 (Stage 5, plan §9.6 + §9.10): THE DEBUFF TYPE MODEL
--
-- Replaces the old "Debuffs to Show" (debuffShowMode) show-mode arms and the
-- four Enlarge toggles with a composable model:
--
--   * a BASE FILTER for the residual "other debuffs" flow (the `primary` group)
--   * debuff TYPES, each with its own on/off toggle and Relative Size
--   * "Show Other Debuffs", itself one of the orderable rows
--
-- v91 (owner ruling 2026-08-17) replaces the per-type Order dropdowns with ONE
-- reorderable PRIORITY LIST of SEVEN rows -- Boss, Role, CC, Dispellable by Me,
-- Dispellable by Others, Priority, Other -- carrying UNIQUE ranks 1..7, and
-- makes that list the single precedence authority everywhere (main row AND
-- container presets; the fixed DEBUFF_PRESET_RANK table is gone). Three
-- explicit Combine checkboxes collapse a pair into one row at the pair's better
-- rank, replacing the v84 same-size+adjacent Boss/Role auto-merge.
--
-- Every enabled, unclaimed type owns a group at its own size, flowed by its
-- rank. Group keys are REUSED, so a shape flip is live setters only and
-- allocates no new engine pool:
--
--   bigBoss    Boss (or the combined Boss+Role union -- isBossOrRoleAura)
--   bigRole    Role
--   bigCC      Crowd Control
--   bigPrio    Priority
--   secondary  Dispellable by Me (or the combined dispel row)
--   secondary2 Dispellable by Others  (v91: the ONE new group key the split
--                                      needs; the combined row parks it)
--   primary    "other debuffs" -- the residual flow, Base Filter driven
--
-- DISJOINTNESS is explicit and total (the engine's own auto-dedup picks an
-- unspecified winner, so it is never relied on):
--   * `primary` negates every type that RENDERS SOMEWHERE ELSE -- live in its
--     own group, claimed by a custom debuff container, or merged away into a
--     LIVE combined row -- and only those. v95 (owner ruling 2026-08-25)
--     replaces the old "a disabled type never renders anywhere" rule: **"Show
--     X" off now means X FALLS BACK INTO Other Debuffs**, where it is subject
--     to Other's Base Filter like any other residual debuff.
--   * Each enabled type group negates every ENABLED type ranked before it --
--     and only those. Disabled types are never negated out of a type group, so
--     a dispellable Polymorph with Crowd Control off and Dispellable on still
--     renders in the Dispellable group (owner ruling: the ENABLED type shows it).
--   * Dispel negations are TYPE-SET candidates (see the dispel model at the top
--     of this file), never filter tokens -- opposing tokens OR-mask.
-- ============================================================

-- Base Filter (the residual "other debuffs" flow only -- type groups are
-- INDEPENDENT of it, because "Show Boss Auras" has to mean boss auras show).
local DEBUFF_BASE_FILTERS = {
    none     = "HARMFUL|INCLUDE_NAME_PLATE_ONLY",
    -- v93: "Show All (Exclude Applied by Friendly)". The TOKEN set is
    -- identical to `none` -- there is no filter token for this. The exclusion
    -- is expressed as the candidate isFromPlayerOrPlayerPet = false, stamped
    -- on the `other` entry below. Kept in this table anyway so every
    -- debuffBaseFilter value resolves here and the `or DEBUFF_BASE_FILTERS.none`
    -- fallback never silently swallows a real value.
    noplayer = "HARMFUL|INCLUDE_NAME_PLATE_ONLY",
    -- "Blizzard Filter": the engine's own "flagged to show on raid frames in
    -- combat" token. STATIC -- it applies the in-combat visibility flag
    -- whatever the player's combat state.
    --
    -- v95 (owner ruling 2026-08-25): kept as a TOKEN, deliberately, after a
    -- detour through candidateFilters.processedAuraType = Debuff. That
    -- candidate is an exact match on AuraUtil.ProcessAura's classification,
    -- and ProcessAura classifies a debuff the PLAYER can dispel (isRaid) as
    -- Dispel, not Debuff -- so the candidate form would have dropped the
    -- player's own dispellables from this row whenever the Dispellable by Me
    -- category was folded in, and the schema has no OR to admit both types in
    -- ONE group (a second group means a second cap, which defeats the single
    -- Max Debuffs this row exists for). The token admits them.
    --
        -- The ProcessAura policy STAYS on the container (EnsureDebuffProcessPolicy)
    -- for the "blizzard" Sort Order, which tiers on the debuffType ProcessAura
    -- stamps. See DebuffGroupSortFor.
    blizzard = "HARMFUL|RAID_IN_COMBAT|INCLUDE_NAME_PLATE_ONLY",
}
-- Boolean-candidate type groups ride the permissive HARMFUL token set: the
-- candidate boolean IS the filter, and the base flow's Base Filter must not
-- narrow them.
local TYPE_BASE_FILTER = "HARMFUL|INCLUDE_NAME_PLATE_ONLY"

-- v91 (owner ruling 2026-08-17): SIX orderable TYPES plus `other` = the SEVEN
-- rows of the user's priority list. Dispellable split into two independent
-- types (by Me / by Others), each with its own Show, Relative Size and RANK.
--
-- RANKS ARE UNIQUE, 1..7, and that is an INVARIANT: defaults ship 1..7, the
-- migration assigns 1..7, and the list arrows SWAP two ranks. Nothing may
-- create a tie -- the negation chain (each live group negates every live group
-- ranked above it) is only total because the order is. `seq` survives purely
-- as the defensive tiebreak for a hand-edited SavedVariables file.
--
-- `gk` group keys are REUSED across shapes so a reshape is live setters only;
-- DispOthers is the ONE new key the split needs (`secondary2`).
local DEBUFF_TYPES = {
    { id = "boss",     gk = "bigBoss", seq = 1, claimId = "boss",
      onKey = "debuffTypeBoss", sizeKey = "debuffSizeBoss",
      maxKey = "debuffMaxBoss",
      rankKey = "debuffRankBoss", cand = "isBossAura" },
    { id = "role",     gk = "bigRole", seq = 2, claimId = "role",
      onKey = "debuffTypeRole", sizeKey = "debuffSizeRole",
      maxKey = "debuffMaxRole",
      rankKey = "debuffRankRole", cand = "isRoleAura" },
    { id = "cc",       gk = "bigCC",   seq = 3, claimId = "cc",
      onKey = "debuffTypeCC", sizeKey = "debuffSizeCC",
      maxKey = "debuffMaxCC",
      rankKey = "debuffRankCC",
      -- CC has no candidate boolean; it rides the CROWD_CONTROL filter token.
      filter = "HARMFUL|CROWD_CONTROL", negToken = "|!CROWD_CONTROL" },
    { id = "dispMe",   gk = "secondary", seq = 4, dispel = "me",
      claimId = "dispelMe",
      onKey = "debuffTypeDispMe", sizeKey = "debuffSizeDispMe",
      maxKey = "debuffMaxDispMe",
      rankKey = "debuffRankDispMe" },
    { id = "dispOthers", gk = "secondary2", seq = 5, dispel = "others",
      claimId = "dispelOthers",
      onKey = "debuffTypeDispOthers", sizeKey = "debuffSizeDispOthers",
      maxKey = "debuffMaxDispOthers",
      rankKey = "debuffRankDispOthers" },
    { id = "priority", gk = "bigPrio", seq = 6, claimId = "priority",
      onKey = "debuffTypePriority", sizeKey = "debuffSizePriority",
      maxKey = "debuffMaxPriority",
      rankKey = "debuffRankPriority", cand = "isPriorityAura" },
}
BF.DEBUFF_TYPES = DEBUFF_TYPES

-- ── 2026-08-25 (owner ruling): THE TWO MODES DO NOT SHARE RANKS ─────────
-- Simple Mode and normal mode ask different questions of the priority list.
-- In normal mode it is a PRECEDENCE list: the groups overlap, so a higher rank
-- claims a multi-category aura out of everything below it, and the residual
-- "Other Debuffs" row therefore may never sit above a real type -- it would
-- swallow the lot. In Simple Mode the groups are engine-CLASSIFIED
-- (processedAuraType Debuff vs Dispel) and disjoint by construction, so
-- nothing claims anything and the list is pure display order -- Other is free
-- to sit anywhere.
--
-- One shared set of rank keys could not express both: enforcing the residual
-- rule for normal mode would silently rewrite a Simple Mode user's deliberate
-- order, and honoring their order would leave normal mode invalid. So Simple
-- Mode has its OWN seven keys, and this is the one place that decides which
-- set a read means. Existing profiles have theirs seeded from the normal ranks
-- by dbVersion 78, so nobody's Simple Mode order moves on upgrade.
--
-- `ac` may be an aura cache OR a raw `debuffs` profile sub-table -- both carry
-- these keys and the nil defaults resolve identically, which is what lets the
-- options page share the resolver with the runtime.
local DEBUFF_RANK_KEY = {
    boss = "debuffRankBoss", role = "debuffRankRole", cc = "debuffRankCC",
    dispMe = "debuffRankDispMe", dispOthers = "debuffRankDispOthers",
    priority = "debuffRankPriority", other = "debuffRankOther",
}
local DEBUFF_SIMPLE_RANK_KEY = {
    boss = "debuffSimpleRankBoss", role = "debuffSimpleRankRole",
    cc = "debuffSimpleRankCC", dispMe = "debuffSimpleRankDispMe",
    dispOthers = "debuffSimpleRankDispOthers",
    priority = "debuffSimpleRankPriority", other = "debuffSimpleRankOther",
}
local DEBUFF_RANK_DEFAULT = {
    boss = 1, role = 2, cc = 3, dispMe = 4, dispOthers = 5, priority = 6,
    other = 7,
}
-- 2026-08-25 (owner ruling): in NORMAL mode the residual "Other Debuffs" row
-- is pinned BEHIND every real type -- a constant above the 1..7 the keys can
-- hold, so debuffRankOther is simply never read there. Other is the residual
-- by definition: ranked ahead of a real type it claims everything and starves
-- every group below it, which is not an arrangement the list should be able to
-- express.
--
-- A CONSTANT rather than a stored value or a migration, deliberately. v5.2.1
-- let the arrows put Other anywhere, so saved profiles in the wild can hold
-- such a rank; pinning it here corrects every one of them at once -- upgrades,
-- imports, profile copies and resets alike, the last three of which never
-- reach the dbVersion dispatcher at all. Nothing is rewritten, so the rule
-- stays one line to revisit rather than an irreversible data write.
--
-- SIMPLE MODE is exempt: its groups are engine-classified and disjoint, so
-- nothing claims anything and the list is pure display order -- the residual
-- is free to sit anywhere, and reads its own stored debuffSimpleRankOther.
local DEBUFF_RESIDUAL_RANK = 10
BF.DEBUFF_RESIDUAL_RANK = DEBUFF_RESIDUAL_RANK
BF.DEBUFF_RANK_KEY        = DEBUFF_RANK_KEY
BF.DEBUFF_SIMPLE_RANK_KEY = DEBUFF_SIMPLE_RANK_KEY
BF.DEBUFF_RANK_DEFAULT    = DEBUFF_RANK_DEFAULT

-- The KEY a rank read/write for `id` means in whichever mode `ac` describes.
-- Exposed because the options list writes ranks as well as reading them.
function BF:DebuffRankKeyOf(ac, id)
    local map = (ac and ac.debuffSimpleMode == true)
        and DEBUFF_SIMPLE_RANK_KEY or DEBUFF_RANK_KEY
    return map[id]
end
-- The rank itself, defaulted to the canonical row sequence -- except the
-- normal-mode residual, which is pinned last (see DEBUFF_RESIDUAL_RANK).
--
-- SIMPLE MODE FALLS BACK TO THE NORMAL ORDER until it is reordered.
--
-- The two modes store their ranks under separate keys on purpose: a reorder
-- in one must not move the other's list. But an UNSET simple rank used to
-- fall to the factory sequence, so merely ticking Simple Mode reshuffled a
-- list the reader had arranged themselves -- an order they never asked to
-- change, presented as if they had. The normal-mode rank is the better
-- default: it is that reader's own order, and the moment they drag anything
-- in Simple Mode that row gets a simple rank of its own and the two lists go
-- their separate ways again, exactly as before.
function BF:DebuffRankOf(ac, id)
    local simple = (ac and ac.debuffSimpleMode == true) or false
    if id == "other" and not simple then
        return DEBUFF_RESIDUAL_RANK
    end
    local k = self:DebuffRankKeyOf(ac, id)
    local v = k and ac and ac[k]
    if v == nil and simple then
        -- This row's NORMAL rank, if the reader has set one. Read directly
        -- rather than through DebuffRankKeyOf, which answers for the mode
        -- that is on.
        local nk = DEBUFF_RANK_KEY[id]
        v = nk and ac and ac[nk]
    end
    return v or DEBUFF_RANK_DEFAULT[id] or 7
end

-- v88: "Maximum Duration" filter. Maps the dropdown key to a seconds bound
-- fed to the engine's candidateFilters.maxDuration — an INCLUSIVE upper bound
-- on the aura's MAX (total, declared) duration, NOT remaining time (which is
-- secret on 12.1). Any non-nil value also hides PERMANENT debuffs (no
-- duration). "none" → nil → the field is omitted (no filtering).
local DEBUFF_MAX_DURATION_SECONDS = {
    none  = nil,
    sec30 = 30,
    min1  = 60,
    min2  = 120,
    min5  = 300,
    min10 = 600,
    min30 = 1800,
    hour1 = 3600,
}
BF.DEBUFF_MAX_DURATION_SECONDS = DEBUFF_MAX_DURATION_SECONDS

-- §9.6: the user-facing sort options. AuraInstanceIDOnly/Normal is what
-- the retired UnitFrameDebuff sortMethod actually produced for enemy-cast
-- debuffs, so it is the behavior-preserving default. Resolved inside a
-- function, never in a file-scope table constructor: the
-- AuraContainerSortMethod / AuraContainerSortDirection globals are FrameXML's
-- and this file is parsed before they are guaranteed to exist.
--
-- ── v95 (2026-08-25): WHY §9.4 FOUND UnitFrameDebuff "INERT" ─────────────
-- The old finding was that the hardcoded UnitFrameDebuff comparator produced
-- nothing but application order. It was not inert -- it was STARVED.
-- AuraUtil.UnitFrameDebuffComparator compares `auraData.debuffType` first and
-- falls through to AuraUtil.DefaultAuraCompare when the two are equal; but
-- `debuffType` is stamped ONLY by AuraUtil.ProcessAura, which the engine runs
-- only when the container carries the ProcessAura processing policy. Our
-- containers were all on the default policy (None), so debuffType was nil on
-- every aura, `a.debuffType ~= b.debuffType` was false for every pair, and
-- every comparison fell straight through to DefaultAuraCompare -- i.e. exactly
-- "yours first, then application order". Setting the policy (see
-- EnsureDebuffProcessPolicy) is what makes the tiering real, which is what the
-- "blizzard" Sort Order below is built on.
--
-- ⚠ The nil that made it inert is also the hazard: a nil debuffType against a
-- stamped one evaluates `nil < number` INSIDE Blizzard's secure comparator and
-- errors. UnitFrameDebuff may therefore only be handed to a group whose auras
-- are all guaranteed classified -- see DebuffGroupSortFor.
local function ResolveDebuffSort(key)
    local M, D = AuraContainerSortMethod, AuraContainerSortDirection
    if key == "recentFirst" then return M.AuraInstanceIDOnly, D.Reverse end
    if key == "expireSoon"  then return M.ExpirationOnly,     D.Normal  end
    if key == "expireLast"  then return M.ExpirationOnly,     D.Reverse end
    -- v95: Blizzard's own raid-frame debuff order -- debuffType tier first
    -- (BossDebuff < BossBuff < PriorityDebuff < NonBossRaidDebuff <
    -- NonBossDebuff), then DefaultAuraCompare within the tier.
    if key == "blizzard"    then return M.UnitFrameDebuff,    D.Normal  end
    return M.AuraInstanceIDOnly, D.Normal
end
BF.ResolveDebuffSort = ResolveDebuffSort

-- v95 (2026-08-25): the PER-GROUP sort. Every Sort Order except "blizzard"
-- applies uniformly to every group of the row, exactly as before -- this
-- function returns ResolveDebuffSort's pair untouched for them.
--
-- "blizzard" is the exception. AuraContainerSortMethod.UnitFrameDebuff
-- compares `a.debuffType < b.debuffType` first, and debuffType is stamped by
-- AuraUtil.ProcessAura only on the auras it classifies (Debuff / Dispel). An
-- aura it returns None for -- a non-boss, non-priority, non-dispellable debuff
-- whose spell's raid-frame visibility flag says "not for your spec" -- has no
-- debuffType, and one such aura against a classified one is a `nil < number`
-- compare inside the secure comparator. PTR-CONFIRMED 2026-08-25: applied to
-- every group under Show All it threw
--   Blizzard_FrameXMLUtil/AuraUtil.lua:179: attempt to compare nil with number
-- So UnitFrameDebuff is handed ONLY to the group whose contents are the
-- Blizzard-classified set: `other` (the `primary` group) under the Blizzard
-- Filter, whose RAID_IN_COMBAT token is the same per-spell visibility flag
-- ProcessAura consults. Every other group -- the type groups, and `other`
-- under Show All / Exclude Friendly -- takes AuraContainerSortMethod.Default,
-- i.e. DefaultAuraCompare: the same yours-first / priority / canApply /
-- instance-ID rule UnitFrameDebuff applies WITHIN a tier, with no debuffType
-- read. A single-category group holds one tier anyway, so nothing is lost
-- there. (If the error ever reproduces under the Blizzard Filter itself, the
-- token admits something ProcessAura does not classify, and the only safe
-- tiered form is the processedAuraType = Debuff candidate -- which drops the
-- player's own dispellables; see DEBUFF_BASE_FILTERS.)
--
-- ── v95 SIMPLE MODE ARM (owner-approved plan, 2026-08-25) ────────────────
-- FIRST, before the user's Sort Order is even read: in Simple Mode the Sort
-- Order option is HIDDEN and IGNORED (the whole point of the mode is "what the
-- default raid frames do"), so the arm returns unconditionally.
--
-- `other` (primary) and `dispMe` (secondary) are built from a
-- candidateFilters.processedAuraType candidate in that mode -- Debuff and
-- Dispel respectively -- so EVERY member of either group is one AuraUtil.
-- ProcessAura classified, which is exactly the guarantee the nil-compare
-- hazard above demands: a group whose members all carry a debuffType. That is
-- what makes UnitFrameDebuff (Blizzard's own tiered raid-frame order) safe
-- here where it is not safe under an arbitrary token filter.
--
-- `boss` (bigBoss) is a plain isBossOrRoleAura candidate with no
-- processedAuraType, so it may hold an aura ProcessAura returned None for
-- (nil debuffType) -- Default, never UnitFrameDebuff. It is one tier anyway.
local function DebuffGroupSortFor(ac, e)
    if ac and ac.debuffSimpleMode == true then
        local M, D = AuraContainerSortMethod, AuraContainerSortDirection
        if e and (e.id == "other" or e.id == "dispMe") then
            return M.UnitFrameDebuff, D.Normal
        end
        return M.Default, D.Normal
    end
    local key = ac and ac.debuffSortOrder
    if key ~= "blizzard" then return ResolveDebuffSort(key) end
    local M, D = AuraContainerSortMethod, AuraContainerSortDirection
    if e and e.id == "other" and (ac.debuffBaseFilter or "none") == "blizzard" then
        return M.UnitFrameDebuff, D.Normal
    end
    return M.Default, D.Normal
end
BF.DebuffGroupSortFor = DebuffGroupSortFor

-- v95: hand the `debuffs` container the ProcessAura processing policy.
--
-- UNCONDITIONAL, and cheap: the policy only makes the engine stamp
-- `processedAuraType` (and, on the paths that classify, `debuffType`) onto each
-- aura during parse; nothing here names processedAuraType in a candidate set,
-- and the ONE consumer is the "blizzard" Sort Order's comparator, which reads
-- debuffType. Setting it at creation and again on every Layout guarantees the
-- policy is never one pass behind that sort.
--
-- ignoreBuffs: the row is HARMFUL-only, so buff classification is dead work.
-- ignoreDispelDebuffs stays FALSE (the engine default): a debuff the player
-- can dispel has isRaid = true and takes ProcessAura's last branch, where it
-- classifies as Dispel with debuffType BossDebuff or NonBossRaidDebuff. That
-- stamp is what lets the "blizzard" Sort Order tier the player's own
-- dispellables correctly inside the Blizzard-filtered row; ignoring them would
-- leave them unclassified (nil debuffType) and trip the comparator.
-- (displayOnlyDispellableDebuffs / ignoreDebuffs are left at their engine
-- defaults of false; SetAuraProcessingPolicy fills every omitted option in from
-- CustomAuraContainerProcessAuraPolicyDefaultOptions.)
--
-- Guarded by a flag on the container itself rather than a signature: the policy
-- has no inputs, so once it is on it never needs re-pushing, and the engine
-- call carries an UpdateAllAuras with it.
local function EnsureDebuffProcessPolicy(c)
    if not c or c._bf_processPolicy then return end
    local P = CustomAuraContainerAuraProcessingPolicy
    if not (P and c.SetAuraProcessingPolicy) then return end
    if pcall(c.SetAuraProcessingPolicy, c, P.ProcessAura, {
        ignoreBuffs = true,
    }) then
        c._bf_processPolicy = true
    end
end

-- v91: every dispel arm is the SAME filter string. The arm is expressed
-- entirely in candidates (include/exclude dispel TYPES), which AND cleanly and
-- never OR-mask -- unlike the retired RAID / !RAID / !DISPELLABLE tokens.
local DISPEL_GROUP_FILTER = "HARMFUL|DISPELLABLE"

-- Union a dispel-type map into cand[key], ALWAYS through a private copy: the
-- myTypes map is cached and shared, and ALL_DISPEL_TYPES is a file constant.
local function MergeDispelTypes(cand, key, src)
    cand = cand or {}
    local cur = cand[key]
    if not cur then cur = {}; cand[key] = cur end
    for k in pairs(src) do cur[k] = true end
    return cand
end

-- The type set a dispel ENTRY covers. "both" (the combined row) is the whole
-- five-key set, so subtracting it out of a lower group is exactly the old
-- |!DISPELLABLE -- expressed as a candidate, hence composable.
local function DispelEntryTypes(e, myTypes, otherTypes)
    if e.dispelKind == "me" then return myTypes end
    if e.dispelKind == "others" then return otherTypes end
    return ALL_DISPEL_TYPES
end

-- Is this type claimed out of the main row by a custom debuff container?
-- Claim beats the toggle (existing v68 rule): the type renders in the
-- container, so its main-row group parks and its options row shows the v89
-- claim note. v91: the two dispel types claim independently (meDispellable /
-- othersDispellable presets) -- allDispellable is retired.
local function TypeClaimed(t, claims)
    if not claims or not t.claimId then return false end
    return claims[t.claimId] == true
end

-- Add `o`'s negation to an accumulating (token, candidate) pair.
local function AddTypeNegation(o, tok, cand, myTypes, otherTypes)
    if o.id == "cc" then
        return tok .. o.t.negToken, cand
    elseif o.dispelKind then
        -- v91: subtract by TYPE SET, never by token. By Me -> myTypes; By
        -- Others -> allTypes − myTypes; the combined row -> the full set.
        -- Non-dispellable auras have dispelName = nil and pass untouched.
        return tok, MergeDispelTypes(cand, "excludeDispelTypes",
            DispelEntryTypes(o, myTypes, otherTypes))
    end
    cand = cand or {}
    -- The merged group covers boss OR role in one candidate -- the schema's
    -- only OR composite.
    cand[o.merged and "isBossOrRoleAura" or o.t.cand] = false
    return tok, cand
end

-- Canonical preset -> row sequence. Hoisted here (v92) from the preset de-dup
-- block further down: it was already the fallback rank for a call with no aura
-- cache, and ResolveDebuffShape now needs it as the sort tiebreak for the
-- synthetic flowed entries -- which are resolved hundreds of lines above that
-- block. One table, two readers, declared before the first of them.
local PRESET_ROW_SEQ = {
    boss = 1, role = 2, crowdControl = 3,
    meDispellable = 4, othersDispellable = 5, priority = 6,
}

-- v91: ranks are UNIQUE, so `rank` alone decides. `sub` exists only for the
-- Priority/Other force-include pair, which deliberately shares one rank with
-- two live groups flowing adjacently; `seq` is the last-ditch tiebreak for a
-- hand-corrupted profile that managed to store a duplicate rank.
local function ShapeEntryLess(a, b)
    if a.rank ~= b.rank then return a.rank < b.rank end
    if a.sub ~= b.sub then return a.sub < b.sub end
    return a.seq < b.seq
end

-- Append the custom-container claim tokens, skipping any this group's filter
-- already carries. v95: `primary` negates only the types that render elsewhere,
-- and a CLAIMED type is one of them -- so the one claim token that still exists
-- (|!CROWD_CONTROL) is already on primary's filter whenever it applies; a repeated
-- identical token is very likely harmless, but the filter strings are also the
-- change-guard keys for SetAuraGroupFilterString, so keeping them canonical
-- keeps the guard honest. Plain find (no patterns) and only at Layout time.
-- The leading "|!" makes every one of these tokens collision-free against the
-- positive tokens in use (a plain find for "|!CROWD_CONTROL" can never match
-- inside a positive "|CROWD_CONTROL").
local function AppendClaimTokens(base, claimSuffix)
    if not claimSuffix or claimSuffix == "" then return base end
    local out = base
    for tok in claimSuffix:gmatch("|![A-Z_]+") do
        if not out:find(tok, 1, true) then out = out .. tok end
    end
    return out
end

-- Cheap signature of every input the shape depends on. Rebuilding the shape is
-- gated on it (Layout runs per frame), and it also folds straight into the
-- candidate-filter change guard in ApplyDebuffLTDExcludes.
-- v92 §B3.3: `flowSig` is the FLOWED SET's signature (ci + pkey + rank + mult
-- per Debuffs-anchored claim, built by ComputeDebuffFlowSet below). It has to
-- be part of THIS string: the flowed entries are synthesised into `entries`,
-- so an anchor flip, a Debuff Category Priority reorder, a per-preset Relative
-- Size edit or a container size-override change all move the resolved flow
-- order -- and every one of them would otherwise be served the memoised shape.
--
-- v95 (2026-08-25) SIMPLE MODE: the two new keys lead the signature. Simple
-- Mode rebuilds the entry set from a different rule (processedAuraType
-- candidates, no Base Filter, no Sort Order, the three normal Combine flags
-- ignored) and "Separate Boss Debuffs" decides whether bigBoss is live
-- at all -- so either flip is a whole different shape and MUST invalidate the
-- memo. They are prepended rather than appended so a mode flip is visible in
-- the first two characters of any logged signature.
local function DebuffShapeSig(ac, claimSuffix, claims, myTypesSig, flowSig)
    local s = (ac.debuffSimpleMode == true and "S1" or "S0")
        .. (ac.debuffSimpleSeparateBoss == true and "b" or "B")
        -- 2026-08-25: Simple Mode's Exclude Applied by Friendly stamps a
        -- CANDIDATE (isFromPlayerOrPlayerPet) on the Debuffs group, so a flip
        -- is a different shape and must invalidate the memo -- exactly like
        -- the normal-mode Base Filter term that follows.
        .. (ac.debuffSimpleExcludeFriendly == true and "f" or "F")
        .. (ac.debuffBaseFilter or "none")
        .. (ac.debuffShowOther ~= false and "|O1:" or "|O0:")
        .. tostring(BF:DebuffRankOf(ac, "other"))
        -- v91: the myTypes signature (spec + talents + both By-Me toggles) and
        -- the three Combine flags are shape inputs now -- a spec change, a
        -- talent change or a Combine tick reshapes groups, filters and
        -- candidates alike, and every one of them has to invalidate this.
        .. "|" .. (myTypesSig or "dt:")
        .. "|c" .. (ac.debuffCombineBossRole == true and "1" or "0")
        .. (ac.debuffCombineDispel == true and "1" or "0")
        .. (ac.debuffCombinePriorityOther == true and "1" or "0")
        -- v88: Maximum Duration is baked into every group's candidate set, so a
        -- change must invalidate the cached shape (unlike Sort Order, which is
        -- applied separately and is not part of the cand -- v95 keeps that
        -- separation: DebuffGroupSortFor is re-evaluated and re-pushed through
        -- the change-guarded BF:SetAuraGridGroupSort on every Layout pass, so
        -- it needs no signature term of its own).
        --
        -- v95 FOLD-IN: the `other` candidate set now depends on which types
        -- render elsewhere, i.e. on every per-type Show (onKey), every claim,
        -- and all three Combine flags. ALL of those are already terms of this
        -- signature (base filter first, the combine trio above, and the
        -- on/size/rank/claim quad per type in the loop below), so the cached
        -- shape invalidates correctly with no new term. CONFIRMED by
        -- inspection, 2026-08-25.
        .. "|md:" .. (ac.debuffMaxDuration or "none")
        .. "|" .. (claimSuffix or "")
    for i = 1, #DEBUFF_TYPES do
        local t = DEBUFF_TYPES[i]
        s = s .. "|" .. (ac[t.onKey] == true and "1" or "0")
            .. ":" .. tostring(ac[t.sizeKey] or 1)
            -- v95: the Max is a LIVENESS input now (Simple Mode: dispMe Max
            -- 0 parks the group), so it has to move the signature too. RAW
            -- (ac[t.maxKey]), not ResolveDebuffTypeMax, which clamps 0 to 1
            -- and would hide exactly the flip this term exists for.
            .. ":m" .. tostring(ac[t.maxKey])
            .. ":" .. tostring(ac[t.rankKey] or t.seq)
            .. ":" .. (TypeClaimed(t, claims) and "c" or "-")
    end
    return s .. "|f:" .. (flowSig or "")
end

-- Resolve the whole shape: which groups are live, at what size, in what flow
-- order, with what filter string and candidate set. Called once per frame per
-- Layout; the result is cached on the frame under its signature and re-read by
-- the combat-edge candidate re-apply (which has no claim/settings context of
-- its own -- the same reason _bf_dbcClaimCats is stashed).
--
-- v92 §B3.2: `flowSet` / `flowSig` describe the DEBUFFS-anchored containers'
-- claimed presets (ComputeDebuffFlowSet). Each one becomes a SYNTHETIC LIVE
-- ENTRY here so it sorts through ShapeEntryLess with the seven real ones: that
-- is what puts a flowed container's icons at its Debuff Category Priority
-- position in the row, and what lets its size participate in maxMult ->
-- geo.lineSizeSlack. A synthetic entry is marked `flowed` and carries NO `t`
-- (no DEBUFF_TYPES row), so every walk that dereferences e.t must skip it --
-- see the three guards below and in ApplyDebuffTypeGroups /
-- ApplyDebuffLTDExcludes.
-- ── 2026-08-25: THE Simple Mode group rule, in ONE place ─────────────────
-- Which groups exist in Simple Mode was written out twice -- here, in
-- ResolveDebuffShape's simple branch, and again in debuffSimpleRowShown
-- (Options/Options_Auras.lua), whose own comment said it was a mirror that
-- "has to stay one". The debuff PREVIEW needs the same rule, which would have
-- made three copies of a rule that decides which groups render. Extracted
-- instead: this function is the rule, and all three read it.
--
--   ac      -- the aura cache, OR a `debuffs` profile sub-table. Only two keys
--              are read (debuffSimpleSeparateBoss and, through
--              BF:DebuffTypeMaxIsOff, debuffMaxDispMe) plus the rank / size
--              keys, and every one resolves identically raw or cached: the
--              cache stamps `== true` for the flag (nil -> false, same as the
--              raw read) and the Max test is `== 0` (nil is not 0).
--   claims  -- table keyed by TYPE ID with truthy values for the types a custom
--              debuff container has claimed. Exactly the shape
--              BF._ComputeDebuffContainerClaims returns, which is what the
--              options page and the preview both already hold.
--
-- Returns (rows, byId):
--   byId[id] = { id, live, claimed, rank, mult, max } for "other", "dispMe"
--              and "boss" -- the only three groups this mode can have.
--   rows     = the LIVE ones, sorted by rank then canonical sequence (the same
--              order ShapeEntryLess gives the real entries).
--
-- LIVE vs CLAIMED are reported separately on purpose: the options page shows a
-- CLAIMED row that is not live (its rank still decides container-preset
-- precedence and its Max slider is the only place that cap can be edited), so
-- a bare "does this group exist" answer would not serve it.
local SIMPLE_ROW_SEQ = { boss = 1, dispMe = 4, other = 7 }
-- Constant, not an inline literal in the loop below: this runs on the Layout
-- path, where a per-call table allocation is exactly what the rest of this
-- file goes out of its way to avoid.
local SIMPLE_ROW_IDS = { "boss", "dispMe", "other" }
local function SimpleRowLess(a, b)
    if a.rank ~= b.rank then return a.rank < b.rank end
    return a.seq < b.seq
end
function BF:ResolveSimpleDebuffRows(ac, claims)
    ac = ac or {}
    claims = claims or {}
    local tBoss = DEBUFF_TYPES[1]   -- boss
    local tMe   = DEBUFF_TYPES[4]   -- dispMe
    local byId = {
        -- The Debuffs group. Always live: it IS the row in this mode and has
        -- no Show toggle (debuffShowOther is a normal-mode key, deliberately
        -- not read here). `other` is not a claimable type.
        other = {
            id = "other", seq = SIMPLE_ROW_SEQ.other, live = true, claimed = false,
            rank = self:DebuffRankOf(ac, "other"), mult = 1,
        },
        -- Dispellable by Me. Parks when a container claimed it, or when its
        -- Max Debuffs is 0 -- this mode's OFF switch for the row, since it has
        -- no Show toggle either.
        dispMe = {
            id = "dispMe", seq = SIMPLE_ROW_SEQ.dispMe,
            claimed = (claims.dispelMe or claims.dispMe) and true or false,
            rank = self:DebuffRankOf(ac, "dispMe"), mult = ac[tMe.sizeKey] or 1,
        },
        -- Boss/Role. Its own group ONLY while "Separate Boss Debuffs" is
        -- ticked and neither half is claimed. Combined (the default),
        -- boss/role debuffs are Debuff-classified and flow inside the Debuffs
        -- group, sorted to the front by the tiered order.
        boss = {
            id = "boss", seq = SIMPLE_ROW_SEQ.boss,
            claimed = (claims.boss or claims.role) and true or false,
            rank = self:DebuffRankOf(ac, "boss"), mult = ac[tBoss.sizeKey] or 1,
        },
    }
    byId.dispMe.live = not byId.dispMe.claimed
        and not BF:DebuffTypeMaxIsOff(ac, "dispMe")
    byId.boss.live = (ac.debuffSimpleSeparateBoss == true) and not byId.boss.claimed
    local rows = {}
    for i = 1, #SIMPLE_ROW_IDS do
        local r = byId[SIMPLE_ROW_IDS[i]]
        -- Resolved, never raw: ResolveDebuffTypeMax clamps the 0 sentinel to 1
        -- so no consumer ever sees a zero cap.
        r.max = BF:ResolveDebuffTypeMax(ac, r.id)
        if r.live then rows[#rows + 1] = r end
    end
    table.sort(rows, SimpleRowLess)
    return rows, byId
end

-- Reusable claims view for the Layout path: ResolveSimpleDebuffRows wants a
-- table keyed by type id, and the entries above already carry `.claimed`.
-- Module-local and refilled per call rather than allocated, like every other
-- per-Layout scratch in this file. ResolveSimpleDebuffRows does not retain it.
local _simpleClaims = {}

-- 2026-08-25: EXPORTED for the debuff preview (Auras/DummyAuras.lua), which
-- used to hand-roll its own liveness and rank guesses for three of the seven
-- types and could therefore never show Role, CC or Priority -- nor agree with
-- the live row about a combined pair, a force-included Priority+Other or a
-- claimed group. `parent` is touched ONLY as the memo slot (_bf_dbShape), and
-- DebuffIcons:CanCreate refuses preview frames outright, so the live path can
-- never collide with a shape memoized on one. Named with the same `_` prefix
-- as the other cross-file debuff helpers (_ComputeDebuffContainerClaims,
-- _ComputeDebuffPresetRanks, _ComputeDebuffFlowSet).
local ResolveDebuffShape
function ResolveDebuffShape(parent, ac, claimSuffix, claims, flowSet, flowSig)
    local myTypes, myTypesSig = BF:MyDispelTypes(ac)
    local sig = DebuffShapeSig(ac, claimSuffix, claims, myTypesSig, flowSig)
    local cached = parent._bf_dbShape
    if cached and cached.sig == sig then return cached end
    local otherTypes = BF:OtherDispelTypes(myTypes)

    local entries, byId = {}, {}
    for i = 1, #DEBUFF_TYPES do
        local t = DEBUFF_TYPES[i]
        local claimed = TypeClaimed(t, claims)
        local e = {
            id = t.id, gk = t.gk, t = t, seq = t.seq,
            claimed = claimed,
            live = (ac[t.onKey] == true) and not claimed,
            mult = ac[t.sizeKey] or 1,
            -- v91: RANK, from the user's priority list. Unique 1..7.
            -- 2026-08-25: through the mode-aware resolver -- Simple Mode reads
            -- its own key set (BF:DebuffRankOf above), so a reorder in one
            -- mode cannot move the other's list.
            rank = BF:DebuffRankOf(ac, t.id),
            sub  = 0,
            dispelKind = t.dispel,
        }
        entries[i] = e
        byId[t.id] = e
    end
    local other = {
        id = "other", gk = "primary", seq = 7, mult = 1, sub = 0,
        live = ac.debuffShowOther ~= false,
        rank = BF:DebuffRankOf(ac, "other"),
    }
    entries[#entries + 1] = other
    byId.other = other

    -- ── v91 COMBINED PAIRS (owner ruling 2026-08-17) ─────────────────────
    -- Explicit checkboxes, NOT the retired same-size+adjacent auto-detect. A
    -- ticked pair renders as ONE row at min(member ranks) and uses the FIRST
    -- member's Show + Relative Size storage (Boss / DispMe / Other's
    -- debuffShowOther); unticking restores each member's own stored values.
    --
    -- A pair whose member is CLAIMED by a custom debuff container falls back
    -- to the SPLIT shape (the plan does not cover this case; splitting is the
    -- conservative answer -- combining would either duplicate the claimed
    -- container's content or swallow the unclaimed member).
    --
    -- v95 SIMPLE MODE (owner-approved plan 2026-08-25): all three Combine
    -- blocks are SKIPPED in that mode -- see the simple branch below.
    local bossE, roleE = byId.boss, byId.role
    local meE, othE = byId.dispMe, byId.dispOthers
    local prioE = byId.priority
    local simpleMode = ac.debuffSimpleMode == true

    if simpleMode then
        -- ── v95 SIMPLE MODE (owner ruling 2026-08-25) ────────────────────
        -- WHY a different entry set instead of a different options preset:
        -- Simple Mode is not "the seven categories arranged a certain way",
        -- it is Blizzard's OWN model -- one Debuffs group in the engine's
        -- priority order, Dispellable by Me beside it, Boss/Role optionally
        -- split out -- and that model is expressed in the engine as
        -- AuraUtil.ProcessAura's classification, not as filter tokens. See
        -- the ProcessAura facts in the header of DEBUFF_BASE_FILTERS: a
        -- debuff the PLAYER can dispel classifies Dispel, everything else the
        -- default raid frames show classifies Debuff, and
        -- candidateFilters.processedAuraType is an EXACT match with no OR --
        -- so "Blizzard's list" is exactly TWO engine groups and can be
        -- nothing else. (Owner accepted the two-group shape, and with it two
        -- Max Debuffs caps, 2026-08-25.)
        --
        -- WHY the seven type entries are still constructed above: they carry
        -- `claimed`, their `t` row, their `gk` and their RANK KEYS. Custom
        -- debuff containers keep working in this mode -- a claimed category
        -- stays a live claim, negates itself out of the simple groups through
        -- the ordinary AddTypeNegation chain, flows at its own rank, and shows
        -- as a claimed row on the options page. Only their own MAIN-ROW
        -- groups go away, which is what `live = false unless claimed` says.
        for i = 1, #DEBUFF_TYPES do
            local e = entries[i]
            if not e.claimed then e.live = false end
        end
        -- 2026-08-25: the three liveness decisions now come from
        -- BF:ResolveSimpleDebuffRows above -- the ONE statement of this mode's
        -- group rule, shared with the options page's row list and the debuff
        -- preview. Every rule that used to be written out here is stated
        -- there, in the same terms: Debuffs always live (it IS the row, and it
        -- has no Show toggle); Dispellable by Me parked by a claim or by the
        -- Max Debuffs 0 sentinel (this mode's OFF switch for a row with no
        -- Show toggle -- ResolveDebuffTypeMax still clamps the 0 to 1, so the
        -- parked group carries a legal maxFrameCount and the engine never sees
        -- a zero); Boss/Role its own group only while "Separate Boss Debuffs"
        -- is ticked and neither half is claimed, and otherwise flowing inside
        -- the Debuffs group where the tiered sort puts it at the front.
        _simpleClaims.boss     = bossE.claimed
        _simpleClaims.role     = roleE.claimed
        _simpleClaims.dispelMe = meE.claimed
        local _, simpleById = BF:ResolveSimpleDebuffRows(ac, _simpleClaims)
        other.live   = simpleById.other.live
        other.simple = true
        meE.live     = simpleById.dispMe.live
        meE.simple   = meE.live
        bossE.live   = simpleById.boss.live
        bossE.simple = bossE.live
    else
        local combineBossRole  = ac.debuffCombineBossRole == true
        local combineDispel    = ac.debuffCombineDispel == true
        local combinePrioOther = ac.debuffCombinePriorityOther == true

        -- Boss + Role: ONE group carrying candidateFilters.isBossOrRoleAura, the
        -- schema's only OR composite and exactly the "boss debuff" class
        -- Blizzard's own raid frames rank ahead. Lives on bigBoss at Boss's size;
        -- bigRole parks, keeping its pool for the split shape.
        if combineBossRole and not bossE.claimed and not roleE.claimed then
            bossE.merged = true
            if roleE.rank < bossE.rank then bossE.rank = roleE.rank end
            roleE.live = false
            roleE.mergedAway = true
        end

        -- Dispellable by Me + by Others: ONE group, plain HARMFUL|DISPELLABLE
        -- with no dispel-type candidate at all (the union of the two arms IS
        -- "dispellable"). Lives on `secondary` at DispMe's size; secondary2 parks.
        if combineDispel and not meE.claimed and not othE.claimed then
            meE.dispelKind = "both"
            if othE.rank < meE.rank then meE.rank = othE.rank end
            othE.live = false
            othE.mergedAway = true
        end

        -- Priority + Other: a REAL MERGE, like the other two pairs.
        --
        -- v91 made this one a FORCE-INCLUDE instead: bigPrio stayed its own
        -- LIVE group at base size, sharing primary's rank (sub 0/1) so it flowed
        -- immediately ahead, while primary kept its isPriorityAura = false
        -- negation. The reasoning was that a true merge drops any priority aura
        -- Other's Base Filter rejects, and force-including rendered them
        -- unconditionally while still reading as one run of icons.
        --
        -- 2026-08-25 (owner ruling): that is not what this box is meant to do.
        -- "Priority+Other is just meant to be one aura group for the engine,
        -- just filtering out everything else that was claimed." Two live groups
        -- also meant TWO caps -- debuffMaxPriority as well as debuffMaxOther --
        -- while the combined options row shows only the owner's single Max
        -- slider, so the row could render twice what its own control said (owner
        -- report: 3 priority icons plus 3 other icons in the preview).
        --
        -- Merging needs nothing but this: with prioE neither live nor claimed,
        -- the fold-in below stops stamping isPriorityAura = false, so priority
        -- auras simply stay in the residual group -- subject to its Base Filter,
        -- which is the accepted consequence. Show and Max both come from the
        -- FIRST member's storage, which for this pair is Other's
        -- (debuffShowOther / debuffMaxOther).
        if combinePrioOther and not prioE.claimed then
            prioE.live = false
            prioE.mergedAway = true
        end
    end

    -- ── v92 §B3.2: FLOWED CONTAINER ENTRIES ──────────────────────────────
    -- One synthetic entry per preset claimed by a DEBUFFS-anchored container.
    -- They are LIVE (their groups really render, inside this row) and carry the
    -- flowed mult of §B4, but they are NOT negation sources: the claim
    -- machinery above has parked the type's own MAIN-ROW entry, and that
    -- parked entry (live = false, claimed = true) is what carries the type
    -- into the AddTypeNegation chain -- v93, see ~:762. Adding the flowed
    -- entry as well would subtract the same content twice -- and it has no
    -- `t` row to negate BY in the first place.
    --
    -- seq = the preset's canonical row sequence + 0.5, so a flowed entry always
    -- sorts immediately AFTER the (parked) main-row entry of the same type it
    -- replaces, deterministically, even though the two share a rank by
    -- construction. Ties between two flowed entries (a ticked Combine box gives
    -- both members the same rank) fall to the same canonical order the rest of
    -- the addon uses.
    local flowEntries
    if flowSet and #flowSet > 0 then
        flowEntries = {}
        for i = 1, #flowSet do
            local f = flowSet[i]
            local fe = {
                id     = "fpre:" .. f.ci .. ":" .. f.pkey,
                gk     = "fpre" .. f.ci .. "_" .. f.pkey,
                flowed = true, ci = f.ci, pkey = f.pkey,
                seq    = (PRESET_ROW_SEQ[f.pkey] or 8) + 0.5,
                sub    = 0,
                live   = true,
                mult   = f.mult,
                rank   = f.rank,
                -- Carried for ApplyDebuffFlowedContainers (spec size + the
                -- container's own Max Icons); no consumer of the seven real
                -- entries reads either field.
                size = f.size, maxIcons = f.maxIcons,
            }
            entries[#entries + 1] = fe
            flowEntries[#flowEntries + 1] = fe
        end
    end

    table.sort(entries, ShapeEntryLess)

    -- Flow order. layoutIndex derives from the resolved sequence for ALL seven
    -- groups; parked ones take an index too, which costs nothing and keeps the
    -- indices dense. (Groups without a layoutIndex fall back to their
    -- registrationIndex, which COLLIDES -- PTR-observed.)
    -- v92: the flowed entries take an index from the SAME dense sequence, which
    -- is the whole point -- their icons land exactly where the unclaimed type
    -- would have. Their mult joins maxMult so lineSizeSlack covers an enlarged
    -- flowed icon the same way it covers an enlarged type group.
    local maxMult = 1
    for i = 1, #entries do
        local e = entries[i]
        e.li = i
        if e.live and e.mult > maxMult then maxMult = e.mult end
    end

    -- Per-group filter string + candidate set.
    for i = 1, #entries do
        local e = entries[i]
        if e.simple then
            -- ── v95 SIMPLE MODE GROUPS (owner-approved plan 2026-08-25) ──
            -- Three shapes, all on the permissive TYPE_BASE_FILTER token set:
            -- the CANDIDATE is the filter here, and the user's Base Filter is
            -- deliberately not read (in this mode the ENGINE'S OWN
            -- classification IS the filter -- that is what "the way the
            -- default raid frames do it" means).
            --
            --   other   processedAuraType = Debuff  -- boss/role, priority and
            --           every other debuff ShouldDisplayDebuff accepts
            --   dispMe  processedAuraType = Dispel  -- what the PLAYER can
            --           dispel, by the engine's own isRaid test (which is why
            --           the talent / long-cooldown governors are inert and
            --           hidden in this mode)
            --   boss    isBossOrRoleAura = true AND processedAuraType = Debuff
            --           -- only while the combine box is unticked. The Debuff
            --           term is what keeps this group DISJOINT from dispMe: a
            --           boss debuff the player can dispel classifies as Dispel
            --           (isRaid), and without the term it would match BOTH
            --           groups and render twice. Blizzard's own frames put it
            --           in the dispellable tier, so it belongs to dispMe here
            --           (plan: accepted). It also makes every member of this
            --           group classified, so the tiered sort would be safe on
            --           it too (DebuffGroupSortFor still uses Default: one
            --           tier).
            --
            -- Debuff and Dispel are DISJOINT by construction (ProcessAura
            -- returns exactly ONE type per aura), so other/dispMe can never
            -- double-render the same aura and no negation between them is
            -- needed or wanted; boss carries the Debuff term for the same
            -- reason, and other carries isBossOrRoleAura = false while boss is
            -- live (below), which closes the last overlap.
            --
            -- AuraUtil is resolved HERE, inside the function, never in a
            -- file-scope table: it is FrameXML's global and this file is
            -- parsed before it is guaranteed to exist -- the same rule
            -- ResolveDebuffSort follows for AuraContainerSortMethod.
            local AT = AuraUtil and AuraUtil.AuraUpdateChangedType
            local cand
            if e.id == "boss" then
                cand = { isBossOrRoleAura = true, processedAuraType = AT and AT.Debuff }
            elseif e.id == "dispMe" then
                -- No includeDispelTypes(myTypes) here, deliberately: the
                -- Dispel classification ALREADY means "dispellable by the
                -- player" (ProcessAura's last branch requires aura.isRaid),
                -- and AND-ing BF's own resolved type set on top would subtract
                -- exactly the cases where the resolver and the engine disagree
                -- -- i.e. re-introduce the guesswork this mode exists to
                -- remove.
                cand = { processedAuraType = AT and AT.Dispel }
            else
                cand = { processedAuraType = AT and AT.Debuff }
                -- SPLIT shape only: with Boss/Role live in its own group, the
                -- Debuffs group must not show them as well. Combined, this
                -- negation is absent ON PURPOSE -- boss/role debuffs are
                -- Debuff-classified and belong inside this group, where the
                -- tiered sort puts them at the front.
                if bossE.live then cand.isBossOrRoleAura = false end
                -- 2026-08-25 (owner request): "Exclude Applied by Friendly",
                -- Simple Mode's own copy of the normal-mode "noplayer" Base
                -- Filter rule -- drop debuffs the player or the player's pet
                -- applied. `false` is the candidate schema's negation, the
                -- same form the normal-mode branch uses.
                --
                -- SCOPE: this group ONLY, matching the normal-mode ruling that
                -- the Base Filter governs the residual Debuffs flow and
                -- nothing else. Dispellable by Me and the split Boss/Role
                -- group stay independent of it -- a boss debuff or one you can
                -- dispel has to show whoever applied it.
                if ac.debuffSimpleExcludeFriendly == true then
                    cand.isFromPlayerOrPlayerPet = false
                end
            end
            -- CLAIM NEGATIONS. A category claimed by a custom debuff container
            -- renders THERE, so it has to be subtracted here or the same aura
            -- shows twice (the engine does NOT de-dup groups within one
            -- container). AddTypeNegation is the machinery normal mode uses and
            -- handles every id: cc by TOKEN, the dispel arms by TYPE SET,
            -- boss/role/priority by candidate boolean -- including the split
            -- isBossAura / isRoleAura form when only one half of the pair is
            -- claimed (o.merged is always false on a claimed entry, so the
            -- isBossOrRoleAura composite cannot fire spuriously).
            --
            -- other/dispMe negate EVERY claimed category regardless of rank:
            -- both are "the auras the engine classified, minus what shows
            -- elsewhere" groups, so a claim ranked BELOW them still has to come
            -- out. `boss` negates only the claims ranked AHEAD of it, exactly
            -- as the normal chain does -- it is an ordinary priority-list row.
            local tok = ""
            local last = (e.id == "boss") and (i - 1) or #entries
            for j = 1, last do
                local o = entries[j]
                if o ~= e and o.claimed and not o.flowed and o.id ~= "other" then
                    tok, cand = AddTypeNegation(o, tok, cand, myTypes, otherTypes)
                end
            end
            e.cand = cand
            e.filter = AppendClaimTokens(TYPE_BASE_FILTER .. tok, claimSuffix)
        elseif e.id == "other" then
            -- ── v95 FOLD-IN (owner ruling 2026-08-25) ────────────────────
            -- `primary` used to negate EVERY type unconditionally, on the old
            -- rule "a disabled type never renders anywhere". That rule is
            -- RETIRED. The new one: **"Show" off means the type falls back
            -- into Other Debuffs**, subject to Other's own Base Filter. So
            -- primary negates only the types that RENDER SOMEWHERE ELSE --
            -- otherwise the aura would be displayed twice (the engine does NOT
            -- auto-dedup groups within one container).
            --
            -- "Renders somewhere else" is exactly three states:
            --   * `live`       -- the type owns a group in this row;
            --   * `claimed`    -- a custom debuff container renders it (in its
            --                    own container, or flowed into this row);
            --   * `mergedAway` INTO A LIVE COMBINED ROW -- role folded into a
            --     live bigBoss (isBossOrRoleAura), dispOthers folded into a
            --     live "both" dispel row. The liveness of the SURVIVOR is
            --     load-bearing: Combine Boss+Role with Show Boss off parks the
            --     combined group entirely, so neither boss nor role renders
            --     anywhere and BOTH must fall back here.
            -- bossE / roleE / meE / othE / prioE are the same entry tables the
            -- combine blocks above resolved; ccE has no combine partner.
            local ccE = byId.cc
            local bossOut = (bossE.live or bossE.claimed) and true or false
            local roleOut = (roleE.live or roleE.claimed
                or (roleE.mergedAway and bossE.live)) and true or false
            local cand = {}
            -- isBossOrRoleAura = false is exactly (isBossAura = false AND
            -- isRoleAura = false), so the single-candidate form still covers
            -- the both-elsewhere case; the split forms cover the rest.
            if bossOut and roleOut then
                cand.isBossOrRoleAura = false
            elseif bossOut then
                cand.isBossAura = false
            elseif roleOut then
                cand.isRoleAura = false
            end
            -- 2026-08-25: no `mergedAway` term here, unlike role above.
            -- Priority merges INTO this very group, so the survivor is
            -- `primary` itself -- there is nothing to subtract, and adding the
            -- negation would empty the merge of the only thing it merges.
            if prioE.live or prioE.claimed then
                cand.isPriorityAura = false
            end
            -- v91: the dispel arms subtract by TYPE SET, never by token. A live
            -- combined ("both") row covers the whole five-key set; each split
            -- arm covers its own. Claimed arms are ALSO stamped by the dispel-
            -- claims block further down -- MergeDispelTypes unions, so covering
            -- them here as well is idempotent, and it keeps this one place the
            -- readable statement of the fold-in rule.
            if meE.live or meE.claimed then
                cand = MergeDispelTypes(cand, "excludeDispelTypes",
                    (meE.dispelKind == "both") and ALL_DISPEL_TYPES or myTypes)
            end
            if othE.live or othE.claimed then
                cand = MergeDispelTypes(cand, "excludeDispelTypes", otherTypes)
            end
            -- v93 Base Filter "noplayer": drop debuffs the player or the
            -- player's pet applied. `false` is the candidate schema's
            -- negation, exactly like the booleans above -- omitting the field
            -- filters on nothing.
            --
            -- SCOPE (owner ruling): Base Filter governs the residual "Other
            -- Debuffs" flow ONLY, so this lands here and NOWHERE else. The
            -- type groups stay independent of it -- "Show Boss Auras" has to
            -- mean boss auras show, even one you applied yourself -- and
            -- debuff containers compose their own candidates.
            local bfKey = ac.debuffBaseFilter or "none"
            if bfKey == "noplayer" then
                cand.isFromPlayerOrPlayerPet = false
            end
            -- (Base Filter "blizzard" is a TOKEN -- see DEBUFF_BASE_FILTERS --
            -- and stamps no candidate here.)
            -- v95: |!CROWD_CONTROL only when CC renders elsewhere -- with Show
            -- Crowd Control off, crowd-control debuffs fall back into this row
            -- like any other folded-in type. (A CLAIMED cc also arrives via
            -- claimSuffix's DEBUFF_CLAIM_TOKEN entry; AppendClaimTokens skips
            -- the duplicate.)
            local base = DEBUFF_BASE_FILTERS[bfKey] or DEBUFF_BASE_FILTERS.none
            if ccE.live or ccE.claimed then base = base .. "|!CROWD_CONTROL" end
            e.cand = cand
            e.filter = AppendClaimTokens(base, claimSuffix)
        elseif e.live and not e.flowed then
            -- v92: a FLOWED entry has no filter/candidate work here at all --
            -- ApplyPresetGroups composes those from the preset def plus the
            -- cross-container de-dup negations. It has no `t` row either, so
            -- falling into this branch would index a nil.
            local tok, cand = "", nil
            for j = 1, i - 1 do
                local o = entries[j]
                -- v92: `not o.flowed` -- flowed entries are NOT negation
                -- sources. The claim machinery already subtracted their content
                -- out of every live group; negating again would double-subtract
                -- (and AddTypeNegation dereferences o.t, which they lack).
                --
                -- v93: `o.live or o.claimed` -- a CLAIMED type is not live (its
                -- own main-row group is parked) but its content still RENDERS,
                -- in the container that claimed it. It must therefore still
                -- subtract itself out of every lower-ranked live group, or the
                -- same aura satisfies both the container's preset group and a
                -- lower-ranked type group and renders twice (the engine does
                -- NOT auto-dedup groups within one container -- see ~:1341).
                -- Rank-correct by construction: only entries ahead of `i` in
                -- the sorted chain negate, so a claim never reaches a group
                -- ranked above it. Claimed entries carry a real `t` row, so
                -- AddTypeNegation works on them unchanged -- unlike flowed
                -- entries, which is why `not o.flowed` stays. `o.merged` is
                -- always false for a claimed entry (the combine blocks require
                -- `not claimed`), so the isBossOrRoleAura branch cannot fire
                -- spuriously; `mergedAway` entries are neither live nor
                -- claimed and stay correctly excluded.
                if o.id ~= "other" and (o.live or o.claimed) and not o.flowed then
                    tok, cand = AddTypeNegation(o, tok, cand, myTypes, otherTypes)
                end
            end
            local base
            if e.dispelKind then
                base = DISPEL_GROUP_FILTER
                -- The combined row needs no dispel candidate: DISPELLABLE
                -- already IS the union of the two arms.
                if e.dispelKind ~= "both" then
                    cand = MergeDispelTypes(cand, "includeDispelTypes",
                        (e.dispelKind == "me") and myTypes or otherTypes)
                end
            else
                base = e.t.filter or TYPE_BASE_FILTER
                if e.t.cand then
                    cand = cand or {}
                    cand[e.merged and "isBossOrRoleAura" or e.t.cand] = true
                end
            end
            e.cand = cand
            e.filter = AppendClaimTokens(base .. tok, claimSuffix)
        end
    end

    -- v91: DISPEL CLAIMS. A custom debuff container holding meDispellable /
    -- othersDispellable used to append a |!RAID / |!DISPELLABLE token to every
    -- main-row filter. Those tokens are gone (they OR-mask against the dispel
    -- groups' own DISPELLABLE token), so the claim is stamped as an
    -- excludeDispelTypes union on EVERY live group instead -- candidates AND,
    -- so this subtracts exactly the claimed arm and nothing else. The claimed
    -- type's own group is not live, so it can never subtract itself away.
    if claims and (claims.dispelMe or claims.dispelOthers) then
        for i = 1, #entries do
            local e = entries[i]
            -- v92: flowed entries own no candidate set here (see above).
            if e.live and not e.flowed then
                if claims.dispelMe then
                    e.cand = MergeDispelTypes(e.cand, "excludeDispelTypes", myTypes)
                end
                if claims.dispelOthers then
                    e.cand = MergeDispelTypes(e.cand, "excludeDispelTypes", otherTypes)
                end
            end
        end
    end

    -- v88: Maximum Duration — stamp the engine maxDuration candidate filter
    -- onto EVERY live group uniformly (it is a debuff-wide setting, not
    -- per-type). Engine-side: it filters on the aura's declared MAX duration
    -- and hides permanents, so it works while remaining duration is secret.
    local maxDur = DEBUFF_MAX_DURATION_SECONDS[ac.debuffMaxDuration or "none"]
    if maxDur then
        for i = 1, #entries do
            local e = entries[i]
            -- v92: NOT the flowed entries -- a flowed container carries its own
            -- Maximum Duration (BF.DebuffContainerMaxDuration, follow-until-
            -- overridden), stamped by ApplyPresetGroups. Applying the row's here
            -- would silently override a container that opted out of it.
            if e.live and not e.flowed then
                e.cand = e.cand or {}
                e.cand.maxDuration = maxDur
            end
        end
    end

    local shape = {
        sig = sig, order = entries, byId = byId,
        maxMult = maxMult, merged = bossE.merged == true,
        -- v92: the synthetic entries, in resolved flow order, for
        -- ApplyDebuffFlowedContainers (which needs e.li per (ci, pkey)).
        flow = flowEntries,
    }
    parent._bf_dbShape = shape
    return shape
end

local function DebuffContainerSpecs(frame)
    local ac = BF:GetAuraCacheForFrame(frame)
    local db = BF:GetSectionProfileForFrame("tooltips", frame)
    local size = ac._roundedDebuffSize or 12
    local autoScale = ac.debuffAutoScale
    local buttonSpec = {
        size             = size,
        showDuration     = ac.showDebuffDuration and true or false,
        durationFont     = ac.debuffDurationFont,
        durationFontSize = autoScale and 11 or (ac.debuffFontSize or 11),
        durationBorder   = ac.debuffDurationBorder or "OUTLINE",
        durationScale    = autoScale and (size / 12 * (ac.debuffTimerScale or 1.0)) or nil,
        fontColor        = ac.debuffFontColor,
        durationCurve    = ac.expiringCurveDebuff,
        hideDurationAbove1Min = ac.hideDurAbove1MinDebuff,
        disableSwipe     = ac.disableDebuffSwipe,
        disableSpark     = ac.disableDebuffSpark,
        reverseSwipe     = ac.reverseDebuffSwipe,
        dispelBorder     = true,
        dispelBorderThickness = ac.debuffDispelBorderThickness,
        -- v71: color the whole border by dispel type (default on). When on, the
        -- base border joins the dispel-type binding, so a dispellable debuff's
        -- WHOLE border is dispel-colored (typeless keeps the configured color).
        colorBorderByDispel = ac.debuffColorBorderByDispel ~= false,
        -- v71: engine-drawn dispel-type icon in the top-right corner (only
        -- shows on dispellable debuffs). Main Debuffs row reads the section
        -- toggle + size directly.
        dispelTypeIcon      = ac.showDebuffDispelTypeIcon == true,
        dispelTypeIconScale = ac.debuffDispelTypeIconScale or 40,
        borderColor      = ac.debuffBorderColor,      -- static base; opaque dispel set draws over it
        blizzardBorders  = ac.debuffBlizzardBorders,
        borderStyle      = ac.debuffBorderStyle,
        borderThickness  = ac.debuffBorderThickness,
        tooltipEnabled   = ac.showDebuffTooltip or false,
        tooltipInCombat  = ac.showDebuffTooltipInCombat or false,
        tooltipPos       = db and db.debuffTooltipPosition or "default",
        tooltipFrameY    = BF.TooltipBelowFrameY(frame, ac.debuffAnchor, ac.debuffOffsetY, size),
        -- NOTE: debuffDurationDispelColor (dispel-tinted timer text) is CUT
        -- on the container path — no dispel-driven text binding exists.
    }
    -- Stack text (Aura Text > Stack Text). Folded onto the button spec so
    -- ContainerFactory's ApplyStackCountStyle can stamp it at creation and
    -- on every restyle walk -- see BF:ApplyStackTextSpec.
    BF:ApplyStackTextSpec(buttonSpec, ac, size)
    local geo = {
        size          = size,
        anchor        = ac.debuffAnchor or "BOTTOMLEFT",
        offsetX       = ac.debuffOffsetX,
        -- v67: the + extraDebuffYOffset term went with the Private Auras
        -- feature. That offset only became non-zero under
        -- separatePrivateAurasInRaid/InParty, which no options widget ever
        -- wrote, so it was already 0 for every real profile.
        offsetY       = ac.debuffOffsetY or 0,
        growDirection = ac.debuffGrowDir,
        perRow        = ac.debuffsPerRow,
        spacing       = ac.debuffSpacing,
        rowSpacing    = ac.debuffRowSpacing,
        maxIcons      = ac.maxDebuffs or 8,
        -- aurasAbovePowerBar lift: resolved inside ApplyAuraGridGeometry
        -- (bottom-anchor gate + clipFrame target) and re-resolved by
        -- ReanchorFrameAuraContainers on power-bar toggles.
        canLift       = true,
    }
    -- v54/v84: with any LIVE type group larger than the base size, widen the
    -- pixel wrap budget by that group's extra width so "Debuffs Per Row" holds
    -- for rows containing one big icon (see SetFlowLayoutMaximumLineSize).
    -- geo.lineSizeSlack is stamped by the caller once the shape is resolved
    -- (it needs the resolved per-type sizes, which need the claim pass).
    return buttonSpec, geo
end

-- ── v68: custom debuff containers CLAIM their categories out of the main ──
-- Debuffs display, so a debuff shown in a container is not duplicated in the
-- main row. Preset-only containers match by CATEGORY, so the claim is a set of
-- negation TOKENS (appended to the primary/secondary filter strings) plus a set
-- of candidate-filter CATEGORY negations (isBossAura/etc — applied to primary
-- and used to park the matching enlarged group). There is NO nonDispellable
-- entry because there is no such preset any more: opposing dispel tokens
-- combine as an OR-mask, not an AND (the PTR-confirmed HELPFUL|HARMFUL note
-- in ContainerFactory — that filter matched EVERYTHING), so |DISPELLABLE
-- appended next to a |!DISPELLABLE claim would widen the main row to all
-- debuffs rather than empty it. No clean negation exists, hence the preset
-- was removed outright (owner, 2026-08-14): the "regular debuffs" view falls
-- out by ELIMINATION once the dispellable categories are claimed away. Each
-- container's per-Layout "Enabled for this Layout" flag is honored — a
-- container hidden on this Layout claims nothing.
-- v91: the two DISPEL claim tokens (|!DISPELLABLE for the retired
-- allDispellable preset, |!RAID for meDispellable) are GONE. Both are now
-- expressed as excludeDispelTypes unions in ResolveDebuffShape / the preset
-- negations: a token can only ever say "all dispellable" or "the ones I can
-- dispel", it OR-masks against the dispel groups' own DISPELLABLE token, and
-- it cannot express the By-Others arm at all. Only CC still claims by token
-- (CROWD_CONTROL has no candidate-filter equivalent).
local DEBUFF_CLAIM_TOKEN = {
    -- v69: Crowd Control is a preset now (the dedicated feature is gone). Its
    -- claim is the same |!CROWD_CONTROL the old showCrowdControl toggle used
    -- to append via DebuffContainerFilters' noCC arm.
    crowdControl   = "|!CROWD_CONTROL",
}
local DEBUFF_CLAIM_CAT = {
    boss     = "isBossAura",
    priority = "isPriorityAura",
    role     = "isRoleAura",
}
-- v84: the same claim, expressed per DEBUFF TYPE id (the shape resolver's
-- vocabulary). A claimed type parks its main-row group and hides its options
-- row -- claim beats the toggle, exactly today's rule.
-- v91: allDispellable is RETIRED; the two dispel presets claim their own arm,
-- matching the main row's split (claimIds dispelMe / dispelOthers).
local DEBUFF_CLAIM_TYPE = {
    boss              = "boss",
    priority          = "priority",
    role              = "role",
    crowdControl      = "cc",
    meDispellable     = "dispelMe",
    othersDispellable = "dispelOthers",
}

-- ══ v92: COMBINED PAIRS ACT AS ONE UNIT (owner ruling 2026-08-20) ══════════
--
-- A ticked Combine box on the Debuffs Preset/Filter page makes its two
-- categories one row in the main display. The owner's ruling extends that to
-- CONTAINER ASSIGNMENT: on a Layout where the box is ticked, the pair is one
-- indivisible thing, so the PARTNER (second member) behaves as if it lived in
-- whichever container holds the FIRST member.
--
-- Three decisions, all load-bearing:
--
--  1. PER-LAYOUT RUNTIME FOLLOW, never a data rewrite. c.presets is untouched;
--     this is resolved per pass from the Layout's own combine flag. Untick the
--     box (or switch to a Layout where it is off) and the stored assignments
--     apply again, unchanged, with no migration and nothing to undo.
--  2. "BOSS ALWAYS WINS". The pair's effective owner is the FIRST member's
--     container. With the first member unassigned the pair is UNOWNED, and the
--     partner's own stored assignment is SUPPRESSED -- the pair renders in the
--     main row instead. Half a pair in a container is exactly what "acts as one
--     unit" forbids.
--  3. The virtual partner renders at the FIRST member's Relative Size, matching
--     the combined slider's read-first rule (Options_AuraCustomizations.lua).
--
-- Runtime twin of the options-side DEBUFF_PRESET_PAIRS; the two must stay in
-- lockstep (same members, same flag keys, same nil-defaults). Priority/Other is
-- absent for the same reason there: "Other" is not an assignable preset.
local DEBUFF_COMBINE_PAIRS = {
    { first = "boss",          second = "role",
      flagKey = "debuffCombineBossRole", flagDefault = true },
    { first = "meDispellable", second = "othersDispellable",
      flagKey = "debuffCombineDispel",   flagDefault = false },
}
-- Interned per-pair state, re-pointed by every ResolveDebuffPairOwnership call.
-- Callers READ these within the pass that produced them and must never stash
-- one across passes -- the GetSingleBuffAnchorHost interning discipline.
local _pairState = {}
for i = 1, #DEBUFF_COMBINE_PAIRS do
    local p = DEBUFF_COMBINE_PAIRS[i]
    _pairState[i] = { first = p.first, second = p.second, ci = nil }
end
local _pairOwnScratch = {}

-- THE one nil-default rule for every Combine flag in this file.
--
-- `flags` is any table carrying the combine keys: the frame's aura cache at
-- runtime (UpdateDB writes real booleans there, so the nil-default never fires),
-- or a raw per-Layout debuffs profile on the options paths -- where nil is the
-- COMMON case, not an edge one. Profiles are SPARSE: a field whose value equals
-- the shipped default is stored as nil, so "Combine Boss + Role is on" -- the
-- default -- is on disk as ABSENT. A bare `flags[key] == true` therefore reads a
-- default-ON flag as OFF on exactly the profiles most users have.
-- v92: ComputeDebuffPresetRanks shares this (it used to spell the test out with
-- `== true`, which was safe only for as long as every caller fed it a cache).
--
-- v95 SIMPLE MODE (owner ruling 2026-08-25): Boss and Role are ALWAYS one unit
-- in Simple Mode, and the two other pairs are never combined there -- the
-- normal-mode Combine boxes are hidden and ignored. Enforced HERE, in the one
-- rule every pair consumer reads (ResolveDebuffPairOwnership -> the
-- claim-coherent pair ownership, ComputeDebuffPresetRanks), so a container
-- claiming either Boss or Role claims the PAIR in this mode, exactly as a
-- combined pair does in normal mode -- and the options page's
-- debuffRowCombineOn mirrors this.
local function CombineFlagOn(flags, key, default)
    if flags and flags.debuffSimpleMode == true then
        return key == "debuffCombineBossRole"
    end
    local v = flags and flags[key]
    if v == nil then return default end
    return v == true
end
local function PairCombineOn(flags, pair)
    return CombineFlagOn(flags, pair.flagKey, pair.flagDefault)
end

-- Which container effectively owns each COMBINED pair on this Layout?
--
-- Returns nil when no pair is combined (the overwhelmingly common shape for the
-- dispel pair, and the whole feature's off-switch), else a map
--     [secondPresetKey] = { first = <firstPresetKey>, second = <key>, ci = <n or nil> }
-- Presence in the map means "this pair is combined here"; `ci` is the owner, or
-- nil for combined-but-unowned. Distinguishing the two matters: absent means
-- stored assignments rule, present-with-nil-ci means the partner is suppressed
-- EVERYWHERE.
--
-- Gates match ComputeDebuffContainerClaims exactly (global Enabled, then the
-- per-Layout showForGroupType under the container's own perLayoutConfig or the
-- group's CFG Debuffs override) -- a container that claims nothing here must not
-- be able to own a pair either.
local function ResolveDebuffPairOwnership(flags, groupTypeKey)
    local own
    for i = 1, #DEBUFF_COMBINE_PAIRS do
        local pair = DEBUFF_COMBINE_PAIRS[i]
        if PairCombineOn(flags, pair) then
            if not own then
                own = _pairOwnScratch
                for k in pairs(own) do own[k] = nil end
            end
            local st = _pairState[i]
            st.ci = nil
            own[pair.second] = st
        end
    end
    if not own then return nil end
    local containers = BF:GetActiveCustomDebuffContainers()
    if not containers or #containers == 0 then return own end
    -- v65: hoist the GROUP RESOLUTION, never the ANSWER -- see the identical
    -- block in ComputeDebuffContainerClaims below.
    local isCFG = type(groupTypeKey) == "string" and not groupTypeKey:find("^flat_")
    local grp   = isCFG and BF.ResolveCFGGroupByFlatID
        and BF:ResolveCFGGroupByFlatID(groupTypeKey) or nil
    local cfgOn = grp and grp[BF.AURAS_GROUP_CFG_FLAG.aurasDebuffs] or false
    for ci, c in ipairs(containers) do
        local shown = c.enabled ~= false
        if shown and c.groupSettings and (c.perLayoutConfig == true or cfgOn) then
            local gs = c.groupSettings[groupTypeKey]
            if gs and gs.showForGroupType == false then shown = false end
        end
        if shown and c.presets then
            for i2 = 1, #DEBUFF_COMBINE_PAIRS do
                local pair = DEBUFF_COMBINE_PAIRS[i2]
                local st = own[pair.second]
                -- First container holding the FIRST member wins. The options UI
                -- makes a preset one-container-only, so this is a formality --
                -- but a hand-edited profile must resolve to ONE owner, not two.
                if st and st.ci == nil and c.presets[pair.first] then st.ci = ci end
            end
        end
    end
    return own
end
BF._ResolveDebuffPairOwnership = ResolveDebuffPairOwnership

-- The preset set container `ci` EFFECTIVELY renders on this Layout: its stored
-- set, plus the partner it owns, minus any partner it does not.
--
-- Returns `c.presets` ITSELF when nothing changes (the common case, and zero
-- cost); otherwise a module scratch. NOT REENTRANT -- every caller consumes the
-- result before the next call, and none of them retain it. Same discipline as
-- _dtgScratch above.
local _effPresetScratch = {}
local function EffectiveDebuffPresetSet(c, ci, pairOwn)
    local presets = c.presets
    if not pairOwn then return presets end
    local out
    for i = 1, #DEBUFF_COMBINE_PAIRS do
        local pair = DEBUFF_COMBINE_PAIRS[i]
        local st = pairOwn[pair.second]
        if st then
            local wants = (st.ci ~= nil and st.ci == ci)
            local has   = (presets and presets[pair.second]) and true or false
            if wants ~= has then
                if not out then
                    out = _effPresetScratch
                    for k in pairs(out) do out[k] = nil end
                    if presets then
                        for k, v in pairs(presets) do out[k] = v end
                    end
                end
                out[pair.second] = wants or nil
            end
        end
    end
    return out or presets
end
BF._EffectiveDebuffPresetSet = EffectiveDebuffPresetSet

-- Ratio source for a preset on a container: the virtual partner of a combined
-- pair reads the FIRST member's Relative Size (owner decision 3). Returns the
-- key to look the ratio up under -- `pkey` itself whenever no pair applies.
local function DebuffPresetRatioKey(pkey, pairOwn)
    if not pairOwn then return pkey end
    local st = pairOwn[pkey]
    return (st and st.first) or pkey
end
BF._DebuffPresetRatioKey = DebuffPresetRatioKey

-- The per-Layout debuffs profile behind a flat ID / CFG flat, for the OPTIONS
-- paths that resolve claims for a Layout they are not standing in
-- (GetDebuffTypeClaims / GetDebuffTypeClaimInfo). Runtime callers pass the
-- frame's aura cache instead and never reach this. Nil when unresolvable; every
-- caller then falls back to PairCombineOn's shipped defaults.
local function DebuffsProfileForFlat(flatID)
    local fl = BF.rpDB and BF.rpDB.profile and BF.rpDB.profile.layouts
        and BF.rpDB.profile.layouts.flatLayouts
    local flat = (type(flatID) == "string" and fl) and fl[flatID] or nil
    local grp
    if type(flatID) == "string" and not flatID:find("^flat_")
       and BF.ResolveCFGGroupByFlatID then
        grp = BF:ResolveCFGGroupByFlatID(flatID)
    end
    if not BF.ResolveCFGAurasSubcat then return nil end
    local p = BF.ResolveCFGAurasSubcat(BF, flat, grp, "debuffs")
    if type(p) ~= "table" then return nil end
    return p
end
-- v92 §B3.1: FIFTH return -- `flowClaims`, a map pkey -> ci for every claim
-- whose owning container is DEBUFFS-anchored on this Layout. Deliberately a
-- PARALLEL map rather than a reshape of `claims[pkey] = true`: every existing
-- consumer (ResolveDebuffShape's TypeClaimed, DebuffShapeSig, the options
-- page's GetDebuffTypeClaims) tests the claim as a boolean, and widening it to
-- a table would have made each of them pay a field read for an answer only the
-- flow builder wants.
--
-- The CLAIM ITSELF IS UNCHANGED by flowing: the type's main-row group still
-- parks (TypeClaimed) and the negation chain still subtracts the claimed
-- content out of primary and every live group. That is what prevents
-- duplicates, and it is orthogonal to WHERE the container's own icons render.
-- Note the map is keyed by PRESET key (the container vocabulary), not by the
-- shape resolver's type id -- the flow builder feeds ApplyPresetGroups, which
-- speaks presets.
--
-- v92 (owner ruling 2026-08-20): the loop claims from each container's
-- EFFECTIVE preset set, not its stored one. That single substitution gives the
-- whole virtual-claim rule for free: the owner container claims the partner
-- (same ci, so the same tokens, categories and flow-ness), a non-owner stops
-- claiming it, and an unowned combined pair is claimed by nobody -- which is
-- exactly "the pair renders in the main row". `pairOwn` is resolved once per
-- pass by the caller (ResolveDebuffPairOwnership); nil means no pair is
-- combined and every gate below reads stored data, byte-identical to pre-v92.
local function ComputeDebuffContainerClaims(parent, groupTypeKey, pairOwn)
    local containers = BF:GetActiveCustomDebuffContainers()
    if not containers or #containers == 0 then return "", nil, false, nil, nil end
    local haveTok, cats, claims, flowClaims = {}, nil, nil, nil
    -- v65: hoist the GROUP RESOLUTION, never the ANSWER.
    --
    -- The per-Layout question has two gates (BF:IsContainerPerLayoutActive):
    -- the CONTAINER's own perLayoutConfig flag, and -- for a CFG scope only --
    -- that group's Debuffs override flag. The first is per container, so the
    -- answer CANNOT be hoisted out of this loop the way it was before v65; a
    -- hoisted answer would ignore c.perLayoutConfig entirely.
    --
    -- What IS constant for the whole pass is groupTypeKey, and therefore the
    -- group it resolves to. Resolving it once here keeps the linear
    -- ResolveCFGGroupByFlatID scan at ONE per Layout pass -- exactly what it
    -- costs today -- and leaves each container paying one field read plus one
    -- boolean OR. Calling the predicate per container instead would turn that
    -- into O(containers x CFG groups). Do not "restore" the old hoist.
    -- type() guard, not a bare find: ResolveGroupTypeKey can hand back nil for
    -- a CFG frame whose flat ID has not been minted yet, and the predicate this
    -- replaces type-checked its key.
    local isCFG = type(groupTypeKey) == "string" and not groupTypeKey:find("^flat_")
    local grp   = isCFG and BF.ResolveCFGGroupByFlatID
        and BF:ResolveCFGGroupByFlatID(groupTypeKey) or nil
    local cfgOn = grp and grp[BF.AURAS_GROUP_CFG_FLAG.aurasDebuffs] or false
    for ci, c in ipairs(containers) do
        local perLayout = c.perLayoutConfig == true or cfgOn
        -- Global Enabled gate first (v69): a disabled container renders
        -- nothing and must claim nothing, or its category would vanish from
        -- the addon entirely (claimed out of the main row, shown nowhere).
        local shown = c.enabled ~= false
        if shown and c.groupSettings and perLayout then
            local gs = c.groupSettings[groupTypeKey]
            if gs and gs.showForGroupType == false then shown = false end
        end
        local eff = shown and EffectiveDebuffPresetSet(c, ci, pairOwn) or nil
        if shown and eff then
            -- v92: resolved ONCE per container (the per-Layout tier resolution
            -- is not free), never per preset.
            local flowed = BF.IsDebuffContainerDebuffsAnchored
                and BF:IsDebuffContainerDebuffsAnchored(c, groupTypeKey) or false
            for pkey in pairs(eff) do
                local tok = DEBUFF_CLAIM_TOKEN[pkey]
                if tok then haveTok[tok] = true end
                local cat = DEBUFF_CLAIM_CAT[pkey]
                if cat then cats = cats or {}; cats[cat] = true end
                local ct = DEBUFF_CLAIM_TYPE[pkey]
                if ct then claims = claims or {}; claims[ct] = true end
                -- v92: only presets that actually claim a TYPE can flow -- a
                -- preset with no main-row twin has no rank to place it at.
                -- (Every DEBUFF_CONTAINER_PRESET has one today; the guard keeps
                -- a future non-claiming preset out of the flow rather than
                -- letting it fall back to rank 8.)
                if flowed and ct then
                    flowClaims = flowClaims or {}
                    if not flowClaims[pkey] then flowClaims[pkey] = ci end
                end
            end
        end
    end
    -- Fixed token order so the change-guarded SetAuraGridGroupFilter sees a
    -- stable string across passes.
    -- v91: CROWD_CONTROL is the only claim token left (see DEBUFF_CLAIM_TOKEN).
    local suffix = ""
    if haveTok["|!CROWD_CONTROL"] then suffix = suffix .. "|!CROWD_CONTROL" end
    -- Third return: "a live container claims CC" (kept for the stashed
    -- _bf_dbcClaimCC flag). Fourth (v84): the per-TYPE claim view the shape
    -- resolver and the options page consume. Fifth (v92): the flowed-claim map.
    return suffix, cats, haveTok["|!CROWD_CONTROL"] == true, claims, flowClaims
end

-- Settings-time claim view for the options page, scoped to the LAYOUT the
-- options panel is currently editing (BF._modifyingFlat). A type is treated as
-- claimed only if a container owns it ON THAT LAYOUT, so the answer mirrors what
-- the runtime shape resolver would park for a real frame on that Layout.
--
-- Passing the modifying-Layout key (instead of the old nil) makes the per-Layout
-- gate inside ComputeDebuffContainerClaims fire: a container set to "Enabled for
-- this Layout = off" on the edited Layout (groupSettings[flatID].showForGroupType
-- == false, under perLayoutConfig) no longer claims its presets THERE, so the
-- type's group re-appears in Preset/Filter for every Layout the container does
-- not own. A non-per-Layout container still claims on every Layout (its single
-- shared config applies everywhere) -- again matching the runtime.
--
-- (This replaces the pre-v89 "claimed on at least one Layout" global view, which
-- hid a type row on Raid just because a Party-only container owned it.)
function BF:GetDebuffTypeClaims()
    local flatID = self._modifyingFlat
    if type(flatID) ~= "string" then
        flatID = self:ResolveActiveFlat(self:GetActiveSlot())
        if type(flatID) ~= "string" or flatID == "none" then flatID = "flat_party" end
    end
    -- v92: the EDITED Layout's own combine flags decide pair ownership, so the
    -- priority list's claim notes report the virtual claim too ("Role Auras --
    -- In Container: <the Boss container>") on Layouts where the pair is
    -- combined, and the stored one where it is not. Cold path: one extra flat
    -- resolution per options render.
    local pairOwn = ResolveDebuffPairOwnership(DebuffsProfileForFlat(flatID), flatID)
    local _, _, _, claims = ComputeDebuffContainerClaims(nil, flatID, pairOwn)
    return claims
end

-- Options-only companion to GetDebuffTypeClaims. For every claimed debuff TYPE
-- (keyed exactly like the claims map: boss / role / cc / priority / dispelMe /
-- dispelOthers -- v91) it returns { names = "<A>" or "<A>, <B>", perLayout = <bool> } so the
-- Preset/Filter page can show WHERE the type is being displayed instead of just
-- hiding the row. Scoped to the Layout the panel is editing (BF._modifyingFlat),
-- with the SAME enabled / per-Layout / showForGroupType gates as
-- ComputeDebuffContainerClaims, so its claimed set matches GetDebuffTypeClaims
-- exactly (a type has a note here iff its row is claimed there).
--
--   perLayout = true  -> claimed ONLY by per-Layout container(s); the assignment
--                        is contingent on THIS Layout (note adds
--                        "for the current Layout").
--   perLayout = false -> at least one always-on container claims it, so it is
--                        claimed on every Layout (no Layout qualifier).
--
-- Cold path: runs on options render only. It deliberately does NOT share the hot
-- ComputeDebuffContainerClaims scan, because it needs the container NAME, which
-- that function has no reason to collect on the per-frame path. flatID here is
-- always an RP flat ("flat_..."), so the CFG cfgOn branch is not reachable and
-- is omitted; perLayout is therefore just the container's own perLayoutConfig.
function BF:GetDebuffTypeClaimInfo()
    local containers = self:GetActiveCustomDebuffContainers()
    if not containers or #containers == 0 then return nil end
    local flatID = self._modifyingFlat
    if type(flatID) ~= "string" then
        flatID = self:ResolveActiveFlat(self:GetActiveSlot())
        if type(flatID) ~= "string" or flatID == "none" then flatID = "flat_party" end
    end
    local info
    -- v92: same effective-ownership view as GetDebuffTypeClaims, so a virtual
    -- claim names the OWNER container ("Role Auras -- In Container: Boss Stuff")
    -- rather than wherever the partner happens to be stored. The two must agree:
    -- a type has a note here iff its row is claimed there.
    local pairOwn = ResolveDebuffPairOwnership(DebuffsProfileForFlat(flatID), flatID)
    for ci, c in ipairs(containers) do
        local perLayout = c.perLayoutConfig == true
        local shown = c.enabled ~= false
        if shown and c.groupSettings and perLayout then
            local gs = c.groupSettings[flatID]
            if gs and gs.showForGroupType == false then shown = false end
        end
        local eff = shown and EffectiveDebuffPresetSet(c, ci, pairOwn) or nil
        if shown and eff then
            -- The scratch is re-pointed by the next EffectiveDebuffPresetSet
            -- call, and this loop makes one per container -- so the set must be
            -- fully consumed here, before the next iteration. It is.
            for pkey in pairs(eff) do
                local ct = DEBUFF_CLAIM_TYPE[pkey]
                if ct then
                    info = info or {}
                    local e = info[ct]
                    local nm = c.name or "a custom container"
                    if not e then
                        -- v91: `index` is the container's position in the
                        -- GetCustomDebuffContainers array (GetActive* is the
                        -- same array, cached) -- exactly the <i> of the
                        -- options page's "debuffContainer_<i>" subtab key, so
                        -- the priority list's "In Container" button can
                        -- SelectGroup straight to it. First claimer wins
                        -- (presets are one-container by invariant anyway).
                        info[ct] = { names = nm, perLayout = perLayout, index = ci }
                    else
                        if not e.names:find(nm, 1, true) then
                            e.names = e.names .. ", " .. nm
                        end
                        -- "for the current Layout" only if EVERY claimer is
                        -- per-Layout; one always-on claimer makes it global.
                        e.perLayout = e.perLayout and perLayout
                    end
                end
            end
        end
    end
    return info
end

-- ── v71: preset DE-DUP (within AND across debuff containers) ──────────────
-- The engine does NOT auto-dedup groups within one container (PTR-observed:
-- an aura matching two preset groups renders twice, and a third time in
-- another container's overlapping preset). So each preset group must NEGATE
-- every higher-precedence preset PRESENT anywhere, leaving each aura in exactly
-- one group. Same facilities the main-row claim uses: filter-string tokens for
-- dispel/CC, candidate booleans for the categories, plus excludeDispelTypes for
-- the warlock Magic case (a candidate, so no OR-mask token trap).
--
-- v91 (owner ruling 2026-08-17): the fixed DEBUFF_PRESET_RANK table is GONE.
-- Container-preset precedence now reads the SAME user priority list the main
-- row uses -- one precedence authority for the whole addon. Preset -> row:
--   crowdControl -> CC, boss -> Boss, role -> Role, priority -> Priority,
--   meDispellable -> DispMe, othersDispellable -> DispOthers.
-- A ticked Combine box gives BOTH members the combined row's (min) rank.
-- 2026-08-25: preset -> TYPE ID, not preset -> rank key. The key a rank read
-- means now depends on the mode (BF:DebuffRankOf), so the map names the type
-- and the resolver names the key.
local PRESET_ROW_TYPE = {
    crowdControl      = "cc",
    boss              = "boss",
    role              = "role",
    priority          = "priority",
    meDispellable     = "dispMe",
    othersDispellable = "dispOthers",
}
-- Fallback ranks for a call with no aura cache (options cold paths): the
-- canonical row sequence, which is also the shipped default order.
-- v92: PRESET_ROW_SEQ itself is declared near ShapeEntryLess -- see the note
-- there (ResolveDebuffShape needs it too, and it is defined first).
local function ComputeDebuffPresetRanks(ac)
    local r = {}
    for pkey, id in pairs(PRESET_ROW_TYPE) do
        r[pkey] = (ac and BF:DebuffRankOf(ac, id)) or PRESET_ROW_SEQ[pkey]
    end
    -- v92: the three Combine tests go through CombineFlagOn, the SAME
    -- nil-default rule PairCombineOn (and the options page's
    -- debuffRowCombineOn) use. They were bare `== true`, which is correct only
    -- for an aura cache; fed a raw SPARSE debuffs profile -- where a
    -- default-valued flag is stored as nil -- a default-ON Combine read as OFF
    -- and the pair kept two different ranks while ResolveDebuffPairOwnership,
    -- one screen away, had already resolved it as combined. Every caller today
    -- passes a cache, so this changes no live answer; it removes the trap that
    -- the next `BF._ComputeDebuffPresetRanks(profile)` caller would have fallen
    -- into, and it means "is this pair combined?" has ONE answer in this file.
    if ac then
        if CombineFlagOn(ac, "debuffCombineBossRole", true) then
            local m = (r.boss < r.role) and r.boss or r.role
            r.boss, r.role = m, m
        end
        if CombineFlagOn(ac, "debuffCombineDispel", false) then
            local m = (r.meDispellable < r.othersDispellable)
                and r.meDispellable or r.othersDispellable
            r.meDispellable, r.othersDispellable = m, m
        end
        if CombineFlagOn(ac, "debuffCombinePriorityOther", true) then
            local o = BF:DebuffRankOf(ac, "other")
            if o < r.priority then r.priority = o end
        end
    end
    return r
end
-- How to SUBTRACT a given (higher-ranked) preset out of a lower group:
--   token     = append to the group's filter string
--   candBool  = set this candidate boolean false
--   dispelArm = "me" / "others": union that arm's TYPE SET into
--               excludeDispelTypes (v91 -- the |!RAID / |!DISPELLABLE tokens
--               are retired; a candidate composes, a token OR-masks).
local DEBUFF_PRESET_SUBTRACT = {
    crowdControl      = { token = "|!CROWD_CONTROL" },
    meDispellable     = { dispelArm = "me" },
    othersDispellable = { dispelArm = "others" },
    boss              = { candBool = "isBossAura" },
    priority          = { candBool = "isPriorityAura" },
    role              = { candBool = "isRoleAura" },
}

-- Effective relative-size RATIO (default 1.0) of a preset on a container.
-- c.presetRelativeSize[pkey] is a percent (10..200); nil == 100.
--
-- IT BELONGS TO THE DEBUFFS SUB-CATEGORY, not to the container.
--
-- This value is edited on the Debuff Preset/Filter page, so it obeys THAT
-- page's per-Layout toggle -- and `ac` is already the debuffs profile
-- resolved for the Layout being rendered, so reading it from there is all
-- per-Layout takes. Stored on the container it was one size shared by every
-- Layout however the toggles were set: raid and party could not differ.
--
-- The container's own table is still read as a FALLBACK, so a profile that
-- set sizes before this moved keeps them until the slider is next touched
-- (the options page clears the container copy when it writes).
local function PresetRatio(c, pkey, ac)
    local pct = ac and ac.presetRelativeSize and ac.presetRelativeSize[pkey]
    if pct == nil then
        pct = c.presetRelativeSize and c.presetRelativeSize[pkey]
    end
    return (pct or 100) / 100
end

-- ── v92 §B4: THE FLOWED SET ───────────────────────────────────────────────
-- For every preset claimed by a DEBUFFS-anchored container (flowClaims, the
-- fifth return of ComputeDebuffContainerClaims), resolve the two numbers
-- ResolveDebuffShape needs: the RANK that places it in the row, and the SIZE
-- MULT it renders at.
--
--   base     = the Debuffs row's cell size (what every _bf_sizeMult multiplies)
--   resolved = ResolveContainerGeometry's size for this container. With "Use
--              Debuffs Icon Size/Spacing" ON that resolver already returns the
--              row's base, so ONE call covers both arms of §B4 -- no separate
--              toggle read, and no way for the two to disagree.
--   mult     = (resolved / base) * PresetRatio(c, pkey, ac)
--
-- i.e. a size override becomes the icon size IN THE ROW (the single-buff flow
-- pattern), and the per-preset Relative Size multiplies on top of it exactly
-- like the main row's own debuffSize* mults.
--
-- Returns (list, sig) or (nil, ""). The list is ordered by the canonical preset
-- order so the signature is byte-stable across passes (pairs() over flowClaims
-- is not).
-- v92 (2026-08-20): `pairOwn` supplies the virtual partner's ratio source --
-- flowClaims already reports the OWNER's ci for a virtual claim, so `c` below is
-- the owner container and its size/Max Icons are the right ones; only the
-- Relative Size has to be read under the first member's key.
local function ComputeDebuffFlowSet(ac, groupTypeKey, flowClaims, pairOwn)
    if not flowClaims then return nil, "" end
    local containers = BF:GetActiveCustomDebuffContainers()
    if not containers then return nil, "" end
    local ranks = ComputeDebuffPresetRanks(ac)
    local base  = ac._roundedDebuffSize or 12
    if base <= 0 then base = 12 end
    local list = nil
    -- SIGNATURE RULE: every field that rides a shape ENTRY must appear here,
    -- not just the ones that move `mult`. The entries are memoised with the
    -- shape (ResolveDebuffShape returns the cached table whenever this sig
    -- repeats), so a field that is read back out of them -- `size`, `maxIcons`
    -- -- serves a stale value for as long as the sig holds still.
    --
    -- `base` leads: with "Use Debuffs Icon Size" ON, resolved == base, so mult
    -- is 1.0 x ratio and is INVARIANT under a Debuffs Icon Size edit. Without
    -- the base (and the per-entry resolved size below) 20 -> 30 on the row left
    -- this sig byte-identical, the memo served the old entry, and the flowed
    -- groups kept the old size -- worse, ApplyDebuffFlowedContainers divides the
    -- stale entry size by the FRESH base, so the §B4 live-resize branch pushed a
    -- wrong mult. Reload-only until some unrelated shape input moved.
    local sig = "b" .. tostring(base) .. ";"
    local order = BF.DEBUFF_CONTAINER_PRESET_ORDER
    for i = 1, #order do
        local pkey = order[i]
        local ci = flowClaims[pkey]
        local c  = ci and containers[ci]
        if c then
            local resolved, maxIcons =
                BF:ResolveContainerGeometry(c, groupTypeKey, ac, "debuff")
            if not (resolved and resolved > 0) then resolved = base end
            local rkey = DebuffPresetRatioKey(pkey, pairOwn)
            local mult = (resolved / base) * PresetRatio(c, rkey, ac)
            list = list or {}
            list[#list + 1] = {
                ci = ci, pkey = pkey,
                rank = ranks[pkey] or PRESET_ROW_SEQ[pkey] or 8,
                mult = mult,
                -- Carried through to the shape's synthetic entry so the flow
                -- builder needs no second ResolveContainerGeometry call.
                size = resolved, maxIcons = maxIcons or 8,
            }
            sig = sig .. pkey .. ":" .. ci .. ":"
                .. tostring(ranks[pkey]) .. ":" .. tostring(mult)
                .. ":" .. tostring(resolved) .. ":" .. tostring(maxIcons) .. ";"
        end
    end
    -- No entry resolved (every flowClaim's container vanished under us): report
    -- the empty sig, so "nothing flows" is one string whatever the row size is.
    if not list then return nil, "" end
    return list, sig
end

-- Map of every preset present across ALL enabled debuff containers on this
-- frame's group type -> { ratio, ci }: its relative-size ratio and the index
-- of the container it is assigned to (a preset can only be assigned to ONE
-- container -- owner ruling 2026-08-17 -- so both are singular). ci scopes the
-- relative-size comparison in PresetWinsOver to presets SHARING a container.
-- Same enabled/per-layout gates as ComputeDebuffContainerClaims. Returns nil
-- when none. Global (across containers) so cross-container overlaps de-dup too.
-- The value doubles as the presence test (a table, so truthy).
-- v91: `ac` (the frame's aura cache) is a THIRD argument -- the preset ranks
-- come from the user's priority list now, and they are stashed on the returned
-- table as `present.ranks` (a non-pkey key; every reader iterates
-- DEBUFF_CONTAINER_PRESET_ORDER, never pairs(), so it cannot be mistaken for a
-- present preset). Passing nil keeps the canonical fallback order.
-- v92: `pairOwn` (ResolveDebuffPairOwnership) makes this the EFFECTIVE view --
-- the owner container carries the virtual partner, at the FIRST member's ratio
-- (owner decision 3), and the container that stored the partner does not carry
-- it at all. PresetWinsOver keys off `ci` and `ratio`, so effective ownership
-- reaches the de-dup competition automatically: the pair competes as one
-- container's pair of presets, which is what "acts as one unit" means for the
-- v90 same-container size rule.
local function ComputeDebuffPresetPresence(parent, groupTypeKey, ac, pairOwn)
    local containers = BF:GetActiveCustomDebuffContainers()
    if not containers or #containers == 0 then return nil end
    local present
    -- v65: hoist the GROUP RESOLUTION, never the ANSWER -- see the identical
    -- block in ComputeDebuffContainerClaims above for why. The container's own
    -- perLayoutConfig flag makes the answer per container; only the group the
    -- (loop-constant) groupTypeKey resolves to can be lifted, which is what
    -- keeps the ResolveCFGGroupByFlatID scan at one per Layout pass.
    local isCFG = type(groupTypeKey) == "string" and not groupTypeKey:find("^flat_")
    local grp   = isCFG and BF.ResolveCFGGroupByFlatID
        and BF:ResolveCFGGroupByFlatID(groupTypeKey) or nil
    local cfgOn = grp and grp[BF.AURAS_GROUP_CFG_FLAG.aurasDebuffs] or false
    for ci, c in ipairs(containers) do
        local perLayout = c.perLayoutConfig == true or cfgOn
        local shown = c.enabled ~= false
        if shown and c.groupSettings and perLayout then
            local gs = c.groupSettings[groupTypeKey]
            if gs and gs.showForGroupType == false then shown = false end
        end
        local eff = shown and EffectiveDebuffPresetSet(c, ci, pairOwn) or nil
        if shown and eff then
            -- v92 §B6: resolved once per container. It does NOT change the
            -- de-dup competition (PresetWinsOver keys off ci and ratio, both
            -- position-independent -- the v90/v91 rulings hold verbatim when a
            -- container flows); it only has to reach the SIGNATURE, so an
            -- anchor flip re-applies every preset group's candidates.
            local flowed = BF.IsDebuffContainerDebuffsAnchored
                and BF:IsDebuffContainerDebuffsAnchored(c, groupTypeKey) or false
            for pkey in pairs(eff) do
                present = present or {}
                -- First container wins on a (theoretically impossible)
                -- duplicate assignment -- the options UI enforces one
                -- container per preset.
                if not present[pkey] then
                    present[pkey] = {
                        -- v92: a combined pair's partner reads the FIRST
                        -- member's Relative Size, so the two halves of one unit
                        -- can never compete against each other on size.
                        ratio = PresetRatio(c, DebuffPresetRatioKey(pkey, pairOwn), ac),
                        ci = ci, flow = flowed or nil,
                    }
                end
            end
        end
    end
    if present then
        present.ranks = ComputeDebuffPresetRanks(ac)
        -- Folded into the presence signature so a LIST REORDER or a Combine
        -- tick re-applies every preset group's negations.
        present.rankSig = ""
        for _, p in ipairs(BF.DEBUFF_CONTAINER_PRESET_ORDER) do
            present.rankSig = present.rankSig .. tostring(present.ranks[p] or "-") .. ","
        end
        -- The By-Me/By-Others boundary moves with spec, talents and the two
        -- By-Me toggles, and both dispel presets subtract by TYPE SET now.
        local _, mySig = BF:MyDispelTypes(ac)
        present.myTypesSig = mySig
    end
    return present
end

-- v71: does `other` WIN the shared aura over `me`? `me` subtracts every
-- `other` that wins against it. present maps pkey -> { ratio, ci }.
-- v90 (owner ruling 2026-08-17): Relative Size competes ONLY between presets
-- assigned to the SAME container -- there it decides (larger wins, rank breaks
-- the tie). Across containers the fixed precedence alone decides; a size set
-- on a preset in another container must never steal an aura from a
-- higher-ranked preset elsewhere.
-- v91: the tiebreak rank source changed from the fixed table to the USER LIST
-- (present.ranks). The v90 same-container size override is untouched and still
-- runs FIRST -- size decides between two presets sharing a container, the user
-- rank breaks the tie and decides everywhere else.
local function PresetWinsOver(other, me, present)
    local o, m = present[other], present[me]
    if o and m and o.ci == m.ci and o.ratio ~= m.ratio then
        return o.ratio > m.ratio
    end
    local r = present.ranks
    local ro = (r and r[other]) or PRESET_ROW_SEQ[other] or 99
    local rm = (r and r[me]) or PRESET_ROW_SEQ[me] or 99
    return ro < rm
end

-- Short signature of the present-set + each preset's ratio and container
-- (+ warlock flag), so the expensive candidate re-apply / ordering only fires
-- when the de-dup inputs change. Built once per Layout. Ratios fold in so a
-- size change re-applies; ci folds in (v90) so MOVING a preset to another
-- container -- which reshapes the same-container size scoping -- re-applies too.
local function DebuffPresetPresenceSig(present)
    local s = ""
    for _, p in ipairs(BF.DEBUFF_CONTAINER_PRESET_ORDER) do
        local e = present and present[p]
        -- v92: the flowed flag folds in too. Anchoring a container moves its
        -- groups from dbc<ci> to `debuffs` under new group keys, so the
        -- candidate re-apply (negChanged) has to fire on the flip -- the new
        -- groups are created from scratch, but the SIBLING containers' groups
        -- also need re-stamping when one of them changes container.
        s = s .. (e and ("1:" .. tostring(e.ratio) .. "@" .. tostring(e.ci)
                         .. (e.flow and "f" or "") .. ";") or "0;")
    end
    -- v91: the user ranks / combine flags (rankSig) and the resolved dispel
    -- type set (myTypesSig) replace the old warlock flag -- both reshape the
    -- negations, so both must invalidate.
    return s .. (present and (present.rankSig or "") or "")
        .. "|" .. (present and present.myTypesSig or "")
end

-- For preset `pkey`, produce the negations of every PRESENT preset that WINS
-- over it (size-driven, tie-broken by rank). Returns (tokenSuffix, candExtra|nil).
-- Iterates the canonical order so the token string is byte-stable (the
-- SetAuraGridGroupFilter change-guard).
local function BuildDebuffPresetNegations(pkey, present, ac)
    if not present then return "", nil end
    if not DEBUFF_PRESET_SUBTRACT[pkey] then return "", nil end
    local tok, cand = "", nil
    local myTypes, otherTypes
    for _, other in ipairs(BF.DEBUFF_CONTAINER_PRESET_ORDER) do
        if other ~= pkey and present[other] and DEBUFF_PRESET_SUBTRACT[other]
           and PresetWinsOver(other, pkey, present) then
            local s = DEBUFF_PRESET_SUBTRACT[other]
            if s.token then
                tok = tok .. s.token
            elseif s.candBool then
                cand = cand or {}; cand[s.candBool] = false
            elseif s.dispelArm then
                -- v91: subtract the winning dispel preset's TYPE SET. By Me and
                -- By Others stay exactly complementary by construction, and a
                -- candidate never OR-masks against the group's own DISPELLABLE
                -- token the way |!RAID / |!DISPELLABLE did.
                if not myTypes then
                    myTypes = BF:MyDispelTypes(ac)
                    otherTypes = BF:OtherDispelTypes(myTypes)
                end
                cand = MergeDispelTypes(cand, "excludeDispelTypes",
                    (s.dispelArm == "me") and myTypes or otherTypes)
            end
        end
    end
    return tok, cand
end
-- Exposed so ApplyPresetGroups (BuffsAndContainers.lua) can compose them.
BF._ComputeDebuffPresetPresence = ComputeDebuffPresetPresence
BF._DebuffPresetPresenceSig     = DebuffPresetPresenceSig
BF._BuildDebuffPresetNegations  = BuildDebuffPresetNegations
BF._DebuffPresetRatio           = PresetRatio
-- v92 §B7: exported for the PREVIEW row assembler (_ShowDummyDebuffs,
-- Auras/DummyAuras.lua). The preview used to be a uniform grid that never
-- consulted the claim system or the priority list; it now resolves each dummy's
-- rank/size from exactly these three functions, so preview and live row cannot
-- drift apart. Read-only helpers -- none of them touch a frame or a cache (the
-- claim scan takes a `parent` it does not use, like GetDebuffTypeClaims's nil).
BF._ComputeDebuffContainerClaims = ComputeDebuffContainerClaims
BF._ResolveDebuffShape           = ResolveDebuffShape
BF._ComputeDebuffPresetRanks     = ComputeDebuffPresetRanks
BF._ComputeDebuffFlowSet         = ComputeDebuffFlowSet

-- Ensure/refresh the TYPE groups on a frame's debuffs container (v84 §9.10).
-- Every live type gets its group created (once) or reconfigured live; every
-- non-live one (toggle off, claimed, or merged away) parks dormant. Group specs
-- copy the base buttonSpec with the type's own size multiplier (ContainerFactory
-- keeps multiplied specs in lockstep on live resize via _bf_sizeMult).
--
-- Ordering inside this function is load-bearing: unparking a group clears its
-- candidateFilters to {} (that IS the dormancy mechanism), and
-- ApplyDebuffLTDExcludes re-applies them right after -- its signature folds the
-- whole resolved shape, so any live/parked flip always re-runs it.
-- v92 (Perf): the derived per-type spec used to be `CopyTable(buttonSpec)` per
-- LIVE entry per Layout — a DEEP copy (~180 per full-roster sweep), and worse,
-- the deep clone gave every nested style table (durationCurve above all) a
-- fresh table identity each pass, so ButtonSpecSig's tostring(durationCurve)
-- term never repeated and the group restyle guard in
-- ApplyAuraGridGroupButtonSpec could never hit while a debuff expiring curve
-- was set — the full button restyle walk ran every Layout. Shallow copy
-- instead: scalars copy, nested tables SHARE the ac-owned refs. That is safe
-- because the exists path consumes the table transiently
-- (ApplyAuraGridGroupButtonSpec copies fields out into the stored spec and
-- guards on a value-built signature, never on table identity), the create path
-- is handed a fresh table it then owns (EnsureAuraGridSpellGroup stores it and
-- MakeInitFn closes over it), and neither path writes into nested spec tables
-- (audited: only scalar spec.size is ever assigned).
local _dtgScratch = {}
local function DeriveTypeSpec(buttonSpec, e, exists)
    local spec
    if exists then
        spec = _dtgScratch
        for k in pairs(spec) do spec[k] = nil end
    else
        spec = {}
    end
    for k, v in pairs(buttonSpec) do spec[k] = v end
    spec._bf_sizeMult = e.mult
    spec.size = (buttonSpec.size or 12) * e.mult
    return spec
end

-- v95: no sortM/sortD parameters any more. The Sort Order is resolved PER GROUP
-- (DebuffGroupSortFor) because "blizzard" may only hand UnitFrameDebuff to
-- groups whose auras are guaranteed to carry a debuffType; every other Sort
-- Order still resolves to the same pair for every group, so this is a no-op for
-- them. Both call sites already pass `ac`, which is the only input needed.
local function ApplyDebuffTypeGroups(parent, buttonSpec, geo, shape, ac)
    local c = parent._bf_auraContainers and parent._bf_auraContainers.debuffs
    if not c then return end
    local entries = shape.order
    for i = 1, #entries do
        local e = entries[i]
        -- v92: `not e.flowed` -- the synthetic entries of a Debuffs-anchored
        -- container are placeholders for FLOW POSITION (e.li) and SIZE
        -- (maxMult) only. Their groups are built by ApplyDebuffFlowedContainers
        -- through ApplyPresetGroups, with the container's own spec/filter/
        -- candidates; they carry no `t`, no filter and no cand, so letting them
        -- through here would create a filterless group.
        if e.id ~= "other" and not e.flowed then
            local exists = c._bf_groupSpecs and c._bf_groupSpecs[e.gk]
            if e.live then
                local spec = DeriveTypeSpec(buttonSpec, e, exists)
                -- v95: this GROUP's sort. Identical for every group under every
                -- Sort Order but "blizzard" (see DebuffGroupSortFor).
                local sortM, sortD = DebuffGroupSortFor(ac, e)
                if not exists then
                    BF:EnsureAuraGridSpellGroup(parent, "debuffs", e.gk, {
                        filter        = e.filter,
                        buttonSpec    = spec,
                        -- From the start, not post-creation: a group whose
                        -- aura-type filter is a bare HARMFUL token would match
                        -- every debuff for the one pass before the candidate
                        -- setter lands. ApplyDebuffLTDExcludes re-applies this
                        -- set (with the long-term excludes folded in) below.
                        candidateFilters = e.cand,
                        layoutIndex   = e.li,
                        -- v93: this TYPE's own Max Debuffs, not the row-wide
                        -- number. e.id is the priority-list row id.
                        maxFrameCount = BF:ResolveDebuffTypeMax(ac, e.id),
                        spacing       = geo.spacing,
                        rowSpacing    = geo.rowSpacing,
                        sortMethod    = sortM,
                        sortDirection = sortD,
                    })
                    exists = c._bf_groupSpecs and c._bf_groupSpecs[e.gk]
                else
                    -- Live restyle + filter / order / size / sort follow.
                    BF:ApplyAuraGridGroupButtonSpec(parent, "debuffs", e.gk, spec)
                    BF:SetAuraGridGroupFilter(parent, "debuffs", e.gk, e.filter)
                    BF:SetAuraGridGroupLayoutIndex(parent, "debuffs", e.gk, e.li)
                    BF:SetAuraGridGroupSort(parent, "debuffs", e.gk, sortM, sortD)
                end
                -- The type groups are permanent now, so the ownMax pinned at
                -- creation would freeze Max Debuffs at whatever geometry the
                -- group was born under (_PLAN_AuraButtonCreation.md §5). Re-point
                -- it every pass; ApplyAuraGridGeometry pushes it and tops up the
                -- styling of any newly displayable pooled button.
                BF:SetAuraGridGroupOwnMax(parent, "debuffs", e.gk,
                    BF:ResolveDebuffTypeMax(ac, e.id))
            end
            if exists then
                BF:SetAuraGridGroupDormant(parent, "debuffs", e.gk, not e.live)
            end
        end
    end
end

-- v50/v54/v84: candidate filters for every LIVE group of the debuffs row:
-- long-term-debuff/blacklist spell excludes (everywhere) merged with the
-- resolved shape's per-group candidate set (own type boolean + the negations of
-- every enabled type ordered ahead of it; for `primary`, the negations of all
-- five types unconditionally).
--
-- Sig-guarded on (excludes signature + the whole resolved shape signature);
-- forced engine rebuild on change (option setters don't re-evaluate existing
-- assignments). SetAuraGroupCandidateFilters REPLACES the whole set, so
-- unparking + candidates must be re-applied together (SetAuraGridGroupDormant
-- unparks to {}).
--
-- Reads the shape STASHED on the frame rather than recomputing it: the
-- combat-edge re-apply (ReapplyCombatConditionalAuraFilters -> this, with no
-- arguments) has no claim or settings context of its own, exactly the reason
-- _bf_dbcClaimCats was stashed before it.
local function ApplyDebuffLTDExcludes(parent)
    local c = parent._bf_auraContainers and parent._bf_auraContainers.debuffs
    if not c then return end
    local shape = parent._bf_dbShape
    if not shape then return end
    local ex, sig = BF:GetLongTermDebuffExcludes(BF._inCombat)
    sig = sig .. "|" .. shape.sig
    if c._bf_ltdSig == sig then return end
    local exTable = next(ex) and ex or nil
    local ok = true
    local entries = shape.order
    for i = 1, #entries do
        local e = entries[i]
        -- Only LIVE groups: a parked group's candidate set IS the dormancy
        -- mechanism, and writing to it would silently unpark it. `primary` is
        -- parked whenever "Show Other Debuffs" is off, so it gets the same test
        -- as everything else rather than the old unconditional write.
        -- v92 LTD DECISION: flowed groups are SKIPPED here, deliberately.
        -- SetAuraGroupCandidateFilters REPLACES the whole set, so stamping the
        -- LTD/blacklist excludes onto an fpre* group would wipe its preset
        -- candidate (isBossAura/includeDispelTypes), its de-dup negations and
        -- its per-container maxDuration. More importantly it would be a
        -- BEHAVIOR CHANGE: a container's preset groups have never carried the
        -- long-term-debuff excludes on the dbc path either (ApplyPresetGroups
        -- is called with ex = nil from ApplyDebuffCustomContainers, and this
        -- function only ever walked the `debuffs` container). Flowing must not
        -- alter what a container shows -- only where it shows it -- so flowed
        -- groups keep exactly the dbc semantics.
        if e.live and not e.flowed
           and (e.id == "other"
                or (c._bf_groupSpecs and c._bf_groupSpecs[e.gk]))
           and not (c._bf_dormantGroups and c._bf_dormantGroups[e.gk]) then
            local cand = { excludeSpellIDs = exTable }
            if e.cand then
                for k, v in pairs(e.cand) do cand[k] = v end
            end
            ok = pcall(c.SetAuraGroupCandidateFilters, c, e.gk, cand) and ok
        end
    end
    if ok then
        c._bf_ltdSig = sig
        pcall(c.UpdateAllAuras, c)
    end
end
BF.ApplyDebuffLTDExcludes = ApplyDebuffLTDExcludes

-- ============================================================
-- CUSTOM DEBUFF CONTAINERS (dbc<ci>)
--
-- A separate, preset-only display of HARMFUL auras, mirroring the buff custom
-- containers (bfc<ci>) but with no assigned spells and no single-buff variant.
-- Content comes entirely from BF.DEBUFF_CONTAINER_PRESETS via the shared
-- BF.ApplyPresetGroups loop (an opts.specBuilder supplies the HARMFUL spec).
-- Geometry/border/duration go through the kind="debuff" resolvers, so a
-- container inherits the Debuffs section baseline unless the user opts out.
-- ============================================================

-- Button spec for a custom debuff container group. Signature matches the
-- ApplyPresetGroups specBuilder contract: (parent, size, c, groupTypeKey, ac).
local function DebuffCustomButtonSpec(parent, size, c, groupTypeKey, ac)
    local db = BF:GetSectionProfileForFrame("tooltips", parent)
    local autoScale = ac.debuffAutoScale
    local spec = {
        size             = size,
        dispelBorder     = true,   -- opaque dispel set draws over the static base
        dispelBorderThickness = ac.debuffDispelBorderThickness,
        -- v71: color whole border by dispel type. Baseline = section toggle; the
        -- per-container resolver below overrides.
        colorBorderByDispel = ac.debuffColorBorderByDispel ~= false,
        -- v71: dispel-type corner icon. Baseline = the section toggle/size;
        -- the per-container resolver below overrides when the container opts in.
        dispelTypeIcon      = ac.showDebuffDispelTypeIcon == true,
        dispelTypeIconScale = ac.debuffDispelTypeIconScale or 40,
        -- Duration baseline (used when the container inherits duration); the
        -- resolver below overrides these when the user opted into own settings.
        showDuration     = ac.showDebuffDuration and true or false,
        durationFont     = ac.debuffDurationFont,
        durationFontSize = autoScale and 11 or (ac.debuffFontSize or 11),
        durationBorder   = ac.debuffDurationBorder or "OUTLINE",
        durationScale    = autoScale and (size / 12 * (ac.debuffTimerScale or 1.0)) or nil,
        fontColor        = ac.debuffFontColor,
        durationCurve    = ac.expiringCurveDebuff,
        hideDurationAbove1Min = ac.hideDurAbove1MinDebuff,
        disableSwipe     = ac.disableDebuffSwipe,
        disableSpark     = ac.disableDebuffSpark,
        reverseSwipe     = ac.reverseDebuffSwipe,
        -- Border baseline; overridden by ResolveContainerBorder below.
        borderColor      = ac.debuffBorderColor,
        blizzardBorders  = ac.debuffBlizzardBorders,
        borderStyle      = ac.debuffBorderStyle,
        borderThickness  = ac.debuffBorderThickness,
        tooltipEnabled   = ac.showDebuffTooltip or false,
        tooltipInCombat  = ac.showDebuffTooltipInCombat or false,
        tooltipPos       = db and db.debuffTooltipPosition or "default",
    }
    -- Per-container border (own or inherited debuff baseline).
    if BF.ResolveContainerBorder then
        local style, color, thickness, blizz =
            BF:ResolveContainerBorder(c, groupTypeKey, ac, "debuff")
        spec.borderStyle     = style
        spec.borderColor     = color
        spec.borderThickness = thickness
        spec.blizzardBorders = blizz
    end
    -- Per-container duration: nil when inheriting (leaves the baseline above).
    if BF.ResolveContainerDuration then
        local r = BF:ResolveContainerDuration(c, groupTypeKey, ac, "debuff")
        if r then
            spec.showDuration     = r.showDur
            spec.durationFont     = r.durationFont
            spec.durationBorder   = r.durationBorder
            spec.durationFontSize = r.autoScale and 11 or (r.fontSize or 11)
            spec.durationScale    = r.autoScale and (size / 12 * (r.timerScale or 1.0)) or nil
            spec.fontColor        = r.fontColor
            spec.durationCurve    = r.expCurve
            spec.hideDurationAbove1Min = r.curveHides
            spec.disableSwipe     = r.swipeDis
            spec.disableSpark     = r.sparkDis
            spec.reverseSwipe     = r.revSwipe
        end
    end
    -- v71/v89: per-container dispel-type icon override. Gated by the container's
    -- "Use Debuffs Border" flag (containerUsesDebuffBorder): with it OFF the
    -- container uses its own dispelTypeIcon / dispelTypeIconScale (per-Layout
    -- source first, then container top level); nil == inherit the section
    -- baseline already on spec.
    if BF.ResolveContainerDispelTypeIcon then
        local on, scale = BF:ResolveContainerDispelTypeIcon(c, groupTypeKey, ac)
        if on ~= nil then
            spec.dispelTypeIcon      = on
            spec.dispelTypeIconScale = scale
        end
    end
    -- v71: per-container "Color border by dispel type" override.
    if BF.ResolveContainerColorBorderByDispel then
        local on = BF:ResolveContainerColorBorderByDispel(c, groupTypeKey, ac)
        if on ~= nil then spec.colorBorderByDispel = on end
    end
    -- v92: per-container ICON EFFECT (Glow / Marching Ants / Flash, plus the
    -- Pandemic tint). Stamped through the SAME BF.ApplyIconEffectToSpec the
    -- per-spell path uses, so a stored entry can never mean two things.
    --
    -- Nothing else is needed to make it live: ButtonSpecSig folds every field
    -- ApplyIconEffectToSpec writes, so a live edit moves the group's style
    -- signature and the existing restyle walk (which already calls ApplyGlow /
    -- ApplyIconEffects) repaints. And because this builder is the specBuilder
    -- for BOTH container paths, the effect reaches a container's dbc<ci> groups
    -- and its flowed fpre<ci>_* groups from this one call site.
    if BF.ResolveContainerIconEffect and BF.ApplyIconEffectToSpec then
        local ie = BF:ResolveContainerIconEffect(c, groupTypeKey)
        if ie then BF.ApplyIconEffectToSpec(spec, ie) end
    end
    -- Stack text (Aura Text > Stack Text) -- see BF:ApplyStackTextSpec.
    return BF:ApplyStackTextSpec(spec, ac, size)
end

-- Geometry table (ApplyAuraGridGeometry shape) for a debuff container.
local function ContainerGeoDebuff(c, ac, groupTypeKey)
    local size, maxIcons, spacing, rowSpacing, perRow, anchor, offX, offY, growDir
        = BF:ResolveContainerGeometry(c, groupTypeKey, ac, "debuff")
    return {
        size          = size,
        anchor        = anchor,
        offsetX       = offX,
        offsetY       = offY,
        growDirection = BF.NormalizeGrowDirection(growDir, anchor),
        perRow        = perRow,
        spacing       = spacing,
        rowSpacing    = rowSpacing,
        maxIcons      = maxIcons,
        canLift       = true,
    }
end

-- Create any missing dbc<ci> engine containers. Preset-only: the container is
-- v79: born with NO groups at all (all real content
-- comes from the pre<pkey> groups ApplyPresetGroups adds), mirroring how the
-- main debuffs container parks its "secondary" group.
-- v84 §9.6: a custom debuff container FOLLOWS the main row's Sort Order until
-- it overrides it (c.sortOrder, same follow-until-overridden shape as the other
-- per-container overrides). nil/"" == follow.
-- v95 (owner ruling 2026-08-25): "blizzard" DEGRADES to Default here, on both
-- the dbc<ci> path and the flowed fpre<ci>_<pkey> path (both resolve their sort
-- through this function, so a container that FOLLOWS the row picks the row's
-- "blizzard" up here). Two reasons it cannot be honored:
--   * a dbc lives in its OWN engine container, which is not on the ProcessAura
--     policy at all -- debuffType is nil on every one of its auras, and
--     UnitFrameDebuff's comparator errors on `nil < number` inside Blizzard's
--     secure code;
--   * a flowed group rides the `debuffs` container (which IS on the policy) but
--     holds preset content -- dispellable and crowd-control presets among it --
--     which ProcessAura does not classify under our policy options.
-- AuraContainerSortMethod.Default is DefaultAuraCompare: the SAME yours-first /
-- priority / canApply / instance-ID rule UnitFrameDebuff applies within a tier,
-- minus the tier. Same treatment the CC and dispel groups of the main row get.
local function ContainerSort(c, ac)
    local key = c and c.sortOrder
    if key == nil or key == "" then key = ac.debuffSortOrder end
    if key == "blizzard" then
        return AuraContainerSortMethod.Default, AuraContainerSortDirection.Normal
    end
    return ResolveDebuffSort(key)
end
BF.DebuffContainerSort = ContainerSort

-- v89: a custom debuff container FOLLOWS the main row's Maximum Duration until
-- it overrides it (c.maxDuration, same follow-until-overridden shape as Sort
-- Order above). nil/"" == follow the Debuffs setting (ac.debuffMaxDuration);
-- an explicit key ("none" / "sec30" / ... / "hour1") overrides it. Returns the
-- inclusive upper bound in SECONDS, or nil for no filtering ("none", or a
-- followed Debuffs setting that is itself "none").
local function ContainerMaxDuration(c, ac)
    local key = c and c.maxDuration
    if key == nil or key == "" then key = ac and ac.debuffMaxDuration end
    return DEBUFF_MAX_DURATION_SECONDS[key or "none"]
end
BF.DebuffContainerMaxDuration = ContainerMaxDuration

local function EnsureDebuffContainers(parent, ac, groupTypeKey)
    local containers = BF:GetActiveCustomDebuffContainers()
    if not containers or #containers == 0 then return end
    for ci, c in ipairs(containers) do
        local key = "dbc" .. ci
        -- v69: never build an engine container for a globally disabled entry
        -- (the seeded Crowd Control container ships disabled for users who had
        -- CC off — they should pay zero tracking cost). Re-enabling reaches
        -- this Ensure again via the options refresh.
        if c.enabled == false then
            -- fall through: parking of a previously-live container is handled
            -- in ApplyDebuffCustomContainers' loop below.
        elseif BF:IsDebuffContainerDebuffsAnchored(c, groupTypeKey) then
            -- v92 §B2: DEBUFFS-anchored -- this container has no engine
            -- container of its own; its claimed presets render as fpre<ci>_*
            -- groups inside the `debuffs` row (ApplyDebuffFlowedContainers).
            -- Creation skip only; a container that ALREADY has a dbc<ci> from
            -- before the switch is parked + hidden in ApplyDebuffCustomContainers
            -- (engine containers can never be destroyed, so leaving it alone
            -- would duplicate every icon). Same two-step the bfc flow anchor
            -- uses (BuffsAndContainers.lua).
        elseif not BF:IsContainerCreationRelevant("debuff", ci) then
            -- v74: no preset/whitelist content -> nothing this container could
            -- ever display -> never build its engine container (see CONTAINER
            -- CREATION RELEVANCE in AuraCustomizations.lua). Creation-only:
            -- a previously-built container is unaffected (it renders nothing,
            -- same as today), and giving the container content funnels
            -- through InvalidateClaimedSpellCache, which re-opens creation.
        elseif not (parent._bf_auraContainers and parent._bf_auraContainers[key]) then
            local cgeo = ContainerGeoDebuff(c, ac, groupTypeKey)
            local spec = DebuffCustomButtonSpec(parent, cgeo.size, c, groupTypeKey, ac)
            -- v79: NO `main` group. Debuff containers are preset-only (no
            -- spell-id filtering exists on this side -- see
            -- Options_AuraCustomizations.lua:243), so every icon comes from the
            -- pre<pkey> groups ApplyPresetGroups adds, each carrying its own
            -- filter string and its own place in the de-dup precedence.
            --
            -- `main` was never a feature: EnsureAuraGridContainer synthesises a
            -- default group when the caller passes no `groups` list, so this
            -- site used to hand it a throwaway "HARMFUL|DISPELLABLE" purely to
            -- get the container built, then park it on the next line. Nothing
            -- ever unparked it. Measured cost on a 2-container profile: 2 groups
            -- x 10 pooled buttons x 50 frames = 1,000 fully-styled aura buttons
            -- that could never render anything.
            --
            -- `groups = {}` is the empty-list form: the creation loop simply
            -- does not run, and _bf_groupKeys is still initialized, so every
            -- sweep and geometry walk that iterates it no-ops correctly. A
            -- group-less AuraContainer is legal -- the shared slot container
            -- (ContainerFactory.lua, EnsureAuraSlotVisual) has always been one.
            local cSortM, cSortD = ContainerSort(c, ac)
            BF:EnsureAuraGridContainer(parent, key, {
                buttonSpec    = spec,
                maxFrameCount = cgeo.maxIcons,
                -- v84 §9.6: the container's own Sort Order (or the main row's,
                -- when it follows). Replaces the inert UnitFrameDebuff default.
                sortMethod    = cSortM,
                sortDirection = cSortD,
                spacing       = cgeo.spacing,
                rowSpacing    = cgeo.rowSpacing,
                groups        = {},
            })
            BF:ApplyAuraGridGeometry(parent, key, cgeo)
        end
    end
end

-- Full per-frame pass for custom debuff containers: ensure, re-apply geometry +
-- button spec, drive the preset groups, and sweep orphaned containers. Called
-- from Create (first build) and Layout (live edits). No-ops with zero cost when
-- the debuff-container array is empty.
-- v92: `pairOwn` is the pass's combined-pair ownership (resolved by the caller
-- in :Create / :Layout, so the claims pass and this one can never disagree).
-- Omitted by an external caller -> resolved here, one extra gated walk. (A
-- caller that resolved it to nil -- no pair combined anywhere -- pays that walk
-- again for the same nil; the flags-all-off shape is the rare one, and the
-- alternative is a sentinel value threaded through an exported signature.)
local function ApplyDebuffCustomContainers(parent, pairOwn)
    local containers = BF:GetActiveCustomDebuffContainers()
    local pools = parent._bf_auraContainers
    local n = containers and #containers or 0
    -- Per-container "Enabled for this Layout" (showForGroupType) resolved here at
    -- settings time into a per-frame cache; DebuffIcons:Update does one lookup.
    -- Mirrors the buff path's _bf_bfcVisible. Debuff containers have no per-
    -- frame-type (party/raid/custom) toggles -- only the per-Layout gate.
    local vis = parent._bf_dbcVisible
    if not vis then vis = {}; parent._bf_dbcVisible = vis end
    -- v92 §B2: a SECOND per-frame flag, deliberately not folded into vis[] --
    -- the _bf_bfcAnchored rationale (BuffsAndContainers.lua) applies verbatim.
    -- vis[ci] stays "the user wants this container visible"; anchored[ci] means
    -- "it has no dbc<ci> of its own, it renders inside the debuffs row". Update
    -- must skip the SyncAuraGridContainer for an anchored container or it would
    -- re-show, once per Layout/Update cycle, the container this pass just hid.
    local dbcAnchored = parent._bf_dbcAnchored
    if not dbcAnchored then dbcAnchored = {}; parent._bf_dbcAnchored = dbcAnchored end
    if n > 0 then
        local ac = BF:GetAuraCacheForFrame(parent)
        local groupTypeKey = BF.ResolveGroupTypeKey and BF:ResolveGroupTypeKey(parent)
        if pairOwn == nil then
            pairOwn = ResolveDebuffPairOwnership(ac, groupTypeKey)
        end
        EnsureDebuffContainers(parent, ac, groupTypeKey)
        -- v74: `pools` was captured BEFORE the Ensure above -- on a frame's
        -- first build it is nil, and the existence gate below would then skip
        -- the just-created containers' preset/spec application until the next
        -- Layout. Re-fetch (same table identity when it already existed).
        pools = pools or parent._bf_auraContainers
        -- v71: global present-preset set + its signature, computed ONCE (they are
        -- identical for every container). ApplyPresetGroups negates each preset
        -- against the higher-ranked presets in this set (within + across
        -- containers); negSig gates the expensive candidate re-apply.
        -- v91: `ac` supplies the user ranks + combine flags + the two By-Me
        -- toggles that resolve the dispel type sets.
        local dedupPresent = ComputeDebuffPresetPresence(parent, groupTypeKey, ac, pairOwn)
        local dedupSig     = DebuffPresetPresenceSig(dedupPresent)
        -- v65: hoist the GROUP RESOLUTION, never the ANSWER -- same shape as
        -- ComputeDebuffContainerClaims / ComputeDebuffPresetPresence above (the
        -- values there are locals of those functions, so they cannot be reused
        -- here). groupTypeKey is fixed for the whole loop, so the linear
        -- ResolveCFGGroupByFlatID scan runs once per Layout pass; the container's
        -- own perLayoutConfig flag is read per container. Do not lift
        -- `perLayout` itself out of the loop -- that would ignore it.
        local dbcIsCFG = type(groupTypeKey) == "string" and not groupTypeKey:find("^flat_")
        local dbcGrp   = dbcIsCFG and BF.ResolveCFGGroupByFlatID
            and BF:ResolveCFGGroupByFlatID(groupTypeKey) or nil
        local dbcCfgOn = dbcGrp and dbcGrp[BF.AURAS_GROUP_CFG_FLAG.aurasDebuffs] or false
        for ci, c in ipairs(containers) do
            local key = "dbc" .. ci
            -- v69: global Enabled gate. Disabled = as if removed: park every
            -- group of a previously-live engine container (mirrors the orphan
            -- sweep below) so the engine stops tracking, hide via vis[], and
            -- skip all geometry/spec/preset work. A never-enabled container
            -- has no engine container at all (EnsureDebuffContainers skips).
            if c.enabled == false then
                vis[ci] = false
                dbcAnchored[ci] = nil
                local oc = pools and pools[key]
                if oc then
                    for _, gk in ipairs(oc._bf_groupKeys) do
                        BF:SetAuraGridGroupDormant(parent, key, gk, true)
                    end
                    BF:SyncAuraGridContainer(parent, key, nil, false)
                end
            else
            -- Resolve visibility. Only the per-Layout tier applies (gated on
            -- this container's own perLayoutConfig flag, or the group's Debuffs
            -- override flag on a CFG scope -- see the hoist above).
            local shown = true
            if c.groupSettings and (c.perLayoutConfig == true or dbcCfgOn) then
                local gs = c.groupSettings[groupTypeKey]
                if gs and gs.showForGroupType == false then shown = false end
            end
            vis[ci] = shown
            -- ── v92 §B2: DEBUFFS-ANCHORED CONTAINERS ───────────────────────
            -- Park + hide any dbc<ci> this container still owns and skip ALL of
            -- its per-container maintenance below. Two reasons, both load-
            -- bearing:
            --
            --   1. Duplication. Engine AuraContainers can never be destroyed,
            --      so the container an already-built entry had before the user
            --      switched it to "Debuffs" would keep its filters, unit
            --      binding and shown state and go on rendering next to the
            --      fpre<ci>_* groups now drawing the same auras. Its index is
            --      <= n, so the orphan sweep below never visits it.
            --   2. THE CRASH GUARD. ApplyAuraGridGeometry ends at SetPoint, and
            --      ResolveContainerGeometry returns anchorPoint RAW by contract
            --      (AuraCustomizations.lua) -- so an anchored container's geo
            --      would hand SetPoint the literal "DEBUFFS". Skipping the
            --      whole arm is what keeps the sentinel away from it; do not
            --      "restore" the geometry call for an anchored container.
            --
            -- Both engine calls are change-guarded, so a container that never
            -- had a dbc pays two table lookups.
            if BF:IsDebuffContainerDebuffsAnchored(c, groupTypeKey) then
                dbcAnchored[ci] = true
                local oc = pools and pools[key]
                if oc then
                    for _, gk in ipairs(oc._bf_groupKeys) do
                        BF:SetAuraGridGroupDormant(parent, key, gk, true)
                    end
                    BF:SyncAuraGridContainer(parent, key, nil, false)
                end
            else
            dbcAnchored[ci] = nil
            -- v74: existence gate. A container skipped at creation (relevance
            -- gate in EnsureDebuffContainers, or a combat-deferred build) has
            -- nothing to maintain; without this the else-arm still paid
            -- ContainerGeoDebuff + DebuffCustomButtonSpec (four Resolve*
            -- calls) + a dead ApplyPresetGroups per skipped container per
            -- frame per Layout. EnsureDebuffContainers ran above, so anything
            -- creatable THIS pass already exists by this line.
            local cc = pools and pools[key]
            if cc then
                local cgeo = ContainerGeoDebuff(c, ac, groupTypeKey)
                BF:ApplyAuraGridGeometry(parent, key, cgeo)
                local spec = DebuffCustomButtonSpec(parent, cgeo.size, c, groupTypeKey, ac)
                -- v99: the `cc._bf_styleGen = nil` cache-gen fast-path defeat is
                -- GONE. This site needed it the most: container settings live in
                -- acDB (which never bumps ac._cacheGen) and this builder stamps
                -- fifteen fields the old partial pre-guard never compared -- the
                -- per-container dispel-type icon, colorBorderByDispel, the dispel
                -- border thickness/scale, both tooltip toggles and the entire v92
                -- Icon Effect set. ApplyAuraGridButtonSpec now compares the full
                -- spec census, so every one of them is guarded by construction.
                BF:ApplyAuraGridButtonSpec(parent, key, spec)
                if BF.ApplyPresetGroups then
                    local ttY = BF.TooltipBelowFrameY(parent, cgeo.anchor, cgeo.offsetY, cgeo.size)
                    local cSortM, cSortD = ContainerSort(c, ac)
                    BF.ApplyPresetGroups(parent, key, c, groupTypeKey, ac,
                        cgeo.size, cgeo.spacing, cgeo.rowSpacing, ttY, nil, nil,
                        { specBuilder = DebuffCustomButtonSpec,
                          -- v93: each debuff type owns its Max Debuffs (the
                          -- container-level Max Icons control was removed).
                          presetMaxPerCategory = true,
                          -- v84 §9.6: per-container Sort Order (or the main
                          -- row's). Applied live on the preset groups too.
                          sortMethod = cSortM, sortDirection = cSortD,
                          -- v92: the EFFECTIVE preset set + the combined pair's
                          -- ratio alias. The owner container builds the virtual
                          -- partner's group here; the container that merely
                          -- STORED it emits nothing for it, and the pre* sweep
                          -- at the end of ApplyPresetGroups parks the group it
                          -- built on an earlier (uncombined) pass.
                          presetSet = EffectiveDebuffPresetSet(c, ci, pairOwn),
                          ratioAlias = pairOwn,
                          dedupPresent = dedupPresent, dedupSig = dedupSig })
                end
            end
            end
            end
        end
    end
    -- ── ORPHANED ENGINE CONTAINERS ──────────────────────────────────────────
    -- Deleting a debuff container shrinks the array, but AuraContainers can
    -- never be destroyed and both this pass and Update only visit 1..n. Park
    -- every group on any dbc beyond the current count and hide it. Mirrors the
    -- bfc orphan sweep in ApplyBuffFilters.
    if pools then
        for key, oc in pairs(pools) do
            local idx = key:match("^dbc(%d+)$")
            if idx and tonumber(idx) > n then
                for _, gk in ipairs(oc._bf_groupKeys) do
                    BF:SetAuraGridGroupDormant(parent, key, gk, true)
                end
                BF:SyncAuraGridContainer(parent, key, nil, false)
            end
        end
    end
end
BF.ApplyDebuffCustomContainers = ApplyDebuffCustomContainers

-- ============================================================
-- v92 §B3.4: FLOWED DEBUFF CONTAINERS (fpre<ci>_<pkey> in `debuffs`)
--
-- A DEBUFFS-anchored container's claimed presets render as ordinary preset
-- groups of the MAIN DEBUFFS CONTAINER, at the layoutIndex the shape resolver
-- assigned their synthetic entries (= their Debuff Category Priority position)
-- and at the flowed mult of §B4. Everything else about them is unchanged: the
-- same BF.ApplyPresetGroups loop builds them, with the same specBuilder, the
-- same per-container Sort Order / Maximum Duration plumbing and the same
-- cross-container de-dup negations. Only the target container and the group-key
-- namespace differ.
--
-- FOUR THINGS THAT WILL BITE ANYONE EDITING THIS:
--
-- 1. The prefix is "fpre" and it must stay disjoint from "pre" / "sb" / "sp".
--    `pre` is the prefix ApplyPresetGroups' own stale sweep matches, and
--    "fpre..":sub(1,3) is "fpr", so the buffs row's and every dbc's sweep stay
--    blind to these groups -- and vice versa.
-- 2. The namespace carries the SOURCE INDEX (fpre<ci>_): two anchored
--    containers share one target container, so a shared namespace would let
--    each one's sweep park the other's groups every pass.
-- 3. ApplyPresetGroups' per-container caches (_bf_presetNegSig, _bf_lastMaxDur)
--    live on the TARGET engine container. With N sources on one target they
--    must be keyed per source -- that is opts.cacheKey (§B3.5). The exclude
--    stamp needs no keying: it is already a table keyed by group key, and the
--    group keys are namespaced.
-- 4. These groups are NOT part of the type-group walk and NOT part of
--    ApplyDebuffLTDExcludes -- see the `e.flowed` guards in both. They keep the
--    dbc candidate semantics exactly.
local _dbFlowSeen = {}
local _dbFlowLI   = {}

local function ApplyDebuffFlowedContainers(parent, ac, groupTypeKey, shape, geo, pairOwn)
    local dc = parent._bf_auraContainers and parent._bf_auraContainers.debuffs
    if not dc or not dc._bf_groupKeys then return end
    local flow  = shape and shape.flow
    local nFlow = flow and #flow or 0
    -- Nothing to build and nothing ever built here: two field reads and out.
    -- _bf_dbFlowHosted has the same lifetime as the groups themselves (both
    -- live on the engine container, which is never destroyed), so the sweep
    -- below can never miss one.
    if nFlow == 0 and not dc._bf_dbFlowHosted then return end
    for k in pairs(_dbFlowSeen) do _dbFlowSeen[k] = nil end
    local containers = BF:GetActiveCustomDebuffContainers()
    local nC = containers and #containers or 0
    -- Sweep validity, the `passValid` idiom: never park on a pass that could
    -- not resolve the Layout. groupTypeKey is nil for a CFG frame whose flat ID
    -- has not been minted yet, and parking on it would blank the flowed icons
    -- until something else forced another Layout.
    local passValid = (groupTypeKey ~= nil)
    if nFlow > 0 and nC > 0 and BF.ApplyPresetGroups then
        -- The global present-preset set. Recomputed here rather than shared
        -- with ApplyDebuffCustomContainers (which runs later in the same
        -- Layout): the inputs are identical and both callers derive the same
        -- negations from them, and threading it would have meant either
        -- reordering the two passes or stashing a pass-scoped value on the
        -- frame. Paid only by frames that actually have a flowed container.
        local dedupPresent = ComputeDebuffPresetPresence(parent, groupTypeKey, ac, pairOwn)
        local dedupSig     = DebuffPresetPresenceSig(dedupPresent)
        local base = ac._roundedDebuffSize or 12
        if base <= 0 then base = 12 end
        dc._bf_dbFlowHosted = true
        for ci = 1, nC do
            local c = containers[ci]
            -- v93: no cMax any more -- a flowed container's cap is per debuff
            -- type (fe.maxIcons is the container-level value the removed Max
            -- Icons slider fed, and nothing reads it here now).
            local cSize, any = nil, false
            for k in pairs(_dbFlowLI) do _dbFlowLI[k] = nil end
            for i = 1, nFlow do
                local fe = flow[i]
                if fe.ci == ci then
                    any = true
                    -- Container-wide, so every preset of one container agrees.
                    cSize = fe.size
                    _dbFlowLI[fe.pkey] = fe.li
                    _dbFlowSeen[fe.gk] = true
                end
            end
            if any and c then
                local prefix = "fpre" .. ci .. "_"
                -- The ROW's anchor/offset, not the container's: these icons sit
                -- in the debuffs row, so that is the frame edge a tooltip has
                -- to clear. (The container's own Position widgets are hidden
                -- while it is anchored -- §B5.)
                local ttY = BF.TooltipBelowFrameY(parent, geo.anchor, geo.offsetY, cSize)
                local cSortM, cSortD = ContainerSort(c, ac)
                BF.ApplyPresetGroups(parent, "debuffs", c, groupTypeKey, ac,
                    cSize, geo.spacing, geo.rowSpacing, ttY, nil, nil,
                    {
                        -- The key is "debuffs", so the kind dispatch cannot
                        -- infer the HARMFUL preset vocabulary from it.
                        presetKind     = "debuff",
                        specBuilder    = DebuffCustomButtonSpec,
                        groupKeyPrefix = prefix,
                        cacheKey       = prefix,
                        -- §B4: the row's cell size is the divisor of the mult,
                        -- the container's own size is the numerator.
                        sizeBase       = base,
                        -- Priority position, not the 1500+ size-driven formula.
                        layoutIndex    = _dbFlowLI,
                        -- v93: per debuff TYPE, not per container -- the
                        -- container-level Max Icons control was removed from
                        -- debuff containers, so there is no cMax to pass here
                        -- any more (it still carries the SIZE above, which is
                        -- container-wide and unchanged).
                        presetMaxPerCategory = true,
                        sortMethod     = cSortM, sortDirection = cSortD,
                        -- v92: SAME effective-set resolution as the dbc path --
                        -- the two must agree or a virtual partner would render
                        -- on one and not the other. `flow` already only carries
                        -- presets whose OWNER is anchored, so the set and the
                        -- layoutIndex map cannot disagree either.
                        presetSet      = EffectiveDebuffPresetSet(c, ci, pairOwn),
                        ratioAlias     = pairOwn,
                        dedupPresent   = dedupPresent, dedupSig = dedupSig,
                    })
                -- maxFrameCount is pinned into _bf_groupOwnMax at creation, so
                -- a group first built under one Max Debuffs value would keep it
                -- forever (_PLAN_AuraButtonCreation.md §5, the same defect
                -- SetAuraGridGroupOwnMax was added for). Re-point it every
                -- pass; the next ApplyAuraGridGeometry pushes it and tops up
                -- the styling of any newly displayable pooled button. Exactly
                -- what ApplyDebuffTypeGroups does for the type groups.
                --
                -- v93: PER PRESET now. ApplyPresetGroups re-points the presets
                -- it emitted this pass; this loop is the wider net -- it walks
                -- every flow entry of this container, including one whose group
                -- ApplyPresetGroups skipped (an absorbed pair partner), and it
                -- is keyed off fe.pkey so each type tracks its own slider.
                for i = 1, nFlow do
                    local fe = flow[i]
                    if fe.ci == ci then
                        BF:SetAuraGridGroupOwnMax(parent, "debuffs", fe.gk,
                            BF:ResolveDebuffPresetMax(ac, fe.pkey))
                    end
                end
            end
        end
    end
    -- ── STALE SWEEP ────────────────────────────────────────────────────────
    -- Park every fpre* group this pass did not emit. ApplyPresetGroups' own
    -- prefix sweep covers a container that dropped ONE preset; this one covers
    -- the cases it cannot see -- a container unanchored, disabled, hidden for
    -- this Layout, or deleted outright.
    if passValid and dc._bf_dbFlowHosted then
        local gks = dc._bf_groupKeys
        for i = 1, #gks do
            local gk = gks[i]
            if gk:sub(1, 4) == "fpre" and not _dbFlowSeen[gk] then
                BF:SetAuraGridGroupDormant(parent, "debuffs", gk, true)
            end
        end
    end
end

-- v77: is the main Debuffs display switched on for this frame? Mirrors the
-- exact expression :Update uses to decide whether to SHOW the container, so
-- creation and visibility can never disagree.
-- v92: hoisted above ApplyDebuffContainerFx, which needs the SAME answer (a
-- Debuffs-anchored container renders nothing while the row is off, so its frame
-- effect must not fire either). Duplicating the expression there is exactly
-- what this function exists to prevent.
local function DebuffsShownFor(parent)
    local ac = BF:GetAuraCacheForFrame(parent)
    local ph = parent._bf_parentHeader or parent:GetParent()
    local moduleOff = ph and ph.isCustomFrame and ph.moduleShowDebuffs == false
    return (ac.showDebuffs ~= false) and not moduleOff
end
BF.DebuffsShownForFrame = DebuffsShownFor

-- ============================================================
-- v92: PER-CONTAINER FRAME EFFECTS (dfx<ci>_<pkey> slot visuals)
--
-- "Tint the health bar / draw a frame border / draw an overlay while THIS
-- container has something to show." Lua cannot answer that on 12.1 -- debuff
-- presence is secret in combat -- so the answer comes from the ENGINE: one aura
-- SLOT per active preset, filtered with EXACTLY the filter+candidates that
-- preset's icon GROUP uses (BF.ComposeDebuffPresetFilter, shared with
-- ApplyPresetGroups so the two can never drift). The engine shows the slot's
-- button while a matching aura exists; the effect art lives on per-kind level
-- HOSTS parented to that button, so it appears and disappears with the aura.
-- Same mechanism as the per-spell frame effects (ApplySpellFx) and the dispel
-- visuals (SyncDispelVisualSlots).
--
-- ONE SLOT PER PRESET, not per container: the presets have different filters,
-- which is the whole thing the engine keys on. A container with two presets
-- therefore gets two slots.
--
-- ── DOUBLE-DRAW: ACCEPTED, AND WHY IT CANNOT BE FIXED ─────────────────────
-- Two slots of one container can be shown AT THE SAME TIME (a boss debuff and
-- a CC debuff both present). Each has its own host, both hosts sit at the same
-- absolute level with identical geometry and identical stamps, so the effect is
-- drawn TWICE. Composited, drawing color C at alpha a twice over background B
-- gives (2a − a²)C + (1−a)²B: IDEMPOTENT at a = 1, and progressively stronger
-- below it. The default frame-effect alpha is 0.5, so it is visible.
--
-- Every alternative is worse or impossible:
--   * One slot per container. Its filter would have to be the UNION of the
--     presets. Candidate filters AND, and opposing filter TOKENS OR-mask (the
--     PTR-confirmed HELPFUL|HARMFUL trap) -- a union is exactly what this
--     engine cannot express. That is why the icon GROUPS are per preset too.
--   * Art on only one preset's slot. Then the effect would vanish whenever the
--     OTHER preset is the one matching -- a correctness bug, not a cosmetic one.
--   * Alpha compensation (draw at a/N). N is how many of this container's
--     presets currently match, and aura presence is SECRET to Lua on 12.1 --
--     the one number needed is the one number unavailable.
--
-- So: accepted, and surfaced in the option's own description rather than left
-- for the user to discover. It costs nothing in the common shape (one category
-- per container, which is what the Add Preset list steers toward), and at
-- alpha 1 it is invisible even with several.
--
-- ASSIST GATE / IDENTITY CARVE-OUT: these slots carry NO includeSpellIDs or
-- excludeSpellIDs (the composition is called with ex = nil -- the same LTD
-- decision the container's icon groups take). That matters because the carve-out
-- silently drops spell-ID candidates for HARMFUL auras on assistable units,
-- which is every unit these frames show. Everything the composition does use --
-- filter tokens, the category booleans, include/excludeDispelTypes -- is exempt.
--
-- INDEPENDENT OF THE ANCHOR. A frame effect is frame-level: it tints the health
-- bar or rings the frame, and it does not care whether the container's icons
-- render in their own dbc<ci> or flowed inside the debuffs row. A
-- DEBUFFS-anchored container keeps its effects. What DOES gate it is the
-- container being enabled and visible on this Layout -- the same two gates the
-- claims pass applies.
--
-- LEVELS are BF.CONTAINER_FX_LEVEL, fixed, one rung below each dispel kind.
-- Never re-levelled at runtime: only the BUFF-side Prioritise toggles move a
-- host, and this feature has no such toggle.
local _dbfxEntry = {}   -- scratch restamp entry; consumed synchronously

-- Map our resolver's output onto the RestampFx* entry shapes. Color tables are
-- COPIED (the resolver hands back interned defaults / live DB tables by
-- reference, and an entry that outlived this call must not alias them).
local function DbfxEntryFor(fx)
    local e = _dbfxEntry
    for k in pairs(e) do e[k] = nil end
    local col = fx.color
    local r, g, b, a = col.r or 1, col.g or 0, col.b or 0, col.a or 0.5
    if fx.kind == "healthColor" then
        -- RestampFxHealth reads r/g/b/a straight off the entry.
        e.r, e.g, e.b, e.a = r, g, b, a
        return "hc", e
    elseif fx.kind == "border" then
        e.color = { r = r, g = g, b = b, a = a }
        e.thickness = fx.borderWidth
        return "bd", e
    elseif fx.kind == "overlay" then
        e.color = { r = r, g = g, b = b, a = a }
        -- FxOverlayAlpha prefers color.a, so the picker's alpha is the opacity.
        e.style, e.gradientDir = "gradient", "topToBottom"
        e.height, e.fillOnly = fx.overlayHeight, fx.overlayFillOnly
        return "ov", e
    end
    return nil, nil
end

local _dbfxSeen = {}

-- Stamp ONE dfx slot's visible state: restamp the configured kind, HIDE the
-- other two (hide-don't-park: the kinds share one button, so parking would take
-- the live one with them). ONE function for both callers -- the creation-time
-- initButton below and the post-creation live-edit pass in
-- ApplyDebuffContainerFx -- so the two can never disagree about what a slot
-- should look like.
--
-- Both callers going through the same sig-guarded restamps is what makes the
-- creation stamp COUNT: RestampFx* commit host._bf_fxSig and HideFxKind latches
-- host._bf_fxHidden only on success, so a slot stamped inside the init window
-- arrives at the post-creation pass already committed, and that pass is a
-- sig-match no-op until the user actually edits the effect.
--
-- Overlay sizing: RestampFxOverlay measures the health bar and bails (no sig)
-- while it reads 0 -- which it can at :Create, before the frame's first
-- Layout has sized it. The header's initial size (BuzzardFrame_GetInitialSize
-- reads header.frameWidth / frameHeight) is the stand-in for that window.
-- Only the size-hinted entry point can take it; without it the plain restamp
-- runs and a 0-size bar still defers to the next Layout, as before.
-- `atCreation` true = pass the header size as a fallback for the unsized bar.
-- The live-edit pass must NOT pass it: outside the init window a 0-size bar
-- means "not laid out yet", and the next Layout re-measures -- committing the
-- frame-sized fallback there would stamp a wrong size the Layout then has to
-- undo (review 2026-09-11).
local function StampDbfxKinds(parent, hosts, kind, entry, atCreation)
    if kind == "hc" then
        BF.RestampFxHealth(parent, hosts.hc, entry)
    else
        BF.HideFxKind(hosts.hc, "hc")
    end
    if kind == "bd" then
        BF.RestampFxBorder(parent, hosts.bd, entry)
    else
        BF.HideFxKind(hosts.bd, "bd")
    end
    if kind == "ov" then
        if atCreation and BF.RestampFxOverlaySized then
            local header = parent._bf_parentHeader or parent:GetParent()
            BF.RestampFxOverlaySized(parent, hosts.ov, entry,
                header and header.frameWidth, header and header.frameHeight)
        else
            BF.RestampFxOverlay(parent, hosts.ov, entry)
        end
    else
        BF.HideFxKind(hosts.ov, "ov")
    end
end

-- Would a live StampDbfxKinds(parent, hosts, kind, entry) WRITE anything?
-- Pure read: the configured kind's restamp is run in PEEK mode (it returns the
-- signature it would commit to host._bf_fxSig and writes nothing), and the
-- other two kinds are checked against the HideFxKind latch
-- (host._bf_fxHidden). A nil peek sig -- a precondition the restamp would
-- bail on (no regions, bar not measurable) -- is "no write".
--
-- WHY (plan §3.1, dfx row; field report 2026-09-10): inside a keystone every
-- post-creation write on a slot button is denied, so the live pass must not
-- attempt the stamp there -- it compares, and on a mismatch asks for the slot
-- to be recreated, whose initButton (MakeDbfxInit) stamps inside the init
-- window. The sig comes from the SAME RestampFx* functions that commit it
-- (BuffsAndContainers.lua), so the two can never drift; a derivation gap would
-- otherwise be a sig that never matches, which the recreate drift guard turns
-- into "wait for the key end" for that slot.
local function DbfxStampPending(parent, hosts, kind, e)
    local h = hosts.hc
    if kind == "hc" then
        local sig = h and BF.RestampFxHealth(parent, h, e, true)
        if sig ~= nil and h._bf_fxSig ~= sig then return true end
    elseif h and not h._bf_fxHidden then
        return true
    end
    h = hosts.bd
    if kind == "bd" then
        local sig = h and BF.RestampFxBorder(parent, h, e, true)
        if sig ~= nil and h._bf_fxSig ~= sig then return true end
    elseif h and not h._bf_fxHidden then
        return true
    end
    h = hosts.ov
    if kind == "ov" then
        -- No initW/initH: the live pass never passes them (see StampDbfxKinds).
        local sig = h and BF.RestampFxOverlay(parent, h, e, nil, nil, true)
        if sig ~= nil and h._bf_fxSig ~= sig then return true end
    elseif h and not h._bf_fxHidden then
        return true
    end
    return false
end

-- initButton for a dfx slot: the regions (InitFxMerged) AND the visible state,
-- both inside the init window.
--
-- WHY at creation: slot buttons are engine-owned and addon code may only write
-- to them inside initializeFrame. During an active Mythic+ keystone auras stay
-- secret for the whole run (BF:IsAuraCreationRestricted() is true in AND out of
-- combat), so after a /reload inside a key every post-creation pcall'd write is
-- denied and nothing retries it until the key ends. With the visible stamp done
-- only after EnsureAuraSlotVisual returned, a reload in a key left these slots
-- built but blank -- field report 2026-09-10: "only some buff customizations
-- are active, some reverted to default".
--
-- `entry` is DbfxEntryFor's output, which lives in the shared scratch table
-- _dbfxEntry and is overwritten on the next container. The engine may run
-- initializeFrame LATE (the unverified lazy slot path), so the closure keeps
-- its own shallow copy; the color sub-table is already a fresh copy per call.
-- Allocated per slot CREATION only, never per pass.
--
-- The visible stamp is pcall'd on its own: a failure there must not fail the
-- structural init (which would mark the slot unhealthy and discard a button
-- whose regions are fine) -- the live-edit pass retries it on the next Layout.
local function MakeDbfxInit(kind, entry)
    local snap = {}
    for k, v in pairs(entry) do snap[k] = v end
    return function(button, parent, hosts)
        BF.InitFxMerged(button, parent, hosts)
        if hosts then pcall(StampDbfxKinds, parent, hosts, kind, snap, true) end
    end
end

local function ApplyDebuffContainerFx(parent, ac, groupTypeKey, pairOwn)
    -- Every kind of this feature renders on or around the health bar; a frame
    -- without one (config headers, some custom frames) can host none of it.
    local keys = parent._bf_dbfxKeys
    local hasOld = keys and #keys > 0
    if not parent.healthBar then
        if not hasOld then return end
    end
    local containers = BF:GetActiveCustomDebuffContainers()
    local nC = containers and #containers or 0
    -- Is the main Debuffs display on for this frame? Only ANCHORED containers
    -- care (see the gate in the loop), but it is frame-wide, so resolve it once.
    local rowShown = DebuffsShownFor(parent)
    -- v65: hoist the GROUP RESOLUTION, never the ANSWER. Lifted ABOVE the
    -- pre-scan so both it and the emit loop share one ResolveCFGGroupByFlatID
    -- scan per pass.
    local isCFG = type(groupTypeKey) == "string" and not groupTypeKey:find("^flat_")
    local grp   = isCFG and BF.ResolveCFGGroupByFlatID
        and BF:ResolveCFGGroupByFlatID(groupTypeKey) or nil
    local cfgOn = grp and grp[BF.AURAS_GROUP_CFG_FLAG.aurasDebuffs] or false
    -- The visibility gates, identical to ComputeDebuffContainerClaims': a
    -- container that claims nothing here shows nothing here, effects included.
    -- One function so the pre-scan and the emit loop cannot answer differently.
    local function ContainerFxShown(c, ci)
        if c.enabled == false then return false end
        if c.groupSettings and (c.perLayoutConfig == true or cfgOn) then
            local gs = c.groupSettings[groupTypeKey]
            if gs and gs.showForGroupType == false then return false end
        end
        -- v92: an ANCHORED container renders NOTHING while the Debuffs display
        -- is off -- there is no row to flow into and its own dbc is suppressed
        -- by the anchor. Firing the frame effect there would tint the health bar
        -- with zero icons on screen and no visible cause. A FLOATING container
        -- keeps the v74 independence: its dbc still renders with the row off,
        -- so its effect stays. Per container, because the anchor is per-Layout.
        if not rowShown and BF:IsDebuffContainerDebuffsAnchored(c, groupTypeKey) then
            return false
        end
        return true
    end
    -- Cheap pre-scan: the overwhelming majority of profiles configure no
    -- container frame effect at all, and this feature must cost them nothing
    -- beyond the gate reads. The gate runs FIRST -- ResolveContainerFrameEffect
    -- does a two-tier per-Layout read, and a container that cannot show one is
    -- not worth asking. Nothing below runs unless a container really has an
    -- effect (or we have slots to sweep).
    local anyFx = false
    if nC > 0 and parent.healthBar then
        for ci = 1, nC do
            local c = containers[ci]
            if ContainerFxShown(c, ci)
               and BF:ResolveContainerFrameEffect(c, groupTypeKey, ac) then
                anyFx = true; break
            end
        end
    end
    if not anyFx and not hasOld then return end
    -- Allocated only once something is actually going to use them: a profile
    -- with no container frame effect never grows these two tables.
    if not keys then keys = {}; parent._bf_dbfxKeys = keys end
    local cis = parent._bf_dbfxCi
    if not cis then cis = {}; parent._bf_dbfxCi = cis end
    for i = #keys, 1, -1 do keys[i] = nil end
    -- Sweep validity: never park on a pass that could not resolve the Layout
    -- (a CFG frame whose flat ID has not been minted), or the effects would
    -- blink out until something else forced another Layout.
    local passValid = (groupTypeKey ~= nil)
    -- Wiped UNCONDITIONALLY, before the emit branch: the sweep below reads it on
    -- the anyFx == false path too (every effect just switched to None), and a
    -- leftover set from the previous frame's pass would mark those slots as
    -- still-seen and strand them showing.
    for k in pairs(_dbfxSeen) do _dbfxSeen[k] = nil end
    if anyFx then
        -- The de-dup inputs, for the negation half of the composition. Resolved
        -- here (not shared with the container passes) for the same reason
        -- ApplyDebuffFlowedContainers resolves its own: identical inputs,
        -- identical answer, and only frames that actually have an effect pay it.
        local dedupPresent = ComputeDebuffPresetPresence(parent, groupTypeKey, ac, pairOwn)
        -- One signature for the whole candidate composition. It is a pure
        -- function of the de-dup set (which already folds the resolved dispel
        -- TYPE SET -- present.myTypesSig -- so a spec/talent change re-pushes
        -- the dispel-arm presets, the dvTypeSig discipline) plus the
        -- container's own Maximum Duration.
        local dedupSig = DebuffPresetPresenceSig(dedupPresent)
        -- Keystone recreate window (plan §3.1): the slot-button writes below
        -- would be denied; compare and request a slot rebuild instead.
        -- Resolved once per pass, and only on frames that have an effect.
        local inWindow = BF.IsAuraRecreateWindow and BF:IsAuraRecreateWindow()
        local defs  = BF.DEBUFF_CONTAINER_PRESETS
        local order = BF.DEBUFF_CONTAINER_PRESET_ORDER
        for ci = 1, nC do
            local c = containers[ci]
            local shown = ContainerFxShown(c, ci)
            local fx = shown and BF:ResolveContainerFrameEffect(c, groupTypeKey, ac) or nil
            local eff = fx and defs and order
                and EffectiveDebuffPresetSet(c, ci, pairOwn) or nil
            if eff then
                local kind, entry = DbfxEntryFor(fx)
                local maxDur = ContainerMaxDuration(c, ac)
                local candSig = dedupSig .. "|" .. tostring(maxDur)
                for i = 1, #order do
                    local pkey = order[i]
                    local def  = defs[pkey]
                    if kind and eff[pkey] and def and def.filter then
                        local key = "dfx" .. ci .. "_" .. pkey
                        local filter, cand = BF.ComposeDebuffPresetFilter(
                            pkey, def, ac, dedupPresent, maxDur, nil)
                        local s = parent._bf_auraSlots and parent._bf_auraSlots[key]
                        -- v88 recovery arm, copied from EnsureFxSlot
                        -- (BuffsAndContainers.lua) because this slot has the
                        -- same initButton and therefore the same failure class:
                        -- an InitFxMerged interrupted by the engine's late
                        -- initializeFrame path (running on a stack that was
                        -- tainted by then) leaves a slot that is structurally
                        -- present and visually DEAD -- no regions, so every
                        -- later pass restamps nothing and the effect is gone for
                        -- the session with no error. Retire it and fall into the
                        -- creation branch, which is already this function's
                        -- every-pass retry. Guarded on the one-boolean health
                        -- bit, so a working slot pays a single read.
                        if s and not s.healthy and BF.AuraSlotStylingState
                           and BF:AuraSlotStylingState(parent, key) == "discard" then
                            -- In the window "discard" means REBUILD (plan
                            -- §3.1): the recreate executor retires this record
                            -- only once its replacement exists, and does not
                            -- spend the slot-attempt budget. Keep the record
                            -- until then.
                            if inWindow then
                                BF:RequestAuraRecreate(parent, "slot",
                                    s.featureKey or key, "dfx")
                            elseif BF:DiscardAuraSlotVisual(parent, key) then
                                s = nil
                            end
                        end
                        if not s then
                            s = BF:EnsureAuraSlotVisual(parent, key, {
                                -- The record's own level is the LOWEST kind's
                                -- rung, an inert base -- every kind draws from
                                -- its own absolute-level host.
                                frameLevelOffset = BF.CONTAINER_FX_LEVEL.hc,
                                filter = filter,
                                candidateFilters = cand,
                                -- Regions AND visible state at creation --
                                -- see MakeDbfxInit.
                                initButton = MakeDbfxInit(kind, entry),
                                levelHosts = BF.MakeFxHostDefs(),
                            })
                            if s then s._bf_dfxCandSig = candSig end
                        else
                            if s.parked then
                                -- Unparking pushes the record's candidate set
                                -- and forces the rebuild, so re-stamp first.
                                BF:SetAuraSlotCandidates(parent, key, cand)
                                s._bf_dfxCandSig = candSig
                                BF:SetAuraSlotVisualDormant(parent, key, false)
                            elseif s._bf_dfxCandSig ~= candSig then
                                BF:SetAuraSlotCandidates(parent, key, cand)
                                s._bf_dfxCandSig = candSig
                            end
                            BF:SetAuraSlotVisualFilter(parent, key, filter)
                        end
                        if s and s.hosts then
                            -- LIVE-EDIT path. A slot created this pass was
                            -- already stamped inside its initButton
                            -- (MakeDbfxInit), with the same sigs/latches, so
                            -- this is a no-op for it; it only writes when the
                            -- effect was edited or an earlier stamp was denied.
                            -- In the recreate window: compare without writing
                            -- (DbfxStampPending), rebuild on a mismatch.
                            if inWindow then
                                if DbfxStampPending(parent, s.hosts, kind, entry) then
                                    BF:RequestAuraRecreate(parent, "slot",
                                        s.featureKey or key, "dfx")
                                end
                            else
                                StampDbfxKinds(parent, s.hosts, kind, entry)
                            end
                            _dbfxSeen[key] = true
                            keys[#keys + 1] = key
                            cis[key] = ci
                        end
                    end
                end
            end
        end
    end
    -- ── STALE SWEEP ────────────────────────────────────────────────────────
    -- Park every dfx slot this pass did not emit: the effect switched to None,
    -- the preset moved container (or was absorbed by a combined pair), the
    -- container was disabled, hidden for this Layout, or deleted.
    if passValid then
        local t = parent._bf_auraSlots
        if t then
            for key in pairs(t) do
                if key:sub(1, 3) == "dfx" and not _dbfxSeen[key] then
                    BF:SetAuraSlotVisualDormant(parent, key, true)
                    cis[key] = nil
                end
            end
        end
    end
end

function DebuffIcons:Create(parent)
    -- Preview frames: plain icon pools only (dummy pipeline; no containers).
    if not parent._isPreviewFrame then
        if parent._bf_auraContainers and parent._bf_auraContainers.debuffs then return end
        -- v72 PERF: nothing for a frame that is not in service yet — the
        -- debuffs container plus every dbc<ci> custom container is built by
        -- BF:EnsureFrameAuraContainers when the frame gets a unit (which
        -- routes back through :Layout, a superset of this function). See
        -- the measured numbers in Auras/ContainerFactory.lua.
        if BF:ShouldDeferFrameAuraContainers(parent) then return end
        -- v77 PERF: no "debuffs" container for a frame whose Debuffs display is
        -- OFF. showDebuffs previously reached only SyncAuraGridContainer's
        -- show/hide, so the container plus primary + secondary + up to four
        -- enlarged category groups were built and styled regardless. Custom
        -- dbc<ci> containers are NOT gated -- v74 decoupled them from this
        -- toggle deliberately. Re-enabling is create-on-first-enable in
        -- :Update, the BigDefIcons.lua:112 pattern.
        if not DebuffsShownFor(parent) then return end
        local buttonSpec, geo = DebuffContainerSpecs(parent)
        local ac = BF:GetAuraCacheForFrame(parent)
        -- v68: fold in the categories/tokens claimed by custom debuff containers
        -- (stash for the combat-edge re-apply). secondary == nil is preserved as
        -- the "no secondary group" signal, so append the token suffix only to a
        -- real secondary filter.
        local groupTypeKey = BF.ResolveGroupTypeKey and BF:ResolveGroupTypeKey(parent)
        -- v92 (2026-08-20): combined-pair ownership FIRST -- the claims pass,
        -- the flow set and both container passes all read it, and resolving it
        -- once here is what guarantees they agree about who owns a pair.
        local pairOwn = ResolveDebuffPairOwnership(ac, groupTypeKey)
        local claimSuffix, claimCats, ccClaimed, claims, flowClaims =
            ComputeDebuffContainerClaims(parent, groupTypeKey, pairOwn)
        parent._bf_dbcClaimCats = claimCats
        parent._bf_dbcClaimCC = ccClaimed or nil
        -- v92 §B4: rank + size mult for every DEBUFFS-anchored claim, resolved
        -- BEFORE the shape (it folds them into its signature and synthesises an
        -- entry per flowed preset).
        local flowSet, flowSig = ComputeDebuffFlowSet(ac, groupTypeKey, flowClaims, pairOwn)
        -- v84 §9.10: resolve the whole type shape before anything is created --
        -- it decides the group set, their sizes, their flow order and the wrap
        -- slack. Stashed on the frame (inside the resolver) for the combat-edge
        -- candidate re-apply.
        local shape = ResolveDebuffShape(parent, ac, claimSuffix, claims, flowSet, flowSig)
        if shape.maxMult > 1 then
            geo.lineSizeSlack = geo.size * (shape.maxMult - 1)
        end
        local other = shape.byId.other
        -- v95: the container-level pair is `primary`'s OWN pair. The only group
        -- this call creates is `primary` (EnsureAuraGridSpellGroup does not fall
        -- back to the container spec for sort), so resolving it for the `other`
        -- entry is exact, not an approximation.
        local sortM, sortD = DebuffGroupSortFor(ac, other)
        local c = BF:EnsureAuraGridContainer(parent, "debuffs", {
            buttonSpec    = buttonSpec,
            maxFrameCount = geo.maxIcons,
            -- §9.6: the user-chosen Sort Order replaces the hardcoded
            -- UnitFrameDebuff comparator (which §9.4 found produced nothing --
            -- see the ResolveDebuffSort header: no ProcessAura policy meant no
            -- debuffType to tier on). Every group of the row takes the same
            -- choice, except under Sort Order "blizzard" -- DebuffGroupSortFor.
            sortMethod    = sortM,
            sortDirection = sortD,
            spacing       = geo.spacing,
            rowSpacing    = geo.rowSpacing,
            groups = {
                -- Explicit flow order: layoutIndex is ORDER-DRIVEN now (1..6
                -- across the five type groups plus this one). Groups without a
                -- layoutIndex fall back to their registrationIndex (1, 2, ...),
                -- which COLLIDES with the type groups' indices -- PTR-observed
                -- as big CC flowing after regular debuffs and two big groups
                -- overlapping at the same origin.
                --
                -- v84: `secondary` is no longer created here. It is now the
                -- Dispellable TYPE group and is created (with its own spec,
                -- size multiplier and own max) by ApplyDebuffTypeGroups below,
                -- alongside bigBoss / bigRole / bigCC / bigPrio -- uniform
                -- handling is what lets every type carry a Relative Size.
                -- v93: "Other Debuffs" is a row on the Preset/Filter list like
                -- any other, so it carries its own Max Debuffs rather than the
                -- container-wide geo.maxIcons fallback.
                { key = "primary", filter = other.filter, layoutIndex = other.li,
                  maxFrameCount = BF:ResolveDebuffTypeMax(ac, "other") },
            },
        })
        -- v95: the ProcessAura policy, from the very first pass, so the
        -- "blizzard" Sort Order has a debuffType to tier on from the start.
        EnsureDebuffProcessPolicy(c)
        -- ...and re-pointed on every LAYOUT pass too (v95 -- the pre-geometry
        -- block in :Layout; until then this :Create call was the only one and
        -- the cap was pinned for the session). create = true because `primary`
        -- is born on the container's own groups list, which stamps no ownMax
        -- entry.
        BF:SetAuraGridGroupOwnMax(parent, "debuffs", "primary",
            BF:ResolveDebuffTypeMax(ac, "other"), true)
        ApplyDebuffTypeGroups(parent, buttonSpec, geo, shape, ac)
        -- v92 §B3.4: the DEBUFFS-anchored containers' preset groups, in this
        -- same container, at their priority positions.
        ApplyDebuffFlowedContainers(parent, ac, groupTypeKey, shape, geo, pairOwn)
        -- "Show Other Debuffs" off parks the residual flow; only the enabled
        -- type groups render.
        BF:SetAuraGridGroupDormant(parent, "debuffs", "primary", not other.live)
        BF:ApplyAuraGridGeometry(parent, "debuffs", geo)
        ApplyDebuffLTDExcludes(parent)
        ApplyDebuffCustomContainers(parent, pairOwn)
        -- v92: per-container FRAME effects. After the container passes, because
        -- it reuses their de-dup inputs and must see the same effective preset
        -- sets they just rendered.
        ApplyDebuffContainerFx(parent, ac, groupTypeKey, pairOwn)
        return
    end
    parent.debuffFrames = parent.debuffFrames or {}
    local level = parent:GetFrameLevel() + 223
    local ac = BF:GetAuraCacheForFrame(parent)
    local db = BF:GetSectionProfileForFrame("tooltips", parent)
    local enabled = ac and ac.showDebuffTooltip or false
    local combat  = ac and ac.showDebuffTooltipInCombat or false
    local pos     = db and db.debuffTooltipPosition or "default"
    for i = 1, BF.MAX_DEBUFFS do
        if not parent.debuffFrames[i] then
            local icon = BF.BuildAuraIconFrame(parent, level)
            parent.debuffFrames[i] = icon
            self:EnableFrameTooltips(icon, enabled, combat, pos)
        end
    end
end

-- v67: DebuffIcons:UpdateFrameSettings removed (12.1-only). Tooltip bindings
-- are baked per container button, so this returned before touching the icon
-- pool on every 12.1 call. Its only dispatcher, BF:DispatchTooltipSettings,
-- was deleted along with the other three empty UpdateFrameSettings methods.

-- Per-scope cache write. Called from RebuildAuraCacheScope. Owns debuff
-- geometry + debuffDurationDispelColor (which lives in auraText behind
-- the useGlobal switch).
function DebuffIcons:UpdateDB(cache, flat, grp)
    -- v60: resolved per aura sub-category. The Buffs and Debuffs
    -- per-layout toggles are independent, so a flat's auras table can
    -- carry stale rawkeys for whichever group is currently OFF --
    -- ResolveCFGSection(..., "auras") plus an index would read them.
    local debuffsP = BF.ResolveCFGAurasSubcat(BF, flat, grp, "debuffs") or {}
    cache.showDebuffs    = debuffsP.showDebuffs ~= false
    cache.debuffSize     = debuffsP.debuffSize or 12
    cache.debuffAnchor   = debuffsP.debuffAnchorPoint or "BOTTOMLEFT"
    cache.debuffOffsetX  = debuffsP.debuffOffsetX or 0
    cache.debuffOffsetY  = debuffsP.debuffOffsetY or 0
    cache.debuffGrowDir  = BF.NormalizeGrowDirection(
        debuffsP.debuffGrowDirection or "RIGHT_UP", cache.debuffAnchor)
    cache.maxDebuffs     = debuffsP.maxDebuffs or 8
    cache.debuffsPerRow  = debuffsP.debuffsPerRow or 3
    cache.debuffSpacing  = debuffsP.debuffSpacing or 1
    cache.debuffRowSpacing = debuffsP.debuffRowSpacing or 1
    -- v85: cache.debuffSortRule removed. The legacy numeric "Sort By" key was
    -- written here and read by NOTHING; §9.6's debuffSortOrder replaced the
    -- option it belonged to, and the dbVersion-66 dead-key sweep nils it.
    -- ── v84 (Stage 5 §9.6 + §9.10): the debuff TYPE model ────────────────
    -- debuffShowMode and the four enlarge*Debuffs keys are GONE; they are read
    -- only by the dbVersion-66 migration, which resets these rows uniformly.
    cache.debuffBaseFilter  = debuffsP.debuffBaseFilter or "none"
    cache.debuffShowOther   = debuffsP.debuffShowOther ~= false
    cache.debuffSortOrder   = debuffsP.debuffSortOrder or "recentLast"
    cache.debuffMaxDuration = debuffsP.debuffMaxDuration or "none"
    -- ── v95 SIMPLE MODE (owner-approved plan 2026-08-25) ────────────────
    -- ResolveDebuffShape / DebuffShapeSig / DebuffGroupSortFor all read these
    -- off the AURA CACHE, never off a profile table, so both mirror blocks
    -- (here and Auras/AuraConfig.lua) must carry them or the runtime silently
    -- sees "off" on one of the two paths. Simple Mode defaults OFF (normal
    -- mode is byte-for-byte unchanged when it is); Combine Boss/Role defaults
    -- ON, so nil reads TRUE (`~= false`).
    cache.debuffSimpleMode        = debuffsP.debuffSimpleMode == true
    cache.debuffSimpleSeparateBoss = debuffsP.debuffSimpleSeparateBoss == true
    -- 2026-08-25 (owner request): Simple Mode's "Exclude Applied by Friendly".
    -- Defaults OFF; read only by the simple arm of ResolveDebuffShape.
    cache.debuffSimpleExcludeFriendly = debuffsP.debuffSimpleExcludeFriendly == true
    -- ── v91: the PRIORITY LIST (owner ruling 2026-08-17) ────────────────
    -- Ranks are UNIQUE 1..7 (Boss 1 / Role 2 / CC 3 / DispMe 4 / DispOthers 5
    -- / Priority 6 / Other 7 by default); debuffOrder* / debuffOtherOrder /
    -- debuffDispellableMode / debuffType|SizeDispellable are RETIRED (migration
    -- only). Combine flags default ✓ / ✗ / ✓ (the mockup state).
    -- KEEP IN LOCKSTEP with the mirror block in Auras/AuraConfig.lua.
    cache.debuffTypeBoss        = debuffsP.debuffTypeBoss ~= false
    cache.debuffSizeBoss        = debuffsP.debuffSizeBoss or 1.4
    cache.debuffRankBoss        = debuffsP.debuffRankBoss or 1
    cache.debuffMaxBoss         = debuffsP.debuffMaxBoss or 3
    cache.debuffTypeRole        = debuffsP.debuffTypeRole ~= false
    cache.debuffSizeRole        = debuffsP.debuffSizeRole or 1.4
    cache.debuffRankRole        = debuffsP.debuffRankRole or 2
    cache.debuffMaxRole         = debuffsP.debuffMaxRole or 3
    cache.debuffTypeCC          = debuffsP.debuffTypeCC ~= false
    cache.debuffSizeCC          = debuffsP.debuffSizeCC or 1.4
    cache.debuffRankCC          = debuffsP.debuffRankCC or 3
    cache.debuffMaxCC           = debuffsP.debuffMaxCC or 3
    cache.debuffTypeDispMe      = debuffsP.debuffTypeDispMe ~= false
    cache.debuffSizeDispMe      = debuffsP.debuffSizeDispMe or 1.0
    cache.debuffRankDispMe      = debuffsP.debuffRankDispMe or 4
    cache.debuffMaxDispMe       = debuffsP.debuffMaxDispMe or 3
    cache.debuffTypeDispOthers  = debuffsP.debuffTypeDispOthers ~= false
    cache.debuffSizeDispOthers  = debuffsP.debuffSizeDispOthers or 1.0
    cache.debuffRankDispOthers  = debuffsP.debuffRankDispOthers or 5
    cache.debuffMaxDispOthers   = debuffsP.debuffMaxDispOthers or 3
    cache.debuffTypePriority    = debuffsP.debuffTypePriority ~= false
    cache.debuffSizePriority    = debuffsP.debuffSizePriority or 1.4
    cache.debuffRankPriority    = debuffsP.debuffRankPriority or 6
    cache.debuffMaxPriority     = debuffsP.debuffMaxPriority or 3
    cache.debuffRankOther       = debuffsP.debuffRankOther or 7
    -- 2026-08-25: Simple Mode's OWN priority list. Seven more keys rather than
    -- a reinterpretation of the seven above -- see BF:DebuffRankOf for why the
    -- two modes cannot share one set. Defaults are the canonical row sequence,
    -- and dbVersion 78 seeds an existing profile's from its normal ranks.
    -- KEEP IN LOCKSTEP with the mirror block in Auras/AuraConfig.lua.
    cache.debuffSimpleRankBoss       = debuffsP.debuffSimpleRankBoss or 1
    cache.debuffSimpleRankRole       = debuffsP.debuffSimpleRankRole or 2
    cache.debuffSimpleRankCC         = debuffsP.debuffSimpleRankCC or 3
    cache.debuffSimpleRankDispMe     = debuffsP.debuffSimpleRankDispMe or 4
    cache.debuffSimpleRankDispOthers = debuffsP.debuffSimpleRankDispOthers or 5
    cache.debuffSimpleRankPriority   = debuffsP.debuffSimpleRankPriority or 6
    cache.debuffSimpleRankOther      = debuffsP.debuffSimpleRankOther or 7
    -- v93: per-type Max Debuffs (Preset/Filter rows). Governs the type's
    -- group in the Debuffs row AND the same type's preset group inside any
    -- container that claimed it -- see BF:ResolveDebuffTypeMax.
    cache.debuffMaxOther        = debuffsP.debuffMaxOther or 3
    cache.debuffCombineBossRole      = debuffsP.debuffCombineBossRole ~= false
    cache.debuffCombineDispel        = debuffsP.debuffCombineDispel == true
    cache.debuffCombinePriorityOther = debuffsP.debuffCombinePriorityOther ~= false
    -- The two "Dispellable by Me" resolver toggles (BF:MyDispelTypes).
    cache.debuffDispMeTalented  = debuffsP.debuffDispMeTalented ~= false
    cache.debuffDispMeLongCd    = debuffsP.debuffDispMeLongCd == true
    -- 2026-09-14: the claimed-category Relative Size table (preset key ->
    -- percent), edited on the Preset/Filter subtab. PresetRatio reads it off
    -- the cache; left out of this copy it was nil on every path and the
    -- container fallback (which the slider clears) answered 100% forever.
    cache.presetRelativeSize    = debuffsP.presetRelativeSize
    cache._roundedDebuffSize = BF:PixelRound(cache.debuffSize)
    cache.debuffBorderColor     = debuffsP.debuffBorderColor
    -- nil falls back to the base thickness at bind time (older profiles /
    -- CFG flats without the key).
    cache.debuffDispelBorderThickness = debuffsP.debuffDispelBorderThickness
    -- v71: dispel-type corner icon (section baseline; per-container override in
    -- ResolveContainerDispelTypeIcon).
    cache.showDebuffDispelTypeIcon  = debuffsP.showDebuffDispelTypeIcon == true
    cache.debuffDispelTypeIconScale = debuffsP.debuffDispelTypeIconScale or 40
    -- v71: color the whole border by dispel type (default on; nil == on).
    cache.debuffColorBorderByDispel = debuffsP.debuffColorBorderByDispel ~= false
    cache.debuffBorderThickness = debuffsP.debuffBorderThickness or 1
    cache.debuffBlizzardBorders = debuffsP.debuffBlizzardBorders == true
    cache.debuffBorderStyle     = debuffsP.debuffBorderStyle

    -- debuffDurationDispelColor: setting REMOVED (12.1 cut, V7: no
    -- dispel-driven text color binding exists) — forced false so stale
    -- DB values are inert on both paths.
    cache.debuffDurationDispelColor = false

    local ttp = BF.ResolveCFGSection(BF, flat, grp, "tooltips") or {}
    cache.showDebuffTooltip         = ttp.showDebuffTooltip or false
    cache.showDebuffTooltipInCombat = ttp.showDebuffTooltipInCombat or false
end

-- Grid2 pattern: stamp cooldown config + color curve targets onto icon
-- frames at Layout time. Debuff-specific: _bf_useDispelColor flag so
-- UpdateIconColorCurve respects dispel color text behavior.
-- v67: 12.0.7 branch removed (addon is 12.1-only).
function DebuffIcons:Layout(parent)
    -- v72 PERF: same in-service gate as BuffsAndContainers:Layout — a frame
    -- that has never carried a unit builds and re-walks nothing.
    if not parent._isPreviewFrame and not BF:ShouldDeferFrameAuraContainers(parent) then
        -- v88b: flag a Layout running inside the restricted window so the regen
        -- replay re-runs it — the debuff twin of the same stamp in
        -- BuffsAndContainers:Layout. See BF:NoteAuraLayoutRestricted
        -- (Auras/ContainerFactory.lua): every engine call below is pcall'd, so a
        -- combat /reload can leave this frame partially applied, silently.
        BF:NoteAuraLayoutRestricted(parent)
        if not (parent._bf_auraContainers and parent._bf_auraContainers.debuffs) then
            self:Create(parent)
        end
        local ac = BF:GetAuraCacheForFrame(parent)
        local buttonSpec, geo = DebuffContainerSpecs(parent)
        -- v68: categories/tokens claimed by custom debuff containers (stashed
        -- for the combat-edge re-apply of ApplyDebuffLTDExcludes).
        local groupTypeKey = BF.ResolveGroupTypeKey and BF:ResolveGroupTypeKey(parent)
        -- v92: see the twin in :Create -- one ownership resolution per pass.
        local pairOwn = ResolveDebuffPairOwnership(ac, groupTypeKey)
        local claimSuffix, claimCats, ccClaimed, claims, flowClaims =
            ComputeDebuffContainerClaims(parent, groupTypeKey, pairOwn)
        parent._bf_dbcClaimCats = claimCats
        parent._bf_dbcClaimCC = ccClaimed or nil
        -- v92 §B4: see the twin in :Create.
        local flowSet, flowSig = ComputeDebuffFlowSet(ac, groupTypeKey, flowClaims, pairOwn)
        -- v84 §9.10: re-resolve the shape (self-caching on its signature), then
        -- stamp the wrap slack BEFORE the geometry pass consumes geo.
        local shape = ResolveDebuffShape(parent, ac, claimSuffix, claims, flowSet, flowSig)
        if shape.maxMult > 1 then
            geo.lineSizeSlack = geo.size * (shape.maxMult - 1)
        end
        local other = shape.byId.other
        -- v95: `primary`'s own sort pair (see DebuffGroupSortFor); the type
        -- groups resolve theirs inside ApplyDebuffTypeGroups.
        local sortM, sortD = DebuffGroupSortFor(ac, other)
        -- v95: cheap, flag-guarded on the container -- but re-offered every
        -- Layout so a container built before the policy existed (a /reload into
        -- a combat-deferred pass, or any future creation path that skips
        -- :Create) still gets it. Nothing else depends on it: the policy only
        -- ADDS metadata, and a group that names neither processedAuraType nor a
        -- debuffType-tiering sort is untouched by it.
        EnsureDebuffProcessPolicy(parent._bf_auraContainers
            and parent._bf_auraContainers.debuffs)
        -- ── v95 FIX (owner report 2026-08-25): RE-POINT EVERY GROUP'S OWN MAX
        -- BEFORE THE GEOMETRY PASS. ───────────────────────────────────────
        -- `primary`'s Max Debuffs (debuffMaxOther) was re-pointed in :Create
        -- ONLY -- the comment there claimed "every pass", but this function
        -- never did it -- so the cap stayed pinned at whatever the frame was
        -- born under until a /reload: editing Priority/Other's Max Debuffs
        -- from 2 to 5 kept capping at 2. The type groups WERE re-pointed each
        -- pass (ApplyDebuffTypeGroups), but AFTER ApplyAuraGridGeometry, which
        -- is the pass that actually pushes SetAuraGroupMaxFrameCount, tops up
        -- the styling of newly displayable pooled buttons and kicks
        -- UpdateAllAuras -- so a type row's Max applied one Layout behind.
        --
        -- Both now happen HERE, ahead of geometry, so the same pass pushes the
        -- new cap. ApplyDebuffTypeGroups keeps its own re-point for the
        -- creation pass (a group that does not exist yet cannot be re-pointed
        -- here -- `create` is deliberately NOT passed for the type groups, so a
        -- missing ownMax entry is left for creation to pin). `primary` passes
        -- create = true for the reason :Create gives: it is born on the
        -- container's own groups list, which stamps no ownMax entry.
        -- Flowed container groups (fpre*) re-point inside ApplyPresetGroups
        -- and are unchanged.
        BF:SetAuraGridGroupOwnMax(parent, "debuffs", "primary",
            BF:ResolveDebuffTypeMax(ac, "other"), true)
        do
            local entries = shape.order
            for i = 1, #entries do
                local e = entries[i]
                if e.t and e.id ~= "other" and not e.flowed then
                    BF:SetAuraGridGroupOwnMax(parent, "debuffs", e.gk,
                        BF:ResolveDebuffTypeMax(ac, e.id))
                end
            end
        end
        BF:ApplyAuraGridGeometry(parent, "debuffs", geo)
        BF:ApplyAuraGridButtonSpec(parent, "debuffs", buttonSpec)
        -- Live filter / order / sort recompute (change-guarded throughout).
        BF:SetAuraGridGroupFilter(parent, "debuffs", "primary", other.filter)
        BF:SetAuraGridGroupLayoutIndex(parent, "debuffs", "primary", other.li)
        BF:SetAuraGridGroupSort(parent, "debuffs", "primary", sortM, sortD)
        -- v84: type groups (create/park/restyle/reorder live).
        -- v94 FIX: `ac` was dropped from this call (the :Create twin at the top
        -- of this file passes it, and the signature declares it). Without it the
        -- two BF:ResolveDebuffTypeMax(ac, e.id) reads inside fall back to the
        -- GLOBAL BF.AuraCache -- the ACTIVE party/raid flat -- so every Layout
        -- pass re-pointed each type group's Max Debuffs from the wrong scope,
        -- silently overwriting the correct value :Create pinned. It flip-flopped
        -- Create<->Layout, and was always wrong for CFG frames and for any frame
        -- whose Layout is not the active one.
        ApplyDebuffTypeGroups(parent, buttonSpec, geo, shape, ac)
        -- v92 §B3.4: DEBUFFS-anchored containers' preset groups + their sweep.
        ApplyDebuffFlowedContainers(parent, ac, groupTypeKey, shape, geo, pairOwn)
        BF:SetAuraGridGroupDormant(parent, "debuffs", "primary", not other.live)
        -- v50: long-term debuff / blacklist exclusions (sig-guarded).
        ApplyDebuffLTDExcludes(parent)
        -- v68: custom debuff containers (dbc<ci>) geometry/spec/presets + sweep.
        ApplyDebuffCustomContainers(parent, pairOwn)
        -- v92: per-container FRAME effects. After the container passes, because
        -- it reuses their de-dup inputs and must see the same effective preset
        -- sets they just rendered.
        ApplyDebuffContainerFx(parent, ac, groupTypeKey, pairOwn)
    end
    -- Fall through for the dummy icon pools (preview/test mode): they
    -- still need the font/scale stamping below.
    if not parent.debuffFrames then return end
    local ac = BF:GetAuraCacheForFrame(parent)
    local curveHides = ac.curveHidesDebuff
    for i = 1, #parent.debuffFrames do
        local icon = parent.debuffFrames[i]
        -- Clear cached index so Update repositions with the new offset table.
        icon.SF_LastIndex = nil
        if icon.cooldown then
            local cd = icon.cooldown
            cd:SetDrawSwipe(not ac.disableDebuffSwipe)
            cd:SetDrawEdge(not ac.disableDebuffSpark)
            cd:SetReverse(ac.reverseDebuffSwipe or false)
            cd:SetHideCountdownNumbers(not ac.showDebuffDuration)
            -- Grid2 pattern: re-fetch if not yet available
            if ac.showDebuffDuration and not cd.timerText then
                cd.timerText = cd:GetCountdownFontString()
            end
            local tt = cd.timerText
            if tt then
                local fontPath = ac.debuffDurationFont or "Interface\\AddOns\\BuzzardFrames\\Media\\Fonts\\RobotoCondensed-Bold.ttf"
                local autoScale = ac.debuffAutoScale
                local fontSize = autoScale and 11 or (ac.debuffFontSize or 11)
                local fontBorder = ac.debuffDurationBorder or "OUTLINE"
                local timerScale = autoScale and ((ac._roundedDebuffSize or 12) / 12 * (ac.debuffTimerScale or 1.0)) or 1.0
                cd._bf_font   = fontPath
                cd._bf_size   = fontSize
                cd._bf_border = fontBorder
                cd._bf_scale  = timerScale
                tt:SetFont(fontPath, fontSize, fontBorder)
                tt:SetScale(timerScale)
                tt:ClearAllPoints()
                tt:SetPoint("CENTER", cd, "CENTER", 0, 0)
                local fc = ac.debuffFontColor
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
            -- Color curve config (Grid2 pattern: stamp on icon)
            icon.colorCurveObject = ac.expiringCurveDebuff
            icon.colorCurveText = tt
            -- Debuffs: border is owned by dispel color, never by curve
            icon.colorCurveBorder = nil
            -- Debuff dispel color text behavior: when dispelColorActive,
            -- UpdateIconColorCurve skips painting the text with the curve color.
            icon._bf_useDispelColor = (not curveHides) and ac.debuffDurationDispelColor or nil
            -- curveHidesDebuff: curve alpha overrides dispel color (text hidden)
            icon._bf_curveOverridesDispel = curveHides or nil
        end
    end
end

-- ============================================================
-- HideAll: hide all debuff icons on a frame.
-- ============================================================
function DebuffIcons:HideAll(frame)
    if not frame.debuffFrames then return end
    for i = 1, #frame.debuffFrames do
        local icon = frame.debuffFrames[i]
        if icon and icon:IsShown() then
            icon:Hide()
            icon.SF_LastIndex = nil
            icon.auraInstanceID = nil
        end
    end
end

-- ============================================================
-- Update: unit-sync + feature-gate for the debuffs AuraContainer.
-- v67 (12.1-only): no Lua aura scan and no status:GetIcons call — the
-- container tracks, filters and renders natively. This resolves the show
-- gate and calls BF:SyncAuraGridContainer.
-- ============================================================
function DebuffIcons:Update(frame, unit)
    if frame._isPreviewFrame then return end
    -- v72 PERF: first-render safety net — see the twin in
    -- BuffsAndContainers:Update. One field read in steady state.
    if not frame._bf_auraContainersBuilt then
        BF:EnsureFrameAuraContainers(frame)
    end
    local ac2 = BF:GetAuraCacheForFrame(frame)
    local parentHeader2 = frame._bf_parentHeader or frame:GetParent()
    local moduleOff = parentHeader2 and parentHeader2.isCustomFrame
        and parentHeader2.moduleShowDebuffs == false
    -- v93: hostile/charmed suppression. The debuffs row had NO unit-state
    -- gate at all -- and it is the row that degrades worst, because the
    -- engine's RAID scoping stops narrowing on a unit we cannot assist: a
    -- mind-controlled member's row filled with the whole raid's DoTs. See
    -- the suppression block near the top of Auras/ContainerFactory.lua.
    -- One table read (cached, event-maintained predicate).
    -- Suppression is a RENDER gate, never a CREATION gate. Creation is
    -- combat-restricted (BF:IsAuraCreationRestricted), so folding suppression
    -- into the create-on-first-enable term below would mean a unit that is
    -- hostile at the moment its frame first paints never gets its container
    -- built -- and when it turned friendly again mid-fight there would be
    -- nothing to show until the next out-of-combat pass. Build as if the unit
    -- were friendly; hide at the Sync, which is a plain SetShown/SetAlpha and
    -- needs no combat window. It is not a park trigger either: the park arms
    -- refuse a suppressed unit by rule, since the state reverts in seconds --
    -- see "NEVER PARK A TRANSIENT STATE" in ContainerFactory.lua.
    local suppressed  = BF:IsUnitAuraSuppressed(unit)
    local wantDebuffs = (ac2.showDebuffs ~= false) and not moduleOff
    local show        = wantDebuffs and not suppressed
    -- v77 CREATE-ON-FIRST-ENABLE — twin of BuffsAndContainers:Update. :Create
    -- skips the container while the display is off, so the first pass that
    -- sees it back ON builds it. :Layout is the build path (geometry, styling,
    -- filters and the enlarged groups all have to land) and is idempotent.
    if wantDebuffs and not (frame._bf_auraContainers and frame._bf_auraContainers.debuffs)
       and not BF:IsAuraCreationRestricted() then
        DebuffIcons:Layout(frame)
    end
    BF:SyncAuraGridContainer(frame, "debuffs", unit, show)
    -- v68: custom debuff containers fold the module show gate with each
    -- container's per-Layout "Enabled for this Layout" flag, resolved at Layout
    -- time into frame._bf_dbcVisible. Orphans beyond #containers were already
    -- hidden by the Layout sweep; this only visits the live range.
    local dbcs = BF:GetActiveCustomDebuffContainers()
    if dbcs then
        local vis = frame._bf_dbcVisible
        -- v92 §B2: a DEBUFFS-anchored container has no dbc<ci> to sync -- it
        -- renders as fpre<ci>_* groups of the `debuffs` container, which this
        -- function already synced above (a group follows its container's shown
        -- state). Skipping it here is what makes ApplyDebuffCustomContainers'
        -- hide stick; without it this loop re-showed, every pass, the container
        -- that pass had just hidden. Resolved at Layout, so the cost here is
        -- one table lookup. Two flags, not one: vis[ci] still means "the user
        -- wants this container" (see the note at its resolution site).
        local dbcAnchored = frame._bf_dbcAnchored
        for ci = 1, #dbcs do
            if not (dbcAnchored and dbcAnchored[ci]) then
            -- v74 (owner ruling): custom debuff containers show INDEPENDENTLY
            -- of the section's Show Debuffs toggle, matching the buff side
            -- (BuffsAndContainers:Update syncs bfc<ci> without showBuffs).
            -- `show` used to fold ac2.showDebuffs in here, so turning the
            -- main row off for a Layout also hid every custom container.
            -- The module gate (moduleOff) and each container's own Enabled /
            -- per-Layout visibility (vis[ci], resolved at Layout) still
            -- apply. Preset dedup never read showDebuffs, so it is unchanged.
            -- v93: suppression applies to custom debuff containers too --
            -- they are as unfilterable on a hostile unit as the main row.
            local cShown = (not moduleOff) and (not suppressed)
                and (not vis or vis[ci] ~= false)
            BF:SyncAuraGridContainer(frame, "dbc" .. ci, unit, cShown)
            end
        end
    end
    -- v92: per-container FRAME EFFECT slots. Deliberately OUTSIDE the loop
    -- above and NOT gated on _bf_dbcAnchored: a frame effect is frame-level
    -- (health tint / border / overlay), so it is independent of where the
    -- container's icons render -- an anchored container keeps its effects. The
    -- container's own Enabled + per-Layout visibility still apply, via the same
    -- vis[] the icons use. Precomputed key list, so a frame with no effect
    -- configured pays one field read on this hot path.
    local fxKeys = frame._bf_dbfxKeys
    if fxKeys and #fxKeys > 0 then
        local vis = frame._bf_dbcVisible
        local cis = frame._bf_dbfxCi
        local anch = frame._bf_dbcAnchored
        for i = 1, #fxKeys do
            local key = fxKeys[i]
            local ci  = cis and cis[key]
            local shown = (not moduleOff) and (not suppressed)
                and (not (vis and ci) or vis[ci] ~= false)
            -- v92: the anchored-container gate, mirroring the Layout pass. An
            -- anchored container renders nothing while the Debuffs row is off
            -- (`show`), so its effect must be off too; a FLOATING container is
            -- independent of the row by the v74 ruling and keeps its effect.
            -- The Layout pass already refuses to EMIT in that state, so this is
            -- the belt to its braces -- it also covers the window between a
            -- showDebuffs toggle and the next Layout.
            if shown and ci and anch and anch[ci] and not show then
                shown = false
            end
            BF:SyncAuraSlotVisual(frame, key, unit, shown)
        end
    end
end

BF:RegisterIndicator(DebuffIcons)
DebuffIcons:EnableDeferredUpdates()
