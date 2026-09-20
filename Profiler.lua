-- ============================================================
-- BuzzardFrames: Profiler.lua
-- Lightweight profiling for hot-path functions.
--
-- Usage:
--   /bf prof start    — begin profiling (resets all counters)
--   /bf prof stop     — stop profiling
--   /bf prof report   — open a copyable window with results sorted by total time
--   /bf prof peaks    — dump each addon's worst single frame since login (catches login/loading stalls)
--   /bf prof reset    — reset counters without stopping
--
-- v96: start OUT of combat. The script-wrap layer needs SetScript on the
-- protected unit frames, which combat lockdown refuses.
--
-- The profiler wraps BF methods with timing code using
-- GetTimePreciseSec. NOT debugprofilestart/debugprofilestop: that
-- pair is one GLOBAL timer, so a wrapped function calling another
-- wrapped function had its clock reset mid-measurement and every
-- nesting row silently undercounted (the tell was a parent row
-- totalling less than a child only it calls). GetTimePreciseSec
-- holds each invocation's start in a local, so nested wraps are
-- genuinely inclusive: a parent row CONTAINS its wrapped children —
-- don't sum related rows.
-- Only wraps functions while profiling is active to avoid any
-- overhead when off.
-- ============================================================

local BF = _G["BuzzardFrames"]
if not BF then return end

local GetTimePreciseSec = GetTimePreciseSec
local format = string.format
local sort   = table.sort
local pairs  = pairs

-- Storage: funcName -> { calls=N, totalMs=N, maxMs=N }
local stats = {}
local profiling = false

-- Original (unwrapped) function references, keyed by name
local originals = {}

-- Functions to profile: { displayName, objectOrTable, methodKey }
-- These are resolved at wrap time so we get the current function ref.
local function GetProfilTargets()
    return {
        -- ── Per-status UNIT_AURA handlers ──────────────────────────────────
        { "Buffs:UNIT_AURA",                BF.statuses and BF.statuses.buffs, "UNIT_AURA" },
        { "BigDef:UNIT_AURA",               BF.statuses and BF.statuses.bigdef, "UNIT_AURA" },
        { "Debuffs:UNIT_AURA",              BF.statuses and BF.statuses.debuffs, "UNIT_AURA" },
        { "Dispel:UNIT_AURA",               BF.statuses and BF.statuses.dispel, "UNIT_AURA" },

        -- v67: the four status GetIcons wraps and the BF:FetchBuffData wrap
        -- were removed (12.1-only). All four status GetIcons methods
        -- and BF:FetchBuffData are deleted — the 12.1 render path is
        -- BF:SyncAuraGridContainer, not a per-unit Lua aura scan.

        -- ── Single-aura tracker framework (Statuses/SingleAuraTrackers.lua) ─
        -- SAT_ScanAndDispatch is the shared HELPFUL scan called from
        -- Buffs:UNIT_AURA (every UA per unit) AND from the framework's
        -- own UNIT_AURA("player") subscription. Walks the registered
        -- tracker set, writes s.idx, dispatches indicators.
        { "SAT_ScanAndDispatch",             BF, "SAT_ScanAndDispatch" },

        -- Display (full-refresh path)
        { "UpdateStandardAuras",             BF, "UpdateStandardAuras" },

        -- v67: the BuffMatch:UpdateCache wrap was removed (12.1-only) —
        -- the method is deleted from Statuses/Auras.lua.

        -- Aura indicators (called from per-status UpdateIndicators)
        { "BigDefIcons:Update",              BF.indicators and BF.indicators.bigDefIcons, "Update" },
        { "BuffsAndContainers:Update",       BF.indicators and BF.indicators.buffsAndContainers, "Update" },
        { "MissingRaidBuff:Update",          BF.indicators and BF.indicators.missingRaidBuff, "Update" },
        { "DebuffIcons:Update",              BF.indicators and BF.indicators.debuffIcons, "Update" },
        { "DispelDebuffBorder:Update",       BF.indicators and BF.indicators.dispelDebuffBorder, "Update" },
        -- v67: BuffHighlight:Update wrap removed — Indicators/BuffHighlight.lua
        -- was deleted (12.1-only; its BuffMatch getters no longer exist).

        -- Per-indicator Create methods (Phase 1 refactor: each aura indicator
        -- builds its own icon pool at frame init). Low-frequency — fires
        -- once per frame at raid spawn / /reload. Use these to attribute
        -- frame-creation lag on raid spawn.
        { "BuffsAndContainers:Create",       BF.indicators and BF.indicators.buffsAndContainers, "Create" },
        { "DebuffIcons:Create",              BF.indicators and BF.indicators.debuffIcons, "Create" },
        { "BigDefIcons:Create",              BF.indicators and BF.indicators.bigDefIcons, "Create" },
        { "MissingRaidBuff:Create",          BF.indicators and BF.indicators.missingRaidBuff, "Create" },

        -- v67: the four per-indicator UpdateFrameSettings wraps and the
        -- BF:DispatchTooltipSettings wrap were removed (12.1-only). Container
        -- buttons bake their tooltip bindings at creation, so all four
        -- indicator methods were empty no-ops and the dispatcher was deleted.

        -- ── Phase 2: per-indicator cache rebuild dispatch ──────────────────
        -- UpdateAuraSizeCache now shrinks to a dispatch helper that calls
        -- IterateAuraCacheScopes + RebuildAuraCacheScope per scope.
        -- Each scope rebuild runs:
        --   1. Per-indicator UpdateDB pass (10 indicators × N scopes)
        --   2. UpdateAuraTextSettings (cross-coupled font/border/color/curve)
        --   3. UpdateCrossSectionCache (cross-section gates + derived fields)
        --   4-7. Offset stamps, cfgBorderColor, _cacheGen bump
        { "UpdateAuraSizeCache",             BF, "UpdateAuraSizeCache" },
        { "UpdateAuraTextSettings",          BF, "UpdateAuraTextSettings" },
        { "UpdateCrossSectionCache",         BF, "UpdateCrossSectionCache" },

        -- Per-indicator UpdateDB methods (Phase 2 cache writes). Fire once
        -- per cache scope per UpdateAuraSizeCache call (typically 1 global
        -- + N CFG flats + M per-layout flats).
        { "BuffsAndContainers:UpdateDB",     BF.indicators and BF.indicators.buffsAndContainers, "UpdateDB" },
        { "DebuffIcons:UpdateDB",            BF.indicators and BF.indicators.debuffIcons, "UpdateDB" },
        { "BigDefIcons:UpdateDB",            BF.indicators and BF.indicators.bigDefIcons, "UpdateDB" },
        { "MissingRaidBuff:UpdateDB",        BF.indicators and BF.indicators.missingRaidBuff, "UpdateDB" },
        { "DispelDebuffIndicator:UpdateDB",  BF.indicators and BF.indicators.dispelDebuffIndicator, "UpdateDB" },
        { "DispelDebuffBorder:UpdateDB",     BF.indicators and BF.indicators.dispelDebuffBorder, "UpdateDB" },
        { "DispelDebuffOverlay:UpdateDB",    BF.indicators and BF.indicators.dispelDebuffOverlay, "UpdateDB" },

        -- Per-status UpdateIndicators (the new hot path)
        { "Buffs:UpdateIndicators",          BF.statuses and BF.statuses.buffs, "UpdateIndicators" },
        { "Debuffs:UpdateIndicators",        BF.statuses and BF.statuses.debuffs, "UpdateIndicators" },
        { "BigDef:UpdateIndicators",         BF.statuses and BF.statuses.bigdef, "UpdateIndicators" },
        { "Dispel:UpdateIndicators",         BF.statuses and BF.statuses.dispel, "UpdateIndicators" },

        -- Health/Power (high-frequency per-unit events)
        -- v93: renamed from "UNIT_HEALTH" to "BF:UNIT_HEALTH". It is ONE of
        -- three listeners on that event, not the event -- see the block below.
        { "BF:UNIT_HEALTH",                  BF, "UNIT_HEALTH" },
        { "UNIT_MAXHEALTH",                  BF, "UNIT_MAXHEALTH" },
        { "UNIT_POWER_UPDATE",               BF, "UNIT_POWER_UPDATE" },

        -- v93 3.0: the OTHER TWO UNIT_HEALTH listeners ---------------------
        -- PerUnitOnEvent (Initialization.lua:121) fans one UNIT_HEALTH out to
        -- every registered listener. THREE register for it; before v93 only
        -- the first was wrapped, so the report understated the event's true
        -- cost by roughly 2x and every ranked action below it was being
        -- decided on incomplete data.
        --
        --   1. Health:OnEnable          -> BF:UNIT_HEALTH        BFStatus.lua:440
        --   2. ShieldsOverflow:OnEnable -> :UpdateIndicators     BFStatus.lua:831
        --   3. Death:OnEnable           -> Death:UNIT_HEALTH     BFStatus.lua:1343
        --
        -- Nesting is inclusive (file header): ShieldsOverflow:UpdateIndicators
        -- CONTAINS AbsorbBarsHealthClamp:Update, which CONTAINS
        -- AbsorbBars:_UpdateAbsorbOverlayHealth. The two inner rows are here to
        -- show how much of the status dispatch is the absorb recompute versus
        -- the fan-out itself -- do NOT add them to the event total.
        --
        -- A MISSING ShieldsOverflow row is itself a result, not a gap: the
        -- status registers UNIT_HEALTH only when showAbsorbsMissingHealth is on
        -- in some flat (BF:RebindAbsorbStatuses), so no row means the cost is
        -- genuinely not being paid in the profiled configuration.
        { "ShieldsOverflow:UpdateIndicators",      BF.statuses   and BF.statuses.shieldsOverflow,        "UpdateIndicators" },
        { "AbsorbBarsHealthClamp:Update",          BF.indicators and BF.indicators.absorbBarsHealthClamp, "Update" },
        { "AbsorbBars:_UpdateAbsorbOverlayHealth", BF.indicators and BF.indicators.absorbBars,            "_UpdateAbsorbOverlayHealth" },

        -- Death:UNIT_HEALTH is ALSO the UNIT_FLAGS handler -- BFStatus.lua:1360
        -- routes UNIT_FLAGS through the same function deliberately. One row
        -- would blend two events with unrelated frequencies, so the 4th field
        -- turns on the per-event split: the report shows
        -- "Death:UNIT_HEALTH [UNIT_HEALTH]" and "[UNIT_FLAGS]" as separate
        -- rows. Only the [UNIT_HEALTH] row belongs in the UNIT_HEALTH total.
        { "Death:UNIT_HEALTH",               BF.statuses and BF.statuses.death, "UNIT_HEALTH", true },

        -- ── Absorb events ──────────────────────────────────────────────────
        { "UNIT_ABSORB_AMOUNT_CHANGED",      BF, "UNIT_ABSORB_AMOUNT_CHANGED" },
        { "UNIT_HEAL_ABSORB_AMOUNT_CHANGED", BF, "UNIT_HEAL_ABSORB_AMOUNT_CHANGED" },
        { "UNIT_HEAL_PREDICTION",            BF, "UNIT_HEAL_PREDICTION" },

        -- v93 3.2: UnitGetDetailedHealPrediction call-site baseline ---------
        -- These three workers plus _UpdateAbsorbOverlayHealth above are every
        -- site in the addon that issues a prediction fill. The three absorb
        -- events dispatch ONE worker each, directly (Initialization.lua:1988,
        -- :2006, :2024) -- not through AbsorbBars:Update, which runs all three
        -- but only on full indicator sweeps. So there is no four-way pile-up.
        --
        -- The one real duplicate is _UpdateAbsorbOverlayHealth (UNIT_HEALTH)
        -- against _UpdateAbsorbOverlay (UNIT_ABSORB): the latter is a strict
        -- superset of the former, so when both events land on one unit in one
        -- engine frame the whole body runs twice. Ranked action 2 collapses
        -- that pair; these rows are the before-picture.
        --
        -- The calculators are NOT interchangeable -- AbsorbCalc clamps at 1,
        -- OvershieldCalc at 2, HealthCalc at 1 with a per-frame incoming-heal
        -- mode (LayoutFrame.lua:216-223) -- so the floor is one fill per
        -- (calculator, unit), never one fill per unit.
        --
        -- Each row is nested INSIDE its event row above -- inclusive, don't sum.
        { "AbsorbBars:_UpdateAbsorbOverlay",  BF.indicators and BF.indicators.absorbBars, "_UpdateAbsorbOverlay" },
        { "AbsorbBars:_UpdateHealPrediction", BF.indicators and BF.indicators.absorbBars, "_UpdateHealPrediction" },
        { "AbsorbBars:_UpdateHealAbsorb",     BF.indicators and BF.indicators.absorbBars, "_UpdateHealAbsorb" },

        -- v93 3.5: power + health-tick widget-write baseline ----------------
        -- Power:UpdateIndicators is the fan-out under BF:UNIT_POWER_UPDATE
        -- (25206 calls / 285 s in the v92 session, with powerType discarded --
        -- ranked action 3). ShouldShowPowerBar is the uncached eligibility
        -- probe re-run per power tick per frame inside PowerBar:Update, routing
        -- through GetSectionProfileForFrame rather than GetCachedSection
        -- (ranked action 4). HealthBar/HealthText:Update carry the
        -- unconditional SetMinMaxValues / SetTextColor writes and the
        -- deficit-string allocations (ranked actions 5 and 7).
        --
        -- CAVEAT on ShouldShowPowerBar: the wrapper itself costs ~0.3 us per
        -- call, a meaningful share of a function this small. Read its CALL
        -- COUNT as the signal (how often the uncached probe runs), not its avg
        -- ms -- and expect the total to fall by more than the wrapper overhead
        -- once the result is cached on the frame.
        { "Power:UpdateIndicators",          BF.statuses   and BF.statuses.power,        "UpdateIndicators" },
        { "PowerBar:Update",                 BF.indicators and BF.indicators.powerBar,   "Update" },
        { "ShouldShowPowerBar",              BF, "ShouldShowPowerBar" },
        { "HealthBar:Update",                BF.indicators and BF.indicators.healthBar,  "Update" },
        { "HealthText:Update",               BF.indicators and BF.indicators.healthText, "Update" },

        -- ── Range timer (fires every 1s) ───────────────────────────────────
        { "UpdateAllRanges",                 BF, "UpdateAllRanges" },
        -- v96: the 1s external-roster range tick itself (Range.lua ticker
        -- resolves BF.RangeTick per fire so this wrap is seen).
        { "RangeTick",                       BF, "RangeTick" },

        -- ── Ping mirror (PingMirror.lua) ───────────────────────────────────
        -- Tick: the 0.2s IsShown() poll over the pre-resolved receiver list
        -- (only attached while the list is non-empty). Resolve: the
        -- roster-change rebuild of that list. PingIndicator:Update is the
        -- raid-frame indicator's per-unit toggle/GUID check.
        { "PingMirror:Tick",                 BF.pingMirror, "Tick" },
        { "PingMirror:Resolve",              BF.pingMirror, "Resolve" },
        { "PingIndicator:Update",            BF.indicators and BF.indicators.pingIndicator, "Update" },

        -- ── Custom containers / default buffs (unified) ───────────────────
        { "RenderAuraGroup",                 BF, "RenderAuraGroup" },

        -- ── Poll tickers (fire on fixed intervals, not per-event) ─────────
        -- v67: the Bounce and DurationMap poll wraps were removed (12.1-only).
        -- BF._BouncePollOnTick / _BounceDriverOnUpdate / _DurationMapPollOnTick
        -- have no definition anywhere in the addon any more; only
        -- _ThresholdPollOnTick (Auras/AuraConfig.lua:943) survives.
        { "ThresholdPollOnTick",              BF, "_ThresholdPollOnTick" },

        -- Indicator system ───────────────────────────────────────────────
        { "UpdateIndicators (frame method)", nil, nil },  -- special case, handled below

        -- ── IncomingCasts module ────────────────────────────────────────────
        -- Event-handler entry points. OnSpellcastStart/ChannelStart only
        -- schedule a C_Timer closure, so their rows measure SCHEDULING
        -- overhead -- the deferred work lands in IC:ProcessCast below.
        { "IC:OnSpellcastStart",       BF.IncomingCasts, "OnSpellcastStart" },
        { "IC:OnSpellcastChannelStart",BF.IncomingCasts, "OnSpellcastChannelStart" },
        { "IC:OnSpellcastEnd",         BF.IncomingCasts, "OnSpellcastEnd" },
        { "IC:OnNameplateAdded",       BF.IncomingCasts, "OnNameplateAdded" },
        { "IC:OnNameplateRemoved",     BF.IncomingCasts, "OnNameplateRemoved" },

        -- Real IC hot path. These were file-locals; they are IC-dot
        -- functions now (all call sites go through IC.) precisely so these
        -- wraps intercept. Nesting is inclusive, same as the status wraps:
        -- ProcessCast > ReleaseCastsForUnit + styling passes, and
        -- RepositionPlayerCasts > PositionOnFrame -- don't sum the rows.
        { "IC:ProcessCast",            BF.IncomingCasts, "ProcessCast" },
        { "IC:ReleaseCastsForUnit",    BF.IncomingCasts, "ReleaseCastsForUnit" },
        { "IC:RepositionPlayerCasts",  BF.IncomingCasts, "RepositionPlayerCasts" },
        { "IC:PositionOnFrame",        BF.IncomingCasts, "PositionOnFrame" },

        -- Styling passes (already IC methods).
        { "IC:ApplyCastBarStyle",      BF.IncomingCasts, "ApplyCastBarStyle" },
        { "IC:ApplyCastBarPerCastState", BF.IncomingCasts, "ApplyCastBarPerCastState" },
        { "IC:RestampCastBarLevel",    BF.IncomingCasts, "RestampCastBarLevel" },

        -- ── oUF unit frame helpers (called from PostUpdate callbacks) ──────
        -- _UpdateOUFIcon is the coalesced RENDER (one per dirty frame per
        -- tick); _QueueOUFIconUpdate is the per-event mark-dirty shell.
        -- Queue calls >> render calls means the coalescing is working.
        { "_UpdateOUFIcon",            BF, "_UpdateOUFIcon" },
        { "_QueueOUFIconUpdate",       BF, "_QueueOUFIconUpdate" },
        { "_GetOUFHealthColor",        BF, "_GetOUFHealthColor" },
        { "_GetOUFPowerColor",         BF, "_GetOUFPowerColor" },

        -- ── oUF PostUpdate callbacks ───────────────────────────────────────
        -- Special case: wrapped per-frame like UpdateIndicators, see below.
        -- v95: the inclusive "oUF:Health.PostUpdate" row is broken down by five
        -- EXCLUSIVE "oUF:H.PU [...]" segment rows emitted inline from the
        -- callback (UnitFrames/oUF_Shared.lua Health.PostUpdate via BF:_ProfSeg).
        -- [text]/[dead]/[bggrad] = per-tick (every UNIT_HEALTH); [color]/[unitchg]
        -- = per-unit-swap (their call counts track swaps, not ticks). Those five
        -- DO sum to ~this row; the shortfall is the callback's own setup.
        { "oUF:Health.PostUpdate",     nil, nil },
        { "oUF:Power.PostUpdate",      nil, nil },

        -- ── Roster update hot path ──────────────────────────────────────────
        -- Everything that runs synchronously or next-tick on GROUP_ROSTER_UPDATE.
        -- Use these to attribute lag when a player joins/leaves the group.
        { "GROUP_ROSTER_UPDATE",             BF, "GROUP_ROSTER_UPDATE" },
        { "GroupChanged",                    BF, "GroupChanged" },
        { "GroupTypeChanged",                BF, "GroupTypeChanged" },
        { "_GroupTypeChangedExecute",        BF, "_GroupTypeChangedExecute" },
        { "ApplyProfile",                    BF, "ApplyProfile" },
        { "QueueRosterUpdate",               BF, "QueueRosterUpdate" },
        { "QueueGroupChanged",               BF, "QueueGroupChanged" },
        { "UpdateVisibility",                BF, "UpdateVisibility" },
        { "AnnounceRaidSizeChange",          BF, "AnnounceRaidSizeChange" },
        { "InvalidateRaidProfileCache",      BF, "InvalidateRaidProfileCache" },
        { "OnUnitChanged",                   BF, "OnUnitChanged" },
        { "UpdateFrameIndicators",           BF, "UpdateFrameIndicators" },
        { "UpdateFramesOfUnit",              BF, "UpdateFramesOfUnit" },
        { "SetFrameUnit",                    BF, "SetFrameUnit" },
        { "RefreshAllCustomContainersWithRebuild", BF, "RefreshAllCustomContainersWithRebuild" },

        -- Dispel is the only aura status with a real ClearAllCaches (the
        -- others were deleted as no-op stubs). Called from GROUP_ROSTER_UPDATE.
        { "Dispel:ClearAllCaches",           BF.statuses and BF.statuses.dispel, "ClearAllCaches" },

        -- ── v92 perf batch: touched hot paths ──────────────────────────────
        -- Regen edges. PLAYER_REGEN_DISABLED is the pull edge (container
        -- suspension, UNIT_AURA unsubscribe); PLAYER_REGEN_ENABLED is the
        -- catch-up edge (resubscribe, SAT_RegenCatchUp, deferred refreshes).
        { "PLAYER_REGEN_DISABLED",           BF, "PLAYER_REGEN_DISABLED" },
        { "PLAYER_REGEN_ENABLED",            BF, "PLAYER_REGEN_ENABLED" },
        { "SAT_RegenCatchUp",                BF, "SAT_RegenCatchUp" },

        -- Aggro highlight (v92: _bfThreatKey change guard — expect high call
        -- counts with near-zero avg when threat state is stable).
        { "AggroHighlight:Update",           BF.indicators and BF.indicators.aggroHighlight, "Update" },

        -- Indicator Layout passes (the OOC settings/roster sweep). These are
        -- where GetContainerBuffConfig, the group spec derivations and the
        -- flow/anchor setter guards all run.
        { "BuffsAndContainers:Layout",       BF.indicators and BF.indicators.buffsAndContainers, "Layout" },
        { "DebuffIcons:Layout",              BF.indicators and BF.indicators.debuffIcons, "Layout" },

        -- v92: memoized per _fbsGeneration — expect many calls, tiny total;
        -- a large total means the memo is being invalidated every pass.
        { "GetContainerBuffConfig",          BF, "GetContainerBuffConfig" },
        { "RefreshAllCustomContainers",      BF, "RefreshAllCustomContainers" },

        -- ContainerFactory entry points behind the new change guards
        -- (AcSpecFieldsMatch, _bf_flowSig, anchor fields, ButtonSpecSig).
        { "SyncAuraGridContainer",           BF, "SyncAuraGridContainer" },
        { "ApplyAuraGridGeometry",           BF, "ApplyAuraGridGeometry" },
        { "ApplyAuraGridButtonSpec",         BF, "ApplyAuraGridButtonSpec" },
        { "ApplyAuraGridGroupButtonSpec",    BF, "ApplyAuraGridGroupButtonSpec" },
        { "ReanchorFrameAuraContainers",     BF, "ReanchorFrameAuraContainers" },

        -- Detached player power bar (v92: Tick/Update split — Tick is the
        -- per-event values-only path, Update is the full restyle).
        { "TickOUFPowerBar",                 BF, "TickOUFPowerBar" },
        { "UpdateOUFPowerBar",               BF, "UpdateOUFPowerBar" },

        -- v92: combat bail at top — combat calls should be ~0 ms.
        { "UpdateSize",                      BF, "UpdateSize" },
    }
end

local function ResetStats()
    for k in pairs(stats) do
        stats[k] = nil
    end
end
-- (topRows is filled by the v96 script wraps / TOP_METHOD_ROWS at start; it
-- is a static classification, not a counter, so reset leaves it alone.)

-- ── Inline segment timing (idle-gated) ─────────────────────────────────────
-- WrapFunction() measures a whole method; _ProfSeg lets ONE function attribute
-- the cost of its internal PHASES as separate rows. Call sites read
-- BF._profActive FIRST (nil when idle) and only sample the clock when set, so
-- an un-profiled session pays a single field read + branch per segment --
-- honoring this file's zero-overhead-when-off contract. Usage (rolling):
--     local _pm = BF._profActive and GetTimePreciseSec()
--     ...phase A...  if _pm then _pm = BF:_ProfSeg("row [A]", _pm) end
--     ...phase B...  if _pm then _pm = BF:_ProfSeg("row [B]", _pm) end
-- Each call closes the previous slice and returns a fresh mark for the next.
-- UNLIKE the method wraps (INCLUSIVE -- a parent row contains its children),
-- these segment rows are EXCLUSIVE and DO sum to ~their parent callback total.
function BF:_ProfSeg(name, t0)
    if not t0 then return nil end            -- guard stray calls when idle
    local now     = GetTimePreciseSec()
    local elapsed = (now - t0) * 1000
    local entry   = stats[name]
    if not entry then
        entry = { calls = 0, totalMs = 0, maxMs = 0 }
        stats[name] = entry
    end
    entry.calls   = entry.calls + 1
    entry.totalMs = entry.totalMs + elapsed
    if elapsed > entry.maxMs then entry.maxMs = elapsed end
    return now                                -- roll forward to next slice
end

local function WrapFunction(name, obj, key, splitByEvent)
    if not obj or not key or not obj[key] then return end
    if originals[name] then return end  -- already wrapped

    -- Deferred-indicator detection (Grid2 IndicatorIcons pattern):
    -- Indicators that call EnableDeferredUpdates have their Update replaced
    -- with a mark-dirty stub at file-load time; the real work lives in
    -- _DoUpdate, which is what deferFrame:OnUpdate actually invokes. If we
    -- wrap Update (the stub) we measure only the mark-dirty overhead
    -- (~0.3 us/call) and miss all the real cost. Detect this case by
    -- checking for a sibling _DoUpdate on the same object and wrap that
    -- instead. The display name stays the same so reports read naturally.
    --
    -- BFIndicator.lua:EnableDeferredUpdates does self._DoUpdate = self.Update
    -- before replacing self.Update with the stub, so the presence of a
    -- _DoUpdate field is the reliable deferral marker.
    local effectiveKey = key
    if key == "Update" and type(obj._DoUpdate) == "function" then
        effectiveKey = "_DoUpdate"
    end

    local orig = obj[effectiveKey]
    -- v93: record whether the method was a RAW field or inherited. Every
    -- status is `setmetatable({}, statusProto)`, so `obj[key]` for
    -- UpdateIndicators resolves through the metatable while `obj[key] = wrapper`
    -- writes a raw shadow. Restoring with a plain assignment would leave that
    -- shadow behind permanently (a frozen copy of the proto method that stops
    -- tracking later edits to statusProto). UnwrapAll uses this flag to nil
    -- the shadow instead.
    local wasRaw = rawget(obj, effectiveKey) ~= nil
    originals[name] = { obj = obj, key = effectiveKey, func = orig, wasRaw = wasRaw }

    -- v93 splitByEvent: one wrapped function can serve MORE THAN ONE event.
    -- Death:UNIT_HEALTH is registered for both UNIT_HEALTH and UNIT_FLAGS
    -- (BFStatus.lua:1343 and :1360), two events with unrelated frequencies.
    -- A single row would blend them and its call count would not be
    -- comparable with the other UNIT_HEALTH listeners. When set, the row key
    -- becomes `name [<first arg>]` -- these handlers take (self, event, unit),
    -- so the first vararg is the event name.
    obj[effectiveKey] = function(self, ...)
        local rowName = name
        if splitByEvent then
            local ev = ...
            rowName = name .. " [" .. (type(ev) == "string" and ev or "?") .. "]"
        end
        local entry = stats[rowName]
        if not entry then
            entry = { calls = 0, totalMs = 0, maxMs = 0 }
            stats[rowName] = entry
        end
        local t0 = GetTimePreciseSec()
        local r1, r2, r3, r4, r5, r6, r7, r8 = orig(self, ...)
        local elapsed = (GetTimePreciseSec() - t0) * 1000
        entry.calls = entry.calls + 1
        entry.totalMs = entry.totalMs + elapsed
        if elapsed > entry.maxMs then entry.maxMs = elapsed end
        return r1, r2, r3, r4, r5, r6, r7, r8
    end
end

-- ============================================================
-- v96: SCRIPT WRAPS -- the layer the method wraps could not see.
--
-- A v95 report summed to ~0.1-0.15 ms per render frame of wrapped rows
-- while C_AddOnProfiler charged BuzzardFrames ~0.9 ms/frame: roughly 85%
-- of the addon's real cost ran in code no method wrap touches -- oUF's own
-- element Update bodies (health/power/castbar/auras/range run BEFORE the
-- PostUpdate callbacks the old rows measured), every OnUpdate script
-- (castbars, deferred sweeps), and the per-unit roster event frames'
-- dispatch. Wrapping the SCRIPT HANDLERS (OnEvent / OnUpdate) on every
-- frame the addon owns catches all of it, inclusive, regardless of which
-- local closure does the work.
--
-- Rows are named "<label>.OnUpdate" and "<label>.OnEvent [EVENT]". These
-- are TOP-LEVEL rows: nothing calls them but the engine, so unlike the
-- method rows they DO sum -- and the coverage section compares their sum
-- (per render frame) against C_AddOnProfiler to show how much of the
-- addon's frame cost the report now accounts for.
--
-- Roots walked (frame + descendants, depth <= 6):
--   * per-unit roster event frames  -> "Roster.OnEvent [EVENT]" (BF:UNIT_HEALTH
--     and friends nest INSIDE these rows now)
--   * every oUF unit frame           -> "oUF:<unit>" / "oUF:<unit>/<Element>"
--   * every raid unit frame + header -> "RaidFrame" / "RaidHeader" (aggregated)
--   * BF._profFrames registry        -> the file-local deferred OnUpdate frames
-- Start profiling OUT of combat: SetScript on protected unit frames is
-- refused in combat and those frames would simply go unmeasured.
-- ============================================================
local GetOUFFrames         -- defined with the oUF PostUpdate wraps below
local scriptWraps = {}     -- array of { frame=, script=, orig= }
local scriptWrapped = {}   -- [frame] = { [script] = true }
local topRows = {}         -- [rowName] = true  (rows that DO sum)

local function Bump(rowName, elapsed, isTop)
    local entry = stats[rowName]
    if not entry then
        entry = { calls = 0, totalMs = 0, maxMs = 0 }
        stats[rowName] = entry
    end
    entry.calls   = entry.calls + 1
    entry.totalMs = entry.totalMs + elapsed
    if elapsed > entry.maxMs then entry.maxMs = elapsed end
    if isTop then topRows[rowName] = true end
end

local function WrapScript(frame, script, label)
    if not frame or not frame.GetScript then return end
    local ok, orig = pcall(frame.GetScript, frame, script)
    if not ok or not orig then return end
    local w = scriptWrapped[frame]
    if w and w[script] then return end
    local wrapper
    if script == "OnEvent" then
        local base = label .. ".OnEvent ["
        wrapper = function(self, event, ...)
            local t0 = GetTimePreciseSec()
            orig(self, event, ...)
            Bump(base .. tostring(event) .. "]", (GetTimePreciseSec() - t0) * 1000, true)
        end
    else
        local rowName = label .. "." .. script
        wrapper = function(self, ...)
            local t0 = GetTimePreciseSec()
            orig(self, ...)
            Bump(rowName, (GetTimePreciseSec() - t0) * 1000, true)
        end
    end
    local set = pcall(frame.SetScript, frame, script, wrapper)
    if not set then return end
    scriptWrapped[frame] = w or {}
    scriptWrapped[frame][script] = true
    scriptWraps[#scriptWraps + 1] = { frame = frame, script = script, orig = orig }
end

-- Name a child by the field its parent stores it under (oUF elements:
-- frame.Castbar, frame.Health, ...), else by its global name, else "child".
local function ChildLabel(parent, child)
    for k, v in pairs(parent) do
        if v == child and type(k) == "string" then return k end
    end
    local ok, n = false, nil
    if type(child.GetName) == "function" then ok, n = pcall(child.GetName, child) end
    return (ok and type(n) == "string" and n) or "child"
end

-- 12.1 aura-container buttons (Blizzard_AuraContainerFrameProviders) are
-- FORBIDDEN objects: any method call from addon code throws. Skip them and
-- anything under them -- they are engine-driven, no addon Lua runs there.
local function IsForbiddenFrame(f)
    if type(f.IsForbidden) ~= "function" then return true end
    local ok, forbidden = pcall(f.IsForbidden, f)
    return (not ok) or forbidden
end

-- nameKids: label children by their parent field (pairs() scan of the
-- parent -- fine for the dozen oUF frames, far too slow for 40 raid frames
-- with ~150 fields each; those aggregate under "<label>/sub" instead).
local walkVisited = {}   -- [frame] = true; a subtree is walked once per start
local function WalkAndWrap(frame, label, depth, nameKids, maxDepth)
    if not frame or type(frame) ~= "table" or not frame.GetScript then return end
    if walkVisited[frame] then return end
    walkVisited[frame] = true
    if IsForbiddenFrame(frame) then return end
    WrapScript(frame, "OnEvent",  label)
    WrapScript(frame, "OnUpdate", label)
    if depth >= (maxDepth or 6) or not frame.GetChildren then return end
    local okc, kids = pcall(function() return { frame:GetChildren() } end)
    if not okc then return end
    for i = 1, #kids do
        local c = kids[i]
        local sub = nameKids and ChildLabel(frame, c) or "sub"
        WalkAndWrap(c, label .. "/" .. sub, depth + 1, nameKids, maxDepth)
    end
end

local function WrapAllScripts()
    for f in pairs(walkVisited) do walkVisited[f] = nil end
    -- 1. per-unit roster event frames (Initialization.lua PerUnitOnEvent)
    if BF._debugPerUnitFrames then
        for _, f in pairs(BF._debugPerUnitFrames) do
            WrapScript(f, "OnEvent", "Roster")
        end
    end
    -- 2. oUF unit frames
    for _, f in ipairs(GetOUFFrames()) do
        WalkAndWrap(f, "oUF:" .. tostring(f.unit or f.__unit or "?"), 0, true)
    end
    if BF._classPowerHost then WalkAndWrap(BF._classPowerHost, "oUF:classpower", 0, true) end
    -- 3. raid unit frames + headers (aggregated under one label each)
    for _, f in pairs(BF.registeredFrames or {}) do
        WalkAndWrap(f, "RaidFrame", 0, nil, 2)
    end
    for _, h in ipairs(BF.groupsUsed or {}) do
        WrapScript(h, "OnEvent",  "RaidHeader")
        WrapScript(h, "OnUpdate", "RaidHeader")
    end
    -- 4. file-local deferred frames that registered themselves
    for name, f in pairs(BF._profFrames or {}) do
        WrapScript(f, "OnUpdate", name)
        WrapScript(f, "OnEvent",  name)
    end
    -- (A former step 5 swept EnumerateFrames() for stray "BuzzardFrames*"
    -- names. Walking every frame in the UI blew the script time limit with
    -- Details/Blizzard raid manager loaded, and the only frames it found
    -- were setup-mode anchors that run no OnUpdate in combat. Removed.)
end

local function UnwrapAllScripts()
    for i = #scriptWraps, 1, -1 do
        local w = scriptWraps[i]
        pcall(w.frame.SetScript, w.frame, w.script, w.orig)
        scriptWraps[i] = nil
    end
    for f in pairs(scriptWrapped) do scriptWrapped[f] = nil end
end

-- ── v96: window sampler ────────────────────────────────────────────────────
-- Counts render frames over the profiled window (so wrap totals convert to
-- ms per FRAME, the unit C_AddOnProfiler reports in) and samples
-- RecentAverageTime once a second for BuzzardFrames, the comparison addons
-- and the overall total, averaging the samples over the whole window. The
-- stop-time snapshot below only reflects the last ~few seconds; this is the
-- like-for-like number: same pull, same frames, every addon.
BF._profCompareAddons = BF._profCompareAddons or { "Grid2", "Ace3" }
local sampler = { frames = 0, ticker = nil, rows = nil }
local samplerFrame = CreateFrame("Frame")
samplerFrame:Hide()
samplerFrame:SetScript("OnUpdate", function() sampler.frames = sampler.frames + 1 end)

local function SamplerTick()
    if not (C_AddOnProfiler and Enum and Enum.AddOnProfilerMetric) then return end
    local M = Enum.AddOnProfilerMetric
    local rows = sampler.rows
    local function acc(key, v)
        if v == nil then return end
        local r = rows[key]
        if not r then r = { sum = 0, n = 0, max = 0 }; rows[key] = r end
        r.sum = r.sum + v; r.n = r.n + 1
        if v > r.max then r.max = v end
    end
    acc("BuzzardFrames", C_AddOnProfiler.GetAddOnMetric("BuzzardFrames", M.RecentAverageTime))
    for _, name in ipairs(BF._profCompareAddons) do
        if C_AddOns.IsAddOnLoaded(name) then
            acc(name, C_AddOnProfiler.GetAddOnMetric(name, M.RecentAverageTime))
        end
    end
    acc("ALL ADDONS", C_AddOnProfiler.GetOverallMetric(M.RecentAverageTime))
end

local function StartSampler()
    sampler.frames = 0
    sampler.rows = {}
    samplerFrame:Show()
    sampler.ticker = C_Timer.NewTicker(1, SamplerTick)
end

local function StopSampler()
    samplerFrame:Hide()
    if sampler.ticker then sampler.ticker:Cancel(); sampler.ticker = nil end
    SamplerTick()  -- close the window with one final sample
end

-- Method rows that are ALSO top-level (engine/timer entry points that no
-- script wrap above contains). Everything else in the method table nests
-- inside a Roster/oUF/RaidFrame script row or one of these.
local TOP_METHOD_ROWS = {
    "PingMirror:Tick", "ThresholdPollOnTick", "RangeTick",
    "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "GROUP_ROSTER_UPDATE",
    "IC:OnSpellcastStart", "IC:OnSpellcastChannelStart", "IC:OnSpellcastEnd",
    "IC:OnNameplateAdded", "IC:OnNameplateRemoved", "IC:ProcessCast",
}

-- Special wrapper for frame:UpdateIndicators() which is a method
-- on each frame object, not on BF. We hook it via the metatable
-- or by wrapping the function on registeredFrames.
local origUpdateIndicators = nil
local function WrapUpdateIndicators()
    -- UpdateIndicators is set on each frame during InitFrame.
    -- We wrap BF's frame factory instead: hook the function that
    -- gets assigned as frame.UpdateIndicators.
    -- Simpler approach: wrap it on all currently active frames
    -- and track globally.
    local name = "UpdateIndicators"
    if originals[name] then return end

    -- Find the function from any active frame
    local sampleFunc
    for frame in pairs(BF.activatedFrames or {}) do
        if frame.UpdateIndicators then
            sampleFunc = frame.UpdateIndicators
            break
        end
    end
    if not sampleFunc then return end

    origUpdateIndicators = sampleFunc
    originals[name] = { obj = nil, key = nil, func = sampleFunc }

    local wrapper = function(frame, ...)
        local entry = stats[name]
        if not entry then
            entry = { calls = 0, totalMs = 0, maxMs = 0 }
            stats[name] = entry
        end
        local t0 = GetTimePreciseSec()
        local r1, r2 = origUpdateIndicators(frame, ...)
        local elapsed = (GetTimePreciseSec() - t0) * 1000
        entry.calls = entry.calls + 1
        entry.totalMs = entry.totalMs + elapsed
        if elapsed > entry.maxMs then entry.maxMs = elapsed end
        return r1, r2
    end

    -- Patch all existing frames
    for frame in pairs(BF.activatedFrames or {}) do
        if frame.UpdateIndicators == sampleFunc then
            frame.UpdateIndicators = wrapper
        end
    end
    -- Also patch registeredFrames (superset of activated)
    for _, frame in pairs(BF.registeredFrames or {}) do
        if frame.UpdateIndicators == sampleFunc then
            frame.UpdateIndicators = wrapper
        end
    end
end

-- ============================================================
-- oUF PostUpdate wrappers
-- Health.PostUpdate and Power.PostUpdate are per-frame callbacks
-- set on each oUF unit frame's Health/Power elements. We wrap
-- them on all existing oUF frames, similar to WrapUpdateIndicators.
-- ============================================================
local origOUFPostUpdates = {}  -- [oufFrame] = { healthOrig=fn, powerOrig=fn }

GetOUFFrames = function()
    local frames = {}
    if BF.oufPlayer         then frames[#frames+1] = BF.oufPlayer end
    if BF.oufTarget         then frames[#frames+1] = BF.oufTarget end
    if BF.oufFocus          then frames[#frames+1] = BF.oufFocus end
    if BF.oufPet            then frames[#frames+1] = BF.oufPet end
    if BF.oufTargetOfTarget then frames[#frames+1] = BF.oufTargetOfTarget end
    if BF.oufFocusTarget    then frames[#frames+1] = BF.oufFocusTarget end
    if BF.oufBoss then
        for i = 1, 5 do
            if BF.oufBoss[i] then frames[#frames+1] = BF.oufBoss[i] end
        end
    end
    return frames
end

local function WrapOUFPostUpdates()
    local hName = "oUF:Health.PostUpdate"
    local pName = "oUF:Power.PostUpdate"
    local frames = GetOUFFrames()
    for _, f in ipairs(frames) do
        local saved = {}
        if f.Health and f.Health.PostUpdate and not origOUFPostUpdates[f] then
            local orig = f.Health.PostUpdate
            saved.healthOrig = orig
            f.Health.PostUpdate = function(element, ...)
                local entry = stats[hName]
                if not entry then
                    entry = { calls = 0, totalMs = 0, maxMs = 0 }
                    stats[hName] = entry
                end
                local t0 = GetTimePreciseSec()
                local r1, r2 = orig(element, ...)
                local elapsed = (GetTimePreciseSec() - t0) * 1000
                entry.calls = entry.calls + 1
                entry.totalMs = entry.totalMs + elapsed
                if elapsed > entry.maxMs then entry.maxMs = elapsed end
                return r1, r2
            end
        end
        if f.Power and f.Power.PostUpdate and not origOUFPostUpdates[f] then
            local orig = f.Power.PostUpdate
            saved.powerOrig = orig
            f.Power.PostUpdate = function(element, ...)
                local entry = stats[pName]
                if not entry then
                    entry = { calls = 0, totalMs = 0, maxMs = 0 }
                    stats[pName] = entry
                end
                local t0 = GetTimePreciseSec()
                local r1, r2 = orig(element, ...)
                local elapsed = (GetTimePreciseSec() - t0) * 1000
                entry.calls = entry.calls + 1
                entry.totalMs = entry.totalMs + elapsed
                if elapsed > entry.maxMs then entry.maxMs = elapsed end
                return r1, r2
            end
        end
        if saved.healthOrig or saved.powerOrig then
            origOUFPostUpdates[f] = saved
        end
    end
end

local function UnwrapOUFPostUpdates()
    for f, saved in pairs(origOUFPostUpdates) do
        if saved.healthOrig and f.Health then
            f.Health.PostUpdate = saved.healthOrig
        end
        if saved.powerOrig and f.Power then
            f.Power.PostUpdate = saved.powerOrig
        end
    end
    origOUFPostUpdates = {}
end

local function UnwrapAll()
    for name, info in pairs(originals) do
        if name == "UpdateIndicators" then
            -- Restore original on all frames
            if origUpdateIndicators then
                for frame in pairs(BF.activatedFrames or {}) do
                    if frame.UpdateIndicators and frame.UpdateIndicators ~= origUpdateIndicators then
                        frame.UpdateIndicators = origUpdateIndicators
                    end
                end
                for _, frame in pairs(BF.registeredFrames or {}) do
                    if frame.UpdateIndicators and frame.UpdateIndicators ~= origUpdateIndicators then
                        frame.UpdateIndicators = origUpdateIndicators
                    end
                end
                origUpdateIndicators = nil
            end
        elseif info.obj and info.key and info.func then
            -- v93: restore inherited methods to nil rather than raw-copying the
            -- proto function onto the object (see wasRaw in WrapFunction).
            if info.wasRaw then
                info.obj[info.key] = info.func
            else
                rawset(info.obj, info.key, nil)
            end
        end
    end
    originals = {}
    UnwrapOUFPostUpdates()
end

-- ============================================================
-- WHOLE-ADDON FRAME COST (C_AddOnProfiler)
--
-- The function wraps above only see the functions they wrap. Blizzard's
-- built-in addon profiler measures each addon's TOTAL Lua time per render
-- frame — every OnUpdate, event handler and timer callback, wrapped or
-- not — which is the attribution layer this report was missing: it
-- answers "is the frame cost this addon, another addon, or the engine"
-- before the per-function rows answer "where inside this addon".
--
-- RecentAverageTime is captured at StopProfiling so its short window
-- lines up with the combat just profiled (it decays fast — reading it at
-- report time could be seconds of idle later).
--
-- PeakTime is SESSION-SCOPED — the worst single frame since login/reload,
-- NOT since '/bf prof start' — so a login or loading-screen stall would
-- masquerade as combat data. Peaks are therefore snapshotted at START as
-- well, and the report shows only peaks that CHANGED during the profiled
-- window; an unchanged peak is pre-window and prints as "-".
--
-- Attribution caveat (report footer carries it too): Blizzard attributes
-- time to the addon whose FILE defined the running closure, so a shared/
-- embedded library's cost lands on whichever addon loaded it first, on
-- behalf of every addon that calls it.
-- ============================================================
local addonSnapshot   = nil  -- stop-time: array of { name, recentMs, peakMs, peakLive }, plus .overallRecent/.overallPeak/.overallPeakLive
local addonStartPeaks = nil  -- start-time: [name] = peakMs, plus .overall

local function CaptureAddonStartPeaks()
    addonStartPeaks = nil
    if not (C_AddOnProfiler and Enum and Enum.AddOnProfilerMetric) then return end
    local M = Enum.AddOnProfilerMetric
    local peaks = { overall = C_AddOnProfiler.GetOverallMetric(M.PeakTime) }
    local num = C_AddOns and C_AddOns.GetNumAddOns and C_AddOns.GetNumAddOns() or 0
    for i = 1, num do
        if C_AddOns.IsAddOnLoaded(i) then
            local name = C_AddOns.GetAddOnInfo(i)
            if name then
                peaks[name] = C_AddOnProfiler.GetAddOnMetric(name, M.PeakTime)
            end
        end
    end
    addonStartPeaks = peaks
end

local function CaptureAddonSnapshot()
    addonSnapshot = nil
    if not (C_AddOnProfiler and Enum and Enum.AddOnProfilerMetric) then return end
    local M = Enum.AddOnProfilerMetric
    local startPeaks = addonStartPeaks or {}
    local overallPeak = C_AddOnProfiler.GetOverallMetric(M.PeakTime)
    local snap = {
        overallRecent   = C_AddOnProfiler.GetOverallMetric(M.RecentAverageTime),
        overallPeak     = overallPeak,
        overallPeakLive = (startPeaks.overall == nil) or (overallPeak ~= startPeaks.overall),
    }
    local num = C_AddOns and C_AddOns.GetNumAddOns and C_AddOns.GetNumAddOns() or 0
    for i = 1, num do
        if C_AddOns.IsAddOnLoaded(i) then
            local name = C_AddOns.GetAddOnInfo(i)
            if name then
                local recent = C_AddOnProfiler.GetAddOnMetric(name, M.RecentAverageTime)
                local peak   = C_AddOnProfiler.GetAddOnMetric(name, M.PeakTime)
                if (recent and recent > 0) or (peak and peak > 0) then
                    -- peakLive: this peak was SET during the profiled window.
                    -- A missing start value (addon loaded mid-window) counts
                    -- as live — there is no pre-window peak to confuse it with.
                    local sp = startPeaks[name]
                    snap[#snap + 1] = {
                        name = name, recentMs = recent or 0, peakMs = peak or 0,
                        peakLive = (sp == nil) or (peak ~= sp),
                    }
                end
            end
        end
    end
    sort(snap, function(a, b) return a.recentMs > b.recentMs end)
    addonSnapshot = snap
end

local function StartProfiling()
    if profiling then
        BF:DebugPrint("|cffd3ff7dBF Prof:|r Already running. Use '/bf prof reset' to reset counters.")
        return
    end
    ResetStats()
    local targets = GetProfilTargets()
    for _, t in ipairs(targets) do
        local name, obj, key, splitByEvent = t[1], t[2], t[3], t[4]
        if obj and key then
            WrapFunction(name, obj, key, splitByEvent)
        end
    end
    WrapUpdateIndicators()
    WrapOUFPostUpdates()
    WrapAllScripts()   -- v96: script-handler layer (see SCRIPT WRAPS)
    for _, n in ipairs(TOP_METHOD_ROWS) do topRows[n] = true end
    StartSampler()
    if InCombatLockdown() then
        BF:DebugPrint("|cffd3ff7dBF Prof:|r Started IN COMBAT - protected unit frames could not be script-wrapped; coverage will be understated.")
    end
    -- v92: restyle change-guard counters (ContainerFactory). hit/miss are the
    -- container-level ApplyAuraGridButtonSpec guard; groupHit/groupMiss are
    -- the per-group ApplyAuraGridGroupButtonSpec ButtonSpecSig guard. A
    -- healthy steady state is near-100% hits after the first pass; a stream
    -- of groupMiss means some spec input churns table identity per Layout.
    BF.restyleStats = BF.restyleStats or { hit = 0, miss = 0, groupHit = 0,
        groupMiss = 0, missCombat = 0, groupMissCombat = 0 }
    BF.restyleStats.hit, BF.restyleStats.miss = 0, 0
    BF.restyleStats.groupHit, BF.restyleStats.groupMiss = 0, 0
    -- v99: restricted-miss counters (see the report note).
    BF.restyleStats.missCombat, BF.restyleStats.groupMissCombat = 0, 0
    -- Live aura rebuilds inside a keystone (ContainerFactory RC.Stat). These
    -- count whether or not profiling is on; zeroed here so the report covers
    -- this window only. Session totals: /bf recreate status.
    BF.restyleStats.recreate, BF.restyleStats.recreateFail = 0, 0
    BF.restyleStats.recreateCapped, BF.restyleStats.recreateDrift = 0, 0
    BF.restyleStats.recreateBuild, BF.restyleStats.leakedButtons = 0, 0
    BF.restyleStatsOn = true
    profiling = true
    BF._profActive = true  -- idle gate for inline segment timing (BF:_ProfSeg)
    -- Baseline the session-scoped addon peaks so the report can tell a
    -- peak set during THIS window from a stale login/loading-screen stall.
    CaptureAddonStartPeaks()
    BF._profilingStartTime = GetTime()
    BF:DebugPrint("|cffd3ff7dBF Prof:|r Profiling started. Use '/bf prof stop' then '/bf prof report'.")
end

local function StopProfiling()
    if not profiling then
        BF:DebugPrint("|cffd3ff7dBF Prof:|r Not running.")
        return
    end
    profiling = false
    BF._profActive = nil
    BF.restyleStatsOn = false
    BF._profilingElapsed = GetTime() - (BF._profilingStartTime or GetTime())
    StopSampler()
    CaptureAddonSnapshot()
    UnwrapAll()
    UnwrapAllScripts()
    BF:DebugPrint(format("|cffd3ff7dBF Prof:|r Stopped after %.1f seconds.", BF._profilingElapsed))
end

-- v92: build the report as ONE plain-text string (no |cff color codes — an
-- EditBox copies its RAW text, so codes would land in the clipboard).
local function BuildReportText()
    local elapsed = BF._profilingElapsed or 0
    local lines = {}
    lines[#lines + 1] = format("BuzzardFrames Profiler Report (%.1f sec profiled)", elapsed)
    -- Header must match the row format below: 5 numeric columns plus name.
    -- Row uses: %-40s %8d %10.2f %8.4f %8.4f  (%.0f/s)
    -- Columns:  Function Calls Total_ms Avg_ms Max_ms  (Calls/s)
    lines[#lines + 1] = format("%-40s %8s %10s %8s %8s  %7s",
        "Function", "Calls", "Total ms", "Avg ms", "Max ms", "Calls/s")
    lines[#lines + 1] = string.rep("-", 90)

    -- Sort by total time descending
    local sorted = {}
    for name, data in pairs(stats) do
        sorted[#sorted + 1] = { name = name, calls = data.calls, totalMs = data.totalMs, maxMs = data.maxMs }
    end
    sort(sorted, function(a, b) return a.totalMs > b.totalMs end)

    for _, entry in ipairs(sorted) do
        local avg = entry.calls > 0 and (entry.totalMs / entry.calls) or 0
        local callsPerSec = elapsed > 0 and (entry.calls / elapsed) or 0
        lines[#lines + 1] = format("%-40s %8d %10.2f %8.4f %8.4f  (%.0f/s)",
            entry.name, entry.calls, entry.totalMs, avg, entry.maxMs, callsPerSec)
    end

    -- v93 3.0: UNIT_HEALTH true cost. Three independent listeners are
    -- registered for this one event (Initialization.lua:121 PerUnitOnEvent
    -- fans out to all of them); the pre-v93 report showed only the first and
    -- understated the event by roughly 2x. Rows are INCLUSIVE of their wrapped
    -- children, so only these three top-level listeners are summed -- the
    -- AbsorbBars rows nested under ShieldsOverflow are already inside its
    -- total and adding them would double-count.
    local UH_ROWS = {
        "BF:UNIT_HEALTH",
        "ShieldsOverflow:UpdateIndicators",
        "Death:UNIT_HEALTH [UNIT_HEALTH]",
    }
    local uhAny = false
    for _, n in ipairs(UH_ROWS) do
        if stats[n] then uhAny = true; break end
    end
    if uhAny then
        local uhTotal, uhEvents = 0, 0
        lines[#lines + 1] = ""
        lines[#lines + 1] = "UNIT_HEALTH true cost (every listener on the one event)"
        lines[#lines + 1] = format("%-40s %8s %10s %8s", "Listener", "Calls", "Total ms", "Avg ms")
        lines[#lines + 1] = string.rep("-", 68)
        for _, n in ipairs(UH_ROWS) do
            local d = stats[n]
            if d then
                local avg = d.calls > 0 and (d.totalMs / d.calls) or 0
                lines[#lines + 1] = format("%-40s %8d %10.2f %8.4f", n, d.calls, d.totalMs, avg)
                uhTotal = uhTotal + d.totalMs
                -- Each listener sees the same event stream, so the event count
                -- is the MAX of the per-listener counts, not their sum. They
                -- can differ: a status enabled mid-session registers late.
                if d.calls > uhEvents then uhEvents = d.calls end
            else
                lines[#lines + 1] = format("%-40s %8s %10s %8s", n, "-", "-", "-")
            end
        end
        lines[#lines + 1] = string.rep("-", 68)
        lines[#lines + 1] = format("%-40s %8d %10.2f %8.4f", "TOTAL per UNIT_HEALTH event",
            uhEvents, uhTotal, uhEvents > 0 and (uhTotal / uhEvents) or 0)
        lines[#lines + 1] = "('-' = that listener never registered this window. ShieldsOverflow"
        lines[#lines + 1] = " registers UNIT_HEALTH only when showAbsorbsMissingHealth is on in"
        lines[#lines + 1] = " some flat, so its absence is a result, not a missing measurement."
        lines[#lines + 1] = " The AbsorbBars rows in the table above are nested INSIDE"
        lines[#lines + 1] = " ShieldsOverflow - already counted, do not add them to TOTAL.)"
    end

    -- v95: oUF Health.PostUpdate segment breakdown. The "oUF:H.PU [...]" rows
    -- in the table above are EXCLUSIVE slices of the inclusive
    -- "oUF:Health.PostUpdate" row -- unlike the method wraps, these DO sum, to
    -- roughly that row's total (the shortfall is the callback's own setup).
    local segAny = false
    for n in pairs(stats) do
        if n:find("oUF:H.PU", 1, true) then segAny = true; break end
    end
    if segAny then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "oUF:Health.PostUpdate breakdown (EXCLUSIVE -- these DO sum to the"
        lines[#lines + 1] = "inclusive oUF:Health.PostUpdate row, minus its setup remainder):"
        lines[#lines + 1] = "  [text]+[dead]+[bggrad] = per-tick (every UNIT_HEALTH)"
        lines[#lines + 1] = "  [color]+[unitchg]      = per-unit-swap (call count tracks swaps)"
    end

    -- v92: restyle change-guard hit rates (counted while profiling was on).
    -- v99: misses split by whether the pass could act. A RESTRICTED miss (in
    -- combat, or while auras are engine-secret) returns before committing its
    -- snapshot, so it cannot converge: it misses again next pass and every pass
    -- after, until the restriction lifts. Those are a rebuild backlog waiting on
    -- regen, NOT churn -- reading them as churn sends you hunting a spec input
    -- that is perfectly stable. Only the unrestricted misses are real work, and
    -- only THEY should be near zero in a steady state.
    local rs = BF.restyleStats
    if rs then
        local mc, gmc = rs.missCombat or 0, rs.groupMissCombat or 0
        if (rs.hit + rs.miss + rs.groupHit + rs.groupMiss + mc + gmc) > 0 then
            lines[#lines + 1] = ""
            lines[#lines + 1] = format(
                "Restyle guards - container: %d hit / %d miss (+%d restricted), "
                .. "group: %d hit / %d miss (+%d restricted)",
                rs.hit, rs.miss, mc, rs.groupHit, rs.groupMiss, gmc)
            local act, tot = rs.miss + rs.groupMiss, rs.hit + rs.miss + mc
                                                   + rs.groupHit + rs.groupMiss + gmc
            lines[#lines + 1] = format(
                "  %d of %d guard consultations did real restyle work (%.1f%%); "
                .. "%d were blocked and will retry.",
                act, tot, tot > 0 and (act / tot * 100) or 0, mc + gmc)
        end
        local rc, rf = rs.recreate or 0, rs.recreateFail or 0
        local rcap, rd = rs.recreateCapped or 0, rs.recreateDrift or 0
        local rb, lb = rs.recreateBuild or 0, rs.leakedButtons or 0
        if (rc + rf + rcap + rd + rb + lb) > 0 then
            lines[#lines + 1] = format(
                "Key rebuilds - %d rebuilt / %d failed / %d capped / %d drift, "
                .. "%d built, %d buttons leaked",
                rc, rf, rcap, rd, rb, lb)
        end
    end

    -- v96: COVERAGE. Top-level rows (script wraps + TOP_METHOD_ROWS) are
    -- entered only by the engine, so they DO sum. Converted to ms per render
    -- frame using the frame count the sampler kept, they can be set against
    -- the C_AddOnProfiler window average for the same frames: the gap is the
    -- addon cost that still runs outside every wrap (secure-header attribute
    -- work, AceTimer/AceEvent dispatch, anything wrapped in combat lockdown).
    local frames = sampler.frames or 0
    if frames > 0 then
        local topTotal, topList = 0, {}
        for n in pairs(topRows) do
            local d = stats[n]
            if d then
                topTotal = topTotal + d.totalMs
                topList[#topList + 1] = { name = n, totalMs = d.totalMs, calls = d.calls }
            end
        end
        sort(topList, function(a, b) return a.totalMs > b.totalMs end)
        lines[#lines + 1] = ""
        lines[#lines + 1] = format("Coverage (ms per render frame, averaged over the whole %d-frame window)", frames)
        lines[#lines + 1] = format("%-40s %12s %12s", "Source", "Avg/frame", "Peak sample")
        lines[#lines + 1] = string.rep("-", 68)
        local rows = sampler.rows or {}
        local bfAvg
        local function emit(key, label)
            local r = rows[key]
            if r and r.n > 0 then
                local avg = r.sum / r.n
                if key == "BuzzardFrames" then bfAvg = avg end
                lines[#lines + 1] = format("%-40s %12.3f %12.3f", label or key, avg, r.max)
            elseif key ~= "ALL ADDONS" then
                lines[#lines + 1] = format("%-40s %12s", (label or key) .. " (not loaded)", "-")
            end
        end
        emit("BuzzardFrames", "BuzzardFrames (C_AddOnProfiler)")
        for _, name in ipairs(BF._profCompareAddons or {}) do emit(name, name .. " (C_AddOnProfiler)") end
        emit("ALL ADDONS")
        local accounted = topTotal / frames
        local pct = (bfAvg and bfAvg > 0) and (100 * accounted / bfAvg) or nil
        lines[#lines + 1] = format("%-40s %12.3f %12s", "Accounted by top-level wrap rows", accounted,
            pct and format("(%.0f%%)", pct) or "")
        if bfAvg then
            lines[#lines + 1] = format("%-40s %12.3f", "Unaccounted (outside every wrap)", math.max(0, bfAvg - accounted))
        end
        lines[#lines + 1] = ""
        lines[#lines + 1] = "Top-level rows (engine entry points; these DO sum -- every other row nests inside one):"
        lines[#lines + 1] = format("%-56s %8s %10s %10s", "Row", "Calls", "Total ms", "ms/frame")
        lines[#lines + 1] = string.rep("-", 88)
        for _, r in ipairs(topList) do
            if r.totalMs >= 0.5 then
                lines[#lines + 1] = format("%-56s %8d %10.2f %10.4f", r.name, r.calls, r.totalMs, r.totalMs / frames)
            end
        end
        lines[#lines + 1] = "(rows under 0.5 ms total omitted; wrapper overhead ~0.3 us/call inflates high-count rows)"
    end

    -- Whole-addon frame cost, snapshotted at '/bf prof stop' (see
    -- CaptureAddonSnapshot). Recent avg is ms of Lua per RENDER FRAME over
    -- the frames just before the stop. These are per-frame numbers, not
    -- per-second: at 60 fps, 1.00 recent avg costs a solid millisecond of
    -- every frame. Peak shows only peaks SET during the profiled window
    -- (delta against the start baseline); "-" means the addon's session
    -- peak predates '/bf prof start' — usually a login/loading stall.
    -- The function rows above only cover BuzzardFrames' wrapped functions;
    -- this section covers EVERYTHING each addon runs — but shared/embedded
    -- library time is attributed to whichever addon LOADED the library
    -- first, not the addon calling into it.
    local snap = addonSnapshot
    if snap then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "AddOn frame cost (ms per render frame, at stop)"
        lines[#lines + 1] = format("%-40s %12s %14s", "AddOn", "Recent avg", "Window peak")
        lines[#lines + 1] = string.rep("-", 68)
        for _, a in ipairs(snap) do
            local peakStr = a.peakLive and format("%14.3f", a.peakMs) or format("%14s", "-")
            lines[#lines + 1] = format("%-40s %12.3f %s", a.name, a.recentMs, peakStr)
        end
        if snap.overallRecent then
            local peakStr = snap.overallPeakLive and format("%14.3f", snap.overallPeak or 0)
                or format("%14s", "-")
            lines[#lines + 1] = format("%-40s %12.3f %s", "ALL ADDONS (overall)",
                snap.overallRecent or 0, peakStr)
        end
        lines[#lines + 1] = "('-' = session peak unchanged during this window; " ..
            "library time lands on the addon that loaded the library first)"
    end
    return table.concat(lines, "\n")
end

-- v92 (owner request): the report opens in a COPYABLE popup window instead of
-- printing to chat. Hand-built frame (BackdropTemplate + UIPanelCloseButton
-- only — no BasicFrameTemplate*, whose title/inset children have drifted
-- across client versions): a scrollable multi-line EditBox that auto-selects
-- its whole text on open, so the flow is /bf prof report → Ctrl+C.
local reportFrame
local function EnsureReportFrame()
    if reportFrame then return reportFrame end
    local f = CreateFrame("Frame", "BFProfilerReportFrame", UIParent, "BackdropTemplate")
    f:SetSize(780, 540)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 8, right = 8, top = 8, bottom = 8 },
    })
    f:Hide()
    -- Named + registered so ESC closes it like any Blizzard panel. With the
    -- EditBox focused, the FIRST Escape clears focus (OnEscapePressed below)
    -- and the second hides the window.
    tinsert(UISpecialFrames, "BFProfilerReportFrame")

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", 0, -16)
    title:SetText("BuzzardFrames Profiler Report  (Ctrl+C to copy)")

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -6, -6)

    local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 16, -40)
    scroll:SetPoint("BOTTOMRIGHT", -36, 16)

    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetAutoFocus(false)
    edit:SetFontObject(ChatFontNormal)
    edit:SetWidth(720)
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    -- Read-only: any user keystroke reverts to the stored report, so the text
    -- can't be munged before copying. Programmatic SetText passes userInput
    -- false and is unaffected.
    edit:SetScript("OnTextChanged", function(self, userInput)
        if userInput then self:SetText(f._bfReportText or "") end
    end)
    scroll:SetScrollChild(edit)
    f.editBox = edit
    reportFrame = f
    return f
end

local function ShowReport()
    if not next(stats) then
        BF:DebugPrint("|cffd3ff7dBF Prof:|r No data. Run '/bf prof start', do some combat, then '/bf prof stop' and '/bf prof report'.")
        return
    end
    local f = EnsureReportFrame()
    f._bfReportText = BuildReportText()
    f.editBox:SetText(f._bfReportText)
    f.editBox:SetCursorPosition(0)
    f:Show()
    -- Focus + select-all so Ctrl+C works immediately.
    f.editBox:SetFocus()
    f.editBox:HighlightText()
end

-- ============================================================
-- SESSION ADDON PEAKS (C_AddOnProfiler, no profiling window needed)
-- '/bf prof peaks' dumps every loaded addon's worst single render frame
-- SINCE LOGIN/RELOAD (PeakTime is session-scoped), sorted worst-first.
-- Unlike the '/bf prof report' AddOn section this needs no start/stop
-- window, so it captures login- and loading-screen stalls: an addon that
-- froze the client for N seconds in one frame shows a peak of ~N*1000 ms.
-- Same attribution caveat as the report: a shared/embedded library's cost
-- lands on whichever addon LOADED it first, not the addon calling into it.
-- ============================================================
local function BuildPeaksText()
    if not (C_AddOnProfiler and Enum and Enum.AddOnProfilerMetric) then
        return "AddOn profiler unavailable (C_AddOnProfiler missing on this client)."
    end
    local M = Enum.AddOnProfilerMetric
    local rows = {}
    local num = C_AddOns and C_AddOns.GetNumAddOns and C_AddOns.GetNumAddOns() or 0
    for i = 1, num do
        if C_AddOns.IsAddOnLoaded(i) then
            local name = C_AddOns.GetAddOnInfo(i)
            if name then
                local peak   = C_AddOnProfiler.GetAddOnMetric(name, M.PeakTime) or 0
                local recent = C_AddOnProfiler.GetAddOnMetric(name, M.RecentAverageTime) or 0
                if peak > 0 or recent > 0 then
                    rows[#rows + 1] = { name = name, peak = peak, recent = recent }
                end
            end
        end
    end
    sort(rows, function(a, b) return a.peak > b.peak end)

    local lines = {}
    lines[#lines + 1] = "AddOn worst single frame SINCE LOGIN/RELOAD (session peak)"
    lines[#lines + 1] = "A peak near 20000 ms = a ~20-second one-frame stall in that addon."
    lines[#lines + 1] = ""
    lines[#lines + 1] = format("%-40s %14s %12s", "AddOn", "Peak (ms)", "Recent avg")
    lines[#lines + 1] = string.rep("-", 68)
    local shown = 0
    for _, r in ipairs(rows) do
        lines[#lines + 1] = format("%-40s %14.1f %12.3f", r.name, r.peak, r.recent)
        shown = shown + 1
        if shown >= 30 then break end
    end
    local overall = C_AddOnProfiler.GetOverallMetric(M.PeakTime) or 0
    lines[#lines + 1] = string.rep("-", 68)
    lines[#lines + 1] = format("%-40s %14.1f", "ALL ADDONS (overall peak)", overall)
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Peak = worst ONE render frame since login/reload; reload resets it."
    lines[#lines + 1] = "Library time lands on the addon that LOADED the library first."
    return table.concat(lines, "\n")
end

local function ShowPeaks()
    local f = EnsureReportFrame()
    f._bfReportText = BuildPeaksText()
    f.editBox:SetText(f._bfReportText)
    f.editBox:SetCursorPosition(0)
    f:Show()
    f.editBox:SetFocus()
    f.editBox:HighlightText()
end

-- ============================================================
-- SLASH COMMAND INTEGRATION
-- Hooks into the existing /bf command handler
-- ============================================================
do
    local origChatCommand = BF.OnChatCommand
    function BF:OnChatCommand(input)
        input = input and input:lower():trim() or ""
        if input == "prof start" then
            StartProfiling()
        elseif input == "prof stop" then
            StopProfiling()
        elseif input == "prof report" then
            ShowReport()
        elseif input == "prof peaks" then
            ShowPeaks()
        elseif input == "prof reset" then
            ResetStats()
            BF:DebugPrint("|cffd3ff7dBF Prof:|r Counters reset.")
        elseif input:sub(1, 4) == "prof" then
            BF:DebugPrint("|cffd3ff7dBF Prof:|r Usage: /bf prof start | stop | report | peaks | reset")
        else
            return origChatCommand(self, input)
        end
    end
end

-- Perf plan §L5.1 load-time mark: last file in the .toc: total parse+execute (.toc 185-186).
if BuzzardFrames then BuzzardFrames:LoadMark("chunk:end") end
