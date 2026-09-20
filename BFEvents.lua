-- ============================================================
-- BuzzardFrames: BFEvents.lua
-- Shared event subscription layer  (event refactor stage 0)
--
-- WHY THIS EXISTS
-- Before this file the addon had 27 hand-rolled event frames across 19
-- files, alongside the central AceEvent registrations in Initialization's
-- OnEnable. The same event was registered in up to nine places, and every
-- one of those sites re-derived the event's contract from scratch. That is
-- how PLAYER_SPECIALIZATION_CHANGED -- which carries a unit and fires once
-- per GROUP MEMBER -- came to be treated as player-only in three separate
-- files, each of them running whole-addon refresh work ~20 times on a raid
-- join. The central handler had the guard; the copies did not.
--
-- The sprawl was not laziness. CallbackHandler stores callbacks as
-- events[event][self] -- keyed by the REGISTERING OBJECT -- so AceEvent
-- already fans out to many listeners, but allows only ONE callback per
-- (object, event) pair. Every module registered on the single BF object, so
-- the second module to want an event had no choice but to build a frame.
-- Give each module its own owner object and the collision disappears.
--
-- WHAT THIS ADDS ON TOP: a declared unit scope. The scope is the thing that
-- was being re-derived and got wrong, so it is a required argument, it
-- lives in one place, and for the player case it is enforced by the engine
-- rather than by a Lua test somebody can forget to write.
--
-- TWO BACKENDS, deliberately
--   AceEvent  for unitless / roster / any-unit subscriptions. Multi-listener
--             fan-out for free, and OnUsed/OnUnused manage the underlying
--             engine registration.
--   A private frame + RegisterUnitEvent  for scope "player".
--             AceEvent has exactly one shared frame and only ever calls the
--             plain RegisterEvent on it (AceEvent-3.0.lua OnUsed), so it
--             CANNOT express a unit filter. Routing player-scoped unit events
--             through it would replace an engine-side filter with a Lua
--             string compare -- for UNIT_POWER_FREQUENT in a 25-man raid
--             that is a per-tick per-unit storm, strictly worse than the bug
--             this refactor exists to fix.
--
-- USAGE
--   local owner = BF:EventOwner("debuffIcons")
--   owner:Sub("PLAYER_TALENT_UPDATE", Handler, "unitless")
--   owner:Sub("PLAYER_SPECIALIZATION_CHANGED", Handler, "player")
--   owner:Sub("UNIT_FLAGS", Handler, "roster")
--   owner:SubOnce("PLAYER_LOGIN", BuildTheThing)
--   owner:Unsub("UNIT_FLAGS")
--   owner:UnsubAll()
--
-- Handlers are ALWAYS called as handler(owner, event, ...). The shape is
-- normalized here so no call site has to know that AceEvent's function-ref
-- style drops the object and shifts every argument left by one -- a handler
-- that got that wrong would silently compare an event name against "player"
-- and do nothing, which is the same silent-no-op failure as the original bug.
--
-- NOT COVERED BY THIS FILE, on purpose:
--   * BF:RegisterRosterUnitEvent (Initialization.lua) -- the per-roster-unit
--     RegisterUnitEvent frames. Already structurally immune to this bug
--     class and already multi-listener. Keep using it for per-unit work.
--   * oUF's own frame:RegisterEvent (Libs/oUF/events.lua) -- already unit
--     filtered, and it re-registers on unit swap. Do not route around it.
--   * The OnUpdate deferral frames. Not event frames.
-- ============================================================

local BF = _G["BuzzardFrames"]
-- Deliberately NOT the `if not BF then return end` guard the other early
-- files use. 22 owners are created from this API at load; a silent return
-- here would turn one missing prerequisite into 22 identical "attempt to
-- call method 'EventOwner' (a nil value)" errors from unrelated files. Fail
-- once, loudly, naming the cause.
if not BF then
    error("BFEvents.lua loaded before BuzzardFrames exists -- check the .toc:"
        .. " this file must come after Defaults.lua and Core.lua.", 0)
end

local AceEvent = LibStub("AceEvent-3.0")
local format, type, tostring = string.format, type, tostring

-- Events that carry a unit token as their first payload argument, and are
-- therefore legal for scope "player" / "roster". Deliberately an allowlist:
-- RegisterUnitEvent on an event with no unit payload silently never fires,
-- and a subscription that never fires is exactly the class of failure this
-- file exists to prevent. If you need one that is missing, add it here --
-- the error message says so.
local UNIT_EVENTS = {
    PLAYER_SPECIALIZATION_CHANGED = true,
    UNIT_AURA = true, UNIT_HEALTH = true, UNIT_MAXHEALTH = true,
    UNIT_POWER_UPDATE = true, UNIT_POWER_FREQUENT = true,
    UNIT_MAXPOWER = true, UNIT_DISPLAYPOWER = true,
    UNIT_ABSORB_AMOUNT_CHANGED = true, UNIT_HEAL_ABSORB_AMOUNT_CHANGED = true,
    UNIT_HEAL_PREDICTION = true,
    UNIT_FLAGS = true, UNIT_FACTION = true, UNIT_PHASE = true,
    UNIT_CONNECTION = true, UNIT_LEVEL = true, UNIT_NAME_UPDATE = true,
    UNIT_PORTRAIT_UPDATE = true, UNIT_CLASSIFICATION_CHANGED = true,
    UNIT_OTHER_PARTY_CHANGED = true, UNIT_THREAT_SITUATION_UPDATE = true,
    UNIT_ENTERED_VEHICLE = true, UNIT_EXITED_VEHICLE = true,
    UNIT_SPELLCAST_START = true, UNIT_SPELLCAST_STOP = true,
    UNIT_SPELLCAST_CHANNEL_START = true, UNIT_SPELLCAST_CHANNEL_STOP = true,
    UNIT_SPELLCAST_INTERRUPTED = true, UNIT_SPELLCAST_FAILED_QUIET = true,
    UNIT_IN_RANGE_UPDATE = true,
    NAME_PLATE_UNIT_ADDED = true, NAME_PLATE_UNIT_REMOVED = true,
    INCOMING_RESURRECT_CHANGED = true, INCOMING_SUMMON_CHANGED = true,
    READY_CHECK_CONFIRM = true,
}

local VALID_SCOPES = {
    unitless = true,   -- event carries no unit
    player   = true,   -- only the player's own unit; engine-filtered
    roster   = true,   -- only units in BF.roster_guids
    any      = true,   -- genuinely every unit; must be spelled out
}

-- Dispatch census. One boolean test when off. The join-trace harness reads
-- BF:EventOwnerStats() to attribute work per (owner, event) rather than
-- guessing from a stack.
BF.eventStatsOn = false
local stats = {}
BF._eventStats = stats

local function Count(ownerName, event)
    local o = stats[ownerName]
    if not o then o = {}; stats[ownerName] = o end
    o[event] = (o[event] or 0) + 1
end

-- ============================================================
-- OWNER
-- ============================================================
local ownerProto = {}
ownerProto.__index = ownerProto

-- Lazily built, and only for scope "player" subscriptions.
local function EnsureUnitFrame(self)
    local f = self._unitFrame
    if f then return f end
    f = CreateFrame("Frame")
    f._owner = self
    f:SetScript("OnEvent", function(frame, event, ...)
        local entry = frame._owner._playerSubs[event]
        if not entry then return end
        if BF.eventStatsOn then Count(frame._owner._name, event) end
        entry.handler(frame._owner, event, ...)
    end)
    self._unitFrame = f
    return f
end

--- Subscribe to an event.
-- @param event   Blizzard event name.
-- @param handler function(owner, event, ...) -- always this shape.
-- @param scope   "unitless" | "player" | "roster" | "any". Required.
function ownerProto:Sub(event, handler, scope)
    if type(event) ~= "string" then
        error("BF EventOwner:Sub - event must be a string", 2)
    end
    if type(handler) ~= "function" then
        error(format("BF EventOwner:Sub(%s) - handler must be a function", event), 2)
    end
    if not VALID_SCOPES[scope] then
        error(format("BF EventOwner:Sub(%s) - scope is required and must be one of"
            .. " unitless/player/roster/any (got %s). The scope is the whole point:"
            .. " it is what three separate files got wrong for"
            .. " PLAYER_SPECIALIZATION_CHANGED.", event, tostring(scope)), 2)
    end
    if (scope == "player" or scope == "roster" or scope == "any")
       and not UNIT_EVENTS[event] then
        error(format("BF EventOwner:Sub(%s) - scope %q implies the event carries a"
            .. " unit, but %s is not in BFEvents' UNIT_EVENTS allowlist. If it"
            .. " really does carry a unit, add it there; if it does not, use"
            .. " scope \"unitless\".", event, scope, event), 2)
    end
    if self._subs[event] then
        error(format("BF EventOwner(%s) - already subscribed to %s. AceEvent"
            .. " allows one callback per (object, event); use one handler that"
            .. " branches, or a second owner.", self._name, event), 2)
    end

    if scope == "player" then
        -- Engine-side filter. Cannot be forgotten, and costs nothing per
        -- foreign unit because the event is never delivered to us at all.
        self._playerSubs[event] = { handler = handler }
        EnsureUnitFrame(self):RegisterUnitEvent(event, "player")
        self._subs[event] = "player"
        return
    end

    local owner = self
    local wrapped
    if scope == "roster" then
        wrapped = function(ev, unit, ...)
            if not (unit and BF.roster_guids and BF.roster_guids[unit]) then return end
            if BF.eventStatsOn then Count(owner._name, ev) end
            return handler(owner, ev, unit, ...)
        end
    else
        wrapped = function(ev, ...)
            if BF.eventStatsOn then Count(owner._name, ev) end
            return handler(owner, ev, ...)
        end
    end
    self:RegisterEvent(event, wrapped)
    self._subs[event] = scope
end

--- Subscribe until the first fire, then unsubscribe automatically.
-- For the deferred-build listeners (PLAYER_LOGIN and friends), which under a
-- naive migration would call UnregisterAllEvents on whatever the first
-- argument happened to be.
function ownerProto:SubOnce(event, handler, scope)
    scope = scope or "unitless"
    local owner = self
    self:Sub(event, function(_, ev, ...)
        owner:Unsub(ev)
        return handler(owner, ev, ...)
    end, scope)
end

function ownerProto:Unsub(event)
    local scope = self._subs[event]
    if not scope then return end
    if scope == "player" then
        self._playerSubs[event] = nil
        if self._unitFrame then self._unitFrame:UnregisterEvent(event) end
    else
        self:UnregisterEvent(event)
    end
    self._subs[event] = nil
end

function ownerProto:UnsubAll()
    for event in pairs(self._subs) do
        if self._subs[event] == "player" then
            self._playerSubs[event] = nil
            if self._unitFrame then self._unitFrame:UnregisterEvent(event) end
        else
            self:UnregisterEvent(event)
        end
    end
    for k in pairs(self._subs) do self._subs[k] = nil end
end

function ownerProto:IsSubscribed(event)
    return self._subs[event] ~= nil
end

-- ============================================================
-- FACTORY
-- ============================================================
local owners = {}
BF._eventOwners = owners

function BF:EventOwner(name)
    if type(name) ~= "string" or name == "" then
        error("BF:EventOwner - a name is required (it labels the dispatch census)", 2)
    end
    if owners[name] then
        error(format("BF:EventOwner - '%s' already exists. Owners are one per"
            .. " module or per status instance; sharing one across features"
            .. " reintroduces the (object, event) collision this replaces.",
            name), 2)
    end
    local o = setmetatable({
        _name       = name,
        _subs       = {},   -- event -> scope
        _playerSubs = {},   -- event -> { handler }
    }, ownerProto)
    AceEvent:Embed(o)
    owners[name] = o
    return o
end

-- Census readout, sorted, for the join-trace harness and /bf.
function BF:EventOwnerStats()
    local rows = {}
    for ownerName, events in pairs(stats) do
        for event, n in pairs(events) do
            rows[#rows + 1] = { ownerName, event, n }
        end
    end
    table.sort(rows, function(a, b) return a[3] > b[3] end)
    return rows
end

function BF:ResetEventOwnerStats()
    for k in pairs(stats) do stats[k] = nil end
end
