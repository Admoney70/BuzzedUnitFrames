-- ============================================================
-- BuzzardFrames: Auras.lua
-- Standard aura (buff/debuff) display and private aura anchoring.
-- ============================================================
local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

-- v93: hoisted out of BF:UpdateStandardAuras, which allocated this table on
-- every call, per frame. Contents are constant.
-- v67: "buffHighlight" was removed from this list (12.1-only; the indicator
-- read BuffMatch getters that no longer exist, so the whole file went).
local AURA_INDICATORS = {
    "bigDefIcons",
    "buffsAndContainers", "missingRaidBuff",
    "debuffIcons", "dispelDebuffBorder",
}

local math_floor        = math.floor
local ipairs, pairs     = ipairs, pairs
local table_wipe        = table.wipe
local select            = select
local InCombatLockdown  = InCombatLockdown
local C_Timer           = C_Timer
local wipe              = wipe


-- Converts a border size in local frame units to the nearest value that
-- maps to a whole number of screen pixels, preventing blurry aura icon borders.
local function PixelPerfectSize(n)
    local uiScale = UIParent:GetEffectiveScale()
    return math.max(1, math_floor(n * uiScale + 0.5)) / uiScale
end

-- Helper functions to check if a value is secret/protected
-- These functions are provided by WoW in Midnight (11.1+)
local issecretvalue = issecretvalue or function(val) return false end
local canaccessvalue = canaccessvalue or function(val) return true end

-- ============================================================
-- DETERMINE GROW DIRECTION FROM ANCHOR POSITION
-- Automatically sets logical grow direction based on anchor.
-- Left anchors grow right, right anchors grow left, etc.
-- ============================================================
local function GetGrowDirectionFromAnchor(anchorPoint)
    -- LEFT, TOPLEFT, BOTTOMLEFT -> grow RIGHT
    if anchorPoint == "LEFT" or anchorPoint == "TOPLEFT" or anchorPoint == "BOTTOMLEFT" then
        return "RIGHT"
    end
    -- RIGHT, TOPRIGHT, BOTTOMRIGHT -> grow LEFT
    if anchorPoint == "RIGHT" or anchorPoint == "TOPRIGHT" or anchorPoint == "BOTTOMRIGHT" then
        return "LEFT"
    end
    -- TOP -> grow DOWN
    if anchorPoint == "TOP" then
        return "DOWN"
    end
    -- BOTTOM -> grow UP
    if anchorPoint == "BOTTOM" then
        return "UP"
    end
    -- Default fallback
    return "LEFT"
end

BF.PixelPerfectSize = PixelPerfectSize

-- ============================================================
-- MAX AURA SLOTS
-- ============================================================
local MAX_BUFFS   = 8
local MAX_DEBUFFS = 8
BF.MAX_BUFFS  = MAX_BUFFS
BF.MAX_DEBUFFS = MAX_DEBUFFS

-- C_UnitAuras upvalues removed; cooldown helpers are now inline in indicators.

-- ============================================================
-- SHARED COOLDOWN HELPERS
-- UpdateCooldownDisplay / ApplyCooldown / applyDebuffDurColors have been
-- removed. All cooldown display logic is now inline in each indicator's
-- Update function (Grid2 pattern: stamp config at Layout time, inline
-- SetCooldownFromExpirationTime + UpdateIconColorCurve at update time).
-- See AuraConfig.lua for BF.UpdateIconColorCurve.
-- ============================================================

-- ============================================================
-- PUBLIC: UPDATE STANDARD AURAS
-- Full-refresh: runs all aura indicators on a single frame.
-- Called from RefreshAllAuras, RefreshBigDef, and other paths
-- that need to force-update all aura visuals (settings changes,
-- spec changes, raid↔party flip).
--
-- Normal UNIT_AURA updates go through the per-status
-- UpdateIndicators path instead (only affected indicators run).
-- ============================================================
function BF:UpdateStandardAuras(frame)
    if not frame or not frame.unit then return end
    local unit = frame.unit

    -- v93: the staleness guard that stood here is GONE, and with it
    -- AuraCache.isRaid. It read
    --     BF.AuraCache.db ~= self.db.profile or BF.AuraCache.isRaid ~= <live>
    -- but AuraCache.db was deleted in v93 (see the BF.AuraCache declaration in
    -- AuraConfig.lua), so the first clause was permanently true, Lua
    -- short-circuited the `or`, and the isRaid comparison never executed --
    -- meaning UpdateAuraSizeCache ran UNCONDITIONALLY on every call, once per
    -- frame. The isRaid arm had been degenerate even before that: it compared
    -- a raw IsInRaid() read against a field written from ResolveActiveIsRaid(),
    -- which prefers _contextIsRaid -- two sources that disagree in any
    -- arena/party/scenario instance.
    --
    -- Nothing here needs the rebuild. Every caller either rebuilds explicitly
    -- first (RefreshAllAuras, RefreshCFGAurasOnly, RefreshBigDef) or is a
    -- runtime edge with no settings change (the suppression edge below,
    -- InvalidateAuraPositionCache, the phase-change sweep in BFStatus). The
    -- flat/context case is serviced by LoadLayout's own UpdateAuraSizeCache,
    -- which BF:ReloadLayout now always reaches on a context flip or flat
    -- change (v93 reload-gate fix).
    --
    -- Consequence to be aware of: a context flip that lands IN COMBAT defers
    -- LoadLayout to PLAYER_REGEN_ENABLED, so the aura cache now holds the
    -- previous flat's values for that fight instead of self-healing on the
    -- next aura refresh. That is the consistent behavior -- the headers and
    -- frames are still the old layout in that window too.

    -- Run all aura indicators on this frame.
    for i = 1, #AURA_INDICATORS do
        local ind = self:GetIndicatorByName(AURA_INDICATORS[i])
        if ind then ind:Update(frame, unit) end
    end
end

-- ============================================================
-- APPLY STACK TEXT STYLE
-- Re-applies font, size, border, and position to all existing
-- stack count FontStrings on every active frame's aura icons.
-- Called from RefreshAllAuras when text settings change.
-- ============================================================
function BF:ApplyStackTextStyle()
    -- Stack text settings live in rpDB.profile.auraText.stackText (v30),
    -- NOT in db.profile. Route through the active flat so the per-layout
    -- auraText toggle is honored at runtime. Pre-fix this function read
    -- from self.db.profile where every key returned nil, so the defaults
    -- (font=Roboto, size=9, border=OUTLINE, anchor=BOTTOMRIGHT) always
    -- fired and every icon's stack FontString was forcibly reset on every
    -- settings change.
    local isRaid = BF:ResolveActiveIsRaid()
    local activeFlat = isRaid and self:GetRaidProfile() or self:GetActivePartyProfile()
    local atp = self:GetSectionProfile("auraText", activeFlat) or {}
    local stP = atp.stackText or {}
    local show      = stP.showStackText ~= false
    local autoScale = stP.stackAutoScale == true
    local timerScale = stP.stackTimerScale or 1.0
    local fontPath  = BF:ResolveFontPathOr(stP.stackTextFont, "Interface\\AddOns\\BuzzardFrames\\Media\\Fonts\\RobotoCondensed-Bold.ttf")
    local fontSize  = stP.stackTextSize  or 9
    local fontBorder = stP.stackTextBorder or "OUTLINE"
    local anchor    = stP.stackTextAnchor or "BOTTOMRIGHT"
    local sx        = stP.stackTextX or 4
    local sy        = stP.stackTextY or -3
    -- Phase 2: showStackText/stackAutoScale/stackTimerScale are owned by
    -- BF:UpdateCrossSectionCache (written during RebuildAuraCacheScope).
    -- Callers of ApplyStackTextStyle that don't already trigger
    -- UpdateAuraSizeCache must call it explicitly — see setAT_Stack in
    -- Options/Options_AuraText.lua.

    local function ApplyToIcon(icon, iconSize)
        if not icon or not icon.count then return end
        if not show then
            icon.count:Hide()
            return
        end
        local sz = fontSize
        local sc = 1.0
        if autoScale then
            local sz12 = iconSize or BF.AuraCache.buffSize or 12
            sc = sz12 / 12 * timerScale
        end
        icon.count:SetFont(fontPath, sz, fontBorder)
        icon.count:SetScale(sc)
        icon.count:ClearAllPoints()
        icon.count:SetPoint(anchor, icon.count.tframe, anchor, sx, sy)
    end

    -- Auto-scale is relative to the icon size of the pool being walked,
    -- so each pool passes its OWN size. Every call site used to omit the
    -- argument, which collapsed sz12 to the BUFF size for debuffs, big
    -- defensives and custom containers alike -- harmless while the
    -- container path ignored stack settings entirely, but the 12.1 path
    -- now scales from the feature's real size (BF:ApplyStackTextSpec), so
    -- the options preview and the live frames would disagree.
    local ac = self.AuraCache or {}
    local buffSz   = ac._roundedBuffSize   or ac.buffSize   or 12
    local debuffSz = ac._roundedDebuffSize or ac.debuffSize or buffSz
    local bigDefSz = ac._roundedBigDefSize or ac.bigDefSize or buffSz

    for _, frame in next, self.registeredFrames do
        local fac = (self.GetAuraCacheForFrame and self:GetAuraCacheForFrame(frame)) or ac
        local fBuff   = fac._roundedBuffSize   or fac.buffSize   or buffSz
        local fDebuff = fac._roundedDebuffSize or fac.debuffSize or debuffSz
        local fBigDef = fac._roundedBigDefSize or fac.bigDefSize or bigDefSz
        if frame.buffFrames then
            for _, icon in ipairs(frame.buffFrames) do ApplyToIcon(icon, fBuff) end
        end
        if frame.debuffFrames then
            for _, icon in ipairs(frame.debuffFrames) do ApplyToIcon(icon, fDebuff) end
        end
        if frame.bigDefIcons then for i=1,#frame.bigDefIcons do ApplyToIcon(frame.bigDefIcons[i], fBigDef) end end
        -- Custom container icons. Each container resolves its own size
        -- (BF:ResolveContainerGeometry), and the icon carries it as its
        -- rendered width -- cheaper and more reliable than re-resolving
        -- the container spec here. Falls back to the buff size before the
        -- first layout has sized the pool.
        if frame.SF_CustomContainerIcons then
            for _, pool in pairs(frame.SF_CustomContainerIcons) do
                for _, icon in ipairs(pool) do
                    local w = icon.GetWidth and icon:GetWidth() or 0
                    ApplyToIcon(icon, (w > 0) and w or fBuff)
                end
            end
        end
    end
end

-- ============================================================
-- REFRESH ALL AURAS (called from BF:RefreshAll)
-- ============================================================
function BF:RefreshAllAuras()
    -- Vehicle defer (see the block above RescanAllAuraContainers's event
    -- frame): config re-application in a vehicle corrupts group assignment.
    if self:DeferAuraRefreshInVehicle() then return end
    -- RefreshAllAuras is the big-hammer refresh path: it's called from
    -- settings flips, PixelPerfect rebuilds, and many other "something
    -- non-trivial just changed" sites. Mark every flat's _auraCache
    -- dirty so UpdateAuraSizeCache rebuilds them all (per-flat callers
    -- can use InvalidateFlatAuraCache for finer-grained refreshes).
    if self.InvalidateAllFlatAuraCaches then self:InvalidateAllFlatAuraCaches() end
    -- Wipe container icon identity/position caches so all visual properties
    -- (font, size, duration settings) are re-applied on the next update.
    if self.InvalidateContainerIconCaches then self:InvalidateContainerIconCaches() end
    -- Wipe container settings cache so EnsureContainerSettings re-resolves
    -- useBuffDur, curves, font, etc. from the current profile values.
    if self.InvalidateClaimedSpellCache then self:InvalidateClaimedSpellCache() end
    -- v93: BOTH invalidations moved ABOVE the rebuild. InvalidateClaimedSpellCache
    -- itself calls InvalidateAllFlatAuraCaches (AuraCustomizations.lua), so with
    -- them below, this function ENDED with every flat marked dirty again --
    -- serviced only by the unconditional rebuild that BF:UpdateStandardAuras
    -- used to perform per frame in the loop below. With that guard deleted, the
    -- flag would have sat set until some unrelated later caller paid a full
    -- all-flats rebuild. Invalidate everything, then rebuild once.
    self:UpdateAuraSizeCache()
    self:ApplyStackTextStyle()
    for _, frame in next, self.registeredFrames do
        if frame and not frame._isPreviewFrame then
            self:ApplyAuraGeometry(frame)
            -- Grid2 pattern: re-stamp cooldown config + color curve
            -- targets after UpdateAuraSizeCache rebuilds the curves.
            -- Without this, icon.colorCurveObject references stale
            -- (pre-rebuild) curve objects.
            if frame.Layout then frame:Layout() end

            if frame.buffFrames then
                for i = 1, #frame.buffFrames do
                    local b = frame.buffFrames[i]
                    if b then b.SF_LastIndex = nil end
                end
            end
            if frame.debuffFrames then
                for i = 1, #frame.debuffFrames do
                    local d = frame.debuffFrames[i]
                    if d then d.SF_LastIndex = nil end
                end
            end

            -- PA state lives on the icon-indicator wrapper
            -- (frame.privateAuraIcons.SF_PrivateAuraUnit etc.) post-
            -- Grid2-parity refactor. It is NOT nilled here.
            -- RefreshAllPrivateAuras (called below) handles the full PA
            -- lifecycle: Layout (teardown + rebuild containers) then
            -- Update (register anchors). Nilling PA fields here would
            -- cause double-teardown.
            if frame.missingRaidBuffIcon then
                frame.missingRaidBuffIcon.SF_MissingAnchor = nil
                frame.missingRaidBuffIcon.cachedSize = nil
            end

            if frame.unit then self:UpdateStandardAuras(frame) end
            -- Grid2 parity: private aura icons and dispel overlay are
            -- registered indicators whose Layout + Update run via the
            -- indicator system. RefreshAllPrivateAuras (called below)
            -- handles the settings-change sweep for PA indicators.
            -- No manual UpdatePrivateAuraAnchor call needed here.
            --
            -- v60: the commented-out ApplyPrivateAuraOverrideFields /
            -- UpdatePrivateAuraOverlay / UpdatePrivateAuraFrameBorder calls
            -- that sat here were removed along with the Private Aura
            -- Customizations module they belonged to.
        end
    end

    -- The Blizzard native private-aura dispel overlay is a separate
    -- indicator; run its settings-change sweep (Layout + Update on all
    -- frames) after the standard aura loop above.
    -- v67: the RefreshAllPrivateAuraIcons call that sat here went with the
    -- Private Auras icon feature. The dispel overlay is NOT that feature
    -- and stays.
    if self.RefreshAllPrivateAuraDispelOverlays then self:RefreshAllPrivateAuraDispelOverlays() end
end

-- ============================================================
-- UNIT_FACTION re-scan.
--
-- After a cinematic the player's faction briefly flips; every group member
-- momentarily reads as non-assistable, and the engine AuraContainers flash
-- stale/unfiltered auras until something forces a re-scan. Blizzard fires
-- UNIT_FACTION("player") on the flip (and again on restore); on it we sweep
-- every live container and call UpdateAllAuras so the engine re-evaluates
-- with the current faction. (The oUF player/target/focus frames already do
-- the equivalent via BF.UpdateOUFAuraFilters on UNIT_FACTION — this covers
-- the party/raid grid + slot containers, which have no such hook.)
--
-- Lightweight on purpose: NOT RefreshAllAuras (that re-lays-out every frame).
-- UpdateAllAuras is combat-safe and pcall-guarded. UNIT_FACTION("player")
-- also fires on PvP-flag toggles, which are infrequent and never a per-GCD
-- hot path, so the per-event sweep cost is acceptable.
-- ============================================================
function BF:RescanAllAuraContainers()
    local frames = self.activatedFrames
    if not frames then return end
    for frame, unit in pairs(frames) do
        if unit then
            local t = frame._bf_auraContainers
            if t then
                for _, c in pairs(t) do
                    if c._bf_shown then
                        pcall(c.UpdateAllAuras, c)
                    end
                end
            end
        end
    end
end

do
    -- v86 (event refactor stage 4): was a private CreateFrame. Scope is
    -- "any" -- deliberately, not by omission: this handler has two real arms,
    -- one for the player and one for group members, so it needs every unit
    -- the event delivers and does its own branching below. Declaring "any"
    -- makes that a stated decision rather than an accident, which is the
    -- distinction that was missing when PLAYER_SPECIALIZATION_CHANGED went
    -- unfiltered in three files.
    local factionEvents = BF:EventOwner("aurasFaction")

    -- ── v93 (2026-08-20): HOSTILE / CHARMED SUPPRESSION EDGE ─────────────
    -- The predicate and its per-unit cache live in ContainerFactory.lua (see
    -- the suppression block above ContainerVisAlpha); this is its event
    -- plumbing, and it lives on this owner because UNIT_FACTION is already
    -- here and the two events are the same edge seen from two sides.
    --
    -- BOTH events, because neither alone is sufficient: UNIT_FACTION carries
    -- the reaction flip and UNIT_FLAGS the charm/control flip, and a mind
    -- control can land either one first.
    --
    -- On an ACTUAL edge we re-run the aura indicators for every frame showing
    -- the unit, rather than only re-running the alpha gate: the indicators are
    -- what fold the predicate into each container's `shown`, and that is what
    -- parks the container DISABLED (no engine-side filter evaluation while we
    -- are showing nothing) and what resumes it when the unit is friendly
    -- again. The visibility refresh then settles the alpha for the shared slot
    -- container, which no feature indicator owns outright.
    --
    -- Edge-guarded, so the steady state is one predicate re-resolve per event
    -- -- and these events are rare (faction flips, charm, PvP toggles), never
    -- a per-GCD path.
    local function AuraSuppressionEdge(_, _, unit)
        if not (unit and BF.roster_guids and BF.roster_guids[unit]) then return end
        if not BF:RefreshUnitAuraSuppression(unit) then return end
        local bucket = BF.frames_of_unit and rawget(BF.frames_of_unit, unit)
        if bucket then
            for frame in next, bucket do
                BF:UpdateStandardAuras(frame)
            end
        end
        if BF.RefreshAuraContainerVisibilityForUnit then
            BF:RefreshAuraContainerVisibilityForUnit(unit)
        end
    end

    factionEvents:Sub("UNIT_FACTION", function(_, _, unit)
        if unit == "player" then
            -- Cinematic while IN A VEHICLE (2026-08-13, owner repro): the
            -- rescan below is a forced re-evaluation, and re-evaluating in
            -- vehicle state corrupts candidate-table assignment (duplication
            -- junk) — while SKIPPING it leaves the cinematic's stale junk.
            -- Neither is displayable, so taint-hide every container and let
            -- the vehicle-exit flush rescan (out of vehicle state) + reveal.
            if BF.PlayerInVehicle and BF.PlayerInVehicle() then
                if BF.MarkAllContainersVehicleTainted then
                    BF:MarkAllContainersVehicleTainted()
                end
            else
                BF:RescanAllAuraContainers()
            end
        elseif unit and BF.roster_guids and BF.roster_guids[unit] then
            -- v93: the suppression edge runs FIRST. It re-runs the aura
            -- indicators, which is what takes a now-hostile unit's containers
            -- to shown = false -- and the re-enable arm below is guarded on
            -- _bf_shown, so running it first is also what stops that arm
            -- re-enabling a container we have just parked.
            AuraSuppressionEdge(nil, nil, unit)
            -- v86 (2026-08-15): PER-MEMBER refresh on UNIT_FACTION. The
            -- client fires UNIT_FACTION for each group member as they become
            -- resolvable after a loading screen or cinematic — the exact
            -- moment a late-loading member's containers can be rebuilt with
            -- real data. Event-driven and per-unit, so it catches members
            -- who finish loading long after our own PEW resync passes ran
            -- (owner-observed: units still buff-less after zone changes).
            -- Same vehicle rule as the player arm: re-evaluating in vehicle
            -- state corrupts candidate assignment, and the vehicle-exit
            -- flush rescans everything anyway.
            if not (BF.PlayerInVehicle and BF.PlayerInVehicle()) then
                local bucket = BF.frames_of_unit
                    and rawget(BF.frames_of_unit, unit)
                if bucket then
                    for frame in next, bucket do
                        local t = frame._bf_auraContainers
                        if t then
                            for _, c in pairs(t) do
                                if c._bf_shown then
                                    pcall(c.SetEnabled, c, true)
                                    pcall(c.UpdateAllAuras, c)
                                end
                            end
                        end
                    end
                    if BF.RefreshAuraContainerVisibilityForUnit then
                        BF:RefreshAuraContainerVisibilityForUnit(unit)
                    end
                end
            end
        end
    end, "any")

    -- The charm/control half of the same edge. Roster-scoped: this handler
    -- has one arm and it is per-member, so unlike its UNIT_FACTION sibling it
    -- states that in the scope rather than branching on it.
    factionEvents:Sub("UNIT_FLAGS", AuraSuppressionEdge, "roster")

    -- Unit tokens are recycled: "raid5" is a different player after a join,
    -- and a cached answer would be whoever held the token before. Drop the
    -- entry with the assignment and let the next read re-resolve -- same
    -- messages, same reason, as the Phased status's ResetPhaseUnit
    -- (BFStatus.lua). Registered on the owner object rather than through
    -- :Sub, which is for engine events; AceEvent is embedded on every owner
    -- and keys callbacks by object, so this collides with nothing.
    local function ForgetUnitSuppression(_, unit)
        BF:ClearUnitAuraSuppression(unit)
    end
    factionEvents:RegisterMessage("BF_UnitUpdated", ForgetUnitSuppression)
    factionEvents:RegisterMessage("BF_UnitLeft",    ForgetUnitSuppression)
end

-- ============================================================
-- CINEMATIC ALPHA GATE (2026-08-16).
--
-- The UNIT_FACTION rescan above is the REPAIR path: it fires on the faction
-- flip, after the engine has already pushed junk to the containers, and a
-- rescan clears junk rather than preventing it — the visible symptom was
-- junk auras on the frames as/after a cinematic plays. CINEMATIC_START /
-- PLAY_MOVIE are the earliest signals the client offers, so the gate closes
-- there (BF:ApplyCinematicAuraGate in ContainerFactory — folds into the
-- container alpha union, never a direct alpha write) and holds across the
-- whole cinematic. The exit edge is DEFERRED: the engine takes a moment to
-- settle its aura display after the stop event, so the rescan runs while
-- everything is still invisible and only then does the alpha restore. A
-- generation counter cancels a pending restore when another cinematic
-- starts inside the window (movie chains; CINEMATIC_STOP followed
-- immediately by PLAY_MOVIE).
--
-- The UNIT_FACTION rescan above is deliberately KEPT: it is the repair path
-- for any cinematic form that fires neither event, and the only handler for
-- plain PvP-flag toggles.
--
-- Vehicle rule at the exit edge: rescanning in vehicle state corrupts
-- candidate-table assignment (see the vehicle section below), so a
-- cinematic that ends while the player is in a vehicle taint-hides instead
-- and lets the vehicle-exit flush rescan + reveal — exactly the
-- cinematic-in-a-vehicle arm of the UNIT_FACTION handler above.
--
-- PLAYER_ENTERING_WORLD failsafe: there is no "is a cinematic playing" API
-- to seed from, and a reload or zone transition mid-cinematic can eat the
-- stop event — if the gate is still closed at PEW, plan the restore.
-- Dedicated event frame (same reason as factionFrame above: no AceEvent
-- one-handler-per-(object,event) hazard).
-- ============================================================
do
    local CINEMATIC_RESTORE_DELAY = 0.5  -- PTR-tune: engine settle time
    local cinematicGen = 0
    local function GateOn()
        cinematicGen = cinematicGen + 1
        BF:ApplyCinematicAuraGate(true)
    end
    local function GateOffDeferred()
        cinematicGen = cinematicGen + 1
        local gen = cinematicGen
        C_Timer.After(CINEMATIC_RESTORE_DELAY, function()
            if gen ~= cinematicGen then return end  -- another cinematic started
            -- Rescan BEFORE the alpha restore: junk clears while invisible.
            if BF.PlayerInVehicle and BF.PlayerInVehicle() then
                if BF.MarkAllContainersVehicleTainted then
                    BF:MarkAllContainersVehicleTainted()
                end
            else
                BF:RescanAllAuraContainers()
            end
            BF:ApplyCinematicAuraGate(false)
        end)
    end
    -- v86 (event refactor stage 4): was a private CreateFrame. Every event
    -- here is unitless.
    local cineEvents = BF:EventOwner("aurasCinematicGate")
    local function OnCinematicEvent(_, event)
        if event == "CINEMATIC_START" or event == "PLAY_MOVIE" then
            GateOn()
        elseif event == "CINEMATIC_STOP" or event == "STOP_MOVIE" then
            GateOffDeferred()
        elseif BF._cinematicGateActive then
            -- PLAYER_ENTERING_WORLD with the gate still closed.
            GateOffDeferred()
        end
    end
    cineEvents:Sub("CINEMATIC_START",       OnCinematicEvent, "unitless")
    cineEvents:Sub("PLAY_MOVIE",            OnCinematicEvent, "unitless")
    cineEvents:Sub("CINEMATIC_STOP",        OnCinematicEvent, "unitless")
    cineEvents:Sub("STOP_MOVIE",            OnCinematicEvent, "unitless")
    cineEvents:Sub("PLAYER_ENTERING_WORLD", OnCinematicEvent, "unitless")
end

-- ============================================================
-- VEHICLE CONFIG DEFER + EXIT SELF-HEAL (2026-08-13).
--
-- PTR-established: re-applying an aura group's config while the PLAYER is in
-- a vehicle makes the engine duplicate one matched aura across the group's
-- slots (and slot buttons show broken art). Any group whose narrowing lives
-- in a candidateFilters table is affected — includeSpellIDs AND
-- excludeSpellIDs both reproduce it (isolated with a temporary
-- exclude-only diagnostic preset); token-only groups (BigDef's shape) are
-- immune. Steady-state containers are FINE in vehicles — the corruption
-- needs a config re-application (settings edit, reload-in-vehicle) to bake
-- in, and then STICKS until something re-scans.
--
-- So: every settings-driven aura refresh defers while the player is in a
-- vehicle (guard below, called at the top of the Refresh* helpers), and
-- vehicle exit re-scans all containers (clears anything that slipped in,
-- e.g. junk baked before this fix or by paths not routed through the
-- helpers) then flushes the deferred refresh. The 0.5s delay matches
-- BuzzardAuras' PTR-tuned engine settle time — flushing ON the exit event
-- re-corrupts (API state lags the event).
-- ============================================================
local function PlayerInVehicle()
    return ((UnitInVehicle and UnitInVehicle("player"))
        or (UnitUsingVehicle and UnitUsingVehicle("player"))) and true or false
end
-- Shared with ContainerFactory's born-in-vehicle container gate.
BF.PlayerInVehicle = PlayerInVehicle

-- Returns true (and remembers the deferral) when aura refreshes must not
-- run right now. Callers just early-return; the exit flush below re-runs
-- the big-hammer RefreshAllAuras once, which supersedes every scoped path.
function BF:DeferAuraRefreshInVehicle()
    if PlayerInVehicle() then
        self._bf_vehiclePendingAuraRefresh = true
        return true
    end
    return false
end

do
    -- v86 (event refactor stage 4): was a private CreateFrame whose handler
    -- hand-tested `unit == "player"` on UNIT_EXITED_VEHICLE. That test is now
    -- the declared scope and is enforced by the engine; the other two events
    -- are unitless. Subscriptions are at the foot of this block, after Flush
    -- and the handler exist.
    local vehicleEvents = BF:EventOwner("aurasVehicleFlush")
    local function Flush()
        if PlayerInVehicle() then return end  -- re-entered during the delay
        -- Rescan first — combat-safe, clears duplicated assignments.
        BF:RescanAllAuraContainers()
        -- Reveal vehicle-TAINTED containers (hidden at alpha 0: born in a
        -- vehicle, or hidden by a cinematic-in-vehicle) — after the rescan
        -- above, so they re-filter before first becoming visible. See the
        -- vehicle-tainted gate in ContainerFactory.
        if BF._bf_anyVehicleTainted then
            BF._bf_anyVehicleTainted = nil
            local frames = BF.activatedFrames
            if frames then
                for frame, unit in pairs(frames) do
                    local t = frame._bf_auraContainers
                    if t then
                        local had = false
                        for _, c in pairs(t) do
                            if c._bf_vehicleTainted then
                                c._bf_vehicleTainted = nil
                                had = true
                            end
                        end
                        if had and unit and BF.RefreshAuraContainerVisibilityForUnit then
                            BF:RefreshAuraContainerVisibilityForUnit(unit)
                        end
                    end
                end
            end
        end
        if BF._bf_vehiclePendingAuraRefresh then
            -- The deferred refresh is settings-path work and combat-locked;
            -- keep the flag and let PLAYER_REGEN_ENABLED retry.
            if InCombatLockdown() then return end
            BF._bf_vehiclePendingAuraRefresh = false
            -- Flush with the HEAVY custom-container path: deferred edits can
            -- include container spell/preset/position changes whose caches
            -- (claimed spells, color curves) plain RefreshAllAuras doesn't
            -- rebuild. Its tail runs RefreshAllAuras, so this supersedes it.
            if BF.RefreshAllCustomContainersWithRebuild then
                BF:RefreshAllCustomContainersWithRebuild()
            elseif BF.RefreshAllAuras then
                BF:RefreshAllAuras()
            end
        end
    end
    local function OnVehicleEvent(_, event)
        if event == "UNIT_EXITED_VEHICLE" then
            -- scope "player" already guarantees this is the player's own
            -- vehicle exit; no unit test needed.
            C_Timer.After(0.5, Flush)
        elseif event == "PLAYER_REGEN_ENABLED" then
            if BF._bf_vehiclePendingAuraRefresh then Flush() end
        elseif event == "PLAYER_ENTERING_WORLD" then
            -- Safety net: a scripted vehicle can despawn/teleport the player
            -- without firing UNIT_EXITED_VEHICLE (and a reload-in-vehicle
            -- then zone-out never sees the exit event either). Flush
            -- re-checks the vehicle state itself, so a PEW fired while
            -- STILL in the vehicle (the reload-in-vehicle PEW) is a no-op.
            if BF._bf_vehiclePendingAuraRefresh or BF._bf_anyVehicleTainted then
                C_Timer.After(0.5, Flush)
            end
        end
    end
    vehicleEvents:Sub("UNIT_EXITED_VEHICLE",  OnVehicleEvent, "player")
    vehicleEvents:Sub("PLAYER_REGEN_ENABLED", OnVehicleEvent, "unitless")
    vehicleEvents:Sub("PLAYER_ENTERING_WORLD", OnVehicleEvent, "unitless")
end

-- ============================================================
-- SCOPED REFRESH HELPERS
--
-- Each function refreshes a single aura subcategory's indicator(s)
-- instead of running the full RefreshAllAuras sweep. See
-- Docs/REFRESH_SCOPING_PLAN.md for the full rationale and the
-- after-Layout work matrix.
--
-- Common pattern:
--   1. Guard combat lockdown + active frames.
--   2. Snapshot cross-effect inputs (only where relevant).
--   3. self:InvalidateRaidProfileCache() + self:UpdateAuraSizeCache()
--      to rebuild the cache. UpdateAuraSizeCache is the source of
--      truth for field computation and handles per-CFG flats.
--   4. Resolve the targeted indicators via GetIndicatorByName.
--   5. Per active frame: Layout + Update the primary indicator(s),
--      plus the cross indicator when its inputs moved.
--   6. RefreshPreviewDummyAuras at the end.
--
-- The Renewing Mist override bug: any path that re-Layouts the
-- buff group reaches _LayoutDefaultBuffGroup (via BuffsAndContainers
-- :Layout → BF:LayoutAuraGroup). That function overwrites per-icon
-- cooldown baseline state and relies on its own
-- cd._bf_sctSpell = true sentinel to make the render loop re-stamp
-- per-spell overrides on the next pass. That sentinel is permanent
-- and load-bearing — DO NOT remove it.
-- ============================================================

-- Buffs subcategory. Primary: buffsAndContainers.
-- v67: the buffHighlight cross-indicator pass was removed with the
-- indicator itself (12.1-only; its BuffMatch getters are gone).
function BF:RefreshBuffsOnly()
    if InCombatLockdown() then return end
    if self:DeferAuraRefreshInVehicle() then return end
    if not self.registeredFrames then return end

    self:InvalidateRaidProfileCache()
    self:UpdateAuraSizeCache()
    self:ApplyStackTextStyle()
    if self.InvalidateContainerIconCaches then self:InvalidateContainerIconCaches() end

    local primary    = self:GetIndicatorByName("buffsAndContainers")
    for _, frame in next, self.registeredFrames do
        if frame and not frame._isPreviewFrame then
            self:ApplyAuraGeometry(frame)
            if frame.buffFrames then
                for i = 1, #frame.buffFrames do
                    local b = frame.buffFrames[i]
                    if b then b.SF_LastIndex = nil end
                end
            end
            if primary then
                primary:Layout(frame)
                if frame.unit then primary:Update(frame, frame.unit) end
            end
        end
    end
    if self.RefreshPreviewDummyAuras then self:RefreshPreviewDummyAuras() end
end

-- Debuffs subcategory. Primary: debuffIcons.
-- v67: the buffHighlight cross-indicator pass was removed with the
-- indicator itself (12.1-only; its BuffMatch getters are gone).
--
-- v67: the extraDebuffYOffset cross-effect that re-positioned private
-- aura icons went with the Private Auras feature. That offset was only
-- ever non-zero under separatePrivateAurasInRaid/InParty, which no
-- options widget has ever written.
function BF:RefreshDebuffsOnly()
    if InCombatLockdown() then return end
    if self:DeferAuraRefreshInVehicle() then return end
    if not self.registeredFrames then return end

    self:InvalidateRaidProfileCache()
    self:UpdateAuraSizeCache()
    self:ApplyStackTextStyle()

    local primary   = self:GetIndicatorByName("debuffIcons")
    for _, frame in next, self.registeredFrames do
        if frame and not frame._isPreviewFrame then
            self:ApplyAuraGeometry(frame)
            if frame.debuffFrames then
                for i = 1, #frame.debuffFrames do
                    local d = frame.debuffFrames[i]
                    if d then d.SF_LastIndex = nil end
                end
            end
            if primary then
                primary:Layout(frame)
                if frame.unit then primary:Update(frame, frame.unit) end
            end
        end
    end
    if self.RefreshPreviewDummyAuras then self:RefreshPreviewDummyAuras() end
end

-- v67: BF:RefreshPrivateAurasOnly removed with the Private Auras icon
-- feature (12.0.7-only). Its dispatcher entries went with the privateAuras
-- sub-category in Core_ProfileAPI.lua. The Blizzard native dispel overlay
-- has its own refresh path (RefreshAllPrivateAuraDispelOverlays) and is
-- unaffected.

-- BigDef subcategory. Primary: bigDefIcons.
function BF:RefreshBigDefOnly()
    if InCombatLockdown() then return end
    if self:DeferAuraRefreshInVehicle() then return end
    if not self.registeredFrames then return end

    self:InvalidateRaidProfileCache()
    self:UpdateAuraSizeCache()

    local primary = self:GetIndicatorByName("bigDefIcons")
    for _, frame in next, self.registeredFrames do
        if frame and not frame._isPreviewFrame then
            self:ApplyAuraGeometry(frame)
            if frame.bigDefIcons then
                for i = 1, #frame.bigDefIcons do
                    frame.bigDefIcons[i].SF_LastIndex = nil
                end
            end
            if primary then
                primary:Layout(frame)
                if frame.unit then primary:Update(frame, frame.unit) end
            end
        end
    end
    if self.RefreshPreviewDummyAuras then self:RefreshPreviewDummyAuras() end
end

-- v64: BF:RefreshImportantOnly removed with the Important feature. Its only
-- caller was the "important" entry in SUBCAT_REFRESH (Options/Options.lua),
-- which is gone too.

-- v69: BF:RefreshCrowdControlOnly removed with the dedicated Crowd Control
-- feature (now a seeded custom debuff container). Its only caller was the
-- "crowdControl" entry in SUBCAT_REFRESH (Options/Options.lua), gone too.
-- Container toggles route through the custom-container refresh path, which
-- already re-runs the debuff-side filter pushes (|!CROWD_CONTROL claim).

-- DispelIndicator subcategory. Targets the three dispel indicators
-- (custom border, custom overlay, custom indicator icon) plus the
-- private aura dispel overlay. Most dispel inputs are read by
-- DispelIndicator:UpdateSettings (reads BF.db directly, not via
-- AuraCache), so RefreshAllPrivateAuraDispelOverlays handles them
-- correctly already — we delegate to it and additionally run the
-- three custom dispel indicators per-frame Update.
function BF:RefreshDispelOnly()
    if InCombatLockdown() then return end
    if self:DeferAuraRefreshInVehicle() then return end
    if not self.registeredFrames then return end

    -- Rebuild the cache so any dispel-driven AuraCache flags refresh.
    self:InvalidateRaidProfileCache()
    self:UpdateAuraSizeCache()

    if self.RefreshAllPrivateAuraDispelOverlays then
        self:RefreshAllPrivateAuraDispelOverlays()
    end

    local border  = self:GetIndicatorByName("dispelDebuffBorder")
    local overlay = self:GetIndicatorByName("dispelDebuffOverlay")
    local indDot  = self:GetIndicatorByName("dispelDebuffIndicator")
    for frame, unit in next, self.activatedFrames do
        if frame and unit and frame:IsShown() then
            if border  then border:Update(frame, frame.unit) end
            if overlay then overlay:Update(frame, frame.unit) end
            if indDot  then indDot:Update(frame, frame.unit) end
        end
    end
    if self.RefreshPreviewDummyAuras then self:RefreshPreviewDummyAuras() end
end

-- aurasAbovePowerBar (healthPower section). The toggle is read by
-- the aura indicators to decide whether icons anchor to the unit frame or
-- to frame.healthBar.clipFrame (lifting them above the power bar):
-- buffsAndContainers, debuffIcons, bigDefIcons. For default-buff and container
-- groups the lift decision is preprocessed into groupConfig.canLiftAboveBar
-- (AuraGroupHelpers.lua) so the pool needs invalidating too.
--
-- Flat-cache note: aurasAbovePowerBar lives in the healthPower section,
-- and the setter writeIP() in Options_HealthPower.lua doesn't mark any
-- flat dirty. The call to InvalidateAllFlatAuraCaches below forces
-- UpdateAuraSizeCache to rebuild every flat (matching what
-- RefreshAllAuras did before scoping).
function BF:RefreshAurasAbovePowerBarToggle()
    if InCombatLockdown() then return end
    if not self.registeredFrames then return end

    self:InvalidateRaidProfileCache()
    if self.InvalidateAllFlatAuraCaches then self:InvalidateAllFlatAuraCaches() end
    self:UpdateAuraSizeCache()
    -- Pool busts so canLiftAboveBar recomputes on the next render.
    if self.InvalidateAuraGroupConfigPools then
        self:InvalidateAuraGroupConfigPools()
    end

    local buffs   = self:GetIndicatorByName("buffsAndContainers")
    local debuffs = self:GetIndicatorByName("debuffIcons")
    local bigDef  = self:GetIndicatorByName("bigDefIcons")

    for _, frame in next, self.registeredFrames do
        if frame and not frame._isPreviewFrame then
            self:ApplyAuraGeometry(frame)
            -- Per-icon position caches must be cleared so the new
            -- anchor decision is applied on the next indicator Update.
            if frame.buffFrames then
                for i = 1, #frame.buffFrames do
                    local b = frame.buffFrames[i]
                    if b then b.SF_LastIndex = nil end
                end
            end
            if frame.debuffFrames then
                for i = 1, #frame.debuffFrames do
                    local d = frame.debuffFrames[i]
                    if d then d.SF_LastIndex = nil end
                end
            end
            if buffs then buffs:Layout(frame); if frame.unit then buffs:Update(frame, frame.unit) end end
            if debuffs then debuffs:Layout(frame); if frame.unit then debuffs:Update(frame, frame.unit) end end
            if bigDef then bigDef:Layout(frame); if frame.unit then bigDef:Update(frame, frame.unit) end end
        end
    end
    if self.RefreshPreviewDummyAuras then self:RefreshPreviewDummyAuras() end
end

-- Tooltips section. The show/in-combat booleans live in BF.AuraCache (or
-- the per-CFG _auraCache after Cleanup 2); UpdateAuraSizeCache rebuilds
-- the relevant flat caches via the dirty-flag markers that setTP must set
-- on writes.
-- v67: the per-frame BF:DispatchTooltipSettings pass was removed
-- (12.1-only). Container buttons bake their tooltip bindings at creation,
-- so all four indicator UpdateFrameSettings methods were already no-ops —
-- tooltip setting changes are reload-prompted in options.
function BF:RefreshTooltipsOnly()
    if InCombatLockdown() then return end
    if not self.registeredFrames then return end
    self:InvalidateRaidProfileCache()
    self:UpdateAuraSizeCache()
    if self.RefreshPreviewDummyAuras then self:RefreshPreviewDummyAuras() end
end

-- Missing raid buff subcategory (lives in icons section, not auras).
-- Flat-cache note: missingRaidBuff* writes go through writeIP() in
-- Options_Icons.lua which doesn't mark any flat dirty (the icons
-- section has no shared write helper that invalidates). Force a
-- full flat-cache rebuild here so UpdateAuraSizeCache picks up the
-- new value across every flat — same pattern as
-- RefreshAurasAbovePowerBarToggle.
function BF:RefreshMissingRaidBuffOnly()
    if InCombatLockdown() then return end
    if not self.registeredFrames then return end

    self:InvalidateRaidProfileCache()
    if self.InvalidateAllFlatAuraCaches then self:InvalidateAllFlatAuraCaches() end
    self:UpdateAuraSizeCache()

    local primary = self:GetIndicatorByName("missingRaidBuff")
    for _, frame in next, self.registeredFrames do
        if frame and not frame._isPreviewFrame then
            if frame.missingRaidBuffIcon then
                frame.missingRaidBuffIcon.SF_MissingAnchor = nil
                frame.missingRaidBuffIcon.cachedSize = nil
            end
            if primary then
                primary:Layout(frame)
                if frame.unit then primary:Update(frame, frame.unit) end
            end
        end
    end
    if self.RefreshPreviewDummyAuras then self:RefreshPreviewDummyAuras() end
end

-- ============================================================
-- REFRESH CFG AURAS ONLY
-- Scoped version of RefreshAllAuras that only touches custom
-- frame group state. Main/RP frame caches and icons are left
-- completely untouched so CFG setting edits cannot leak into
-- party/raid frames.
-- ============================================================
function BF:RefreshCFGAurasOnly()
    if self:DeferAuraRefreshInVehicle() then return end
    -- Rebuild per-CFG aura caches only. UpdateAuraSizeCache rebuilds
    -- the global BF.AuraCache from the main profile AND per-CFG caches.
    -- The global cache values come from the main RP profile, so they
    -- won't change when only CFG settings were edited.
    self:UpdateAuraSizeCache()

    -- Wipe container icon state only on CFG frames.
    if self.InvalidateContainerIconCachesCFGOnly then
        self:InvalidateContainerIconCachesCFGOnly()
    end
    -- Wipe container settings cache only for CFG-scoped keys (v61: those are
    -- cfgFlatID strings now, not the old positional "cfGroup_N").
    if self.InvalidateContainerSettingsCacheCFGOnly then
        self:InvalidateContainerSettingsCacheCFGOnly()
    end

    -- Resolve indicators once before the per-frame loop (same pattern
    -- as RefreshBuffsOnly).
    local primary = self:GetIndicatorByName("buffsAndContainers")

    -- Re-apply geometry, re-Layout default buffs, and re-fetch standard
    -- auras on CFG frames.
    for _, frame in next, self.registeredFrames do
        if frame and not frame._isPreviewFrame then
            local h = frame._bf_parentHeader or frame:GetParent()
            if h and h.isCustomFrame then
                self:ApplyAuraGeometry(frame)
                if frame.buffFrames then
                    for i = 1, #frame.buffFrames do
                        local b = frame.buffFrames[i]
                        if b then b.SF_LastIndex = nil end
                    end
                end
                if frame.debuffFrames then
                    for i = 1, #frame.debuffFrames do
                        local d = frame.debuffFrames[i]
                        if d then d.SF_LastIndex = nil end
                    end
                end

                if frame.missingRaidBuffIcon then
                    frame.missingRaidBuffIcon.SF_MissingAnchor = nil
                    frame.missingRaidBuffIcon.cachedSize = nil
                end

                -- Re-Layout the buffs+containers indicator so
                -- _LayoutDefaultBuffGroup re-stamps cooldown font /
                -- timer-scale from the (now-updated) CFG _auraCache.
                -- Without this, a CFG buffSize change rebuilds the
                -- cache and resizes icons, but the stamped tt:SetScale
                -- from the prior Layout stays at the old bSize.
                if primary then primary:Layout(frame) end

                if frame.unit then self:UpdateStandardAuras(frame) end
            end
        end
    end
end

-- ============================================================
-- REFRESH BIG DEFENSIVE (called when those settings change)
-- ============================================================
function BF:RefreshBigDef()
    self:UpdateAuraSizeCache()
    for _, frame in next, self.registeredFrames do
        if frame and not frame._isPreviewFrame then
            -- Grid2 lazy fetch: no eager cache rebuilds needed. Each
            -- indicator's Update re-syncs its own aura grid container.
            self:ApplyAuraGeometry(frame)
            if frame.unit then self:UpdateStandardAuras(frame) end
        end
    end
end

-- ============================================================
-- INVALIDATE AURA POSITION CACHES FOR ONE FRAME
-- Called when the power bar shows/hides, which changes whether
-- aura icons anchor to frame or healthBar.clipFrame (when
-- aurasAbovePowerBar is enabled). Clears SF_LastIndex on all
-- icon types so indicators re-anchor them on the next pass.
-- ============================================================
function BF:InvalidateAuraPositionCache(frame)
    if not frame then return end
    -- 12.1 container path: the aurasAbovePowerBar lift target is baked
    -- into the containers' SetPoint — re-resolve it now that the power
    -- bar's visibility changed (light re-anchor, not a full Layout).
    -- v67: 12.0.7 branch removed (addon is 12.1-only).
    if self.ReanchorFrameAuraContainers then
        self:ReanchorFrameAuraContainers(frame)
    end
    if frame.buffFrames then
        for i = 1, #frame.buffFrames do
            local icon = frame.buffFrames[i]
            if icon then icon.SF_LastIndex = nil end
        end
    end
    if frame.debuffFrames then
        for i = 1, #frame.debuffFrames do
            local icon = frame.debuffFrames[i]
            if icon then icon.SF_LastIndex = nil end
        end
    end
    if frame.bigDefIcons then
        for i = 1, #frame.bigDefIcons do frame.bigDefIcons[i].SF_LastIndex = nil end
    end
    if frame.missingRaidBuffIcon then
        frame.missingRaidBuffIcon.SF_MissingAnchor = nil
    end
    -- Also invalidate custom container icon position caches
    if frame.SF_CustomContainerIcons then
        for _, pool in pairs(frame.SF_CustomContainerIcons) do
            for _, icon in ipairs(pool) do icon.SF_LastIndex = nil end
        end
    end
    -- Trigger a redisplay so icons reposition immediately
    self:UpdateStandardAuras(frame)
end