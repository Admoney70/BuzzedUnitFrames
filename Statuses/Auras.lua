-- ============================================================
-- BuzzardFrames: Statuses/Auras.lua
-- Aura statuses — Grid2 architecture.
--
-- Grid2 reference: modules/StatusAuras.lua
-- BF mirrors Grid2's separate-status-object layout (buffs, bigdef,
-- debuffs, dispel, buffmatch, crowdcontrol), each with its own
-- indicator bindings.
--
-- v67 (12.1-only): every aura DATA path in this file is gone. Aura
-- rendering runs through the 12.1 AuraContainer path (ContainerFactory.lua
-- + BF:SyncAuraGridContainer), so what remains here is registration and
-- liveness only:
--   * buffs — keeps its UNIT_AURA registration because the SingleAuraTracker
--     scan (missing-raid-buff / symbiotic) is that event's one live consumer.
--   * bigdef / debuffs / dispel / crowdcontrol — registered so indicator
--     bindings resolve and IsActive answers, but they no longer register
--     UNIT_AURA, fetch auras, or cache anything.
--   * buffmatch — data-only status; its producer (UpdateCache) and consumer
--     (the buffHighlight indicator) are both gone.
-- The cache-clearing entry points below are retained because callers
-- OUTSIDE this file still invoke them; each says who.
-- ============================================================

local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

-- v67: the legacy GetUnitAuras full-fetch wrapper and its GetUnitAuras_Raw
-- upvalue removed (12.1-only). The wrapper unconditionally returned nil, so
-- all five call sites (BigDef:GetIcons, FetchHarmfulInternal,
-- Debuffs:GetIcons x2, CrowdControl:GetIcons) produced no data and the
-- functions containing them were dead. The parallel scratch arrays
-- (_debuff*, _bigDef*, _cc*) they filled went with them, as did the
-- upvalues they orphaned: next, pairs, ipairs, rawget, canaccessvalue,
-- issecretvalue, InCombatLockdown, UnitIsVisible, GetAuraDuration and
-- GetAuraApplicationDisplayCount.

-- v67: the per-render-frame ticker (a CreateFrame OnUpdate that bumped
-- _currentFrame forever), PreProcessUnitAura, HasFrameForUnit and the
-- whole per-unit cache-invalidation layer removed. The ticker fed only the
-- GetIcons/reachability caches; both helpers were reachable only from
-- UNIT_AURA handlers that no longer register — or, for buffs, from code
-- below an unconditional early return.


-- ============================================================
-- STATUS: buffs
--
-- Grid2 equivalent: mbuffs in StatusAuras.lua.
-- Only surviving live work: the SingleAuraTracker scan.
-- ============================================================
local Buffs = BF.statusPrototype:new("buffs")


function Buffs:UNIT_AURA(_, unit)
    -- Single-aura tracker scan (missing-raid-buff redesign, see
    -- Docs/MISSING_RAID_BUFF_REDESIGN_PLAN.md).
    --
    -- The scan bails fast (#Trackers == 0, or personal-only tracker on a
    -- non-player unit) when nothing needs the data, so the cost when no
    -- missing-buff feature is active is sub-microsecond. With the
    -- toggle-gated registration in AuraCustomizations.lua
    -- EnsureMissingRaidBuffTracker, users with showMissingRaidBuff and
    -- showMissingSymbiotic both off everywhere have no trackers registered
    -- and pay only the #Trackers == 0 fast-bail per UNIT_AURA.
    --
    -- v67: everything that used to follow sat behind
    -- `if AuraContainerSortMethod ~= nil then return end` — the same
    -- permanently-true 12.1 feature detect as the purged BF._useAuraContainers
    -- — so the legacy tail (showBuffs gate, PreProcessUnitAura,
    -- HasFrameForUnit, UpdateIndicators) was unreachable and is deleted.
    -- The UNIT_AURA registration itself stays: this scan needs it.
    if BF.SAT_ScanAndDispatch then
        BF:SAT_ScanAndDispatch(unit)
    end
end

-- v67: Buffs:GetIcons removed — no caller remained anywhere in the addon
-- (the buff row is built by BF:FetchBuffData directly), and its
-- single-entry (unit, frame) guard depended on the deleted frame ticker.

-- v92 (owner ruling): the SingleAuraTracker features this scan feeds
-- (missing raid buff / missing symbiotic) are combat-INERT by design, so
-- the addon must not listen to UNIT_AURA in combat at all. The roster
-- registration exists only out of combat; the regen edges below flip it.
-- The regen-exit catch-up rescan is owned by SingleAuraTrackers.lua
-- (SAT_RegenCatchUp), which also handles its player-scoped subscription.
-- Register/Unregister are idempotent set-writes (Initialization.lua
-- BF.RegisterRosterUnitEvent), so the edges cannot double-register.
function Buffs:OnEnable()
    if not InCombatLockdown() then
        self:RegisterRosterUnitEvent("UNIT_AURA")
    end
    self:RegisterEvent("PLAYER_REGEN_DISABLED", "OnCombatEnter")
    self:RegisterEvent("PLAYER_REGEN_ENABLED",  "OnCombatExit")
end
function Buffs:OnCombatEnter()
    self:UnregisterRosterUnitEvent("UNIT_AURA")
end
function Buffs:OnCombatExit()
    self:RegisterRosterUnitEvent("UNIT_AURA")
end
function Buffs:OnDisable()
    self:UnregisterRosterUnitEvent("UNIT_AURA")
    self:UnregisterEvent("PLAYER_REGEN_DISABLED")
    self:UnregisterEvent("PLAYER_REGEN_ENABLED")
end
function Buffs:IsActive(unit) return unit ~= nil end

-- Retained: external callers remain (AuraCustomizations.lua
-- RefreshAllCustomContainersWithRebuild; Initialization.lua combat-transition
-- handlers). v67: now a no-op — the cache it invalidated died with
-- Buffs:GetIcons. Kept so those call sites need no coordinated change.
function Buffs:InvalidateGetIconsCache()
end

-- Note: Buffs has no ClearAllCaches / ClearCachesForUnit. The legacy
-- implementations cleared _symbioticIID; that state is now owned by
-- the SingleAuraTracker framework's BF_UnitLeft handler. Callers
-- (Initialization.lua GROUP_ROSTER_UPDATE, Offline.lua SetOffline)
-- have been updated to no longer reach into Buffs for cache clearing.
BF:RegisterStatus(Buffs)


-- ============================================================
-- STATUS: bigdef
--
-- v67: BigDef:UNIT_AURA, BigDef:GetIcons and BigDef:GetSeenIfCached removed.
-- The handler never registered (OnEnable was gated on the permanently-true
-- AuraContainerSortMethod detect), GetIcons was one of the dead
-- GetUnitAuras call sites, and GetSeenIfCached only served that cache.
-- AuraCustomizations.lua's dedup pass probes both by name
-- (`bdStatus.GetSeenIfCached and ...` / `if ... bdStatus.GetIcons then`)
-- so it degrades to "no dedup" — which is what it already did, since the
-- seen-set was always empty.
-- ============================================================
local BigDef = BF.statusPrototype:new("bigdef")

function BigDef:OnEnable()
    -- 12.1: big-defensive icons render via AuraContainer — no Lua scan.
end
function BigDef:OnDisable()
end
function BigDef:IsActive(unit) return unit ~= nil and BF.AuraCache.showBigDef == true end


BF:RegisterStatus(BigDef)


-- v64: the "important" STATUS was removed with the Important feature.
-- It existed solely to feed the Important icon indicator, which is gone
-- along with its options tab and settings keys. IMPORTANT-flagged buffs now
-- reach the regular buff row (the |!IMPORTANT negation was dropped from the
-- general buff filter in AuraCustomizations.lua), or a custom container via
-- the "Important" preset.


-- ============================================================
-- STATUS: debuffs
--
-- v67: all debuff DATA code removed — Debuffs:UNIT_AURA (never registered),
-- FetchHarmfulInternal, InjectFilteredDebuffs (+ _getSpellName/_injectState),
-- Debuffs:GetIcons, Debuffs:GetHarmful and Debuffs:GetDurationObject, plus
-- the two-pool cache state. GetIcons/FetchHarmfulInternal were dead
-- GetUnitAuras call sites; GetHarmful already returned a hard `0, {}`; and
-- GetDurationObject had no caller anywhere in the addon.
-- ============================================================
local Debuffs = BF.statusPrototype:new("debuffs")

function Debuffs:OnEnable()
    -- 12.1: DebuffIcons renders via container; the dispel border/overlay/dot
    -- are slot-visual containers. Nothing left for a Lua UNIT_AURA scan.
end
function Debuffs:OnDisable()
end
function Debuffs:IsActive(unit) return unit ~= nil end

-- Retained: external callers remain (Initialization.lua combat-transition
-- handlers, two sites). v67: now a no-op — the icons/harmful pool caches it
-- wiped died with Debuffs:GetIcons. Kept so those call sites need no
-- coordinated change.
function Debuffs:InvalidateGetIconsCache()
end


BF:RegisterStatus(Debuffs)


-- ============================================================
-- STATUS: dispel
--
-- Grid2 equivalent: mdebuffType / debuffs-DispellableByMe.
--
-- v67: Dispel:UNIT_AURA (never registered — OnEnable was gated on the
-- permanently-true AuraContainerSortMethod detect), Dispel:GetIconColors,
-- Dispel:GetFallbackIconColors, Dispel:SetLastDebuffAuras and
-- Dispel:GetLastDebuffAuras removed, along with the _dispelIconColor /
-- _dispelAllColor / _dispelAllDispellableColor / _dispelFallbackIconColors /
-- _lastDebuffAuras caches. The fallback color paths all sourced from
-- Debuffs:GetHarmful, which returned nothing; Set/GetLastDebuffAuras had no
-- caller left (DebuffIcons.lua only mentions them in a stale header comment).
-- ============================================================
local Dispel = BF.statusPrototype:new("dispel")

-- Per-unit dispellable-by-me color cache (Grid2 pattern: dispel_cache).
-- v67: no longer written — its producer was Dispel:UNIT_AURA. Kept because
-- IsActive/GetColor read it and ClearAllCaches/ClearCachesForUnit wipe it.
local _dispelColor = {}  -- unit -> secret color object (dispellable only)

-- GetColor is NOT deleted despite having no live consumer.
-- Auras/PrivateAuraDispelOverlay.lua:144 still calls
-- `dispelStatus:GetColor(unit, self._containerDispelMode)`; that call sits
-- behind `self._privateAurasOnly`, which the file sets to false
-- unconditionally, so it never runs today. But statusProto defines a default
-- `GetColor(unit) return 0, 0, 0, 1 end` — removing this override would make
-- that call inherit the prototype and evaluate `~= nil` as TRUE, silently
-- hiding the overlay if the flag ever flips. A one-line honest override is
-- cheaper than that trap.
-- v67: the "all" / "allDispellable" fallback branches removed — both walked
-- Debuffs:GetHarmful, which no longer returns auras.
function Dispel:GetColor(unit)
    return _dispelColor[unit]
end

function Dispel:IsActive(unit)
    return _dispelColor[unit] ~= nil
end

function Dispel:OnEnable()
    -- 12.1: all three dispel visuals (border/overlay/dot) are slot-visual
    -- containers — the eager per-UNIT_AURA dispel scan is gone.
end
function Dispel:OnDisable()
end

-- Retained: called externally by BFLayout.lua and Initialization.lua on
-- GROUP_ROSTER_UPDATE (and wrapped by Profiler.lua).
function Dispel:ClearAllCaches()
    table.wipe(_dispelColor)
end

-- Retained: called externally by Statuses/Offline.lua (two sites) when a
-- unit goes offline, so a stale secret color object can't survive into a
-- SetVertexColor call and render as a black overlay.
function Dispel:ClearCachesForUnit(unit)
    _dispelColor[unit] = nil
end

BF:RegisterStatus(Dispel)


-- ============================================================
-- STATUS: buffmatch
--
-- Per-spell indicator matching for custom aura indicators. Data-only
-- status: it never owned UNIT_AURA.
--
-- v67: BuffMatch:UpdateCache (its only producer — it had no caller left)
-- and the getters it fed (GetMatchedColor / GetMatchedBorder /
-- GetMatchedOverlay / GetOverlayAuraIID / GetColorAuraIID / HasRegularBuff)
-- removed together with the buffHighlight indicator that consumed them.
-- The status registration stays so BF.statuses.buffmatch resolves for
-- external cache-clearing callers.
-- ============================================================
local BuffMatch = BF.statusPrototype:new("buffmatch")

-- v67: only the three caches IsActive reads survive; _bmOverlayIID,
-- _bmColorIID, _bmHasRegBuff and the three change-guard tables were written
-- solely by the deleted UpdateCache. Nothing writes these any more either,
-- but IsActive and ClearAllCaches still reference them.
local _bmColor   = {}  -- unit -> matched color config table or nil
local _bmBorder  = {}  -- unit -> matched border config table or nil
local _bmOverlay = {}  -- unit -> matched overlay config table or nil

function BuffMatch:IsActive(unit)
    return _bmColor[unit] ~= nil or _bmBorder[unit] ~= nil or _bmOverlay[unit] ~= nil
end

-- No UNIT_AURA registration. OnEnable/OnDisable are the prototype no-ops;
-- the status is enabled/disabled solely by indicator binding (Grid2 pattern).

-- Retained: called externally by BFLayout.lua on GROUP_ROSTER_UPDATE.
function BuffMatch:ClearAllCaches()
    table.wipe(_bmColor)
    table.wipe(_bmBorder)
    table.wipe(_bmOverlay)
end

BF:RegisterStatus(BuffMatch)

-- v69: the "crowdcontrol" status removed with the dedicated Crowd Control
-- feature (now a seeded custom debuff container — crowdControl preset,
-- HARMFUL|CROWD_CONTROL). Its only binding was the crowdControlIcons
-- indicator in BFStatus.lua, deleted in the same pass.
