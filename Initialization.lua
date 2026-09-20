-- ============================================================
-- BuzzardFrames: Initialization.lua (NEW - Secure Header Version)
-- Event handlers and initial setup
-- ============================================================

local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")
local issecretvalue  = issecretvalue  or function(v) return false end
local UNKNOWNOBJECT  = UNKNOWNOBJECT

-- Seed/refresh the dead-state cache for one unit, in the death status'
-- own vocabulary ("Dead" / "Ghost" / false). Called when a unit is added
-- to the roster and when the roster sweep finds a new occupant on a token.
local function SeedDeadCache(unit)
    local cache = BF.unitWasDeadCache
    if not cache then return end
    cache[unit] = BF.UnitDeadState(unit)
end

-- ============================================================
-- LIBSHAREDMEDIA FONT REGISTRATION
-- Register bundled fonts so they appear in LSM font pickers.
-- ============================================================
do
    local LSM = LibStub("LibSharedMedia-3.0", true)
    if LSM then
        local base = "Interface\\AddOns\\BuzzardFrames\\Media\\Fonts\\"
        LSM:Register("font", "Roboto Condensed Bold", base .. "RobotoCondensed-Bold.ttf")
        LSM:Register("font", "PT Sans Narrow",         base .. "PTSansNarrow.ttf")
        -- Bundled statusbar textures. Buzzard Glass: original BF-generated
        -- grayscale gradient (Smooth/Clean-family profile plus an upper
        -- gloss pane with a soft midline reflection break and faint bottom
        -- sheen) — tintable by SetStatusBarColor like any LSM statusbar.
        LSM:Register("statusbar", "Buzzard Glass",
            "Interface\\AddOns\\BuzzardFrames\\Media\\BuzzardGlass")
        -- Dark variant: same profile, top pane ~12% darker, lower pane
        -- ~5% darker (factor blended through the gloss break).
        LSM:Register("statusbar", "Buzzard Glass Dark",
            "Interface\\AddOns\\BuzzardFrames\\Media\\BuzzardGlassDark")
        -- Shiny variant (made for absorb overlays): hotter specular top,
        -- brighter upper pane, harder gloss break, strong bottom reflection.
        LSM:Register("statusbar", "Buzzard Glass Shine",
            "Interface\\AddOns\\BuzzardFrames\\Media\\BuzzardGlassShine")
    end
end
-- unitToFrameCache is written by SetFrameUnit (Layout.lua) and read by Auras.lua
-- for O(1) unit->frame lookups.  Wiped on GROUP_ROSTER_UPDATE to clear stale entries.
BF.unitToFrameCache = BF.unitToFrameCache or {}
local unitToFrameCache = BF.unitToFrameCache

-- THE per-unit dead state cache (state on the unit token, not on a frame):
-- unitWasDeadCache[unit] = "Dead" | "Ghost" | false | nil
-- Seeded when a unit is added to the roster, refreshed when the roster
-- sweep detects a new occupant on a token, nil'd when the unit leaves.
-- The death status (BFStatus.lua) is its only other writer, and every
-- consumer reads it through that status rather than directly.
--
-- Offline state is owned exclusively by the Offline status (Statuses/Offline.lua).
BF.unitWasDeadCache = BF.unitWasDeadCache or {}

-- UNIT_AURA scratch tables moved to Statuses/Auras.lua (buffs/debuffs statuses).

-- ============================================================
-- STATUS DISPATCH CACHE
-- Resolved lazily on first use (after InitStatusSystem runs in OnEnable).
-- Each is a status object whose :UpdateIndicators(unit) method only
-- calls the indicators bound to that status — Grid2's core optimization.
-- ============================================================
-- Status dispatch locals — only for per-unit events still dispatched through
-- Initialization.lua's perUnitFrames system. All global events are now owned
-- by their statuses (via OnEnable in BFStatus.lua).
local S_HEALTH, S_POWER, S_ABSORBS

local function ResolveStatuses()
    local s = BF.statuses
    if not s then return end
    S_HEALTH  = s.health
    S_POWER   = s.power
    S_ABSORBS = s.absorbs
end

-- ============================================================
-- PER-UNIT EVENT SYSTEM (Grid2 GridRosterUnitEvents.lua pattern)
--
-- High-frequency unit events (UNIT_HEALTH, UNIT_AURA, etc.) are registered
-- with Frame:RegisterUnitEvent(event, unit) so the game only delivers them
-- when the specific unit fires, not for every unit in the game.
--
-- Grid2 pattern: events are registered SELECTIVELY based on which statuses
-- are enabled. When a status calls BF.RegisterRosterUnitEvent("UNIT_POWER_UPDATE"),
-- that event is registered on all current roster unit frames. When the last
-- status unregisters it, the event is removed from all frames. This ensures
-- no CPU is spent dispatching events for disabled features.
--
-- One hidden frame is created per active roster unit. When a unit joins the
-- roster, all currently-active events are registered on that unit's frame.
-- When a unit leaves, all events are unregistered.
-- ============================================================
local perUnitFrames  = {}   -- unit -> hidden event frame
BF._debugPerUnitFrames = perUnitFrames  -- exposed for /bf debugreg

-- Grid2 pattern: rosterEvents[eventName] = { [object] = handler_func, ... }
-- An event is registered on unit frames only while it has at least one listener.
local rosterEvents = {}

-- Legacy list retained for documentation; actual registration is now dynamic.
local perUnitEventSet = {}   -- fast lookup: eventName -> true

-- Returns true when ALL frame display is suppressed: the global party/raid
-- toggle is off AND no custom frame groups are active. Used to guard
-- high-frequency per-unit events so we don't bail on custom frames.
-- An activated raid-style twin (UnitFrames/Twins.lua) is a live frame on a
-- live token that belongs to no header, so it keeps the per-unit machinery
-- alive on its own. Cheap: the list is empty and the loop does not run
-- unless the feature is switched on.
local function AnyTwinActive()
    local twins = BF.twinFrames
    if not twins then return false end
    for i = 1, #twins do
        local twin = twins[i]
        if twin._bf_twinActive and twin.unit then return true end
    end
    return false
end
BF._AnyTwinActive = AnyTwinActive

local function AllFramesInactive()
    if BF._framesActiveForContext ~= false then return false end
    if BF.groupsUsed then
        for _, h in ipairs(BF.groupsUsed) do
            if h.isCustomFrame then return false end
        end
    end
    return true
end

-- Grid2 verbatim: OnEvent handler iterates all listeners for this event.
local function PerUnitOnEvent(_, event, unit, ...)
    -- The twin term is deliberately HERE and in the roster-identity sweep
    -- rather than inside AllFramesInactive: a twin needs its token's per-unit
    -- events and a fresh GUID/name for that token, nothing else. The other two
    -- callers (GROUP_ROSTER_UPDATE and the deferred group-change pipeline)
    -- drive whole-layout work that a user with raid AND party frames off has
    -- switched off on purpose, and twins get their occupant changes from their
    -- own events (UnitFrames/Twins.lua).
    if AllFramesInactive() and not AnyTwinActive() then return end
    local listeners = rosterEvents[event]
    if listeners then
        for obj, func in next, listeners do
            func(obj, event, unit, ...)
        end
    end
end

-- Grid2 verbatim (GridRosterUnitEvents.lua `frames` metatable): unit
-- frames are created on demand and CACHED for the token's lifetime — a
-- departing unit's frame is disarmed (UnregisterAllEvents), never
-- discarded, so a token that rejoins reuses its frame.
local function GetUnitEventFrame(unit)
    local f = perUnitFrames[unit]
    if not f then
        f = CreateFrame("Frame")
        f:Hide()
        f:SetScript("OnEvent", PerUnitOnEvent)
        perUnitFrames[unit] = f
    end
    return f
end

-- Grid2 verbatim (Messages:Grid_UnitUpdated joined=true): arm all active
-- events on the unit's frame. Reached ONLY via the BF_UnitUpdated
-- (joined=true) message sent by RegisterRosterUnit's AddUnit path —
-- per-unit events exist exclusively for units actually added to the
-- roster, exactly like Grid2.
local function RegisterUnitEventFrame(unit)
    local f = GetUnitEventFrame(unit)
    for eventName in next, rosterEvents do
        f:RegisterUnitEvent(eventName, unit)
    end
end

-- Grid2 verbatim (Messages:Grid_UnitLeft): disarm, keep the frame cached.
local function UnregisterUnitEventFrame(unit)
    local f = perUnitFrames[unit]
    if not f then return end
    f:UnregisterAllEvents()
end

-- Grid2 verbatim (GridRosterUnitEvents.lua Messages): a dedicated
-- AceEvent object owns arming/disarming the unit frames. It subscribes
-- to the roster join/leave messages only while at least one roster
-- event has a listener (see RegisterRosterUnitEvent below).
local Messages = LibStub("AceEvent-3.0"):Embed({})

function Messages:BF_UnitLeft(_, unit)
    UnregisterUnitEventFrame(unit)
end

function Messages:BF_UnitUpdated(_, unit, joined)
    if joined then
        RegisterUnitEventFrame(unit)
    end
end

-- ============================================================
-- PUBLIC: RegisterRosterUnitEvent / UnregisterRosterUnitEvent
-- Grid2 GridRosterUnitEvents.lua — verbatim logic.
--
-- Statuses call these in OnEnable/OnDisable to register/unregister
-- the specific per-unit events they need. When the first listener
-- registers an event, it's added to all existing unit frames.
-- When the last listener unregisters, the event is removed from all frames.
-- ============================================================
function BF.RegisterRosterUnitEvent(object, event, method)
    -- Grid2 verbatim: the join/leave messages are subscribed with the
    -- first listener of the first event, unsubscribed with the last.
    if not next(rosterEvents) then
        Messages:RegisterMessage("BF_UnitUpdated")
        Messages:RegisterMessage("BF_UnitLeft")
    end
    local listeners = rosterEvents[event]
    if not listeners then
        -- First listener for this event: create listener table and
        -- register the event for every unit currently in the roster
        -- (Grid2: IterateRosterUnits == the roster_guids keys — NOT the
        -- frame cache, which can hold disarmed frames of departed units).
        listeners = {}
        rosterEvents[event] = listeners
        perUnitEventSet[event] = true
        if BF.roster_guids then
            for unit in next, BF.roster_guids do
                GetUnitEventFrame(unit):RegisterUnitEvent(event, unit)
            end
        end
    end
    listeners[object] = type(method) == "function" and method or object[method or event]
end

function BF.UnregisterRosterUnitEvent(object, event)
    local listeners = rosterEvents[event]
    if not listeners then return end
    listeners[object] = nil
    if not next(listeners) then
        -- Last listener removed: unregister the event from all roster units.
        rosterEvents[event] = nil
        perUnitEventSet[event] = nil
        if BF.roster_guids then
            for unit in next, BF.roster_guids do
                local f = perUnitFrames[unit]
                if f then f:UnregisterEvent(event) end
            end
        end
        -- Grid2 verbatim: last event gone — drop the message subscriptions.
        if not next(rosterEvents) then
            Messages:UnregisterMessage("BF_UnitUpdated")
            Messages:UnregisterMessage("BF_UnitLeft")
        end
    end
end

-- Called by Layout.lua (SetFrameUnit) when a frame is assigned a unit.
-- Grid2 verbatim (GridRoster.lua RosterRegisterUnit → AddUnit): a unit
-- joins the roster only when the client can currently resolve it
-- (UnitExists). AddUnit seeds roster_guids/roster_names unconditionally
-- with whatever the API returns at that moment and broadcasts
-- BF_UnitUpdated with joined=true — which is what arms the unit's
-- per-unit event frame (see Messages above), exactly like Grid2's
-- Grid_UnitUpdated → GridRosterUnitEvents flow. Populating roster_names
-- here lets the next QueueRosterUpdate sweep detect Unknown→real
-- transitions via the name-change branch and fan out to indicators
-- (Grid2 ticket #628: UnitName often returns "Unknown" for the player's
-- own raid slot during the GROUP_ROSTER_UPDATE storm at login).
function BF:RegisterRosterUnit(unit)
    if not unit or unit == "" then return end
    if not UnitExists(unit) then return end
    if self.roster_guids and self.roster_guids[unit] then return end
    -- Grid2 AddUnit (GridRoster.lua:119-146), minus the realm/dead/
    -- guid-reverse tables BF does not keep.
    if self.roster_guids then self.roster_guids[unit] = UnitGUID(unit) end
    if self.roster_names then self.roster_names[unit] = UnitName(unit) end
    -- v97 (2026-08-27): Grid2 AddUnit seeds roster_deads here
    -- (GridRoster.lua:144). BF never seeded unitWasDeadCache, and a unit that
    -- is ALREADY dead at /reload produces no UNIT_HEALTH / UNIT_FLAGS tick to
    -- seed it, so its resurrection read as alive->alive: no transition, no
    -- sweep, and HealthBarColor never painted the bar (white by default).
    SeedDeadCache(unit)
    -- Grid2 primes per-unit caches from the Grid_UnitUpdated join message
    -- (its Range status subscribes there); BF's range status has no join
    -- subscriber, so the prime stays inline. Grid2 primes with the FULL
    -- range check (self.UnitRangeCheck(unit)), NOT raw UnitInRange:
    -- UnitInRange("pet") fails while solo, so the solo pet must go through
    -- the IsSpellInRange(petSpell) branch. PrimeRangeForUnit routes there.
    if self.rangeCache and self.PrimeRangeForUnit then
        self:PrimeRangeForUnit(unit)
    end
    -- Grid2 AddUnit tail: Grid_UnitUpdated(unit, true) — joined=true is
    -- what GridRosterUnitEvents (BF: Messages above) keys off to arm the
    -- unit's event frame; other subscribers (offline, phased, trackers)
    -- treat it as any identity refresh.
    self:SendMessage("BF_UnitUpdated", unit, true)
end

-- Called by Layout.lua (SetFrameUnit) when the last frame for a unit is unassigned.
-- Grid2 verbatim (GridRoster.lua RosterUnregisterUnit → DelUnit): only a
-- unit actually in the roster is removed. The BF_UnitLeft broadcast at
-- the tail is what disarms the unit's per-unit event frame (see Messages
-- above) and clears per-unit status caches, mirroring Grid_UnitLeft.
function BF:UnregisterRosterUnit(unit)
    if not unit or unit == "" then return end
    if not (self.roster_guids and self.roster_guids[unit]) then return end
    -- Grid2 DelUnit (GridRoster.lua:148-166), minus the realm/dead/
    -- guid-reverse tables BF does not keep.
    self.roster_guids[unit] = nil
    if self.roster_names then self.roster_names[unit] = nil end
    -- Drop any in-flight cast state for the departing unit, otherwise
    -- the castbar status' per-unit table accumulates entries for units
    -- that left the group.
    local cbs = self.statuses and self.statuses.castbar
    if cbs then cbs:ClearUnit(unit) end
    -- Grid2 pattern: Grid_UnitLeft message clears offline cache for departing unit
    -- v92: the dead-state cache is per-unit too (the GRU bulk wipe is gone —
    -- see BF:GROUP_ROSTER_UPDATE). A departing token's entry goes with it.
    if self.unitWasDeadCache then self.unitWasDeadCache[unit] = nil end
    self:SendMessage("BF_UnitLeft", unit)
end

-- Kept for compatibility.
function BF:UnregisterAllRosterUnits()
    for unit in pairs(perUnitFrames) do
        UnregisterUnitEventFrame(unit)
    end
end


function BF:OnEnable()
    -- §L5.1: PLAYER_LOGIN boundary. The delta from init:exit is the client
    -- + other addons, not BuzzardFrames.
    self:LoadMark("enable:enter")
    -- ============================================================
    -- Phase 2: build BF._auraIndicatorsOrdered — the static dispatch
    -- list of aura indicators used by RebuildAuraCacheScope and
    -- IterateAuraCacheScopes. Must run BEFORE the first UpdateAuraSizeCache
    -- call below. All 10 indicators have registered by file-load time
    -- (PLAYER_LOGIN fires OnEnable after every loaded file's top-level
    -- code runs), so BF.indicators[name] lookup is safe here.
    -- ============================================================
    do
        local names = {
            "buffsAndContainers",
            "debuffIcons",
            "bigDefIcons",
            -- v69: "crowdControlIcons" removed — the dedicated Crowd Control
            -- feature became a seeded custom debuff container (crowdControl
            -- preset, HARMFUL|CROWD_CONTROL). See MigrateCrowdControlToContainer.
            "missingRaidBuff",
            "dispelDebuffIndicator",
            "dispelDebuffBorder",
            "dispelDebuffOverlay",
            -- v67: "privateAuraIcons" removed with the Private Auras feature
            -- (12.0.7-only; the addon is 12.1-only from this release). Note
            -- privateAuraDispelOverlay is a SEPARATE, still-live feature and
            -- was never in this list.
        }
        local ordered = {}
        for i = 1, #names do
            local ind = self.indicators and self.indicators[names[i]]
            if not ind then
                error("BuzzardFrames: aura indicator '" .. names[i]
                    .. "' missing from BF.indicators at OnEnable. "
                    .. "Check .toc includes the indicator file and that "
                    .. "the file registers via BF:RegisterIndicator(...) "
                    .. "at top-level (not in OnInitialize).")
            end
            ordered[i] = ind
        end
        self._auraIndicatorsOrdered = ordered
    end
    self:LoadMarkD("enable:indicatorsOrdered")

    -- Migration: showPowerBar master toggle removed. If a user had it enabled,
    -- ensure at least one sub-toggle is on so their power bars keep showing.
    do
        local p = self.db and self.db.profile
        if p and p.showPowerBar then
            if not p.showAllPowerBars and not p.showPowerBarHealers and not p.showPowerBarBloodDK then
                p.showPowerBarHealers = true
            end
            p.showPowerBar = nil  -- clear legacy key
        end
    end

    -- Migration: collapse legacy tier-specific test-mode flags into the single
    -- unified setupModeActive boolean. Runs once at login after AceDB migrations.
    -- The old flags remain in SavedVariables for rollback but are never read at
    -- runtime after this point.
    do
        local g = self.db and self.db.global
        if g and (g.partyTestMode or g.raid20TestMode or g.raid30TestMode or g.raid40TestMode) then
            g.setupModeActive = true
        end
    end

    -- Migration: horizontalGroups (boolean) → raidGrowDirection (string)
    do
        local p = self.db and self.db.profile
        if p and p.horizontalGroups ~= nil then
            if not p.raidGrowDirection then
                p.raidGrowDirection = p.horizontalGroups and "RIGHT" or "DOWN"
            end
            p.horizontalGroups = nil
        end
    end

    -- Migration: party growDirection "HORIZONTAL"/"VERTICAL" → "RIGHT"/"DOWN"
    do
        local p = self.db and self.db.profile
        if p and p.layouts then
            for _, layout in pairs(p.layouts) do
                if layout.party and layout.party.growDirection then
                    local dir = layout.party.growDirection
                    if dir == "HORIZONTAL" then layout.party.growDirection = "RIGHT"
                    elseif dir == "VERTICAL" then layout.party.growDirection = "DOWN" end
                end
            end
        end
    end

    -- Migration: "Mirror Blizzard Frames" filter mode removed (12.0.5 compat).
    -- CompactUnitFrame_UpdateAuras no longer exists as a global function.
    -- Revert any user who had "blizzard" to the appropriate default.
    do
        local p = self.db and self.db.profile
        local acp = self.acDB and self.acDB.profile
        if p and acp then
            -- Debuff filter: "blizzard" → "HARMFUL"
            if acp.debuffFilter == "blizzard" then
                acp.debuffFilter = "HARMFUL"
            end
            -- The healerBuffFilter arm that used to sit here is GONE. Core_DB
            -- nils acp.healerBuffFilter on every login, and that purge runs in
            -- RegisterDB -- strictly before OnEnable -- so the value tested
            -- here was always nil and the branch could never fire. Deleted
            -- with the §14.2 dead-key sweep so the purge's intent is
            -- unambiguous; it is not a behavior change.
            -- Non-healer buff filter: "blizzard" → "player_raid"
            if acp.nonHealerBuffFilter == "blizzard" then
                acp.nonHealerBuffFilter = "player_raid"
            end
        end
    end

    -- The Resto Shaman (264) and Resto Druid (105) "force whitelist"
    -- migrations that lived here were removed 2026-08-15 along with the
    -- per-spec filter key itself. Their rationale --
    -- HELPFUL|PLAYER|RAID_IN_COMBAT does not return weapon imbues
    -- (Earthliving Weapon) or passive buffs (Ancestral Vigor), so SPEC_SPELLS
    -- had to be fetched by spellId instead -- is now served for EVERY healer
    -- spec, and for Augmentation, by the seeded "none" Buffs preset
    -- overrides: they make the Whitelist the source of truth rather than a
    -- Blizzard filter category. See EnsureBuffsPresetsSeeded in
    -- AuraCustomizations.lua.

    -- Initialize class colors from Blizzard's table.
    -- _DefaultClassColors is the pristine baseline (never mutated at
    -- runtime); ApplyCustomClassColors overlays rpDB.profile.colors.customClassColors
    -- on top when useCustomClassColors is enabled. When disabled, the
    -- overlay is a no-op and classColors equals _DefaultClassColors --
    -- same bit-for-bit result as the pre-custom-class-colors code.
    for class, color in pairs(RAID_CLASS_COLORS) do
        self._DefaultClassColors[class] = { r=color.r, g=color.g, b=color.b }
    end
    if self.ApplyCustomClassColors then self:ApplyCustomClassColors() end
    
    -- Default to enabled so frames always work if the context check
    -- hasn't run yet or fails for any reason.
    self._framesActiveForContext = true

    -- Initialize tables
    self.unitFrames = {}
    -- DO NOT overwrite activeFrames here. BFLayout.lua aliases it to
    -- activatedFrames (the Grid2 frame→unit map populated by SetFrameUnit
    -- via OnAttributeChanged). Overwriting it with {} severs that alias
    -- and leaves the Options panel iterating an empty table.
    if not self.activeFrames then self.activeFrames = {} end
    -- DO NOT overwrite rangeCache here. Range.lua sets it up as a
    -- setmetatable({}, {__index=function() return false end}) so that
    -- unknown units default to false (OOR) rather than nil, matching
    -- Grid2's Range.cache pattern. Overwriting it with a plain {} here
    -- destroys that metatable and breaks IsOutOfRange/UpdateRange.
    if not self.rangeCache then
        self.rangeCache = setmetatable({}, { __index = function() return false end })
    end
    
    -- Create a hidden frame to parent Blizzard frames to
    if not self.hiddenFrame then
        self.hiddenFrame = CreateFrame("Frame")
        self.hiddenFrame:Hide()
    end
	
	-- ── Clean up legacy flat p.raid40/30/20 sub-table keys ─────────────────────
	-- The flat p.raid40/30/20 tables should only carry testMode. All frame
	-- settings (frameWidth, anchorX, anchorCoordsAreScreenPixels, etc.) belong
	-- under p.layouts[id].raid40/30/20. Strip any leftovers from old saves.
	do
	    local p = self.db.profile
	    local FLAT_RAID_KEEP = { testMode = true }
	    for _, key in ipairs({"raid40", "raid30", "raid20"}) do
	        local t = p[key]
	        if t then
	            for k in pairs(t) do
	                if not FLAT_RAID_KEEP[k] then t[k] = nil end
	            end
	    end
	end
	end

	-- ── Clean up legacy private aura overlay keys from all layout profiles ──────
	-- These were removed from the UI but may still exist in saved variables.
	do
	    local p = self.db.profile
	    local OVERLAY_KEYS = {
	        "showPrivateAuraOverlay",
	        "privateAuraOverlayOffsetX",
	        "privateAuraOverlayOffsetY",
	        "privateAuraOverlayScale",
	        "privateAuraOverlayAnchorPoint",
	        "privateAuraOverlayGrowDirection",
	    }
	    if p.layouts then
	        for _, layout in pairs(p.layouts) do
	            for _, tier in ipairs({"raid40", "raid30", "raid20", "party"}) do
	                local t = layout[tier]
	                if t then
	                    for _, k in ipairs(OVERLAY_KEYS) do
	                        t[k] = nil
	                    end
	                end
	            end
	        end
	    end
	end

	-- Create anchor with drag handle. Always created, even when both party
	-- and raid frames are globally disabled: CreateAnchor() also builds
	-- self.testAnchorFrame (Setup Mode's independent test anchor — see
	-- SetupMode.lua), and Setup Mode must be able to preview/edit a flat
	-- regardless of whether its live toggle is on. Gating this on the
	-- enable flags left testAnchorFrame nil whenever both were off, so
	-- CreateTestHeader/CreateTestPartyHeader parented their header to a
	-- nil frame, which WoW resolves against UIParent — pinning Setup
	-- Mode's test frames to a screen corner instead of the saved anchor
	-- position. CreateAnchor() itself only creates invisible 1x1 anchor
	-- points; it does not show any real headers (that's gated separately
	-- by UpdateVisibility / the contextDisabled hide path), so creating
	-- it unconditionally is safe.
	self:CreateAnchor()
	-- Restore the single global lock state on reload.
	local lockedValue = self.db.global.locked
	if lockedValue == nil then lockedValue = true end
	self:SetLocked(lockedValue)
    self:SetupMinimapButton()


    -- Populate the file-scoped profile upvalue in UnitFrames.lua so all
    -- Update*() and LayoutFrame() functions see the correct profile from
    -- the very first event (before any OnProfileChanged fires).
    -- §L5.1: RefreshProfileCache's FIRST action is UpdateAuraSizeCache --
    -- aura-cache rebuild #1 of the login (§L1.0 row 22b). Tag it so
    -- /bf loadreport can attribute the pass to this call site.
    self:LoadUASCTag("enable:refreshProfileCache")
    if self.RefreshProfileCache then self:RefreshProfileCache() end
    if self.ApplyCustomPowerColors then self:ApplyCustomPowerColors() end
    if self.ApplyCustomClassColors then self:ApplyCustomClassColors() end

    -- Grid2 pattern: initialize the status→indicator binding system.
    -- Must run after all indicators are registered (Indicators/*.lua)
    -- and before any events fire.
    if self.InitStatusSystem then self:InitStatusSystem() end
    ResolveStatuses()
    self:LoadMarkD("enable:statusSystem")
    if self.RebuildHealthGradientCurves then self:RebuildHealthGradientCurves() end
    
    -- Register unit events for efficient updates
    -- High-frequency unit events (UNIT_HEALTH, UNIT_AURA, etc.) are intentionally
    -- NOT registered here.  They are registered per-unit via RegisterUnitEvent so
    -- the engine only delivers them for roster members, not every unit in the game.
    -- See RegisterRosterUnit / UnregisterAllRosterUnits above.
    -- Grid2 verbatim: NO eager "player" pre-arm here. The player joins the
    -- roster like every other unit — SetFrameUnit → RegisterRosterUnit →
    -- BF_UnitUpdated(joined=true) — and the message handler arms all
    -- active events on its frame at that moment (UnitExists("player") is
    -- always true, so the join can never be refused).

    -- Low-frequency or non-unit events registered globally as before.
    -- Events owned by statuses (via OnEnable) are NOT registered here:
    --   UNIT_THREAT_SITUATION_UPDATE → threat status
    --   UNIT_NAME_UPDATE → name status (also handled at addon-level
    --     by BF:UNIT_NAME_UPDATE below, matching Grid2's pattern of
    --     re-running every indicator on the frame so bar class color
    --     refreshes at the same instant the name arrives).
    --   PLAYER_TARGET_CHANGED → target status
    --   RAID_TARGET_UPDATE → raidicon status
    --   PARTY_LEADER_CHANGED → leader status
    --   INCOMING_RESURRECT_CHANGED → resurrect status
    --   INCOMING_SUMMON_CHANGED → summon status
    --   UNIT_FLAGS / PLAYER_FLAGS_CHANGED → flags status
    -- UNIT_DISPLAYPOWER: now registered per-unit via Power status OnEnable.
    -- UNIT_CONNECTION / PARTY_MEMBER_ENABLE / PARTY_MEMBER_DISABLE:
    --   now owned by offline status (Statuses/Offline.lua) via self:RegisterEvent
    self:RegisterEvent("PLAYER_REGEN_DISABLED")  -- Entering combat
    self:RegisterEvent("PLAYER_REGEN_ENABLED")   -- Leaving combat
    -- UNIT_PORTRAIT_UPDATE → role status
    -- UNIT_PHASE → phased status
    -- READY_CHECK / READY_CHECK_CONFIRM / READY_CHECK_FINISHED → readycheck status
    self:RegisterEvent("UNIT_ENTERED_VEHICLE")
    self:RegisterEvent("UNIT_EXITED_VEHICLE")
    self:RegisterEvent("UNIT_NAME_UPDATE")  -- addon-level fan-out (see BF:UNIT_NAME_UPDATE)

    -- Register events
    -- PLAYER_LOGIN: one-shot post-migration chat message + the deferred
    -- one-time notifications (Core_Notifications.lua).
    --
    -- REGISTERING IT HERE IS TOO LATE ON ITS OWN. AceAddon fires OnEnable FROM
    -- PLAYER_LOGIN -- the comment at the top of this function says as much --
    -- so by the time this line runs the event has already been raised and the
    -- handler would never be called. That is why the 12.1 welcome popup never
    -- appeared on a first 12.1 login.
    --
    -- IsLoggedIn() is the standard test for "has PLAYER_LOGIN already fired".
    -- The RegisterEvent branch is kept for the case where it has not (an addon
    -- enabled by hand before login completes).
    if IsLoggedIn() then
        self:PLAYER_LOGIN()
    else
        self:RegisterEvent("PLAYER_LOGIN")
    end
    self:RegisterEvent("PLAYER_ENTERING_WORLD")
    self:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    self:RegisterEvent("GROUP_ROSTER_UPDATE")
    self:RegisterEvent("PLAYER_ROLES_ASSIGNED")
    self:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
    self:RegisterEvent("PLAYER_TALENT_UPDATE")
    -- Modern trait-system commit event. A talent commit may fire only
    -- this (not PLAYER_TALENT_UPDATE) on 12.x — without it, talent-gated
    -- state (Verdant Infusion swiftmendable gate, hero-tree secret
    -- detection, talent-gated dispels) goes stale until reload. Routed
    -- to the same handler; the deferred refresh inside is debounced.
    self:RegisterEvent("TRAIT_CONFIG_UPDATED", "PLAYER_TALENT_UPDATE")
    -- 12.x: fires the moment an addon restriction (Combat, Encounter,
    -- ChallengeMode, PvPMatch, Map) activates or lifts. Every deferred aura
    -- build in this addon is drained from PLAYER_REGEN_ENABLED and re-tests
    -- BF:IsAuraCreationRestricted() -- which stays TRUE for the whole of an
    -- active keystone run, in or out of combat, because auras are secret for
    -- the run. So a queue armed inside a key was drained by nothing: every
    -- regen edge during the run refused it, and the key ending out of combat
    -- fires no regen edge at all (field report 2026-09-10). This is the
    -- guaranteed "restriction lifted" wake. Registered only where the client
    -- has it; older clients keep the regen-only behavior.
    if C_RestrictedActions then
        self:RegisterEvent("ADDON_RESTRICTION_STATE_CHANGED")
    end
    self:LoadMarkD("enable:eventsRegistered")

    -- Initialize Incoming Casts module (party frames only)
    -- Routes existing BF events to IC; no new Frame:RegisterEvent calls needed.
    if self.IncomingCasts then
        self.IncomingCasts:Init()
    end
    self:LoadMarkD("enable:incomingCasts")

    -- Initialize FrameSort integration (registers as self-managed provider).
    -- Must run after AceAddon is fully set up but before layouts fire.
    if self.InitFrameSort then
        self:InitFrameSort()
    end

    -- ─ One-shot work migrated from PLAYER_ENTERING_WORLD ────────────────
    -- Per PEW_GRID2_REFACTOR_PLAN §2, these only need to run once at addon
    -- load — they self-guard against re-application (HideBlizzardFrames sets
    -- _raidHidden) or are pure cache wipes / initial visibility passes.
    -- Keeping them here lets PLAYER_ENTERING_WORLD collapse to the Grid2
    -- 7-line shape (Init.lua mirroring GridRoster.lua:338-344).

    -- Hide Blizzard's raid/party/raid-manager frames. _raidHidden makes
    -- subsequent calls no-ops; LoadLayout's tail re-attempts if the first
    -- pass failed (combat at addon-load is rare but possible).
    if self.HideBlizzardFrames and not InCombatLockdown() then
        self:HideBlizzardFrames()
    end

    -- NOTE: ApplyOUFVisibility / ApplyBlizzardFrameVisibility were originally
    -- moved here from PLAYER_ENTERING_WORLD per the PEW Grid2-parity refactor.
    -- Empirically that broke oUF unit frame loading because Build* functions
    -- depend on world state (UnitGUID, secure state drivers) that isn't
    -- reliable at OnEnable time on first login. Moved back to PEW.

    -- Start the OnUpdate range timer. Subsequent toggling is driven by
    -- SyncRangeChecker from LoadLayout.
    if self.StartRangeChecker then self:StartRangeChecker() end

    -- Cache the player's spec ID at addon load. PLAYER_SPECIALIZATION_CHANGED
    -- handles all subsequent spec changes; PLAYER_ENTERING_WORLD's
    -- self:PLAYER_SPECIALIZATION_CHANGED('PEW','player') call covers the
    -- LFG-silent-spec-change case on zone-in. Without this OnEnable prime,
    -- the BuffsAndContainers indicator's pre-resolve cache reads
    -- GetSpecialization() every frame until the first spec event fires.
    -- §L5.1: OnPlayerSpecChanged -> InvalidateAllFlatAuraCaches +
    -- UpdateAuraSizeCache = aura-cache rebuild #2 (§L1.0 row 23).
    self:LoadUASCTag("enable:specPrimed")
    if self.OnPlayerSpecChanged then self:OnPlayerSpecChanged() end
    self:LoadMarkD("enable:specPrimed")

    -- Resolve the player's dispel spell for cooldown tracking. Subsequent
    -- changes are handled by PLAYER_SPECIALIZATION_CHANGED and
    -- PLAYER_TALENT_UPDATE; the latter fires on login.
    if self.UpdateDispelCooldownTracking then self:UpdateDispelCooldownTracking() end
    self:LoadMark("enable:exit")
end

-- ============================================================
-- PLAYER ENTERING WORLD
-- ============================================================
-- Turns off all setup/test modes when the player is inside an instance.
-- Called on PLAYER_ENTERING_WORLD and ZONE_CHANGED_NEW_AREA so that
-- entering a dungeon or raid with setup mode active doesn't cause frames
-- to remain at their preview size.
function BF:DisableSetupModeIfInInstance()
    local inInstance = select(2, IsInInstance()) ~= "none"
    if not inInstance then return end
    if not BF.db.global.setupModeActive then return end

    -- Pure UI teardown. Setup Mode edits are saved at the moment of change
    -- (drag-stop / option setter), so exiting here doesn't need to commit
    -- anything. ExitSetupMode() hides the test headers, grid, UF test frames
    -- and restores the real-anchor handle without touching frame geometry.
    self:ExitSetupMode()
end

-- Grid2 parity (GridRoster.lua:338-344). PLAYER_ENTERING_WORLD is a SINGLE
-- entry point into the layout build pipeline — GroupChanged → GroupTypeChanged
-- → _GroupTypeChangedExecute → ApplyProfile → ReloadLayout → LoadLayout.
-- Per PEW_GRID2_REFACTOR_PLAN.md §3.1, all other PEW side-work has migrated:
--   * OnEnable one-shots: HideBlizzardFrames, ApplyOUFVisibility,
--     ApplyBlizzardFrameVisibility, StartRangeChecker
--   * LoadLayout tail: UpdateAuraSizeCache (pre-build prime), the late aura
--     indicator re-layout, BumpGroupLabelGeomKey + UpdateGroupLabels,
--     RefreshAllCustomContainersWithRebuild, HideBlizzardFrames retry
--   * ZONE_CHANGED_NEW_AREA: AnnounceInstanceContext
--   * PLAYER_SPECIALIZATION_CHANGED('PEW','player') call on zone-in (not
--     initial login) mirrors Grid2's GridRoster.lua:339-341 LFG-silent-
--     spec-change guard.
function BF:PLAYER_ENTERING_WORLD(_, isInitialLogin, isReloadingUi)
    -- §L5.1: first PEW. The delta from enable:exit is the client's world
    -- load, not BuzzardFrames. Arming the seal here is what guarantees the
    -- harness costs nothing once the player is actually playing: three
    -- seconds later every collector is swapped for a no-op.
    self:LoadMark("pew:enter")
    self:ArmLoadReportSeal()
    -- Grid2 parity: spec re-resolve only on zone-in (not initial login or
    -- reloadui). On initial login, OnPlayerSpecChanged ran inside OnEnable.
    -- On reload, the PLAYER_SPECIALIZATION_CHANGED event fires naturally.
    -- The remaining case (zone-in into an LFG group that silently changed
    -- the player's spec on the server) needs the re-resolve here.
    if not (isInitialLogin or isReloadingUi) then
        if self.PLAYER_SPECIALIZATION_CHANGED then
            self:PLAYER_SPECIALIZATION_CHANGED("PLAYER_ENTERING_WORLD", "player")
        end
    end

    -- Reset group type so GroupChanged always triggers a layout reload on
    -- zone-in, matching Grid2's `self.groupType = nil` in
    -- PLAYER_ENTERING_WORLD (GridRoster.lua:343).
    self._groupType = nil

    -- Turn off setup mode before any layout work so frames are sized
    -- correctly from the start if the player logs in/reloads inside an
    -- instance. No-op outside instances.
    self:DisableSetupModeIfInInstance()

    -- Apply oUF and Blizzard frame visibility. Must run on EVERY PEW (not
    -- once at OnEnable) because Build* functions depend on world state
    -- (UnitGUID, secure state drivers) that's only reliable post-PEW.
    if self.ApplyOUFVisibility           then self:ApplyOUFVisibility()           end
    -- §L5.1: how many oUF frames this PEW SPAWNED vs re-laid-out. Zero by
    -- default (ptfEnabled = false); ~7 spawns x ~40 widgets when on.
    if not self._loadSealed then self:LoadOUFCounts() end
    -- v96: start the shared ping mirror INDEPENDENTLY of the unit frames.
    -- It used to be reached only through ApplyOUFPlayerLayout, so with
    -- ptfEnabled off (or merely showPlayerFrame off) the player frame was
    -- never built, the mirror never existed, and the RAID/PARTY ping pins
    -- never updated. Self-guards on HasPingPinEvents() and on already-built,
    -- so this is a no-op on repeat PEWs and on builds without the pin.
    if self.EnsurePingMirror then self:EnsurePingMirror() end
    self:LoadMark("pew:oufVisibility")
    if self.ApplyBlizzardFrameVisibility then self:ApplyBlizzardFrameVisibility() end

    -- Single entry into the build pipeline. Respect per-context enable
    -- flags: when both party and raid are off, GroupChanged still runs so
    -- _groupType is set correctly, and _GroupTypeChangedExecute's
    -- contextDisabled branch handles the hide path. Skipping GroupChanged
    -- here would leave _groupType=nil and break later transitions.
    self:LoadMark("pew:preGroupChanged")
    self:GroupChanged()
    self:LoadMark("pew:postGroupChanged")

    -- Grid2 verbatim (GridFrame.lua:284 — Grid2Frame registers
    -- PLAYER_ENTERING_WORLD → UpdateFrameUnits): after the world loads,
    -- re-resolve SecureButton_GetModifiedUnit for every activated frame
    -- and re-run the SetFrameUnit lifecycle on any whose token resolves
    -- differently now (vehicle suffix settled, unit data streamed in).
    -- This is Grid2's re-entry path that re-attempts roster registration
    -- for units assigned during the loading screen; BF carried
    -- UpdateFrameUnits as an unwired port (BFLayout.lua) while Grid2 has
    -- always called it here — the gap left refused units permanently
    -- outside roster_guids, with no per-unit events armed (field report:
    -- Dead text / Offline color+text / range frozen after initial paint).
    self:UpdateFrameUnits()

    -- Cast bar context gates (partyOnly / pvpOnly) depend on instance type,
    -- which can change on zone-in without a group-type change (e.g. logging
    -- in / reloading inside an arena as a party). GroupChanged only re-runs
    -- the castBar rebind when _groupType actually flips, so re-check here.
    -- Idempotent and cold-path; safe on every PEW.
    if self.RebindCastBarStatus then self:RebindCastBarStatus() end

    -- Incoming Casts is dungeon/delve only and gates at event REGISTRATION,
    -- so its context has to be re-evaluated wherever the instance type can
    -- change. Same two hooks as the cast bar rebind above; idempotent.
    if self.IncomingCasts then self.IncomingCasts:RebindContext() end

    -- v64: LOGIN ROBUSTNESS for the Blizzard native dispel overlay.
    -- Deferred sweep running EXACTLY the settings-change refresh path
    -- (UpdateSettings + per-frame Layout/Update, idempotent) once the
    -- build pipeline and roster have settled. Belt-and-braces alongside
    -- the auraUnit latch fix in PrivateAuraDispelOverlay:Update — the
    -- overlay must never depend on the first registration pass alone.
    self:LoadMark("pew:exit")
    C_Timer.After(1.0, function()
        if self.RefreshAllPrivateAuraDispelOverlays then
            self:RefreshAllPrivateAuraDispelOverlays()
        end
    end)
end

-- ============================================================
-- ZONE CHANGED NEW AREA  (fires on every instance transition)
-- ============================================================
function BF:ZONE_CHANGED_NEW_AREA()
    -- v67: the 0.6s ClearBuffHighlightForNonVisibleUnits sweep was removed
    -- (12.1-only) along with the buffHighlight indicator that set the
    -- per-frame flags it tested.
    -- (Phase L: the _modifyingGroupType clear that lived here is gone --
    -- the field was written by ApplyProfile and read by nothing.)
    -- Disable setup mode before GroupChanged rebuilds layout,
    -- in case the player transitions into an instance with it active.
    self:DisableSetupModeIfInInstance()
    self:GroupChanged()

    -- Cast bar context gate (pvpOnly) depends on instance type. Entering or
    -- leaving a PvP instance without a group-type change (e.g. party in the
    -- world -> party in an arena) leaves GroupChanged a no-op, so the castBar
    -- rebind would not otherwise re-run. Re-check here. Idempotent, cold-path.
    if self.RebindCastBarStatus then self:RebindCastBarStatus() end

    -- Incoming Casts context gate -- see the note on the PEW handler.
    if self.IncomingCasts then self.IncomingCasts:RebindContext() end

    -- v92: generation snapshot for the §6.5 safety net below. LoadLayout
    -- bumps _loadLayoutGeneration on entry and its deferred tail runs
    -- RefreshAllCustomContainersWithRebuild — the heaviest refresh in the
    -- addon (~1s at high frame counts). If the generation advanced by the
    -- time the 0.5s timer fires, a LoadLayout ran during this transition and
    -- its tail owns (or already did) the rebuild — running it again here
    -- doubled the loading-screen hitch on every group-type-changing zone.
    local zoneGen = self._loadLayoutGeneration or 0
    C_Timer.After(0.5, function()
        self:InvalidateRaidProfileCache()
        if self.UpdateAnchorPosition then self:UpdateAnchorPosition() end
        local now = GetTime()
        if not self._lastAnnouncedZone or (now - self._lastAnnouncedZone) > 2 then
            self._lastAnnouncedZone = now
            self:AnnounceInstanceContext()
        end
        BF:RefreshPanel("context")
        -- §6.5 safety net: when _groupType didn't change across the zone
        -- transition (e.g. raid → raid instance), GroupChanged above is a
        -- no-op and no LoadLayout fires. In that case we still want to
        -- rebuild the aura caches so missingRaidBuff and debuffs don't
        -- wait for UNIT_AURA to fire.
        -- v92: when _groupType DID change, LoadLayout's tail owns the
        -- rebuild — skip the duplicate (generation snapshot above).
        if self.RefreshAllCustomContainersWithRebuild then
            if (self._loadLayoutGeneration or 0) == zoneGen then
                self:RefreshAllCustomContainersWithRebuild()
            end
        else
            for frame in pairs(self.activeFrames) do
                if frame and frame.unit and frame:IsShown() then
                    self:UpdateFrameIndicators(frame, frame.unit)
                end
            end
            if self.FlushDeferredIndicatorUpdates then self:FlushDeferredIndicatorUpdates() end
        end
    end)
end

-- ============================================================
-- GROUP CHANGED  (mirrors Grid2:GroupChanged)
-- Detects whether the group type/size actually changed and only
-- calls UpdatePartyFrames when it did.  On GROUP_ROSTER_UPDATE
-- where nothing structural changed (member joined/left within the
-- same raid), we do nothing to the headers — OnAttributeChanged
-- on the secure header children already fired and handled unit
-- register/unregister via SetFrameUnit.
-- ============================================================
function BF:GroupChanged()
    local newGroupType
    if IsInRaid() then
        -- Include the capacity tier so that crossing a tier boundary (e.g. 30→40 man)
        -- is treated as a group type change and triggers a full layout/resize.
        local tier = self:GetCapacityTier()
        newGroupType = "raid_" .. tier
        -- A 6+ raid inside a dungeon/scenario/arena renders as raid; a raid
        -- of <=5 there renders as party. Key on that flag so crossing the
        -- 5-member boundary triggers a full relayout.
        if self:IsOversizedRaidInPartyInstance() then
            newGroupType = newGroupType .. "_oversized"
        end
    elseif GetNumGroupMembers() > 0 then
        newGroupType = "party"
    else
        newGroupType = "solo"
    end

    if self._groupType ~= newGroupType then
        self._groupType = newGroupType
        self:GroupTypeChanged()
    end

    -- Always queue a roster pass (names/GUIDs/health refresh), matching
    -- Grid2's QueueUpdateRoster which runs every GROUP_ROSTER_UPDATE.
    self:QueueRosterUpdate()
end

-- Called only when group type or size actually changed.
-- Equivalent to Grid2Layout:Grid_GroupTypeChanged → ReloadLayout.
-- Delegates to ApplyProfile for a nuclear rebuild that guarantees no
-- previous frame geometry or position can leak across context switches.
-- Grid2 pattern: runs synchronously (no debounce). Grid2's ReloadLayout
-- runs immediately on Grid_GroupTypeChanged; BF's GroupChanged() already
-- guards against redundant calls (only fires when _groupType actually
-- changes), so rapid GROUP_ROSTER_UPDATEs that don't change the group
-- type won't trigger this at all.
function BF:GroupTypeChanged()
    -- Grid2 parity (GridLayout.lua:286-294): queue via RunSecure in combat.
    -- Slot 2 sits between the reserved ReloadProfile slot (1) and the
    -- ReloadLayout slot (3). _GroupTypeChangedExecute is the BF-specific
    -- monolithic superset of Grid2's Grid_GroupTypeChanged cascade (setup
    -- mode + role/spec resolve + contextDisabled branch + ApplyProfile +
    -- ReloadLayout), so gating one level above ReloadLayout is the
    -- structural equivalent of Grid2 per-method gating. See
    -- Docs/PEW_GRID2_REFACTOR_PLAN.md §3.3, §3.6.
    if self:RunSecure(2, self, "_GroupTypeChangedExecute") then return end
    self:_GroupTypeChangedExecute()
end

function BF:_GroupTypeChangedExecute()
    -- v96: re-resolve the ping mirror's pin list after this rebuild. At the
    -- TOP deliberately -- the 0.5s debounce means the resolve lands after the
    -- synchronous build below, and this spot covers BOTH exits: the normal
    -- path AND the contextDisabled early return, which still builds custom
    -- frame groups into activeFrames (each carrying a pingIndicatorTex).
    if self.RebuildPingMirror then self:RebuildPingMirror() end

    -- Exit setup mode only when the real-frame flat is actually changing.
    -- The previous unconditional exit fired on every _groupType flip,
    -- including transient roster updates, tier-to-tier changes that
    -- resolve to the same flat, and raid-size changes that don't cause
    -- a relayout. The flat-layouts model decouples "group type" from
    -- "which flat renders": multiple tiers can share a single flat, so
    -- a tier change alone is not sufficient reason to close setup mode.
    --
    -- We compare the flat that ResolveActiveFlat picks for the new slot
    -- against the one we remembered from the last call. If it's the
    -- same flat, the real frames will rebuild against the same data
    -- and setup mode's test overlay remains coherent.
    --
    -- Note: this intentionally does NOT exit on party<->raid conversion
    -- when both types resolve to the same flat (impossible under the
    -- current model since flats are typed, but noted for future
    -- flexibility). Party<->raid normally DOES change the resolved flat
    -- and therefore DOES exit, which is the desired behavior.
    if BF.db.global.setupModeActive then
        local newSlot       = self:GetActiveSlot()
        local newActiveFlat = self:ResolveActiveFlat(newSlot)
        if self._lastActiveFlatForSetup ~= newActiveFlat then
            self:ExitSetupMode()
        end
    end
    -- Always update the remembered flat, whether or not setup mode was
    -- open, so the next _GroupTypeChangedExecute call has an accurate
    -- baseline.
    self._lastActiveFlatForSetup = self:ResolveActiveFlat(self:GetActiveSlot())

    -- Resolve the correct group type and layout for the new context.
    -- GetTrueActiveTab returns "party", "raid20", "raid30", or "raid40"
    -- based purely on game state (instance type, group size, open world
    -- settings), ignoring any active test mode.
    local gt = self:GetTrueActiveTab()

    -- Check per-context enable flags: if the user disabled party or raid
    -- frames individually, hide ALL headers and bail out for that context.
    -- Also set _framesActiveForContext = false so event handlers and timers
    -- skip all work while frames are hidden.
    local g = self.db.global
    local contextDisabled = false
    if gt == "party" and g.partyFramesEnabled == false then
        contextDisabled = true
    elseif gt ~= "party" and g.raidFramesEnabled == false then
        contextDisabled = true
    end

    if contextDisabled then
        self._framesActiveForContext = false
        -- Grid2 parity (GridLayout.lua:854-863): when the current
        -- context's enable flag is off, Grid2 still builds the layout
        -- on Grid_GroupTypeChanged and then `UpdateVisibility` hides
        -- the layout frame. We mirror this: on first reload with the
        -- context disabled (e.g. partyFramesEnabled == false in a
        -- 5-man party), no prior ApplyProfile has run, so headers
        -- don't exist yet for UpdateVisibility / the header :Hide()
        -- loop below to act on. Do a one-shot ReloadLayout(true) to
        -- materialise them. On subsequent reloads / context changes,
        -- _lastAppliedFlat will be set and this guard is a no-op.
        if self._lastAppliedFlat == nil and (not self.groupsUsed or #self.groupsUsed == 0) then
            self:ReloadLayout(true)
        end
        -- Grid2 pattern: hide the anchor frame so all parented headers
        -- and their children are hidden. UpdateVisibility checks the
        -- enable flags and hides the anchor.
        if self.UpdateVisibility then self:UpdateVisibility() end
        if not InCombatLockdown() then
            -- Also explicitly hide headers in case they aren't parented
            -- to the anchor (e.g. during startup before PlaceHeaders ran).
            if self.groupsUsed and #self.groupsUsed > 0 then
                for _, header in ipairs(self.groupsUsed) do
                    if not header.isCustomFrame then
                        header:Hide()
                    end
                end
            elseif self.mainHeader then
                self.mainHeader:Hide()
            end
        end
        -- Still build and show any enabled custom frame groups — they are
        -- independent of the global party/raid enable toggle.
        if self.AddCustomFrameHeaders and self.groupsUsed then
            self:ResolveContext(gt)
            self:InvalidateRaidProfileCache()
            self:SetResolvedProfile(self._contextIsRaid)
            -- Only rebuild if custom frames aren't already present
            local hasCustom = false
            for _, h in ipairs(self.groupsUsed) do
                if h.isCustomFrame then hasCustom = true; break end
            end
            if not hasCustom then
                self:AddCustomFrameHeaders()
                self:PlaceHeaders()
                -- PlaceHeaders() has no concept of "custom frames only" — it
                -- repositions and :Show()s every non-detached header currently
                -- in groupsUsed, which still includes the real party/raid
                -- header we just hid above. Without this, that header pops
                -- back up (and, since anchorFrame doesn't exist while this
                -- context is disabled, lands pinned to UIParent's corner
                -- instead of the user's saved position).
                if not InCombatLockdown() then
                    for _, header in ipairs(self.groupsUsed) do
                        if not header.isCustomFrame then
                            header:Hide()
                        end
                    end
                end
            end
        end
        -- Stop the range timer only if no custom frame groups are active.
        -- Custom frames may still show units that need range checking even
        -- when the global party/raid toggle is off.
        local anyCustomFrames = false
        if self.groupsUsed then
            for _, h in ipairs(self.groupsUsed) do
                if h.isCustomFrame then anyCustomFrames = true; break end
            end
        end
        if anyCustomFrames then
            -- Custom frames are present: ensure the range checker is running.
            -- It may have been stopped by a previous contextDisabled pass before
            -- these groups existed, or by StopRangeChecker called elsewhere.
            if self.SyncRangeChecker then self:SyncRangeChecker() end
        else
            if self.StopRangeChecker then self:StopRangeChecker() end
        end
        return
    end

    -- Context is enabled: mark active so all event handlers proceed normally.
    -- Defaults to true so frames work even if this code path is never reached.
    self._framesActiveForContext = true

    -- Re-resolve role/spec overrides without triggering RefreshAll
    -- (ApplyProfile will do the full rebuild). Phase L: the named-layout
    -- return value is gone -- ApplyRoleSpecLayout only refreshes the
    -- override resolution state now.
    self:ApplyRoleSpecLayout(true, true)

    -- Resolve UF layout independently (positions only, no frame rebuild)
    if self.ApplyUFRoleSpecLayout then
        self:ApplyUFRoleSpecLayout(true)
    end

    -- Skip the nuclear ApplyProfile rebuild when the resolved flat AND
    -- context are unchanged from the last successful ApplyProfile. This
    -- mirrors Grid2's pattern: GridRoster fires Grid_GroupTypeChanged on
    -- every group-type flip, but Grid2Layout:ReloadLayout gates the
    -- LoadLayout call on whether the resolved layoutName actually changed
    -- (GridLayout.lua line 535). We apply the same idea here one level up:
    -- if the inputs ApplyProfile reads (flat + context) haven't changed,
    -- its output would be identical, so call the lighter ReloadLayout
    -- instead and let its own layoutName gate decide whether LoadLayout
    -- needs to run.
    --
    -- _lastAppliedFlat and _lastAppliedContextIsRaid are set at the end
    -- of ApplyProfile. On first call in a fresh session they are nil, so
    -- the comparison fails and ApplyProfile runs -- the correct default.
    -- Phase L: the layoutID comparison leg is gone with the named-layout
    -- system -- role/spec switches change the RESOLVED FLAT (via
    -- roleOverrides/specOverrides), so the flat+context pair is the
    -- complete identity of an apply.
    local newFlat    = self:ResolveActiveFlat(self:GetActiveSlot())
    local newIsRaid  = (gt ~= "party")
    local lastFlat   = self._lastAppliedFlat
    local lastIsRaid = self._lastAppliedContextIsRaid
    if lastFlat ~= nil and lastFlat == newFlat
       and lastIsRaid == newIsRaid then
        -- Same flat + same context -> ApplyProfile would
        -- be a no-op rebuild. Call ReloadLayout without force; its gate
        -- will no-op when layoutName and instance sizing are unchanged,
        -- and will rebuild only if layoutHasAuto + sizing crossed a
        -- threshold (e.g. maxGroup changed within the same tier).
        -- Resolve _contextIsRaid/_resolvedProfile the same way ApplyProfile
        -- would so downstream reads stay consistent. SetResolvedProfile
        -- atomically updates _resolvedProfile and the _lastResolvedFlatID
        -- cache key — see Core_ProfileAPI.lua.
        self:ResolveContext(gt)
        self:InvalidateRaidProfileCache()
        self:SetResolvedProfile(self._contextIsRaid)
        self:ReloadLayout()
    else
        -- ApplyProfile does: abort test mode, nuke all caches, move
        -- anchor, full header rebuild, LayoutFrame+UpdateFrame sweep,
        -- deferred visual refresh, and options panel notification.
        self:ApplyProfile(gt)
    end

    -- Hide test header when entering a real group (it should not be
    -- visible alongside real frames outside of setup mode).
    if self.testHeader and (IsInRaid() or IsInGroup()) then
        self.testHeader:Hide()
    end
    -- HideBlizzardFrames here removed: it's a one-shot at OnEnable and
    -- LoadLayout's tail retries if the OnEnable pass was skipped. The
    -- _raidHidden self-guard makes any subsequent call a no-op anyway.
    -- See PEW_GRID2_REFACTOR_PLAN §2.
end

-- Throttled to next frame like Grid2's QueueUpdateRoster.
-- Updates health/icons for all active frames after roster settles.
do
    -- roster_guids mirrors Grid2's roster_guids: unit -> last known GUID.
    -- roster_names mirrors Grid2's roster_names: unit -> last known name.
    -- UpdateRoster compares UnitGUID/UnitName against stored values; only
    -- calls UpdateFrame on frames whose slot's identity changed.
    local roster_guids = {}
    local roster_names = {}  -- Grid2 pattern: track names to detect name changes
    -- Grid2 pattern (GridRoster.lua): roster_unknowns flag flips true when
    -- any unit reports UNKNOWNOBJECT during a sweep. Workaround for Blizzard
    -- bug (Grid2 ticket #628) where UnitName returns "Unknown" briefly during
    -- the GROUP_ROSTER_UPDATE storm at login, most notably for the player's
    -- own raid slot. Exposed via BF:RosterHasUnknowns() so callers can poll.
    local roster_unknowns = false
    BF.roster_guids = roster_guids  -- expose: RegisterRosterUnit seeds it; RosterUnitEvent iterates it (Grid2 IterateRosterUnits)
    BF.roster_names = roster_names  -- expose so RegisterRosterUnit can seed names

    function BF:RosterHasUnknowns() return roster_unknowns end

    -- Grid2 pattern (GridRoster.lua UpdateUnit lines 79-117): both the GUID
    -- check and the name check run independently. Either changing returns
    -- true so the caller knows to fan out. Also updates roster_unknowns.
    -- Extracted as a local so both the sweep and BF:UNIT_NAME_UPDATE can
    -- call it — mirrors Grid2's UNIT_NAME_UPDATE which calls UpdateUnit
    -- before UpdateFramesOfUnit (GridRoster.lua:194-197).
    local function UpdateUnit(unit)
        local modified
        -- GUID check (GridRoster.lua:81-94). Guard against secret values
        -- before comparing: pet unit GUIDs are secret when the executing
        -- code is tainted by an addon.
        local guid = UnitGUID(unit)
        local old_guid = roster_guids[unit]
        if issecretvalue(guid) or issecretvalue(old_guid) or guid ~= old_guid then
            roster_guids[unit] = guid
            modified = true
        end
        -- Name check (GridRoster.lua:95-107) — runs independently of the
        -- GUID check, matching Grid2 exactly.
        local name = UnitName(unit)
        if not issecretvalue(name) and name == UNKNOWNOBJECT then
            roster_unknowns = true
        end
        if issecretvalue(name) or issecretvalue(roster_names[unit]) or name ~= roster_names[unit] then
            roster_names[unit] = name
            modified = true
        end
        -- Grid2 parity (GridRoster.lua:112-115): broadcast the identity
        -- change BEFORE the caller repaints, so per-unit cache owners
        -- (offline, phased, single-aura trackers) refresh first and the
        -- repaint renders fresh data. Without this, the "same token,
        -- different occupant" sweep branch and the login Unknown→real
        -- resolve repainted indicators against the previous occupant's
        -- cached state. Fires only when GUID or name actually changed:
        -- zero cost on quiet sweeps.
        if modified then
            -- Same token, different occupant — the dead-state cache still
            -- describes the PREVIOUS occupant, so refresh it to the new
            -- one's ACTUAL state (not "alive"). SeedDeadCache overwrites.
            SeedDeadCache(unit)
            BF:SendMessage("BF_UnitUpdated", unit)
        end
        return modified
    end

    -- Expose to BF:UNIT_NAME_UPDATE (defined later in this file, outside
    -- this `do` block) so it can refresh the cached name + unknowns flag
    -- before fanning out, exactly like Grid2's UNIT_NAME_UPDATE handler.
    BF._RosterUpdateUnit = UpdateUnit

    local rosterUpdateFrame = CreateFrame("Frame")
    rosterUpdateFrame:Hide()
    BF._profFrames = BF._profFrames or {}
    BF._profFrames["Roster defer"] = rosterUpdateFrame  -- Profiler.lua script-wrap registry
    rosterUpdateFrame:SetScript("OnUpdate", function(self)
        self:Hide()
        local bf = BF
        -- Skip roster update work when ALL frames are inactive -- unless a
        -- raid-style twin is live, whose token is swept here for identity
        -- changes like any other (see PerUnitOnEvent above).
        if AllFramesInactive() and not AnyTwinActive() then return end
        if bf.SyncRangeChecker then bf:SyncRangeChecker() end
        -- Grid2:UpdateRoster (verbatim logic from GridRoster.lua:231-239):
        -- Reset the unknowns flag at the start of every sweep so it reflects
        -- "are any unknowns CURRENTLY present" rather than "have any ever been seen".
        roster_unknowns = false
        -- Iterate known units. If GUID or name changed, call UpdateFramesOfUnit.
        -- New units are handled by OnAttributeChanged → SetFrameUnit, not here.
        --
        -- Grid2 verbatim (GridRoster.lua:233-237):
        --     for unit in next, roster_guids do
        --         if UnitExists(unit) and UpdateUnit(unit) then
        --             self:UpdateFramesOfUnit(unit)
        --         end
        --     end
        --
        -- Do NOT add an `else` branch that evicts the unit when UnitExists is
        -- false. That was BF's bug and Grid2 has no analog: during the login
        -- GROUP_ROSTER_UPDATE storm UnitExists is TRANSIENTLY false, and evicting
        -- on that is permanent. RegisterRosterUnit is the only writer into
        -- roster_guids and it sits behind SetFrameUnit's first-frame guard
        -- (`if not next(frames)`, BFLayout.lua:129-131), which never re-fires once
        -- the bucket is populated — so an evicted unit never comes back. The
        -- player's own slot is exactly the one #628 leaves unresolved longest, so
        -- it got evicted, the sweep then never visited it, UpdateUnit never ran,
        -- roster_unknowns never set, and the FixRoster recovery loop never armed:
        -- blank name until /reload. Everything else on the frame kept working
        -- because eviction bypasses UnregisterRosterUnit, leaving perUnitFrames
        -- intact — which is why only the name was affected.
        --
        -- Skipping is safe: departures are handled the same way Grid2 handles them,
        -- via SetFrameUnit(frame, nil) → BF:UnregisterRosterUnit (BFLayout.lua:124),
        -- which is already wired identically to Grid2's RosterUnregisterUnit. A
        -- transiently-missing unit is simply re-checked on the next sweep.
        -- v99c: GROUP_ROSTER_UPDATE is what the game fires when a member
        -- changes zone / instance -- the trigger behind the engine repainting
        -- unfiltered auras on a member the client can no longer see. Re-sample
        -- visibility for every roster unit here (one UnitIsVisible + a cache
        -- compare each; the gate only re-runs on an edge).
        local resample = bf.ResampleUnitVisibility
        for unit in next, roster_guids do
            if resample and UnitExists(unit) then resample(unit) end
            if UnitExists(unit) and UpdateUnit(unit) then
                -- Grid2:UpdateFramesOfUnit
                local bucket = bf.frames_of_unit and rawget(bf.frames_of_unit, unit)
                if bucket then
                    for frame in next, bucket do
                        local old, new = frame.unit, SecureButton_GetModifiedUnit(frame)
                        if old ~= new then
                            bf.SetFrameUnit(frame, new)
                            bf.OnUnitChanged(frame, new)
                        else
                            -- Grid2 UpdateFramesOfUnit(unit, true) ->
                            -- UpdateIndicators(true): same token, new
                            -- occupant, so the aura containers get their
                            -- UpdateAllAuras rebuild -- plus BF's own
                            -- per-frame occupant-state reset (v97, see
                            -- BF.OnUnitOccupantChanged in BFLayout.lua).
                            bf.OnUnitOccupantChanged(frame, unit)
                        end
                    end
                end
            end
        end
        -- Re-anchor group labels after roster settles: child frames may
        -- have shifted (compacted) or hidden, invalidating label anchors.
        if bf.UpdateGroupLabels and not InCombatLockdown() then
            bf:UpdateGroupLabels()
        end
        -- Grid2 parity (GridRoster.lua:238 + GridLayout.lua:297-301):
        -- UpdateRoster ends by broadcasting the unknowns flag via
        -- "Grid_RosterUpdate"; Grid2Layout responds by arming a 0.25s
        -- throttled FixRoster poll that re-runs UpdateHeaders + the
        -- roster sweep until the Blizzard login bug (ticket #628:
        -- UnitName returns UNKNOWNOBJECT during the GROUP_ROSTER_UPDATE
        -- storm, notably for the player's own slot) clears. BF calls
        -- FixRoster directly instead of hopping through a message bus —
        -- identical flow, one fewer dispatch. Each FixRoster pass that
        -- still sees unknowns queues another sweep, and that sweep's
        -- tail re-arms the throttle, exactly mirroring Grid2's
        -- UpdateRoster → Grid_RosterUpdate → FixRoster cycle.
        if roster_unknowns and bf.FixRoster then
            bf:RunThrottled(bf, "FixRoster", 0.25)
        end
    end)
    function BF:QueueRosterUpdate()
        rosterUpdateFrame:Show()
    end
end

do
    -- groupChangedFrame mirrors rosterUpdateFrame's pattern: hidden frame +
    -- OnUpdate + Show() from caller. Defers GroupChanged and the rest of the
    -- IsInRaid()-dependent cascade to next frame so Blizzard's group APIs
    -- settle through the GRU storm during a party<->raid auto-conversion.
    -- Without this, GRU fires while IsInRaid()==false but GetNumGroupMembers()
    -- already reflects the new size, causing a misclassification as "party"
    -- and a transient frame render at party size before snapping to raid.
    local groupChangedFrame = CreateFrame("Frame")
    groupChangedFrame:Hide()
    BF._profFrames = BF._profFrames or {}
    BF._profFrames["GroupChanged defer"] = groupChangedFrame  -- Profiler.lua script-wrap registry
    groupChangedFrame:SetScript("OnUpdate", function(self)
        self:Hide()
        local bf = BF
        -- Re-check both early-exit guards from the synchronous GRU body:
        -- AllFramesInactive AND the partyFramesEnabled/raidFramesEnabled
        -- + custom-frame fallback. _framesActiveForContext (read by
        -- AllFramesInactive) is updated by _GroupTypeChangedExecute and
        -- can briefly disagree with the per-flag toggles between frames,
        -- so both guards are needed (the synchronous body's guards may
        -- have passed at GRU time but state could have flipped during
        -- the one-tick wait).
        if AllFramesInactive() then return end
        local g = bf.db.global
        if g.partyFramesEnabled == false and g.raidFramesEnabled == false then
            local anyCustom = false
            if bf.groupsUsed then
                for _, h in ipairs(bf.groupsUsed) do
                    if h.isCustomFrame then anyCustom = true; break end
                end
            end
            if not anyCustom then return end
        end

        -- Order matches today's synchronous GRU body (lines 1150, 1174,
        -- 1176, 1187 in pre-fix code) for safety. AnnounceRaidSizeChange
        -- does not depend on _contextIs* state that GroupChanged writes
        -- (it resolves the active slot independently), so its position
        -- before GroupChanged is fine and preserves today's dedup keying.
        bf:AnnounceRaidSizeChange()
        bf:GroupChanged()
        bf:UpdateVisibility()
        bf:CheckFitResizeOnRoster()

        -- FrameSort re-sort moved here from a separate C_Timer.After(0)
        -- in the synchronous GRU body. Direct call (no extra timer) so
        -- ordering against GroupChanged is deterministic: Sort runs AFTER
        -- ResolveContext has updated _contextIsParty/_contextIsRaid that
        -- IsFrameSortActive reads. In the flip case
        -- FrameSortOnLayoutReloaded (BFLayout.lua) also runs Sort —
        -- benign duplicate with identical inputs.
        if bf:IsFrameSortActive() and not InCombatLockdown() then
            if bf.groupsUsed and #bf.groupsUsed > 0 then
                local fsProvider = bf._frameSortProvider
                if fsProvider and fsProvider.Sort then
                    fsProvider:Sort()
                end
            end
        end
    end)
    function BF:QueueGroupChanged()
        groupChangedFrame:Show()
    end
end

-- ============================================================
-- GROUP ROSTER UPDATE
-- ============================================================
function BF:GROUP_ROSTER_UPDATE()
    -- Bail early only when ALL frames are inactive (context disabled AND no custom frames).
    if AllFramesInactive() then return end
    local g = self.db.global
    if g.partyFramesEnabled == false and g.raidFramesEnabled == false then
        -- Main frames disabled — but still process roster if custom frames exist.
        local anyCustom = false
        if self.groupsUsed then
            for _, h in ipairs(self.groupsUsed) do
                if h.isCustomFrame then anyCustom = true; break end
            end
        end
        if not anyCustom then return end
    end
    -- EAGER invalidation, deliberately kept (a v92 attempt to remove it was
    -- REVERTED, owner-reported): it looks redundant with ReloadLayout's
    -- gated invalidation, but two same-tick/next-frame consumers read the
    -- section caches BEFORE the deferred QueueGroupChanged → ReloadLayout
    -- gate can run — the RunThrottled UpdateSize below (sorting section →
    -- anchor-box fit) and the QueueRosterUpdate repaint sweep. On a
    -- party→raid flip with an unchanged layout name, nothing re-runs them
    -- after the deferred invalidation, so they'd act on the OLD context's
    -- sections permanently (symptom: raid frames off-position after a raid
    -- join). Do not remove without moving those consumers behind the
    -- deferred gate first.
    self:InvalidateRaidProfileCache()
    -- Clear dispel color caches (now owned by the dispel status)
    local S_DISPEL = self.statuses and self.statuses.dispel
    if S_DISPEL and S_DISPEL.ClearAllCaches then S_DISPEL:ClearAllCaches() end
    table.wipe(unitToFrameCache)
    -- Grid2 pattern: offline cache is NOT bulk-wiped here. Individual
    -- BF_UnitLeft messages fire as units depart (via SetFrameUnit →
    -- UnregisterRosterUnit), and BF_UnitUpdated fires as new units arrive
    -- (via OnUnitChanged). This matches Grid2's DelUnit → Grid_UnitLeft
    -- and AddUnit → Grid_UnitUpdated flow.
    --
    -- PERF (v92): the dead-state cache follows the SAME per-unit pattern
    -- (cleared in UnregisterRosterUnit, re-seeded in UpdateUnit's
    -- identity-change branch) instead of being bulk-wiped here. The bulk
    -- wipe reset every unit to "was alive", so each currently-dead raider
    -- re-fired a death transition and its repaint on their next UNIT_HEALTH
    -- tick after ANY mid-combat roster event, for units whose state never
    -- changed.
    -- (Phase L: the _modifyingGroupType clear that lived here is gone --
    -- the field was written by ApplyProfile and read by nothing.)

    -- Surgical fix for the per-unit refresh lag: QueueRosterUpdate fires
    -- the roster sweep on the very next frame, matching today's timing.
    -- BF:GroupChanged (called from inside the deferred QueueGroupChanged
    -- below) also calls QueueRosterUpdate, but rosterUpdateFrame:Show() is
    -- idempotent when the frame is already shown — both calls coalesce
    -- into a single OnUpdate fire next frame.
    self:QueueRosterUpdate()
    -- Defer GroupChanged + IsInRaid()-dependent work to next frame so
    -- Blizzard's group APIs settle through the GRU storm during a
    -- party<->raid auto-conversion before classification runs.
    self:QueueGroupChanged()
    -- Grid2 pattern (GridLayout.lua Grid_RosterUpdate -> RunThrottled
    -- UpdateSize 0.01): re-fit the anchor box after the secure header
    -- reflows for the new roster (the header reflow lands AFTER this
    -- event, hence the delay). Required for party Grow-from-Center: the
    -- box is CENTER-pinned, so a member joining/leaving must re-fit it
    -- or the remaining frames sit off-pin (field report: leaving a 5-man
    -- left the solo frame at slot 1 instead of the pin). Free otherwise:
    -- UpdateSize's SetSize is change-guarded.
    self:RunThrottled(self, "UpdateSize", 0.01)
end

-- Recompute the live occupied-group count. If it changed since the last
-- resize AND scaleRaidToFit is on AND we're in a raid, run ResizeAllFrames
-- (and the setup-mode equivalent) to re-apply the fit width. In combat,
-- queue via RunSecure at priority 6 — Grid2 parity with
-- UpdateFramesSizeByRaidSize (GridLayout.lua:796-806).
--
-- "Occupied groups" is the number of raid groups (1-8) with at least one
-- member -- which is what visually determines column count, not total
-- player count. 3 players spread across 3 groups = 3 columns.
--
-- §3.6 superset tail: after the resize, also run ApplyOUFPlayerLayout (pri
-- 7) and UpdateVisibility (pri 8) so this pri-6 method remains a superset
-- of those tiers under RunSecure's strict-priority displacement.
function BF:CheckFitResizeOnRoster()
    local lp = self.rpDB and self.rpDB.profile and self.rpDB.profile.layouts
    if not lp or not lp.scaleRaidToFit then
        -- Setting off: clear any stale state.
        self._fitGroupCount = nil
        return
    end
    if not IsInRaid() then
        -- Not in a raid: reset the cache so the next entry into a raid
        -- resizes from a clean baseline.
        self._fitGroupCount = nil
        return
    end
    local bucket = self:GetOccupiedGroupCount() or 0
    if bucket == self._fitGroupCount then return end

    if self:RunSecure(6, self, "CheckFitResizeOnRoster") then return end

    self._fitGroupCount = bucket
    if self.ResizeAllFrames then self:ResizeAllFrames() end
    if BF.db.global.setupModeActive and self.ResizeTestFramesInPlace then
        self:ResizeTestFramesInPlace()
    end

    -- Superset tail (§3.6): keep pri 6 a superset of pri 7/8.
    if self.ApplyOUFPlayerLayout then self:ApplyOUFPlayerLayout() end
    if self.UpdateVisibility     then self:UpdateVisibility()     end
end

-- ============================================================
-- PLAYER ROLES ASSIGNED
-- ============================================================
function BF:PLAYER_ROLES_ASSIGNED()
    -- In combat: route the layout re-evaluation through GroupTypeChanged →
    -- RunSecure(2, _GroupTypeChangedExecute). _GroupTypeChangedExecute's body
    -- already calls ApplyRoleSpecLayout(true, true) and ApplyUFRoleSpecLayout(true)
    -- as part of its cascade, so the role/spec layout re-resolution runs on
    -- combat exit. The role-status sweep below is non-secure and can run now.
    -- See PEW_GRID2_REFACTOR_PLAN §3.5 (_pendingRolesUpdate → ApplyProfile
    -- self-deferral path).
    if InCombatLockdown() then
        if self.GroupTypeChanged then self:GroupTypeChanged() end
        local S_ROLE = self.statuses and self.statuses.role
        if S_ROLE and S_ROLE.UpdateAllUnits then S_ROLE:UpdateAllUnits() end
        return
    end

    -- Out of combat: skip the redundant UpdatePartyFrames call. GroupTypeChanged
    -- (triggered by GROUP_ROSTER_UPDATE) already calls ApplyProfile which fully
    -- rebuilds the layout. PLAYER_ROLES_ASSIGNED fires immediately after group
    -- changes and login/reload — in all cases ApplyProfile has already run.
    -- Running UpdatePartyFrames here causes a redundant Hide/Show cycle that
    -- makes frames flash. Grid2 does not call ReloadLayout from
    -- PLAYER_ROLES_ASSIGNED for the same reason. The legacy
    -- _startupRolesGuard flag was deleted as part of the PEW collapse
    -- (PEW_GRID2_REFACTOR_PLAN §2).

    -- Role assignment may have changed which layout/profile applies.
    C_Timer.After(0.1, function()
        if self.ApplyRoleSpecLayout then
            self:ApplyRoleSpecLayout()
        end
        if self.ApplyUFRoleSpecLayout then
            self:ApplyUFRoleSpecLayout()
        end
    end)
    -- Grid2 pattern: Grid2:PLAYER_ROLES_ASSIGNED sends Grid_PlayerRolesAssigned
    -- which triggers DungeonRole:UpdateAllUnits — a sweep of all roster units.
    -- This is necessary because PLAYER_ROLES_ASSIGNED has no unit arg and fires
    -- when ANY group member's role changes (including spec change).
    local S_ROLE = self.statuses and self.statuses.role
    if S_ROLE and S_ROLE.UpdateAllUnits then S_ROLE:UpdateAllUnits() end
end

-- ============================================================
-- PLAYER SPECIALIZATION CHANGED
-- ============================================================
function BF:PLAYER_SPECIALIZATION_CHANGED(event, unit)
    -- Only care about the player's own spec change
    if unit ~= "player" then return end
    -- Small delay to let GetSpecialization() return the new spec
    C_Timer.After(0.2, function()
        -- §L5.1: aura-cache rebuild #7 on a /reload. Fires AFTER the
        -- synchronous PEW build, which is why Stage 1's latch cannot reach it.
        self:LoadUASCTag("spec:deferredRebuild")
        if self.OnPlayerSpecChanged then
            self:OnPlayerSpecChanged()
        end
        self:LoadMark("spec:deferredRebuild")
        -- Re-resolve dispel spell for cooldown tracking (spell changes with spec)
        if self.UpdateDispelCooldownTracking then self:UpdateDispelCooldownTracking() end
        -- (Removed in dbVersion 17: ApplyProfileAutoSwitch call.
        --  Auto-switch is ripped out as part of the Modular Profiles rework.
        --  ApplyRoleSpecLayout / ApplyUFRoleSpecLayout below still run so that
        --  the per-module layout follows spec changes the same as before.)
        if self.ApplyRoleSpecLayout then
            self:ApplyRoleSpecLayout()
        end
        if self.ApplyUFRoleSpecLayout then
            self:ApplyUFRoleSpecLayout()
        end
        -- Update indicators on the player frame since role may have changed
        for frame in pairs(self.activeFrames or {}) do
            if frame and frame.unit and UnitIsUnit(frame.unit, "player") then
                frame:UpdateIndicators()
            end
        end
        -- Refresh options UI so spec tab icons update to the new spec.
        -- v72 (perf plan L1.6 D3): the bridge refreshes only an OPEN panel.
        -- PLAYER_SPECIALIZATION_CHANGED fires on the login path, and a
        -- panel nobody is looking at has nothing to redraw.
        BF:RefreshPanel("spec")
        -- If we're in setup mode, the layout change must be reflected in the
        -- dummy frames immediately (ApplyRoleSpecLayout only updates the pointer).
        if BF.db.global.setupModeActive then
            self:InvalidateRaidProfileCache()
            if self.RefreshAll then self:RefreshAll() end
        end
    end)
end

-- ============================================================
-- PLAYER TALENT UPDATE
-- ============================================================
function BF:PLAYER_TALENT_UPDATE()
    if self.RebuildMissingRaidBuffCaches then
        self:RebuildMissingRaidBuffCaches()
    end
    -- Re-resolve dispel spell (some dispels are talent-gated)
    if self.UpdateDispelCooldownTracking then self:UpdateDispelCooldownTracking() end
    -- Talent-gated secret detection (e.g. Holy Paladin's Dawnlight vs Holy
    -- Armaments, resolved by hero tree via IsPlayerSpell) is cached in
    -- EnsureFetchBuffSettings behind _fbsValid. A hero-tree swap fires
    -- PLAYER_TALENT_UPDATE (not PLAYER_SPECIALIZATION_CHANGED), so invalidate
    -- the claimed-spell cache here to force the RIC sentinel to re-resolve. This
    -- is a rare event (login / talent edit / spec change), never a combat hot
    -- path, so the broader invalidation cost is acceptable.
    if self.InvalidateClaimedSpellCache then self:InvalidateClaimedSpellCache() end
    -- 12.1: re-apply container config to live frames so talent-gated
    -- feature state (e.g. the Verdant Infusion swiftmendable gate — VI
    -- makes every unit swiftmendable, so the slots park) takes effect
    -- without a reload. DEFERRED 0.2s: IsPlayerSpell can still report
    -- the PRE-change talent state when PLAYER_TALENT_UPDATE fires (same
    -- staleness the PLAYER_SPECIALIZATION_CHANGED handler defers for),
    -- and a synchronous rebuild would bake that stale state into the
    -- settings cache with nothing to invalidate it afterward. The
    -- invalidation must happen INSIDE the timer for the same reason.
    -- Rare event, never a combat hot path.
    -- v67: 12.0.7 branch removed (addon is 12.1-only).
    if not self._bf_talentRefreshPending then
        self._bf_talentRefreshPending = true
        C_Timer.After(0.2, function()
            BF._bf_talentRefreshPending = nil
            if InCombatLockdown() then return end
            if BF.InvalidateClaimedSpellCache then BF:InvalidateClaimedSpellCache() end
            if BF.RefreshAllAuras then BF:RefreshAllAuras() end
        end)
    end
end

-- PLAYER_TARGET_CHANGED: now owned by target status (BFStatus.lua)

-- ============================================================
-- UNIT EVENT HANDLERS (event-based updates)
-- ============================================================
-- Health events
-- Grid2 pattern (StatusHealth.lua): Health status owns UNIT_HEALTH and fires
-- UpdateIndicators to its bound indicators. Death and shieldsOverflow are
-- separate statuses that also register UNIT_HEALTH independently via their
-- own OnEnable (see BFStatus.lua). Each status only dispatches to its bound
-- indicators, so the per-tick work collapses to what the active feature set
-- actually needs.
--
-- Before this refactor, BF:UNIT_HEALTH did three things on every tick:
--   1. S_HEALTH:UpdateIndicators (one bucket iteration)  -- kept
--   2. Absorb overlay clamp: global lookup + UnitIsDeadOrGhost check +
--      a second full bucket iteration calling _UpdateAbsorbOverlayHealth
--      for every frame regardless of whether absorbs were enabled
--   3. Death transition work (change-guarded, but always evaluated)
--
-- After the refactor, (2) is owned by the shieldsOverflow status (only
-- enabled when showAbsorbsMissingHealth is on in any flat) via the
-- absorbBarsHealthClamp sidekick indicator. (3) is owned by the death
-- status's own UNIT_HEALTH handler with the change guard (99% of events
-- skip everything). 99% of UNIT_HEALTH events now do one bucket iteration.
function BF:UNIT_HEALTH(event, unit)
    if S_HEALTH then S_HEALTH:UpdateIndicators(unit) end
end

function BF:UNIT_MAXHEALTH(event, unit)
    if S_HEALTH then S_HEALTH:UpdateIndicators(unit) end
    -- Grid2 pattern: shields status registers UNIT_MAXHEALTH so absorb bars
    -- update when max health changes (SetMinMaxValues depends on it).
    if S_ABSORBS then S_ABSORBS:UpdateIndicators(unit) end
end

-- Power events
-- v94 PERF (Win 1): UNIT_POWER_UPDATE fires for EVERY resource a unit
-- owns, but a raid frame's power bar only ever shows one. Ticks for a
-- resource the bar isn't displaying -- combo points, runes, holy power,
-- soul shards, chi, arcane charges, maelstrom, etc. regenerating or
-- churning under an energy / focus / runic-power bar -- used to run the
-- full per-frame update (ShouldShowPowerBar + GetPercent + GetColor +
-- widget writes) for nothing. This was the highest-frequency event in the
-- profile with its powerType argument discarded.
--
-- The displayed resource is the unit's ACTIVE power type, with one
-- exception the bar itself honors: a healer druid in a non-mana form
-- shows MANA (see GetEffectivePowerType). So:
--   * event token == active token  -> that IS the displayed bar; process.
--   * event token == "MANA"         -> always process, so a healer druid's
--     mana bar still refreshes while shifted (its active token is energy).
--   * anything else                 -> a secondary resource the bar never
--     shows; skip the whole fan-out.
-- The one over-process case -- a healer druid's own form energy ticking --
-- is a rare missed skip, never a wrong value (the update's force-mana
-- logic just re-writes the same mana value). An unknown/unreadable token
-- falls through to a full update, so the filter never hides a real change.
-- UnitPowerType is a cheap C getter; it gates a much heavier path.
--
-- Resto-druid-in-form (frozen mana) is safe: the "show mana while shifted"
-- behavior lives entirely in the display path (GetEffectivePowerType ->
-- Power:GetPercent, which returns nil for an inaccessible party value so
-- PowerBar:Update keeps the last value = the freeze). This filter only
-- gates WHETHER that path runs on a given UNIT_POWER_UPDATE. Mana ticks are
-- whitelisted above; form-shift arrives via UNIT_DISPLAYPOWER and max
-- changes via UNIT_MAXPOWER, both separate unconditional handlers this
-- filter never sees. For a shifted druid the active token IS energy, so
-- energy ticks still pass (== activeToken); the only events dropped are
-- non-active, non-mana secondaries (e.g. combo points) the mana bar never
-- shows -- exactly the intended skip.
function BF:UNIT_POWER_UPDATE(event, unit, powerType)
    if not S_POWER then return end
    if powerType then
        local _, activeToken = UnitPowerType(unit)
        if activeToken and powerType ~= activeToken and powerType ~= "MANA" then
            return
        end
    end
    S_POWER:UpdateIndicators(unit)
end

function BF:UNIT_MAXPOWER(event, unit, powerType)
    if S_POWER then S_POWER:UpdateIndicators(unit) end
end

function BF:UNIT_DISPLAYPOWER(event, unit)
    if S_POWER then S_POWER:UpdateIndicators(unit) end
end

-- Aura events
-- Grid2 architecture: each aura status owns its own UNIT_AURA handler.
-- There is no central BF:UNIT_AURA dispatcher. Each status (buffs, debuffs,
-- dispel, bigdef, important, crowdcontrol) registers UNIT_AURA independently
-- via RegisterRosterUnitEvent in its OnEnable. When UNIT_AURA fires,
-- the roster event system calls each status's handler directly.
-- Shared pre-processing (reachability) is handled by PreProcessUnitAura
-- in Statuses/Auras.lua, called at the top of each handler.

-- RAID_TARGET_UPDATE: now owned by raidicon status (BFStatus.lua)
-- PARTY_LEADER_CHANGED: now owned by leader status (BFStatus.lua)
-- UNIT_THREAT_SITUATION_UPDATE: now owned by threat status (BFStatus.lua)

-- Combat events - refresh debuff borders when combat state changes
-- This handles cases like exhaustion being hidden when entering combat
function BF:PLAYER_REGEN_DISABLED()
    self._inCombat = true
    -- v50 (12.1): swap combat-conditional aura filters (long-term
    -- debuff OOC display, raid-buff OOC group). pcall'd internally.
    -- v67: 12.0.7 branch removed (addon is 12.1-only).
    if self.ReapplyCombatConditionalAuraFilters then
        self:ReapplyCombatConditionalAuraFilters()
    end

    -- v72 (perf plan L1.6 D2): the lone `self._startupGuard = nil` write lived
    -- here. Nothing ever set the flag, so this cleared nothing and the read it
    -- paired with in BF:RefreshAll was dead. Both deleted together — see the
    -- note at the top of BF:RefreshAll (Core_Refresh.lua) for why the guard is
    -- not re-armed instead.

    -- Hide test frames so real frames are visible during combat.
    -- Crucially, do NOT clear the testMode flags — that way setup mode
    -- resumes automatically when PLAYER_REGEN_ENABLED fires.
    if self.testHeader then
        if self.testHeader.resizeHandle then self.testHeader.resizeHandle:Hide() end
        self.testHeader:Hide()
    end
    if self.partyTestHeader then
        if self.partyTestHeader.resizeHandle then self.partyTestHeader.resizeHandle:Hide() end
        self.partyTestHeader:Hide()
    end
    -- Hide the other setup frame categories so they don't linger during combat.
    -- Matches the Show* calls in ToggleSetupMode(true) lines 1325–1327.
    if self.HideUFTestFrames          then self:HideUFTestFrames()          end
    if self.HideCustomFrameTestFrames then self:HideCustomFrameTestFrames() end
    if self.HidePetTestFrames         then self:HidePetTestFrames()         end
    -- Hide the setup grid overlay too.
    if self._setupGrid then self._setupGrid:Hide() end

    -- Hide drag handles — moving is never allowed during combat lockdown.
    if self.anchorFrame and self.anchorFrame.handle then
        self.anchorFrame:EnableMouse(false)
        self.anchorFrame.handle:Hide()
    end
    if self.testAnchorFrame and self.testAnchorFrame.handle then
        self.testAnchorFrame:EnableMouse(false)
        self.testAnchorFrame.handle:Hide()
    end

    -- Hide custom frame group detached header handles during combat.
    -- Grid2 pattern: cancel any in-progress drag, then hide the handle.
    if self.groupsUsed then
        for _, header in ipairs(self.groupsUsed) do
            if header.isDetached and header._handle then
                if header.isMoving then
                    header:StopMovingOrSizing()
                    header.isMoving = nil
                    header:SetScript("OnUpdate", nil)
                end
                if header._handle:IsShown() then
                    header._handle:Hide()
                    header._handleWasShown = true
                end
            end
        end
    end

    -- Hide oUF unit frame drag handles during combat.
    -- Also stop any in-progress drag so frames don't get stuck mid-move.
    for _, key in ipairs({"oufPlayer", "oufTarget", "oufFocus", "oufTargetOfTarget", "oufFocusTarget", "oufPet", "oufResourceBar"}) do
        local f = self[key]
        if f then
            -- Stop any in-progress move on the frame or its anchor.
            if f.IsMovable and f:IsMovable() then
                f:StopMovingOrSizing()
            end
            if f._anchor and f._anchor.IsMovable and f._anchor:IsMovable() then
                f._anchor:StopMovingOrSizing()
            end
            if f._handle and f._handle:IsShown() then
                f._handle:Hide()
                f._handleWasShown = true
            end
        end
    end

    -- Refresh options panel so disabled buttons update immediately
    do
        BF:RefreshPanel("combat")
    end
    -- Grid2 does nothing else on PLAYER_REGEN_DISABLED.
    -- Raid buff filtering (ShouldFilterBuff checks InCombatLockdown) is
    -- re-evaluated automatically when UNIT_AURA fires at combat start.

    -- v92: the "combat-only injection refresh" that lived here — a full
    -- buffsAndContainers:Update + debuffIcons:Update on EVERY active frame,
    -- landing on the exact frame the pull starts — was legacy 12.0 machinery
    -- and is DELETED. Its own wiring proved it dead: it invalidated
    -- Buffs/Debuffs GetIcons caches that v67 turned into documented no-op
    -- stubs, and it existed to make Fetch*Data re-inject icons — a path v67
    -- removed entirely. On 12.1 the raid buff / long-term-debuff combat
    -- visibility is engine-owned: ReapplyCombatConditionalAuraFilters (called
    -- at the top of this handler) re-pushes the candidate filters and runs
    -- the UpdateAllAuras rebuilds, which is the whole edge. The indicator
    -- Updates this block forced only re-synced container shown/unit state —
    -- none of which changes at a combat edge.
end

-- ADDON_RESTRICTION_STATE_CHANGED: one restriction changed state. Only the
-- "nothing restricts aura creation any more" edge matters here: replay the
-- aura queues exactly as the regen handler does. Deferred one frame for the
-- same reason the drains are (the engine releases the per-button deny state
-- in its own update pass, after the event). The regen handler still runs on
-- combat exit; both replays are idempotent and change-guarded, so a pair of
-- edges costs one no-op walk.
-- Bounded retry: if ShouldAurasBeSecret() lags the event by more than a frame
-- when a key ends out of combat, no later event would arrive to try again.
local RESTRICTION_REPLAY_DELAYS = { 0, 0.5, 2 }
function BF:ADDON_RESTRICTION_STATE_CHANGED()
    if self:IsAuraCreationRestricted() then return end
    local step = 0
    local function replay()
        step = step + 1
        local delay = RESTRICTION_REPLAY_DELAYS[step]
        if not delay then return end
        C_Timer.After(delay, function()
            if BF:IsAuraCreationRestricted() then replay(); return end
            -- Lift edge: the replay below owns every edit still queued for a
            -- live rebuild; rebuilding after the key would only leak. Also
            -- prints the key summary. Runs before the flushes.
            if BF.ClearAuraRecreateQueue then BF:ClearAuraRecreateQueue() end
            if BF.DrainPendingTopUps then BF:DrainPendingTopUps() end
            if BF.FlushPendingAuraContainers then BF:FlushPendingAuraContainers() end
        end)
    end
    replay()
end

-- Grid2 parity (GridUtils.lua:288-310). PLAYER_REGEN_ENABLED runs the
-- single highest-priority RunSecure-queued call, then restores combat-
-- hidden UI handles that have no clean event source (they are paired with
-- explicit hides in PLAYER_REGEN_DISABLED). All formerly-flag-based work
-- (pendingGroupTypeChanged, _pendingVisibility, _pendingRolesUpdate,
-- pendingAnchorUpdate, _pendingOUFPlayerLayout, pendingSpacingUpdate,
-- _pendingFitResize) now self-defers via RunSecure at the writer site.
-- See Docs/PEW_GRID2_REFACTOR_PLAN.md §3.4, §3.5.
function BF:PLAYER_REGEN_ENABLED()
    -- v98: aura button top-ups refused during combat.
    if self.DrainPendingTopUps then self:DrainPendingTopUps() end
    -- Combat catch-up for the anchor-box fit: UpdateSize skips SetSize in
    -- combat, so roster changes during a fight leave a stale box (only
    -- visible in party Grow-from-Center mode). Change-guarded, so this is
    -- a no-op when nothing changed.
    self:RunThrottled(self, "UpdateSize", 0.01)
    self._inCombat = false
    -- v50 (12.1): swap combat-conditional aura filters back.
    -- v67: 12.0.7 branch removed (addon is 12.1-only).
    if self.ReapplyCombatConditionalAuraFilters then
        self:ReapplyCombatConditionalAuraFilters()
    end
    -- v53 PERF: containers for features that were switched on while
    -- restricted (in combat / secret-aura window) are created now — see
    -- BF:EnsureFeatureAuraContainer in Auras/ContainerFactory.lua.
    -- v67: 12.0.7 branch removed (addon is 12.1-only).
    if self.FlushPendingAuraContainers then
        self:FlushPendingAuraContainers()
    end
    -- Combat ended inside a keystone: the flush above refuses while auras are
    -- still restricted, so re-arm the live aura rebuild queue instead. No-op
    -- when nothing is queued.
    if self.KickAuraRecreate then self:KickAuraRecreate() end
    local p = self.db.profile

    -- Grid2 pattern: run the single highest-priority deferred call queued
    -- during combat via RunSecure. This may itself fan out (e.g. a
    -- _GroupTypeChangedExecute replay calls ApplyProfile → ReloadLayout →
    -- LoadLayout, whose tail invokes RefreshAllCustomContainersWithRebuild,
    -- UpdateGroupLabels, etc.).
    if self.RunSecure_OnRegenEnabled then
        self:RunSecure_OnRegenEnabled()
    end

    -- Register clicks on any frames that were created mid-combat
    -- (RegisterForClicks is protected and can't run in combat).
    -- KEEP — no RunSecure slot rebuilds this state. RegisterFrame fires
    -- from BuzzardHeader_InitialConfigFunction during secure-header child
    -- expansion which can happen any time the raid grows past the current
    -- child pool, including in combat. See PEW_GRID2_REFACTOR_PLAN §6.3.
    if self._framesCreatedInCombat then
        self._framesCreatedInCombat = nil
        local clickType = (p.clickOnMouseDown and "AnyDown") or "AnyUp"
        for _, frame in next, self.registeredFrames do
            frame:RegisterForClicks(clickType)
            if Clique then Clique:UpdateRegisteredClicks(frame) end
        end
    end

    -- ─ Restore combat-hidden UI handles ─────────────────────────────────
    -- These are paired with the explicit hide work in PLAYER_REGEN_DISABLED.
    -- The handle frames themselves are unprotected mover/handle frames, so
    -- the Show calls below are safe outside of any RunSecure gate.

    -- Setup mode UI restore (paired with PLAYER_REGEN_DISABLED hides).
    -- Deferred 0-tick so any RunSecure replay above has had a chance to
    -- rebuild the layout it's restoring on top of.
    if BF.db.global.setupModeActive then
        C_Timer.After(0, function()
            -- Re-show all setup frame categories that were hidden on combat
            -- enter. UpdateSetupFrames handles raid/party test headers and
            -- pet test frames; UF and custom frame test frames need explicit
            -- Show* calls (mirrors ToggleSetupMode(true) lines 1325–1327).
            if self.UpdateSetupFrames         then self:UpdateSetupFrames()         end
            if self.ShowUFTestFrames          then self:ShowUFTestFrames()          end
            if self.ShowCustomFrameTestFrames then self:ShowCustomFrameTestFrames() end
            if self.UpdateSetupGrid           then self:UpdateSetupGrid()           end
            if self.UpdateAnchorPosition      then self:UpdateAnchorPosition()      end
            -- testAnchorFrame.handle is explicitly kept hidden during setup
            -- mode (ToggleSetupMode line 1309). Defer handle visibility to
            -- RefreshHandleVisibility, which enforces the correct invariant:
            -- "if setup mode is active, hide all handles".
            if self.RefreshHandleVisibility   then self:RefreshHandleVisibility()   end
        end)
    else
        if self.anchorFrame and self.anchorFrame.handle then
            local locked = self.db.global.locked
            if locked == nil then locked = true end
            if not locked then
                self.anchorFrame:EnableMouse(true)
                self.anchorFrame.handle:Show()
            end
        end
    end

    -- Restore oUF unit frame drag handles that were hidden on combat enter.
    for _, key in ipairs({"oufPlayer", "oufTarget", "oufFocus", "oufTargetOfTarget", "oufFocusTarget", "oufPet", "oufResourceBar"}) do
        local f = self[key]
        if f and f._handle and f._handleWasShown then
            f._handle:Show()
            f._handleWasShown = nil
        end
    end

    -- Restore custom frame group detached header handles. Note (§6.4): if a
    -- RunSecure replay above rebuilt groupsUsed, the new headers are NEW
    -- objects whose _handleWasShown flag was never set — they stay hidden
    -- here. That's acceptable because out-of-combat handle visibility is
    -- ultimately driven by lock state via RefreshHandleVisibility, which
    -- LoadLayout's tail runs after rebuild.
    if self.groupsUsed then
        for _, header in ipairs(self.groupsUsed) do
            if header.isDetached and header._handle and header._handleWasShown then
                header._handle:Show()
                if header._handle.SnapToParent then header._handle.SnapToParent() end
                header._handleWasShown = nil
            end
        end
    end

    -- Refresh options panel (cheap, no frame work).
    BF:RefreshPanel("combat")

    -- v92: exit-edge "injection refresh" DELETED — same legacy 12.0 block as
    -- the PLAYER_REGEN_DISABLED one (see the note there). The raid buff /
    -- long-term-debuff reappearance is engine-owned on 12.1:
    -- ReapplyCombatConditionalAuraFilters at the top of this handler
    -- unparks the raid-buff group and re-pushes the OOC exclude sets, with
    -- the UpdateAllAuras rebuilds doing the rendering.
end

-- UNIT_NAME_UPDATE: name status owns the targeted refresh (paints
-- nameText + roleIcon). This addon-level handler additionally fans the
-- event out to every indicator on the frame via UpdateFramesOfUnit,
-- matching Grid2's GridRoster.lua:194-197 + GridFrame.lua:48-56 pattern.
-- This is what causes the health bar's class color to refresh at the
-- same instant the name arrives on roster join (the bar-color indicator
-- is bound to `classcolor`, which on its own only listens to
-- UNIT_PORTRAIT_UPDATE — a noticeably later event).
function BF:UNIT_NAME_UPDATE(_, unit)
    if self.roster_guids and self.roster_guids[unit] then
        -- Grid2 mirror (GridRoster.lua:194-197): refresh the cached
        -- roster_names entry (and the unknowns flag) BEFORE fanning out
        -- so the next sweep doesn't see this UNIT_NAME_UPDATE as a
        -- no-op vs. the pre-seeded value from RegisterRosterUnit.
        -- Fixes the player's own name not appearing on the party frame
        -- at solo fresh login, where roster_names["player"] was seeded
        -- with an empty/Unknown value during RegisterRosterUnit and
        -- the eventual real value matched none of the sweep's change
        -- conditions.
        if self._RosterUpdateUnit then self._RosterUpdateUnit(unit) end
        self:UpdateFramesOfUnit(unit)
    end
end

-- UNIT_PORTRAIT_UPDATE: now owned by role status (BFStatus.lua)

-- Absorb and heal prediction events — still dispatched through Initialization.lua
-- because they're per-unit events registered via the perUnitFrames system.
-- Grid2 pattern: each absorb-related event does a targeted call to only
-- the sub-method that needs updating. This avoids running all 3 sub-methods
-- (heal prediction, absorb overlay, heal absorb) on every absorb event.
function BF:UNIT_ABSORB_AMOUNT_CHANGED(event, unit)
    local absorbInd = self._absorbInd
    if not absorbInd then
        absorbInd = self:GetIndicatorByName("absorbBars")
        self._absorbInd = absorbInd
    end
    if absorbInd then
        local bucket = self.frames_of_unit and rawget(self.frames_of_unit, unit)
        if bucket then
            for f in pairs(bucket) do
                if f.unit == unit then
                    absorbInd:_UpdateAbsorbOverlay(f, unit)
                end
            end
        end
    end
end

function BF:UNIT_HEAL_ABSORB_AMOUNT_CHANGED(event, unit)
    local absorbInd = self._absorbInd
    if not absorbInd then
        absorbInd = self:GetIndicatorByName("absorbBars")
        self._absorbInd = absorbInd
    end
    if absorbInd then
        local bucket = self.frames_of_unit and rawget(self.frames_of_unit, unit)
        if bucket then
            for f in pairs(bucket) do
                if f.unit == unit then
                    absorbInd:_UpdateHealAbsorb(f, unit)
                end
            end
        end
    end
end

function BF:UNIT_HEAL_PREDICTION(event, unit)
    local absorbInd = self._absorbInd
    if not absorbInd then
        absorbInd = self:GetIndicatorByName("absorbBars")
        self._absorbInd = absorbInd
    end
    if absorbInd then
        local bucket = self.frames_of_unit and rawget(self.frames_of_unit, unit)
        if bucket then
            for f in pairs(bucket) do
                if f.unit == unit then
                    absorbInd:_UpdateHealPrediction(f, unit)
                end
            end
        end
    end
end

-- READY_CHECK / READY_CHECK_CONFIRM / READY_CHECK_FINISHED: now owned by readycheck status (BFStatus.lua)

-- INCOMING_RESURRECT_CHANGED: now owned by resurrect status (BFStatus.lua)
-- UNIT_PHASE: now owned by phased status (BFStatus.lua)

-- Static pet_of_unit and owner_of_unit maps matching Grid2's GridRoster.
-- pet_of_unit:   player=>pet, party1=>partypet1, raid1=>raidpet1, etc.
-- owner_of_unit: pet=>player, partypet1=>party1, raidpet1=>raid1, etc.
local pet_of_unit   = {}
local owner_of_unit = {}
local function register_unit(unit, pet)
    pet_of_unit[unit]   = pet
    owner_of_unit[pet]  = unit
end
register_unit("player", "pet")
for i = 1, MAX_PARTY_MEMBERS do register_unit("party"..i,  "partypet"..i)  end
for i = 1, MAX_RAID_MEMBERS  do register_unit("raid"..i,   "raidpet"..i)   end
for i = 1, 5                 do register_unit("arena"..i,  "arenapet"..i)  end
BF.pet_of_unit   = pet_of_unit
BF.owner_of_unit = owner_of_unit

-- Re-runs UpdateFrame on all frames currently showing a unit. Used by the
-- deferred vehicle timer, matching Grid2's RefreshFramesOfUnit.
local function RefreshFramesOfUnit(unit)
    local bucket = BF.frames_of_unit and rawget(BF.frames_of_unit, unit)
    if bucket then
        for frame in next, bucket do
            frame:UpdateIndicators()
        end
    end
end


function BF:UNIT_ENTERED_VEHICLE(event, unit)
    if unit then
        local bucket = self.frames_of_unit and rawget(self.frames_of_unit, unit)
        if bucket then
            local remapped = false
            for frame in next, bucket do
                local old, new = frame.unit, SecureButton_GetModifiedUnit(frame)
                if old ~= new then
                    remapped = true
                    self.SetFrameUnit(frame, new)
                    if UnitExists(new) and (event == nil or string.find(UnitGUID(new), "^Vehicle")) then
                        self.OnUnitChanged(frame, new)
                    else
                        C_Timer.After(1.5, function() RefreshFramesOfUnit(new) end)
                    end
                else
                    -- v68: multi-seat vehicles (UnitUsingVehicle true, no
                    -- vehicle bar) never remap the secure unit, so this
                    -- branch used to do NOTHING — the vehicle status flip
                    -- was invisible until some unrelated indicator update.
                    -- Refresh this frame's indicators now.
                    frame:UpdateIndicators()
                end
            end
            if not remapped then
                -- Second pass after the APIs settle: the vehicle APIs can
                -- LAG the UNIT_*_VEHICLE events by a beat (PTR-established
                -- in BuzzardAuras), so the immediate refresh above can read
                -- the OLD state on either edge. One timer per edge, cheap.
                C_Timer.After(0.6, function() RefreshFramesOfUnit(unit) end)
            end
        end
        self:UNIT_ENTERED_VEHICLE(nil, pet_of_unit[unit])
    end
end

BF.UNIT_EXITED_VEHICLE = BF.UNIT_ENTERED_VEHICLE

-- INCOMING_SUMMON_CHANGED: now owned by summon status (BFStatus.lua)
-- UNIT_CONNECTION / PARTY_MEMBER_ENABLE / PARTY_MEMBER_DISABLE:
--   now owned by offline status (Statuses/Offline.lua)

-- UNIT_FLAGS / PLAYER_FLAGS_CHANGED: now owned by flags status (BFStatus.lua)

-- ============================================================
-- PUBLIC FRAME ACCESSOR
-- Returns a flat list of all active unit frames.
-- ============================================================
function BuzzardFrames_GetAllFrames()
    local BF = _G["BuzzardFrames"]
    if not BF or not BF.activeFrames then
        return {}
    end

    local result = {}
    for frame in pairs(BF.activeFrames) do
        if frame.unit and frame.unit ~= "" then
            result[#result + 1] = frame
        end
    end
    return result
end

-- Perf plan §L5.1 load-time mark: 99 KB (.toc 114-151).
if BuzzardFrames then BuzzardFrames:LoadMark("chunk:initialization") end
