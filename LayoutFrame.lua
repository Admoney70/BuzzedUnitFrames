-- ============================================================
-- BuzzardFrames: LayoutFrame.lua
-- ============================================================
--
local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")
--
-- Shared helpers, caches, and RefreshAll* entry points used by
-- indicators, options panels, and event handlers.
--
-- All Update*() logic has been migrated to individual indicator
-- files in Indicators/. This file retains:
--   • ShouldShowPowerBar helper
--   • AbsorbCalc / HealthCalc calculator objects
--   • RefreshAll* functions (invalidate caches, re-run indicators)
--   • UpdateSwiftmendable (called from CustomAuras)
--   • ApplyStatusColorToName (offline name tinting)
-- ============================================================
--
-- Profile storage split (v28):
--   text keys        live in rpDB.profile.text        (per-layout aware, v25)
--   healthPower keys live in rpDB.profile.healthPower (per-layout aware, v28)
--   swiftmend keys   live in acDB.profile             (Aura Customizations DB)
-- None of these live in db.profile (the AceDB root) — that DB holds only the
-- UnitFrames / Incoming Casts / globals / legacy keys. Functions in this file
-- resolve each section via GetSectionProfile at call time (Grid2 pattern:
-- `local dbx = Grid2Frame.db.profile` in GridFrame.lua:145). The previous
-- module-local `p = self.db.profile` was fossil code from before the v15
-- namespace split and pointed at the wrong DB for every key accessed here.
-- ============================================================

hooksecurefunc(BF, "RefreshProfileCache", function(self)
    if self.ApplyCustomPowerColors then self:ApplyCustomPowerColors() end
    if self.ApplyCustomClassColors then self:ApplyCustomClassColors() end
end)

local pairs = pairs

local canaccessvalue = canaccessvalue or function() return true  end

local UnitExists             = UnitExists
local UnitClass              = UnitClass
-- v67: local UnitIsVisible removed — its only reader was
-- ClearBuffHighlightForNonVisibleUnits (deleted with buffHighlight).
local UnitGroupRolesAssigned = UnitGroupRolesAssigned
local IsInGroup              = IsInGroup

-- v93 (A1): the frame path now goes through GetCachedSection, which memoises
-- the resolved section on the CFG flat (CFG frames) or in BF._sectionProfileCache
-- (normal RP frames) instead of re-walking the resolution chain -- ResolveActiveIsRaid,
-- GetRaidProfile/GetActivePartyProfile, the per-Layout toggle test, GetSectionProfile --
-- on every call. BF:ShouldShowPowerBar below runs this per power tick per frame
-- (31052 calls / 410.7 s in the v93 profile, 186 ms in that row alone), and it was
-- the LAST healthPower reader still on the uncached path: BFStatus.lua:336,
-- Indicators/HealthBar.lua:307, Indicators/NameText.lua:351 and
-- StatusText_Overlay.lua:76 already use GetCachedSection for this same section.
--
-- Equivalence (re-derived after the v93 ResolveActiveIsRaid sweep):
--   * normal RP frame -- both now resolve isRaid via ResolveActiveIsRaid and call
--     GetSectionProfile with the same active flat. (Before the sweep GetCachedSection
--     still ran the old inlined isRaid expression and could pick the wrong flat; that
--     was the blocker for this change and it is gone.)
--   * CFG frame -- GetCachedSection delegates to GetSectionProfileForFrame and caches
--     the result, so identical by construction.
--   * PREVIEW frames DIVERGE: GetCachedSection has no _isPreviewFrame branch and would
--     answer for the live context. Safe here only because preview frames cannot reach
--     ShouldShowPowerBar -- they have no unit and no UpdateIndicators
--     (Preview/Options_PreviewSystem.lua), PowerBar:Update never runs on them, and
--     Container.lua's call is gated on parent.unit. Do NOT copy this swap to a reader
--     that preview frames DO reach.
--
-- Invalidation is already covered: WriteSectionKey calls _InvalidateSectionViews on
-- both branches (every healthPower key is subtab-mapped), which clears both the global
-- memo and every flat's copy; a context or flat change clears everything via
-- InvalidateRaidProfileCache.
--
-- Read-only: GetCachedSection's contract requires callers not to mutate the return.
-- ShouldShowPowerBar only reads.
local function getHealthPowerProfile(frame)
    if frame then return BF:GetCachedSection("healthPower", frame) end
    local isRaid = BF:ResolveActiveIsRaid()
    local activeFlat = isRaid and BF:GetRaidProfile() or BF:GetActivePartyProfile()
    return BF:GetSectionProfile("healthPower", activeFlat)
end

-- Most keys here are text-section (rpDB.profile.text). rangeFadeAlpha and
-- fadeOfflineFrames live in the healthPower section (rpDB.profile.healthPower)
-- because their UI widgets are rendered on the Health & Power tab. The two
-- sections are resolved independently since their per-layout toggles are
-- independent.
-- REFACTOR (plan 2.3/3.4): nameText color/alpha is owned by NameText's
-- color companion now; this is a thin delegate kept for the RefreshAll
-- funnels and the public BF:ApplyStatusColorToName export. The old inline
-- offline-color logic is reproduced (and extended with OOR handling)
-- inside NameText.lua ApplyNameColor. The statusText fade line that
-- lived here was redundant with StatusText_Overlay's own offline branch,
-- which sets the same alpha — dropped.
local function ApplyStatusColorToName(frame)
    local unit = frame.unit
    if not unit or not frame.nameText then return end
    local nameInd = BF.GetIndicatorByName and BF:GetIndicatorByName("nameText")
    if nameInd and nameInd.UpdateColor then
        nameInd:UpdateColor(frame, unit)
    end
end

function BF:ApplyStatusColorToName(frame)
    ApplyStatusColorToName(frame)
end

-- ============================================================
-- RAID-STYLE TWIN POWER BAR RULE
-- A twin stands in for its oUF frame on screen, so its power bar follows
-- that frame's own showPowerBar toggle (oUF semantics: on unless explicitly
-- false -- oUF_Shared.lua:5922 _ApplyOUFPowerElementState) and ignores the
-- flat's three power-bar filters, in both directions.
-- Returns true (forced on), false (forced off), or nil = not a twin / no
-- profile, in which case the caller applies the normal flat rules.
-- Read by ShouldShowPowerBar below and by Indicators/Container.lua's
-- height reservation, so the rule lives in exactly one place.
-- ============================================================
function BF:TwinForcesPowerBar(frame)
    if not (frame and frame._bf_twinKey) then return nil end
    local p  = self.ufDB and self.ufDB.profile
    local pf = p and frame._bf_twinUF and p[frame._bf_twinUF]
    if not pf then return nil end
    return pf.showPowerBar ~= false
end

-- ============================================================
-- POWER BAR HELPER
-- showAllPowerBars / showPowerBarHealers / showPowerBarBloodDK are
-- healthPower-section keys (rpDB.profile.healthPower).
-- ============================================================

function BF:ShouldShowPowerBar(unit, frame)
    local hp = getHealthPowerProfile(frame)
    if not hp then return false end

    -- Twins skip the three filters entirely: the oUF frame's showPowerBar is
    -- the only switch (BF:TwinForcesPowerBar above). Offline and UnitExists
    -- still apply -- an offline or absent unit shows no bar on any frame.
    local twinForced = BF:TwinForcesPowerBar(frame)
    if twinForced ~= nil then
        if not twinForced then return false end
        local offlineTwin = BF.statuses and BF.statuses.offline
        if offlineTwin and offlineTwin:IsActive(unit) then return false end
        if not (unit and UnitExists(unit)) then return false end
        return true
    end

    -- Derived from the 3 visibility toggles — no master toggle needed.
    if not hp.showAllPowerBars and not hp.showPowerBarHealers and not hp.showPowerBarBloodDK then return false end

    local offlineStatus = BF.statuses and BF.statuses.offline
    if offlineStatus and offlineStatus:IsActive(unit) then return false end
    if not UnitExists(unit) then return false end

    if hp.showAllPowerBars then return true end

    -- Filtered mode — unit must match one of the enabled filters
    if unit == "player" and not IsInGroup() then
        -- Classic: no specializations -- filtered mode cannot match, so bail.
        local spec = GetSpecialization and GetSpecialization()
        if not spec then return false end
        if hp.showPowerBarHealers and GetSpecializationRole and GetSpecializationRole(spec) == "HEALER" then return true end
        if hp.showPowerBarBloodDK then
            local _, className = UnitClass(unit)
            if className == "DEATHKNIGHT" and spec == 1 then return true end
        end
        return false
    end

    local role = UnitGroupRolesAssigned(unit)
    -- 12.1: role/class can be secret for identity-secret units — comparing a
    -- secret hard-errors. Unreadable ⇒ treat as no-match (bar stays hidden),
    -- same fallback CastBar's healers-only filter uses.
    if not canaccessvalue(role) then role = nil end
    if hp.showPowerBarHealers and role == "HEALER" then return true end
    if hp.showPowerBarBloodDK then
        local _, className = UnitClass(unit)
        if not canaccessvalue(className) then className = nil end
        if className == "DEATHKNIGHT" and role == "TANK" then return true end
    end
    return false
end

-- ============================================================
-- ABSORB CALCULATORS (used by AbsorbBars indicator)
-- ============================================================

BF.AbsorbCalc = CreateUnitHealPredictionCalculator()
BF.AbsorbCalc:SetDamageAbsorbClampMode(1)

BF.OvershieldCalc = CreateUnitHealPredictionCalculator()
BF.OvershieldCalc:SetDamageAbsorbClampMode(2)

BF.HealthCalc = CreateUnitHealPredictionCalculator()
BF.HealthCalc:SetDamageAbsorbClampMode(1)

-- ============================================================
-- TARGETED REFRESH FUNCTIONS (Grid2 pattern)
-- Options panels call these to update only the affected indicators.
-- ============================================================

function BF:RefreshAllHealthColors()
    local ind = self:GetIndicatorByName("healthBar")
    local colorInd = self:GetIndicatorByName("healthBarColor")
    local overlay = self:GetIndicatorByName("statusOverlay")
    for frame in pairs(self.activeFrames or {}) do
        if frame:IsShown() and frame.unit then
            frame.cachedHealthR = nil
            if ind then ind:Update(frame, frame.unit) end
            -- Perf 3B: color now lives in the sidekick indicator.
            if colorInd then colorInd:Update(frame, frame.unit) end
            if overlay then overlay:Update(frame, frame.unit) end
        end
    end
end

function BF:RefreshAllStatusColors()
    -- Composed name entries bake append/showAFK/applyStatusColors flags
    -- (BFStatus.lua BuildComposedName); the setters for those options funnel
    -- HERE, not through RefreshAllNames, so the cache must be dropped here
    -- too or the toggles paint with stale entries (refactor review M1 —
    -- e.g. append toggled off left a stale composed "Name (Dead)" on the
    -- name while statusText also showed "Dead").
    if self.InvalidateComposedNameText then self:InvalidateComposedNameText() end
    local overlay = self:GetIndicatorByName("statusOverlay")
    local nameInd = self:GetIndicatorByName("nameText")
    for frame in pairs(self.activeFrames or {}) do
        if frame:IsShown() and frame.unit then
            if overlay then overlay:Update(frame, frame.unit) end
            if nameInd then nameInd:Update(frame, frame.unit) end
            ApplyStatusColorToName(frame)
        end
    end
end

function BF:RefreshAllNames()
    -- Drop memoized composed-name entries first: section tables are mutated
    -- in place by the options UI, so a text-option change must rebuild the
    -- closures (plan Phase 5.1; every text setter funnels through here).
    if self.InvalidateComposedNameText then self:InvalidateComposedNameText() end
    local nameInd = self:GetIndicatorByName("nameText")
    local overlay = self:GetIndicatorByName("statusOverlay")
    for frame in pairs(self.activeFrames or {}) do
        if frame:IsShown() and frame.unit then
            -- Re-run StatusOverlay first: in append mode it owns the name
            -- text for dead/offline/AFK frames, so abbreviation changes
            -- must be picked up by re-rendering the status text.
            if overlay then overlay:Update(frame, frame.unit) end
            if nameInd then nameInd:Update(frame, frame.unit) end
            ApplyStatusColorToName(frame)
        end
    end
end

-- ============================================================
-- LIGHTWEIGHT REFRESH HELPERS (Phase 3 refactor)
--
-- Options setters for color-only changes (healthBarOpacity, custom
-- health/hostile/dead/offline colors, gradient colors) previously
-- called LayoutFrame or RefreshAll, which rebuilds all indicator
-- geometry. Color changes only need the color indicator to re-run
-- its :Update — no Create, no Layout, no geometry.
--
-- RefreshColors: sweeps all visible frames and re-runs only the
-- health-bar color sidekick + power bar color updates. ~10x cheaper
-- than LayoutFrame per frame.
--
-- RefreshHealthBarLayout: sweeps all visible frames and re-runs
-- only the healthBar + healthBarColor indicator Layout + Update.
-- Used for texture changes which need SetStatusBarTexture (Layout)
-- plus a color re-eval (Update).
-- ============================================================

function BF:RefreshColors()
    local colorInd = self:GetIndicatorByName("healthBarColor")
    local overlay  = self:GetIndicatorByName("statusOverlay")
    for frame in pairs(self.activeFrames or {}) do
        if frame:IsShown() and frame.unit then
            if colorInd then colorInd:Update(frame, frame.unit) end
            if overlay  then overlay:Update(frame, frame.unit) end
        end
    end
end

function BF:RefreshHealthBarLayout()
    local barInd   = self:GetIndicatorByName("healthBar")
    local colorInd = self:GetIndicatorByName("healthBarColor")
    -- Grid2 rule: Layout every registered frame, Update the unit-holding ones.
    for _, frame in next, self.registeredFrames or {} do
        if not frame._isPreviewFrame then
            if barInd then barInd:Layout(frame) end
            if frame.unit then
                if barInd   then barInd:Update(frame, frame.unit) end
                if colorInd then colorInd:Update(frame, frame.unit) end
            end
        end
    end
    -- The per-spell health tints are stamped with the bar's texture FILE,
    -- so a new texture leaves them holding the old one until they are
    -- re-stamped -- see BF:RestampFrameFx (Indicators/BuffsAndContainers.lua).
    if self.RestampFrameFx then self:RestampFrameFx() end
end

function BF:RefreshPowerBarLayout()
    local barInd = self:GetIndicatorByName("powerBar")
    -- Grid2 rule: Layout every registered frame, Update the unit-holding ones.
    for _, frame in next, self.registeredFrames or {} do
        if barInd and not frame._isPreviewFrame then
            barInd:Layout(frame)
            if frame.unit then barInd:Update(frame, frame.unit) end
        end
    end
end

-- ============================================================
-- LEGACY ADAPTER FUNCTIONS
-- Map old per-frame BF:UpdateX(frame) calls from Options panels
-- to the new indicator:Update(frame, unit) pattern.
-- Grid2 equivalent: each status/indicator has UpdateAllFrames().
-- ============================================================

function BF:UpdateHealth(frame)
    if not frame or not frame.unit then return end
    local ind = self:GetIndicatorByName("healthBar")
    if ind then ind:Update(frame, frame.unit) end
    -- Perf 3B: color sidekick. Without this, options setters that call
    -- self:UpdateHealth(f) would update bar value but leave the color
    -- stale (since UNIT_HEALTH no longer drives color when gradients are off).
    local colorInd = self:GetIndicatorByName("healthBarColor")
    if colorInd then colorInd:Update(frame, frame.unit) end
    local htInd = self:GetIndicatorByName("healthText")
    if htInd then htInd:Update(frame, frame.unit) end
    local overlay = self:GetIndicatorByName("statusOverlay")
    if overlay then overlay:Update(frame, frame.unit) end
end

function BF:UpdatePower(frame)
    if not frame or not frame.unit then return end
    -- Options setters funnel here (e.g. the custom power-color refresh in
    -- Options_Colors.refreshPowerColors). PowerBar:Update guards its color
    -- write on _powerColorType, which does NOT change when only the color
    -- VALUE for an existing type is edited -- so clear the key here to force
    -- a repaint, mirroring _RefreshAllOUFPowerColors invalidating
    -- _bf_powerCType on the oUF side.
    frame._powerColorType = nil
    local ind = self:GetIndicatorByName("powerBar")
    if ind then ind:Update(frame, frame.unit) end
end

function BF:UpdateName(frame)
    if not frame or not frame.unit then return end
    local ind = self:GetIndicatorByName("nameText")
    if ind then ind:Update(frame, frame.unit) end
end

function BF:UpdateRange(frame)
    if not frame or not frame.unit then return end
    local ind = self:GetIndicatorByName("rangeAlpha")
    if ind then ind:Update(frame, frame.unit) end
end

function BF:UpdateOffline(frame)
    if not frame or not frame.unit then return end
    local overlay = self:GetIndicatorByName("statusOverlay")
    if overlay then overlay:Update(frame, frame.unit) end
    local nameInd = self:GetIndicatorByName("nameText")
    if nameInd then nameInd:Update(frame, frame.unit) end
    local healthInd = self:GetIndicatorByName("healthBar")
    if healthInd then healthInd:Update(frame, frame.unit) end
    -- Perf 3B: also update color so offline↔online transitions restore
    -- the correct bar color (not just value).
    local colorInd = self:GetIndicatorByName("healthBarColor")
    if colorInd then colorInd:Update(frame, frame.unit) end
end

function BF:UpdateThreat(frame)
    if not frame or not frame.unit then return end
    local ind = self:GetIndicatorByName("aggroHighlight")
    if ind then ind:Update(frame, frame.unit) end
end

function BF:UpdateTarget(frame)
    if not frame or not frame.unit then return end
    local ind = self:GetIndicatorByName("targetHighlight")
    if ind then ind:Update(frame, frame.unit) end
end

function BF:UpdateRoleIcon(frame)
    if not frame or not frame.unit then return end
    local ind = self:GetIndicatorByName("roleIcon")
    if ind then ind:Update(frame, frame.unit) end
end

function BF:UpdateRaidTargetIcon(frame)
    if not frame or not frame.unit then return end
    local ind = self:GetIndicatorByName("raidTargetIcon")
    if ind then ind:Update(frame, frame.unit) end
end

function BF:UpdateLeaderIcon(frame)
    if not frame or not frame.unit then return end
    local ind = self:GetIndicatorByName("leaderIcon")
    if ind then ind:Update(frame, frame.unit) end
end

function BF:UpdateReadyCheck(frame)
    if not frame then return end
    local ind = self:GetIndicatorByName("statusIcons")
    if ind then ind:Update(frame, frame.unit) end
end

function BF:UpdatePhased(frame)
    if not frame then return end
    local ind = self:GetIndicatorByName("statusIcons")
    if ind then ind:Update(frame, frame.unit) end
end

function BF:UpdateSummonPending(frame)
    if not frame then return end
    local ind = self:GetIndicatorByName("statusIcons")
    if ind then ind:Update(frame, frame.unit) end
end

function BF:UpdateResurrectPending(frame)
    if not frame then return end
    local ind = self:GetIndicatorByName("statusIcons")
    if ind then ind:Update(frame, frame.unit) end
end

function BF:UpdateVehicle(frame)
    if not frame then return end
    local ind = self:GetIndicatorByName("statusIcons")
    if ind then ind:Update(frame, frame.unit) end
end

function BF:UpdateDebuffHighlight(frame)
    if not frame or not frame.unit then return end
    local ind = self:GetIndicatorByName("dispelDebuffBorder")
    if ind then ind:Update(frame, frame.unit) end
end

-- v67: BF:UpdateBuffHighlight removed (12.1-only). It dispatched the
-- buffHighlight indicator, which no longer exists — its BuffMatch getters
-- (GetMatchedColor / GetMatchedBorder / GetMatchedOverlay) were deleted
-- from Statuses/Auras.lua. It had no live callers.

-- The three absorb shims below are the option-setter entrances into
-- AbsorbBars:Update (Core_Refresh loops call them per frame). Bumping the
-- style generation here makes the next Update re-run _ApplyAbsorbStyle —
-- required because the in-combat setter path skips the destructive Layout.
-- Hot per-event paths (UNIT_MAXHEALTH sweeps, death/offline transitions,
-- UpdateFrameIndicators) call the indicator directly and therefore skip
-- the settings pass via the unchanged generation.
function BF:UpdateAbsorbOverlay(frame)
    if not frame then return end
    self._absorbStyleGen = (self._absorbStyleGen or 1) + 1
    local ind = self:GetIndicatorByName("absorbBars")
    if ind then ind:Update(frame, frame.unit) end
end

function BF:UpdateHealPrediction(frame)
    if not frame then return end
    self._absorbStyleGen = (self._absorbStyleGen or 1) + 1
    local ind = self:GetIndicatorByName("absorbBars")
    if ind then ind:Update(frame, frame.unit) end
end

function BF:UpdateHealAbsorb(frame)
    if not frame then return end
    self._absorbStyleGen = (self._absorbStyleGen or 1) + 1
    local ind = self:GetIndicatorByName("absorbBars")
    if ind then ind:Update(frame, frame.unit) end
end

function BF:UpdateFrame(frame)
    if not frame or not frame.unit then return end
    frame:UpdateIndicators()
end

-- LayoutFrame adapter: re-layouts ALL indicators on the frame.
-- Grid2 equivalent: indicator:LayoutAllFrames()
--
-- WARNING: this dispatches `:Layout` on every enabled indicator, which
-- includes IconIndicator (private auras). IconIndicator:Layout calls
-- ClearFrameAuraAnchors which RemovePrivateAuraAnchor's every handle
-- currently registered on the frame's wrapper and nils
-- SF_PrivateAuraUnit. Re-registration only happens on the next
-- unit-change event (OnAttributeChanged → UpdateIndicators →
-- IconIndicator:Update gate: `unit ~= f.SF_PrivateAuraUnit`).
--
-- If you call LayoutFrame after a unit is already assigned and stable
-- (e.g. mid-combat refresh, post-build settle), private auras will
-- silently disappear until the unit token changes on that frame.
--
-- Only call from contexts where re-running Layout on every indicator
-- is the intended behavior — typically user-action setter callbacks
-- that changed a geometry-affecting setting (frame width/height,
-- border thickness, heal absorb bar height, etc.).
--
-- See RefreshAllHealAbsorbs (Core_Refresh.lua) for a worked example.
function BF:LayoutFrame(frame)
    if not frame then return end
    self:LayoutFrameIndicators(frame)
end

-- v67: BF:ClearBuffHighlightForNonVisibleUnits removed (12.1-only). Every
-- state flag it tested was written only by the deleted buffHighlight
-- indicator (_buffBorderActive / _buffOverlayActive) or is never set at all
-- (SF_SpecColorActive — BFLayout.lua:484 only ever clears it), so the loop
-- body could not run. Its sole caller was the ZONE_CHANGED_NEW_AREA timer
-- in Initialization.lua, also removed.

