-- ============================================================
-- BuzzardFrames: BFLayout.lua
-- Grid2-style modular layout engine.
--
-- REPLACES: Layout.lua (header creation, management, ordering)
--           ApplyProfile.lua RebuildHeaders()
--
-- KEEPS:    PixelPerfect.lua (pixel math, InitFrame, LayoutFrame) — unchanged
--           LayoutFrame.lua  (shared helpers, caches, RefreshAll*) — no update logic
--
-- Architecture (mirrors GridLayout.lua):
--   BF.layoutSettings[name]  = registered layout definition table
--   BF:AddLayout(name, tbl)  registers a layout
--   BF:ReloadLayout(force)   picks layout name from profile, calls LoadLayout
--   BF:LoadLayout(name)      ResetHeaders → iterate layout → AddHeader → PlaceHeaders
--   BF:AddHeader(dbx, defaults, idx) creates/reuses a pooled header
--   BF:GenerateHeaders(defaults, idx) auto per-group headers from instance size
--   BF:PlaceHeaders()        RestorePosition → SetOrientation → anchor chain → Show
-- ============================================================

local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")
local SecureButton_GetModifiedUnit = SecureButton_GetModifiedUnit

local floor = math.floor
local pairs, ipairs, next, wipe = pairs, ipairs, next, wipe
local InCombatLockdown = InCombatLockdown
local IsInRaid, IsInGroup, GetNumGroupMembers = IsInRaid, IsInGroup, GetNumGroupMembers
local GetInstanceInfo, UnitExists = GetInstanceInfo, UnitExists

-- Epsilon used by UpdateFramesSizeForHeader to compare the resolved
-- header scale against header:GetScale() without falsely flagging
-- floating-point precision drift as a real change.
local SCALE_EPSILON = 0.0001

-- The most units any grid can ever show: a full 40-man raid. It is a
-- FRAME COUNT ceiling, not a display one -- ForceFramesCreation builds
-- maxColumns x unitsPerColumn frames in one pass, eagerly, so a grid
-- configured at 40 x 5 built 200 complete unit frames (auras, indicators,
-- containers and all) and froze the game. Nothing above 40 can ever be
-- filled, so nothing above 40 is ever built.
local GRID_MAX_UNITS = 40

-- How many columns (or rows, growing horizontally) it takes to show
-- `units` at `upc` per column -- the ceiling every grid's maxColumns is
-- held to. Rounds UP, so the last column may be partial: at upc 7 the
-- answer is 6, which shows 42 slots for 40 units. `units` defaults to a
-- full raid; the raid path passes the instance's own size, which is
-- smaller in a 5- or 20-man.
--
-- The one piece of this arithmetic in the addon: the CFG dims, the pet
-- dims and the "auto" resolve below all ask here, and the option setters
-- clamp writes with it.
function BF:GetGridMaxColumns(upc, units)
    upc = tonumber(upc) or 5
    if upc < 1 then upc = 1 end
    return math.max(1, math.ceil((units or GRID_MAX_UNITS) / upc))
end

-- ============================================================
-- Pre-compute custom frame aura offsets at layout time (N3).
-- Called after cfAuraProfile is assigned. Stores _buffOffCache
-- and _debuffOffCache on cfAP so the render path reads them
-- unconditionally (zero computation in Update).
-- ============================================================
local function PrecomputeCfAuraOffsets(cfAP)
    if not cfAP then return end
    local CalcAuraOffsets = BF.CalcAuraOffsets
    if not CalcAuraOffsets then return end

    -- Buff offsets
    local bSize    = cfAP.buffSize     or 12
    local bSpacing = cfAP.buffSpacing  or 1
    local bRowSp   = cfAP.buffRowSpacing or 1
    local bPerRow  = cfAP.buffsPerRow  or 3
    local bGrow    = cfAP.buffGrowDirection or "LEFT"
    local bAnchor  = cfAP.buffAnchorPoint   or "BOTTOMRIGHT"
    cfAP._buffOffCache = CalcAuraOffsets(bSize, bSpacing, bRowSp, bPerRow, bGrow, bAnchor)
    cfAP._bOffSize    = bSize
    cfAP._bOffSpacing = bSpacing
    cfAP._bOffRowSp   = bRowSp
    cfAP._bOffPerRow  = bPerRow
    cfAP._bOffGrow    = bGrow
    cfAP._bOffAnchor  = bAnchor

    -- Debuff offsets
    local dSize    = cfAP.debuffSize    or 12
    local dSpacing = cfAP.debuffSpacing or 1
    local dRowSp   = cfAP.debuffRowSpacing or 1
    local dPerRow  = cfAP.debuffsPerRow or 3
    local dGrow    = cfAP.debuffGrowDirection or "RIGHT"
    local dAnchor  = cfAP.debuffAnchorPoint   or "BOTTOMLEFT"
    cfAP._debuffOffCache = CalcAuraOffsets(dSize, dSpacing, dRowSp, dPerRow, dGrow, dAnchor)
    cfAP._dOffSize    = dSize
    cfAP._dOffSpacing = dSpacing
    cfAP._dOffRowSp   = dRowSp
    cfAP._dOffPerRow  = dPerRow
    cfAP._dOffGrow    = dGrow
    cfAP._dOffAnchor  = dAnchor
end

-- ============================================================
-- Build a flat aura-profile view for indicator code compatibility.
-- Old structure: grp.buffSize, grp.debuffSize, etc. (flat on group root)
-- New structure: grp.flat.auras.buffs.buffSize, grp.flat.auras.debuffs.debuffSize
-- This view uses __index to resolve old flat key names to the new nested
-- locations, so BuffIcons.lua / DebuffIcons.lua need no modification.
-- Runtime cache keys (_buffOffCache, etc.) are stored as rawkeys on the view.
--
-- v60: the sub-category tables are resolved ONCE here, via
-- ResolveCFGAurasSubcat, instead of the __index closing over flat.auras and
-- indexing it per key read. Two reasons:
--   • Correctness. The Buffs and Debuffs per-layout toggles are now
--     independent, so flat.auras can hold rawkeys for a group whose toggle
--     is OFF; indexing flat.auras directly would read them. (It also
--     ignored the CFG overrideAuras flag entirely.)
--   • Cost. The view table stays empty apart from its rawkeys, so EVERY
--     key read misses and runs __index — resolving per read would put a
--     routing call on a path the indicator layout code hits per frame.
--     Resolved-once keeps read cost at one table lookup, as before.
-- Snapshotting at build time is consistent with the previous behavior
-- (which snapshotted the flat.auras table identity) and with the view's
-- lifecycle: both call sites rebuild it during header setup, and
-- SetSectionPerLayout ends in RefreshAll, which re-runs header setup.
-- ============================================================
local function BuildCfAuraProfileView(flat, grp)
    if not flat or not flat.auras then return nil end
    local SUBCAT_OF = BF.AURAS_SUBCATEGORY_OF
    if not SUBCAT_OF then return nil end
    local subs = {}
    for _, subcat in ipairs(BF.AURAS_SUBCATEGORIES or {}) do
        subs[subcat] = BF.ResolveCFGAurasSubcat(BF, flat, grp, subcat)
    end
    return setmetatable({}, {
        __index = function(_, key)
            local subcat = SUBCAT_OF[key]
            if subcat then
                local sub = subs[subcat]
                if sub then return sub[key] end
            end
        end
    })
end

-- ============================================================
-- 1. FRAME TRACKING (Grid2 GridFrame.lua — verbatim)
-- ============================================================
-- Forward declarations (defined in sections below)
local OnUnitChanged
local BuzzardFrame_GetInitialSize

local frames_of_unit = setmetatable({}, { __index = function (self, key)
	local result = {}
	self[key] = result
	return result
end})
local activatedFrames = {}  -- only frames assigned to an unit: activatedFrames[frame] = unit
local registeredFrames = {} -- all frames created used and unused: registeredFrames[frameName] = frame

-- Grid2: SetFrameUnit — verbatim from GridFrame.lua
local function SetFrameUnit(frame, unit)
	local prev_unit = activatedFrames[frame]
	if prev_unit then
		local frames = frames_of_unit[prev_unit]
		frames[frame] = nil
		if not next(frames) then
			frames_of_unit[prev_unit] = nil
			BF:UnregisterRosterUnit(prev_unit)
		end
	end
	if unit then
		local frames = frames_of_unit[unit]
		if not next(frames) then
			BF:RegisterRosterUnit(unit)
		end
		frames[frame] = true
	end
	activatedFrames[frame] = unit
	frame.unit = unit
end

-- Grid2: GetUnitFrames — verbatim
function BF:GetUnitFrames(unit)
	return frames_of_unit[unit]
end

-- Grid2: UpdateFramesOfUnit — verbatim pattern.
-- If the underlying unit changed (e.g. roster shuffle), run the full
-- unit-change lifecycle. Otherwise just refresh indicators.
function BF:UpdateFramesOfUnit(unit, unitChanged)
	for frame in next, frames_of_unit[unit] do
		local old, new = frame.unit, SecureButton_GetModifiedUnit(frame)
		if old ~= new then
			SetFrameUnit(frame, new)
			OnUnitChanged(frame, new)
		else
			frame:UpdateIndicators(unitChanged)
		end
	end
end

-- Grid2: RefreshFramesOfUnit — verbatim
function BF:RefreshFramesOfUnit(unit)
	BF:RegisterRosterUnit(unit)
	for frame in next, frames_of_unit[unit] do
		frame:UpdateIndicators()
	end
end

-- Expose for Initialization.lua and other files
BF.frames_of_unit   = frames_of_unit
BF.activatedFrames  = activatedFrames
BF.registeredFrames = registeredFrames
BF.SetFrameUnit     = SetFrameUnit

-- Backward compatibility: BF.activeFrames is used throughout the codebase
-- (Core.lua, LayoutFrame.lua, Range.lua, Auras.lua, etc.) as:
--   for frame in pairs(self.activeFrames) do ... end
-- Grid2's activatedFrames maps frame→unit which yields identical frame keys
-- under pairs(). Alias directly so all existing callers keep working.
BF.activeFrames = activatedFrames

-- ============================================================
-- 2. FRAME SCRIPT HANDLERS (Grid2 GridFrameEvents — verbatim)
-- ============================================================
local BuzzardFrameEvents = {}

function BuzzardFrameEvents:OnShow()
	BF:SendMessage("BF_UpdateLayoutSize")
end

function BuzzardFrameEvents:OnHide()
	BF:SendMessage("BF_UpdateLayoutSize")
end

function BuzzardFrameEvents:OnAttributeChanged(name, value)
	if name == "unit" then
		local old_unit = self.unit
		if value then
			local unit = SecureButton_GetModifiedUnit(self)
			if old_unit ~= unit then
				SetFrameUnit(self, unit)
				OnUnitChanged(self, unit)
			end
		elseif old_unit then
			SetFrameUnit(self, nil)
			-- Grid2 GridFrame.lua:89-91: a frame that lost its unit parks
			-- its aura containers (disable, hide, SetUnit('none')). Without
			-- this they stayed bound and enabled on the departed token.
			self:UpdateAuraContainers()
		end
	end
end

-- Grid2: SetEventHook — verbatim
-- OnEnter/OnLeave are NOT registered in BuzzardFrameEvents (unlike Grid2)
-- because doing so adds an extra HookScript layer that interferes with
-- third-party tooltip addons' repositioning. The tooltip indicator uses HookScript
-- directly (matching the old working v3.1.4 approach).
local eventHooks = { OnEnter = {}, OnLeave = {} }

function BF:SetEventHook(event, func, enabled)
	eventHooks[event][func] = enabled or nil
end

-- ============================================================
-- 3. FRAME PROTOTYPE (Grid2 GridFramePrototype — verbatim structure)
-- ============================================================

local BuzzardFramePrototype = {}

if PingUtil then
	function BuzzardFramePrototype:GetContextualPingType()
		return PingUtil:GetContextualPingTypeForUnit( UnitGUID(self.unit) )
	end
	function BuzzardFramePrototype:GetTargetPingGUID()
		return UnitGUID(self.unit)
	end
end

-- ============================================================
-- AURA CACHE HELPERS (ported from 3.1.7 BFLayout.lua)
-- ============================================================
local function WipeAuraCache(unit)
    if not BF.auraMatchCache then return end
    local cache = BF.auraMatchCache[unit]
    if not cache then return end
    if cache.buffFrames         then wipe(cache.buffFrames)         end
    if cache.generalBuffs       then wipe(cache.generalBuffs)       end
    if cache.allTracked         then wipe(cache.allTracked)         end
    if cache.allHelpful         then wipe(cache.allHelpful)         end
    if cache.debuffFrames       then wipe(cache.debuffFrames)       end
    if cache.dispelDebuffFrames then wipe(cache.dispelDebuffFrames) end
    if cache.helpfulBySpellID   then wipe(cache.helpfulBySpellID)   end
    if cache.containers then
        for _, t in pairs(cache.containers) do wipe(t) end
    end
    cache.missingRaidBuff = nil
end

-- ============================================================
-- DEFERRED UPDATE QUEUE (ported from 3.1.7 BFLayout.lua)
-- Processes aura rebuilds on the next render frame so they run
-- outside the secure OnAttributeChanged context (no taint).
-- ============================================================
local deferredAuraFrames  = {}
local deferredRangeFrames = {}

do
    local deferredFrame = CreateFrame("Frame")
    deferredFrame:Hide()
    BF._profFrames = BF._profFrames or {}
    BF._profFrames["Layout defer"] = deferredFrame  -- Profiler.lua script-wrap registry
    deferredFrame:SetScript("OnUpdate", function(self)
        self:Hide()
        -- Grid2 parity: re-send BF_UnitUpdated for each deferred unit so
        -- that Offline:BF_UnitUpdated re-checks UnitIsConnected() after
        -- the roster data has settled (one render frame after assignment).
        -- Without this, UnitIsConnected can return a stale true during
        -- the initial OnUnitChanged pass, leaving offline units cached
        -- as online with green health bars. Grid2 achieves this via its
        -- QueueUpdateRoster → UpdateRoster deferred sweep which re-sends
        -- Grid_UnitUpdated for any unit whose data changed.
        -- This also gives UnitClass a second chance to return class data
        -- for distant members, reducing the visible green-flash before
        -- class colors are applied.
        local refreshedUnits
        for i = 1, #deferredAuraFrames do
            local frame = deferredAuraFrames[i]
            local unit  = frame.unit
            if unit and frame._deferredAuraUnit == unit then
                if not refreshedUnits then refreshedUnits = {} end
                if not refreshedUnits[unit] then
                    refreshedUnits[unit] = true
                    BF:SendMessage("BF_UnitUpdated", unit)
                end
            end
        end
        for i = 1, #deferredAuraFrames do
            local frame = deferredAuraFrames[i]
            local unit  = frame.unit
            if unit and frame._deferredAuraUnit == unit then
                BF:UpdateFrameIndicators(frame, unit)
            end
            frame._deferredAuraUnit = nil
        end
        wipe(deferredAuraFrames)
        if BF.FlushDeferredIndicatorUpdates then BF:FlushDeferredIndicatorUpdates() end
        for i = 1, #deferredRangeFrames do
            local frame = deferredRangeFrames[i]
            if frame.unit then
                if BF.ImmediateRangeUpdate then
                    BF:ImmediateRangeUpdate(frame)
                end
                -- Re-run range and status indicators so they render
                -- with settled data (one render frame after assignment).
                local unit = frame.unit
                local rangeInd  = BF.indicators and BF.indicators["rangeAlpha"]
                local statusInd = BF.indicators and BF.indicators["statusIcons"]
                local overlayInd = BF.indicators and BF.indicators["statusOverlay"]
                if rangeInd  then rangeInd:Update(frame, unit)  end
                if statusInd then statusInd:Update(frame, unit) end
                if overlayInd then overlayInd:Update(frame, unit) end
            end
        end
        wipe(deferredRangeFrames)
    end)

    function BF:QueueDeferredAuraRebuild(frame, unit)
        -- Deduplicate: if this frame is already queued for the same unit, skip.
        -- Multiple callers (startup sweeps, RefreshAllCustomContainersWithRebuild,
        -- UpdateIndicators unitChanged) can queue the same frame within a single
        -- render tick.  Processing it twice runs UpdateStandardAuras →
        -- RunCustomPasses → UpdateCustomBuffContainers redundantly, which can
        -- cause a visible flash on permanent custom-container auras.
        if frame._deferredAuraUnit == unit then return end
        frame._deferredAuraUnit = unit
        deferredAuraFrames[#deferredAuraFrames + 1] = frame
        deferredFrame:Show()
    end

    function BF:QueueDeferredRangeUpdate(frame)
        deferredRangeFrames[#deferredRangeFrames + 1] = frame
        deferredFrame:Show()
    end
end

-- Grid2 verbatim: Layout() iterates all enabled indicators
function BuzzardFramePrototype:Layout()
	local w, h = BuzzardFrame_GetInitialSize(self)
	-- Set size (protected — skip in combat)
	if not InCombatLockdown() then self:SetSize(w, h) end
	-- Grid2 verbatim: iterate all enabled indicators.
	local indicators = BF:GetIndicatorsEnabled()
	for i = 1, #indicators do
		local indicator = indicators[i]
		if BF:ShouldLayoutIndicator(indicator, self) then
			indicator:Layout(self)
		end
	end
end

-- v97: re-derive the reduced-max-health bar/clip and its text for a fresh
-- occupant. Deliberately NOT part of AbsorbBars:Update (perf decision that
-- removed it from the per-event path stands); this runs once per unit
-- assignment only.
local function RefreshReducedMaxHealth(frame, unit)
    local absorbInd = BF.indicators and BF.indicators.absorbBars
    if absorbInd and absorbInd._UpdateReducedMaxHealth and absorbInd:GetFrame(frame) then
        absorbInd:_UpdateReducedMaxHealth(frame, unit)
    end
    local textInd = BF.indicators and BF.indicators.reducedMaxHealthText
    if textInd and textInd:GetFrame(frame) then
        textInd:Update(frame, unit)
    end
end

-- ============================================================
-- UNIT-CHANGE LIFECYCLE (BuzzardFrames-specific)
-- Called when a frame is assigned a genuinely new unit.
-- Grid2 doesn't need this because it has no custom aura system;
-- BF has aura caches, icon pools, and deferred rebuilds that must
-- be reset when the displayed unit changes.
-- ============================================================
OnUnitChanged = function(frame, unit)
    -- Clear ready check timer
    if frame.readyCheckHideTimer then
        frame.readyCheckHideTimer:Cancel()
        frame.readyCheckHideTimer = nil
    end
    frame.readyCheckCachedStatus = nil

    -- Clear per-frame render caches so indicators never use a
    -- previous unit's stale state.
    frame._cachedClassName     = nil
    frame._auraLayoutDirty     = nil
    frame.SF_SpecColorActive   = nil
    frame.SF_CustomColorActive = nil
    frame.cachedHealthR        = nil
    frame._powerColorType      = nil
    -- v97: NameText reads _offline before StatusOverlay (which writes it)
    -- runs in the same sweep (toc order 139 < 143); a stale true from the
    -- previous occupant faded the new occupant's name.
    frame._offline             = nil
    -- (_nameRenderedUnit/_nameRetryPending: deleted — confirmed write-only
    -- dead code, never read anywhere; plan Phase 2.5.)

    -- Wipe aura match cache (previous unit's routing data).
    -- Grid2 pattern: do NOT hide icons here — the deferred indicator
    -- update will re-render them with the new unit's data. Hiding
    -- first causes a visible flash.
    WipeAuraCache(unit)

    if frame.healPrediction then frame.healPrediction:SetAlpha(0) end

    -- Grid2 parity: OnAttributeChanged does NOT call Layout on
    -- indicators. Grid2's OnAttributeChanged is just SetFrameUnit +
    -- UpdateIndicators. Frame resizing in Grid2 lives in
    -- UpdateFramesSizeForHeader, which we mirror in
    -- BF:UpdateFramesSizeForHeader (it calls frame:Layout() per frame
    -- when dimensions change). Calling LayoutFrame here invokes
    -- IconIndicator:Layout → ClearFrameAuraAnchors, which on the
    -- reload-in-combat path was wiping private aura state between
    -- frame creation and the post-combat flush re-registration.

    -- Prime offline cache immediately (Grid2 pattern: Grid_UnitUpdated)
    BF:SendMessage("BF_UnitUpdated", unit)

    -- v72 PERF: this frame is now IN SERVICE, so build its aura grid
    -- containers and their button pools. They are no longer built at frame
    -- creation (BF:EnsureFrameAuraContainers, Auras/ContainerFactory.lua):
    -- solo, 44 of the 45 header children created at login never get a unit,
    -- and each was paying for 20 containers / 360 styled aura buttons it
    -- could never render — 3339 ms of InitAuraButton inside a 7614 ms
    -- headersBuilt span.
    --
    -- BEFORE UpdateIndicators below, so the very first render pass on this
    -- unit already has the containers. Queued for PLAYER_REGEN_ENABLED
    -- instead while aura creation is restricted, which degrades exactly
    -- like a feature container toggled on in combat does today.
    if BF.EnsureFrameAuraContainers then
        BF:EnsureFrameAuraContainers(frame)
    end

    -- Run all indicators with the new unit.
    frame:UpdateIndicators()

    -- Targeted AbsorbBars:Layout re-run for new units joining the group
    -- mid-session (late joiners after a fresh group composition). Same
    -- rationale as the LoadLayout-tail call site below: AbsorbBars:Layout
    -- snapshots hBar:GetWidth() and the build-time snapshot may have been
    -- 0 if the frame wasn't sized yet. Late-joiner frames get their unit
    -- assignment here via OnAttributeChanged; by this point the frame's
    -- dimensions are correct, so re-snapshotting now captures the real
    -- value. Scoped to ONE indicator — does NOT touch IconIndicator (PA).
    do
        local absorbBars = BF.GetIndicatorByName and BF:GetIndicatorByName("absorbBars")
        if absorbBars and absorbBars:GetFrame(frame) then
            absorbBars:Layout(frame)
        end
    end

    -- Same rationale, same bug class, for nameText — this is what fixed the
    -- player's name never appearing on the raid/party frame at a fresh login.
    --
    -- NameText:Layout snapshots per-frame state that NameText:Update then
    -- REPLAYS on every single repaint:
    --   * parent._nameWidth   (NameText.lua:194-196) -> replayed at :409-411
    --   * parent._nameFont*   (NameText.lua:146-153) -> replayed at :373-375
    -- Layout runs exactly once, at frame build (BFLayout.lua:618), before the
    -- header has finished sizing the frame. A small-but-positive build-time width
    -- passes Layout's `barW > 0` guard and pins _nameWidth to a few pixels; with
    -- SetWordWrap(false), SetMaxLines(1) and nameClip:SetClipsChildren(true) the
    -- name is then painted correctly and clipped to invisibility on every repaint,
    -- forever. Nothing else re-runs NameText:Layout for a live frame.
    --
    -- This is why the name looked like it "never appeared" while in fact it
    -- repainted several times a second: at the time, statusOverlay's alive branch
    -- cross-called nameText:Update on every UNIT_HEALTH (since REMOVED by the
    -- Grid2-parity refactor — see Docs/NAME_PATH_GRID2_REFACTOR_PLAN.md D2). No
    -- amount of repainting could fix it, because Update re-applied the bad
    -- snapshot. Update is stateless now, making this Layout re-run the healing
    -- mechanism rather than a bypass.
    --
    -- Player-only because the player's frame is built earliest, before sizing has
    -- settled, and because the _nameFont* replay at NameText.lua:373-375 sits past
    -- the issecretvalue() early-return at :299 — every other unit's UnitName is a
    -- secret value in 12.0, so only the player reaches that code at all.
    -- Fresh-login-only because after a /reload the sizes are already resolved on
    -- the first Layout.
    do
        local nameText = BF.GetIndicatorByName and BF:GetIndicatorByName("nameText")
        if nameText and nameText:GetFrame(frame) then
            nameText:Layout(frame)
        end
    end

    -- Third of the same family, for statusOverlay. NOT the fix for the
    -- "status text smaller than configured" report -- that was a
    -- GetFont -> SetFont round trip shrinking the height on every tick of
    -- a dead unit (see StatusOverlay:Layout), plus ReloadLayout skipping
    -- frame:Layout() on a flat change that left the frame size unchanged
    -- (see the _forceReload note in BF:ReloadLayout). This re-run only
    -- covers the Status Text option setters, which sweep BF.activeFrames
    -- (frames holding a unit) rather than every header child: a spare
    -- that comes into service after such an edit picks up the current
    -- font, border and position here. One SetFont + SetPoint per unit
    -- assignment, in line with the two re-runs above.
    do
        local statusOverlay = BF.GetIndicatorByName and BF:GetIndicatorByName("statusOverlay")
        if statusOverlay and statusOverlay:GetFrame(frame) then
            statusOverlay:Layout(frame)
        end
    end

    -- Grid2 parity: private aura icons and dispel overlay are now
    -- registered indicators (privateAuraIcons, privateAuraDispelOverlay)
    -- in PrivateAuras.lua. Their Update methods run inside
    -- UpdateIndicators() above and handle unit-change anchor registration.
    -- No manual PA block needed here.
    --
    -- v60: the commented-out ApplyPrivateAuraOverrideFields /
    -- RegisterPrivateAuraOverlayAnchorsOnly / RegisterPrivateAuraBorderAnchorsOnly
    -- calls that sat here were removed with the Private Aura Customizations
    -- module they belonged to.

    -- v97: reduced-max-health is event-driven only
    -- (UNIT_MAX_HEALTH_MODIFIERS_CHANGED), which never re-fires for a unit
    -- assignment, so re-derive it here like Blizzard's CompactUnitFrame_UpdateAll.
    RefreshReducedMaxHealth(frame, unit)

    -- Deferred aura rebuild (outside secure context, no taint)
    BF:QueueDeferredAuraRebuild(frame, unit)
    -- Deferred range evaluation — also clears _unitJustChanged and re-runs
    -- the indicators that were suppressed above so they render with valid data.
    BF:QueueDeferredRangeUpdate(frame)
end

-- ============================================================
-- v97 (2026-08-27): SAME TOKEN, NEW OCCUPANT.
-- Grid2's roster sweep runs UpdateIndicators(true) on this branch and needs
-- nothing else because Grid2 keeps no per-frame render state. BF does, and
-- OnUnitChanged (above) is NOT on this path -- the token never changed -- so
-- the occupant-dependent caches it clears survived the shuffle: the new
-- occupant inherited the previous one's offline name coloring (NameText
-- reads _offline before StatusOverlay rewrites it), a ready-check icon
-- inside its 10 s hold, and the reduced-max-health bar/clip/suffix. Called
-- from the roster sweep (Initialization.lua) in place of the bare
-- UpdateIndicators(true).
-- ============================================================
function BF.OnUnitOccupantChanged(frame, unit)
    if frame.readyCheckHideTimer then
        frame.readyCheckHideTimer:Cancel()
        frame.readyCheckHideTimer = nil
    end
    frame.readyCheckCachedStatus = nil
    frame._offline               = nil
    frame.cachedHealthR          = nil
    frame._cachedClassName       = nil
    frame:UpdateIndicators(true)
    RefreshReducedMaxHealth(frame, unit)
end

-- Expose for Initialization.lua (startup sweep first-pass)
BF.OnUnitChanged = OnUnitChanged

-- Grid2 verbatim (GridFrame.lua:184-218): UpdateAuraContainers +
-- UpdateIndicators(unitChanged). The container body lives in
-- Auras/ContainerFactory.lua (BF:UpdateFrameAuraContainers) next to the
-- alpha gate it shares with SyncAuraGridContainer.
function BuzzardFramePrototype:UpdateAuraContainers()
    if BF.UpdateFrameAuraContainers then
        BF:UpdateFrameAuraContainers(self, self.unit)
    end
end

-- Grid2 verbatim: UpdateIndicators — pure indicator dispatch, plus the
-- Grid2 `unitChanged` tail: the roster sweep passes true for a token whose
-- occupant changed, and the containers get the same-token UpdateAllAuras
-- rebuild the engine does not perform on its own (v97, 2026-08-27).
function BuzzardFramePrototype:UpdateIndicators(unitChanged)
    local unit = self.unit
    if unit then
        local indicators = BF:GetIndicatorsEnabled()
        for i = 1, #indicators do
            indicators[i]:Update(self, unit)
        end
    end
    if unitChanged then
        self:UpdateAuraContainers()
    end
end

-- Grid2 verbatim: CreateIndicators() iterates all sorted indicators
function BuzzardFramePrototype:CreateIndicators()
	local indicators = BF:GetIndicatorsSorted()
	local hb = BF._loadHB   -- §L5.1: counts dispatches, nil unless collecting
	for i = 1, #indicators do
		local indicator = indicators[i]
		if indicator:CanCreate(self) then
			indicator:Create(self)
			if hb then hb.indCreates = hb.indCreates + 1 end
		end
	end
end

-- ============================================================
-- 4. FRAME REGISTRATION (Grid2 GridFrame_Init — verbatim structure)
-- ============================================================
BuzzardFrame_GetInitialSize = function(self)
	local header = self:GetParent()
	return header.frameWidth, header.frameHeight
end

-- ============================================================
-- v98 (2026-08-27, owner-approved): RIGHT-CLICK MENU MISFIRE CORRECTION.
-- For a raid member the client cannot see (another instance / phase)
-- UnitIsOtherPlayersBattlePet(unit) answers TRUE (diag-confirmed: raid27,
-- isPlayer=true, inRaid=27, battlePet=true), and the secure "togglemenu"
-- action tests the pet predicates BEFORE UnitIsPlayer, so the OTHERBATTLEPET
-- menu opens. The classifier cannot be replaced (see SECURE_INIT), so this
-- insecure post-click hook detects the impossible combination "is a player
-- AND is someone's pet", closes the wrong menu and opens the right one. It
-- never fires for a visible member, whose menu stays fully secure. In the
-- corrected menu Set Focus is blocked (tainted opener) -- accepted: the
-- alternative was a battle-pet menu with nothing usable on it.
-- ============================================================
local issecretvalue = issecretvalue or function() return false end

-- v98b: SECURE "SET FOCUS" FOR THE CORRECTED MENU. The corrected menu is
-- opened by addon code, so Blizzard's own Set Focus entry (FocusUnit from
-- a tainted menu) throws ADDON_ACTION_FORBIDDEN. A SecureActionButton with
-- type="focus" is the sanctioned route (Clique's focus binding is exactly
-- this): the hardware click lands on the secure button, which sits on top
-- of Blizzard's "Set Focus" element for the duration of the menu. Only
-- possible OUT of combat (the unit attribute and the button's
-- parent/points are protected writes); in combat the entry is disabled.
local misfireUnit          -- set around UnitPopup_OpenMenu in MenuMisfireHook
local focusBtn             -- the shared secure button, created lazily
local function GetFocusButton()
	if focusBtn then return focusBtn end
	focusBtn = CreateFrame("Button", "BuzzardFramesMenuFocusButton", UIParent,
		"SecureActionButtonTemplate")
	focusBtn:SetAttribute("type", "focus")
	-- Act on RELEASE, explicitly. SecureActionButton_OnClick performs the
	-- action on the press type selected by the ActionButtonUseKeyDown cvar
	-- unless the button pins it with this attribute; menu entries respond
	-- on release, and closing the menu on the down-click (v98b's first
	-- cut) hid the button before the up-click could reach it -- the focus
	-- never fired.
	focusBtn:SetAttribute("useOnKeyDown", false)
	focusBtn:RegisterForClicks("AnyUp")
	focusBtn:Hide()
	-- Insecure, runs after the secure focus action: fold the menu away.
	focusBtn:SetScript("PostClick", function()
		local mgr = Menu and Menu.GetManager and Menu.GetManager()
		if mgr then pcall(mgr.CloseMenus, mgr) end
	end)
	-- The overlay takes the mouse, so the element underneath never gets its
	-- own OnEnter; drive that element's highlight (MenuVariants.CreateHighlight
	-- texture, `frame.highlight`) from here so the entry looks like its
	-- neighbors.
	focusBtn:SetScript("OnEnter", function(b)
		local f = b:GetParent()
		if f and f.highlight then f.highlight:SetAlpha(1); f.highlight:Show() end
	end)
	focusBtn:SetScript("OnLeave", function(b)
		local f = b:GetParent()
		if f and f.highlight then f.highlight:Hide() end
	end)
	return focusBtn
end
local function ParkFocusButton()
	if not focusBtn or InCombatLockdown() then return end
	focusBtn:Hide()
	focusBtn:ClearAllPoints()
	focusBtn:SetParent(UIParent)
end
local function OnMisfireMenuModify(owner, rootDescription, contextData)
	local u = misfireUnit
	if not u or not contextData or contextData.unit ~= u then return end
	if not (rootDescription and rootDescription.EnumerateElementDescriptions) then return end
	for _, desc in rootDescription:EnumerateElementDescriptions() do
		local text = MenuUtil and MenuUtil.GetElementText and MenuUtil.GetElementText(desc)
		if text == SET_FOCUS then
			if InCombatLockdown() then
				desc:SetEnabled(false)  -- would throw; gray it out instead
			else
				desc:AddInitializer(function(frame)
					local b = GetFocusButton()
					if InCombatLockdown() then return end
					b:SetAttribute("unit", u)
					b:SetParent(frame)
					b:ClearAllPoints()
					b:SetAllPoints(frame)
					b:SetFrameStrata(frame:GetFrameStrata())
					b:SetFrameLevel(frame:GetFrameLevel() + 10)
					b:Show()
					if not frame._bfFocusParkHooked then
						frame._bfFocusParkHooked = true
						frame:HookScript("OnHide", function(f)
							if focusBtn and focusBtn:GetParent() == f then ParkFocusButton() end
						end)
					end
				end)
			end
			return
		end
	end
end
if Menu and Menu.ModifyMenu then
	for _, tag in ipairs({ "MENU_UNIT_RAID_PLAYER", "MENU_UNIT_PARTY", "MENU_UNIT_PLAYER" }) do
		pcall(Menu.ModifyMenu, tag, OnMisfireMenuModify)
	end
end

local function MenuMisfireHook(self, button)
	if button ~= "RightButton" then return end
	local u = self.unit
	if not u or not UnitExists(u) then return end
	local mgr = Menu and Menu.GetManager and Menu.GetManager()
	if not (mgr and mgr.GetOpenMenu and mgr:GetOpenMenu()) then return end
	local isPlayer = UnitIsPlayer(u)
	if issecretvalue(isPlayer) or not isPlayer then return end
	local bp = UnitIsOtherPlayersBattlePet and UnitIsOtherPlayersBattlePet(u)
	local op = UnitIsOtherPlayersPet and UnitIsOtherPlayersPet(u)
	if issecretvalue(bp) or issecretvalue(op) or not (bp or op) then return end
	if not UnitPopup_OpenMenu then return end
	pcall(mgr.CloseMenus, mgr)
	local which = (UnitInRaid(u) and "RAID_PLAYER")
		or (UnitInParty(u) and "PARTY") or "PLAYER"
	misfireUnit = u
	local ok, err = pcall(UnitPopup_OpenMenu, which, { unit = u })
	misfireUnit = nil
	if not ok then geterrorhandler()(err) end
end

-- v99b NOTE (2026-08-27): a PostClick hook that called SpellStopTargeting()
-- for a click-cast on a member the client cannot see (another instance)
-- was tried and REVERTED: SpellStopTargeting is protected on 12.1
-- (ADDON_ACTION_FORBIDDEN). Nothing secure distinguishes those units
-- (UnitCanAssist is true, UnitIsVisible has no macro conditional and is not
-- in the restricted environment), so the targeting cursor / auto-self-cast
-- on such a click is the game's behavior and stays.
local function BuzzardFrame_Init(frame, width, height)
	-- §L5.1 headersBuilt drill-down: five timestamps, all nil unless the
	-- harness is collecting. This is the per-frame body the whole span is
	-- made of, so the stage boundaries are placed here rather than inferred.
	local hb  = BF._loadHB
	local ht0 = hb and debugprofilestop() or nil
	-- Grid2: mix in prototype methods
	for name, value in pairs(BuzzardFramePrototype) do
		frame[name] = value
	end
	-- Grid2: hook script handlers
	for event, handler in pairs(BuzzardFrameEvents) do
		frame:HookScript(event, handler)
	end
	frame:HookScript("OnClick", MenuMisfireHook)  -- v98, see above
	-- Grid2: set initial attributes
	if frame:CanChangeAttribute() then
		frame:SetAttribute("initial-width", width)
		frame:SetAttribute("initial-height", height)
		if PingUtil then
			frame:SetAttribute("ping-receiver", true)
			frame.IsPingable = true
		end
	end
	-- RegisterForClicks is PROTECTED. The comment that used to sit here said
	-- this could never run in combat because ReloadLayout is RunSecure-guarded
	-- -- true of the LoadLayout/ForceFramesCreation path, but NOT of the path
	-- that actually reaches here in a fight: a secure group header materializes
	-- a new child button on its own whenever the roster outgrows its child
	-- pool, and that fires initialConfigFunction -> BF:RegisterFrame -> this
	-- function from inside SecureGroupHeader_Update, combat included (user
	-- report: 5x ADDON_ACTION_BLOCKED on 'RegisterForClicks' mid-combat).
	-- So skip both click registrations while locked down and flag the pool
	-- instead: BF:PLAYER_REGEN_ENABLED (Initialization.lua) drains
	-- _framesCreatedInCombat and re-registers every frame in
	-- self.registeredFrames the moment combat drops.
	if InCombatLockdown() then
		BF._framesCreatedInCombat = true
	else
		frame:RegisterForClicks( BF.db and BF.db.profile.clickOnMouseDown and "AnyDown" or "AnyUp" )
		if Clique then Clique:UpdateRegisteredClicks(frame) end
	end
	-- Grid2 verbatim: container texture (visible background)
	frame.container = BF.Texture(frame)
	local ht1 = hb and debugprofilestop() or nil
	-- Grid2: CreateIndicators (modular widget creation)
	-- Aura icon pools (buff/debuff/bigDef/missingRaidBuff)
	-- are built by each aura indicator's :Create method, dispatched here.
	-- :CanCreate(parent) on each aura indicator returns false for preview
	-- frames so DummyAuras can build preview icons via BF.BuildAuraIconFrame
	-- when it needs them.
	-- v75 (owner ruling, 2026-08-15): EAGER init-window build RESTORED — the
	-- v72 per-frame deferral is retired. It broke COMBAT RELOADS: with every
	-- aura build gated behind IsAuraCreationRestricted, a /reload during a
	-- fight refused all of them and queued them for PLAYER_REGEN_ENABLED, so
	-- NO frame showed ANY auras until combat ended. The pre-v72 init window
	-- built unconditionally inside the post-load configuration window (where
	-- secure setup is still legal on a combat reload) and combat reloads
	-- worked.
	-- Mechanism: stamping _bf_auraContainersLive BEFORE the dispatches makes
	-- BF:ShouldDeferFrameAuraContainers short-circuit false for this frame,
	-- so every v72 gate — the aura indicators' :Create, the Preallocate gate
	-- below, and the container arms inside frame:Layout() — passes exactly
	-- like pre-v72, restriction check included (the old init window never
	-- checked either). The v72/v74 machinery (ShouldDefer, the Update safety
	-- nets, pendingFrameBuilds, the idle warm-up) all REMAIN — inert in
	-- steady state, and still the rebuild path after a v74 relevance-change
	-- sweep clears the built latch.
	-- Cost: the full per-frame container build is back in this init window
	-- (the v72 lazy-login win is given up — owner's call). The v74 relevance
	-- filter + single-buff pool clamp still gate WHAT each build creates.
	if not frame._isPreviewFrame then
		frame._bf_auraContainersLive = true
	end
	frame:CreateIndicators()
	local ht2 = hb and debugprofilestop() or nil
	-- Pre-allocate custom container icon pools for the current spec so the
	-- display-time growth path in ensureContainerIconPool never runs in
	-- combat. Mirrors Grid2's Icon_Layout pre-allocation pattern.
	-- (v75: the ShouldDefer gate here passes now — Live is stamped above.)
	if not frame._isPreviewFrame and BF.PreallocateContainerPools
		and not BF:ShouldDeferFrameAuraContainers(frame) then
		BF:PreallocateContainerPools(frame)
	end
	local ht3 = hb and debugprofilestop() or nil
	-- Stamp aura-anchor pre-resolved per-frame fields. _bf_auraAnchorTarget
	-- is the frame to anchor to when the aurasAbovePowerBar lift fires
	-- (the container health-area rect; never changes for the frame's
	-- lifetime). container, NOT healthBar.clipFrame: the clip narrows
	-- while a reduced-max-health effect is active (AbsorbBars
	-- _UpdateReducedMaxHealth), which dragged lifted auras left with the
	-- health fill. See BF.AuraLiftAnchorFrame (ContainerFactory.lua).
	-- _bf_powerBarShown mirrors powerBar:IsShown();
	-- maintained event-driven by PowerBar:Update afterwards.
	frame._bf_auraAnchorTarget = frame.container or (frame.healthBar and (frame.healthBar.clipFrame or frame.healthBar)) or frame
	frame._bf_powerBarShown    = (frame.powerBar and frame.powerBar:IsShown()) and true or false
	-- Grid2: Layout (positions everything)
	frame:Layout()
	-- v75: everything EnsureFrameAuraContainers would build (both aura
	-- indicators' :Layout + Preallocate) just ran, so stamp the built latch
	-- here — otherwise the first Update's safety net would re-dispatch the
	-- whole container Layout once per frame for nothing.
	if not frame._isPreviewFrame then
		frame._bf_auraContainersBuilt = true
	end
	local ht4 = hb and debugprofilestop() or nil
	-- Grid2: notify
	BF:SendMessage("BF_UpdateLayoutSize")
	if hb then
		BF:LoadHBFrame(ht0, ht1, ht2, ht3, ht4, debugprofilestop())
	end
end

function BF:RegisterFrame(frame)
	BuzzardFrame_Init(frame, BuzzardFrame_GetInitialSize(frame))
	registeredFrames[frame:GetName()] = frame
	if InCombatLockdown() then
		self._framesCreatedInCombat = true
	end
end

local function BuzzardHeader_InitialConfigFunction(headerFrame, frameName)
	local frame = _G[frameName]
	-- Evidence for BF:CanCompileSnippets(): only the secure snippet (or the
	-- Lua fallback, which sets its own flag) ever reaches here.
	if frame then frame._bfConfigured = true end
	BF:RegisterFrame(frame)
end

-- Grid2: CreateIndicators on all registered frames
function BF:CreateAllFrameIndicators()
	for _, frame in next, registeredFrames do
		frame:CreateIndicators()
	end
end

-- Grid2: UpdateIndicators on all activated frames
function BF:UpdateAllFrameIndicators()
	for frame in next, activatedFrames do
		frame:UpdateIndicators()
	end
end

-- Grid2: LayoutFrames — iterates all headers, calls Layout on each frame
function BF:LayoutAllFrames(notify)
	for _, header in ipairs(self.groupsUsed or {}) do
		for _, frame in ipairs(header) do
			frame:Layout()
		end
	end
	-- Twins are not header children (UnitFrames/Twins.lua). Forced: the loop
	-- above relayouts every child whether or not its size moved, because this
	-- is the funnel for settings that change what Layout() PRODUCES, and a
	-- size-guarded twin pass would leave the twins on stale geometry.
	if self.RefreshTwinLayout then self:RefreshTwinLayout(true) end
	if notify then self:SendMessage("BF_UpdateLayoutSize") end
end

-- Grid2: WithAllFrames — run a function on every registered frame
do
	local type, with = type, {}
	with["table"] = function(self, object, func, ...)
		if type(func) == "string" then func = object[func] end
		for _, frame in next, registeredFrames do
			func(object, frame, ...)
		end
	end
	with["function"] = function(self, func, ...)
		for _, frame in next, registeredFrames do
			func(frame, ...)
		end
	end
	function BF:WithAllFrames( param , ... )
		with[type(param)](self, param, ...)
	end
end

-- Grid2: UpdateFrameUnits — verbatim. WIRED (2026-08-23): called from
-- BF:PLAYER_ENTERING_WORLD (Initialization.lua), mirroring Grid2Frame's
-- RegisterEvent("PLAYER_ENTERING_WORLD", "UpdateFrameUnits")
-- (GridFrame.lua:284). Re-resolves SecureButton_GetModifiedUnit for every
-- activated frame after the world loads, so a frame whose token resolved
-- differently during the loading screen (vehicle suffix, unresolved unit)
-- re-runs the SetFrameUnit lifecycle — which re-attempts roster
-- registration. This was an unwired port before; Grid2 has always run it.
function BF:UpdateFrameUnits()
	for frame, old_unit in next, activatedFrames do
		local unit = SecureButton_GetModifiedUnit(frame)
		if old_unit ~= unit then
			SetFrameUnit(frame, unit)
			OnUnitChanged(frame, unit)
		end
	end
end

-- Expose prototype for external access (Grid2 pattern)
BF.FramePrototype = BuzzardFramePrototype

-- ============================================================
-- 5. HEADER CLASS (Grid2's GridLayoutHeaderClass)
-- ============================================================
local NUM_HEADERS = 0

-- PingableUnitFrameTemplate (12.1): makes header children resolve unit
-- pings, same as oUF frames (ouf.lua Spawn/SpawnHeader). Raid/party
-- units are always friendly, so the frames keep their `.unit` Lua field
-- — the secret-identity ping bug only bites hostile units (the oUF
-- __unit workaround is unit-frame-only for that reason).
local FRAMES_TEMPLATE  = "SecureUnitButtonTemplate,PingableUnitFrameTemplate"  .. (BackdropTemplateMixin and ",BackdropTemplate" or "")
local FRAMEC_TEMPLATE  = "ClickCastUnitTemplate,SecureUnitButtonTemplate,PingableUnitFrameTemplate" .. (BackdropTemplateMixin and ",BackdropTemplate" or "")

-- UnitFrames/Twins.lua builds standalone raid-style twins with the same
-- template the headers hand their children, so it needs the resolved string.
-- A getter, not a constant: BFHeaderClass:New tests `Clique` at header
-- creation time (runtime), not at file load, and the twin must match.
function BF:GetRaidFrameTemplate()
    return Clique and FRAMEC_TEMPLATE or FRAMES_TEMPLATE
end

local SECURE_INIT = [[
    self:SetAttribute("*type1", "target")
    -- "togglemenu" is the ONLY secure menu route for addon frames (v97
    -- finding): "menu" + a menu opener attribute taints the click path (Set
    -- Focus -> ADDON_ACTION_FORBIDDEN). Its misfire for unseen raid members
    -- is corrected after the fact by MenuMisfireHook (BuzzardFrame_Init).
    -- NOTE: this snippet is compiled by the restricted environment, which
    -- rejects the word f-u-n-c-t-i-o-n anywhere in the text, comments too.
    self:SetAttribute("*type2", "togglemenu")
    self:SetAttribute("useparent-toggleForVehicle", true)
    self:SetAttribute("useparent-allowVehicleTarget", true)
    self:SetAttribute("useparent-unitsuffix", true)
    -- v91 FIX (user report): with toggleForVehicle on, a raid member in a
    -- vehicle/possessed state makes SecureButton_GetModifiedUnit swap raidN ->
    -- raidpetN for EVERY click action -- so right-click opened the PET unit
    -- menu (short list + "Show Pet in Journal") instead of the raid-player
    -- menu. The per-button modified attribute below turns the vehicle toggle
    -- off for button 2 ONLY (SecureButton_GetModifiedAttribute checks
    -- "*toggleForVehicle2" ahead of the plain attribute): the MENU always
    -- resolves the player, while left-click targeting keeps the vehicle swap.
    -- v97 CORRECTION: a stored `false` is NOT honored -- GetModifiedAttribute
    -- does `if not value and useparent-...` and falls through to the HEADER's
    -- toggleForVehicle=true. The documented opt-out is ATTRIBUTE_NOOP, the
    -- empty string: truthy, so no parent fallback, then mapped to nil.
    self:SetAttribute("*toggleForVehicle2", "")
    local header = self:GetParent()
    local clickcast = header:GetFrameRef("clickcast_header")
    if clickcast then
        clickcast:SetAttribute("clickcast_button", self)
        clickcast:RunAttribute("clickcast_register")
    end
    header:CallMethod("initialConfigFunction", self:GetName())
]]

-- ── Classic fallback for SECURE_INIT ────────────────────────────
-- Classic builds ship Blizzard_RestrictedAddOnEnvironment WITHOUT the
-- untainted loadstring that RestrictedExecution.lua needs to compile an
-- `initialConfigFunction` attribute string. The moment a
-- SecureGroupHeader created its first child, the compile blew up with
--   RestrictedExecution.lua:79: attempt to call a nil value
-- (locals showed `loadstring_untainted = nil`), which unwound all the way
-- out through header:Show() in ForceFramesCreation and left the layout
-- half-built.
--
-- So on Classic we never hand the header the attribute string at all --
-- with no `initialConfigFunction` attribute set, Blizzard's child-creation
-- path skips the restricted compile entirely -- and do the same setup from
-- plain Lua instead. Everything SECURE_INIT does is a SetAttribute, a
-- Clique registration and a CallMethod: none of it is protected, and it
-- all runs at header bring-up while the header is hidden and out of
-- combat, so the insecure route is equivalent here.
local function ConfigureChildInsecure(header, child)
    if not child or child._bfInsecureConfigured or child._bfConfigured then return end
    child._bfInsecureConfigured = true

    child:SetAttribute("*type1", "target")
    child:SetAttribute("*type2", "togglemenu")
    child:SetAttribute("useparent-toggleForVehicle", true)
    child:SetAttribute("useparent-allowVehicleTarget", true)
    child:SetAttribute("useparent-unitsuffix", true)
    -- Same vehicle opt-out as the snippet: ATTRIBUTE_NOOP (empty string),
    -- because a stored `false` falls through to the header's value.
    child:SetAttribute("*toggleForVehicle2", "")

    -- Clique's insecure registration path. The snippet's
    -- clickcast_register RunAttribute is restricted-env only; adding the
    -- button to ClickCastFrames is the documented Lua equivalent and
    -- Clique picks it up on its next header sync.
    if Clique and _G.ClickCastFrames then
        _G.ClickCastFrames[child] = true
    end

    BuzzardHeader_InitialConfigFunction(header, child:GetName())
end

-- Sweep any children the header created that have not been through
-- ConfigureChildInsecure yet. Cheap and idempotent -- the per-child flag
-- makes re-runs no-ops -- so callers can fire it after any child-creating
-- round trip without tracking which children are new.
-- Can the restricted environment compile a snippet string?
-- Nothing addon code can inspect answers this reliably: on the reporting
-- Classic client the global loadstring_untainted existed, yet
-- RestrictedExecution.lua's captured copy was nil, and any test compile
-- reports its failure straight to the error frame (pcall can't catch it,
-- because it runs inside a secure attribute handler).
--
-- So: start from the client's interface version (Classic clients are
-- below 100000), then trust evidence. ForceFramesCreation checks whether
-- the snippet actually configured the children it just built; if any are
-- missing, snippets are broken here, this flips to false, and every
-- header is switched to the Lua path (see DisableSecureInit).
function BF:CanCompileSnippets()
    if self.canCompileSnippets == nil then
        local toc = select(4, GetBuildInfo()) or 0
        self.canCompileSnippets = toc >= 100000
    end
    return self.canCompileSnippets
end

local function ConfigureNewChildrenInsecure(header)
    if BF:CanCompileSnippets() then return end
    -- A header can parent frames that are not unit buttons (anchors,
    -- backgrounds). Only the template-spawned buttons get configured:
    -- they are Buttons, and SecureGroupHeaderTemplate names them
    -- "<headerName>UnitButtonN".
    local prefix = header:GetName()
    if not prefix then return end
    for _, child in ipairs({ header:GetChildren() }) do
        if not child._bfInsecureConfigured
           and child.IsObjectType and child:IsObjectType("Button") then
            local name = child:GetName()
            if name and name:find(prefix, 1, true) == 1 then
                ConfigureChildInsecure(header, child)
            end
        end
    end
end

-- Snippets turned out not to compile on this client: stop every existing
-- header from trying again. With the attribute cleared, Blizzard's child
-- creation skips the restricted compile, so no further errors are raised.
local function DisableSecureInit()
    BF.canCompileSnippets = false
    for i = 1, NUM_HEADERS do
        local h = _G["BFLayoutHeader" .. i]
        if h then h:SetAttribute("initialConfigFunction", nil) end
    end
end

-- All attributes that Reset() must clear (Grid2's HeaderAttributes)
-- IMPORTANT: "point", "xOffset", "yOffset" are intentionally NOT in this list.
-- Grid2 never clears them in Reset(). They survive across header reuse so that
-- ForceFramesCreation's Show() (which triggers SecureGroupHeader_Update) always
-- has a valid "point" attribute. They are overwritten later in SetOrientation().
local HeaderAttributes = {
    "nameList", "groupFilter", "roleFilter", "strictFiltering",
    "sortDir", "groupBy", "groupingOrder", "maxColumns", "unitsPerColumn",
    "startingIndex", "columnSpacing", "columnAnchorPoint",
    "useOwnerUnit", "filterOnPet", "unitsuffix", "sortMethod",
    "toggleForVehicle", "showSolo", "showPlayer", "showParty", "showRaid",
}

-- Custom defaults applied on Reset (Grid2's customDefaults)
local HEADER_DEFAULTS = {
    toggleForVehicle = true,
    showSolo   = false,
    showPlayer = true,
    showParty  = false,
    showRaid   = false,
}

local BFHeaderClass = { prototype = {} }

function BFHeaderClass:New(template)
    NUM_HEADERS = NUM_HEADERS + 1
    template = template or "SecureGroupHeaderTemplate"
    local parentFrame = BF.anchorFrame or UIParent
    local frame = CreateFrame("Frame", "BFLayoutHeader"..NUM_HEADERS, parentFrame, template)

    -- Mix in prototype methods
    for name, func in pairs(self.prototype) do
        frame[name] = func
    end

    -- Template & Clique
    if Clique then
        frame:SetAttribute("template", FRAMEC_TEMPLATE)
        SecureHandler_OnLoad(frame)
        frame:SetFrameRef("clickcast_header", Clique.header)
    else
        frame:SetAttribute("template", FRAMES_TEMPLATE)
    end

    frame.initialConfigFunction = BuzzardHeader_InitialConfigFunction
    -- Classic cannot compile the snippet (see ConfigureChildInsecure): leave
    -- the attribute unset there so Blizzard skips the restricted compile,
    -- and configure children from Lua after each creation pass instead.
    if BF:CanCompileSnippets() then
        frame:SetAttribute("initialConfigFunction", SECURE_INIT)
    end
    frame:Reset()
    return frame
end

-- Grid2: header:Reset() — from GridLayoutHeaderClass.prototype:Reset(), plus
-- the per-frame cache clear on every child (see the loop comment).
function BFHeaderClass.prototype:Reset()
    -- Grid2 verbatim: Hide the header before initializing attributes to
    -- avoid a lot of unnecessary SecureGroupHeader_Update() calls
    self:Hide()
    self:SetSize(1,1)
    -- SecureGroupFrames code does not correctly resets all the buttons, we need to do it manually because
    -- Grid2Frame relies on :OnAttributeChanged() event to add/delete units in roster and unit_frames tables.
    --
    -- EVERY child, not only the ones holding a unit. The reference design
    -- stops at the first unit-less child because units are assigned
    -- contiguously from index 1 and unassigning is all its loop does. The
    -- per-frame cache clear below piggybacked on that loop, but the caches
    -- it clears are stamped at frame BUILD time, unit or not: BuzzardFrame_Init
    -- runs frame:Layout() on every pre-created child, and the aura indicators'
    -- Layout memoizes BF:ResolveGroupTypeKey (the active flat ID) on the frame.
    -- With strictGroupLayout all eight group headers are built in a party, so
    -- 35+ spare children carried the PARTY flat's key into the raid; the early
    -- break left it in place, the flat-change re-Layout applied the party
    -- flat's per-Layout container geometry to them, and only the children in
    -- service by the LoadLayout deferred tail were re-derived (it sweeps
    -- BF.activeFrames). A child that received its unit LATER -- a raid that
    -- fills over time -- kept rendering per-Layout containers at the party
    -- flat's size and position (owner report, 25-man, frames near the end).
    -- The same hole applied to a CFG header recycled for a different group.
    for _,uframe in ipairs(self) do
        if uframe.unit ~= nil then
            uframe:SetAttribute("unit", nil)
        end
        -- Clear cached parent header so it re-resolves from GetParent()
        -- after the header is reassigned (stale refs cause aura offsets,
        -- cfAuraProfile, etc. to read from the old header).
        uframe._bf_parentHeader = nil
        -- Clear every per-frame cache that depends on header identity or on
        -- the active flat (groupTypeKey memo, isCustom/Raid/Party flags,
        -- containerHidden, activeGroups). Centralized in AuraGroupHelpers.lua
        -- so InvalidateContainerIconCaches and this site stay in sync.
        if BF.ClearFrameHeaderDerivedCaches then
            BF:ClearFrameHeaderDerivedCaches(uframe)
        end
        -- Grid2 parity (GridLayout.lua Reset): indicator widgets and
        -- their parent[self.name] keys must SURVIVE Reset so the
        -- subsequent LoadLayout -> ResizeAllFrames -> frame:Layout()
        -- dispatch can re-Layout each indicator. If we Disable here,
        -- the indicator dispatch loop in BuzzardFramePrototype:Layout
        -- gates on indicator:GetFrame(self) and skips any indicator
        -- whose parent[self.name] was nilled. IconIndicator:Layout
        -- calls ClearFrameAuraAnchors at the top, so anchor
        -- re-registration works correctly without a pre-Disable
        -- teardown.
    end
    -- Initialize attributes
    local defaults = HEADER_DEFAULTS
    for _, attr in ipairs(HeaderAttributes) do
        self:SetAttribute(attr, defaults[attr] or nil  )
    end
    --
    self.dbx = nil
    -- Clear custom frame group metadata (set by AddCustomFrameHeaders)
    self.isCustomFrame    = nil
    self._bf_isCFGHeader  = nil
    self.customGroupIndex = nil
    self.customGroupName  = nil
    self.isDetached       = nil
    self.headerPosKey     = nil
    self._classString     = nil
    -- v60: self.excludePlayer removed — the field had no readers and its one
    -- writer was scope-broken (see AddCustomFrameHeaders). The real
    -- exclude-player state lives on the group and reaches the header via the
    -- showPlayer attribute.
    -- Pet frame metadata (set by AddPetHeaders)
    self.isPetFrame  = nil
    self.petFlatID   = nil
    -- Module settings (set by AddCustomFrameHeaders)
    self.moduleShowBuffs            = nil
    self.moduleShowDebuffs          = nil
    self.moduleShowBigDef           = nil
    -- CFG section resolution (set by AddCustomFrameHeaders)
    self._cfgFlat     = nil
    self._cfgGroup    = nil
    -- Aura source profile (resolved from cfAuraSourceGroupType at layout time)
    self.cfAuraProfile               = nil
    -- Layout Settings (per-group overrides)
    self.cfFrameWidth      = nil
    self.cfFrameHeight     = nil
    self.cfMaxColumns      = nil
    self.cfUnitsPerColumn  = nil
    self.cfFrameSpacingH   = nil
    self.cfFrameSpacingV   = nil
    self.cfEnableFrameScale = nil
    self.cfFrameScale      = nil
    self.cfScaleIndicators = nil
    self.cfGrowDirection   = nil
    -- Hide the drag handle (but don't destroy it — it's reused when the
    -- header is recycled for a new custom frame group).
    if self._handle then self._handle:Hide() end
end

-- Grid2 anchorPoints table — used by PlaceHeaders and _DoRefreshCustomFrameHeaders
-- to derive columnAnchorPoint from groupAnchor. The perpendicular orientation table
-- maps groupAnchor to the anchor edge where new columns/rows start.
-- [false] = vertical groupAnchor → horizontal column direction
-- [true]  = horizontal groupAnchor → vertical row direction
local anchorToPoint = {
    [false] = { TOPLEFT = "TOP",  TOPRIGHT = "TOP",   BOTTOMLEFT = "BOTTOM", BOTTOMRIGHT = "BOTTOM" },
    [true]  = { TOPLEFT = "LEFT", TOPRIGHT = "RIGHT", BOTTOMLEFT = "LEFT",   BOTTOMRIGHT = "RIGHT"  },
}

-- Grid2 relativePoints table — used by PlaceHeaders to chain non-detached
-- headers together. [false]=vertical chaining (headers stack downward/upward),
-- [true]=horizontal chaining (headers go rightward/leftward).
-- The boolean key is the PERPENDICULAR axis: when frames grow horizontally,
-- headers chain vertically ([false]), and vice versa.
local relativePoints = {
    [false] = { TOPLEFT = "BOTTOMLEFT", TOPRIGHT = "BOTTOMRIGHT", BOTTOMLEFT = "TOPLEFT",     BOTTOMRIGHT = "TOPRIGHT"   },
    [true]  = { TOPLEFT = "TOPRIGHT",   TOPRIGHT = "TOPLEFT",     BOTTOMLEFT = "BOTTOMRIGHT", BOTTOMRIGHT = "BOTTOMLEFT" },
}

-- Derive groupAnchor from primary and secondary grow directions.
-- Grid2 derives this from a single "groupAnchor" setting (TOPLEFT/TOPRIGHT/
-- BOTTOMLEFT/BOTTOMRIGHT). BuzzardFrames exposes primary + secondary grow
-- direction dropdowns which map to the same four-corner anchor:
--
--   Primary | Secondary | groupAnchor
--   --------|-----------|------------
--   DOWN    | RIGHT     | TOPLEFT
--   DOWN    | LEFT      | TOPRIGHT
--   UP      | RIGHT     | BOTTOMLEFT
--   UP      | LEFT      | BOTTOMRIGHT
--   RIGHT   | DOWN      | TOPLEFT
--   RIGHT   | UP        | BOTTOMLEFT
--   LEFT    | DOWN      | TOPRIGHT
--   LEFT    | UP        | BOTTOMRIGHT
--
-- When secondaryDir is nil, the default secondary is used:
--   DOWN/UP → RIGHT,  RIGHT/LEFT → DOWN.
local function DeriveGroupAnchor(primaryDir, secondaryDir)
    -- Exposed as BF:DeriveGroupAnchor() below for use by options setters.
    if primaryDir == "DOWN" or primaryDir == "UP" then
        local sec = secondaryDir or "RIGHT"
        if primaryDir == "DOWN" then
            return (sec == "LEFT") and "TOPRIGHT" or "TOPLEFT"
        else -- UP
            return (sec == "LEFT") and "BOTTOMRIGHT" or "BOTTOMLEFT"
        end
    else -- RIGHT or LEFT
        local sec = secondaryDir or "DOWN"
        if primaryDir == "RIGHT" then
            return (sec == "UP") and "BOTTOMLEFT" or "TOPLEFT"
        else -- LEFT
            return (sec == "UP") and "BOTTOMRIGHT" or "TOPRIGHT"
        end
    end
end

function BF:DeriveGroupAnchor(primaryDir, secondaryDir)
    return DeriveGroupAnchor(primaryDir, secondaryDir)
end

-- Normalize a flat's stored pet secondary grow direction against its CURRENT
-- primary axis. A secondary value is only valid on one axis: horizontal
-- primary (RIGHT/LEFT) accepts UP/DOWN, vertical primary (DOWN/UP) accepts
-- LEFT/RIGHT. When the primary direction's axis changes (e.g. a party flat's
-- pet grow direction flips from UP to RIGHT, or a raid->party copy / profile
-- import / enable-seed leaves a cross-axis value behind), the stored secondary
-- becomes stale. If it happens to be a value that is *valid for the new axis*
-- (e.g. stored "UP" with new RIGHT primary), DeriveGroupAnchor's `or default`
-- guard does NOT replace it -- only nil triggers the default -- so the anchor
-- corner (and thus the top-vs-bottom grow origin) flips non-deterministically
-- depending on whatever was last stored. Returning nil for any value not valid
-- on the current axis forces DeriveGroupAnchor to use its canonical default,
-- making the derived anchor deterministic for every primary direction. This
-- mirrors the petSecondaryGrowDirection option's get() guard.
local function GetNormalizedPetSecondary(flat, primaryOverride)
    if not flat then return nil end
    -- primaryOverride lets callers that resolve the effective primary direction
    -- with a fallback (e.g. PlaceHeaders falling back to the main grow
    -- direction when the flat has no petGrowDirection) normalize against the
    -- SAME primary axis they pass to DeriveGroupAnchor.
    local dir = primaryOverride or flat.petGrowDirection or "DOWN"
    local sec = flat.petSecondaryGrowDirection
    if not sec then return nil end
    if dir == "RIGHT" or dir == "LEFT" then
        -- Horizontal primary: only UP/DOWN are valid secondaries.
        if sec == "UP" or sec == "DOWN" then return sec end
    else
        -- Vertical primary (DOWN/UP): only LEFT/RIGHT are valid secondaries.
        if sec == "LEFT" or sec == "RIGHT" then return sec end
    end
    return nil
end

function BF:GetPetSecondaryGrowDirection(flat, primaryOverride)
    return GetNormalizedPetSecondary(flat, primaryOverride)
end

-- Return the layout anchor for the active context (Grid2: p.anchor).
-- Party and raid have separate fields (partyLayoutAnchor / raidLayoutAnchor)
-- so changing one context's grow direction never affects the other.
-- Grow from Center anchor point (Grid2 "Layout Anchor = Center").
-- Grid2 centers ONLY the cross-axis: for vertical grow (DOWN/UP) the
-- block is pinned by its TOP/BOTTOM edge (vertical fixed, horizontal
-- centered); for horizontal grow (RIGHT/LEFT) by its LEFT/RIGHT edge
-- (horizontal fixed, vertical centered). This mirrors Grid2's anchorPoints
-- table (GridLayout.lua:109-111). Using "CENTER" (both axes) is wrong: a
-- lone frame would jump to the center on the grow axis too.
--   grow DOWN  → anchor TOP     grow UP    → anchor BOTTOM
--   grow RIGHT → anchor LEFT    grow LEFT  → anchor RIGHT
-- The anchored edge is the one the block grows AWAY from.
local _growCenterAnchor = {
    DOWN = "TOP", UP = "BOTTOM", RIGHT = "LEFT", LEFT = "RIGHT",
    -- legacy/migration aliases
    HORIZONTAL = "LEFT", VERTICAL = "TOP",
}
function BF:GrowFromCenterAnchor(growDir)
    return _growCenterAnchor[growDir or ""] or "TOP"
end

function BF:GetLayoutAnchor()
    local flat = self._resolvedProfile
    if not flat then
        flat = self._contextIsParty and self:GetActivePartyProfile()
               or self:GetRaidProfile()
    end
    if self._contextIsParty then
        -- Grow from Center: a party is a SINGLE group (one row or one
        -- column), so the cross axis is a single frame and only the GROW
        -- axis extent varies with member count. Pin the whole block by its
        -- CENTER — that centers the grow axis (what the user wants: e.g.
        -- horizontal grow centers horizontally) and harmlessly centers the
        -- trivial single-frame cross axis. Raid differs (multi-group grid):
        -- it edge-pins the grow axis and centers only the cross axis, below.
        -- partyLayoutAnchor stays stored and resumes when the toggle is off.
        local sp = self:GetSectionProfile("sorting", flat)
        if sp and sp.growFromCenter then return "CENTER" end
        return (flat and flat.partyLayoutAnchor) or "TOPLEFT"
    end
    -- Raid Grow from Center: same cross-axis edge-pin model as party.
    do
        local sp = self:GetSectionProfile("sorting", flat)
        if sp and sp.raidGrowFromCenter then
            return self:GrowFromCenterAnchor((sp and sp.raidGrowDirection) or "DOWN")
        end
    end
    return (flat and flat.raidLayoutAnchor) or "TOPLEFT"
end

-- Return the layout anchor for the modifying context (setup mode editing).
-- Unlike GetLayoutAnchor() which reads the active context, this reads from
-- the profile currently being edited via _modifyingFlat.
function BF:GetModifyingLayoutAnchor()
    local modProfile = self:GetModifyingProfile()
    if modProfile then
        if modProfile.type == "party" then
            -- Party grow-from-center pins by full CENTER (see GetLayoutAnchor).
            local sp = self:GetSectionProfile("sorting", modProfile)
            if sp and sp.growFromCenter then return "CENTER" end
            return modProfile.partyLayoutAnchor or "TOPLEFT"
        else
            local sp = self:GetSectionProfile("sorting", modProfile)
            if sp and sp.raidGrowFromCenter then
                return self:GrowFromCenterAnchor((sp and sp.raidGrowDirection) or "DOWN")
            end
            return modProfile.raidLayoutAnchor or "TOPLEFT"
        end
    end
    return self:GetLayoutAnchor()
end

-- Grid2: header:SetOrientation(horizontal)
-- Sets the "point", "xOffset", "yOffset" attributes on a SecureGroupHeaderTemplate
-- to control how child frames are laid out.
--
-- SecureGroupHeader child positioning:
--   point="TOP"    → child.TOP    at prev.BOTTOM + yOffset → grows DOWN when yOffset < 0
--   point="BOTTOM" → child.BOTTOM at prev.TOP    + yOffset → grows UP   when yOffset > 0
--   point="LEFT"   → child.LEFT   at prev.RIGHT  + xOffset → grows RIGHT when xOffset > 0
--   point="RIGHT"  → child.RIGHT  at prev.LEFT   + xOffset → grows LEFT  when xOffset < 0
--
-- For the main frames and DOWN/RIGHT custom frames this uses the same
-- point/direction as the original code. UP and LEFT use the opposite
-- point and a positive offset so frames flow in the reverse direction.
function BFHeaderClass.prototype:SetOrientation(horizontal, padding, growDir)
    padding = padding or 0
    growDir = growDir or (horizontal and "RIGHT" or "DOWN")
    local point, xOffset, yOffset
    if growDir == "DOWN" then
        point   = "TOP"
        xOffset = 0
        yOffset = -padding
    elseif growDir == "UP" then
        point   = "BOTTOM"
        xOffset = 0
        yOffset = padding
    elseif growDir == "RIGHT" then
        point   = "LEFT"
        xOffset = padding
        yOffset = 0
    elseif growDir == "LEFT" then
        point   = "RIGHT"
        xOffset = -padding
        yOffset = 0
    end
    self:ClearChildPoints()
    self:SetAttribute("xOffset", xOffset)
    self:SetAttribute("yOffset", yOffset)
    self:SetAttribute("point", point)
end

-- Grid2: header:Update() — force SecureGroupHeader to re-run
function BFHeaderClass.prototype:Update()
    if self:IsVisible() then
        self:Hide()
        self:Show()
    end
end

-- Grid2: header:ClearChildPoints()
function BFHeaderClass.prototype:ClearChildPoints()
    local count, uframe = 1, self:GetAttribute("child1")
    while uframe do
        uframe:ClearAllPoints()
        count = count + 1
        uframe = self:GetAttribute("child" .. count)
    end
end

-- ============================================================
-- 6. LAYOUT ENGINE
-- ============================================================

-- Header pool: groups[template] = { header1, header2, ... }
-- indexes[template] = how many from that pool are currently in use
BF.layoutGroups  = setmetatable({}, { __index = function(t,k) t[k]={}; return t[k] end })
BF.layoutIndexes = setmetatable({}, { __index = function() return 0 end })
BF.groupsUsed    = {}    -- ordered list of headers currently active (like Grid2.groupsUsed)

-- Per-CFG anchor frame pool. Each custom frame group gets its own persistent,
-- plain (non-secure) anchor frame, mirroring the raid BF.anchorFrame. The CFG
-- secure header is parented to it and pinned to the grow-derived corner, so
-- secondary-direction flips only change which corner pins (the anchor frame's
-- full-grid-sized rect stays put) — keeping the block in place exactly like raid.
BF.cfgAnchorFrames = {}  -- [groupIndex] = anchor frame
-- Per-pet-flat anchor frame pool — same purpose as cfgAnchorFrames but for pet
-- headers. Without it, grow-direction recompute read the 1x1 secure pet header's
-- geometry (all corners identical) and corrupted the saved position.
BF.petAnchorFrames = {}  -- [flatID] = anchor frame

-- Layout settings registry (like Grid2Layout.layoutSettings)
BF.layoutSettings = {}

-- Per-group filter table (like Grid2Layout.groupFilters)
BF.groupFilters = {
    { groupFilter = "1" }, { groupFilter = "2" }, { groupFilter = "3" }, { groupFilter = "4" },
    { groupFilter = "5" }, { groupFilter = "6" }, { groupFilter = "7" }, { groupFilter = "8" },
}

BF.groupsFilterStrings = { "1", "1,2", "1,2,3", "1,2,3,4", "1,2,3,4,5", "1,2,3,4,5,6", "1,2,3,4,5,6,7", "1,2,3,4,5,6,7,8" }

function BF:AddLayout(name, layout)
    self.layoutSettings[name] = layout
end

-- ── ResetHeaders (Grid2: ResetHeaders) ──────────────────────────
function BF:ResetHeaders()
    self.layoutHasAuto     = nil
    self.layoutHasDetached = nil
    -- Clear custom frame keybinds before resetting headers
    if self.ClearCustomFrameKeybinds then
        self:ClearCustomFrameKeybinds()
    end
    for groupType, headers in pairs(self.layoutGroups) do
        for i = self.layoutIndexes[groupType], 1, -1 do
            headers[i]:Reset()
        end
        self.layoutIndexes[groupType] = 0
    end
    wipe(self.groupsUsed)
end

-- ── AddHeader (Grid2: AddHeader) ────────────────────────────────
-- template: WoW secure template name (passed to CreateFrame)
-- poolKey:  optional internal pool key; defaults to template.
--           Use a separate poolKey (e.g. "CFGHeader") to give a
--           header category its own pool so it can be reset
--           independently of other categories sharing the same
--           WoW template.
function BF:AddHeader(dbx, defaults, setupIndex, template, poolKey)
    local wowTemplate = template or "SecureGroupHeaderTemplate"
    local groupType   = poolKey  or wowTemplate
    local index     = self.layoutIndexes[groupType] + 1
    local headers   = self.layoutGroups[groupType]
    local header    = headers[index]
    if not header then
        header = BFHeaderClass:New(wowTemplate)
        headers[index] = header
    end
    self.layoutIndexes[groupType] = index
    self.groupsUsed[#self.groupsUsed + 1] = header
    -- v53 Phase 2.1: FixHeaderAttributes (below) runs BEFORE
    -- AddCustomFrameHeaders can set header.isCustomFrame, and its
    -- ForceFramesCreation call is the one that builds the grid. Record the
    -- pool identity here so that call can size itself. Cleared by Reset().
    header._bf_isCFGHeader = (groupType == "CFGHeader") or nil

    -- Apply defaults then specific attributes (Grid2 pattern)
    self:SetHeaderAttributes(header, defaults)
    self:SetHeaderAttributes(header, dbx)
    -- Copy internal fields from dbx to the header object before
    -- FixHeaderAttributes runs, so it can read _classString etc.
    -- Grid2 pattern: SetHeaderProperties sets isDetached from dbx.detachHeader
    -- BEFORE SetupDetachedHeader runs, so the handle gets created.
    if dbx then
        header._classString = dbx._classString
        if dbx.detachHeader then
            header.isDetached = true
        end
        if dbx.isPetFrame then
            header.isPetFrame = true
            header.petFlatID  = dbx.petFlatID
        end
    end
    self:FixHeaderAttributes(header, #self.groupsUsed)
    -- Grid2 verbatim: SetupDetachedHeader is called at the end of every
    -- AddHeader. It's a no-op for non-detached headers.
    self:SetupDetachedHeader(header)
end

-- ── GenerateHeaders (Grid2: GenerateHeaders) ────────────────────
-- Grid2 pattern: when strictGroupLayout is off (the default Grid2 behavior),
-- layoutHasAuto is true and only instMaxGroup headers are created — so the
-- layout dynamically adjusts to the instance/raid size and empty trailing
-- groups simply don't get a header (units flow into the available columns).
-- When strictGroupLayout is on, all 8 group headers are always created so
-- every raid group occupies its own column even if it's empty.
function BF:GenerateHeaders(defaults, setupIndex)
    -- Sorting settings moved to rpDB.profile.sorting.* (or flat.sorting.*
    -- when the per-layout toggle is ON). Resolve via GetSectionProfile so
    -- per-layout overrides on the active raid flat are respected.
    local sortFlat = self._resolvedProfile or (self._contextIsRaid and self:GetRaidProfile() or self:GetActivePartyProfile())
    local sp = self:GetSectionProfile("sorting", sortFlat)
    local strict = sp and sp.strictGroupLayout
    self.layoutHasAuto = (not strict) or nil
    local maxGroups = (self.layoutHasAuto and self.instMaxGroup) or 8
    if not maxGroups or maxGroups < 1 then maxGroups = 8 end
    if maxGroups > 8 then maxGroups = 8 end
    for i = 1, maxGroups do
        self:AddHeader(self.groupFilters[i], defaults, setupIndex)
    end
end

-- ── SetHeaderAttributes (Grid2: SetHeaderAttributes) ────────────
function BF:SetHeaderAttributes(header, layoutAttrs)
    if layoutAttrs then
        for attr, value in next, layoutAttrs do
            if attr ~= "type" and attr ~= "meta"
               and attr:sub(1, 1) ~= "_" then  -- skip internal keys (_classString, etc.)
                header:SetAttribute(attr, value)
            end
        end
    end
end

-- ── FixHeaderAttributes (Grid2: FixHeaderAttributes) ────────────
-- Apply BuzzardFrames-specific fixes after all attributes are set
function BF:FixHeaderAttributes(header, index)
    local lp = self.rpDB.profile.layouts
    -- Pet headers need a minimal set of fixed attributes.
    -- Grid2 pattern: filterOnPet/useOwnerUnit make the header
    -- display pet units instead of player units.
    if header.isPetFrame then
        header:SetAttribute("filterOnPet",  true)
        header:SetAttribute("useOwnerUnit", false)
        header:SetAttribute("unitsuffix",   nil)
        header:SetAttribute("showRaid",  true)
        header:SetAttribute("showParty", true)
        -- showSolo is driven by the flat's petShowSolo toggle so pet
        -- headers can spawn the player's pet while solo when the user
        -- has "Show when Solo" enabled for this layout.
        local lpPet    = self.rpDB and self.rpDB.profile and self.rpDB.profile.layouts
        local flPet    = lpPet and lpPet.flatLayouts
        local flatPet  = header.petFlatID and flPet and flPet[header.petFlatID]
        header:SetAttribute("showSolo", (flatPet and flatPet.petShowSolo) and true or false)
        local petMaxCols, petUPC = self:GetPetGridDims(flatPet)
        header:SetAttribute("unitsPerColumn", petUPC)
        header:SetAttribute("maxColumns", petMaxCols)
        -- Resolve pet grow direction and set columnAnchorPoint/columnSpacing
        -- using the same pattern as the main raid headers below.
        local fl  = lp.flatLayouts
        local petFlat = header.petFlatID and fl and fl[header.petFlatID]
        local petDir = (petFlat and petFlat.petGrowDirection) or "DOWN"
        -- Normalize the secondary against the current primary axis so a stale
        -- cross-axis value can never change the derived corner (see
        -- GetNormalizedPetSecondary).
        local petSecDir = GetNormalizedPetSecondary(petFlat)
        local petH = (petDir == "RIGHT" or petDir == "LEFT")
        local petGA = DeriveGroupAnchor(petDir, petSecDir)
        header.cfgLayoutAnchor = petGA
        local petSpacing = (petFlat and petFlat.petFrameSpacing) or (lp.Padding or 0)
        if petH then
            header:SetAttribute("columnSpacing", petSpacing)
            header:SetAttribute("columnAnchorPoint", anchorToPoint[false][petGA])
        else
            header:SetAttribute("columnSpacing", petSpacing)
            header:SetAttribute("columnAnchorPoint", anchorToPoint[true][petGA])
        end
        self:UpdateFramesSizeForHeader(header)
        self:ForceFramesCreation(header)
        return
    end
    -- Sorting settings moved to rpDB.profile.sorting.* (or flat.sorting.*
    -- when per-layout toggle is ON). Resolve once so all subsequent reads
    -- see the right source.
    local _sortFlat = self._resolvedProfile or (self._contextIsRaid and self:GetRaidProfile() or self:GetActivePartyProfile())
    local sp = self:GetSectionProfile("sorting", _sortFlat)

    -- Ensure active headers have show* visibility attributes set.
    -- Reset() defaults these to false so pooled (unused) headers can't
    -- self-show via SecureGroupHeader_OnAttributeChanged.
    -- All active headers get true here; custom frame headers override
    -- these with their per-group settings in AddCustomFrameHeaders.
    header:SetAttribute("showRaid", true)
    header:SetAttribute("showParty", true)
    header:SetAttribute("showSolo", true)

    -- Fix unitsPerColumn (Grid2 pattern: honor layout's explicit value first,
    -- then profile, then fallback to 5).
    --
    -- Grid2 equivalent (GridLayout.lua ~line 677):
    --     local unitsPerColumn = header:GetAttribute("unitsPerColumn")
    --     if not unitsPerColumn then
    --         unitsPerColumn = p.unitsPerColumns[header.headerClass] or 5
    --         header:SetAttribute("unitsPerColumn", unitsPerColumn)
    --     end
    --
    -- BF adapts the profile read to its own schema: sp.unitsPerColumn is a
    -- single per-flat setting (not Grid2's per-header-class table). In GROUP
    -- sorting mode each header is a single raid group capped at 5, so 5 is
    -- forced regardless of the user's profile value — matching the cap
    -- expressed at Core_ProfileAPI.lua:64 and the five other call sites that
    -- read sp.unitsPerColumn throughout the codebase.
    --
    -- Prior to this, the function hardcoded `upc = 5` whenever the attribute
    -- was nil — which is always, because none of BF's built-in layouts
    -- ("By Group", "By Group Flowing", "By Role", "By Group & Role") set
    -- unitsPerColumn in their layout table. That silently ignored the user's
    -- Units Per Column setting in ROLE and flowing sorting modes.
    local upc = header:GetAttribute("unitsPerColumn")
    if not upc then
        if sp and sp.sortingMode == "GROUP" then
            upc = 5
        else
            upc = (sp and sp.unitsPerColumn) or 5
        end
        header:SetAttribute("unitsPerColumn", upc)
    end

    -- Grid2 pattern: set columnSpacing and columnAnchorPoint.
    -- Skip for custom frame headers — PlaceHeaders sets their
    -- columnSpacing and columnAnchorPoint based on cfGrowDirection.
    -- For main headers, derive from raidGrowDirection/party growDirection.
    if not header.isCustomFrame then
        local mainDir
        if self._contextIsParty then
            local ap = self._resolvedProfile or self:GetActivePartyProfile()
            -- Party growDirection moved to rpDB.profile.sorting.growDirection
            -- (or flat.sorting.growDirection when per-layout toggle is ON).
            local apSP = self:GetSectionProfile("sorting", ap)
            mainDir = apSP and apSP.growDirection or "RIGHT"
            if mainDir == "HORIZONTAL" then mainDir = "RIGHT" end
            if mainDir == "VERTICAL" then mainDir = "DOWN" end
        else
            mainDir = (sp and sp.raidGrowDirection) or "DOWN"
        end
        local mainH = (mainDir == "RIGHT" or mainDir == "LEFT")
        local secDir = (not self._contextIsParty) and (sp and sp.raidSecondaryGrowDirection) or nil
        local mainGA = DeriveGroupAnchor(mainDir, secDir)
        if mainH then
            header:SetAttribute("columnSpacing", lp.Padding or 0)
            header:SetAttribute("columnAnchorPoint", anchorToPoint[false][mainGA])
        else
            header:SetAttribute("columnSpacing", lp.Padding or 0)
            header:SetAttribute("columnAnchorPoint", anchorToPoint[true][mainGA])
        end
    end

    -- Fix maxColumns = "auto"
    if header:GetAttribute("maxColumns") == "auto" then
        self.layoutHasAuto = true
        header:SetAttribute("maxColumns",
            self:GetGridMaxColumns(upc, self.instMaxPlayers or GRID_MAX_UNITS))
    end
    -- Fix groupFilter = "auto"
    -- When FrameSort is active for this header, use nameList instead of
    -- groupFilter (same pattern as custom frame groups with nameList mode).
    -- nameList CANNOT coexist with groupFilter on SecureGroupHeaderTemplate.
    local gf = header:GetAttribute("groupFilter")
    if self:IsFrameSortActive() and not header.isCustomFrame and not header.isPetFrame then
        local nameList = self:BuildFrameSortNameList()
        if nameList then
            -- nameList is the sole filter — no groupFilter.
            header:SetAttribute("groupFilter", nil)
            header:SetAttribute("groupBy", nil)
            header:SetAttribute("groupingOrder", nil)
            header:SetAttribute("sortMethod", "NAMELIST")
            header:SetAttribute("nameList", nameList)
            gf = nil
        elseif gf == "auto" then
            -- FrameSort units not available yet — fall through to normal
            -- groupFilter. Sort() will switch to nameList later.
            self.layoutHasAuto = true
            gf = self.groupsFilterStrings[self.instMaxGroup or 8] or "1,2,3,4,5,6,7,8"
            header:SetAttribute("groupFilter", gf)
        end
    elseif gf == "auto" then
        self.layoutHasAuto = true
        gf = self.groupsFilterStrings[self.instMaxGroup or 8] or "1,2,3,4,5,6,7,8"
        header:SetAttribute("groupFilter", gf)
    end

    -- Grid2 pattern: when strictFiltering is set, append class names to
    -- groupFilter so the secure header's combined filter works.
    -- Custom frame headers store their class string in dbx._classString
    -- (set by GetCustomFrameHeaderDefs). For non-custom headers (e.g. the
    -- built-in "By Role" layout), we append all classes unconditionally
    -- (matching Grid2's FixHeaderAttributes behavior).
    if header:GetAttribute("strictFiltering") and gf then
        -- Only append if classes aren't already present (avoid double-appending)
        if not gf:find("DEATHKNIGHT") then
            local classStr = header._classString
            if not classStr or classStr == "" then
                -- Fallback: append all classes (Grid2 default behavior)
                classStr = "DEATHKNIGHT,DEMONHUNTER,DRUID,EVOKER,HUNTER,MAGE,MONK,PALADIN,PRIEST,ROGUE,SHAMAN,WARLOCK,WARRIOR"
            end
            gf = gf .. "," .. classStr
            header:SetAttribute("groupFilter", gf)
        end
    end

    -- Apply showGroup filtering to multi-group headers (e.g. By Role).
    -- Single-group headers (strict By Group) are handled by PlaceHeaders visibility.
    -- For comma-separated groupFilter strings, strip any disabled group numbers
    -- so the SecureGroupHeader never creates frames for those groups.
    -- Non-numeric tokens (class names from strictFiltering) are always preserved.
    if gf and self._contextIsRaid then
        local ap = self._resolvedProfile
        -- cap/sg together are the group visibility rule: Auto Hide Groups
        -- by Instance Size answers through cap, the per-group toggles
        -- through sg, and exactly one of the two is live.
        local cap, sg = self:GetGroupVisibilityRule(ap)
        if (sg or cap < 8) and gf:find(",") then
            local filtered = {}
            for token in gf:gmatch("[^,]+") do
                local gi = tonumber(token)
                if gi then
                    -- Numeric token = group number: apply the visibility rule
                    if gi <= cap and not (sg and sg[gi] == false) then
                        filtered[#filtered + 1] = token
                    end
                else
                    -- Non-numeric token = class name: always keep
                    filtered[#filtered + 1] = token
                end
            end
            local newGF = table.concat(filtered, ",")
            if newGF ~= "" and newGF ~= gf then
                header:SetAttribute("groupFilter", newGF)
            end
        end
    end

    -- (2026-08-24 dead-read removal: a raid-side groupingOrderOverride
    -- branch sat here reading a key nothing ever wrote — no setter, no
    -- default, absent from real SavedVariables. Party role ordering below
    -- is the live mechanism.)

    -- Party role ordering: apply groupOrderingMode when in party context.
    -- The "By Group" layout doesn't set groupBy/groupingOrder, so party
    -- frames default to index order. This applies the user's chosen role
    -- order from Frames - Sorting > Party Layout > Role Order.
    -- Skip when FrameSort is managing sort order (it sets nameList itself).
    if not (self:IsFrameSortActive() and not header.isCustomFrame) and self._contextIsParty and sp and sp.groupOrderingMode and not header:GetAttribute("nameList") then
        local mode = sp.groupOrderingMode
        local ORDER_MAP = {
            TANK_HEALER_DPS = "TANK,HEALER,DAMAGER,NONE",
            TANK_DPS_HEALER = "TANK,DAMAGER,HEALER,NONE",
            HEALER_TANK_DPS = "HEALER,TANK,DAMAGER,NONE",
            HEALER_DPS_TANK = "HEALER,DAMAGER,TANK,NONE",
            DPS_TANK_HEALER = "DAMAGER,TANK,HEALER,NONE",
            DPS_HEALER_TANK = "DAMAGER,HEALER,TANK,NONE",
        }
        local orderStr = ORDER_MAP[mode]
        if orderStr then
            header:SetAttribute("groupBy", "ASSIGNEDROLE")
            header:SetAttribute("groupingOrder", orderStr)
        elseif mode == "UNSORTED_NAME" then
            header:SetAttribute("sortMethod", "NAME")
        end
        -- UNSORTED_INDEX: default behavior, no attributes needed
    end

    -- Strict group layout: sort within each per-group header column.
    -- Only applies when strictGroupLayout is on and we're in raid context
    -- (each header has a single groupFilter like "1", "2", etc.).
    -- Skip when FrameSort is managing sort order.
    if not (self:IsFrameSortActive() and not header.isCustomFrame) and sp and sp.strictGroupLayout and self._contextIsRaid and sp.strictGroupSortBy then
        local sortBy = sp.strictGroupSortBy
        if sortBy == "NAME" then
            header:SetAttribute("sortMethod", "NAME")
        elseif sortBy == "ASSIGNEDROLE" then
            header:SetAttribute("groupBy", "ASSIGNEDROLE")
            header:SetAttribute("groupingOrder", "TANK,HEALER,DAMAGER,NONE")
            header:SetAttribute("sortMethod", "NAME")
        elseif sortBy == "CLASS" then
            header:SetAttribute("groupBy", "CLASS")
            header:SetAttribute("groupingOrder", "DEATHKNIGHT,DEMONHUNTER,DRUID,EVOKER,HUNTER,MAGE,MONK,PALADIN,PRIEST,ROGUE,SHAMAN,WARLOCK,WARRIOR")
            header:SetAttribute("sortMethod", "NAME")
        end
    end

    -- Size frames (Grid2: UpdateFramesSizeForHeader)
    --
    -- v86 PERF: a Custom Frame Group header reaches this line BEFORE
    -- ConfigureCustomFrameHeader has set header.isCustomFrame and the cf*
    -- size fields — AddHeader has to return first, and Reset() cleared both
    -- on the way in. _ResolveHeaderSizeAndScale branches on isCustomFrame
    -- alone, so this pass took its MAIN-header arm and sized the group's
    -- children to the active raid/party flat; ConfigureCustomFrameHeader
    -- then resolved the real cf size (raid40-baselined per
    -- GetCustomFrameBaseSize, so normally a different number) and called
    -- UpdateFramesSizeForHeader again. Both passes saw sizeChanged and
    -- dispatched frame:Layout() over every child, so a CFG header laid its
    -- whole pool out TWICE per LoadLayout at two different sizes — measured
    -- at ~145 ms of a 678 ms party<->raid flip for a single 15-child group,
    -- and it happened on every reload in every context, not just flips.
    --
    -- Skip the pass that cannot be correct, and with it the frame creation
    -- that depends on it: BuzzardFrame_GetInitialSize reads header.frameWidth
    -- with no fallback, so creating children before a sizing pass would hand
    -- BuzzardFramePrototype:Layout a nil width on a first-ever CFG header.
    -- ConfigureCustomFrameHeader does both, in this order, unconditionally
    -- (v86: hoisted out of its `if grp` arm for exactly this reason), so a
    -- CFG header is still sized and filled exactly once, from the right flat.
    -- Non-CFG headers are untouched.
    if header._bf_isCFGHeader and not header.isCustomFrame then
        return
    end

    -- Size frames (Grid2: UpdateFramesSizeForHeader)
    self:UpdateFramesSizeForHeader(header)

    -- Pre-create frames (Grid2: ForceFramesCreation)
    -- For a custom frame group THIS is the call that actually builds the
    -- child pool — the ForceFramesCreation calls further down in
    -- AddCustomFrameHeaders and ReloadCustomFrameHeadersOnly are no-ops by
    -- then because header.FrameCount already covers the full grid.
    self:ForceFramesCreation(header)
end

-- ── UpdateFramesSizeForHeader (Grid2 equivalent) ────────────────
-- Writes header.frameWidth/Height AND header:SetScale via
-- _ResolveHeaderSizeAndScale. Dimension + scale resolution is unified
-- here so the build path (FixHeaderAttributes → this) applies scale
-- BEFORE ForceFramesCreation triggers BuzzardFrame_Init's one-shot
-- frame:Layout(). This replaces the destructive post-LoadLayout
-- ResizeAllFrames sweep that wiped private aura anchors.
function BF:UpdateFramesSizeForHeader(header)
    local w, h, scale = self:_ResolveHeaderSizeAndScale(header)
    -- Hoisted out of the `if` unchanged, purely so the §L5.2 counter can
    -- tell "this header actually changed size" from "only _forceReload
    -- made us re-dispatch" -- the number §L3 6a lives or dies on.
    local sizeChanged = w ~= header.frameWidth
       or h ~= header.frameHeight
       or math.abs(scale - (header:GetScale() or 1)) > SCALE_EPSILON
    if sizeChanged or self._forceReload then
        header.frameWidth  = w
        header.frameHeight = h
        header:SetScale(scale)
        local swT0 = self._swActive and debugprofilestop() or nil
        for _, frame in ipairs(header) do
            frame:Layout()
        end
        if swT0 then
            local n = 0
            for _ in ipairs(header) do n = n + 1 end
            self:SwitchCountLayouts(n, sizeChanged, debugprofilestop() - swT0)
        end
        return true
    end
end

-- Fallback frame dimensions for custom frame groups. Primary CFG sizing
-- reads grp.flat (ConfigureCustomFrameHeader sets header.cfFrameWidth /
-- cfFrameHeight from it); this is consulted only when those are nil.
-- Phase L (owner ruling 2026-08-24): resolve from the seeded flat_raid40
-- flat -- CFGs are raid-typed, so the raid40 flat is the only sensible
-- default source -- with a hard 70 x 40 floor. The pre-flat
-- layouts.layouts[*] tier tables are gone; nothing may read them.
function BF:GetCustomFrameBaseSize()
    local lp = self.rpDB and self.rpDB.profile and self.rpDB.profile.layouts
    local flat = lp and lp.flatLayouts and lp.flatLayouts.flat_raid40
    -- flat_raid40 is metatable-wired (WireFlatDefaults), so un-customized
    -- keys resolve through its CreateRaidProfile template.
    local w = (flat and flat.frameWidth)  or 70
    local h = (flat and flat.frameHeight) or 40
    return w, h
end

-- Returns (w, h) for this header's frames based on current context.
-- Custom frame groups always baseline against raid40 sizes, not the current
-- context profile — so they don't bloat to party size when in a party.
function BF:GetFramesSizeForHeader(header)
    if header.isPetFrame then
        local lp  = self.rpDB and self.rpDB.profile and self.rpDB.profile.layouts
        local fl  = lp and lp.flatLayouts
        local flat = header.petFlatID and fl and fl[header.petFlatID]
        local w = (flat and flat.petFrameWidth)  or 65
        local h = (flat and flat.petFrameHeight) or 30
        return self:PixelRound(w), self:PixelRound(h)
    end
    if header.isCustomFrame then
        local defW, defH = self:GetCustomFrameBaseSize()
        local w = header.cfFrameWidth  or defW
        local h = header.cfFrameHeight or defH
        return self:PixelRound(w), self:PixelRound(h)
    end
    return self:ComputeFrameSize()
end

-- Precreate frames to avoid a blizzard bug that prevents initializing unit frames in combat
-- https://authors.curseforge.com/forums/world-of-warcraft/official-addon-threads/unit-frames/grid-grid2/222076-grid?page=159#c3169
--
-- Grid2 verbatim (GridLayout.lua ForceFramesCreation) — v53 Phase 2.1
-- right-sizing REVERTED (owner ruling 2026-08-23): the full
-- maxColumns x unitsPerColumn grid is built in ONE pass, on a header that
-- ends unconditionally Hide()n, exactly as Grid2 does. The v53 shape
-- (build only what the roster fills; BF:TopUpCustomHeaderFrames grows it
-- on GROUP_ROSTER_UPDATE) ran the startingIndex round trip on SHOWN
-- headers in the middle of the roster storm. Each round trip re-runs
-- SecureGroupHeader_Update twice, unassigning and reassigning every
-- child's unit at exactly the moment unit data can be unresolved — and a
-- unit assigned while UnitExists() is false is refused roster
-- registration (RegisterRosterUnit, Grid2 parity) and never gets its
-- per-unit events armed (field report: Dead text / Offline color+text /
-- range all frozen after initial paint). Grid2 never grows a header
-- mid-storm: creation happens once, hidden, at header bring-up, and every
-- bring-up caller (FinalizeCustomFrameHeader, PlaceHeaders) Shows the
-- header afterwards. Cost accepted with the revert: a CFG's first add
-- builds its whole grid in one pass again.
--
-- The v53 machinery that went with the right-sizing — the per-header
-- target count, the CFG_PRECREATE_* constants and the roster-driven
-- top-up sweep — was retired on 2026-09-14 (see
-- _to_delete/cfg_precreate_rightsizing_2026-09-14/). It had been dead
-- since the revert: this function ignored the count it was handed, so
-- every top-up pass found header.FrameCount already at the full grid and
-- did nothing.
function BF:ForceFramesCreation(header)
    -- §L5.1 headersBuilt drill-down: nil unless the harness is collecting.
    local hbT0 = self._loadHB and debugprofilestop() or nil
    local hbMade = 0
    local startingIndex  = header:GetAttribute("startingIndex")
    local maxColumns     = header:GetAttribute("maxColumns") or 1
    local unitsPerColumn = header:GetAttribute("unitsPerColumn") or 5
    local maxFrames      = maxColumns * unitsPerColumn
    local count          = header.FrameCount
    if not count or count < maxFrames then
        header:Show()
        header:SetAttribute("startingIndex", 1 - maxFrames)
        header:SetAttribute("startingIndex", startingIndex)
        header.FrameCount = maxFrames
        -- Grid2 verbatim: unconditional Hide. Creation now only happens at
        -- header bring-up (hidden phase); the bring-up callers Show after.
        header:Hide()
        hbMade = maxFrames - (count or 0)
        -- v75: the v73 idle warm-up arm that lived here is GONE — children
        -- are built eagerly in their own BuzzardFrame_Init again (see the
        -- v75 block there; owner ruling restoring pre-v72 behavior after
        -- the deferral broke combat reloads), so a fresh child has nothing
        -- left to warm. The warm-up machinery itself remains in
        -- ContainerFactory.lua: the v74 relevance-change sweep still hands
        -- newly-relevant SPARE rebuilds to it, and those are tiny.
    end
    -- Classic only: children created above got no initialConfigFunction (the
    -- attribute is unset there), so configure them from Lua now. Runs
    -- unconditionally rather than inside the branch above so that a header
    -- which grew children outside this pass still gets swept on the next
    -- bring-up. Returns immediately on retail, where the secure snippet
    -- already configured every child at creation time.
    -- Evidence check: if the secure snippet was supposed to configure the
    -- children but any unit button came out unconfigured, snippets don't
    -- compile on this client. Fall back to the Lua path for good.
    if BF.canCompileSnippets then
        local prefix = header:GetName()
        for _, child in ipairs({ header:GetChildren() }) do
            local name = child.IsObjectType and child:IsObjectType("Button") and child:GetName()
            if name and prefix and name:find(prefix, 1, true) == 1 and not child._bfConfigured then
                DisableSecureInit()
                break
            end
        end
    end
    ConfigureNewChildrenInsecure(header)

    if hbT0 then
        self:LoadHBHeader(header, hbMade, debugprofilestop() - hbT0)
    end
end

-- ── PlaceHeaders (Grid2: PlaceHeaders) ──────────────────────────
-- Modified to handle detached headers separately, mirroring Grid2's
-- PlaceHeaders which iterates non-detached headers first (chained
-- together in the main anchor), then detached headers (independently
-- positioned).
function BF:PlaceHeaders()
    local ap = self._resolvedProfile
    if not ap then
        ap = self._contextIsRaid and self:GetRaidProfile() or self:GetActivePartyProfile()
    end
    -- Sorting settings moved to rpDB.profile.sorting.* (or flat.sorting.*
    -- when per-layout toggle is ON). `ap` is already the active flat, so
    -- pass it as the routing hint.
    local sp = self:GetSectionProfile("sorting", ap)

    -- Group visibility rule, resolved ONCE for the whole placement pass.
    -- Hoisted rather than asked per header because the Auto Hide arm calls
    -- GetInstanceInfo, and the header loop below runs up to eight times.
    local vgCap, vgShow = self:GetGroupVisibilityRule(ap)

    local horizontal
    local mainGrowDir  -- grow direction string for main (non-custom) headers
    if self._contextIsParty then
        local dir = (sp and sp.growDirection) or "RIGHT"
        -- Migration: old profiles may still have "HORIZONTAL"/"VERTICAL"
        if dir == "HORIZONTAL" then dir = "RIGHT" end
        if dir == "VERTICAL" then dir = "DOWN" end
        mainGrowDir = dir
        horizontal = (dir == "RIGHT" or dir == "LEFT")
    else
        mainGrowDir = (sp and sp.raidGrowDirection) or "DOWN"
        horizontal = (mainGrowDir == "RIGHT" or mainGrowDir == "LEFT")
    end
    -- Derive groupAnchor for columnAnchorPoint using DeriveGroupAnchor
    local secondaryGrowDir
    if not self._contextIsParty then
        secondaryGrowDir = sp and sp.raidSecondaryGrowDirection
    end
    local mainGroupAnchor = DeriveGroupAnchor(mainGrowDir, secondaryGrowDir)
    self._mainGroupAnchor = mainGroupAnchor  -- stash for UpdateSize

    -- Compute spacing from the resolved profile (Grid2: reads from settings directly)
    local spacingH, spacingV
    if self._contextIsRaid then
        spacingH = self:PixelSnap(ap.frameSpacingH or 0)
        spacingV = self:PixelSnap(ap.frameSpacingV or 0)
    else
        local sp = ap.frameSpacing or 0
        spacingH = self:PixelSnap(sp)
        spacingV = spacingH
    end

    -- Compute header scale from the resolved profile
    local headerScale = self:ComputeHeaderScale()

    -- Restore anchor position FIRST (Grid2: RestorePosition)
    self:RestorePosition()

    -- ── Pass 1: Non-detached headers (chained in main anchor) ────
    -- Grid2 pattern: anchor the first header to the groupAnchor corner of
    -- the anchor frame, then chain subsequent headers using relativePoints.
    -- The grid grows naturally from the anchor corner — no manual pixel
    -- offset computation needed.
    local relPoint = relativePoints[not horizontal][mainGroupAnchor]
    local prevFrame
    for i, header in self:IterateDetachedHeaders(false) do
        -- Reparent to anchor frame
        header:SetParent(self.anchorFrame or UIParent)
        header:SetScale(headerScale)

        -- SetOrientation with the actual grow direction
        local padding = horizontal and spacingH or spacingV
        header:SetOrientation(horizontal, padding, mainGrowDir)
        -- Clear any stale sortDir
        header:SetAttribute("sortDir", nil)
        -- Column layout
        if horizontal then
            header:SetAttribute("columnAnchorPoint", anchorToPoint[false][mainGroupAnchor])
            header:SetAttribute("columnSpacing", spacingV)
        else
            header:SetAttribute("columnAnchorPoint", anchorToPoint[true][mainGroupAnchor])
            header:SetAttribute("columnSpacing", spacingH)
        end

        -- Chain headers using mainGroupAnchor (Grid2 pattern).
        -- First header: anchor to the groupAnchor corner of the anchor frame.
        -- Subsequent headers: chain using relativePoints with perpendicular
        -- spacing so frameSpacingH (vertical grow) or frameSpacingV
        -- (horizontal grow) controls the gap between group columns/rows.
        local chainOffX, chainOffY = 0, 0
        if horizontal then
            if mainGroupAnchor == "TOPLEFT" or mainGroupAnchor == "TOPRIGHT" then
                chainOffY = -spacingV
            else
                chainOffY = spacingV
            end
        else
            if mainGroupAnchor == "TOPLEFT" or mainGroupAnchor == "BOTTOMLEFT" then
                chainOffX = spacingH
            else
                chainOffX = -spacingH
            end
        end
        header:ClearAllPoints()
        if not prevFrame then
            header:SetPoint(mainGroupAnchor, self.anchorFrame or UIParent, mainGroupAnchor, 0, 0)
        else
            header:SetPoint(mainGroupAnchor, prevFrame, relPoint, chainOffX, chainOffY)
        end

        -- Visibility: hide empty group headers so they take no space.
        -- Beyond vgCap: Auto Hide Groups by Instance Size -- the instance
        --   cannot fill this group (e.g. group 7 in a 30-man raid).
        -- vgShow=false: user explicitly disabled the group.
        -- GetPopulatedGroups: no raid members in that group → collapse.
        -- Headers are re-shown by ReanchorGroupHeaders (debounced from
        -- GROUP_ROSTER_UPDATE) when a unit joins an empty group.
        local visible = true
        if self._contextIsRaid then
            local gf = header:GetAttribute("groupFilter")
            local gi = gf and tonumber(gf)
            if gi then
                if gi > vgCap or (vgShow and vgShow[gi] == false) then
                    visible = false
                end
            end
        end

        if visible then
            header:Show()
            header:Update()  -- force SecureGroupHeader_Update → OnAttributeChanged on children
            prevFrame = header
        else
            header:Hide()
        end
    end

    -- ── Pass 2: Detached headers (independently positioned) ──────
    -- Grid2 equivalent: the second loop in PlaceHeaders that iterates
    -- IterateHeaders(true) and calls RestoreHeaderPosition on each.
    for i, header in self:IterateDetachedHeaders(true) do
        -- Check showParty/showRaid visibility for the current context.
        -- If the header shouldn't be shown, hide it and its handle, then skip.
        local showForContext = true
        if self._contextIsParty and not header:GetAttribute("showParty") then
            showForContext = false
        elseif self._contextIsRaid and not header:GetAttribute("showRaid") then
            showForContext = false
        end
        if not showForContext then
            header:Hide()
            if header._handle then header._handle:Hide() end
        else

        -- Custom frame groups are parented to UIParent directly so they remain
        -- visible even when the main anchorFrame is hidden (e.g. global party/raid
        -- frames toggled off). Pet headers do the same so their effective scale
        -- is applied exactly once (the pet header's own SetScale) rather than
        -- being multiplied by the anchor's scale — which caused visible drift
        -- whenever the party frameScale slider moved. Other detached headers
        -- follow the anchor.
        if header.isCustomFrame then
            -- Parent CFG headers to their own persistent anchor frame (raid
            -- parity). The anchor frame stays at scale 1.0 (never SetScale'd),
            -- so parenting to it is scale-neutral like UIParent — no scale
            -- drift — while giving the header a stable corner to pin to.
            local af = self:GetOrCreateCFGAnchorFrame(header.customGroupIndex)
            header:SetParent(af or UIParent)
        elseif header.isPetFrame then
            -- Parent to the pet anchor frame (scale-1.0, scale-neutral like
            -- UIParent) so the header pins to a stable corner.
            local af = self:GetOrCreatePetAnchorFrame(header.petFlatID)
            header:SetParent(af or UIParent)
        else
            header:SetParent(self.anchorFrame or UIParent)
        end

        -- Per-group scale and spacing overrides for custom frame groups
        local cfScale   = headerScale
        local cfSpacingH = spacingH
        local cfSpacingV = spacingV
        if header.isCustomFrame then
            if header.cfEnableFrameScale and header.cfFrameScale then
                local cfS  = header.cfFrameScale
                local cfSI = header.cfScaleIndicators ~= false
                if cfSI then
                    -- Scale indicators: apply scale to the header, frames stay natural size
                    local cfDefW, cfDefH = self:GetCustomFrameBaseSize()
                    local w = header.cfFrameWidth  or cfDefW
                    local h = header.cfFrameHeight or cfDefH
                    -- v93: shared device-pixel snap (see BF:SnapScaleForSize). This
                    -- extent math must resolve the SAME scale the header actually
                    -- gets in _ResolveHeaderSizeAndScale, or the computed region
                    -- disagrees with what is drawn.
                    cfScale = self:SnapScaleForSize(cfS, w, h)
                else
                    -- Don't scale indicators: header stays at 1.0, frame dimensions absorb the scale
                    cfScale = 1.0
                end
            end
            if header.cfFrameSpacingH then cfSpacingH = self:PixelSnap(header.cfFrameSpacingH) end
            if header.cfFrameSpacingV then cfSpacingV = self:PixelSnap(header.cfFrameSpacingV) end
        elseif header.isPetFrame then
            -- Scale pet headers exactly like custom frame groups are scaled
            -- above: start at 1.0 and only apply a scale when the flat's
            -- enableFrameScale/frameScale pair is set. petFlat is the active
            -- party flat, so the party's scale slider drives pet sizing the
            -- same way the custom group's own slider drives its frames.
            cfScale = 1.0
            local lp2  = self.rpDB and self.rpDB.profile and self.rpDB.profile.layouts
            local fl2  = lp2 and lp2.flatLayouts
            local petFlat = header.petFlatID and fl2 and fl2[header.petFlatID]
            if petFlat and petFlat.enableFrameScale and petFlat.frameScale then
                local cfS  = petFlat.frameScale
                local cfSI = petFlat.scaleIndicators ~= false
                if cfSI then
                    local w = petFlat.petFrameWidth  or 65
                    local h = petFlat.petFrameHeight or 30
                    -- v93: shared device-pixel snap (see BF:SnapScaleForSize). This
                    -- extent math must resolve the SAME scale the header actually
                    -- gets in _ResolveHeaderSizeAndScale, or the computed region
                    -- disagrees with what is drawn.
                    cfScale = self:SnapScaleForSize(cfS, w, h)
                else
                    cfScale = 1.0
                end
            end
        end

        -- Custom frames and pet frames use their own grow direction.
        -- Derive horizontal flag and groupAnchor (for columnAnchorPoint) from direction.
        --   DOWN  → vertical,   anchor TOPLEFT    (columns→LEFT)
        --   UP    → vertical,   anchor BOTTOMLEFT (columns→LEFT)
        --   RIGHT → horizontal, anchor TOPLEFT    (rows→TOP)
        --   LEFT  → horizontal, anchor TOPRIGHT   (rows→TOP)
        local cfHorizontal = horizontal
        local cfGroupAnchor = "TOPLEFT"
        local cfGrowDir  -- passed to SetOrientation
        if header.isCustomFrame then
            local dir = header.cfGrowDirection
            cfHorizontal = (dir == "RIGHT" or dir == "LEFT")
            cfGrowDir = dir
            cfGroupAnchor = DeriveGroupAnchor(dir, header.cfSecondaryGrowDirection)
        elseif header.isPetFrame then
            -- Same pattern as custom frame groups, plus secondary grow direction.
            local lp2  = self.rpDB and self.rpDB.profile and self.rpDB.profile.layouts
            local fl2  = lp2 and lp2.flatLayouts
            local petFlat = header.petFlatID and fl2 and fl2[header.petFlatID]
            local dir = petFlat and petFlat.petGrowDirection
            if not dir then dir = mainGrowDir end
            -- Normalize the secondary against the EFFECTIVE primary axis (dir,
            -- which may fall back to mainGrowDir) so a stale cross-axis value
            -- can never change the derived corner (see GetNormalizedPetSecondary).
            local petSecDir = GetNormalizedPetSecondary(petFlat, dir)
            cfHorizontal = (dir == "RIGHT" or dir == "LEFT")
            cfGrowDir = dir
            cfGroupAnchor = DeriveGroupAnchor(dir, petSecDir)
            -- Stored-anchor corner tracks the grow-derived anchor so
            -- SaveDetachedHeaderPosition stores the matching corner.
            header.cfgLayoutAnchor = cfGroupAnchor
            -- Pet spacing: read from flat, fall back to main layout spacing.
            local petSpacing = petFlat and petFlat.petFrameSpacing
            if petSpacing then
                local snapped = self:PixelSnap(petSpacing)
                cfSpacingH = snapped
                cfSpacingV = snapped
            end
        end
        header:SetScale(cfScale)
        local cfPadding = cfHorizontal and cfSpacingH or cfSpacingV
        header:SetOrientation(cfHorizontal, cfPadding, cfGrowDir)
        -- Grid2 pattern: columnAnchorPoint from anchorToPoint[opposite orientation][groupAnchor]
        -- Vertical grow: columns go sideways. Horizontal grow: rows stack vertically.
        if cfHorizontal then
            header:SetAttribute("columnAnchorPoint", anchorToPoint[false][cfGroupAnchor])
            header:SetAttribute("columnSpacing", cfSpacingV)
        else
            header:SetAttribute("columnAnchorPoint", anchorToPoint[true][cfGroupAnchor])
            header:SetAttribute("columnSpacing", cfSpacingH)
        end

        -- Stamp the grow-derived anchor and size the CFG anchor frame to the
        -- full grid BEFORE positioning, so RestoreDetachedHeaderPosition pins
        -- the header to a stable corner (raid parity).
        if header.isCustomFrame then
            header.cfgLayoutAnchor = cfGroupAnchor
            self:UpdateCFGAnchorFrameSize(header.customGroupIndex)
        elseif header.isPetFrame then
            header.cfgLayoutAnchor = cfGroupAnchor
            self:UpdatePetAnchorFrameSize(header.petFlatID)
        end

        -- Set header size to the computed bounding box so that
        -- SaveDetachedHeaderPosition reads correct geometry on drag.
        if header.isCustomFrame and header.frameWidth and header.frameHeight then
            local bbMaxCols = header:GetAttribute("maxColumns") or 8
            local bbUPC     = header:GetAttribute("unitsPerColumn") or 5
            local bbW, bbH
            if cfHorizontal then
                bbW = bbUPC * header.frameWidth     + math.max(0, bbUPC - 1)     * cfSpacingH
                bbH = bbMaxCols * header.frameHeight + math.max(0, bbMaxCols - 1) * cfSpacingV
            else
                bbW = bbMaxCols * header.frameWidth  + math.max(0, bbMaxCols - 1) * cfSpacingH
                bbH = bbUPC * header.frameHeight     + math.max(0, bbUPC - 1)     * cfSpacingV
            end
            header:SetSize(bbW, bbH)
        end

        if not self:RestoreDetachedHeaderPosition(header) then
            -- No saved position. Pet headers use the flat's petFrameAnchorX/Y
            -- as the initial position. Other detached headers default to CENTER.
            local initX, initY = 0, 0
            if header.isPetFrame then
                local lp = self.rpDB and self.rpDB.profile and self.rpDB.profile.layouts
                local flat = header.petFlatID and lp and lp.flatLayouts and lp.flatLayouts[header.petFlatID]
                initX = (flat and flat.petFrameAnchorX) or 0
                initY = (flat and flat.petFrameAnchorY) or -300
            end
            if header.isCustomFrame then
                -- CFG headers are parented to their anchor frame, so SetPoint'ing
                -- the header to UIParent here would be anchor-frame-relative
                -- (mis-placed). Instead seed the ANCHOR FRAME's position to the
                -- default and pin the header to its corner, matching the
                -- saved-position path so there's no transient misalignment.
                local af = self:GetOrCreateCFGAnchorFrame(header.customGroupIndex)
                local laC = header.cfgLayoutAnchor or "TOPLEFT"
                if af then
                    af:ClearAllPoints()
                    af:SetPoint(laC, UIParent, "CENTER", initX, initY)
                    header:ClearAllPoints()
                    header:SetPoint(laC, af, laC, 0, 0)
                    header:Show()
                    C_Timer.After(0, function()
                        self:SaveDetachedHeaderPosition(header)
                        self:RestoreDetachedHeaderPosition(header)
                    end)
                end
            else
                header:ClearAllPoints()
                header:SetClampedToScreen(true)
                header:SetPoint("CENTER", UIParent, "CENTER", initX, initY)
                header:Show()
                C_Timer.After(0, function()
                    self:SaveDetachedHeaderPosition(header)
                    self:RestoreDetachedHeaderPosition(header)
                    header:SetClampedToScreen(false)
                end)
            end
        end

        header:Show()
        header:Update()

        -- Force SecureGroupPetHeader_Update to re-run configureChildren
        -- with the final correct attributes. Pet headers don't have an
        -- OnShow handler, so Show()/Update() alone won't trigger a
        -- child re-layout. Touching an attribute while visible forces
        -- OnAttributeChanged → SecureGroupPetHeader_Update.
        if header.isPetFrame then
            header:SetAttribute("_forceUpdate", not header:GetAttribute("_forceUpdate"))
        end

        -- Show/hide the drag handle based on lock state
        if header._handle then
            local locked = self.db.global.locked
            if locked == nil then locked = true end
            if not locked then
                header._handle:Show()
                if header._handle.SnapToParent then header._handle.SnapToParent() end
            else
                header._handle:Hide()
            end
        end

        end -- close showForContext else block
    end
end

-- ── UpdateSize (Grid2: UpdateSize) ─────────────────────────────
-- Measure the bounding box of all non-detached headers and resize
-- anchorFrame to match.  This is critical so that the groupAnchor
-- corner of anchorFrame is at the correct screen position — when
-- the user switches grow directions the grid stays in place because
-- the first header attaches to a different corner of the same
-- sized rectangle.
function BF:UpdateSize()
    -- PERF (v92): the function's ONLY side effect (af:SetSize at the bottom)
    -- was already combat-guarded — but the guard wrapped just the write, so
    -- every mid-combat GROUP_ROSTER_UPDATE still paid the full header walk
    -- (GetLeft/Right/Top/Bottom per header), the sorting-section resolve, and
    -- GetConfiguredGridExtent's scale/pixel math, then threw the result away.
    -- Bail up front: PLAYER_REGEN_ENABLED re-runs UpdateSize as the combat
    -- catch-up (Initialization.lua), so nothing is lost.
    if InCombatLockdown() then return end
    local af = self.anchorFrame
    if not af then return end
    local anchor = self._mainGroupAnchor or "TOPLEFT"
    -- Seed the bounding box from the groupAnchor corner of the frame
    -- (Grid2 pattern: start from the anchor corner, expand outward).
    local x1 = anchor:find("LEFT") and af:GetLeft() or af:GetRight()
    local y1 = anchor:find("TOP")  and af:GetTop()  or af:GetBottom()
    if not x1 or not y1 then return end  -- frame not yet on screen
    local x2, y2 = x1, y1
    for _, header in self:IterateDetachedHeaders(false) do
        if header[1] and header[1]:IsVisible() then
            local l, r, t, b = header:GetLeft(), header:GetRight(), header:GetTop(), header:GetBottom()
            if l and r and t and b then
                -- The headers are SCALED (header:SetScale(headerScale) in
                -- PlaceHeaders) and the anchor frame is not, so their edges
                -- come back in HEADER units while the seed above is in
                -- UIParent units. Mixing the two inflated the box by
                -- 1/headerScale: in Grow from Center that off-centered the
                -- block (the centered axis is sized to this measurement),
                -- and in corner mode the inflated content beat the real
                -- grid in the max() below, leaving the region the grow
                -- conversions read too big. Converted, not compared raw.
                l = self:ToUIUnits(l, header)
                r = self:ToUIUnits(r, header)
                t = self:ToUIUnits(t, header)
                b = self:ToUIUnits(b, header)
                x1 = math.min(x1, l)
                x2 = math.max(x2, r)
                y1 = math.max(y1, t)
                y2 = math.min(y2, b)
            end
        end
    end
    local width  = math.max(x2 - x1, 1)
    local height = math.max(y1 - y2, 1)

    -- Party: size as if a full group of 5 is present so that grow-direction
    -- changes work correctly even when solo (anchor frame corners stay at
    -- the positions they would occupy with a full party).
    if self._contextIsParty then
        local ap = self._resolvedProfile or self:GetActivePartyProfile()
        if ap then
            local sp = self:GetSectionProfile("sorting", ap)
            -- Grow from Center: size to the ACTUAL content bounding box
            -- (Grid2 CENTER parity). The full-5 sizing below exists so
            -- corner-anchored grow-direction changes stay in place; with
            -- a CENTER pin it would leave sub-5 parties off-center.
            -- (Setup mode included: the preview box and the real box are
            -- both centered on the pin, so they align by CENTER - with
            -- fewer than 5 real members the real frames sit centered
            -- under the middle of the 5-frame preview, exactly like a
            -- Grid2 CENTER layout with a different test unit count.)
            local centerMode = sp and sp.growFromCenter
            -- Shared with the Grow from Center anchor conversions — see
            -- GetConfiguredGridExtent above (divergence = drift bugs).
            local fullW, fullH = self:GetConfiguredGridExtent(ap, true)
            if not centerMode then
                width  = math.max(width,  fullW)
                height = math.max(height, fullH)
            end
            -- Grow from Center (party): the anchor is a full CENTER pin, so
            -- both axes stay content-sized — the block centers on both axes
            -- (grow axis is what matters; the single-frame cross axis centers
            -- harmlessly). A sub-5 party sits centered on the pin, exactly the
            -- pre-edge-anchor behavior. (Raid uses the axis-selective sizing
            -- below because it edge-pins the grow axis.)
        end
    end

    -- Raid: size based on the number of enabled groups so that the anchor
    -- frame corners stay correct even when some groups are empty. Without
    -- this, changing secondary grow direction to LEFT (anchor TOPRIGHT)
    -- positions based on populated groups rather than configured groups.
    if self._contextIsRaid then
        local ap = self._resolvedProfile or self:GetRaidProfile()
        if ap then
            local sp = self:GetSectionProfile("sorting", ap)
            -- Raid Grow from Center: size to the ACTUAL content bounding
            -- box (party parity) — the full-grid sizing below keeps the
            -- corner-pinned box stable across empty groups, but with a
            -- CENTER pin it would leave partial raids off-center.
            local raidCenterMode = sp and sp.raidGrowFromCenter
            local dir   = (sp and sp.raidGrowDirection) or "DOWN"
            local isH   = (dir == "RIGHT" or dir == "LEFT")
            -- Full-grid extent: GROUP mode gives each enabled group its own
            -- column of 5; ROLE/flowing mode derives columns from total
            -- units and unitsPerColumn. Shared with the Grow from Center
            -- anchor conversions — see GetConfiguredGridExtent above
            -- (divergence = drift bugs).
            local fullW, fullH = self:GetConfiguredGridExtent(ap, false)
            if not raidCenterMode then
                width  = math.max(width,  fullW)
                height = math.max(height, fullH)
            else
                -- Grow from Center: center ONLY the cross-axis. The grow-axis
                -- edge (TOP for DOWN, LEFT for RIGHT, ...) stays fixed, so the
                -- grow-axis extent must be the FULL grid — otherwise a lone
                -- frame collapses that axis and the block re-centers on it
                -- (e.g. solo raid member jumping to vertical center with grow
                -- DOWN). The cross-axis stays content-sized so it centers
                -- tightly. Grid2 anchors by the TOP/BOTTOM or LEFT/RIGHT edge
                -- (GridLayout.lua:109-111) for exactly this reason.
                if isH then
                    -- horizontal grow: width is the grow axis.
                    width  = math.max(width, fullW)
                else
                    -- vertical grow: height is the grow axis.
                    height = math.max(height, fullH)
                end
            end
        end
    end

    if not InCombatLockdown() then
        -- Change-guarded + pixel-rounded: UpdateSize can be called from
        -- several layout paths in a row; identical dimensions must not
        -- re-fire SetSize (a CENTER-pinned anchor moves its own corners
        -- on every resize, so ungated float jitter would cascade into
        -- header re-anchoring on each call).
        width  = self:PixelRound(width)
        height = self:PixelRound(height)
        local ow, oh = af:GetWidth(), af:GetHeight()
        -- v93: half a GRID STEP, not a hard-coded 0.5. One device pixel is
        -- under 0.5 UI units on any display taller than 1536px at UI scale 1
        -- (every 1440p and 4K setup), so the old literal was wider than a
        -- real size change and silently dropped it -- leaving the anchor
        -- frame with a stale rect that the corner-pinned grow-direction math
        -- then reads as the region extent.
        local eps = self:PixelsToUI(1) * 0.5
        if not ow or math.abs(ow - width) > eps or math.abs(oh - height) > eps then
            af:SetSize(width, height)
        end
    end
end

-- ── GetConfiguredGridExtent ─────────────────────────────────────
-- Width/height of the FULL configured grid (the REGION a corner-anchored
-- layout occupies), in anchorFrame/UIParent units — the exact fullW/fullH
-- UpdateSize computes, extracted so the Grow from Center anchor
-- conversions in Options_Frames_Sorting.lua use IDENTICAL math (UpdateSize
-- calls this too; divergence between the two was the toggle-drift bug
-- class).
--
-- Why the conversions need it: the Grow from Center semantics are
-- REGION-invariant — the configured full-grid region stays pinned and the
-- frames rearrange within it (owner-confirmed 2026-08-16: setup mode,
-- whose test anchor is always full-grid sized, is the reference
-- behavior). In live center mode UpdateSize deliberately sizes the
-- anchorFrame's CROSS-axis to the content, so the anchor box's cross-axis
-- edges are CONTENT edges — an OFF conversion reading them re-based the
-- region at the content's own position (frames visibly did nothing, and
-- the region walked sideways one half-gap per toggle cycle). The region's
-- cross-axis edges must instead be computed as pin ± extent/2 from this
-- function.
-- dirOverride: compute the extent for this grow direction instead of the
-- stored one — used by the grow-direction setters, whose conversion needs
-- the extent of the OLD region (the box currently on screen) after the new
-- direction has already been written to the profile.
-- Frame dimensions and the header multiplier, resolved the way the RENDERER
-- resolves them -- because there are TWO scale models and this function used
-- to know only one.
--
--   Apply Scale to Indicators ON   the header is scaled and the frames keep
--                                  their configured size; the multiplier
--                                  carries the scale (and the spacing with
--                                  it, since the header scales everything
--                                  under it).
--   OFF                            the header stays at 1.0 and the SIZE
--                                  absorbs the scale; spacing is NOT scaled.
--
-- ComputeHeaderScale returns exactly 1.0 in the OFF case (see its `if not si
-- then return 1.0`), so the old `PixelRound(w) * ComputeHeaderScale(ap)`
-- described the UNSCALED grid there -- a configured extent that did not match
-- anything on screen. Everything downstream inherited that: the
-- Grow-from-Center conversion wrote a corner from the wrong half-extent,
-- UpdateSize floored the anchor frame's rect at the wrong width, and because
-- setup mode's test anchor IS sized correctly (SetupMode bakes the scale into
-- layoutW), the options page read one rectangle with setup mode open and a
-- different one with it closed, and repeated toggling walked the block across
-- the screen. Both models now come from here, so they cannot disagree.
--
-- The renderer's own copies of this branch: _ResolveHeaderSizeAndScale
-- (main, custom-frame and pet headers) and SetupMode's CreateRaidTestFrames /
-- party twin.
--
-- The DIMENSIONS are passed in rather than read off the flat: the scale flags
-- live under the same three keys for every block, but a pet block is sized by
-- petFrameWidth/petFrameHeight and a custom frame group may take its size from
-- a different flat than the one carrying the flags. The caller knows which
-- pair it means; this only knows what to do with them.
--
-- SnapScaleForSize rather than ComputeHeaderScale for the same reason -- the
-- latter re-reads frameWidth/frameHeight off the profile, which is the wrong
-- pair for pets -- and it is the call the renderer itself makes.
function BF:_ExtentFrameMetrics(ap, rawW, rawH)
    local scale, si = 1.0, true
    if ap.enableFrameScale then
        scale = ap.frameScale or 1.0
        si    = ap.scaleIndicators ~= false
    end
    if si then
        return self:PixelRound(rawW), self:PixelRound(rawH),
               self:SnapScaleForSize(scale, rawW, rawH)
    end
    return self:PixelRound(rawW * scale), self:PixelRound(rawH * scale), 1.0
end

function BF:GetConfiguredGridExtent(ap, isParty, dirOverride)
    if not ap then return nil end
    local sp = self:GetSectionProfile("sorting", ap)
    if isParty then
        local dir = dirOverride or (sp and sp.growDirection) or "RIGHT"
        if dir == "HORIZONTAL" then dir = "RIGHT" end
        if dir == "VERTICAL" then dir = "DOWN" end
        local fw, fh, scale = self:_ExtentFrameMetrics(ap,
            ap.frameWidth or 100, ap.frameHeight or 70)
        local fs = self:PixelSnap(ap.frameSpacing or 0)
        if dir == "RIGHT" or dir == "LEFT" then
            return (fw * 5 + fs * 4) * scale, fh * scale
        end
        return fw * scale, (fh * 5 + fs * 4) * scale
    end
    local dir   = dirOverride or (sp and sp.raidGrowDirection) or "DOWN"
    local isH   = (dir == "RIGHT" or dir == "LEFT")
    local fw, fh, scale = self:_ExtentFrameMetrics(ap,
        ap.frameWidth or 70, ap.frameHeight or 40)
    local spH   = self:PixelSnap(ap.frameSpacingH or 0)
    local spV   = self:PixelSnap(ap.frameSpacingV or 0)
    local isGroup = sp and sp.sortingMode == "GROUP"
    local upc   = isGroup and 5 or (sp and sp.unitsPerColumn or 5)
    -- Same visibility rule the headers themselves use, so the configured
    -- extent (the setup-mode outline, the anchor's full-grid box) matches
    -- what actually renders under Auto Hide Groups by Instance Size.
    local cap, sg = self:GetGroupVisibilityRule(ap)
    local enabledGroups = 0
    for g = 1, 8 do
        if g <= cap and not (sg and sg[g] == false) then
            enabledGroups = enabledGroups + 1
        end
    end
    local totalUnits = enabledGroups * 5
    local numColumns
    if isGroup then
        numColumns = enabledGroups
    else
        numColumns = math.ceil(totalUnits / upc)
    end
    local gridCols, gridRows
    if isH then
        gridCols = upc
        gridRows = numColumns
    else
        gridRows = upc
        gridCols = numColumns
    end
    local fullW = (gridCols * fw + math.max(0, gridCols - 1) * spH) * scale
    local fullH = (gridRows * fh + math.max(0, gridRows - 1) * spV) * scale
    return fullW, fullH
end

-- ── Per-CFG anchor frames ───────────────────────────────────────
-- Each custom frame group gets its own persistent plain anchor frame,
-- mirroring BF.anchorFrame for raid. The CFG secure header is parented
-- to it and pinned to the grow-derived corner, so secondary-direction
-- flips only change which corner pins; the anchor frame's full-grid
-- rect stays put, keeping the block in place (raid parity).

function BF:GetOrCreateCFGAnchorFrame(groupIndex)
    if not groupIndex then return nil end
    if not self.cfgAnchorFrames then self.cfgAnchorFrames = {} end
    if self.cfgAnchorFrames[groupIndex] then
        return self.cfgAnchorFrames[groupIndex]
    end
    if InCombatLockdown() then return nil end  -- cannot create frames in combat
    local af = CreateFrame("Frame", "BuzzardFrames_CFGAnchor_" .. groupIndex, UIParent)
    af:SetSize(1, 1)
    af:SetFrameStrata("MEDIUM")
    af:SetMovable(true)
    af:SetClampedToScreen(true)
    af:EnableMouse(false)
    self.cfgAnchorFrames[groupIndex] = af
    return af
end

-- The grid dimensions of a custom frame group -- the CFG twin of
-- GetPetGridDims. Takes the group flat's `sorting` table (nil is fine) and
-- answers maxColumns, unitsPerColumn.
--
-- Published because the fallbacks have to agree and did not: the render path
-- (the secure header attributes, this file's bounding boxes, GetCFGGridExtent)
-- fell back to 8 -- the RAID default, copied across -- while everything the
-- user sees fell back to 4: both panels seed a new group's sorting.maxColumns
-- to 4, and both slider getters show 4. A group whose maxColumns was never
-- written therefore rendered and clamped on 8 columns while the options panel
-- said 4. 4 is the CFG default, so it is the one here, and every CFG site now
-- asks this function instead of carrying its own copy.
function BF:GetCFGGridDims(sorting)
    local maxCols = (sorting and sorting.maxColumns) or 4
    local upc     = (sorting and sorting.unitsPerColumn) or 5
    -- Held to the unit ceiling here rather than at each call site, so the
    -- secure header attributes, ForceFramesCreation's eager build, the
    -- anchor frame extent, the setup preview and both panels' getters are
    -- all capped by asking the same question they already ask.
    return math.min(maxCols, self:GetGridMaxColumns(upc)), upc
end

-- The configured extent of a custom frame group's block -- the CFG twin of
-- GetPetGridExtent. Returns the FULL grid (maxColumns × unitsPerColumn) in
-- UIParent units, plus the header scale that produced it.
--
-- Published because two frames must agree on it, and both are clamped to the
-- screen: the real CFG anchor frame is SIZED to it (unscaled, so it takes the
-- returned w,h as they are), and the setup-mode preview header is sized to it
-- too (it carries the scale itself, so it takes w/scale, h/scale). A clamp is
-- computed from the frame's own rect, so two different rects clamp at two
-- different places -- which is what let the preview be dragged off the screen
-- edge while the real block stopped dead, desyncing the two (owner report).
function BF:GetCFGGridExtent(groupIndex)
    if not groupIndex then return nil end
    local cfgp = self.cfgDB and self.cfgDB.profile
    local groups = cfgp and cfgp.customFrameGroups
    local grp = groups and groups[groupIndex]
    local flat = grp and grp.flat
    if not flat then return end

    -- Match _DoRefreshCustomFrameHeaders: size may come from the active
    -- layout when useActiveLayoutSize is set.
    local sizeFlat = flat
    if grp.useActiveLayoutSize then
        local isRaid = self:ResolveActiveIsRaid()
        local activeFlat = isRaid and self:GetRaidProfile() or self:GetActivePartyProfile()
        if activeFlat then sizeFlat = activeFlat end
    end

    local sorting = flat.sorting
    -- Match the header scale logic in _DoRefreshCustomFrameHeaders so the
    -- anchor frame extent matches the rendered block. The cf* fields that
    -- path reads are copied from THIS sizeFlat (see _DoRefreshCustomFrameHeaders,
    -- header.cfEnableFrameScale = sizeFlat.enableFrameScale), so the flags and
    -- the dimensions come from the same place.
    --
    -- Shared with the main grid (see _ExtentFrameMetrics), which is what
    -- teaches this the OTHER scale model: with Apply Scale to Indicators off
    -- the header stays at 1.0 and the SIZE absorbs the scale, so the old
    -- `scale = 1.0` here left the rect sized to the unscaled grid.
    local spH = self:PixelSnap(sizeFlat.frameSpacingH or 0)
    local spV = self:PixelSnap(sizeFlat.frameSpacingV or 0)
    local maxCols, upc = self:GetCFGGridDims(sorting)
    local dir = (sorting and sorting.raidGrowDirection) or "DOWN"
    local isH = (dir == "RIGHT" or dir == "LEFT")

    local fw, fh, scale = self:_ExtentFrameMetrics(sizeFlat,
        sizeFlat.frameWidth or 70, sizeFlat.frameHeight or 40)

    local gridCols, gridRows
    if isH then
        gridCols = upc
        gridRows = maxCols
    else
        gridRows = upc
        gridCols = maxCols
    end
    local w = (gridCols * fw + math.max(0, gridCols - 1) * spH) * scale
    local h = (gridRows * fh + math.max(0, gridRows - 1) * spV) * scale
    return w, h, scale
end

-- Size a CFG anchor frame to the FULL configured grid (maxColumns ×
-- unitsPerColumn), so all four corners are at fixed positions regardless
-- of how many frames are currently visible. Mirrors the raid UpdateSize
-- full-grid sizing so secondary-direction flips don't shift the block.
function BF:UpdateCFGAnchorFrameSize(groupIndex)
    local af = self.cfgAnchorFrames and self.cfgAnchorFrames[groupIndex]
    if not af then return end
    local w, h = self:GetCFGGridExtent(groupIndex)
    if not w then return end
    if not InCombatLockdown() then
        af:SetSize(math.max(w, 1), math.max(h, 1))
    end
end

-- Per-pet-flat anchor frame: same purpose as the CFG anchor frame. The pet
-- secure header is parented to it and pinned to the grow-derived corner, so
-- grow-direction flips only change which corner pins (the anchor frame's
-- full-grid rect stays put). Recompute/Save read THIS frame's stable corner
-- instead of the 1x1 secure pet header's geometry.
function BF:GetOrCreatePetAnchorFrame(flatID)
    if not flatID then return nil end
    if not self.petAnchorFrames then self.petAnchorFrames = {} end
    if self.petAnchorFrames[flatID] then
        return self.petAnchorFrames[flatID]
    end
    if InCombatLockdown() then return nil end
    local af = CreateFrame("Frame", "BuzzardFrames_PetAnchor_" .. flatID, UIParent)
    af:SetSize(1, 1)
    af:SetFrameStrata("MEDIUM")
    af:SetMovable(true)
    af:SetClampedToScreen(true)
    af:EnableMouse(false)
    self.petAnchorFrames[flatID] = af
    return af
end

-- Resolve the pet block grid dimensions (maxColumns, unitsPerColumn) from the
-- flat's user settings, with a party clamp to a single column of 5. Used by
-- the secure header attributes, the anchor frame sizing, and the setup preview
-- so all three agree.
function BF:GetPetGridDims(flat)
    local upc = flat and flat.petUnitsPerColumn or 5
    local maxCols
    if flat and flat.type == "party" then
        maxCols = 1   -- party: single column of (up to) 5 pets
    else
        -- Raid: same unit ceiling as every other grid (see
        -- GetGridMaxColumns). 8 columns x 10 per column is 80 pet frames
        -- built eagerly, and a raid cannot field more than 40 pets.
        maxCols = math.min(flat and flat.petMaxColumns or 2,
                           self:GetGridMaxColumns(upc))
    end
    return maxCols, upc
end

-- Size a pet anchor frame to the configured grid (petMaxColumns ×
-- petUnitsPerColumn, party-clamped), so all four corners are stable regardless
-- of how many pets are visible. Mirrors UpdateCFGAnchorFrameSize.
-- The configured extent of a pet block, the pet twin of
-- GetConfiguredGridExtent. Published because two callers need the same
-- answer: the anchor frame is SIZED to it, and the options page centers the
-- block against it -- and a second copy of this arithmetic is a second thing
-- to keep in step with the renderer.
function BF:GetPetGridExtent(flat)
    if not flat then return nil end
    local sp  = self:PixelSnap(flat.petFrameSpacing or 0)
    local dir = flat.petGrowDirection or "DOWN"
    local isH = (dir == "RIGHT" or dir == "LEFT")
    -- Grid dims from user settings (party-clamped). Must match the secure
    -- header's maxColumns/unitsPerColumn so the anchor frame rect matches the
    -- real block's maximum extent.
    local maxCols, upc = self:GetPetGridDims(flat)

    -- The flat's own scale flags over the PET dimensions -- which is the pair
    -- _ResolveHeaderSizeAndScale's pet branch resolves. Shared with the main
    -- grid (see _ExtentFrameMetrics) so the Apply-Scale-to-Indicators-off
    -- model reaches here too: a plain `scale = 1.0` in that case would size
    -- the rect to the unscaled grid while the frames rendered scaled.
    local fw, fh, scale = self:_ExtentFrameMetrics(flat,
        flat.petFrameWidth or 65, flat.petFrameHeight or 30)

    local gridCols, gridRows
    if isH then
        gridCols, gridRows = upc, maxCols
    else
        gridRows, gridCols = upc, maxCols
    end
    -- Third return: the header scale that produced these numbers. The setup
    -- preview header carries that scale itself, so it sizes to w/scale --
    -- see GetCFGGridExtent for why the two rects have to match exactly.
    return (gridCols * fw + math.max(0, gridCols - 1) * sp) * scale,
           (gridRows * fh + math.max(0, gridRows - 1) * sp) * scale,
           scale
end

function BF:UpdatePetAnchorFrameSize(flatID)
    local af = self.petAnchorFrames and self.petAnchorFrames[flatID]
    if not af then return end
    local lp = self.rpDB and self.rpDB.profile and self.rpDB.profile.layouts
    local fl = lp and lp.flatLayouts
    local flat = fl and fl[flatID]
    if not flat then return end

    local w, h = self:GetPetGridExtent(flat)
    if not w then return end

    if not InCombatLockdown() then
        af:SetSize(math.max(w, 1), math.max(h, 1))
    end
end

-- ── RestorePosition (Grid2: RestorePosition) ────────────────────
-- Positions the anchor frame so that its layoutAnchor corner is at
-- the saved (anchorX, anchorY) offset from UIParent's CENTER.
-- Grid2 equivalent uses p.anchor for the same purpose.
function BF:RestorePosition()
    if not self.anchorFrame then return end
    if InCombatLockdown() then return end

    local activeProfile = self:GetTrueActiveProfile()
    local ax = (activeProfile and activeProfile.anchorX) or -200
    local ay = (activeProfile and activeProfile.anchorY) or 100
    local layoutAnchor = self:GetLayoutAnchor()

    self.anchorFrame:ClearAllPoints()
    self.anchorFrame:SetPoint(layoutAnchor, UIParent, "CENTER", self:SnapAnchor(ax), self:SnapAnchor(ay))
    if self.anchorFrame.SnapHandle then self.anchorFrame.SnapHandle() end
end

-- ── ComputeHeaderScale ──────────────────────────────────────────
-- apOverride: optional flat to compute for instead of the resolved/active
-- context profile — used by GetConfiguredGridExtent so option setters can
-- do region math for the MODIFYING flat (which need not be the active
-- context). Callers without an override are unchanged.
function BF:ComputeHeaderScale(apOverride)
    local ap = apOverride or self._resolvedProfile
    if not ap then
        ap = self._contextIsRaid and self:GetRaidProfile() or self:GetActivePartyProfile()
    end
    local scale, si
    if ap.enableFrameScale then
        scale = ap.frameScale or 1.0
        si    = ap.scaleIndicators ~= false
    else
        scale = 1.0
        si    = true
    end
    if not si then return 1.0 end

    -- v93 (owner-reported: 108 -> 107 made frames BIGGER): the snap scale
    -- MUST be computed from the same dimensions the frames are actually
    -- sized to. Callers size children to PixelRound(frameWidth) and then
    -- apply this scale on top, so reading the RAW width here applied the
    -- rounding correction twice -- on-screen width became
    -- floor(w*ui+0.5)^2 / (w*ui), which is not monotonic in w (at ui 0.8:
    -- 108 -> 85.6px but 107 -> 86.4px). Rounding first makes the scale
    -- exactly `scale` at scale=1 and keeps the scaled size whole-pixel and
    -- strictly monotonic for every other scale.
    -- v93: one shared implementation (PixelPerfect.lua). It pixel-rounds the
    -- dimensions itself on the device-pixel grid, so at scale == 1 this
    -- returns exactly 1.0 and rendered width stays monotonic in the slider.
    local w = ap.frameWidth  or (self._contextIsRaid and 70 or 100)
    local h = ap.frameHeight or (self._contextIsRaid and 40 or 68)
    return self:SnapScaleForSize(scale, w, h)
end

-- ── _ResolveHeaderSizeAndScale ──────────────────────────────────
-- Returns the final (width, height, scale) for this header, handling
-- main raid/party, custom-frame-group, and pet header types. Reads
-- from _resolvedProfile + header overrides + flatLayouts. Pure read;
-- no mutation (no SetSize / SetScale / SetAttribute). Replaces the
-- scale/dimension-resolution math currently in ResizeAllFrames
-- (BFLayout.lua:~3611-3702).
function BF:_ResolveHeaderSizeAndScale(header)
    if header.isCustomFrame then
        -- cf path: extracted from ResizeAllFrames cf-branch.
        local w, h = self:GetFramesSizeForHeader(header)
        -- Default scale: inherit the MAIN raid/party header scale
        -- (ComputeHeaderScale). Matches original ResizeAllFrames where
        -- `thisScale = headerScale` was the initial value; cf headers
        -- without cfEnableFrameScale fall through to this default.
        local scale = self:ComputeHeaderScale()
        if header.cfEnableFrameScale and header.cfFrameScale then
            local cfS  = header.cfFrameScale
            local cfSI = header.cfScaleIndicators ~= false
            if cfSI then
                -- v93: shared device-pixel snap (see BF:SnapScaleForSize). These
                -- dimensions are already PixelRound'd; snapping them against
                -- UIParent:GetEffectiveScale() here applied the correction on a
                -- second, coarser grid and made rendered width non-monotonic.
                scale = self:SnapScaleForSize(cfS, w, h)
            else
                -- Don't scale indicators: frame dimensions absorb the scale, header stays 1.0
                scale = 1.0
                w     = self:PixelRound(w * cfS)
                h     = self:PixelRound(h * cfS)
            end
        end
        return w, h, scale
    elseif header.isPetFrame then
        -- pet path: extracted from ResizeAllFrames pet-branch.
        -- Pet header is parented to UIParent; this SetScale is the only
        -- scale applied. Default is 1.0 (pet does not inherit main).
        local w, h = self:GetFramesSizeForHeader(header)
        local scale = 1.0
        local lp2  = self.rpDB and self.rpDB.profile and self.rpDB.profile.layouts
        local fl2  = lp2 and lp2.flatLayouts
        local petFlat = header.petFlatID and fl2 and fl2[header.petFlatID]
        if petFlat and petFlat.enableFrameScale and petFlat.frameScale then
            local cfS  = petFlat.frameScale
            local cfSI = petFlat.scaleIndicators ~= false
            if cfSI then
                -- v93: shared device-pixel snap (see BF:SnapScaleForSize). These
                -- dimensions are already PixelRound'd; snapping them against
                -- UIParent:GetEffectiveScale() here applied the correction on a
                -- second, coarser grid and made rendered width non-monotonic.
                scale = self:SnapScaleForSize(cfS, w, h)
            else
                scale = 1.0
                w     = self:PixelRound(w * cfS)
                h     = self:PixelRound(h * cfS)
            end
        end
        return w, h, scale
    else
        -- Main raid/party header: extracted from ResizeAllFrames
        -- pre-iteration section (resolves baseW/H and scale, then
        -- applies scaleRaidToFit).
        if self._contextIsRaid == nil then self:ResolveContext() end
        local useRaid = self._contextIsRaid
        local lp = self.rpDB.profile.layouts

        local ap = self._resolvedProfile
        if not ap then
            self:InvalidateRaidProfileCache()
            ap = useRaid and self:GetRaidProfile() or self:GetActivePartyProfile()
        end
        local width  = ap.frameWidth  or (useRaid and 70 or 100)
        local height = ap.frameHeight or (useRaid and 40 or 68)
        local scale, scaleIndicators
        if ap.enableFrameScale then
            scale           = ap.frameScale or 1.0
            scaleIndicators = ap.scaleIndicators ~= false
        else
            scale           = 1.0
            scaleIndicators = true
        end

        local headerScale = self:ComputeHeaderScale()
        local layoutWidth, layoutHeight
        if scaleIndicators then
            layoutWidth  = self:PixelRound(width)
            layoutHeight = self:PixelRound(height)
        else
            headerScale  = 1.0
            layoutWidth  = self:PixelRound(width  * scale)
            layoutHeight = self:PixelRound(height * scale)
        end

        -- scaleRaidToFit
        if lp.scaleRaidToFit and useRaid then
            local spacingH = ap.frameSpacingH or 0
            -- v93: re-round. GetFitFrameWidth math.floor()s to a whole UI unit,
            -- which is NOT a pixel boundary, and SetupMode.lua already rounds
            -- its result -- so without this the live frames and the setup-mode
            -- preview disagreed by up to half a pixel.
            layoutWidth = self:PixelRound(self:GetFitFrameWidth(layoutWidth, spacingH))
        end

        return layoutWidth, layoutHeight, headerScale
    end
end

-- ── UpdateHeaders (Grid2: UpdateHeaders) ────────────────────────
function BF:UpdateHeaders()
    for _, header in ipairs(self.groupsUsed) do
        header:Update()
    end
end

-- ── FixRoster (Grid2: GridLayout.lua:330-340) ───────────────────
-- Workaround for a Blizzard bug in SecureGroupHeaders.lua (Grid2 ticket
-- #628): during the GROUP_ROSTER_UPDATE storm at login, UnitName()
-- briefly returns UNKNOWNOBJECT ("Unknown") — most notably for the
-- player's own slot — and GetRaidRosterInfo() can return nil, so the
-- first frame paint shows no name and no event reliably repaints it
-- (UNIT_NAME_UPDATE can fire before roster registration; solo login
-- produces no further GROUP_ROSTER_UPDATE). While unknown entities are
-- present in the roster we refresh the headers and re-sweep every 1/4
-- second until all unknowns are gone; the Unknown→real name change is
-- then detected by the sweep's UpdateUnit and fanned out to the
-- frame's indicators. Armed exclusively from the roster sweep's tail
-- (see rosterUpdateFrame in Initialization.lua) when roster_unknowns
-- is set, so it has zero cost in steady state and in combat.
-- Grid2 gates its arming on `not self.useInsecureHeaders`; BF only
-- uses secure headers, so that condition is always true here.
function BF:FixRoster()
    if self:RosterHasUnknowns() then
        if not self:RunSecure(5, self, "FixRoster") then
            self:UpdateHeaders()
            self:QueueRosterUpdate()
        end
    end
end

-- ── IterateHeaders (Grid2: IterateHeaders) ──────────────────────
-- Returns an iterator over all active headers
function BF:IterateHeaders(func)
    for _, header in ipairs(self.groupsUsed) do
        func(header)
    end
end

-- Call func(frame) for every child frame across all active headers
function BF:IterateHeaderChildren(func)
    self:IterateHeaders(function(header)
        local i = 1
        while true do
            local frame = header:GetAttribute("child" .. i)
            if not frame then break end
            func(frame)
            i = i + 1
        end
    end)
end

-- ── UpdateFramesSize (Grid2: UpdateFramesSize) ──────────────────
-- Called when frame dimensions change (resize sliders, etc.)
function BF:UpdateFramesSize()
    local modified
    for _, header in ipairs(self.groupsUsed) do
        modified = self:UpdateFramesSizeForHeader(header) or modified
    end
    if modified then
        self:UpdateHeaders()
    end
    return modified
end

-- ── UpdateVisibility ────────────────────────────────────────────
-- Grid2 pattern: drive visibility via the parent anchorFrame, not individual
-- secure headers. anchorFrame is unprotected (mover frame), but we still
-- gate via RunSecure to match Grid2's GridLayout.lua:854-865 pattern and to
-- keep ordering consistent with the rest of the cascade. Slot 8 mirrors
-- Grid2's UpdateVisibility tier exactly. See PEW_GRID2_REFACTOR_PLAN §3.5.
function BF:UpdateVisibility()
    if self:RunSecure(8, self, "UpdateVisibility") then return end

    local g = self.db.global

    -- Grid2 pattern: check per-context enable flags first.
    -- If the current context's frames are disabled, hide everything.
    local gt = self:GetTrueActiveTab()
    if gt == "party" and g.partyFramesEnabled == false then
        if self.anchorFrame then
            self.anchorFrame:SetShown(false)
        end
        return
    elseif gt ~= "party" and g.raidFramesEnabled == false then
        if self.anchorFrame then
            self.anchorFrame:SetShown(false)
        end
        return
    end

    local soloVal = "party"
    local isSolo = not IsInGroup()

    -- Honor "None" selected for the solo slot in Layouts by Instance Type.
    -- GetRaidProfile resolves the active slot and sets openWorldNoneOverride
    -- when the resolved flat ID is the literal string "none". Forcing soloVal
    -- to "none" here routes through the same hide path the rest of this
    -- function uses, so the anchor frame (and therefore all parented main
    -- headers) gets hidden.
    if isSolo then
        self:GetRaidProfile()
        if self.openWorldNoneOverride then
            soloVal = "none"
        end
    end

    -- When solo with party frames + hideSelf, there are no units to show
    -- (the player is the only member and is hidden). Hide the frames
    -- entirely so the empty anchor/headers don't linger on screen.
    -- Exception: if the flat has pet frames enabled with "Show when Solo"
    -- on, the pet header still needs the anchor to stay visible (pet
    -- headers are parented to the anchor so they inherit its scale/position).
    if isSolo and soloVal == "party" then
        local pp = self:GetActivePartyProfile()
        -- hideSelf moved to rpDB.profile.sorting.hideSelf (or
        -- flat.sorting.hideSelf when per-layout toggle is ON).
        local sp = self:GetSectionProfile("sorting", pp)
        if sp and sp.hideSelf then
            local keepForPet = pp and pp.showPetFrames and pp.petShowSolo
            if not keepForPet then
                soloVal = "none"
            end
        end
    end
    local shouldShow = not isSolo or soloVal ~= "none"
    if self.anchorFrame then
        -- RunSecure gate at function entry has already deferred us if in
        -- combat, so this is unconditional here.
        self.anchorFrame:SetShown(shouldShow)
    end
end

-- ============================================================
-- 7. LOAD / RELOAD LAYOUT (Grid2 core flow)
-- ============================================================

-- Resolve layout name from group type (Grid2: ReloadLayout logic)
-- Phase L: the lp.layoutsByGroupType lookups that used to run first were
-- removed -- that key was never written anywhere, so every lookup was nil
-- and the sorting-derived selection below was always the live path.
function BF:ResolveLayoutName()
    -- Sorting settings moved to rpDB.profile.sorting.* (or flat.sorting.*
    -- when per-layout toggle is ON). Consult the truly-active raid/party
    -- flat so per-layout overrides drive layout selection.
    local layoutName
    local _sortFlat = self._contextIsRaid and self:GetRaidProfile() or self:GetActivePartyProfile()
    local sp = self:GetSectionProfile("sorting", _sortFlat)
    local sortMode = (sp and sp.sortingMode) or "GROUP"
    if sortMode == "ROLE" then
        layoutName = "By Role"
    elseif sortMode == "GROUP" and not (sp and sp.strictGroupLayout) then
        layoutName = "By Group Flowing"
    else
        layoutName = "By Group"
    end

    -- FrameSort override: nameList sorting requires a single header.
    -- Strict "By Group" creates multiple per-group headers which
    -- breaks nameList. Switch to "By Group Flowing" (single header).
    if self:IsFrameSortActive() then
        if layoutName == "By Group" then
            layoutName = "By Group Flowing"
        end
    end

    return layoutName
end

-- ============================================================
-- BuildFrameSortNameList: returns the comma-separated name list
-- from FrameSort's sorted units. Used by FixHeaderAttributes
-- during layout (same pattern as custom frame groups).
-- ============================================================
function BF:BuildFrameSortNameList()
    if not FrameSortApi or not FrameSortApi.v3 then return nil end

    local units = FrameSortApi.v3.Sorting:GetFriendlyUnits()
    if not units or #units == 0 then return nil end

    local issecretvalue = issecretvalue or function() return false end
    local names = {}
    for i = 1, #units do
        local unit = units[i]
        if unit and not string.find(unit, "pet") and UnitExists(unit) then
            local name = GetUnitName(unit, true)
            if name and not issecretvalue(name) then
                names[#names + 1] = name
            end
        end
    end
    if #names == 0 then return nil end
    return table.concat(names, ",")
end

-- Grid2: SetGroupType equivalent
function BF:SetGroupType(partyType, instType, maxPlayers, maxGroup)
    self.partyType      = partyType
    self.instType       = instType
    self.instMaxPlayers = maxPlayers
    self.instMaxGroup   = maxGroup
end

-- ── AddCustomFrameHeaders (Grid2: AddSpecialHeaders) ────────────
-- Appends one SecureGroupHeaderTemplate header per enabled custom
-- frame group.  Called at the end of LoadLayout, after the main
-- layout headers are built but before PlaceHeaders.
--
-- Grid2 equivalent: Grid2Layout:AddSpecialHeaders() which iterates
-- the specialHeaders table and calls AddHeader() for each enabled
-- entry with detachHeader=true.
-- ── ConfigureCustomFrameHeader ─────────────────────────────────
-- v53 Phase 2.1: the per-entry body of AddCustomFrameHeaders, lifted
-- verbatim so BF:AddCustomFrameHeaderForGroup can bring up ONE header
-- without a global CFG teardown. Appends the header to groupsUsed and
-- returns it.
local function ConfigureCustomFrameHeader(self, entry)
    do
        -- setupIndex > 1 signals to SetupDetachedHeader that this header
        -- should be detached.  Grid2 uses index+10000 for special headers;
        -- we use 20000+groupIndex to avoid collision with layout indices.
        local setupIndex = 20000 + entry.groupIndex
        self:AddHeader(entry.headerDef, nil, setupIndex, nil, "CFGHeader")
        -- Tag the header with custom frame group metadata so PlaceHeaders
        -- and position save/restore can identify it.
        local header = self.groupsUsed[#self.groupsUsed]
        header.isCustomFrame     = true
        header.customGroupIndex  = entry.groupIndex
        header.customGroupName   = entry.groupName
        -- Re-apply per-group show* attributes after AddHeader, because
        -- FixHeaderAttributes (called inside AddHeader) sets all show*
        -- to true as a safe default for main headers. Custom frame groups
        -- need their own per-group visibility settings to take effect.
        header:SetAttribute("showSolo",  entry.headerDef.showSolo  or false)
        header:SetAttribute("showParty", entry.headerDef.showParty or false)
        header:SetAttribute("showRaid",  entry.headerDef.showRaid  or false)
        -- Update the handle label now that customGroupName is set.
        -- SetupDetachedHeader ran inside AddHeader before the name was
        -- available, so the label defaults to "Custom Frames" until here.
        if header._handle and header._handle._label then
            header._handle._label:SetText("Custom Frame Group: " .. (entry.groupName or "Custom Frames"))
        end
        header._classString      = entry.headerDef._classString or nil
        -- v60: `header.excludePlayer = grp and grp.excludePlayer or nil` was
        -- removed from here. It read `grp` five lines BEFORE `local grp` was
        -- declared below, so it resolved to the (nil) global and the field was
        -- always nil. Nothing was broken by that, because nothing ever read the
        -- field -- the exclude-player filter runs entirely through
        -- `def.showPlayer = not group.excludePlayer` (CustomFrames.lua), which
        -- feeds the secure header's showPlayer attribute. The field's only other
        -- mention was a reset to nil in the header-recycle path, also removed.
        -- Anything that needs this in future should read
        -- `header._cfgGroup.excludePlayer`, stored a few lines below.
        -- CFG section resolution: store the CFG flat and group reference
        -- on the header so GetSectionProfileForFrame can resolve
        -- section profiles for CFG frames at runtime.
        local grp = self:GetCustomFrameGroups()[entry.groupIndex]
        if grp then
            local flat = grp.flat
            header._cfgFlat = flat
            header._cfgGroup = grp
            -- Aura show toggles. v60: resolved per sub-category via
            -- ResolveCFGAurasSubcat rather than indexing flat.auras, so the
            -- independent Buffs/Debuffs per-layout toggles and the CFG
            -- overrideAuras flag are both honored. Defaults still arrive
            -- through the rpDB.profile.auras.<subcat> fallback chain.
            local buffsP   = BF.ResolveCFGAurasSubcat(BF, flat, grp, "buffs")
            local debuffsP = BF.ResolveCFGAurasSubcat(BF, flat, grp, "debuffs")
            local bigDefP  = BF.ResolveCFGAurasSubcat(BF, flat, grp, "bigDef")
            header.moduleShowBuffs            = not buffsP or buffsP.showBuffs ~= false
            header.moduleShowDebuffs          = not debuffsP or debuffsP.showDebuffs ~= false
            -- v67: header.moduleShowPrivateAuras removed with the Private
            -- Auras icon feature. Its only reader was ShouldDisablePrivateAuras
            -- in the deleted PrivateAuras.lua. Blizzard's native private-aura
            -- dispel overlay is a SEPARATE feature and stopped reading this
            -- flag in v60 — see the note on ShouldDisableDispelOverlay — so it
            -- is unaffected.
            header.moduleShowBigDef           = bigDefP and bigDefP.showBigDef or false
            -- v69: moduleShowCrowdControl removed with the dedicated Crowd
            -- Control feature; its only reader was the deleted
            -- CrowdControlIcons indicator's Update.
            -- Aura profile: build a flat view over grp.flat.auras so
            -- BuffIcons/DebuffIcons can read cfAP.buffSize etc. without
            -- knowing the sub-category nesting.
            local sorting = flat and flat.sorting
            header.cfAuraProfile = BuildCfAuraProfileView(flat, grp)
            PrecomputeCfAuraOffsets(header.cfAuraProfile)
            -- Layout Settings: when useActiveLayoutSize is ON, read size/spacing
            -- from the active RP flat instead of the CFG flat.
            local sizeFlat = flat
            if grp.useActiveLayoutSize then
                local isRaid = self:ResolveActiveIsRaid()
                local activeFlat = isRaid and self:GetRaidProfile() or self:GetActivePartyProfile()
                if activeFlat then sizeFlat = activeFlat end
            end
            header.cfFrameWidth      = sizeFlat and sizeFlat.frameWidth
            header.cfFrameHeight     = sizeFlat and sizeFlat.frameHeight
            header.cfMaxColumns      = sorting and sorting.maxColumns
            header.cfUnitsPerColumn  = sorting and sorting.unitsPerColumn
            header.cfFrameSpacingH   = sizeFlat and sizeFlat.frameSpacingH
            header.cfFrameSpacingV   = sizeFlat and sizeFlat.frameSpacingV
            header.cfEnableFrameScale = sizeFlat and sizeFlat.enableFrameScale
            header.cfFrameScale      = sizeFlat and sizeFlat.frameScale
            header.cfScaleIndicators = sizeFlat and sizeFlat.scaleIndicators
            local dir = sorting and sorting.raidGrowDirection
            header.cfGrowDirection   = (dir == "RIGHT" or dir == "UP" or dir == "LEFT") and dir or "DOWN"
            header.cfSecondaryGrowDirection = sorting and sorting.raidSecondaryGrowDirection
            header.cfgLayoutAnchor   = flat and flat.raidLayoutAnchor or "TOPLEFT"
        end
        -- Mark as detached (Grid2: header.isDetached)
        header.isDetached        = true
        header.headerPosKey      = "customFrame_" .. entry.groupIndex

        -- Apply per-group layout overrides to the header attributes.
        -- These must run after FixHeaderAttributes (called inside AddHeader)
        -- so they win over the global defaults.
        if grp then
            -- Always set both explicitly so FixHeaderAttributes' global defaults don't win.
            local s = grp.flat and grp.flat.sorting
            local cfMaxCols, cfUPC = self:GetCFGGridDims(s)
            header:SetAttribute("maxColumns", cfMaxCols)
            header:SetAttribute("unitsPerColumn", cfUPC)
        end

        -- Grid2 pattern: setup frames size, then pre-create.
        --
        -- v86: hoisted OUT of the `if grp` arm above and made unconditional,
        -- because FixHeaderAttributes now deliberately skips its own sizing
        -- pass for a header that is not yet tagged isCustomFrame (it would
        -- take _ResolveHeaderSizeAndScale's main-header arm and size the
        -- children to the wrong flat — see the comment there). This is now
        -- the ONLY place a CFG header's children get sized, so it may not be
        -- conditional on grp. It still runs BEFORE ForceFramesCreation, which
        -- is required: a child created there runs BuzzardFrame_Init, whose
        -- one-shot frame:Layout() reads header.frameWidth/Height.
        self:UpdateFramesSizeForHeader(header)
        -- v86: also unconditional. FixHeaderAttributes no longer pre-creates
        -- CFG children (it would have to size them first, from the wrong
        -- flat), so this is now the only call that builds the group's pool.
        self:ForceFramesCreation(header)

    end
    return self.groupsUsed[#self.groupsUsed]
end

function BF:AddCustomFrameHeaders()
    if not self.GetCustomFrameHeaderDefs then return end
    local defs = self:GetCustomFrameHeaderDefs()
    for _, entry in ipairs(defs) do
        ConfigureCustomFrameHeader(self, entry)
    end
    if #defs > 0 then
        self.layoutHasDetached = true
    end

    -- Set up keybinds for add/remove name on nameList groups
    if self.SetupCustomFrameKeybinds then
        self:SetupCustomFrameKeybinds()
    end
end

-- ── AddPetHeaders (Grid2: AddSpecialHeaders pet variant) ──────────
-- For every active flat that has showPetFrames=true, creates one
-- SecureGroupPetHeaderTemplate header as a detached header.
-- Grid2 pattern: pet headers use SecureGroupPetHeaderTemplate with
-- filterOnPet=true, useOwnerUnit=false to avoid a Blizzard bug.
function BF:AddPetHeaders()
    local lp = self.rpDB and self.rpDB.profile and self.rpDB.profile.layouts
    local fl = lp and lp.flatLayouts
    if not fl then return end

    -- Collect flats that are active and have showPetFrames on.
    -- We only create a pet header for the flat that is actively rendering
    -- (the current resolved flat), not for every flat in the profile.
    -- This matches how custom frame groups work: they render for the
    -- active context, not all possible contexts simultaneously.
    local activeFlatID
    if self._contextIsRaid then
        local flat = self:GetRaidProfile()
        -- Find its ID by reverse lookup
        for id, f in pairs(fl) do
            if f == flat then activeFlatID = id; break end
        end
    else
        local flat = self:GetActivePartyProfile()
        for id, f in pairs(fl) do
            if f == flat then activeFlatID = id; break end
        end
    end

    if not activeFlatID then return end
    local flat = fl[activeFlatID]
    if not flat or not flat.showPetFrames then return end

    -- Build a header definition table with pet-specific attributes,
    -- then call AddHeader with SecureGroupPetHeaderTemplate
    -- (same pattern as AddCustomFrameHeaders).
    local headerDef = {
        showRaid  = true,
        showParty = true,
        showSolo  = flat.petShowSolo and true or false,
        filterOnPet  = true,
        useOwnerUnit = false,
        detachHeader = true,
        isPetFrame   = true,
        petFlatID    = activeFlatID,
    }
    local setupIndex = 30000  -- distinct from custom frame group range (20000+)
    self:AddHeader(headerDef, nil, setupIndex, "SecureGroupPetHeaderTemplate")
    local header = self.groupsUsed[#self.groupsUsed]

    -- Tag as pet frame so FixHeaderAttributes routes correctly.
    header.isPetFrame   = true
    header.petFlatID    = activeFlatID
    header.isDetached   = true
    header.headerPosKey = "petFrame_" .. activeFlatID

    -- Re-apply pet-specific attributes after FixHeaderAttributes
    -- (which may have overwritten them with main-header defaults).
    header:SetAttribute("filterOnPet",  true)
    header:SetAttribute("useOwnerUnit", false)
    header:SetAttribute("unitsuffix",   nil)
    header:SetAttribute("showSolo",     flat.petShowSolo and true or false)
    local petMaxCols0, petUPC0 = self:GetPetGridDims(flat)
    header:SetAttribute("unitsPerColumn", petUPC0)
    header:SetAttribute("maxColumns", petMaxCols0)

    -- Resolve pet grow direction and apply orientation + columnAnchorPoint.
    local petDir = flat.petGrowDirection or "DOWN"
    -- Normalize the secondary against the current primary axis so a stale
    -- cross-axis value can never change the derived corner (see
    -- GetNormalizedPetSecondary).
    local petSecDir = GetNormalizedPetSecondary(flat)
    local petH = (petDir == "RIGHT" or petDir == "LEFT")
    local petGA = DeriveGroupAnchor(petDir, petSecDir)
    -- Stored-anchor corner tracks the grow-derived anchor (see RefreshPetHeaders).
    header.cfgLayoutAnchor = petGA
    local petSpacing = flat.petFrameSpacing or (lp.Padding or 0)
    header:SetAttribute("columnSpacing", petSpacing)
    if petH then
        header:SetAttribute("columnAnchorPoint", anchorToPoint[false][petGA])
    else
        header:SetAttribute("columnAnchorPoint", anchorToPoint[true][petGA])
    end

    -- Size and pre-create frames.
    self:UpdateFramesSizeForHeader(header)
    self:ForceFramesCreation(header)
    self:SetupDetachedHeader(header)

    -- Update the drag handle label.
    if header._handle and header._handle._label then
        local flatName = flat.name or activeFlatID
        header._handle._label:SetText(flatName .. ": Pet Frames")
    end

    self.layoutHasDetached = true
end

-- ── TogglePetFrames ─────────────────────────────────────────────
-- Surgically adds or removes the pet header without a full
-- ReloadLayout. When enabling, calls AddPetHeaders then
-- PlaceHeaders to position it. When disabling, finds the pet
-- header in groupsUsed, resets it, removes it, and hides it.
function BF:TogglePetFrames()
    if InCombatLockdown() then return end

    local lp = self.rpDB and self.rpDB.profile and self.rpDB.profile.layouts
    local fl = lp and lp.flatLayouts
    if not fl then return end

    -- Resolve the active flat
    local activeFlatID
    if self._contextIsRaid then
        local flat = self:GetRaidProfile()
        for id, f in pairs(fl) do
            if f == flat then activeFlatID = id; break end
        end
    else
        local flat = self:GetActivePartyProfile()
        for id, f in pairs(fl) do
            if f == flat then activeFlatID = id; break end
        end
    end
    if not activeFlatID then return end
    local flat = fl[activeFlatID]
    if not flat then return end

    if flat.showPetFrames then
        -- Enable: check if a pet header already exists for this flat
        local exists = false
        for _, header in ipairs(self.groupsUsed) do
            if header.isPetFrame and header.petFlatID == activeFlatID then
                exists = true
                break
            end
        end
        if not exists then
            self:AddPetHeaders()
            self:PlaceHeaders()
            self:UpdateSize()
            self:UpdateHeaders()
            self:ResizeAllFrames()
        end
    else
        -- Disable: find and remove the pet header
        for i = #self.groupsUsed, 1, -1 do
            local header = self.groupsUsed[i]
            if header.isPetFrame and header.petFlatID == activeFlatID then
                -- Clear units from child frames before reset
                for _, uframe in ipairs(header) do
                    if uframe.unit then
                        uframe:SetAttribute("unit", nil)
                    end
                end
                header:Hide()
                if header._handle then header._handle:Hide() end
                -- Hide the pet anchor frame too (header is reparented away on
                -- Reset; the anchor frame is invisible but tidy to hide).
                if self.petAnchorFrames and self.petAnchorFrames[activeFlatID] then
                    self.petAnchorFrames[activeFlatID]:Hide()
                end
                header:Reset()
                table.remove(self.groupsUsed, i)
                -- Decrement the pool index so the header is reusable
                local poolKey = "SecureGroupPetHeaderTemplate"
                local idx = self.layoutIndexes[poolKey] or 0
                if idx > 0 then
                    self.layoutIndexes[poolKey] = idx - 1
                end
                break
            end
        end
        -- Recheck if any detached headers remain
        self.layoutHasDetached = nil
        for _, header in ipairs(self.groupsUsed) do
            if header.isDetached then
                self.layoutHasDetached = true
                break
            end
        end
    end
end

-- ── RecomputePetHeaderAnchor ─────────────────────────────────────
-- Called by the pet grow-direction / secondary-grow-direction options
-- setters when the grow direction changes. Mirrors the raid setter
-- (Options_Frames_Sorting.lua:342-364) and the custom-frame
-- recalcPosition (Options_CustomFrames.lua:703-722): re-derive the
-- layout anchor corner, recompute the stored CENTER-relative offset
-- from that corner of the CURRENT visible pet block so the block does
-- not shift, and write it to both representations the pet header uses
-- (customFrameGroupPositions[posKey] and the flat's petFrameAnchorX/Y,
-- which back the X/Y Position sliders).
--
-- Must be called BEFORE RefreshPetHeaders so the refresh restores from
-- the recomputed position. flatID is the modifying flat's id.
function BF:RecomputePetHeaderAnchor(flatID, newLA)
    if InCombatLockdown() then return end
    if not flatID or not newLA then return end
    -- Read the NEW corner from the PET ANCHOR FRAME (full-grid sized, stable),
    -- NOT the 1x1 secure pet header (whose four corners are the same point and
    -- whose rect tracks its children). Reading the header corrupted the saved
    -- position on a grow flip — the actual bug. Mirror the CFG recompute.
    -- Do NOT resize the anchor frame here. Reading the new corner from a
    -- just-resized-but-not-yet-repositioned frame yields a position offset by
    -- the size delta, which compounds on every grow change (progressive drift).
    -- CFG's recalcPosition reads the anchor frame's CURRENT corner without
    -- resizing first; RefreshPetHeaders resizes + repositions afterward.
    local af = self:GetOrCreatePetAnchorFrame(flatID)
    if not af or not af:GetLeft() then return end
    local ux, uy = UIParent:GetCenter()
    if not ux or not uy then return end
    local newX = newLA:find("LEFT") and af:GetLeft() or af:GetRight()
    local newY = newLA:find("TOP")  and af:GetTop()  or af:GetBottom()
    if not newX or not newY then return end
    local cx = floor(newX - ux + 0.5)
    local cy = floor(newY - uy + 0.5)

    -- Stamp the live header's anchor too (if present) so SaveDetachedHeaderPosition uses it.
    for _, h in ipairs(self.groupsUsed or {}) do
        if h.isPetFrame and h.petFlatID == flatID then h.cfgLayoutAnchor = newLA; break end
    end

    -- Detached-header position store (read by RestoreDetachedHeaderPosition).
    local cfgp = self.cfgDB and self.cfgDB.profile
    if cfgp then
        if not cfgp.customFrameGroupPositions then
            cfgp.customFrameGroupPositions = {}
        end
        cfgp.customFrameGroupPositions["petFrame_" .. flatID] = { newLA, cx, cy }
    end

    -- Keep the X/Y Position sliders accurate (CENTER-relative, anchor = newLA).
    local lp = self.rpDB and self.rpDB.profile and self.rpDB.profile.layouts
    local fl = lp and lp.flatLayouts
    local flat = fl and fl[flatID]
    if flat then
        flat.petFrameAnchorX = cx
        flat.petFrameAnchorY = cy
    end
end

-- ── RefreshPetHeaders ────────────────────────────────────────────
-- Lightweight refresh for pet header visual settings (grow direction,
-- spacing, size). Mirrors _DoRefreshCustomFrameHeaders pattern.
function BF:RefreshPetHeaders()
    if InCombatLockdown() then return end
    local lp = self.rpDB and self.rpDB.profile and self.rpDB.profile.layouts
    local fl = lp and lp.flatLayouts
    if not fl then return end

    for i, header in ipairs(self.groupsUsed or {}) do
        if header.isPetFrame and header.petFlatID then
            local petFlat = fl[header.petFlatID]
            if petFlat then
                self:FixHeaderAttributes(header, i)

                local dir = petFlat.petGrowDirection or "DOWN"
                -- Normalize the secondary against the current primary axis so a
                -- stale cross-axis value can never change the derived corner
                -- (see GetNormalizedPetSecondary).
                local secDir = GetNormalizedPetSecondary(petFlat)
                local isH = (dir == "RIGHT" or dir == "LEFT")
                local ga = DeriveGroupAnchor(dir, secDir)
                -- Keep the stored-anchor corner in sync with the grow-derived
                -- columnAnchorPoint so SaveDetachedHeaderPosition (on drag) and
                -- the grow-direction recompute agree.
                header.cfgLayoutAnchor = ga
                local spacing = petFlat.petFrameSpacing or (lp.Padding or 0)
                local snapped = self:PixelSnap(spacing)
                header:SetOrientation(isH, snapped, dir)
                if isH then
                    header:SetAttribute("columnAnchorPoint", anchorToPoint[false][ga])
                    header:SetAttribute("columnSpacing", snapped)
                else
                    header:SetAttribute("columnAnchorPoint", anchorToPoint[true][ga])
                    header:SetAttribute("columnSpacing", snapped)
                end

                local petMaxCols, petUPC = self:GetPetGridDims(petFlat)
                header:SetAttribute("maxColumns", petMaxCols)
                header:SetAttribute("unitsPerColumn", petUPC)

                local w, h = self:GetFramesSizeForHeader(header)
                -- Scale the pet header exactly like _DoRefreshCustomFrameHeaders
                -- scales custom frame groups: start at 1.0 and only apply a
                -- scale when the flat's enableFrameScale/frameScale pair is set.
                -- Inputs are the party flat's scale settings (petFlat == the
                -- active party flat), so the party's scale slider drives pet
                -- sizing exactly as the custom group's own slider drives its
                -- frames. Pet header is parented to UIParent so this SetScale
                -- is the only scale applied.
                local thisScale = 1.0
                if petFlat.enableFrameScale and petFlat.frameScale then
                    local cfS  = petFlat.frameScale
                    local cfSI = petFlat.scaleIndicators ~= false
                    if cfSI then
                        -- v93: shared device-pixel snap (see BF:SnapScaleForSize). These
                        -- dimensions are already PixelRound'd; snapping them against
                        -- UIParent:GetEffectiveScale() here applied the correction on a
                        -- second, coarser grid and made rendered width non-monotonic.
                        thisScale = self:SnapScaleForSize(cfS, w, h)
                    else
                        thisScale = 1.0
                        w = self:PixelRound(w * cfS)
                        h = self:PixelRound(h * cfS)
                    end
                end
                header:SetScale(thisScale)
                header.frameWidth  = w
                header.frameHeight = h
                for _, frame in ipairs(header) do
                    frame:Layout()
                end

                -- Parent to the pet anchor frame and size it to the full grid
                -- before restoring, so the header pins to a stable corner.
                local petAF = self:GetOrCreatePetAnchorFrame(header.petFlatID)
                if petAF then
                    header:SetParent(petAF)
                    self:UpdatePetAnchorFrameSize(header.petFlatID)
                end

                -- Position, show, and update only this pet header.
                -- Previous versions called PlaceHeaders + UpdateHeaders on ALL
                -- headers which invalidated PA anchors on non-pet frames.
                self:RestoreDetachedHeaderPosition(header)
                header:Show()
                header:Update()
                -- Force SecureGroupPetHeader_Update to re-run configureChildren.
                header:SetAttribute("_forceUpdate", not header:GetAttribute("_forceUpdate"))

                if header._handle then
                    local locked = self.db.global.locked
                    if locked == nil then locked = true end
                    if not locked then
                        header._handle:Show()
                        if header._handle.SnapToParent then header._handle.SnapToParent() end
                    else
                        header._handle:Hide()
                    end
                end

                -- Re-register private aura anchors after Hide/Show cycles.
                for _, frame in ipairs(header) do
                    if self.RegisterPrivateAuraDispelOverlayOnly then self:RegisterPrivateAuraDispelOverlayOnly(frame) end
                end
            end
        end
    end
end

-- ── SetupDetachedHeader (Grid2: SetupDetachedHeader) ────────────
-- Lightweight update for custom frame group visual settings (size, spacing,
-- scale, grow direction). Syncs group config to the live headers and re-applies
-- attributes without destroying/recreating headers like ReloadLayout does.
-- Debounce timer for lightweight custom frame header refresh.
local _cfRefreshTimer = nil

function BF:RefreshCustomFrameHeaders()
    if InCombatLockdown() then return end

    -- Debounce: sliders fire on every tick. Batch into a single
    -- update after the user stops dragging.
    if _cfRefreshTimer then _cfRefreshTimer:Cancel() end
    _cfRefreshTimer = C_Timer.NewTimer(0.1, function()
        _cfRefreshTimer = nil
        if InCombatLockdown() then return end
        BF:_DoRefreshCustomFrameHeaders()
        if BF.UpdateCustomFrameTestFrames then
            BF:UpdateCustomFrameTestFrames()
        end
    end)
end

function BF:_DoRefreshCustomFrameHeaders()
    local cfgp = self.cfgDB.profile
    local groups = cfgp.customFrameGroups
    if not groups then return end

    for i, header in ipairs(self.groupsUsed or {}) do
        if header.isCustomFrame and header.customGroupIndex then
            local grp = groups[header.customGroupIndex]
            if grp then
                local flat = grp.flat
                local sorting = flat and flat.sorting
                -- When useActiveLayoutSize is ON, read size/spacing from the
                -- active RP flat instead of the CFG flat.
                local sizeFlat = flat
                if grp.useActiveLayoutSize then
                    local isRaid = self:ResolveActiveIsRaid()
                    local activeFlat = isRaid and self:GetRaidProfile() or self:GetActivePartyProfile()
                    if activeFlat then sizeFlat = activeFlat end
                end
                header.cfFrameWidth      = sizeFlat and sizeFlat.frameWidth
                header.cfFrameHeight     = sizeFlat and sizeFlat.frameHeight
                header.cfMaxColumns      = sorting and sorting.maxColumns
                header.cfUnitsPerColumn  = sorting and sorting.unitsPerColumn
                header.cfFrameSpacingH   = sizeFlat and sizeFlat.frameSpacingH
                header.cfFrameSpacingV   = sizeFlat and sizeFlat.frameSpacingV
                header.cfEnableFrameScale = sizeFlat and sizeFlat.enableFrameScale
                header.cfFrameScale      = sizeFlat and sizeFlat.frameScale
                header.cfScaleIndicators = sizeFlat and sizeFlat.scaleIndicators
                local dir2 = sorting and sorting.raidGrowDirection
                header.cfGrowDirection   = (dir2 == "RIGHT" or dir2 == "UP" or dir2 == "LEFT") and dir2 or "DOWN"
                header.cfSecondaryGrowDirection = sorting and sorting.raidSecondaryGrowDirection
                header.cfgLayoutAnchor   = flat and flat.raidLayoutAnchor or "TOPLEFT"
                header.cfAuraProfile     = BuildCfAuraProfileView(flat, grp)
                PrecomputeCfAuraOffsets(header.cfAuraProfile)

                -- Hide the header across ALL attribute mutations below. Each
                -- SetAttribute on a VISIBLE SecureGroupHeaderTemplate fires
                -- SecureGroupHeader_Update immediately. A PRIMARY grow-direction
                -- change flips the "point" attribute (TOP<->LEFT via
                -- SetOrientation); mutating "point" on a live header while
                -- maxColumns/unitsPerColumn are already set re-lays children from
                -- a partial attribute mix, producing a wrong layout on the FIRST
                -- refresh (a later refresh settles it). Hiding here makes the
                -- final Show()+Update() below run exactly ONE clean
                -- SecureGroupHeader_Update from a consistent attribute set — the
                -- same effect raid gets from ReloadLayout. Safe post anchor-frame
                -- refactor: CFG positioning reads the anchor frame / config, never
                -- the header's live geometry, so hiding does not move the block.
                header:Hide()

                self:FixHeaderAttributes(header, i)

                -- Set orientation attributes BEFORE maxColumns/unitsPerColumn.
                local cfDir = header.cfGrowDirection
                local cfH = (cfDir == "RIGHT" or cfDir == "LEFT")
                local cfGA = DeriveGroupAnchor(cfDir, header.cfSecondaryGrowDirection)
                local cfSpH = header.cfFrameSpacingH and self:PixelSnap(header.cfFrameSpacingH) or 0
                local cfSpV = header.cfFrameSpacingV and self:PixelSnap(header.cfFrameSpacingV) or 0
                local cfPad = cfH and cfSpH or cfSpV
                header:SetOrientation(cfH, cfPad, cfDir)
                if cfH then
                    header:SetAttribute("columnAnchorPoint", anchorToPoint[false][cfGA])
                    header:SetAttribute("columnSpacing", cfSpV)
                else
                    header:SetAttribute("columnAnchorPoint", anchorToPoint[true][cfGA])
                    header:SetAttribute("columnSpacing", cfSpH)
                end

                local cfMaxCols, cfUPC = self:GetCFGGridDims(sorting)
                header:SetAttribute("maxColumns", cfMaxCols)
                header:SetAttribute("unitsPerColumn", cfUPC)

                -- Resize + re-layout only this header's child frames
                local w, h = self:GetFramesSizeForHeader(header)
                local thisScale = 1.0
                if header.cfEnableFrameScale and header.cfFrameScale then
                    local cfS  = header.cfFrameScale
                    local cfSI = header.cfScaleIndicators ~= false
                    if cfSI then
                        -- v93: shared device-pixel snap (see BF:SnapScaleForSize). These
                        -- dimensions are already PixelRound'd; snapping them against
                        -- UIParent:GetEffectiveScale() here applied the correction on a
                        -- second, coarser grid and made rendered width non-monotonic.
                        thisScale = self:SnapScaleForSize(cfS, w, h)
                    else
                        thisScale = 1.0
                        w = self:PixelRound(w * cfS)
                        h = self:PixelRound(h * cfS)
                    end
                end
                header:SetScale(thisScale)
                header.frameWidth  = w
                header.frameHeight = h
                for _, frame in ipairs(header) do
                    frame:Layout()
                end

                -- Set header size to the computed bounding box so that
                -- GetLeft()/GetRight()/GetTop()/GetBottom() return the
                -- actual visual extent. SecureGroupHeaderTemplate doesn't
                -- auto-size to its children, so without this the header
                -- is zero-size and SaveDetachedHeaderPosition (called on
                -- drag) reads incorrect geometry. Matches raid UpdateSize
                -- pattern where the anchor frame is explicitly sized.
                local bbMaxCols, bbUPC = self:GetCFGGridDims(sorting)
                local bbW, bbH
                if cfH then
                    bbW = bbUPC * w     + math.max(0, bbUPC - 1)     * cfSpH
                    bbH = bbMaxCols * h + math.max(0, bbMaxCols - 1) * cfSpV
                else
                    bbW = bbMaxCols * w + math.max(0, bbMaxCols - 1) * cfSpH
                    bbH = bbUPC * h     + math.max(0, bbUPC - 1)     * cfSpV
                end
                header:SetSize(bbW, bbH)

                -- Size the CFG anchor frame to the full grid BEFORE restoring,
                -- so the header pins to a stable corner (raid parity). The
                -- anchor + header pin are applied inside
                -- RestoreDetachedHeaderPosition's isCustomFrame branch.
                self:UpdateCFGAnchorFrameSize(header.customGroupIndex)

                -- Position, show, and update this header.  Previous versions
                -- called self:PlaceHeaders() + self:UpdateHeaders() here which
                -- operated on ALL headers (including raid/party), invalidating
                -- private-aura anchors on non-CFG frames.  Now we only touch
                -- the CFG headers that actually changed.
                self:RestoreDetachedHeaderPosition(header)
                header:Show()
                header:Update()

                -- Show/hide the drag handle based on lock state.
                if header._handle then
                    local locked = self.db.global.locked
                    if locked == nil then locked = true end
                    if not locked then
                        header._handle:Show()
                        if header._handle.SnapToParent then header._handle.SnapToParent() end
                    else
                        header._handle:Hide()
                    end
                end

                -- Re-update all indicators on CFG child frames.
                -- header:Update() only triggers OnUnitChanged when the
                -- unit attribute actually changes. When settings change
                -- (override toggle, section edits) the same unit stays on
                -- the same frame, so OnAttributeChanged is a no-op and
                -- indicators never re-read the new profile. Explicit
                -- UpdateIndicators forces them to pick up the freshly
                -- resolved section profile (cache was wiped by
                -- InvalidateRaidProfileCache before this runs).
                for _, frame in ipairs(header) do
                    if frame.unit then
                        frame:UpdateIndicators()
                    end
                end

                -- Re-register private aura anchors for this header's children.
                -- header:Update() triggers Hide/Show cycles on child frames
                -- which invalidate C_UnitAuras.AddPrivateAuraAnchor handles.
                for _, frame in ipairs(header) do
                    if self.RegisterPrivateAuraDispelOverlayOnly then self:RegisterPrivateAuraDispelOverlayOnly(frame) end
                end
            end
        end
    end
end

-- ── ApplySoloCustomHeaderOverride ──────────────────────────────
-- v53 Phase 2.1: step 3 of ReloadCustomFrameHeadersOnly, lifted verbatim
-- and scoped to ONE header so the targeted first-add path can apply it
-- without walking every CFG header. Caller owns the `not IsInGroup()` test.
local function ApplySoloCustomHeaderOverride(self, header)
    if not (header.isCustomFrame and header:GetAttribute("showSolo")) then return end
    local playerRole = self.playerSpecRole or "DAMAGER"
    local _, playerClass = UnitClass("player")
    local groups = self:GetCustomFrameGroups()
    local gi = header.customGroupIndex
    local grp = gi and groups[gi]
    local matches = true
    if grp then
        if grp.roleFilterEnabled and grp.roleFilter then
            local hasAnyRole = grp.roleFilter.TANK or grp.roleFilter.HEALER or grp.roleFilter.DAMAGER
            if hasAnyRole and not grp.roleFilter[playerRole] then
                matches = false
            end
        end
        if matches and grp.classFilterEnabled and grp.classFilter then
            local hasAnyClass = false
            for _, cls in ipairs(BF.CLASS_SORT_ORDER_ALPHA) do
                if grp.classFilter[cls] then hasAnyClass = true; break end
            end
            if hasAnyClass and not grp.classFilter[playerClass] then
                matches = false
            end
        end
    end
    if matches then
        header:SetAttribute("groupFilter", nil)
        header:SetAttribute("roleFilter", nil)
        header:SetAttribute("strictFiltering", nil)
    else
        header:SetAttribute("showSolo", false)
    end
end

-- ── FinalizeCustomFrameHeader ──────────────────────────────────
-- v53 Phase 2.1: step 4 of ReloadCustomFrameHeadersOnly, lifted verbatim
-- and scoped to ONE header (size → scale → per-frame Layout → position →
-- Show/Update → handle → private aura anchors). Shared with the targeted
-- first-add path so both spell exactly the same header bring-up.
local function FinalizeCustomFrameHeader(self, header)
    local grp = self:GetCustomFrameGroups()[header.customGroupIndex]
    if not grp then return end

    self:UpdateFramesSizeForHeader(header)
    self:ForceFramesCreation(header)

    local w, h = self:GetFramesSizeForHeader(header)
    local thisScale = 1.0
    if header.cfEnableFrameScale and header.cfFrameScale then
        local cfS  = header.cfFrameScale
        local cfSI = header.cfScaleIndicators ~= false
        if cfSI then
            -- v93: shared device-pixel snap (see BF:SnapScaleForSize). These
            -- dimensions are already PixelRound'd; snapping them against
            -- UIParent:GetEffectiveScale() here applied the correction on a
            -- second, coarser grid and made rendered width non-monotonic.
            thisScale = self:SnapScaleForSize(cfS, w, h)
        else
            thisScale = 1.0
            w = self:PixelRound(w * cfS)
            h = self:PixelRound(h * cfS)
        end
    end
    header:SetScale(thisScale)
    header.frameWidth  = w
    header.frameHeight = h

    for _, frame in ipairs(header) do
        frame:Layout()
    end

    if not self:RestoreDetachedHeaderPosition(header) then
        -- No saved position (newly created group). Offset from
        -- center by group index so multiple new groups don't
        -- stack on top of each other. Matches the setup mode
        -- test frame default positioning pattern.
        local gi = header.customGroupIndex or 1
        header:ClearAllPoints()
        header:SetClampedToScreen(true)
        header:SetPoint("CENTER", UIParent, "CENTER", 200, 100 - (gi - 1) * 60)
        header:Show()
        C_Timer.After(0, function()
            self:SaveDetachedHeaderPosition(header)
            self:RestoreDetachedHeaderPosition(header)
            header:SetClampedToScreen(false)
        end)
    end
    header:Show()
    header:Update()

    -- Show/hide drag handle
    if header._handle then
        local locked = self.db.global.locked
        if locked == nil then locked = true end
        if not locked then
            header._handle:Show()
            if header._handle.SnapToParent then header._handle.SnapToParent() end
        else
            header._handle:Hide()
        end
    end

    -- Re-register private aura anchors after Update's Hide/Show
    for _, frame in ipairs(header) do
        if self.RegisterPrivateAuraDispelOverlayOnly then self:RegisterPrivateAuraDispelOverlayOnly(frame) end
    end
end

-- ============================================================
-- ReloadCustomFrameHeadersOnly — CFG-only structural reload.
-- Tears down and rebuilds only CFG headers, leaving main/raid/pet
-- headers untouched. Use this instead of ReloadLayout(true) when
-- only CFG configuration changed (add/remove group, enable/disable,
-- filter changes, nameList changes, visibility toggles, etc.).
-- ============================================================
function BF:ReloadCustomFrameHeadersOnly()
    if InCombatLockdown() then return end

    -- 1. Remove existing CFG headers from groupsUsed, reset each one.
    --    Clear keybinds first (they reference CFG headers by index).
    if self.ClearCustomFrameKeybinds then
        self:ClearCustomFrameKeybinds()
    end


    -- Walk groupsUsed backwards, remove CFG entries and reset them.
    for i = #self.groupsUsed, 1, -1 do
        local header = self.groupsUsed[i]
        if header.isCustomFrame then
            header:Reset()
            table.remove(self.groupsUsed, i)
        end
    end
    -- Reset the CFG pool index so AddHeader reuses slots.
    self.layoutIndexes["CFGHeader"] = 0

    -- 1b. Hide anchor frames for groups that no longer exist (deleted/disabled),
    --     so a removed group doesn't leave a stray anchor frame around. Frames
    --     for still-existing groups are reused and re-sized on rebuild.
    if self.cfgAnchorFrames then
        local groups = self:GetCustomFrameGroups()
        for gi, af in pairs(self.cfgAnchorFrames) do
            if not (groups and groups[gi]) then
                af:Hide()
            end
        end
    end

    -- 2. Rebuild CFG headers from current config.
    self:InvalidateRaidProfileCache()
    -- Refresh aura-size cache + wipe stale CFG container-settings before
    -- the per-frame Layout below. Without this, the first frame:Layout()
    -- after a header (re)spawn can read stale or default buffSize values
    -- via EnsureContainerSettings's [ci][groupTypeKey] cache. /reload
    -- masked it because reload reinits the Lua state with empty caches
    -- and then runs UpdateAuraSizeCache during Initialization.
    if self.InvalidateAllFlatAuraCaches then self:InvalidateAllFlatAuraCaches() end
    if self.UpdateAuraSizeCache then self:UpdateAuraSizeCache() end
    if self.InvalidateContainerSettingsCacheCFGOnly then
        self:InvalidateContainerSettingsCacheCFGOnly()
    end
    self:AddCustomFrameHeaders()

    -- 3. Solo CFG override: when solo, clear filter attributes on
    --    CFG headers whose filters match the player, or hide them.
    if not IsInGroup() then
        for _, header in ipairs(self.groupsUsed) do
            ApplySoloCustomHeaderOverride(self, header)
        end
    end

    -- 4. Size, place, and show only CFG headers.
    for _, header in ipairs(self.groupsUsed) do
        if header.isCustomFrame then
            FinalizeCustomFrameHeader(self, header)
        end
    end

    -- 5. Sync range checker (CFGs may have been added/removed).
    if self._framesActiveForContext == false then
        local anyCustom = false
        for _, h in ipairs(self.groupsUsed) do
            if h.isCustomFrame then anyCustom = true; break end
        end
        -- An active raid-style twin is an external range unit of its own
        -- (Range.lua roster_external), so the ticker must survive a context
        -- whose raid/party frames are disabled.
        if not anyCustom and self.twinFrames then
            for _, twin in ipairs(self.twinFrames) do
                if twin._bf_twinActive and twin.unit then anyCustom = true; break end
            end
        end
        if anyCustom then
            if self.SyncRangeChecker then self:SyncRangeChecker() end
        else
            if self.StopRangeChecker then self:StopRangeChecker() end
        end
    else
        if self.SyncRangeChecker then self:SyncRangeChecker() end
    end

    -- 6. Deferred aura/indicator refresh for CFG frames only.
    C_Timer.After(0, function()
        for _, header in ipairs(self.groupsUsed) do
            if header.isCustomFrame then
                for _, frame in ipairs(header) do
                    if frame and frame.unit and frame:IsShown() then
                        -- Re-Layout once now that header identity is
                        -- stable (parent header has isCustomFrame /
                        -- _cfgFlat set, and frame._bf_parentHeader has
                        -- been resolved by an earlier code path). This
                        -- re-stamps default-buff cooldown font / scale
                        -- from the CFG's _auraCache; any earlier stamp
                        -- that ran during AddHeader's synchronous
                        -- child-frame creation used BF.AuraCache because
                        -- the parent's isCustomFrame flag wasn't set yet.
                        frame:Layout()
                        self:UpdateFrameIndicators(frame, frame.unit)
                    end
                end
            end
        end
        if self.FlushDeferredIndicatorUpdates then self:FlushDeferredIndicatorUpdates() end
    end)
end

-- ============================================================
-- v53 Phase 2.1 — AddCustomFrameHeaderForGroup(groupIndex)
--
-- The targeted counterpart of BF:ApplyCustomGroupNameListOnly: that fast
-- path covers every add/remove AFTER a group has a header, this one covers
-- the birth of the header itself (the "list gains its first name" case that
-- used to fall through to the full ReloadCustomFrameHeadersOnly).
--
-- What the full path does that this deliberately does NOT:
--   * Reset() every OTHER CFG header (and the groupsUsed/pool-index churn
--     that goes with it) — nothing about the other groups changed.
--   * InvalidateAllFlatAuraCaches() + UpdateAuraSizeCache() — a nameList
--     edit changes no aura setting, so rebuilding the aura settings cache
--     for the global scope + every CFG flat + every per-layout flat is pure
--     waste. Only this group's flat cache is built, and only if it is
--     missing (it is built at login for every flat).
--   * frame:Layout() over every pre-created frame of every OTHER CFG.
--   * SetupCustomFrameKeybinds() — the bindings are derived from the group
--     config, not from headers, and the keybind that got us here is proof
--     they are already installed.
--
-- What it keeps, because a header BIRTH genuinely needs it:
--   * InvalidateContainerSettingsCacheCFGOnly() — the [ci][groupTypeKey]
--     settings cache can hold stale/default buffSize values for CFG-scoped
--     keys, which the brand-new frames' first Layout() would read.
--   * the solo filter override and the whole FinalizeCustomFrameHeader
--     bring-up, both shared verbatim with the full path.
--
-- Returns true when it handled the change; false means "not my case, use
-- the full rebuild".
-- ============================================================
function BF:AddCustomFrameHeaderForGroup(groupIndex)
    if InCombatLockdown() then return false end
    if not (self.groupsUsed and self.GetCustomFrameHeaderDefs) then return false end

    -- Only for a group that has no header yet. Anything else (a header that
    -- exists, a group that should not have one) is not this function's case.
    for _, h in ipairs(self.groupsUsed) do
        if h.isCustomFrame and h.customGroupIndex == groupIndex then return false end
    end

    local defs = self:GetCustomFrameHeaderDefs()
    local entry
    for _, e in ipairs(defs) do
        if e.groupIndex == groupIndex then entry = e; break end
    end
    if not entry then return false end

    -- Only this group's aura scope, and only when it is actually missing.
    local grp = self:GetCustomFrameGroups()[groupIndex]
    local flat = grp and grp.flat
    if flat and not flat._auraCache and self._RebuildAuraCacheScope then
        flat._auraCache = {}
        self._RebuildAuraCacheScope(flat._auraCache, flat, grp)
    end
    if self.InvalidateContainerSettingsCacheCFGOnly then
        self:InvalidateContainerSettingsCacheCFGOnly()
    end

    local header = ConfigureCustomFrameHeader(self, entry)
    if not header or header.customGroupIndex ~= groupIndex then
        -- Something moved underneath us; hand back to the full rebuild.
        return false
    end
    self.layoutHasDetached = true

    if not IsInGroup() then
        ApplySoloCustomHeaderOverride(self, header)
    end
    FinalizeCustomFrameHeader(self, header)

    -- The set of units shown changed, so the polled range roster did too.
    if self.SyncRangeChecker then self:SyncRangeChecker() end

    -- Same deferred tail as step 6 of the full path, scoped to this header.
    C_Timer.After(0, function()
        for _, frame in ipairs(header) do
            if frame and frame.unit and frame:IsShown() then
                frame:Layout()
                self:UpdateFrameIndicators(frame, frame.unit)
            end
        end
        if self.FlushDeferredIndicatorUpdates then self:FlushDeferredIndicatorUpdates() end
    end)

    return true
end

-- Creates or updates the drag handle for a detached header.
-- The handle sits above the header (like the main BuzzardFrames anchor
-- handle) and displays the custom frame group's name.
-- Respects the tinyHandle profile setting.
function BF:SetupDetachedHeader(header)
    -- Grid2 verbatim: only do work for detached headers. Non-detached
    -- headers pass through AddHeader → SetupDetachedHeader as a no-op.
    if not header.isDetached then return end
    if not header._handle then
        -- Create the drag handle — matches the main anchor handle pattern
        -- from SetupModeUnlockMode.lua: BackdropTemplate, label FontString,
        -- RegisterForDrag, pinned above the header.
        local handle = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
        handle:SetSize(200, 16)
        handle:SetFrameStrata("MEDIUM")
        handle:SetFrameLevel(100)
        handle:SetBackdrop({
            bgFile = "Interface\\Buttons\\White8x8",
            edgeFile = "Interface\\Buttons\\White8x8",
            edgeSize = 1,
        })
        handle:SetBackdropColor(0.5, 0.2, 0.6, 0.8)
        handle:SetBackdropBorderColor(0.7, 0.4, 0.9, 1)
        handle:EnableMouse(true)
        handle:SetMovable(true)
        handle:RegisterForDrag("LeftButton")

        local label = handle:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetPoint("CENTER")
        label:SetTextColor(1, 1, 1)
        handle._label = label

        -- Pin the handle above the header, same pattern as the main anchor.
        local function SnapHandleToHeader()
            handle:ClearAllPoints()
            handle:SetPoint("BOTTOMLEFT", header, "TOPLEFT", 0, 2)
        end
        handle.SnapToParent = SnapHandleToHeader
        handle:HookScript("OnShow", SnapHandleToHeader)

        -- Drag: move the header, update handle position via OnUpdate during drag.
        -- NOTE: pet headers use SecureGroupPetHeaderTemplate (secure frame).
        -- StartMoving() on a secure frame taints insecure Lua, so we cannot
        -- drag the header directly. Instead, make the handle itself movable
        -- and use it as the drag proxy — then anchor the header to the handle
        -- on DragStop. Non-pet (custom frame) headers are plain frames and can
        -- call StartMoving() directly.
        if header.isPetFrame then
            -- Pet header is parented to its pet anchor frame, so drag the
            -- ANCHOR FRAME (the header follows). Moving the header directly
            -- would be anchor-frame-relative and SaveDetachedHeaderPosition
            -- (which reads the anchor frame) wouldn't capture the drag.
            handle:SetScript("OnDragStart", function()
                if InCombatLockdown() then return end
                local locked = BF.db and BF.db.global and BF.db.global.locked
                if locked == nil then locked = true end
                if locked then return end
                local af = BF:GetOrCreatePetAnchorFrame(header.petFlatID)
                local dragTarget = af or header
                dragTarget:SetMovable(true)
                dragTarget:StartMoving()
                header._dragTarget = dragTarget
                header.isMoving = true
                header:SetScript("OnUpdate", function() SnapHandleToHeader() end)
            end)
            handle:SetScript("OnDragStop", function()
                if not header.isMoving then return end
                local dragTarget = header._dragTarget or header
                dragTarget:StopMovingOrSizing()
                header._dragTarget = nil
                header.isMoving = nil
                header:SetScript("OnUpdate", nil)
                SnapHandleToHeader()
                BF:SaveDetachedHeaderPosition(header)
                BF:RestoreDetachedHeaderPosition(header)
                SnapHandleToHeader()
                BF:RefreshPanel("layoutSize")
            end)
        else
            handle:SetScript("OnDragStart", function()
                if InCombatLockdown() then return end
                local locked = BF.db and BF.db.global and BF.db.global.locked
                if locked == nil then locked = true end
                if locked then return end
                header:SetMovable(true)
                header:StartMoving()
                header.isMoving = true
                header:SetScript("OnUpdate", function() SnapHandleToHeader() end)
            end)
            handle:SetScript("OnDragStop", function()
                if not header.isMoving then return end
                header:StopMovingOrSizing()
                header.isMoving = nil
                header:SetScript("OnUpdate", nil)
                SnapHandleToHeader()
                BF:SaveDetachedHeaderPosition(header)
                BF:RestoreDetachedHeaderPosition(header)
                SnapHandleToHeader()
                BF:RefreshPanel("layoutSize")
            end)
        end

        handle:Hide()
        handle.header = header
        header._handle = handle
    end

    -- Update the label text to the group name
    local groupName
    if header.isPetFrame then
        local lp2 = self.rpDB and self.rpDB.profile and self.rpDB.profile.layouts
        local fl2 = lp2 and lp2.flatLayouts
        local petFlat = header.petFlatID and fl2 and fl2[header.petFlatID]
        local flatName = (petFlat and petFlat.name) or header.petFlatID or "Layout"
        groupName = flatName .. ": Pet Frames"
    else
        groupName = "Custom Frame Group: " .. (header.customGroupName or "Custom Frames")
    end
    if header._handle._label then
        header._handle._label:SetText(groupName)
    end

    -- Pet frame handles use blue (matching the main anchor handle)
    -- instead of purple (custom frame groups).
    if header.isPetFrame and header._handle then
        if header._handle.SetBackdropColor then
            header._handle:SetBackdropColor(0.1, 0.3, 0.6, 0.8)
            header._handle:SetBackdropBorderColor(0.2, 0.5, 0.9, 1)
        end
    end

    -- Apply tiny handle mode if active
    if self.db and self.db.profile and self.db.global.tinyHandle then
        self:ApplyTinyHandleToDetachedHeader(header)
    end
end

-- ── ApplyTinyHandleToDetachedHeader ─────────────────────────
-- Applies or removes tiny-handle mode on a single detached header's
-- handle, matching the pattern in ApplyTinyHandle for the main anchor.
function BF:ApplyTinyHandleToDetachedHeader(header)
    local handle = header._handle
    if not handle then return end
    local tiny = self.db and self.db.profile and self.db.global.tinyHandle

    if tiny then
        handle:SetSize(5, 5)
        handle:SetHitRectInsets(-10, -10, -10, 0)
        if handle.SetBackdropColor then
            if header.isPetFrame then
                handle:SetBackdropColor(0.1, 0.3, 0.6, 0.2)
                handle:SetBackdropBorderColor(0.2, 0.5, 0.9, 0.2)
            else
                handle:SetBackdropColor(0.5, 0.2, 0.6, 0.2)
                handle:SetBackdropBorderColor(0.7, 0.4, 0.9, 0.2)
            end
        end
        -- Hide all child fontstrings
        for i = 1, select("#", handle:GetRegions()) do
            local region = select(i, handle:GetRegions())
            if region and region.GetObjectType and region:GetObjectType() == "FontString" then
                region:Hide()
            end
        end
    else
        handle:SetSize(200, 16)
        handle:SetHitRectInsets(0, 0, 0, 0)
        if handle.SetBackdropColor then
            if header.isPetFrame then
                handle:SetBackdropColor(0.1, 0.3, 0.6, 0.8)
                handle:SetBackdropBorderColor(0.2, 0.5, 0.9, 1)
            else
                handle:SetBackdropColor(0.5, 0.2, 0.6, 0.8)
                handle:SetBackdropBorderColor(0.7, 0.4, 0.9, 1)
            end
        end
        -- Restore child fontstrings
        for i = 1, select("#", handle:GetRegions()) do
            local region = select(i, handle:GetRegions())
            if region and region.GetObjectType and region:GetObjectType() == "FontString" then
                region:Show()
                if handle._label and region == handle._label then
                    if header.isPetFrame then
                        local lp2 = BF.rpDB and BF.rpDB.profile and BF.rpDB.profile.layouts
                        local fl2 = lp2 and lp2.flatLayouts
                        local petFlat = header.petFlatID and fl2 and fl2[header.petFlatID]
                        local flatName = (petFlat and petFlat.name) or header.petFlatID or "Layout"
                        region:SetText(flatName .. ": Pet Frames")
                    else
                        region:SetText("Custom Frame Group: " .. (header.customGroupName or "Custom Frames"))
                    end
                end
            end
        end
    end
end

-- ── Detached header position save/restore (Grid2 pattern) ───────
-- Saves position as CENTER-relative offsets (matching the main anchor
-- system).  The anchor corner comes from cfgLayoutAnchor on the header.
-- Grid2 equivalent: Grid2Layout:SavePosition(header).
function BF:SaveDetachedHeaderPosition(header)
    if not header.headerPosKey then return end

    local anchor = header.cfgLayoutAnchor or "TOPLEFT"
    local ux, uy = UIParent:GetCenter()
    if not ux or not uy then return end

    -- CFG and pet headers are parented to their anchor frame, so their own
    -- edges are anchor-relative. Read the ANCHOR FRAME's corner (in UIParent
    -- coords) instead — the stable reference, mirroring raid's anchorX/anchorY.
    local refFrame = header
    if header.isCustomFrame then
        local af = self:GetOrCreateCFGAnchorFrame(header.customGroupIndex)
        if not af then return end
        refFrame = af
    elseif header.isPetFrame then
        local af = self:GetOrCreatePetAnchorFrame(header.petFlatID)
        if not af then return end
        refFrame = af
    end
    if not refFrame:GetLeft() then return end

    -- Pick the anchor-corner edge of the reference frame in UIParent coords.
    local ax = anchor:find("LEFT") and refFrame:GetLeft() or refFrame:GetRight()
    local ay = anchor:find("TOP")  and refFrame:GetTop()  or refFrame:GetBottom()
    if not ax or not ay then return end
    -- Store as CENTER-relative UI coords (not physical pixels).
    local cx = math.floor(ax - ux + 0.5)
    local cy = math.floor(ay - uy + 0.5)

    local cfgp = self.cfgDB.profile
    if not cfgp.customFrameGroupPositions then
        cfgp.customFrameGroupPositions = {}
    end
    cfgp.customFrameGroupPositions[header.headerPosKey] = { anchor, cx, cy }
end

-- Grid2 equivalent: Grid2Layout:RestoreHeaderPosition(header).
-- Returns true if a saved position was found and applied.
function BF:RestoreDetachedHeaderPosition(header)
    if InCombatLockdown() then return end
    if not header.headerPosKey then return end

    local cfgp = self.cfgDB.profile
    local positions = cfgp.customFrameGroupPositions
    if not positions then return end

    local pos = positions[header.headerPosKey]
    if not pos then return end

    local anchor, cx, cy = pos[1], pos[2], pos[3]
    local us = UIParent:GetEffectiveScale()

    -- CFG headers: position the ANCHOR FRAME to the stored corner, then pin
    -- the header to the same-named corner of the anchor frame (raid pattern,
    -- BFLayout PlaceHeaders first-header anchoring). Secondary-direction flips
    -- only change which corner the header pins to; the anchor frame's
    -- full-grid rect stays put, so the block stays in place.
    if header.isCustomFrame then
        local af = self:GetOrCreateCFGAnchorFrame(header.customGroupIndex)
        if not af then return end
        local afs = af:GetEffectiveScale()
        af:ClearAllPoints()
        af:SetPoint(anchor, UIParent, "CENTER", cx * us / afs, cy * us / afs)
        af:Show()  -- ensure a previously-hidden anchor frame is visible
        header:ClearAllPoints()
        header:SetPoint(anchor, af, anchor, 0, 0)
        header:Show()
        return true
    end

    -- Pet headers: same anchor-frame model as CFG. Position the pet anchor
    -- frame to the stored corner, then pin the header to its matching corner.
    if header.isPetFrame then
        local af = self:GetOrCreatePetAnchorFrame(header.petFlatID)
        if not af then return end
        -- Do NOT resize the anchor frame here. The CFG branch (which works
        -- across axis switches) does NOT resize inside RestoreDetachedHeaderPosition
        -- — callers size it beforehand (UpdatePetAnchorFrameSize runs before every
        -- RestoreDetachedHeaderPosition call). Resizing here transposes the rect
        -- between the saved corner read and the SetPoint, moving the block on a
        -- vertical<->horizontal switch. Match CFG exactly: size-then-restore, never
        -- resize during restore.
        local afs = af:GetEffectiveScale()
        af:ClearAllPoints()
        af:SetPoint(anchor, UIParent, "CENTER", cx * us / afs, cy * us / afs)
        af:Show()  -- ensure a previously-hidden anchor frame is visible
        header:ClearAllPoints()
        header:SetPoint(anchor, af, anchor, 0, 0)
        header:Show()
        return true
    end

    -- Other detached headers: pin the header directly to UIParent as before.
    -- Scale adjustment: stored cx/cy are in UIParent UI coords, so divide by
    -- the ratio header_scale/ui_scale.
    local s  = header:GetEffectiveScale()
    local ox = cx * us / s
    local oy = cy * us / s

    header:ClearAllPoints()
    header:SetPoint(anchor, UIParent, "CENTER", ox, oy)
    header:Show()
    return true
end

-- ── IterateHeaders with detached filtering (Grid2 pattern) ──────
-- Returns an iterator. detached=true iterates only detached headers;
-- detached=false/nil iterates only non-detached headers.
-- Grid2 equivalent: Grid2Layout:IterateHeaders(detached)
function BF:IterateDetachedHeaders(detached)
    if detached and not self.layoutHasDetached then
        return function() end  -- empty iterator
    end
    local i = 0
    local t = self.groupsUsed
    local d = detached or nil
    return function()
        repeat
            i = i + 1
            if i > #t then return end
        until d == (t[i].isDetached or nil)
        return i, t[i]
    end
end

-- Grid2: RunThrottled (GridUtils.lua:312-335) — verbatim port.
-- Delays and throttles the execution of a method or function: the call
-- runs `delay` seconds after the first request; requests arriving while
-- the timer chain is alive coalesce into at most one execution per
-- `delay` window. The chain self-destructs once a window passes with no
-- new requests, so this costs nothing in steady state.
do
    local After = C_Timer.After
    local counts = {}
    function BF:RunThrottled(object, method, delay)
        local func  = object[method] or method
        local count = counts[func]
        counts[func] = (count or 0) + 1
        if not count then
            local callback
            callback = function()
                if counts[func] > 0 then
                    counts[func] = 0
                    func(object)
                    After(delay or 0.1, callback)
                else
                    counts[func] = nil
                end
            end
            After(delay or 0.1, callback)
        end
    end
end

-- Grid2: RunSecure — queue a method to execute after combat ends.
-- Methods with lower priority override higher priority.
-- Returns true if in combat (call was deferred), nil if not.
do
    local sec_priority, sec_object, sec_method, sec_arg
    function BF:RunSecure(priority, object, method, arg)
        if InCombatLockdown() then
            -- §L5.2: make the combat swallow observable rather than
            -- theoretical (§L0.4). One print per swallowed call, and only
            -- when debugTiming is on.
            if self.SwitchSecureSwallow then
                self:SwitchSecureSwallow(priority, method,
                    sec_priority ~= nil and priority < sec_priority)
            end
            if not sec_priority or priority < sec_priority then
                sec_priority, sec_object, sec_method, sec_arg = priority, object, method, arg
            end
            return true
        end
    end
    function BF:RunSecure_OnRegenEnabled()
        if sec_priority then
            sec_priority = nil
            sec_object[sec_method](sec_object, sec_arg)
            return true
        end
        return false
    end
end

-- Grid2: ReloadLayout
function BF:ReloadLayout(force)
    if not UnitExists("player") then return end

    -- §L5.2 layout-switch harness. SwitchBegin is a single db.global read
    -- when debugTiming is off, and every SwitchMark below is then one
    -- boolean test. The buffer is printed once per switch by SwitchFlush --
    -- from the deferred tail when LoadLayout ran, from here otherwise.
    self:SwitchBegin(force and "ReloadLayout(force)" or "ReloadLayout")
    self:SwitchMark("sw:enter")

    -- Snapshot the previous context flag and the previously-resolved flat
    -- BEFORE ResolveContext mutates the context. We compare against the new
    -- values below to decide whether the resolved profile / section caches
    -- actually need to be rebuilt, instead of paying for
    -- InvalidateRaidProfileCache (which also wipes section and CFG caches)
    -- on every roster tick.
    local prevContextIsRaid = self._contextIsRaid
    local prevFlatID        = self._lastResolvedFlatID
    -- v98: when called from _ApplyProfileBody the context and flat were
    -- already flipped before we got here; use the snapshot it took first.
    local snap = self._reloadGateSnapshot
    if snap then
        prevContextIsRaid = snap.contextIsRaid
        prevFlatID        = snap.flatID
        self._reloadGateSnapshot = nil
    end

    -- Resolve group type info
    local gt = self:GetTrueActiveTab()
    self:ResolveContext(gt)
    self:SwitchMark("sw:contextResolved")

    -- Compute the active slot's resolved flat now that context is fresh.
    -- ResolveActiveFlat is cheap (≤5 table lookups, no allocations).
    local currentSlot   = self:GetActiveSlot()
    local currentFlatID = self:ResolveActiveFlat(currentSlot)

    -- Compute instance info for auto layouts.
    local _, instanceType, _, _, maxPlayers = GetInstanceInfo()
    if IsInRaid() then
        if instanceType == "none" then
            maxPlayers = math.max(GetNumGroupMembers(), 40)
        elseif not maxPlayers or maxPlayers == 0 then
            maxPlayers = 40
        end
    else
        maxPlayers = GetNumGroupMembers()
    end
    local maxGroup = math.ceil((maxPlayers or 1) / 5)
    if maxGroup < 1 then maxGroup = 1 end
    if maxGroup > 8 then maxGroup = 8 end

    -- Determine layout name
    local layoutName = self:ResolveLayoutName()

    -- _contextIsParty / _contextIsRaid were updated unconditionally by
    -- ResolveContext above. _resolvedProfile MUST be kept in lockstep with
    -- them — when the context flips between calls, render paths that read
    -- _resolvedProfile directly (ComputeFrameSize) and paths that branch
    -- on _contextIsParty (grow direction, sorting field-name selection)
    -- can otherwise end up consulting different flats in the same render.
    -- That's the source of the party-size + raid-grow-direction bleed.
    --
    -- Three gate conditions:
    --   contextFlipped — party↔raid transition (the classic bleed case;
    --     prevContextIsRaid == nil on the first call after load forces an
    --     initial resolve via this branch).
    --   flatChanged   — same context, but the active slot's resolved flat
    --     changed since last call (e.g. zoning from raidOpen to raid20, or
    --     a profile import that lands new slot assignments). Direct callers
    --     of ReloadLayout(true) — UpdatePartyFrames, UpdateGroupOrdering,
    --     UpdateFrameLayout, FrameSort callback, Options_Frames_Sorting
    --     setters — don't pre-set _resolvedProfile, so without this check
    --     LoadLayout would render against a stale flat.
    --   force         — explicit force-reload requested. Some Options
    --     setters call ReloadLayout(true) after mutating the active flat's
    --     contents (growDirection, scale, etc.) without changing slot/flatID;
    --     force here ensures we refresh the resolved profile against the
    --     mutated flat. Safe because every other writer of _resolvedProfile
    --     (ApplyProfile, Initialization, Options_Frames) uses the same
    --     GetRaidProfile/GetActivePartyProfile call we use here.
    -- On the common no-flip / no-slot-change / non-force path (most roster
    -- updates inside a stable context) the gate is skipped and the section
    -- caches stay valid.
    local contextFlipped = (self._contextIsRaid ~= prevContextIsRaid)
    local flatChanged    = (currentFlatID ~= prevFlatID)
    if contextFlipped or flatChanged or force then
        -- InvalidateRaidProfileCache wipes raidProfileCache, the active
        -- profile cache, _sectionProfileCache, and per-CFG-flat section
        -- caches. Force-true callers (Options setters that mutate the
        -- active flat's CONTENTS without changing slot/flatID) rely on
        -- this wipe so subsequent reads see their edits. Keep it inside
        -- the force branch.
        self:InvalidateRaidProfileCache()
        -- The _resolvedProfile getter call is only needed when the
        -- SLOT-LEVEL cache key changed. Every writer of _resolvedProfile
        -- in this addon routes through BF:SetResolvedProfile, which
        -- atomically updates _resolvedProfile and _lastResolvedFlatID
        -- together — so when contextFlipped and flatChanged are both
        -- false but force is true (the ApplyProfile→ReloadLayout(true)
        -- path), the writer has already brought _resolvedProfile and the
        -- cache key into sync. Calling the getter again would just
        -- re-compute the same value.
        if contextFlipped or flatChanged then
            self:SetResolvedProfile(self._contextIsRaid)
            -- v65 §6.3a: this is the one place the addon already knows the
            -- active flat moved. Custom Frame Groups with an aura override
            -- OFF resolve their aura values against that flat, and
            -- InvalidateRaidProfileCache above only drops the SECTION caches
            -- (_auraCache is derived and may only be rebuilt atomically by
            -- UpdateAuraSizeCache). Mark the affected CFG flats dirty; the
            -- next UpdateAuraSizeCache -- LoadLayout's, below, or whichever
            -- comes first -- rebuilds exactly those. Deliberately not in the
            -- bare `force` arm: force means the active flat's CONTENTS were
            -- mutated, which the Options setters already invalidate for.
            if self.InvalidateCFGAuraCachesFollowingActiveLayout then
                self:InvalidateCFGAuraCachesFollowingActiveLayout()
            end
        end
    end
    -- Auto Hide Groups by Instance Size: the instance's own capacity is a
    -- reload trigger in its own right. Zoning from a 30-man raid to a
    -- 20-man one changes which groups may render, but by default EVERY
    -- raid slot resolves to the same flat, so contextFlipped and
    -- flatChanged are both false -- and strictGroupLayout (the default)
    -- leaves layoutHasAuto nil, so the maxPlayers/maxGroup arm below is
    -- skipped too. Without this the old group set would survive the zone.
    -- Read from _resolvedProfile, which the gate above has just brought
    -- into sync with the active flat.
    local autoCap = self:GetInstanceMaxGroup()
    local autoCapChanged = false
    if self._contextIsRaid then
        local rp = self._resolvedProfile
        if rp and rp.autoHideGroupsByInstance
           and self._lastAutoCap ~= nil and autoCap ~= self._lastAutoCap then
            autoCapChanged = true
        end
    end
    self._lastAutoCap = autoCap
    self:SwitchMark("sw:gate", "contextFlipped=" .. tostring(contextFlipped)
        .. " flatChanged=" .. tostring(flatChanged)
        .. " force=" .. tostring(force and true or false)
        .. " autoCap=" .. tostring(autoCap)
        .. " autoCapChanged=" .. tostring(autoCapChanged))

    -- Check if reload is needed.
    --
    -- v93: contextFlipped / flatChanged added. They were computed above and
    -- used only to invalidate caches, never to decide whether to REBUILD --
    -- so the gate asked a lossy proxy question instead of the direct one.
    -- layoutName is one of exactly three strings ("By Group", "By Group
    -- Flowing", "By Role") derived from the resolved flat's SORTING mode
    -- (ResolveLayoutName), so two flats that happen to sort the same way
    -- produced no layoutName change and fell to the else arm -- which does
    -- nothing but SetGroupType's four field writes. Net effect: the active
    -- flat moved, _resolvedProfile was repointed at it and the section
    -- caches were dropped, but no header was rebuilt and no frame resized,
    -- so only a SUBSET of the new flat applied. Sizes, borders and aura
    -- geometry kept the previous flat's values until something else forced
    -- a layout. layoutHasAuto masked it whenever group size also changed,
    -- which is why it survived zoning between raid sizes.
    --
    -- Both flags are already computed, both already trigger the expensive
    -- InvalidateRaidProfileCache above (the code was already treating them
    -- as "something big changed"), and both are rare -- zoning, a role/spec
    -- override resolving a different flat, a profile import. In combat
    -- RunSecure queues the reload exactly as before.
    if layoutName ~= self._currentLayoutName
       or contextFlipped
       or flatChanged
       or (self.layoutHasAuto and (maxPlayers ~= self.instMaxPlayers or maxGroup ~= self.instMaxGroup))
       or autoCapChanged
       or force then

        -- A context flip or a flat change is a THEME change in the reference
        -- design's terms: the config that Layout() reads -- fonts, text
        -- positions, icon sizes -- may differ per flat, so every header
        -- child must re-Layout, not only the children of a header whose
        -- frame size moved. Grid2 does this by passing force=true from its
        -- theme reload, so UpdateFramesSizeForHeader's forceReload branch
        -- runs ("theme or profile changed, we need to Layout frames because
        -- icon/text sizes could change"). Before this, a flip that left the
        -- frame size unchanged skipped frame:Layout() for every existing
        -- child, and only frames created afterwards carried the new flat's
        -- text settings (user report: status text size wrong on some
        -- frames). Same three flags that already gate the invalidation
        -- above; a plain layout-name / auto-size change stays size-gated.
        self._forceReload = (force or contextFlipped or flatChanged) and true or nil
        -- Grid2 pattern: if in combat, queue ReloadLayout for after combat
        if not self:RunSecure(3, self, "ReloadLayout") then
            self:SetGroupType(gt, instanceType, maxPlayers, maxGroup)
            self:SwitchMark("sw:loadStart")
            self:LoadLayout(layoutName)
            self._forceReload = nil
        end
        -- Flushes now if LoadLayout was swallowed by the combat queue;
        -- otherwise the deferred tail owes us sw:tail and flushes there.
        self:SwitchFlush()
        return true
    else
        -- Nothing relevant changed: no layout switch, no context flip, no
        -- flat change, no auto-size change, no force. SetGroupType's field
        -- writes are all this path owes.
        --
        -- v93: an earlier pass added an UpdateAuraSizeCache() call here,
        -- guarded on (contextFlipped or flatChanged), to service the CFG
        -- aura-cache dirty flags the gate above sets. With those two
        -- conditions now IN the gate, this arm is unreachable while either
        -- is true, so that call could never fire -- removed rather than left
        -- as dead code. LoadLayout's own UpdateAuraSizeCache is the
        -- guaranteed servicer now, which also retires the "or whichever
        -- comes first" deferral described in the gate's CFG comment.
        self:SetGroupType(gt, instanceType, maxPlayers, maxGroup)
        self:SwitchMark("sw:noReloadNeeded")
        self:SwitchFlush()
    end
end

-- Grid2: LoadLayout
function BF:LoadLayout(layoutName)
    self:LoadMark("load:enter")
    self:LoadHBBegin()   -- §L5.1 headersBuilt drill-down; no-op unless detail
    local layout = self.layoutSettings[layoutName]
    if not layout then
        -- Fallback: if layout not found, generate a default "By Group"
        layout = self.layoutSettings["By Group"]
        layoutName = "By Group"
    end
    if not layout then return end

    self._currentLayoutName = layoutName

    -- Invalidate caches
    self:InvalidateRaidProfileCache()
    if self.InvalidateActiveProfileCache then self:InvalidateActiveProfileCache() end
    if self.WipeLayoutSizeCache then self:WipeLayoutSizeCache() end
    if self.unitToFrameCache then table.wipe(self.unitToFrameCache) end
    -- §L5.1: RefreshProfileCache's UpdateAuraSizeCache -- rebuild #5.
    self:LoadUASCTag("load:refreshProfileCache")
    if self.RefreshProfileCache then self:RefreshProfileCache() end

    -- Prime BF.AuraCache against the freshly-resolved profile BEFORE any
    -- header build dispatches frame:Layout() (which runs IconIndicator:Layout
    -- → BF:GetAuraCacheForFrame). Without this prime, indicators see the
    -- empty static defaults from Auras/AuraConfig.lua and wrappers are
    -- sized with fallback values instead of the user's actual settings.
    -- Grid2 avoids this because its indicators read profile state directly
    -- via RegisterIndicator → UpdateDB; BF's UpdateDB doesn't populate
    -- AuraCache, so the explicit prime must run here. Must come AFTER
    -- RefreshProfileCache (profile state is fresh) and BEFORE ResetHeaders
    -- / GenerateHeaders. See Docs/PEW_GRID2_REFACTOR_PLAN.md §6.7.
    -- §L5.1: rebuild #6, 12 lines after #5.
    self:LoadUASCTag("load:direct")
    if self.UpdateAuraSizeCache then self:UpdateAuraSizeCache() end
    self:LoadMark("load:auraCache")
    self:SwitchMark("sw:auraCache")

    -- Clear dispel/buffmatch caches so DebuffHighlight and BuffHighlight
    -- don't render stale state during the ResetHeaders → PlaceHeaders pass
    -- (frames get assigned units via OnAttributeChanged which triggers
    -- UpdateIndicators before any UNIT_AURA has fired for the new layout).
    local S_DISPEL = self.statuses and self.statuses.dispel
    if S_DISPEL and S_DISPEL.ClearAllCaches then S_DISPEL:ClearAllCaches() end
    local S_BUFFMATCH = self.statuses and self.statuses.buffmatch
    if S_BUFFMATCH and S_BUFFMATCH.ClearAllCaches then S_BUFFMATCH:ClearAllCaches() end

    -- Reset all headers (Grid2: ResetHeaders)
    self:ResetHeaders()

    -- Build headers from layout definition
    if layout[1] then
        -- Layout has explicit header definitions
        for index, layoutHeader in ipairs(layout) do
            if layoutHeader == "auto" then
                self:GenerateHeaders(layout.defaults, index)
            else
                self:AddHeader(layoutHeader, layout.defaults, index)
            end
        end
    elseif not layout.empty then
        -- No explicit entries = auto-generate (Grid2 default)
        self:GenerateHeaders(layout.defaults, 1)
    end

    -- Append custom frame group headers (Grid2: AddSpecialHeaders)
    self:AddCustomFrameHeaders()

    -- Append pet frame headers for flats with showPetFrames enabled
    self:AddPetHeaders()
    self:LoadHBEnd()
    self:LoadMark("load:headersBuilt")
    self:SwitchMark("sw:headers")

    -- Hide self in party: when hideSelf is set in the party profile,
    -- set showPlayer=false on main (non-custom, non-pet) headers so the
    -- SecureGroupHeader skips the player frame. Also drop showSolo=false
    -- because when solo, SecureGroupHeader_Update spawns the player via
    -- the showSolo branch regardless of showPlayer — both need to be off
    -- for the player frame to actually disappear while solo.
    -- Applied here (after AddCustomFrameHeaders) because isCustomFrame
    -- is set after AddHeader returns, so FixHeaderAttributes can't
    -- reliably distinguish main vs custom headers.
    -- Pet headers are excluded because showPlayer/showSolo on a
    -- SecureGroupPetHeaderTemplate control whether the player's OWN pet
    -- is shown — flipping them off for hideSelf would hide the pet too.
    if self._contextIsParty then
        local pp = self:GetActivePartyProfile()
        -- hideSelf moved to rpDB.profile.sorting.hideSelf (or
        -- flat.sorting.hideSelf when per-layout toggle is ON).
        local sp = self:GetSectionProfile("sorting", pp)
        local hide = sp and sp.hideSelf
        for _, header in ipairs(self.groupsUsed) do
            if not header.isCustomFrame and not header.isPetFrame then
                header:SetAttribute("showPlayer", not hide)
                if hide then
                    header:SetAttribute("showSolo", false)
                end
            end
        end
    end

    -- Solo custom frame groups: when solo, SecureGroupHeaderTemplate's
    -- groupFilter/roleFilter/strictFiltering prevent the player from
    -- showing because there's no raid roster. Check if the player
    -- matches the group's configured filters (role/class). If they
    -- match, clear the filter attributes so the header falls back to
    -- showSolo/showPlayer visibility. If they don't match, hide the
    -- header by setting showSolo=false.
    -- Attributes are restored when joining a group (ReloadLayout fires
    -- on roster change).
    if not IsInGroup() then
        local playerRole = self.playerSpecRole or "DAMAGER"
        local _, playerClass = UnitClass("player")
        local groups = self:GetCustomFrameGroups()
        for _, header in ipairs(self.groupsUsed) do
            if header.isCustomFrame and header:GetAttribute("showSolo") then
                local gi = header.customGroupIndex
                local grp = gi and groups[gi]
                local matches = true
                if grp then
                    -- Check role filter
                    if grp.roleFilterEnabled and grp.roleFilter then
                        local hasAnyRole = grp.roleFilter.TANK or grp.roleFilter.HEALER or grp.roleFilter.DAMAGER
                        if hasAnyRole and not grp.roleFilter[playerRole] then
                            matches = false
                        end
                    end
                    -- Check class filter
                    if matches and grp.classFilterEnabled and grp.classFilter then
                        local hasAnyClass = false
                        for _, cls in ipairs(BF.CLASS_SORT_ORDER_ALPHA) do
                            if grp.classFilter[cls] then hasAnyClass = true; break end
                        end
                        if hasAnyClass and not grp.classFilter[playerClass] then
                            matches = false
                        end
                    end
                end
                if matches then
                    header:SetAttribute("groupFilter", nil)
                    header:SetAttribute("roleFilter", nil)
                    header:SetAttribute("strictFiltering", nil)
                else
                    header:SetAttribute("showSolo", false)
                end
            end
        end
    end

    -- Grid2 verbatim: SetupMainFrame — ensure anchor has a valid size
    -- so it is visible if we are in combat after a UI reload.
    if self.anchorFrame and self.anchorFrame:GetWidth() == 0 then
        self.anchorFrame:SetSize(1, 1)
    end

    -- Place and show (Grid2: PlaceHeaders → UpdateSize → UpdateTextures → UpdateColor → UpdateVisibility)
    self:PlaceHeaders()
    self:UpdateSize()
    self:UpdateVisibility()
    self:LoadMark("load:placed")
    self:SwitchMark("sw:placed")

    -- Re-apply FrameSort ordering after layout rebuild (headers were reset).
    if self.FrameSortOnLayoutReloaded then self:FrameSortOnLayoutReloaded() end

    -- Sync the range checker now that groupsUsed is final.
    -- If context is disabled (party/raid toggle off), only keep the timer
    -- running when custom frame groups are present in groupsUsed.
    -- If context is enabled, SyncRangeChecker handles it normally.
    if self._framesActiveForContext == false then
        local anyCustom = false
        for _, h in ipairs(self.groupsUsed) do
            if h.isCustomFrame then anyCustom = true; break end
        end
        -- An active raid-style twin is an external range unit of its own
        -- (Range.lua roster_external), so the ticker must survive a context
        -- whose raid/party frames are disabled.
        if not anyCustom and self.twinFrames then
            for _, twin in ipairs(self.twinFrames) do
                if twin._bf_twinActive and twin.unit then anyCustom = true; break end
            end
        end
        if anyCustom then
            if self.SyncRangeChecker then self:SyncRangeChecker() end
        else
            if self.StopRangeChecker then self:StopRangeChecker() end
        end
    else
        if self.SyncRangeChecker then self:SyncRangeChecker() end
    end

    -- (Removed) self:ResizeAllFrames() — was destructive: dispatched
    -- per-child frame:Layout() which wiped just-registered private aura
    -- anchors via IconIndicator:Layout → ClearFrameAuraAnchors. Frame
    -- dimensions + scale are now applied earlier by
    -- FixHeaderAttributes → UpdateFramesSizeForHeader (which writes
    -- header.frameWidth/Height AND header:SetScale) BEFORE
    -- ForceFramesCreation triggers secure-header child pre-allocation,
    -- so BuzzardFrame_Init's one-shot frame:Layout() reads the correct
    -- values on its first (and only) call. ResizeAllFrames stays in
    -- the codebase for user-driven settings-change callers (frame width
    -- slider, etc.). See Docs/RESIZEALLFRAMES_GRID2_PLAN.md.

    -- Update main anchor handle label to show the active flat name.
    if self.anchorFrame and self.anchorFrame.handle then
        local ap = self._resolvedProfile
        local flatName = ap and ap.name or "BuzzardFrames"
        for i = 1, select("#", self.anchorFrame.handle:GetRegions()) do
            local region = select(i, self.anchorFrame.handle:GetRegions())
            if region and region.GetObjectType and region:GetObjectType() == "FontString" then
                region:SetText(flatName)
                break
            end
        end
    end

    -- Same flat, same size resolution, different parents: re-apply it to the
    -- raid-style twins (UnitFrames/Twins.lua) now that the headers are final.
    if self.RefreshTwinLayout then self:RefreshTwinLayout() end

    -- Deferred visual refresh (guarded by generation counter so rapid
    -- ReloadLayout calls — e.g. from a slider — don't let a stale callback
    -- run against already-reset headers.  Grid2 avoids this because its
    -- LoadLayout has no deferred tail; we need the guard here).
    self:LoadMark("load:exit")
    self:SwitchMark("sw:exit")
    self:SwitchPendingTail()
    self._loadLayoutGeneration = (self._loadLayoutGeneration or 0) + 1
    local gen = self._loadLayoutGeneration
    C_Timer.After(0, function()
        -- Superseded by a newer LoadLayout: do NOT flush the switch buffer
        -- here -- it already belongs to that newer switch, whose own tail
        -- will print it.
        if self._loadLayoutGeneration ~= gen then return end
        self:LoadMark("tail:enter")
        -- Deferred tail timing (db.global.debugTiming). This runs a frame
        -- AFTER LoadLayout returns, so it is invisible to any timing
        -- wrapped around the caller -- but the client still hitches on it.
        local dbg = self.db and self.db.global and self.db.global.debugTiming
            and self:IsDebugOutputEnabled()
        local tt0 = dbg and debugprofilestop() or 0
        if self.RefreshAllCustomContainersWithRebuild then
            self:RefreshAllCustomContainersWithRebuild()
        else
            if self.RefreshAllAuras then self:RefreshAllAuras() end
        end
        if dbg then
            print(("|cff11ace9BF|r   [deferred] containers %7.1f ms")
                :format(debugprofilestop() - tt0))
            tt0 = debugprofilestop()
        end
        self:LoadMark("tail:containers")
        if self.RefreshAllAbsorbs     then self:RefreshAllAbsorbs()     end
        -- Same reason as the AbsorbBars re-Layout below: CastBar:Layout
        -- snapshots the bar height and the container's height (overlay
        -- placement sizes itself as a fraction of it), both of which can
        -- still be 0 at LoadLayout build time.
        if self.RefreshAllCastBars    then self:RefreshAllCastBars()    end
        if dbg then
            print(("|cff11ace9BF|r   [deferred] absorbs+cast %7.1f ms")
                :format(debugprofilestop() - tt0))
            tt0 = debugprofilestop()
        end
        -- §L5.1 [REV3]: RefreshAllAbsorbs + RefreshAllCastBars are the FIRST
        -- TWO of the four frame walks in this tail; the two explicit
        -- pairs(activeFrames) loops below are the other two.
        self:LoadMark("tail:castbars")

        -- Targeted re-Layout of just the AbsorbBars indicator.
        -- AbsorbBars:Layout snapshots hBar:GetWidth() to size
        -- absorbMissingHealth (Grid2 IndicatorBar.lua:32-35 pattern —
        -- bars also use snapshot-on-Layout). At LoadLayout build time
        -- hBar may be 0-wide; the snapshot then locks the bar at 0
        -- width until something re-runs Layout. Grid2 gets this via
        -- UpdateFramesSizeForHeader → frame:Layout() per child whenever
        -- header dimensions change. BF's removal of ResizeAllFrames from
        -- this tail (for PA reload-in-combat fix) means that broader
        -- re-dispatch is gone, so we explicitly re-Layout AbsorbBars
        -- here. This is the equivalent of Grid2's per-child dispatch
        -- scoped to ONE indicator — does NOT touch IconIndicator, so PA
        -- anchors aren't wiped.
        do
            local absorbBars = self.GetIndicatorByName and self:GetIndicatorByName("absorbBars")
            -- Grid2 rule: a Layout sweep reaches every registered frame
            -- (indicator:LayoutAllFrames walks registeredFrames), so a
            -- spare is laid out from the same config as the frames in
            -- service and needs nothing when it is later handed a unit.
            if absorbBars then absorbBars:LayoutAllFrames() end
        end
        -- Same bug class, same scoped fix, for nameText — the SECOND half of
        -- the first-login blank-name fix. The OnUnitChanged nameText:Layout
        -- re-run (fix #5) fires inside ForceFramesCreation at login, BEFORE
        -- the header is sized, so its snapshot-free Layout still computes
        -- geometry (width/anchor) from unsized frames. This tail runs one
        -- render frame later on settled geometry. Evidence this is the gap:
        -- after the stateless-Update refactor, JOINING A GROUP made the name
        -- appear — that path is OnUnitChanged → nameText:Layout on
        -- already-sized frames, i.e. exactly what this pass provides at
        -- login. Update is called after Layout so the text repaints into the
        -- corrected geometry. Scoped to ONE indicator, like absorbBars above
        -- — never a broad Layout dispatch (see warning below).
        do
            -- container FIRST: it is the anchor target of the name's clip
            -- frame (nameClip:SetAllPoints(container)). Container:Layout does
            -- ClearAllPoints + SetPoint, i.e. exactly the engine rect rebuild
            -- the login build window can leave stale — Container:Update is a
            -- deliberate no-op, so no event-driven path ever re-anchors it.
            -- Scoped single-indicator dispatch (does NOT touch IconIndicator,
            -- so private-aura anchors are safe — see warning below).
            local containerInd = self.GetIndicatorByName and self:GetIndicatorByName("container")
            local nameInd = self.GetIndicatorByName and self:GetIndicatorByName("nameText")
            -- Same rule: Layout over every registered frame, Update over
            -- the ones holding a unit.
            if containerInd then containerInd:LayoutAllFrames() end
            if nameInd then
                nameInd:LayoutAllFrames()
                nameInd:UpdateAllFrames()
            end
        end
        -- ────────────────────────────────────────────────────────────────
        -- DO NOT ADD ANY CALL HERE THAT INVOKES BF:LayoutFrame OR ANY
        -- FUNCTION THAT DISPATCHES IndicatorPrototype:Layout PER FRAME.
        -- ────────────────────────────────────────────────────────────────
        --
        -- This deferred tail runs ONE FRAME after LoadLayout populates
        -- headers and OnAttributeChanged → UpdateIndicators registers
        -- private aura anchors via IconIndicator:Update. Any LayoutFrame
        -- call here will dispatch IconIndicator:Layout which calls
        -- ClearFrameAuraAnchors and silently destroys those anchors.
        -- Re-registration only happens on the next unit-change event
        -- (gate: `unit ~= f.SF_PrivateAuraUnit`), so private auras
        -- vanish until the unit token next flips on the frame.
        --
        -- Specifically: RefreshAllHealAbsorbs (Core_Refresh.lua:374) was
        -- previously called here and caused exactly that bug. The non-
        -- destructive sibling RefreshAllHealAbsorbsPostBuild
        -- (Core_Refresh.lua:393) is what runs from this tail instead.
        --
        -- See PEW_GRID2_REFACTOR_PLAN.md for the diagnosis trace.
        -- §L5.1: closes the two explicit pairs(activeFrames) sweeps.
        self:LoadMark("tail:sweeps")
        if self.BumpGroupLabelGeomKey then self:BumpGroupLabelGeomKey() end
        if self.UpdateGroupLabels     then self:UpdateGroupLabels()     end
        if self.UpdateAllRanges       then self:UpdateAllRanges()       end
        -- HideBlizzardFrames retry (per PEW_GRID2_REFACTOR_PLAN §2): the
        -- OnEnable one-shot may have been skipped if combat was active at
        -- addon load. Re-attempt here only if the first pass didn't take.
        -- Self-guarded via _raidHidden so this is a no-op once successful.
        if self.HideBlizzardFrames and not self._raidHidden and not InCombatLockdown() then
            self:HideBlizzardFrames()
        end
        -- §6.4: explicit RefreshHandleVisibility after rebuild so newly-
        -- created groupsUsed headers get correct handle visibility under
        -- the current lock state, independent of the _handleWasShown flags
        -- (which only exist for headers that were live at last regen).
        -- Combat-guarded: RefreshHandleVisibility calls EnableMouse on
        -- the anchor frame which is protected in combat. PLAYER_REGEN_ENABLED
        -- already calls RefreshHandleVisibility (Initialization.lua handle-
        -- restore block), so skipping here in combat is safe — the post-
        -- combat path covers it.
        if self.RefreshHandleVisibility and not InCombatLockdown() then
            self:RefreshHandleVisibility()
        end
        if dbg then
            print(("|cff11ace9BF|r   [deferred] rest        %7.1f ms")
                :format(debugprofilestop() - tt0))
        end
        -- §L5.1: the login path is only genuinely finished HERE, one frame
        -- after LoadLayout returned. LOGIN->PLAYABLE is measured to this mark.
        self:LoadMark("tail:exit")
        self:SwitchMark("sw:tail")
        self:SwitchFlush(true)
    end)
end

-- ============================================================
-- 8. LAYOUT DEFINITIONS
-- ============================================================

local DEFAULT_ROLE       = "ASSIGNEDROLE"
local DEFAULT_ROLE_ORDER = "TANK,HEALER,DAMAGER,NONE"

-- "By Group" — one header per raid group (auto-generated), default layout
-- Used when strictGroupLayout is on. Each group gets its own column.
BF:AddLayout("By Group", {
    -- When no [1] entries and not empty, GenerateHeaders runs automatically.
    -- Each auto header gets groupFilter="1", groupFilter="2", etc.
})

-- "By Group Flowing" — single header, all units flow continuously,
-- grouped visually by raid group number. Used when strictGroupLayout is off.
-- Equivalent to a custom frame group with no filter, groupBy=GROUP, sortBy=INDEX.
BF:AddLayout("By Group Flowing", {
    [1] = {
        maxColumns     = "auto",
        groupFilter    = "auto",
        groupBy        = "GROUP",
        groupingOrder  = "1,2,3,4,5,6,7,8",
    },
})

-- "By Role" — single header grouping all units by role
BF:AddLayout("By Role", {
    [1] = {
        maxColumns     = "auto",
        groupFilter    = "auto",
        groupBy        = DEFAULT_ROLE,
        groupingOrder  = DEFAULT_ROLE_ORDER,
        sortMethod     = "NAME",
    },
})

-- "By Group & Role" — per-group headers, each sorted by role within
BF:AddLayout("By Group & Role", {
    defaults = {
        groupBy       = DEFAULT_ROLE,
        groupingOrder = DEFAULT_ROLE_ORDER,
        sortMethod    = "NAME",
    },
    -- auto-generated per-group headers inherit the defaults
})

-- "None" — empty layout, no headers shown
BF:AddLayout("None", {
    empty = true,
})

-- ============================================================
-- 9. BACKWARD COMPATIBILITY SHIMS
-- These ensure old call sites still work during transition.
-- ============================================================

-- (Removed) BF:CreateMainHeader — was an extra layout-build entry
-- point that duplicated GroupChanged → GroupTypeChanged → ApplyProfile
-- → ReloadLayout(true). Removing it eliminated the double-rebuild on
-- every reload that was destroying private aura anchors registered
-- against the first rebuild's frames. Grid2 parity: GroupChanged is
-- the sole entry point into the layout build pipeline on
-- PLAYER_ENTERING_WORLD.

-- Old UpdatePartyFrames → delegates to ReloadLayout
function BF:UpdatePartyFrames()
    if InCombatLockdown() then return end
    self:ReloadLayout(true)
end

-- Old UpdateGroupOrdering → delegates to ReloadLayout
function BF:UpdateGroupOrdering()
    if InCombatLockdown() then return end
    self:ReloadLayout(true)
end

-- Old UpdateFrameLayout → delegates to ReloadLayout
function BF:UpdateFrameLayout()
    if InCombatLockdown() then return end
    self:ReloadLayout(true)
end

-- Old RebuildHeaders → delegates to LoadLayout with current name
function BF:RebuildHeaders()
    if InCombatLockdown() then return end
    self:LoadLayout(self._currentLayoutName or "By Group")
end

-- Old ResizeAllFrames → update frame sizes on all active headers
-- This is the main entry point used by SetupModeUnlockMode.lua and Options.
-- Grid2 pattern: updates initial-width/height on child frames and calls
-- UpdateHeaders() to let SecureGroupHeaderTemplate handle positioning.
function BF:ResizeAllFrames()
    if InCombatLockdown() then return end
    local lp = self.rpDB.profile.layouts

    -- Don't resize real frames while setup mode is editing a flat whose
    -- type / dimensions don't match the active flat. Test frames handle their
    -- own sizing; touching the real frames here would leave them mis-sized on
    -- setup mode exit.
    if BF.db.global.setupModeActive and not self:ActiveMatchesModifying() then
        return
    end

    -- Determine dimensions
    if self._contextIsRaid == nil then self:ResolveContext() end
    local useRaid = self._contextIsRaid

    local ap = self._resolvedProfile
    if not ap then
        self:InvalidateRaidProfileCache()
        ap = useRaid and self:GetRaidProfile() or self:GetActivePartyProfile()
    end
    local width  = ap.frameWidth  or (useRaid and 70 or 100)
    local height = ap.frameHeight or (useRaid and 40 or 68)
    local scale, scaleIndicators
    if ap.enableFrameScale then
        scale           = ap.frameScale or 1.0
        scaleIndicators = ap.scaleIndicators ~= false
    else
        scale           = 1.0
        scaleIndicators = true
    end

    local headerScale = self:ComputeHeaderScale()
    local layoutWidth, layoutHeight
    if scaleIndicators then
        layoutWidth  = self:PixelRound(width)
        layoutHeight = self:PixelRound(height)
    else
        headerScale  = 1.0
        layoutWidth  = self:PixelRound(width  * scale)
        layoutHeight = self:PixelRound(height * scale)
    end

    -- scaleRaidToFit
    if lp.scaleRaidToFit and useRaid then
        local spacingH = ap.frameSpacingH or 0
        -- v93: re-round -- twin of the call in _ResolveHeaderSizeAndScale.
        layoutWidth = self:PixelRound(self:GetFitFrameWidth(layoutWidth, spacingH))
    end

    -- Apply to all active headers
    for _, header in ipairs(self.groupsUsed) do
        -- Custom frame groups always use GetFramesSizeForHeader (which baselines
        -- against raid40 and respects cfFrameWidth/cfFrameHeight overrides).
        -- Never fall back to layoutWidth/layoutHeight for custom frames, which
        -- would apply party dimensions when in a party context.
        local thisScale  = headerScale
        local thisWidth  = layoutWidth
        local thisHeight = layoutHeight
        if header.isCustomFrame then
            -- Always resolve from GetFramesSizeForHeader — this uses GetCustomFrameBaseSize
            -- (raid40 profile) as the floor, with cfFrameWidth/cfFrameHeight on top.
            thisWidth, thisHeight = self:GetFramesSizeForHeader(header)
            if header.cfEnableFrameScale and header.cfFrameScale then
                local cfS  = header.cfFrameScale
                local cfSI = header.cfScaleIndicators ~= false
                if cfSI then
                    -- v93: shared device-pixel snap (see BF:SnapScaleForSize). These
                    -- dimensions are already PixelRound'd; snapping them against
                    -- UIParent:GetEffectiveScale() here applied the correction on a
                    -- second, coarser grid and made rendered width non-monotonic.
                    thisScale = self:SnapScaleForSize(cfS, thisWidth, thisHeight)
                else
                    -- Don't scale indicators: frame dimensions absorb the scale, header stays 1.0
                    thisScale  = 1.0
                    thisWidth  = self:PixelRound(thisWidth  * cfS)
                    thisHeight = self:PixelRound(thisHeight * cfS)
                end
            end
        elseif header.isPetFrame then
            -- Scale the pet header exactly like the custom-frame branch above:
            -- start at 1.0 and only apply a scale when the flat's
            -- enableFrameScale/frameScale pair is set. Pet header is parented
            -- to UIParent, so this SetScale is the only scale applied.
            thisWidth, thisHeight = self:GetFramesSizeForHeader(header)
            thisScale = 1.0
            local lp2  = self.rpDB and self.rpDB.profile and self.rpDB.profile.layouts
            local fl2  = lp2 and lp2.flatLayouts
            local petFlat = header.petFlatID and fl2 and fl2[header.petFlatID]
            if petFlat and petFlat.enableFrameScale and petFlat.frameScale then
                local cfS  = petFlat.frameScale
                local cfSI = petFlat.scaleIndicators ~= false
                if cfSI then
                    -- v93: shared device-pixel snap (see BF:SnapScaleForSize). These
                    -- dimensions are already PixelRound'd; snapping them against
                    -- UIParent:GetEffectiveScale() here applied the correction on a
                    -- second, coarser grid and made rendered width non-monotonic.
                    thisScale = self:SnapScaleForSize(cfS, thisWidth, thisHeight)
                else
                    thisScale  = 1.0
                    thisWidth  = self:PixelRound(thisWidth  * cfS)
                    thisHeight = self:PixelRound(thisHeight * cfS)
                end
            end
        end

        header:SetScale(thisScale)
        header.frameWidth  = thisWidth
        header.frameHeight = thisHeight
    end

    -- Grid2 pattern: call Layout() on all children of all headers,
    -- then UpdateHeaders() to let SecureGroupHeader re-run.
    if self.InvalidateActiveProfileCache then self:InvalidateActiveProfileCache() end
    for _, header in ipairs(self.groupsUsed) do
        for _, frame in ipairs(header) do
            frame:Layout()
        end
    end
    self:UpdateHeaders()

    -- Twins take their size from the same flat but through their own holders
    -- (UnitFrames/Twins.lua); the groupsUsed walks above cannot reach them.
    -- Forced, for the same reason as in BF:LayoutAllFrames: the per-child
    -- frame:Layout() above is unconditional once we are in here.
    if self.RefreshTwinLayout then self:RefreshTwinLayout(true) end

    -- Grid2 parity: frame:Layout() above already called Layout+Update on
    -- all indicators including private auras, so no separate PA sweep needed.

    -- Re-fit the anchor frame to the resized content. Harmless in corner
    -- mode (the pinned corner is also the content corner, and SetSize is
    -- change-guarded), REQUIRED in party Grow-from-Center mode: the box
    -- is pinned by its CENTER, so a content resize must re-fit the box or
    -- the frames hang off a stale-sized box's corner and drift off-pin
    -- (field report: setup preview no longer matched real frames after a
    -- resize -- the preview box re-fit, the real box didn't).
    self:UpdateSize()
end

-- Old UpdateFrameSpacing → update spacing on all active headers
-- Grid2 parity (GridLayout.lua:796-806 UpdateFramesSizeByRaidSize):
-- queue via RunSecure at priority 6 when called in combat. RunSecure's
-- strict-priority displacement means a lower-priority-number call (e.g.
-- a pri-2 _GroupTypeChangedExecute) will displace this — which is safe
-- because that path's rebuild is a superset of UpdateFrameSpacing's work.
-- Conversely, this pri-6 call would displace a queued pri-7
-- ApplyOUFPlayerLayout or pri-8 UpdateVisibility — to keep that safe, the
-- tail below explicitly runs ApplyOUFPlayerLayout and UpdateVisibility so
-- pri 6 remains a true superset of pri 7/8. See PEW_GRID2_REFACTOR_PLAN
-- §3.5, §3.6.
function BF:UpdateFrameSpacing()
    if self:RunSecure(6, self, "UpdateFrameSpacing") then return end

    -- Debounce: slider fires on every tick; batch into a single
    -- PlaceHeaders + ResizeAllFrames after the user stops dragging.
    if self._spacingTimer then
        self._spacingTimer:Cancel()
    end
    self._spacingTimer = C_Timer.NewTimer(0.15, function()
        self._spacingTimer = nil
        -- Re-check combat: the timer may fire while the player is in
        -- combat even though the original call wasn't.
        if self:RunSecure(6, self, "UpdateFrameSpacing") then return end
        -- Invalidate the resolved profile so PlaceHeaders reads fresh spacing.
        -- SetResolvedProfile atomically updates _resolvedProfile and the
        -- _lastResolvedFlatID cache key — see Core_ProfileAPI.lua.
        self:InvalidateRaidProfileCache()
        self:SetResolvedProfile(self._contextIsRaid)

        -- PlaceHeaders calls SetOrientation on each header which sets
        -- xOffset, yOffset, columnSpacing, and re-chains anchors.
        -- No full ReloadLayout needed — headers already exist.
        self:PlaceHeaders()
        self:UpdateSize()
        self:ResizeAllFrames()

        -- Superset tail (§3.6): keep pri 6 a superset of pri 7 (oUF layout)
        -- and pri 8 (anchor visibility) so a queued lower-priority-number
        -- displacement by this method doesn't drop their work.
        if self.ApplyOUFPlayerLayout then self:ApplyOUFPlayerLayout() end
        if self.UpdateVisibility     then self:UpdateVisibility()     end
    end)
end

-- Old ReanchorGroupHeaders → just reload
function BF:ReanchorGroupHeaders()
    if InCombatLockdown() then return end
    -- Force all headers to re-evaluate their children via Hide/Show.
    -- Then shrink any header with no visible children to 1x1 so it
    -- takes no visual space in the anchor chain (Grid2 pattern:
    -- Reset sets SetSize(1,1) and empty headers stay at that size).
    self:UpdateHeaders()
    for _, header in ipairs(self.groupsUsed) do
        if not header.isDetached then
            local child1 = header[1]
            if not child1 or not child1:IsVisible() then
                header:SetSize(1, 1)
            end
        end
    end
    self:PlaceHeaders()
    self:UpdateSize()
end

-- Backward compat: mainHeader / groupHeaders accessors
-- These allow SetupModeUnlockMode.lua to still iterate headers
-- without knowing the new internal structure.
-- mainHeader returns the first header in groupsUsed (or nil)
-- groupHeaders returns a table indexed 1-8 mapping to per-group headers
function BF:_GetMainHeader()
    return self.groupsUsed and self.groupsUsed[1]
end

function BF:_GetGroupHeaders()
    -- Build a compatibility table mapping group index → header
    local result = {}
    for _, header in ipairs(self.groupsUsed) do
        local gf = header:GetAttribute("groupFilter")
        if gf and tonumber(gf) then
            result[tonumber(gf)] = header
        end
    end
    return result
end

-- Debug: /run BuzzardFrames:DebugFit() — dump everything relevant to scaleRaidToFit
function BF:DebugFit()
    if not self:IsDebugOutputEnabled() then return end
    local lp = self.rpDB and self.rpDB.profile and self.rpDB.profile.layouts
    print("|cff00ff00===== BF DebugFit =====|r")
    print(string.format("  scaleRaidToFit=%s scaleRaidToFitMaxWidth=%s",
        tostring(lp and lp.scaleRaidToFit), tostring(lp and lp.scaleRaidToFitMaxWidth)))
    print(string.format("  IsInRaid=%s NumMembers=%s", tostring(IsInRaid()), tostring(GetNumGroupMembers())))
    local rp = self:GetRaidProfile()
    print(string.format("  raid flat name=%s frameWidth=%s frameSpacingH=%s",
        tostring(rp and rp.name), tostring(rp and rp.frameWidth), tostring(rp and rp.frameSpacingH)))
    print(string.format("  _contextIsRaid=%s _contextIsParty=%s",
        tostring(self._contextIsRaid), tostring(self._contextIsParty)))
    print(string.format("  occupiedGroups=%s", tostring(self:GetOccupiedGroupCount())))
    local sp = self:GetSectionProfile("sorting", rp)
    print(string.format("  sortingMode=%s strictGroupLayout=%s unitsPerColumn=%s",
        tostring(sp and sp.sortingMode), tostring(sp and sp.strictGroupLayout), tostring(sp and sp.unitsPerColumn)))
    print(string.format("  groupsUsed=%d", #self.groupsUsed))
    for i, header in ipairs(self.groupsUsed) do
        if not header.isDetached then
            local child = header[1]
            local childW = child and child:GetWidth() or -1
            print(string.format("  header%d frameWidth=%s scale=%.3f child:GetWidth()=%.2f",
                i, tostring(header.frameWidth), header:GetScale(), childW))
        end
    end
    print("|cff00ff00========================|r")
end

-- Debug: /run BuzzardFrames:DebugGroupVisibility()
function BF:DebugGroupVisibility()
    if not self:IsDebugOutputEnabled() then return end
    local ap = self._resolvedProfile
    print("|cff00ff00[BF Debug]|r _contextIsRaid="..tostring(self._contextIsRaid)
        .." _contextIsParty="..tostring(self._contextIsParty)
        .." groupsUsed="..#self.groupsUsed)
    local pop = self:GetPopulatedGroups()
    local popStr = ""
    for i = 1, 8 do popStr = popStr .. i .. "=" .. tostring(pop[i] or false) .. " " end
    print("|cff00ff00[BF Debug]|r PopulatedGroups: " .. popStr)
    print("|cff00ff00[BF Debug]|r InRaid=" .. tostring(IsInRaid()) .. " NumMembers=" .. GetNumGroupMembers())
    for i, header in ipairs(self.groupsUsed) do
        local gf = header:GetAttribute("groupFilter") or "nil"
        local shown = header:IsShown()
        local childCount = 0
        local ci = 1
        while header:GetAttribute("child"..ci) do childCount = childCount + 1; ci = ci + 1 end
        local sg = ap and ap.showGroup
        local gi = tonumber(gf)
        local sgVal = (sg and gi) and sg[gi] or "nil"
        print(string.format("  Header %d: gf=%s shown=%s children=%d showGroup=%s detached=%s custom=%s",
            i, gf, tostring(shown), childCount, tostring(sgVal), tostring(header.isDetached), tostring(header.isCustomFrame)))
    end
end

-- ============================================================
-- 10. DEBUG
-- ============================================================
function BF:DebugPetHeader()
    if not self:IsDebugOutputEnabled() then return end
    for _, header in ipairs(self.groupsUsed) do
        if header.isPetFrame then
            print("|cff00ff00[BF PetDebug]|r isPetFrame="..tostring(header.isPetFrame).." petFlatID="..tostring(header.petFlatID))
            print("  point="..tostring(header:GetAttribute("point")))
            print("  xOffset="..tostring(header:GetAttribute("xOffset")))
            print("  yOffset="..tostring(header:GetAttribute("yOffset")))
            print("  columnAnchorPoint="..tostring(header:GetAttribute("columnAnchorPoint")))
            print("  columnSpacing="..tostring(header:GetAttribute("columnSpacing")))
            print("  maxColumns="..tostring(header:GetAttribute("maxColumns")))
            print("  unitsPerColumn="..tostring(header:GetAttribute("unitsPerColumn")))
            print("  filterOnPet="..tostring(header:GetAttribute("filterOnPet")))
            print("  useOwnerUnit="..tostring(header:GetAttribute("useOwnerUnit")))
            print("  showRaid="..tostring(header:GetAttribute("showRaid")))
            print("  showParty="..tostring(header:GetAttribute("showParty")))
            print("  isDetached="..tostring(header.isDetached))
            print("  headerName="..tostring(header:GetName()))
            local lp = self.rpDB and self.rpDB.profile and self.rpDB.profile.layouts
            local fl = lp and lp.flatLayouts
            local petFlat = header.petFlatID and fl and fl[header.petFlatID]
            if petFlat then
                print("  flat.petGrowDirection="..tostring(petFlat.petGrowDirection))
                print("  flat.petSecondaryGrowDirection="..tostring(petFlat.petSecondaryGrowDirection))
                print("  flat.petFrameSpacing="..tostring(petFlat.petFrameSpacing))
            else
                print("  petFlat=nil")
            end
            local childCount = 0
            local ci = 1
            while header:GetAttribute("child"..ci) do childCount = childCount + 1; ci = ci + 1 end
            print("  children="..childCount.." shown="..tostring(header:IsShown()))
            print("  header.cfgLayoutAnchor="..tostring(header.cfgLayoutAnchor))
            -- Rects (screen coords) to compare real vs setup-mode alignment.
            local function rect(f, label)
                if f and f.GetLeft and f:GetLeft() then
                    print(string.format("  %s L=%.1f R=%.1f T=%.1f B=%.1f scale=%.3f",
                        label, f:GetLeft(), f:GetRight(), f:GetTop(), f:GetBottom(), f:GetEffectiveScale()))
                else
                    print("  "..label.."=nil/no-rect")
                end
            end
            local af = self.petAnchorFrames and self.petAnchorFrames[header.petFlatID]
            rect(af, "petAnchorFrame")
            rect(header, "realHeader")
            rect(header:GetAttribute("child1"), "realPet#1")
            -- Stored position
            local cfgp = self.cfgDB and self.cfgDB.profile
            local pos = cfgp and cfgp.customFrameGroupPositions
                        and cfgp.customFrameGroupPositions["petFrame_"..tostring(header.petFlatID)]
            if pos then
                print(string.format("  stored petFrame_ = {%s, %s, %s}",
                    tostring(pos[1]), tostring(pos[2]), tostring(pos[3])))
            else
                print("  stored petFrame_ = nil")
            end
            -- Setup-mode test header + cell #1 (globals created by SetupModePetFrames).
            local th = _G["BFPetTestHeader"]
            rect(th, "testHeader")
            rect(_G["BFPetTestFrame_1"], "testCell#1")
            return
        end
    end
    print("|cff00ff00[BF PetDebug]|r No pet header found in groupsUsed")
end

function BF:DebugSpacing()
    if not self:IsDebugOutputEnabled() then return end
    local _, physH = GetPhysicalScreenSize()
    local uiScale  = UIParent:GetEffectiveScale()
    local perfect  = 768 / physH
    local mult     = (uiScale > 0) and (perfect / uiScale) or 1

    print("|cff00ff00===== BF DebugSpacing =====|r")
    print(string.format("  physH=%d  uiScale=%.6f  mult(1px in UI)=%.6f", physH, uiScale, mult))

    if self.anchorFrame then
        local s  = self.anchorFrame:GetEffectiveScale()
        local lf = self.anchorFrame:GetLeft()
        local tp = self.anchorFrame:GetTop()
        local lfPx = lf and (lf * s) or 0
        local tpPx = tp and (tp * s) or 0
        local lfFrac = lfPx - floor(lfPx + 0.5)
        local tpFrac = tpPx - floor(tpPx + 0.5)
        print(string.format("  anchor TOPLEFT: %.4fpx, %.4fpx  frac=(%.4f, %.4f)  %s",
            lfPx, tpPx, lfFrac, tpFrac,
            (math.abs(lfFrac) < 0.01 and math.abs(tpFrac) < 0.01)
                and "|cff00ff00ALIGNED|r" or "|cffff4444NOT ALIGNED|r"))
    end

    print(string.format("  Active layout: %s  (%d headers in groupsUsed)", tostring(self._currentLayoutName), #self.groupsUsed))

    local function dumpHeader(h, label)
        if not h then print("  " .. label .. ": nil"); return end
        local fw   = h.frameWidth  or 0
        local fh   = h.frameHeight or 0
        local xOff = h:GetAttribute("xOffset")      or 0
        local yOff = h:GetAttribute("yOffset")      or 0
        local cSpc = h:GetAttribute("columnSpacing") or 0
        local pt   = h:GetAttribute("point")         or "?"
        local stepH = xOff
        local stepV = math.abs(yOff)
        local stepHpx = stepH * uiScale
        local stepVpx = stepV * uiScale
        local hOK = math.abs(stepHpx - floor(stepHpx + 0.5)) < 0.001
        local vOK = math.abs(stepVpx - floor(stepVpx + 0.5)) < 0.001
        print(string.format("  |cffffcc00[%s]|r fw=%s fh=%s xOff=%.4f yOff=%.4f cSpc=%.4f pt=%s gf=%s",
            label, tostring(fw), tostring(fh), xOff, yOff, cSpc, pt,
            tostring(h:GetAttribute("groupFilter") or "nil")))
        print(string.format("    stepH=%.6f -> %.6fpx  %s",
            stepH, stepHpx, hOK and "|cff00ff00WHOLE|r" or "|cffff4444FRACTIONAL|r"))
        print(string.format("    stepV=%.6f -> %.6fpx  %s",
            stepV, stepVpx, vOK and "|cff00ff00WHOLE|r" or "|cffff4444FRACTIONAL|r"))
    end

    local printed = false
    for i, header in ipairs(self.groupsUsed) do
        if header:IsShown() then
            dumpHeader(header, "Header" .. i)
            printed = true
        end
    end
    if not printed then print("  No visible headers found.") end
    print("|cff00ff00============================|r")
end

-- Perf plan §L5.1 load-time mark: 233 KB (.toc 113).
if BuzzardFrames then BuzzardFrames:LoadMark("chunk:bfLayout") end
