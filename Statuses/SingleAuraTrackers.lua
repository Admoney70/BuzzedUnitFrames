-- ============================================================
-- BuzzardFrames: Statuses/SingleAuraTrackers.lua
-- Shared single-aura tracker framework.
--
-- Queries each tracker's spell ID directly via
-- C_UnitAuras.GetUnitAuraBySpellID. For BF's typical tracker count
-- (1-2: missing raid buff + missing symbiotic) the per-tracker targeted lookup
-- is cheaper than a 40-slot scan -- no Lua table allocation for the aura
-- list, and at most one small record allocation per tracker per UA.
--
-- A SingleAuraTracker maintains s.idx[unit] = auraInstanceID for any
-- unit currently carrying its tracked spell. Per UA per unit, the
-- framework iterates registered trackers and calls GetUnitAuraBySpellID
-- with the tracker's resolved spell ID. Each tracker step compares the
-- returned auraInstanceID against tracker.idx[unit]: any difference
-- (present→absent, absent→present, refreshed IID) writes the new value
-- and dispatches the bound indicator inline. Structural removal is the
-- present→absent case; no separate second pass needed.
--
-- Trackers do NOT extend BFStatus -- they have a different shape
-- (single bound indicator with custom data, not the multi-indicator
-- indicatorList pattern). The framework owns its own roster lifecycle
-- via BF_UnitLeft messages (Initialization.lua:199 sender).
--
-- Public surface:
--   BF.SingleAuraTracker         prototype (for :new)
--   BF.SingleAuraTrackers        ordered list of registered trackers
--   BF:SAT_ScanAndDispatch(unit) per-tracker scan + dispatch. Called
--                                from Buffs:UNIT_AURA.
--   BF.SAT_ScanSilent(unit)      scan-only (no dispatch). Used by the
--                                registration backfill.
--   BF.SAT_RefreshPersonalOnlyFlag() recompute the fast-path flag.
--
-- See Docs/MISSING_RAID_BUFF_REDESIGN_PLAN.md and
-- Docs/SAT_API_SWITCH_PLAN.md for the design.
-- ============================================================

local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

local next                  = next
local ipairs                = ipairs
local rawget                = rawget
local tinsert               = table.insert
local tremove               = table.remove
local twipe                 = table.wipe
local issecretvalue         = issecretvalue or function(v) return false end
local UnitClassBase         = UnitClassBase
local GetUnitAuraBySpellID  = C_UnitAuras and C_UnitAuras.GetUnitAuraBySpellID
local GetSpellTexture       = C_Spell and C_Spell.GetSpellTexture
local C_Timer_After         = C_Timer and C_Timer.After

-- ============================================================
-- MODULE STATE
-- ============================================================

-- Ordered list of registered trackers (registration order). ScanInto
-- iterates this list once per UA per unit; ordering does not affect
-- correctness, only deterministic dispatch order across trackers.
local Trackers = {}

-- Reentrancy guard. ScanAndDispatch sets this true on entry and false
-- on exit. tracker:Register() defers backfill via C_Timer.After(0, ...)
-- when this is true to avoid corrupting the in-progress event's
-- accounting.
local _insideScanDispatch = false

-- Queue for backfills that arrived during dispatch. Drained at the end
-- of ScanAndDispatch.
local _pendingBackfills = nil

-- Count of registered personalOnly trackers. When > 0, the framework owns
-- a dedicated UNIT_AURA("player") subscription so personalOnly trackers'
-- s.idx["player"] stays current even when the player has no "player"-token
-- unit frame in BF.roster_guids (e.g. player has only raid frames + no
-- oUF player frame). See the _playerEvents subscription below.
local _personalOnlyCount = 0

-- v86 (event refactor stage 4): was a private CreateFrame with
-- RegisterUnitEvent. Scope "player" reproduces that exactly -- BFEvents backs
-- player-scoped subscriptions with a real frame and RegisterUnitEvent
-- precisely so a filter like this is never downgraded to a Lua compare. The
-- old belt-and-braces `if unit ~= "player"` test is therefore redundant and
-- has gone with it.
local _playerEvents = BF:EventOwner("singleAuraTrackersPlayer")

local function OnPlayerAura()
    -- Run the same scan-and-dispatch the buff status would run, but with
    -- unit = "player" so personalOnly trackers get scanned. Indicator
    -- dispatch for non-"player" frames (raid/party slots showing the player)
    -- is handled by the buff status's own UNIT_AURA on those tokens.
    if BF.SAT_ScanAndDispatch then
        BF:SAT_ScanAndDispatch("player")
    end
end

local function SubscribePlayerEvents()
    -- Driven by _personalOnlyCount crossing 0, which can re-enter.
    -- v92 (owner ruling): SAT features are combat-inert -- never hold a
    -- UNIT_AURA subscription in combat. The regen handler below resubs on
    -- the exit edge (gated on _personalOnlyCount, same as the callers).
    if InCombatLockdown() then return end
    if _playerEvents:IsSubscribed("UNIT_AURA") then return end
    _playerEvents:Sub("UNIT_AURA", OnPlayerAura, "player")
end

local function UnsubscribePlayerEvents()
    _playerEvents:Unsub("UNIT_AURA")
end

-- Expose for external access (Phase 1 integration + debugging).
BF.SingleAuraTrackers = Trackers

-- ============================================================
-- SPELL-ID RESOLVERS
--
-- Each tracker has a tracker.resolveSpellID(self, unit) hook returning
-- the spell ID to look up for the given unit. AddSpellId sets a sensible
-- default based on input shape:
--   * number   -> constant returner (most trackers, includes Symbiotic)
--   * table    -> Evoker-style per-target-class lookup via
--                 BF.EVOKER_BUFF_BY_CLASS[UnitClassBase(unit)]. Works
--                 because the Evoker variant set is keyed by target's
--                 class; for any other future "lookup per target class"
--                 use case the same resolver applies (just point
--                 BF.<something>_BY_CLASS at the right table).
--
-- For custom resolution logic, callers can override tracker.resolveSpellID
-- after AddSpellId (see SetResolveSpellID setter).
-- ============================================================

local function MakeConstantResolver(spellID)
    return function() return spellID end
end

-- The Evoker resolver assumes BF.EVOKER_BUFF_BY_CLASS exists by the time
-- it's called. AddSpellId only installs this resolver when the input is
-- a table, which means the caller registered class-variant IDs --
-- BF.EVOKER_BUFF_BY_CLASS is the only such table in the codebase right
-- now. If a future tracker uses table-form spellIds for a different
-- reason, it can SetResolveSpellID to override.
local function EvokerResolver(_, unit)
    if not UnitClassBase then return nil end
    -- 12.1: UnitClassBase returns a secret for identity-secret units — a
    -- secret cannot be truth-tested or used as a table key, so resolve to
    -- no spell (tracker treats the buff as absent for that unit).
    local class = UnitClassBase(unit)
    if class == nil or issecretvalue(class) then return nil end
    local map = BF.EVOKER_BUFF_BY_CLASS
    return map and map[class]
end

-- ============================================================
-- TRACKER PROTOTYPE
-- ============================================================

local trackerProto = {}
trackerProto.__index = trackerProto

function trackerProto:new(name)
    local t = setmetatable({}, self)
    t.name           = name
    t.spellIds       = {}       -- set: { [spellId] = true } -- kept for unregister-time texture invalidation and debugging
    t.missingTexture = nil      -- resolved at register time
    t.indicator      = nil      -- single bound indicator (see :BindIndicator)
    t.personalOnly   = false    -- when true, scan/dispatch limited to player
    t.registered     = false

    -- Per-unit live state. s.idx[unit] = current auraInstanceID for the
    -- tracked spell on this unit. nil = aura absent (or unknown).
    -- Mirrors Grid2 s.idx[u].
    t.idx = {}

    -- Per-unit "could not resolve a spell ID for this unit" flag. Distinct
    -- from idx[unit] == nil, which means "resolved, and the aura is not
    -- there". The Evoker resolver returns nil when the unit's class can't
    -- be read (12.1 identity-secret units), and treating that as ABSENT
    -- made the missing-buff icon claim a buff was missing on a unit we
    -- simply knew nothing about. Unknown must never render as missing.
    t.unknown = {}

    -- Per-event dispatch flag. Set inside ScanInto's per-tracker step
    -- and reset at the end of the same iteration. Vestigial under the
    -- single-pass design (could be a local) but kept for the Grid2-style
    -- mental model: 1 = changed (dispatched), -1 = unchanged.
    t.seen = nil

    -- Default resolver returns nil. AddSpellId installs the real resolver.
    t.resolveSpellID = function() return nil end

    return t
end

-- Add a spell ID (or list of variant IDs) to the tracker. Determines the
-- spell-ID resolver based on input shape. Must be called BEFORE :Register.
function trackerProto:AddSpellId(id)
    if type(id) == "number" then
        self.spellIds[id] = true
        self.resolveSpellID = MakeConstantResolver(id)
    elseif type(id) == "table" then
        for sid in pairs(id) do
            if type(sid) == "number" then
                self.spellIds[sid] = true
            end
        end
        -- Table form implies per-target-class variants (Evoker pattern).
        self.resolveSpellID = EvokerResolver
    end
end

-- Override the spell-ID resolver. Use for trackers with custom resolution
-- needs (e.g. spec-dependent buff, conditional on unit role, etc.). The
-- resolver is called as resolveSpellID(tracker, unit) -- standard colon
-- semantics.
function trackerProto:SetResolveSpellID(fn)
    self.resolveSpellID = fn
end

-- Bind the indicator that this tracker drives. One indicator per tracker
-- (vs Grid2's multi-indicator pattern) -- trackers are single-purpose.
-- The indicator must implement :Update(frame, unit) and ideally :HideAll(frame)
-- for the unregister cleanup path.
function trackerProto:BindIndicator(indicator)
    self.indicator = indicator
end

-- Tracker is "present" on unit when s.idx[unit] is set.
function trackerProto:IsPresent(unit)
    return self.idx[unit] ~= nil
end

-- Convenience inverse for the missing-buff indicator semantics.
-- UNKNOWN is NOT absent: when the resolver couldn't produce a spell ID for
-- this unit we have no evidence either way, so the missing-buff icon must
-- stay hidden rather than assert a buff is missing.
function trackerProto:IsAbsent(unit)
    if self.unknown[unit] then return false end
    return self.idx[unit] == nil
end

-- Clear per-unit state. Called by the structural-removal pass in
-- ScanAndDispatch and by the BF_UnitLeft cleanup. Per-unit only --
-- does NOT iterate other units.
function trackerProto:Reset(unit)
    self.idx[unit] = nil
    self.unknown[unit] = nil
end

-- ============================================================
-- TEXTURE RESOLUTION (deferred registration)
-- ============================================================

-- Resolve the missing-buff texture. Picks an arbitrary spellId from the
-- tracker's set and queries C_Spell.GetSpellTexture. Returns the texture
-- path or nil if not yet resolvable (very early load).
local function ResolveTexture(tracker)
    if not GetSpellTexture then return nil end
    -- next() on a hash set returns one arbitrary key. For missing-buff
    -- trackers all spellIds in a set share the same icon family (e.g.
    -- Evoker Blessing of the Bronze variants all use the same icon), so
    -- any of them works.
    local representativeId = next(tracker.spellIds)
    if not representativeId then return nil end
    return GetSpellTexture(representativeId)
end

-- Forward decl: used inside Register / texture-retry path.
local DoRegisterNow

-- Spell-data retry frame. SPELLS_CHANGED fires when missing spell data
-- becomes available. Trackers whose first registration call returned a
-- nil texture queue here and retry on the event.
local _pendingTextureRetry = {}  -- set: { tracker -> true }

-- v86 (event refactor stage 4): was a private CreateFrame. SPELLS_CHANGED is
-- unitless. This is a re-armable pseudo-one-shot rather than a SubOnce: it
-- unsubscribes only once the retry queue actually drains, and DoRegisterNow
-- re-arms it whenever a texture is still unresolved. IsSubscribed replaces
-- the frame's IsEventRegistered, which CallbackHandler has no equivalent for.
local _textureRetryEvents = BF:EventOwner("singleAuraTrackersTextureRetry")

local function OnSpellsChanged()
    -- Snapshot and clear: a tracker that fails again re-enters via
    -- DoRegisterNow's own re-queue path.
    local snapshot = _pendingTextureRetry
    _pendingTextureRetry = {}
    for tracker in next, snapshot do
        DoRegisterNow(tracker)
    end
    if not next(_pendingTextureRetry) then
        _textureRetryEvents:Unsub("SPELLS_CHANGED")
    end
end

local function ArmTextureRetry()
    if _textureRetryEvents:IsSubscribed("SPELLS_CHANGED") then return end
    _textureRetryEvents:Sub("SPELLS_CHANGED", OnSpellsChanged, "unitless")
end

-- ============================================================
-- REGISTRATION
-- ============================================================

-- Internal: do the actual registration work. Called by :Register
-- directly when safe, or queued via C_Timer.After(0, ...) if called
-- during ScanAndDispatch (reentrancy guard).
DoRegisterNow = function(tracker)
    if tracker.registered then return end

    -- Resolve texture. If unavailable, queue for SPELLS_CHANGED retry
    -- and bail without registering. Plan §6.2 user decision: defer
    -- registration entirely, no fallback icon. Until the texture
    -- resolves, the tracker simply does not exist; no scan, no
    -- dispatch, indicator stays hidden.
    local tex = ResolveTexture(tracker)
    if not tex then
        _pendingTextureRetry[tracker] = true
        ArmTextureRetry()
        return
    end
    tracker.missingTexture = tex

    -- Add to the ordered tracker list.
    tinsert(Trackers, tracker)
    tracker.registered = true

    -- Recompute personal-only flag now that the tracker set has changed.
    if BF.SAT_RefreshPersonalOnlyFlag then BF.SAT_RefreshPersonalOnlyFlag() end

    -- If this is the first personalOnly tracker, subscribe to the
    -- dedicated "player"-unit UNIT_AURA event so personalOnly trackers'
    -- s.idx["player"] stays current regardless of whether the player has
    -- a "player"-token frame in BF.roster_guids.
    if tracker.personalOnly then
        _personalOnlyCount = _personalOnlyCount + 1
        if _personalOnlyCount == 1 then
            SubscribePlayerEvents()
        end
    end

    -- Backfill: scan every known roster unit so s.idx[unit] is correct
    -- immediately, not on each unit's next UA. Mirrors Grid2's
    -- UpdateAllAuras at StatusAurasTemp.lua:66-70.
    --
    -- For personalOnly trackers: only "player" matters as a scan source.
    -- The dedicated player-scoped UNIT_AURA subscription keeps it current
    -- going forward.
    local roster = BF.roster_guids
    local indicator = tracker.indicator
    local fou       = BF.frames_of_unit

    if tracker.personalOnly then
        BF.SAT_ScanSilent("player")
    elseif roster then
        for unit in next, roster do
            BF.SAT_ScanSilent(unit)
        end
    end

    -- Dispatch phase: render the freshly-backfilled state on visible frames.
    -- PersonalOnly trackers fan out via UnitIsUnit(unit, "player") so the
    -- player's raid7/party3 frame gets the update (not just frames bound
    -- to the literal "player" token).
    if indicator and fou then
        if tracker.personalOnly then
            if roster then
                for unit in next, roster do
                    if unit == "player" or UnitIsUnit(unit, "player") then
                        local bucket = rawget(fou, unit)
                        if bucket then
                            for frame in next, bucket do
                                if frame.unit == unit then
                                    indicator:Update(frame, unit)
                                end
                            end
                        end
                    end
                end
            end
        elseif roster then
            for unit in next, roster do
                local bucket = rawget(fou, unit)
                if bucket then
                    for frame in next, bucket do
                        if frame.unit == unit then
                            indicator:Update(frame, unit)
                        end
                    end
                end
            end
        end
    end
end

-- Public: register the tracker with the framework. Resolves the missing
-- texture (deferring if not yet available) and backfills s.idx[unit] for
-- all current roster units.
--
-- Reentrancy: if called from inside a UA scan dispatch (talent-change
-- message routed via the event system during raid combat), defers the
-- actual work to the post-dispatch drain.
function trackerProto:Register()
    if self.registered then return end
    if _insideScanDispatch then
        _pendingBackfills = _pendingBackfills or {}
        _pendingBackfills[#_pendingBackfills + 1] = self
        return
    end
    DoRegisterNow(self)
end

-- Public: unregister the tracker. Clears s.idx for every known unit,
-- removes from the Trackers list, and dispatches the bound indicator on
-- every frame so icons hide immediately (don't wait for next UA).
--
-- Safe in combat: the dispatch path calls indicator:Update which
-- ultimately reaches HideAll -- pure widget hide, no protected API.
function trackerProto:Unregister()
    if not self.registered then
        -- Might be sitting in the texture-retry queue; remove it there too.
        if _pendingTextureRetry[self] then
            _pendingTextureRetry[self] = nil
        end
        return
    end

    -- Drop from ordered list.
    for i = #Trackers, 1, -1 do
        if Trackers[i] == self then
            tremove(Trackers, i)
            break
        end
    end

    -- Clear per-unit state.
    twipe(self.idx)
    self.seen      = nil
    self.registered = false

    -- Decrement personalOnly counter and tear down the player-event
    -- subscription when the last personalOnly tracker unregisters.
    if self.personalOnly then
        _personalOnlyCount = _personalOnlyCount - 1
        if _personalOnlyCount <= 0 then
            _personalOnlyCount = 0
            UnsubscribePlayerEvents()
        end
    end

    if BF.SAT_RefreshPersonalOnlyFlag then BF.SAT_RefreshPersonalOnlyFlag() end

    -- Dispatch on bound indicator for every visible frame so the icon
    -- hides immediately. PersonalOnly trackers fan out via UnitIsUnit.
    local indicator = self.indicator
    local fou       = BF.frames_of_unit
    if indicator and fou then
        local roster = BF.roster_guids
        if roster then
            if self.personalOnly then
                for unit in next, roster do
                    if unit == "player" or UnitIsUnit(unit, "player") then
                        local bucket = rawget(fou, unit)
                        if bucket then
                            for frame in next, bucket do
                                if frame.unit == unit then
                                    indicator:Update(frame, unit)
                                end
                            end
                        end
                    end
                end
            else
                for unit in next, roster do
                    local bucket = rawget(fou, unit)
                    if bucket then
                        for frame in next, bucket do
                            if frame.unit == unit then
                                indicator:Update(frame, unit)
                            end
                        end
                    end
                end
            end
        end
    end
end

BF.SingleAuraTracker = trackerProto

-- ============================================================
-- SCAN LOOP
--
-- ScanInto(unit, dispatch) iterates each registered tracker, resolves
-- its spell ID for this unit, and calls GetUnitAuraBySpellID. Each
-- tracker step compares the result against tracker.idx[unit] and, on
-- change, writes the new value and dispatches the bound indicator
-- inline. No separate second pass; structural removal is just the
-- present→absent transition handled by the same compare.
--
-- Cost per tracker per UA per unit:
--   * 1 resolveSpellID call (constant return for non-Evoker, UnitClassBase
--     + table lookup for Evoker).
--   * 1 GetUnitAuraBySpellID C call.
--   * 1 small aura-record allocation IF the aura is present.
--   * 1 secret-value-safe IID comparison.
--
-- No 40-aura Lua table allocation. No reverse index lookup. For 1-2
-- trackers (BF's typical use) this is materially cheaper than
-- GetUnitAuras(40) used by Grid2's multi-aura statuses.
--
-- Inline-dispatch caveat: if multiple trackers transition in the same
-- scan (e.g. Druid with both missing-raid-buff and missing-symbiotic
-- trackers firing on the same player UA), the bound indicator's :Update
-- runs once per dispatching tracker. This is safe and cheap because
-- MissingRaidBuff:EnableDeferredUpdates makes :Update an idempotent
-- mark-dirty stub -- the real _DoUpdate fires once on the next OnUpdate
-- tick regardless of how many times mark-dirty was called. If a future
-- consumer of this framework binds a non-deferred indicator, that
-- contract changes.
-- ============================================================

-- Scratch list for personalOnly dispatch fan-out: the set of (frame, unit)
-- pairs whose unit token resolves to the player via UnitIsUnit. Computed
-- lazily on the first personalOnly tracker that needs it within a single
-- ScanInto call, then reused across any subsequent personalOnly trackers
-- in the same scan. Reset at the top of every ScanInto.
local _personalFanoutFrames = {}  -- list of frame
local _personalFanoutUnits  = {}  -- parallel list: same indices
local _personalFanoutCount  = 0
local _personalFanoutBuilt  = false

local function BuildPersonalFanout()
    _personalFanoutCount = 0
    _personalFanoutBuilt = true
    local fou = BF.frames_of_unit
    if not fou then return end
    local roster = BF.roster_guids
    if not roster then return end
    for rosterUnit in next, roster do
        if rosterUnit == "player" or UnitIsUnit(rosterUnit, "player") then
            local rbucket = rawget(fou, rosterUnit)
            if rbucket then
                for frame in next, rbucket do
                    if frame.unit == rosterUnit then
                        _personalFanoutCount = _personalFanoutCount + 1
                        _personalFanoutFrames[_personalFanoutCount] = frame
                        _personalFanoutUnits[_personalFanoutCount]  = rosterUnit
                    end
                end
            end
        end
    end
end

local function ScanInto(unit, dispatch)
    if not GetUnitAuraBySpellID then return end

    local fou    = BF.frames_of_unit
    local bucket = fou and rawget(fou, unit)
    local nTrk   = #Trackers

    -- Reset the personalOnly fan-out cache. It rebuilds lazily on first
    -- personalOnly dispatch within this scan; subsequent personalOnly
    -- dispatches in the same scan reuse it.
    _personalFanoutBuilt = false

    for i = 1, nTrk do
        local tracker = Trackers[i]

        -- Skip personalOnly trackers on non-player units.
        if (not tracker.personalOnly) or unit == "player" then
            local spellID = tracker:resolveSpellID(unit)
            local newIID  = nil
            -- nil spellID = we could not work out WHICH aura to look for on
            -- this unit (Evoker resolver on an unreadable class). That is
            -- UNKNOWN, not absent — see trackerProto.unknown.
            local newUnknown = (spellID == nil) or nil
            if spellID then
                local aura = GetUnitAuraBySpellID(unit, spellID)
                if aura then newIID = aura.auraInstanceID end
            end

            local prevIID     = tracker.idx[unit]
            local prevUnknown = tracker.unknown[unit]

            -- Secret-value safe compare: if EITHER side is secret, the
            -- `==` comparison would taint, so treat as changed (force-
            -- update). prevIID can be secret if a previous scan wrote a
            -- secret newIID; newIID can be secret if Blizzard returned
            -- a restricted aura. issecretvalue on nil returns false, so
            -- the nil branches below are safe.
            local changed
            if (newIID  and issecretvalue(newIID))
            or (prevIID and issecretvalue(prevIID)) then
                changed = true
            else
                -- An unknown<->known transition is a change even when the
                -- aura id itself stays nil both sides: the indicator has to
                -- re-render (unknown hides the icon, absent shows it).
                changed = (prevIID ~= newIID) or (prevUnknown ~= newUnknown)
            end

            if changed then
                tracker.idx[unit]     = newIID  -- may be nil (structural removal)
                tracker.unknown[unit] = newUnknown
                tracker.seen          = 1
            else
                tracker.seen          = -1
            end

            -- Dispatch this tracker if needed.
            if dispatch and tracker.seen == 1 and tracker.indicator then
                local indicator = tracker.indicator
                if tracker.personalOnly then
                    -- PersonalOnly fan-out: the scan ran with unit=="player",
                    -- but the player's frame may be bound to a raid/party
                    -- slot token (raid7, party3), not the literal "player".
                    -- Build the player-frame list lazily on first need within
                    -- this scan; reuse for any other personalOnly trackers
                    -- transitioning in the same scan.
                    if not _personalFanoutBuilt then
                        BuildPersonalFanout()
                    end
                    for j = 1, _personalFanoutCount do
                        indicator:Update(_personalFanoutFrames[j], _personalFanoutUnits[j])
                    end
                elseif bucket then
                    for frame in next, bucket do
                        if frame.unit == unit then
                            indicator:Update(frame, unit)
                        end
                    end
                end
            end

            -- Reset seen for next event.
            tracker.seen = nil
        end
    end
end

-- Public scan-and-dispatch entrypoint. Called from Buffs:UNIT_AURA. Runs
-- the per-tracker scan + dispatch under a reentrancy guard so trackers
-- can safely call :Register from inside an indicator's Update without
-- corrupting the in-progress event's accounting.
function BF:SAT_ScanAndDispatch(unit)
    if #Trackers == 0 then return end

    -- v92 (owner ruling): missing raid buff / missing symbiotic do not work
    -- in combat and must not RUN in combat. Both UNIT_AURA subscriptions are
    -- unregistered at the combat edges (Statuses/Auras.lua roster listener;
    -- SubscribePlayerEvents above); this gate is the belt for the remaining
    -- callers (BF_UnitUpdated mid-combat roster shuffles). SAT_RegenCatchUp
    -- rescans everything on the exit edge, so no state is lost.
    if InCombatLockdown() then return end

    -- Personal-only fast path: if every registered tracker is personalOnly
    -- and this unit is not the player, every tracker would skip the scan
    -- anyway. Bail early.
    if BF.SAT_OnlyPersonalTrackers and unit ~= "player" then
        return
    end

    _insideScanDispatch = true

    -- Guard the scan call so an error inside an indicator's Update
    -- doesn't leave _insideScanDispatch stuck true.
    local ok, err = pcall(ScanInto, unit, true)
    _insideScanDispatch = false

    -- Drain any deferred backfills queued during dispatch.
    if _pendingBackfills then
        local pending = _pendingBackfills
        _pendingBackfills = nil
        if C_Timer_After then
            C_Timer_After(0, function()
                for i = 1, #pending do
                    DoRegisterNow(pending[i])
                end
            end)
        else
            for i = 1, #pending do
                DoRegisterNow(pending[i])
            end
        end
    end

    if not ok then
        error(err)
    end
end

-- v92: regen-exit catch-up. One full pass so tracker state (and the
-- missing-buff indicators it drives) reflect everything that happened while
-- combat-silenced. Personal-only fast path: one player scan covers it.
function BF.SAT_RegenCatchUp()
    if #Trackers == 0 then return end
    if not BF.SAT_OnlyPersonalTrackers then
        local units = BF.roster_guids
        if units then
            for unit in next, units do
                BF:SAT_ScanAndDispatch(unit)
            end
        end
    end
    BF:SAT_ScanAndDispatch("player")
end

-- Public: scan WITHOUT the dispatch pass. Used by the registration backfill.
function BF.SAT_ScanSilent(unit)
    if #Trackers == 0 then return end
    ScanInto(unit, false)
end

-- Recompute and cache "are all registered trackers personalOnly?". The
-- ScanAndDispatch fast-path uses this to skip work entirely on non-player
-- units when only player-only trackers are registered. Called from
-- DoRegisterNow and trackerProto:Unregister; the flag only changes when
-- the tracker set changes, so per-event recompute is unnecessary.
function BF.SAT_RefreshPersonalOnlyFlag()
    if #Trackers == 0 then
        BF.SAT_OnlyPersonalTrackers = false
        return
    end
    for i = 1, #Trackers do
        if not Trackers[i].personalOnly then
            BF.SAT_OnlyPersonalTrackers = false
            return
        end
    end
    BF.SAT_OnlyPersonalTrackers = true
end

-- ============================================================
-- ROSTER LIFECYCLE
-- ============================================================

-- Subscribe to BF_UnitLeft once for the framework. When a unit token
-- leaves the roster (Initialization.lua:199 sender), clear its s.idx
-- entry from every tracker. Without this, a unit token reused for a
-- different player later would inherit stale s.idx data.
do
    local dispatcher = LibStub("AceEvent-3.0"):Embed({})
    -- v92 (owner ruling): combat edges. Enter: drop the player-scoped
    -- UNIT_AURA subscription (the roster one is dropped by the Buffs status,
    -- Statuses/Auras.lua). Exit: resub when personalOnly trackers exist
    -- (SubscribePlayerEvents no-ops in combat and when already subscribed),
    -- then run the full catch-up rescan.
    dispatcher:RegisterEvent("PLAYER_REGEN_DISABLED", function()
        UnsubscribePlayerEvents()
    end)
    dispatcher:RegisterEvent("PLAYER_REGEN_ENABLED", function()
        if _personalOnlyCount > 0 then
            SubscribePlayerEvents()
        end
        if BF.SAT_RegenCatchUp then BF.SAT_RegenCatchUp() end
    end)
    dispatcher:RegisterMessage("BF_UnitLeft", function(_, unit)
        if not unit then return end
        for i = 1, #Trackers do
            local tracker = Trackers[i]
            if tracker.idx[unit] ~= nil then
                tracker.idx[unit] = nil
            end
            -- Clear the unknown flag too, or a slot that later hosts a
            -- different player would inherit a stale "unknown".
            tracker.unknown[unit] = nil
        end
    end)

    -- Rescan when a unit joins the roster or is reassigned (Grid2 mirror:
    -- StatusAurasTemp.lua:72-75, which re-runs the aura scan for the unit
    -- on every Grid_UnitUpdated). Without this, s.idx[unit] for any unit
    -- that joined AFTER tracker registration stays nil ("missing") until
    -- the unit's first UNIT_AURA — which solo/idle can be a long time away.
    -- This was the cause of the post-/reload false "missing raid buff"
    -- icon: the trackers register at OnEnable when roster_guids is still
    -- empty (the registration backfill scans nothing), units join at PEW,
    -- and any full UpdateIndicators pass between then and the unit's first
    -- UA painted the never-scanned state. ScanAndDispatch fast-bails when
    -- no trackers are registered and dispatches the indicator only when
    -- the per-unit state actually changed, so the steady-state cost of
    -- this handler is one #Trackers == 0 check per unit (re)assignment.
    dispatcher:RegisterMessage("BF_UnitUpdated", function(_, unit)
        if not unit then return end
        if BF.SAT_ScanAndDispatch then
            BF:SAT_ScanAndDispatch(unit)
        end
    end)
end

-- ============================================================
-- INITIAL STATE
-- ============================================================

BF.SAT_OnlyPersonalTrackers = false
