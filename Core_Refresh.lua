-- ============================================================
-- BuzzardFrames: Core_Refresh.lua
-- Group labels and refresh orchestration.
--   • UpdateGroupLabels / BumpGroupLabelGeomKey — label frames above raid groups
--   • DebouncedRefreshAll / DebouncedApplyRoleSpecLayout — debounced entry points
--   • RefreshAll — central refresh entry point that delegates to ApplyProfile
--   • RefreshAllAuras / RefreshAllAbsorbs / InvalidateAbsorbTextureCaches /
--     RefreshAllHealAbsorbs — targeted refresh helpers
-- Extracted from Core.lua in the Core split refactor.
-- ============================================================
local BF = _G["BuzzardFrames"]

-- ============================================================
-- GROUP LABELS - One label frame per raid group (1-8), positioned
-- above the first unit frame of each group.  Non-secure frames so
-- they can be freely shown/hidden and repositioned at any time.
-- ============================================================
function BF:UpdateGroupLabels()
    -- Grid2 parity: out-of-band callers self-queue via RunSecure at the
    -- visibility tier (8). LoadLayout's tail already calls UpdateGroupLabels
    -- after every rebuild, so the deferred replay here is mostly a no-op
    -- for the rebuild path; it's the option-setter and slash-command paths
    -- that need this guard. See PEW_GRID2_REFACTOR_PLAN §6.8.
    if self:RunSecure(8, self, "UpdateGroupLabels") then return end

    local p = self.db.profile

    -- Text-section reads route via GetSectionProfile so the text per-layout
    -- toggle governs group-label visibility/font/color. When setup mode is
    -- active, use the modifying flat; otherwise use live raid context.
    -- Pre-v25 this read showGroupLabels, groupLabelFont, etc. directly off
    -- self.db.profile -- the wrong table (the UI writes to rpDB.profile.text).
    -- Fixed as part of the v25 text rollout.
    local setupActive    = BF.db.global.setupModeActive
    local modFlat        = setupActive and self:GetModifyingProfile() or nil
    local _textFlat      = setupActive and modFlat or self:GetRaidProfile()
    local tp             = self:GetSectionProfile("text", _textFlat) or {}

    -- Early exit before creating any frames if labels will never show.
    -- When setup mode is active, the modifying flat decides whether labels
    -- apply (raid flats yes, party flats no). Otherwise the live context decides.
    local activeGroupIsParty
    if setupActive then
        activeGroupIsParty = (modFlat and modFlat.type == "party")
    else
        activeGroupIsParty = self:ShouldUsePartyAnchor()
    end
    if not tp.showGroupLabels or activeGroupIsParty then
        -- Still hide any labels that may be showing from a previous context.
        if self._groupLabelFrames then
            for i = 1, 8 do self._groupLabelFrames[i]:Hide() end
        end
        -- Wipe cache so next show rebuilds it.
        self._groupLabelTopCache = nil
        return
    end

    -- Lazily create the 8 label frames on first call.
    if not self._groupLabelFrames then
        self._groupLabelFrames = {}
        for i = 1, 8 do
            local f = CreateFrame("Frame", "BuzzardFramesGroupLabel" .. i, UIParent)
            f:SetSize(1, 1)
            f:SetFrameStrata("MEDIUM")
            local fs = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            fs:SetText("Group " .. i)
            f.label = fs
            f:Hide()
            self._groupLabelFrames[i] = f
        end
    end

    local labels = self._groupLabelFrames

    -- Hide all labels first; we'll selectively show the ones that have a visible group.
    for i = 1, 8 do labels[i]:Hide() end

    -- Only show in GROUP sorting mode with strict group layout enabled.
    -- Sorting settings moved to rpDB.profile.sorting.*; route through
    -- GetSectionProfile so per-layout-sorting-toggle is respected.
    local _sortFlat = setupActive and modFlat or self:GetRaidProfile()
    local sp = self:GetSectionProfile("sorting", _sortFlat)
    if (sp and sp.sortingMode or "GROUP") ~= "GROUP" then return end
    if not (sp and sp.strictGroupLayout) then return end

    -- Grow direction determines where labels are placed relative to each
    -- group's frames:
    --   DOWN  → labels above the topmost frame   (find max top)
    --   UP    → labels below the bottommost frame (find min bottom)
    --   RIGHT → labels to the left of the leftmost frame  (find min left)
    --   LEFT  → labels to the right of the rightmost frame (find max right)
    local growDir = (sp and sp.raidGrowDirection) or "DOWN"
    local isHorizGrow = (growDir == "RIGHT" or growDir == "LEFT")

    -- Which edge to read and whether we want the min or max value.
    -- getVal(frame) returns the relevant coordinate; isBetter(new, old)
    -- returns true when `new` should replace `old` as the anchor frame.
    local getVal, isBetter
    if growDir == "DOWN" then
        getVal   = function(f) return f:GetTop() end
        isBetter = function(new, old) return new > old end
    elseif growDir == "UP" then
        getVal   = function(f) return f:GetBottom() end
        isBetter = function(new, old) return new < old end
    elseif growDir == "RIGHT" then
        getVal   = function(f) return f:GetLeft() end
        isBetter = function(new, old) return new < old end
    else -- LEFT
        getVal   = function(f) return f:GetRight() end
        isBetter = function(new, old) return new > old end
    end

    -- ── Find anchor frame per group ────────────────────────────────────────
    -- Walk visible frames and pick the one at the "origin edge" of each
    -- group — the edge closest to where the grow direction starts.
    -- This runs on every call (at most once per frame via C_Timer.After(0));
    -- walking ≤40 setup frames or a handful of live headers is negligible.
    -- ────────────────────────────────────────────────────────────────────────
    local anchorFrames = {}

    if setupActive and modFlat and modFlat.type == "raid" then
        local header = self.testHeader
        if header and header.frames then
            local activeCount = header.activeCount or #header.frames
            for i = 1, activeCount do
                local frame = header.frames[i]
                if frame and frame:IsVisible() then
                    local sg = math.ceil(i / 5)
                    local val = getVal(frame)
                    if val then
                        local existing = anchorFrames[sg]
                        if not existing or isBetter(val, existing[2]) then
                            anchorFrames[sg] = { frame, val }
                        end
                    end
                end
            end
        end
    else
        -- Live mode: walk groupsUsed (the BFLayout.lua engine).
        -- Each header with a numeric groupFilter owns one raid group.
        for _, header in ipairs(self.groupsUsed or {}) do
            if header:IsShown() then
                local gf = header:GetAttribute("groupFilter")
                local gi = gf and tonumber(gf)
                if gi then
                    local bestFrame, bestVal = nil, nil
                    local ci = 1
                    while true do
                        local frame = header:GetAttribute("child" .. ci)
                        if not frame then break end
                        if frame:IsVisible() and frame.unit then
                            local val = getVal(frame)
                            if val and (not bestVal or isBetter(val, bestVal)) then
                                bestFrame, bestVal = frame, val
                            end
                        end
                        ci = ci + 1
                    end
                    if bestFrame then anchorFrames[gi] = { bestFrame, bestVal } end
                end
            end
        end
    end

    -- Apply font/color only when they've changed since last call.
    local fontSize  = tp.groupLabelFontSize or 11
    local fontPath  = tp.adjustGroupLabelFont and BF:ResolveFontPath(tp.groupLabelFont) or BF.font
    local fontBorder = (tp.adjustGroupLabelFont and tp.groupLabelFontBorder) or ""
    local c        = tp.groupLabelColor or { r=1, g=1, b=1 }
    -- User offset: positive = further away from frames. 0 = flush with frame edge.
    local labelOffset = tp.groupLabelYOffset or 0
    local numberOnly = tp.groupLabelNumberOnly

    local prevSize  = self._labelFontSize
    local prevR     = self._labelColorR
    local styleChanged = (prevSize ~= fontSize or prevR ~= c.r
        or self._labelColorG ~= c.g or self._labelColorB ~= c.b
        or self._labelFontPath ~= fontPath or self._labelFontBorder ~= fontBorder
        or self._labelNumberOnly ~= numberOnly)

    if styleChanged then
        self._labelFontSize   = fontSize
        self._labelColorR     = c.r
        self._labelColorG     = c.g
        self._labelColorB     = c.b
        self._labelFontPath   = fontPath
        self._labelFontBorder = fontBorder
        self._labelNumberOnly = numberOnly
    end

    for g = 1, 8 do
        local entry = anchorFrames[g]
        if entry then
            local lf = labels[g]
            -- Apply style whenever styleChanged OR the label was previously hidden,
            -- so newly-visible labels always get the correct color (not GameFontNormalSmall default).
            if styleChanged or not lf:IsShown() then
                lf.label:SetFont(fontPath, fontSize, fontBorder)
                lf.label:SetTextColor(c.r, c.g, c.b)
                lf.label:SetText(numberOnly and tostring(g) or ("Group " .. g))
            end
            -- Parent frame is a 1x1 anchor point. The font string gets a
            -- single-point anchor that controls alignment — text auto-sizes
            -- and renders outside the parent bounds, so no frame resizing needed.
            lf:ClearAllPoints()
            lf.label:ClearAllPoints()
            if growDir == "DOWN" then
                lf:SetPoint("BOTTOM", entry[1], "TOP", 0, labelOffset)
                lf.label:SetPoint("BOTTOM", lf, "BOTTOM", 0, 0)
            elseif growDir == "UP" then
                lf:SetPoint("TOP", entry[1], "BOTTOM", 0, -labelOffset)
                lf.label:SetPoint("TOP", lf, "TOP", 0, 0)
            elseif growDir == "RIGHT" then
                lf:SetPoint("RIGHT", entry[1], "LEFT", -labelOffset, 0)
                lf.label:SetPoint("RIGHT", lf, "RIGHT", 0, 0)
            else -- LEFT
                lf:SetPoint("LEFT", entry[1], "RIGHT", labelOffset, 0)
                lf.label:SetPoint("LEFT", lf, "LEFT", 0, 0)
            end
            lf:Show()
        end
    end
end

-- Legacy stub — kept so existing callers don't error. The group label
-- cache was removed; UpdateGroupLabels now rebuilds anchor positions on
-- every call (walking ≤40 frames is negligible).
function BF:BumpGroupLabelGeomKey()
end

-- ============================================================
-- DEBOUNCED REFRESH - Collapses rapid back-to-back RefreshAll calls
-- (e.g. quickly clicking between raid-tier tabs) into a single
-- execution 50 ms after the last call, avoiding repeated
-- full frame rebuilds within one interaction.
-- ============================================================
function BF:DebouncedRefreshAll()
    if self._refreshTimer then
        self._refreshTimer:Cancel()
        self._refreshTimer = nil
    end
    self._refreshTimer = C_Timer.NewTimer(0.05, function()
        self._refreshTimer = nil
        self:RefreshAll()
    end)
end

-- Debounced ApplyRoleSpecLayout — collapses multiple rapid calls (e.g. from
-- GroupTypeChanged + the 1 s startup timer) into a single execution 100 ms
-- after the last call.  This prevents the expensive RefreshAll inside
-- ApplyRoleSpecLayout from firing several times during the startup window.
function BF:DebouncedApplyRoleSpecLayout(silent, noRefresh)
    if self._roleLayoutTimer then
        self._roleLayoutTimer:Cancel()
        self._roleLayoutTimer = nil
    end
    self._roleLayoutTimer = C_Timer.NewTimer(0.1, function()
        self._roleLayoutTimer = nil
        if self.ApplyRoleSpecLayout then self:ApplyRoleSpecLayout(silent, noRefresh) end
    end)
end

function BF:RefreshAll()
    if InCombatLockdown() then return end

    -- v72 (perf plan L1.6 D2): a `if self._startupGuard then return end` used to
    -- sit here, under a comment promising it suppressed "2-3 full per-frame
    -- sweeps on every reload" during the startup window. NOTHING in the tree
    -- ever SET the flag — the only other occurrence was a lone
    -- `self._startupGuard = nil` in Initialization.lua — so the branch was dead
    -- and the suppression it described did not exist. Both are deleted rather
    -- than left to mislead the next reader measuring this exact problem.
    --
    -- Deliberately NOT re-armed: the review showed that setting the flag loses
    -- the TERMINAL refresh on a combat login, because the startup timer that
    -- would clear it and re-issue RefreshAll is itself skipped by the
    -- InCombatLockdown guard above. Re-arming needs a paired terminal refresh
    -- and is separate, non-free work.

    local p = self.db.profile
    local setupActive = BF.db.global.setupModeActive

    -- While setup mode is editing a flat whose type differs from reality, only
    -- update the test frames and skip every operation that touches real secure
    -- frame geometry. Touching the real frames to match the edited flat would
    -- leave them wrong-sized on setup mode exit.
    -- Exception: when active matches modifying, the test and real frames represent
    -- the same on-screen frames, so we must update both.
    if setupActive and not self:ActiveMatchesModifying() then
        if self.UpdateSetupFrames then self:UpdateSetupFrames() end
        -- Group labels need a deferred call so test frames have finished positioning.
        C_Timer.After(0, function()
            if self.BumpGroupLabelGeomKey then self:BumpGroupLabelGeomKey() end
            if self.UpdateGroupLabels then self:UpdateGroupLabels() end
        end)
        return
    end

    -- Delegate all geometry work to ApplyProfile so it is the single authoritative
    -- path for context resolution, cache invalidation, header rebuild, and
    -- LayoutFrame sweeps.  This guarantees scaling and profile settings are always
    -- applied consistently regardless of what triggered RefreshAll.
    if self.ApplyProfile then
        local gt = self:GetTrueActiveTab()
        if gt == "none" then gt = "party" end
        self:ApplyProfile(gt)
        return
    end
end

-- NOTE: The real BF:RefreshAllAuras() is defined in Auras.lua (which loads after
-- this file).  This stub exists only so callers in Core.lua that run before
-- Auras.lua has loaded don't error.  It is overwritten at addon load time.
function BF:RefreshAllAuras()
    -- Auras.lua has not loaded yet; nothing to do.
end

function BF:RefreshAllAbsorbs()
    -- Rebind the absorb-related statuses first: if the user just flipped
    -- showAbsorbsMissingHealth or showOvershield, the `absorbs` status may
    -- need to enable/disable (and register/unregister UNIT_ABSORB_AMOUNT_CHANGED).
    -- Must run before the per-frame update sweep so stale widgets get the
    -- correct hidden state below.
    if self.RebindAbsorbStatuses then self:RebindAbsorbStatuses() end
    for frame in pairs(self.activeFrames) do
        if frame.unit then self:UpdateAbsorbOverlay(frame) end
    end
    -- Also refresh oUF unit frames (player/target/focus/boss etc.) so
    -- their absorb/overshield/heal-prediction/reduced-max widgets pick
    -- up the new settings.
    if self._RefreshAllOUFAbsorbs then self:_RefreshAllOUFAbsorbs() end
end

-- ============================================================
-- RefreshAllCastBars
--
-- Called by every castBar option setter. Order matters:
--
--  1. RebindCastBarStatus first, because flipping castBar.enabled decides
--     whether the castbar status registers its 13 UNIT_SPELLCAST_* events
--     at all. Doing it after the sweep would leave the events open (or
--     shut) for one round of frames.
--  2. Container:Layout, because the "row" placement reserves vertical
--     space and a placement/height change resizes the health area.
--  3. CastBar:Layout, which re-reads every style option. Update never
--     touches the profile, so without this pass nothing visual changes.
-- ============================================================
function BF:RefreshAllCastBars()
    if self.RebindCastBarStatus then self:RebindCastBarStatus() end

    local castInd = self:GetIndicatorByName("castBar")
    if not castInd then return end

    -- Deliberately does NOT re-Layout the container or invalidate the aura
    -- position cache.
    --
    -- Both were here from the design that had a "row" placement reserving
    -- vertical space, where the cast bar genuinely moved the health area
    -- and the aura anchors. That placement is gone -- the cast bar is a
    -- pure overlay in every position and reserves nothing -- so neither
    -- can be affected by a cast bar setting.
    --
    -- They were also by far the most expensive part of this function:
    -- InvalidateAuraPositionCache tail-calls UpdateStandardAuras, which
    -- runs six indicator Updates (including the un-change-guarded
    -- DispelDebuffBorder:Update) plus a fresh table allocation, PER FRAME.
    -- At 40 raid frames, times the two or three times a profile change
    -- routes through here, that was seconds of stall on a settings toggle.
    -- Grid2 rule: Layout reaches every registered frame (spares included);
    -- Update only the ones holding a unit.
    for _, frame in next, self.registeredFrames do
        if not frame._isPreviewFrame then
            castInd:Layout(frame)
            if frame.unit then castInd:Update(frame, frame.unit) end
        end
    end
end

-- Invalidate absorb texture style caches on all frames.
-- Call when overshieldStyle changes so the next update re-applies textures.
function BF:InvalidateAbsorbTextureCaches()
    for _, frame in next, self.registeredFrames do
        frame._absorbMissingHealthTexStyle = nil
        frame._absorbOvershieldTexStyle = nil
    end
end

-- ============================================================
-- RefreshAllHealAbsorbs
--
-- DESTRUCTIVE — only call from user-action setter callbacks for heal
-- absorb settings (style, bar height, color). Do NOT call from
-- post-build / post-layout contexts.
--
-- WHY DESTRUCTIVE: this function calls BF:LayoutFrame(frame) on every
-- active frame, which dispatches BF:LayoutFrameIndicators(frame), which
-- iterates EVERY enabled indicator including IconIndicator (private
-- auras). IconIndicator:Layout starts with ClearFrameAuraAnchors which
-- calls C_UnitAuras.RemovePrivateAuraAnchor on each registered handle
-- AND nils SF_PrivateAuraUnit on the wrapper. Any private aura anchor
-- that was registered by IconIndicator:Update (via OnAttributeChanged →
-- UpdateIndicators on the secure header's unit assignment) gets wiped.
--
-- The wipe is only re-registered on the NEXT unit-change event for
-- that frame (because IconIndicator:Update's gate is
-- `unit ~= f.SF_PrivateAuraUnit` — same unit no longer triggers
-- re-registration; ClearFrameAuraAnchors did nil it but the next
-- OnAttributeChanged with the same unit doesn't fire). Net result:
-- private auras silently disappear until the player gets a new unit
-- token on that frame.
--
-- HISTORY: this function was previously called from LoadLayout's
-- deferred tail (BFLayout.lua ~3453) as a "refresh everything after
-- layout" defensive measure, which caused private auras to never
-- appear after every /reload (both in and out of combat). Removed
-- from the tail in PEW Grid2-parity refactor. Setter callbacks for
-- heal-absorb settings are still safe call sites because in those
-- contexts the destructive re-layout is the INTENDED behavior (user
-- just changed bar height; geometry needs to be re-derived).
--
-- IF YOU NEED A POST-BUILD HEAL-ABSORB REFRESH, write a
-- non-LayoutFrame variant that only calls UpdateHealAbsorb +
-- _RefreshAllOUFAbsorbs.
-- ============================================================
function BF:RefreshAllHealAbsorbs()
    -- Rebind: showHealAbsorb may have just flipped.
    if self.RebindAbsorbStatuses then self:RebindAbsorbStatuses() end
    -- Targeted dispatch (Grid2 pattern): re-Layout the AbsorbBars
    -- indicator only, not the whole frame. The previous BF:LayoutFrame
    -- call ran HealthBar:Layout too, which resets the bg ColorTexture
    -- to alpha 0 ("initialize to a neutral value for the first frame"
    -- in HealthBar.lua) and waits for the next HealthBarColor tick to
    -- repaint -- producing a visible bg flash on every heal-absorb
    -- settings change.
    local absorbBars = self.GetIndicatorByName and self:GetIndicatorByName("absorbBars")
    -- Grid2 rule: Layout every registered frame, Update the unit-holding ones.
    for _, frame in next, self.registeredFrames do
        if not frame._isPreviewFrame then
            if absorbBars and not InCombatLockdown() then
                absorbBars:Layout(frame)
            end
            if frame.unit then self:UpdateHealAbsorb(frame) end
        end
    end
    -- Also refresh oUF unit frames so their heal-absorb widget updates.
    if self._RefreshAllOUFAbsorbs then self:_RefreshAllOUFAbsorbs() end
end

-- ============================================================
-- RefreshAllHealAbsorbsPostBuild
--
-- Non-destructive sibling of RefreshAllHealAbsorbs intended for the
-- LoadLayout deferred tail. Calls AbsorbBars:Layout DIRECTLY on each
-- frame (not via BF:LayoutFrame, which would dispatch every indicator's
-- Layout including IconIndicator and wipe private aura registrations).
-- Then runs the absorbBars Update to refresh values, rebinds absorb
-- statuses, and refreshes oUF absorbs.
--
-- This targeted dispatch ensures the absorbMissingHealth background,
-- healPrediction, healAbsorbBar, etc. get correctly positioned and
-- sized post-build (which BuzzardFrame_Init's frame:Layout did during
-- pre-allocation, but may have read stale section profile data before
-- _resolvedProfile was fully primed) without touching the PA indicator.
--
-- Use from build paths. Use RefreshAllHealAbsorbs (above) for
-- user-action setter callbacks where the destructive re-Layout (which
-- includes PA Layout) is the intended response to a setting change.
-- ============================================================
function BF:RefreshAllHealAbsorbsPostBuild()
    if self.RebindAbsorbStatuses then self:RebindAbsorbStatuses() end
    local absorbBars = self.GetIndicatorByName and self:GetIndicatorByName("absorbBars")
    -- Grid2 rule: Layout every registered frame, Update the unit-holding ones.
    for _, frame in next, self.registeredFrames do
        if not frame._isPreviewFrame then
            if absorbBars and not InCombatLockdown() then
                absorbBars:Layout(frame)
                if frame.unit then absorbBars:Update(frame, frame.unit) end
            elseif frame.unit then
                self:UpdateHealAbsorb(frame)
            end
        end
    end
    if self._RefreshAllOUFAbsorbs then self:_RefreshAllOUFAbsorbs() end
end

-- ============================================================
-- RefreshAllHealPrediction
-- Refreshes heal prediction on all raid/party frames (per-frame
-- UpdateHealPrediction with anchor-cache reset) AND on all oUF
-- unit frames (via _RefreshAllOUFAbsorbs).
--
-- Used by Options_Absorbs.lua heal-prediction setters:
--   showHealPrediction, healPredictionAnchor, healPredictionColor,
--   useCustomHealPredictionTexture, healPredictionTexture.
-- The anchor-cache reset (_healPredAnchor = nil) is necessary for
-- the healPredictionAnchor setter specifically, and a cheap no-op
-- for the other four (next UpdateHealPrediction re-caches).
-- ============================================================
function BF:RefreshAllHealPrediction()
    -- Rebind: showHealPrediction may have just flipped.
    if self.RebindAbsorbStatuses then self:RebindAbsorbStatuses() end
    for frame in pairs(self.activeFrames) do
        if frame.unit then
            frame._healPredAnchor = nil
            self:UpdateHealPrediction(frame)
        end
    end
    if self._RefreshAllOUFAbsorbs then self:_RefreshAllOUFAbsorbs() end
end

-- ============================================================
-- RefreshAllReducedMaxHealth
-- Refreshes the reduced-max-health bar on all raid/party frames (per-frame
-- UpdateAbsorbOverlay) AND on all oUF unit frames (via _RefreshAllOUFAbsorbs).
-- Also rebinds the reducedmaxhealth status so UNIT_MAX_HEALTH_MODIFIERS_CHANGED
-- is registered or unregistered when showReducedMaxHealth flips.
--
-- Used by Options_Absorbs.lua reduced-max setters (showReducedMaxHealth,
-- useCustomReducedMaxTexture, reducedMaxHealthTexture, reducedMaxHealthColor).
-- ============================================================
function BF:RefreshAllReducedMaxHealth()
    if self.RebindAbsorbStatuses then self:RebindAbsorbStatuses() end
    for frame in pairs(self.activeFrames) do
        if frame.unit then self:UpdateAbsorbOverlay(frame) end
    end
    if self._RefreshAllOUFAbsorbs then self:_RefreshAllOUFAbsorbs() end
end

