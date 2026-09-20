-- ============================================================
-- BuzzardFrames: ApplyProfile.lua (Grid2-style rewrite)
--
-- Simplified to use BFLayout.lua's LoadLayout/ReloadLayout.
-- Retains: ResolveContext, ComputeFrameSize, GetPopulatedGroups.
-- Removes: RebuildHeaders (replaced by BFLayout:LoadLayout).
-- ApplyProfile now delegates to ReloadLayout(true).
-- ============================================================
local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

local floor = math.floor

-- ============================================================
-- INPUT NORMALIZATION
-- ============================================================
-- This is the ONE place a capacity tier is validated against a closed
-- list: an unlisted value makes _ApplyProfileBody print and return without
-- applying anything. So every tier BF:GetCapacityTier can return must have
-- a key here -- raid25 (Midnight Mythic Flex) included, or RefreshAll would
-- silently do nothing in exactly those raids.
local GROUP_TYPE_MAP = {
    party   = "party",
    raid20  = "raid20",  raid_20 = "raid20",
    raid25  = "raid25",  raid_25 = "raid25",
    raid30  = "raid30",  raid_30 = "raid30",
    raid40  = "raid40",  raid_40 = "raid40",
}

local function NormalizeGroupType(input)
    if not input then return nil end
    return GROUP_TYPE_MAP[input:lower()]
end

-- ============================================================
-- CONTEXT SNAPSHOT (unchanged)
-- ============================================================
function BF:ResolveContext(groupTypeHint)
    local p = self.db.profile
    local _, instanceType = GetInstanceInfo()
    local inRaid  = IsInRaid()
    local inGroup = IsInGroup()

    local isParty
    if groupTypeHint then
        isParty = (groupTypeHint == "party")
    else
        if (instanceType == "arena" or instanceType == "party" or instanceType == "scenario")
                and not self:IsOversizedRaidInPartyInstance() then
            isParty = true
        else
            self:GetRaidProfile()
            if self.openWorldPartyOverride then
                isParty = true
            elseif inGroup and not inRaid then
                isParty = true
            else
                isParty = false
            end
        end
    end

    self._contextIsParty = isParty
    self._contextIsRaid  = not isParty
end

-- ============================================================
-- FRAME SIZE COMPUTATION (unchanged)
-- ============================================================
function BF:ComputeFrameSize()
    local lp      = self.rpDB.profile.layouts
    local useRaid = self._contextIsRaid
    -- Grid2 pattern: read from the profile resolved ONCE in ReloadLayout.
    -- Never re-call GetRaidProfile() here — its caching/side-effects can
    -- return a stale or wrong profile when the context just changed.
    local ap = self._resolvedProfile
    if not ap then
        -- Fallback if called before ReloadLayout stored the profile
        ap = useRaid and self:GetRaidProfile() or self:GetActivePartyProfile()
    end
    local baseW = ap.frameWidth  or (useRaid and 70 or 100)
    local baseH = ap.frameHeight or (useRaid and 40 or 68)
    local scaleIndicators, frameScale
    if ap.enableFrameScale then
        scaleIndicators = ap.scaleIndicators ~= false
        frameScale      = ap.frameScale or 1.0
    else
        scaleIndicators = true
        frameScale      = 1.0
    end
    if useRaid and lp.scaleRaidToFit then
        local spacingH = ap.frameSpacingH or 0
        baseW = self:GetFitFrameWidth(baseW, spacingH)
    end
    local w = scaleIndicators and baseW or (baseW * frameScale)
    local h = scaleIndicators and baseH or (baseH * frameScale)
    -- v93: route through PixelRound instead of inlining the old
    -- 1/effectiveScale rounding. This is a public size API (BF:GetFrameSize,
    -- and GetFramesSizeForHeader's main-header fallback); left as-is it would
    -- return coarse-grid dimensions that silently disagree with the
    -- header.frameWidth every other path now produces.
    return self:PixelRound(w), self:PixelRound(h)
end

-- ============================================================
-- GET POPULATED GROUPS (unchanged)
-- ============================================================
function BF:GetPopulatedGroups()
    local result = {}
    if not IsInRaid() then
        for i = 1, 8 do result[i] = true end
        return result
    end
    -- Iterate to MAX_RAID_MEMBERS (40), not GetNumGroupMembers().
    -- Raid indices can have holes — a member at index 30 won't be
    -- reached if we only iterate to the member count.
    local issecretvalue = issecretvalue or function() return false end
    for i = 1, MAX_RAID_MEMBERS do
        local name, _, subgroup = GetRaidRosterInfo(i)
        if name and subgroup and not issecretvalue(subgroup) then
            result[subgroup] = true
        end
    end
    -- Fallback: if GetRaidRosterInfo returned no usable data (all nil/secret),
    -- assume all groups with existing units are populated by checking UnitExists.
    if not next(result) then
        for i = 1, 8 do result[i] = true end
    end
    return result
end

-- ============================================================
-- BF:ApplyProfile(groupType)
-- Now a thin wrapper around the Grid2-style ReloadLayout.
-- Phase L: the layoutID parameter is gone with the pre-flat named-layout
-- system -- the resolved flat + context pair fully identifies the render.
--
-- Combat behavior: in combat, ApplyProfile routes the request through
-- GroupTypeChanged → RunSecure(2, _GroupTypeChangedExecute). The previous
-- behavior (silently `return` on `InCombatLockdown()`) dropped every
-- subsequent step including the rebuild itself, leaving the layout stale
-- until the next roster event. _GroupTypeChangedExecute is a SUPERSET of
-- ApplyProfile (it does setup-mode-exit, role/spec resolve, contextDisabled
-- branch, and calls ApplyProfile as one step at the end) so re-running the
-- whole cascade on combat exit is correct. The groupType arg
-- is not preserved across the deferral — _GroupTypeChangedExecute
-- re-resolves it from live game state via GetTrueActiveTab, which is what
-- we want anyway (an arg computed in combat is likely stale by the time
-- combat ends). See Docs/PEW_GRID2_REFACTOR_PLAN.md §3.7.
-- ============================================================
function BF:ApplyProfile(groupType)
    -- Step 1: Combat guard — route to the broadest cascade.
    if InCombatLockdown() then
        self:GroupTypeChanged()
        return
    end
    self:_ApplyProfileBody(groupType)
end

-- The actual ApplyProfile work. Split out so the combat guard above can
-- defer cleanly. Direct callers should always go through BF:ApplyProfile.
function BF:_ApplyProfileBody(groupType)
    self:LoadMark("apply:enter")
    -- Step 2: Normalize inputs
    local gt = NormalizeGroupType(groupType)
    if not gt then
        print("|cffd3ff7dBuzzardFrames:|r ApplyProfile: invalid groupType \"" .. tostring(groupType) .. "\"")
        return
    end

    -- Step 3: Snapshot context.
    --
    -- Setup mode is deliberately NOT exited here. ApplyProfile is called
    -- from many indirect paths (RefreshAll, PLAYER_ROLES_ASSIGNED deferred,
    -- Core_ProfileAutoSwitch, options setters) that rebuild the real frames
    -- underneath the test overlay without the user doing anything that
    -- warrants closing their setup session. Setup mode renders test frames
    -- from _modifyingFlat, which is independent of the real-frame context,
    -- so the real frames can safely rebuild beneath the test overlay.
    --
    -- The legitimate reasons to exit setup mode are handled elsewhere:
    --   * Zoning into an instance: DisableSetupModeIfInInstance
    --     (PLAYER_ENTERING_WORLD / ZONE_CHANGED_NEW_AREA)
    --   * Real-frame flat genuinely changes: _GroupTypeChangedExecute
    --     (only when ResolveActiveFlat picks a different flat)
    --   * Explicit user action: the Setup Mode button in options
    -- v98 (2026-08-27): snapshot the PRE-apply context + flat for
    -- ReloadLayout's gate. ResolveContext (next line) and SetResolvedProfile
    -- (below) both mutate the values ReloadLayout snapshots on entry, so on
    -- this path -- the party<->raid flip, the single most important
    -- transition -- the gate read contextFlipped=false flatChanged=false
    -- and only worked because force=true carried it. Any fast path keyed
    -- off those flags would have been silently wrong.
    self._reloadGateSnapshot = {
        contextIsRaid = self._contextIsRaid,
        flatID        = self._lastResolvedFlatID,
    }
    self:ResolveContext(gt)

    -- (Steps 3b/4 of the pre-flat named-layout system -- tier-table
    -- creation and active-layout tracking -- were removed in Phase L.
    -- Flats are the only layout storage; the resolved flat + context pair
    -- recorded in step 11 is the complete identity of this apply.)

    -- Step 5: Nuke caches and resolve profile ONCE (Grid2 pattern)
    self:InvalidateRaidProfileCache()
    if self.InvalidateActiveProfileCache then self:InvalidateActiveProfileCache() end
    if self.WipeLayoutSizeCache then self:WipeLayoutSizeCache() end
    if self.unitToFrameCache then table.wipe(self.unitToFrameCache) end
    -- §L5.1: RefreshProfileCache calls UpdateAuraSizeCache first -- this is
    -- aura-cache rebuild #3 of the login (§L1.0 row 27).
    self:LoadUASCTag("apply:refreshProfileCache")
    if self.RefreshProfileCache then self:RefreshProfileCache() end

    -- AuraCache must be populated before RefreshIndicatorSettings so any
    -- indicator UpdateSettings override that reads from BF.AuraCache sees
    -- fresh values. LoadLayout (called below via ReloadLayout) ALSO calls
    -- UpdateAuraSizeCache, but that runs AFTER RefreshIndicatorSettings —
    -- too late for AuraCache-dependent indicator settings. See
    -- Docs/PEW_GRID2_REFACTOR_PLAN.md §6.7.
    --
    -- v65 §6.3a: ApplyProfile has just re-resolved the context and the active
    -- Layout, and a Custom Frame Group whose aura override is OFF reads its
    -- aura values from whatever flat is active. InvalidateRaidProfileCache
    -- above cannot cover this -- it deliberately leaves _auraCache alone --
    -- so mark the affected CFG flats dirty HERE, before the rebuild below,
    -- not after it. The equivalent gate in ReloadLayout catches active-flat
    -- changes that arrive without a full ApplyProfile.
    if self.InvalidateCFGAuraCachesFollowingActiveLayout then
        self:InvalidateCFGAuraCachesFollowingActiveLayout()
    end
    -- §L5.1: rebuild #4, 19 lines after #3.
    self:LoadUASCTag("apply:direct")
    if self.UpdateAuraSizeCache then self:UpdateAuraSizeCache() end
    self:LoadMark("apply:auraCache")

    -- Grid2 parity (RefreshTheme → RefreshIndicators(true) → UpdateDB):
    -- re-read cached settings on all indicators so event handlers are
    -- registered/unregistered for the new profile context.
    if self.RefreshIndicatorSettings then self:RefreshIndicatorSettings() end
    self:LoadMarkD("apply:indicatorSettings")

    -- Grid2 pattern: resolve the active profile ONCE and store it.
    -- ReloadLayout (called in step 7) and all downstream functions read
    -- from self._resolvedProfile instead of re-calling GetRaidProfile().
    -- SetResolvedProfile atomically updates _resolvedProfile and the
    -- _lastResolvedFlatID cache key — see Core_ProfileAPI.lua.
    self:SetResolvedProfile(self._contextIsRaid)

    -- Step 6: Move anchor — via RestorePosition, so the coordinates and
    -- the layout-anchor point come from the SAME sources the rest of the
    -- addon uses (the resolved flat + the accessor). The old inline read
    -- used layout[gt] — the layout-TIER table, which can disagree with
    -- the flat and is even freshly created with DEFAULT corner coords by
    -- Step 3 when missing. Pinning a party Grow-from-Center box at those
    -- corner-era/default coords parked the frames far left on raid→party
    -- context flips (field report). _resolvedProfile is set in Step 5,
    -- so RestorePosition resolves correctly here.
    if self.anchorFrame then
        self:RestorePosition()
    end
    if self.testAnchorFrame then
        -- When setup mode is active the user may have dragged the test
        -- anchor to a new position that is saved on the modifying flat,
        -- not on the layout profile. Read from the flat so ApplyProfile
        -- (which can be triggered indirectly by options changes) doesn't
        -- snap the test frames back to the layout profile's stale position.
        local testSrc
        if BF.db.global.setupModeActive then
            testSrc = self:GetModifyingProfile()
        end
        if not testSrc then
            -- Same source unification as Step 6: the resolved flat, not
            -- the layout-tier table.
            testSrc = self:GetTrueActiveProfile()
        end
        local ax = (testSrc and testSrc.anchorX) or -200
        local ay = (testSrc and testSrc.anchorY) or 100
        local la = self:GetModifyingLayoutAnchor()
        self.testAnchorFrame:ClearAllPoints()
        self.testAnchorFrame:SetPoint(la, UIParent, "CENTER",
            self:SnapAnchor(ax), self:SnapAnchor(ay))
        if self.testAnchorFrame.SnapHandle then self.testAnchorFrame.SnapHandle() end
    end

    -- Step 7: CORE — delegate to Grid2-style LoadLayout
    -- ResolveLayoutName uses the BF profile's sorting/group settings
    -- to pick the correct Grid2-style layout name.
    self._forceReload = true
    self:ReloadLayout(true)
    self._forceReload = nil
    self._reloadGateSnapshot = nil  -- v98: consumed (or abandoned) above

    -- Step 8: Restore lock state
    if self.anchorFrame and self.anchorFrame.handle then
        local locked = self.db.global.locked
        if locked == nil then locked = true end
        if not locked then
            self.anchorFrame:EnableMouse(true)
            self.anchorFrame.handle:Show()
        else
            self.anchorFrame:EnableMouse(false)
            self.anchorFrame.handle:Hide()
        end
    end

    -- Step 9: Notify options panel
    BF:RefreshPanel("profile")

    -- Step 10: Refresh oUF unit frame absorbs for the new context.
    -- The raid↔party context flip changes which flat (raid or party)
    -- supplies the absorbs sub-table when the absorbs per-layout toggle
    -- is ON, so every oUF HealthPrediction element needs to re-resolve
    -- and repaint heal prediction, damage absorb, overshield, heal absorb,
    -- and reduced-max-health. Cheap: one ForceUpdate per oUF frame.
    if self._RefreshAllOUFAbsorbs then self:_RefreshAllOUFAbsorbs() end

    -- Step 10b: Same for the party/raid cast bars. A raid↔party context
    -- flip can move to a flat where castBar.enabled or the placement
    -- differs, which changes both the reserved row height and whether the
    -- castbar status should hold its UNIT_SPELLCAST_* registrations.
    if self.RefreshAllCastBars then self:RefreshAllCastBars() end

    -- Step 11: Record the applied state so _GroupTypeChangedExecute can
    -- detect no-op transitions on subsequent GROUP_ROSTER_UPDATEs. The
    -- resolved flat and context together determine everything ApplyProfile
    -- produces: the header layout name, frame dimensions, anchor position,
    -- and which oUF absorbs profile is read. If the next _groupType
    -- transition resolves to the same flat + same context, ApplyProfile
    -- would produce identical output, so _GroupTypeChangedExecute can
    -- skip it and call ReloadLayout() instead (whose internal gate will
    -- also no-op when the layout name is unchanged).
    local newAppliedFlat = self:ResolveActiveFlat(self:GetActiveSlot())

    -- Setup-mode live-follow re-sync. Setup entry snapshots _modifyingFlat to
    -- the then-active flat (SetupMode.lua:1254), and the drag live-follow is
    -- gated on ActiveMatchesModifying() — i.e. that snapshot still matching
    -- ResolveActiveFlat(). Resolution depends on LIVE state (role overrides,
    -- spec overrides, group-context slot), so a mid-setup role assignment,
    -- spec change, or party<->raid flip re-resolves to a different flat, the
    -- stale snapshot never matches again, and live-follow silently dies for
    -- the rest of the session (real frames stop tracking setup drags; they
    -- snap into place on exit, which rebuilds everything).
    --
    -- If the user was editing the LIVE layout (snapshot == previous applied
    -- flat), keep them on the live layout: re-snapshot to the new resolution
    -- and refresh the setup frames. If they explicitly chose to edit a
    -- non-active layout via the options dropdown, snapshot ~= applied flat
    -- and we leave their choice untouched — not following is correct there.
    if BF.db and BF.db.global and BF.db.global.setupModeActive
       and self._modifyingFlat
       and self._modifyingFlat == self._lastAppliedFlat
       and newAppliedFlat ~= self._modifyingFlat then
        self._modifyingFlat = newAppliedFlat
        if self.UpdateSetupFrames then self:UpdateSetupFrames() end
    end

    self._lastAppliedFlat = newAppliedFlat
    self._lastAppliedContextIsRaid = self._contextIsRaid
    self:LoadMark("apply:exit")
end
