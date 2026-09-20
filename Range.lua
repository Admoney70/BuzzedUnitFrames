-- ============================================================
-- BuzzardFrames: Range.lua
-- Range detection modelled directly on Grid2's StatusRange.lua.
-- ============================================================

local BF = _G["BuzzardFrames"]
if not BF then
    error("BuzzardFrames: Range.lua loaded before Core.lua!")
    return
end

local issecretvalue = issecretvalue or function() return false end

local next                 = next
local UnitCanAttack        = UnitCanAttack
local UnitIsDeadOrGhost    = UnitIsDeadOrGhost
local CheckInteractDistance= CheckInteractDistance
local IsSpellInRange       = C_Spell.IsSpellInRange
local UnitPhaseReason      = UnitPhaseReason
local InCombatLockdown     = InCombatLockdown
local playerClass          = select(2, UnitClass("player"))

-- Default to false (OOR) exactly as Grid2 does: Range.cache defaults to false
-- and IsActive is inverted (returns `not cache[unit]`), so false → unit is
-- treated as in-range by the alpha indicator.  We follow the same convention.
BF.rangeCache = setmetatable({}, { __index = function() return false end })

-- roster_external: the set of units the range timer polls, mirroring Grid2's
-- roster_external (GridRoster.lua:38, StatusRange.lua:263 refreshUnits).
--
-- Grid2 polls ONLY these units. Grouped units are driven entirely by the
-- UNIT_IN_RANGE_UPDATE event and are never polled — in a 40-man raid Grid2's
-- range timer does zero work. BF previously iterated all of roster_guids every
-- tick, i.e. 40 full range checks per second.
--
-- In Grid2 roster_external holds target/focus/targettarget/focustarget plus the
-- solo pet. BF's roster only ever contains party/raid/pet tokens (target/focus
-- frames live on the separate oUF pipeline and never enter roster_guids), so in
-- practice this table only ever holds "pet".
BF.roster_external = {}
local roster_external = BF.roster_external


-- phaseCache[unit] = true when the unit is in a different phase, nil otherwise.
-- Populated by the UNIT_PHASE event handler in BFStatus.lua.
-- Note: Phased:IsActive calls UnitPhaseReason live rather than relying on
-- this cache, because the cache can go stale on /reload.
BF.phaseCache = {}

-- grouped_units: mirrors Grid2's GridRoster.lua exactly
local grouped_units = {}
do
    grouped_units["player"] = true
    grouped_units["pet"]    = true
    for i = 1, 5 do
        grouped_units["party"    .. i] = true
        grouped_units["partypet" .. i] = true
    end
    for i = 1, 40 do
        grouped_units["raid"    .. i] = true
        grouped_units["raidpet" .. i] = true
    end
end

local InCombat = false

do
    local origDisabled = BF.PLAYER_REGEN_DISABLED
    function BF:PLAYER_REGEN_DISABLED(...)
        InCombat = true
        if origDisabled then return origDisabled(self, ...) end
    end
    local origEnabled = BF.PLAYER_REGEN_ENABLED
    function BF:PLAYER_REGEN_ENABLED(...)
        InCombat = false
        if origEnabled then return origEnabled(self, ...) end
    end
end

-- ============================================================
-- RANGE CHECK SPELLS  (mirrors Grid2's spell init block exactly)
-- ============================================================
local spellHostile, spellFriendly = "", nil
do
    local function IVS(id) return IsPlayerSpell(id) and id end
    local getHostile, getFriendly
    if playerClass == "DRUID" then
        getHostile  = function() return 8921  end  -- Moonfire
        getFriendly = function() return 8936  end  -- Regrowth
    elseif playerClass == "PRIEST" then
        getHostile  = function() return 585   end  -- Smite
        getFriendly = function() return 2061  end  -- Flash Heal
    elseif playerClass == "SHAMAN" then
        getHostile  = function() return 188196 end -- Lightning Bolt
        getFriendly = function() return 8004  end  -- Healing Surge
    elseif playerClass == "PALADIN" then
        getHostile  = function() return 62124 end  -- Hand of Reckoning
        getFriendly = function() return 19750 end  -- Flash of Light
    elseif playerClass == "MONK" then
        getHostile  = function() return 115546 end -- Provoke
        getFriendly = function() return 116670 end -- Vivify
    elseif playerClass == "EVOKER" then
        getHostile  = function() return 361469 end -- Living Flame
        getFriendly = function() return 355913 end -- Emerald Blossom
    elseif playerClass == "WARLOCK" then
        getHostile  = function() return 686   end  -- Shadow Bolt
        getFriendly = function() return 20707 end  -- Soulstone
    elseif playerClass == "WARRIOR" then
        getHostile  = function() return 355   end  -- Taunt
        getFriendly = function() return nil   end
    elseif playerClass == "DEMONHUNTER" then
        getHostile  = function() return 185123 end -- Throw Glaive
        getFriendly = function() return nil   end
    elseif playerClass == "HUNTER" then
        getHostile  = function() return IVS(193455) or IVS(19434) or IVS(132031) end
        getFriendly = function() return nil   end
    elseif playerClass == "ROGUE" then
        getHostile  = function() return IVS(36554) or IVS(6770) end -- Shadowstep / Sap
        getFriendly = function() return IVS(36554) end             -- Shadowstep
    elseif playerClass == "DEATHKNIGHT" then
        getHostile  = function() return IVS(47541) or IVS(49576) end -- Death Coil / Death Grip
        getFriendly = function() return IVS(47541) end               -- Death Coil
    elseif playerClass == "MAGE" then
        getHostile  = function() return IVS(116) or IVS(30451) or IVS(133) end -- Frostbolt/Arcane Blast/Fireball
        getFriendly = function() return 1459  end  -- Arcane Intellect
    end

    function BF:UpdatePlayerRangeSpells()
        local hid = getHostile and getHostile()
        local fid = getFriendly and getFriendly()
        spellHostile  = (hid and C_Spell.GetSpellName(hid))  or ""
        spellFriendly = (fid and C_Spell.GetSpellName(fid))  or nil
    end
end

-- Grid2 verbatim (StatusRange.lua:76-85): SPELLS_CHANGED is used ONLY on
-- login/reload and unregistered immediately after the first fire, because it
-- fires a lot in combat. Talent swaps are picked up via PLAYER_TALENT_UPDATE
-- instead, debounced through a 0.01s timer because that event fires twice.
-- BF previously left SPELLS_CHANGED registered permanently, rebuilding the
-- range-check closure on every fire — including throughout combat.
local pendingSpellUpdate

function BF:SPELLS_CHANGED()
    self:UpdatePlayerRangeSpells()
    -- Login/reload only — drop it so it stops firing in combat.
    self:UnregisterEvent("SPELLS_CHANGED")
end

-- PLAYER_TALENT_UPDATE is already registered globally (Initialization.lua:530)
-- and already has a handler (Initialization.lua:1361). (SoulOfTheForest.lua
-- used to wrap it too — feature removed v80, 2026-08-15.) Defining
-- BF:PLAYER_TALENT_UPDATE outright would silently destroy the existing
-- handler chain. Wrap, as the rest of this file does for PLAYER_REGEN_*
-- and GROUP_ROSTER_UPDATE.
do
    local origTalentUpdate = BF.PLAYER_TALENT_UPDATE
    function BF:PLAYER_TALENT_UPDATE(...)
        if origTalentUpdate then origTalentUpdate(self, ...) end
        -- Grid2 verbatim (StatusRange.lua:79-84): debounce, because this event
        -- fires twice per talent change.
        if pendingSpellUpdate then return end
        pendingSpellUpdate = true
        C_Timer.After(0.01, function()
            pendingSpellUpdate = nil
            BF:UpdatePlayerRangeSpells()
        end)
    end
end

-- ============================================================
-- REZ + PET SPELLS
-- ============================================================
local rezSpellID = ({
    DRUID       = 20484,  -- Rebirth
    PRIEST      = 2006,   -- Resurrection
    PALADIN     = 7328,   -- Redemption
    SHAMAN      = 2008,   -- Ancestral Spirit
    MONK        = 115178, -- Resuscitate
    DEATHKNIGHT = 61999,  -- Raise Ally
    WARLOCK     = 20707,  -- Soulstone
    EVOKER      = 361227, -- Return
})[playerClass]
local rezSpell = rezSpellID and C_Spell.GetSpellName(rezSpellID)

-- Pet range-check spell: a spell castable on the player's own pet, used ONLY
-- to range the pet frame (group members use spellFriendly/spellHostile).
-- NOTE: Health Funnel (755) was removed in patch 12.0.0, so Warlock uses
-- Unending Breath (5697) — a friendly buff that can target the pet.
local petSpellID = ({
    HUNTER      = 136,   -- Mend Pet
    WARLOCK     = 5697,  -- Unending Breath (Health Funnel 755 removed in 12.0)
    DEATHKNIGHT = 47541, -- Death Coil
})[playerClass]
local petSpell = petSpellID and C_Spell.GetSpellName(petSpellID)

-- Grid2 verbatim: petCheckUnit (StatusRange.lua:94). 'pet' while solo, nil
-- otherwise. Set only when the class has a petSpell, exactly as Grid2 does.
local petCheckUnit = nil

-- Grid2 verbatim: Grid_GroupTypeChanged (StatusRange.lua:166-168)
--   if petSpell then
--       petCheckUnit = (Grid2.groupType=='solo') and 'pet' or nil
--       roster_external.pet = roster_guids[petCheckUnit]
--   end
--
-- Must be declared below petSpell/petCheckUnit and above its caller
-- (SyncRangeChecker). Lua resolves locals at compile time: a local referenced
-- before its declaration silently compiles to a nil global read.
--
-- Grid2 reads Grid2.groupType; BF has no equivalent that is settled at this
-- point in the GROUP_ROSTER_UPDATE sequence (BF._groupType is assigned by the
-- deferred GroupChanged — see the GRU handler at the bottom of this file), so
-- read GetNumGroupMembers() directly. Same condition, available earlier.
--
-- guids[petCheckUnit] may be a SECRET value (Initialization.lua:1015-1017: pet
-- GUIDs are secret under taint). Assign it plainly, as Grid2 does — never put it
-- through and/or, which forces a truthiness test on a secret. Only the KEY of
-- roster_external is ever read (next()/for-in), never the value. A nil
-- petCheckUnit is fine as a table read: guids[nil] returns nil.
--
-- The twin arm below is the second occupant of roster_external. Raid-style
-- twins (UnitFrames/Twins.lua) run on target / focus / bossN, which are not
-- group tokens: UNIT_IN_RANGE_UPDATE is delivered for group members only, so
-- without this the 1 s ticker never visits them and their range alpha would
-- be whatever the last event left. `player` is deliberately absent -- the
-- range check answers true for it without touching an API.
local function UpdateRosterExternal()
    if petSpell then
        petCheckUnit = (GetNumGroupMembers() == 0) and 'pet' or nil
        local guids = BF.roster_guids
        if guids then
            roster_external.pet = guids[petCheckUnit]
        else
            roster_external.pet = nil
        end
    end
    local twins = BF.twinFrames
    if twins then
        for i = 1, #twins do
            local twin = twins[i]
            local key  = twin._bf_twinKey
            if key and key ~= 'player' then
                roster_external[key] = (twin._bf_twinActive and true) or nil
            end
        end
    end
end

-- ============================================================
-- CreateRangeCheck — direct copy of Grid2's StatusRange.lua
-- ============================================================
-- DIVERGENCE FROM GRID2 — solo pet only. Grid2's pet branch is:
--     return IsSpellInRange(petSpell, unit) == true
-- IsSpellInRange has THREE returns, not two:
--     true  -> in range
--     false -> valid target, out of range
--     nil   -> cannot cast this spell on this unit at all
-- `== true` collapses nil into false, i.e. reports "spell unusable" as "out of
-- range". That is fine for a spell that is always castable, but DEATHKNIGHT's
-- petSpell is Death Coil (47541), which is temporarily replaced by an ability
-- that cannot target friendlies. For that window IsSpellInRange returns nil and
-- the solo DK's ghoul frame fades even though it is standing next to you.
--
-- We split nil out. true/false are passed through unchanged, so every case that
-- works today is untouched — only the nil path, which is the bug, changes.
--
-- What to answer on nil is constrained by there being NO usable range API in the
-- exact failing case (solo, in combat, pet spell overridden):
--   * IsSpellInRange   -> nil, that is why we are in this branch
--   * CheckInteractDistance -> PROTECTED in combat since 10.2.0; the 2023-12-11
--     hotfix re-permitted enemy units only, so our own pet stays restricted
--   * UnitInRange      -> returns unchecked for the pet while solo, which is the
--     entire reason petCheckUnit exists
-- So in combat we hold the LAST KNOWN value instead of inventing one. Returning
-- true hides a genuinely out-of-range pet; returning false is the original bug.
-- Out of combat CheckInteractDistance is callable, so measure properly (~28y,
-- close enough to Death Coil's 30y).
--
-- LIMITATION, unavoidable: if the pet leaves range *during* the override window
-- the frame holds the stale in-range value until the override ends. No API can
-- tell us otherwise. The window is a buff duration, and the alternative is being
-- wrong in one direction 100% of the time instead of some of the time.
local function PetRangeCheck(unit)
    local r = IsSpellInRange(petSpell, unit)
    -- Compare against true/false rather than nil: Grid2 already relies on
    -- `== true` being safe here, and this avoids a bare nil comparison.
    if r == true then return true end
    if r == false then return false end
    if not InCombat then
        return CheckInteractDistance(unit, 4) and true or false
    end
    -- Sticky. rangeCache holds plain booleans for the pet (PetRangeCheck only
    -- ever returns true/false), never a secret, so this is safe to coerce.
    -- Metatable default is false, so a first-ever call inside an override reads
    -- OOR and self-corrects the moment the override ends.
    return BF.rangeCache[unit] and true or false
end

-- Grid2 verbatim: StatusRange.lua:102-122, except the pet branch (see above).
local function CreateRangeCheck(spellFriendly, spellHostile, blizRange)
    return function(unit)
        if unit == 'player' then
            return true
        elseif unit == petCheckUnit then -- solo player with pet
            return PetRangeCheck(unit)
        elseif blizRange and grouped_units[unit] then -- 38y range check
            return UnitInRange(unit)
        elseif UnitPhaseReason(unit) then
            return false
        elseif UnitCanAttack('player', unit) then
            return IsSpellInRange(spellHostile, unit) == true
        elseif rezSpell and UnitIsDeadOrGhost(unit) then
            return IsSpellInRange(rezSpell, unit) == true
        elseif spellFriendly then -- extra CheckInteractDistance() for OOC friendly npcs if spell check fails
            return IsSpellInRange(spellFriendly, unit) == true or (not InCombat and CheckInteractDistance(unit, 4))
        else
            return InCombat or CheckInteractDistance(unit, 4)
        end
    end
end

-- The active range check function — rebuilt whenever spells change (via UpdatePlayerRangeSpells)
local UnitInRangeCheck = CreateRangeCheck(spellFriendly, spellHostile, true)

-- Wrap the existing UpdatePlayerRangeSpells to also rebuild the closure
do
    local origUpdate = BF.UpdatePlayerRangeSpells
    function BF:UpdatePlayerRangeSpells()
        origUpdate(self)
        UnitInRangeCheck = CreateRangeCheck(spellFriendly, spellHostile, true)
    end
end

-- ============================================================
-- UpdateIndicators for range — mirrors Grid2's status:UpdateIndicators(unit)
--
-- Grid2's StatusRange calls self:UpdateIndicators(unit) which iterates
-- all frames showing that unit and calls only the bound indicators.
-- BF doesn't have the status→indicator binding system, so we look up
-- the RangeAlpha indicator by name and call its Update directly.
-- This avoids running all indicators on every range tick.
-- ============================================================
local rangeIndicator  -- resolved lazily on first use

local function UpdateRangeIndicator(unit)
    if not rangeIndicator then
        rangeIndicator = BF.indicators and BF.indicators["rangeAlpha"]
        if not rangeIndicator then return end
    end
    -- Grid2 verbatim: iterate all frames showing this unit
    local bucket = BF.frames_of_unit and rawget(BF.frames_of_unit, unit)
    if bucket then
        for frame in next, bucket do
            rangeIndicator:Update(frame, unit)
        end
    end
end

-- ============================================================
-- UpdateUnits — Grid2 verbatim: Range:UpdateUnits
--
-- Grid2 iterates roster_guids (unit→guid). BF iterates
-- activatedFrames (frame→unit) which is the same unit set.
-- On range change: update cache, call UpdateRangeIndicator(unit)
-- for all frames of that unit.
-- ============================================================
local RANGE_INTERVAL = 1.0

-- BF-specific guard: skip work entirely when no frames are active for the
-- current context and no custom frames exist. Not a Grid2 concept — keep.
local function FramesInactive()
    if BF._framesActiveForContext == false then
        local hasCustom = false
        if BF.groupsUsed then
            for _, h in ipairs(BF.groupsUsed) do
                if h.isCustomFrame then hasCustom = true; break end
            end
        end
        -- An activated twin keeps its own token live even in a context whose
        -- raid/party frames are switched off (Initialization.lua's
        -- AllFramesInactive carries the same term).
        if not hasCustom and BF._AnyTwinActive and BF._AnyTwinActive() then
            hasCustom = true
        end
        if not hasCustom then return true end
    end
    return false
end

-- Grid2 verbatim: Shared:UpdateUnits (StatusRange.lua:138-149).
-- Generic over the unit set so the timer can sweep roster_external while
-- Refresh/UpdateAllRanges sweeps the full roster_guids.
local function UpdateUnits(units)
    if not units then return end
    if FramesInactive() then return end
    local cache = BF.rangeCache
    local check = UnitInRangeCheck
    for unit in next, units do
        local new = check(unit)
        local old = cache[unit]
        if issecretvalue(new) or issecretvalue(old) or new ~= old then
            cache[unit] = new
            UpdateRangeIndicator(unit)
        end
    end
end

-- The timer sweeps ONLY roster_external (Grid2's refreshUnits for 38y range,
-- StatusRange.lua:263). Grouped units are event-driven via UNIT_IN_RANGE_UPDATE.
local function RangeUpdateTimer()
    UpdateUnits(roster_external)
end
-- Exposed as a BF field so Profiler.lua can wrap the tick; the ticker below
-- resolves BF.RangeTick on every fire so a wrap installed later is seen.
BF.RangeTick = RangeUpdateTimer

-- ============================================================
-- UNIT_IN_RANGE_UPDATE — Grid2 verbatim: Range:UNIT_IN_RANGE_UPDATE
-- ============================================================
function BF:UNIT_IN_RANGE_UPDATE(event, unit)
    self.rangeCache[unit] = UnitInRangeCheck(unit)
    UpdateRangeIndicator(unit)
    -- v99c: a member crossing into another instance always leaves range,
    -- and this event is immediate where UNIT_PHASE / PARTY_MEMBER_DISABLE
    -- are not -- so re-run the aura-container visibility gate here too
    -- (fresh UnitIsVisible read, change-guarded writes). Trims the junk
    -- flash the 0.25 s ticker would otherwise leave.
    if self.RefreshAuraContainerVisibilityForUnit then
        self:RefreshAuraContainerVisibilityForUnit(unit)
    end
end

-- ============================================================
-- Grid2 verbatim: Shared:Grid_UnitUpdated (StatusRange.lua:173-179)
--   self.cache[unit] = self.UnitRangeCheck(unit)
--   if unit==petCheckUnit then roster_external.pet = roster_guids.pet end
--   self.timer:SetPlaying( next(self.refreshUnits)~=nil )
function BF:PrimeRangeForUnit(unit)
    if not unit or unit == "" then return end
    self.rangeCache[unit] = UnitInRangeCheck(unit)
    -- The pet is the only unit that can enter roster_external, so it is the only
    -- one whose arrival can require starting the ticker. SyncRangeChecker
    -- refreshes roster_external itself. This is the additive half of Grid2's
    -- Grid_UnitUpdated → SetPlaying; without it a pet summoned while solo would
    -- never be polled.
    if unit == "pet" then
        self:SyncRangeChecker()
    end
end

-- Grid2 verbatim: Shared:Grid_UnitUpdated — the MESSAGE subscription, not
-- just the join-time prime above. The roster sweep's UpdateUnit broadcasts
-- BF_UnitUpdated whenever a unit's GUID or name changes, BEFORE the sweep
-- repaints the frame ("per-unit cache owners refresh first" ordering,
-- Initialization.lua). A raid member entering a DIFFERENT INSTANCE unloads
-- their unit data (GUID changes) and NO UNIT_IN_RANGE_UPDATE fires for that
-- transition — this recompute is how Grid2 flips them to OOR (UnitInRange →
-- false) before the repaint reads the cache. Without it BF repainted the
-- stale in-range value forever (field report: cross-instance raider shown
-- in range). PrimeRangeForUnit IS Grid2's handler body (cache recompute +
-- pet ticker resync) so the handler delegates; no repaint here, matching
-- Grid2 — the sweep's own UpdateIndicators fan-out runs right after this
-- message and reads the fresh cache.
function BF:BF_UnitUpdated(_, unit)
    self:PrimeRangeForUnit(unit)
end

-- Grid2 verbatim: Shared:Grid_UnitLeft (StatusRange.lua:181-187)
--   if unit==petCheckUnit then roster_external.pet = nil end
--   self.cache[unit] = nil
--   self.timer:SetPlaying( next(self.refreshUnits)~=nil )
-- BF had no equivalent at all, so rangeCache entries for departed units leaked.
function BF:BF_UnitLeft(_, unit)
    if not unit or unit == "" then return end
    self.rangeCache[unit] = nil
    -- UnregisterRosterUnit clears roster_guids[unit] (Initialization.lua:210)
    -- BEFORE sending this message (:213), so SyncRangeChecker's refresh will
    -- correctly drop the pet from roster_external and cancel the ticker.
    if unit == "pet" then
        self:SyncRangeChecker()
    end
end

function BF:ImmediateRangeUpdate(frame)
    local unit = frame and frame.unit
    if not unit then return end
    -- Only prime the cache. Do NOT call UpdateRangeIndicator here —
    -- this runs inside OnAttributeChanged (restricted/secure context)
    -- where method calls on tables containing secret values cause taint.
    -- The indicator will read the primed cache when UpdateIndicators
    -- runs immediately after in OnUnitChanged.
    self.rangeCache[unit] = UnitInRangeCheck(unit)
end

-- ============================================================
-- Grid2 verbatim: Range:Grid_GroupTypeChanged (StatusRange.lua:165-171).
-- petCheckUnit + roster_external are maintained by UpdateRosterExternal, which
-- SyncRangeChecker calls before deciding whether the ticker runs.
-- ============================================================
function BF:OnGroupTypeChanged()
    self:SyncRangeChecker()
end

-- Grid2's timer:SetPlaying( next(self.refreshUnits)~=nil ) (StatusRange.lua:170).
-- BF has no timer abstraction, so start/cancel a C_Timer ticker on the same
-- condition. In a party/raid roster_external is empty and the ticker is
-- canceled outright.
--
-- The hasUnits guard was previously removed because it raced: SyncRangeChecker
-- could run before frames were assigned, leaving the timer permanently stopped.
-- That race is closed by refreshing roster_external HERE rather than at the call
-- sites. Grid2 can keep the two separate because its only SetPlaying callers are
-- Grid_UnitUpdated/Grid_UnitLeft/Grid_GroupTypeChanged, which all maintain
-- roster_external themselves. BF has six SyncRangeChecker call sites
-- (Initialization.lua:895/1063, BFLayout.lua:3348/3353/4037/4042, plus this
-- file) that do not, and any one of them evaluating a stale roster_external
-- would leave the ticker stopped with a live pet. Refreshing here makes every
-- call site correct by construction. Cost is one GetNumGroupMembers() plus a
-- table read — these sites are roster/layout events, never a combat hot path.
-- No enableRangeFade gate, matching Grid2 — SetPlaying(next(refreshUnits)~=nil)
-- is Grid2's whole condition. The gate that used to be here read
-- BF.db.profile.enableRangeFade, but that key was migrated into
-- rpDB.profile.healthPower (Core_Migrations.lua:542) and is resolved per-flat,
-- so it read nil and the gate was dead code. Range fade is still honored:
-- RangeAlpha:Update reads the correct per-flat value via
-- GetSectionProfileForFrame (Indicators/RangeAlpha.lua:58,63) and sets alpha 1
-- when it is off. Re-adding a gate here would buy one IsSpellInRange per second
-- while solo with a pet, since roster_external holds nothing else.
function BF:SyncRangeChecker()
    UpdateRosterExternal()
    if next(roster_external) ~= nil then
        if not self.rangeTimer then
            self.rangeTimer = C_Timer.NewTicker(RANGE_INTERVAL, function() BF.RangeTick() end)
        end
    else
        if self.rangeTimer then
            self.rangeTimer:Cancel()
            self.rangeTimer = nil
        end
    end
end

function BF:StartRangeChecker()
    self:OnGroupTypeChanged()
end

function BF:StopRangeChecker()
    if self.rangeTimer then
        self.rangeTimer:Cancel()
        self.rangeTimer = nil
    end
end

-- Grid2 verbatim: Shared:Refresh (StatusRange.lua:152-161)
--   wipe(self.cache) -- to remove secrets
--   for unit in Grid2:IterateRosterUnits() do cache[unit] = check(unit); UpdateIndicators(unit) end
--
-- Full immediate range evaluation over the WHOLE roster, not just the polled
-- roster_external set — callers (e.g. LoadLayout) need every unit resolved now
-- rather than waiting on UNIT_IN_RANGE_UPDATE. The cache is wiped first because
-- stale entries may hold secret values from a previous 38y pass, and a secret
-- compared against a fresh non-secret would never register as changed.
function BF:UpdateAllRanges()
    local units = self.roster_guids
    if not units then return end
    self:SyncRangeChecker()  -- refreshes roster_external and starts/stops the ticker
    if FramesInactive() then return end
    -- Unconditional set + update, NOT the UpdateUnits diff. Grid2's Refresh does
    -- the same: after the wipe every cache read returns the metatable default
    -- (false), so a diff would suppress the indicator update for every unit that
    -- is genuinely out of range and leave them painted in-range.
    wipe(self.rangeCache)
    local cache = self.rangeCache
    local check = UnitInRangeCheck
    for unit in next, units do
        cache[unit] = check(unit)
        UpdateRangeIndicator(unit)
    end
end

do
    local origOnEnable = BF.OnEnable
    function BF:OnEnable(...)
        if origOnEnable then origOnEnable(self, ...) end
        -- Grid2 verbatim (StatusRange.lua:224). Without this, a mid-combat
        -- /reload leaves InCombat stuck false for the rest of the fight —
        -- PLAYER_REGEN_DISABLED already fired before the reload and will not
        -- fire again.
        InCombat = InCombatLockdown()
        self:RegisterEvent("SPELLS_CHANGED")
        -- UNIT_IN_RANGE_UPDATE is registered per-unit via Initialization.lua's
        -- perUnitEvents list (mirrors Grid2's RegisterRosterUnitEvent). Do NOT
        -- register it globally here — the global event fires unreliably.
        self:RegisterEvent("GROUP_ROSTER_UPDATE")
        -- Grid2 verbatim (StatusRange.lua:232): registered for 38y range so a
        -- zone change resweeps the roster. UNIT_IN_RANGE_UPDATE does not
        -- reliably fire across a zone transition, so without this grouped units
        -- keep whatever value they held before the loading screen.
        self:RegisterEvent("PLAYER_ENTERING_WORLD")
        -- Grid2 verbatim: Grid_UnitUpdated (StatusRange.lua:173) + Grid_UnitLeft
        -- (StatusRange.lua:181). Updated: recompute cache on identity change
        -- (cross-instance detection — see BF:BF_UnitUpdated above). Left:
        -- clear the range cache for departing units and resync the timer.
        self:RegisterMessage("BF_UnitUpdated")
        self:RegisterMessage("BF_UnitLeft")
        self:UpdatePlayerRangeSpells()
    end
end

-- Grid2 verbatim: Shared:PLAYER_ENTERING_WORLD (StatusRange.lua:189-192)
--   if isLogin or isReload then return end
--   self:UpdateUnits(roster_guids)
-- Sweeps the FULL roster (not roster_external) because grouped units are
-- event-driven and the event does not survive a zone change. Login/reload are
-- skipped: the roster is built after this fires, and RegisterRosterUnit primes
-- each unit as it is added.
do
    local origEnteringWorld = BF.PLAYER_ENTERING_WORLD
    function BF:PLAYER_ENTERING_WORLD(event, isLogin, isReload, ...)
        if origEnteringWorld then origEnteringWorld(self, event, isLogin, isReload, ...) end
        if isLogin or isReload then return end
        self:SyncRangeChecker()
        UpdateUnits(self.roster_guids)
        -- v84: zone-in container resync — engine rebuild for unchanged-token
        -- containers + offline/phase/tracker cache re-prime + visibility gate
        -- re-run. Lives in ContainerFactory; hooked here because this wrapper
        -- already owns the non-login PLAYER_ENTERING_WORLD arm.
        -- v84b (2026-08-15): DEFERRED one frame. Running the resync
        -- synchronously here was too early — LoadLayout (inside the chained
        -- handler above) schedules its deferred tail via C_Timer.After(0),
        -- and that tail's container refreshes (RefreshAllCustomContainers-
        -- WithRebuild etc.) then ran AFTER — and rebuilt over — the resync.
        -- Scheduling ours from here lands it BEHIND the tail in the same-
        -- frame timer queue (FIFO), so the authoritative engine rebuild is
        -- the LAST thing to touch the containers. When the reload gate
        -- skipped LoadLayout (same layout + size: exactly the dungeon→
        -- dungeon case) there is no tail and this is simply the resync one
        -- frame late. Owner-observed victims of the too-early ordering: one
        -- unit with no buffs, sbc single-buff slots missing, and the dispel
        -- OVERLAY slot missing while dispel icons/regular debuffs (group
        -- paths with their own repaint) survived — all shared-host slot
        -- visuals or whole-container state, the exact class only the forced
        -- UpdateAllAuras sweep repairs.
        C_Timer.After(0, function()
            if BF.ResyncAuraContainersAfterZone then
                BF:ResyncAuraContainersAfterZone()
            end
        end)
        -- v84c: SECOND pass a few seconds later. Party members routinely
        -- finish their own loading screens AFTER ours — a rebind performed
        -- while a member is still unreachable binds to a unit the engine
        -- can't resolve yet and stays empty. One delayed sweep catches the
        -- late loaders; cost is one extra rebind wave, out of the hot path.
        C_Timer.After(4, function()
            if BF.ResyncAuraContainersAfterZone then
                BF:ResyncAuraContainersAfterZone()
            end
        end)
    end
end

do
    local origGroupRosterUpdate = BF.GROUP_ROSTER_UPDATE
    function BF:GROUP_ROSTER_UPDATE(...)
        -- Chain to Initialization.lua's handler first (invalidates caches,
        -- announces size change, calls GroupChanged, etc.), then sync the
        -- range checker for the new group state.
        -- NOTE: the chained Initialization.lua GRU handler now defers
        -- GroupChanged (and AnnounceRaidSizeChange / UpdateVisibility /
        -- CheckFitResizeOnRoster / FrameSort) to the next frame via
        -- BF:QueueGroupChanged, to dodge the party<->raid auto-conversion
        -- window where IsInRaid() lags GetNumGroupMembers(). This is safe
        -- for Range because OnGroupTypeChanged only reads GetNumGroupMembers()
        -- — it does not touch _contextIsRaid, _resolvedProfile, or any state
        -- that GroupChanged updates, so running synchronously here (before the
        -- deferred classification) is correct.
        if origGroupRosterUpdate then origGroupRosterUpdate(self, ...) end
        -- Wipe phaseCache on roster changes so stale entries from old unit
        -- token assignments don't cause spurious phase icons on new units.
        wipe(self.phaseCache)
        self:OnGroupTypeChanged()
    end
end

-- ============================================================
-- DEBUG: /bf debugrange
-- Dumps the entire range pipeline so we can see exactly where
-- the data flow breaks.
-- ============================================================
function BF:DebugRange()
    print("|cff00ff00===== BF Range Debug =====|r")

    -- 1. Profile settings. enableRangeFade/rangeFadeAlpha live in
    -- rpDB.profile.healthPower (Core_Migrations.lua:542 moved them there) and
    -- resolve PER-FLAT, so the global shown here is only what a frame inherits
    -- when the healthPower per-layout toggle is off or the flat has no override.
    -- The authoritative per-frame value is what RangeAlpha:Update reads via
    -- GetSectionProfileForFrame. These do NOT gate the range timer.
    do
        local rpp = self.rpDB and self.rpDB.profile
        local hp = rpp and rpp.healthPower
        -- 2026-08-24: healthPower toggles are per-subtab; report the Range
        -- subtab's own toggle (the one these keys follow) plus the coarse
        -- section answer.
        local rangeOn = BF:IsPerLayoutSectionSubtab("healthPower", "range")
        print(string.format("  enableRangeFade (global): %s   rangeFadeAlpha (global): %s",
            tostring(hp and hp.enableRangeFade), tostring(hp and hp.rangeFadeAlpha)))
        print(string.format("  healthPower_range per-layout: %s (any healthPower subtab: %s)%s",
            tostring(rangeOn), tostring(BF:IsPerLayoutSection("healthPower")),
            rangeOn
                and " |cffffcc00(per-flat overrides active — global above may not apply)|r" or ""))
    end
    print(string.format("  _framesActiveForContext: %s", tostring(self._framesActiveForContext)))

    -- 2. Timer state
    print(string.format("  rangeTimer: %s", self.rangeTimer and "RUNNING" or "|cffff0000NIL/STOPPED|r"))

    -- 2b. roster_external — the ONLY thing the timer sweeps, and the sole
    -- determinant of whether the ticker runs at all. Grouped units are
    -- event-driven (UNIT_IN_RANGE_UPDATE) and are intentionally absent here,
    -- so an empty roster_external in a party/raid is CORRECT, not a fault.
    do
        local ext, n = self.roster_external, 0
        local keys = {}
        if ext then for u in next, ext do n = n + 1; keys[#keys+1] = u end end
        print(string.format("  roster_external: %d unit(s) [%s]  (timer sweeps ONLY these)",
            n, table.concat(keys, ", ")))
        print(string.format("  solo: %s (GetNumGroupMembers=%d)",
            tostring(GetNumGroupMembers() == 0), GetNumGroupMembers()))
    end

    -- 3. Spell state
    print(string.format("  spellHostile: %s", tostring(spellHostile)))
    print(string.format("  spellFriendly: %s", tostring(spellFriendly)))

    -- Solo-pet diagnostics. petCheckUnit is 'pet' only while solo AND the class
    -- has a petSpell; it gates both the pet range branch and whether the pet is
    -- polled via roster_external.
    print(string.format("  petSpell: %s  petCheckUnit: %s  GetNumGroupMembers: %s",
        tostring(petSpell), tostring(petCheckUnit), tostring(GetNumGroupMembers())))

    -- 4. roster_guids
    local rg = self.roster_guids
    local rgCount = 0
    if rg then for _ in next, rg do rgCount = rgCount + 1 end end
    print(string.format("  roster_guids: %s (%d units)", rg and "exists" or "|cffff0000NIL|r", rgCount))

    -- 5. frames_of_unit
    local fouCount = 0
    if self.frames_of_unit then
        for u, bucket in next, self.frames_of_unit do
            if rawget(self.frames_of_unit, u) then fouCount = fouCount + 1 end
        end
    end
    print(string.format("  frames_of_unit: %d units with frames", fouCount))

    -- 6. Indicator
    local ind = self.indicators and self.indicators["rangeAlpha"]
    print(string.format("  rangeAlpha indicator: %s", ind and "REGISTERED" or "|cffff0000MISSING|r"))

    -- 7. Range status
    local rs = self.statuses and self.statuses.range
    print(string.format("  range status: %s", rs and "REGISTERED" or "|cffff0000MISSING|r"))

    -- 8. Per-unit data for each active frame
    print("  ── Per-frame range state ──")
    local cache = self.rangeCache
    local check = UnitInRangeCheck
    local count = 0
    for frame in next, (self.activatedFrames or {}) do
        local unit = frame.unit
        if unit then
            count = count + 1
            if count <= 10 then  -- limit output
                local cached = cache and rawget(cache, unit)
                local cachedMeta = cache and cache[unit]  -- triggers metatable
                local live = check and check(unit)
                local isSecret = issecretvalue(cachedMeta)
                local liveSecret = live ~= nil and issecretvalue(live)
                local frameAlpha = frame:GetAlpha()

                -- Range status IsActive result
                local state, invert
                if rs then state, invert = rs:IsActive(unit) end
                local stateSecret = state ~= nil and issecretvalue(state)

                print(string.format("    |cffffcc00%s|r: cached(raw)=%s cached(meta)=%s secret=%s live=%s liveSecret=%s alpha=%.2f state=%s stateSecret=%s invert=%s",
                    unit,
                    tostring(cached),
                    tostring(not isSecret and cachedMeta or "<secret>"),
                    tostring(isSecret),
                    tostring(not liveSecret and live or "<secret>"),
                    tostring(liveSecret),
                    frameAlpha,
                    tostring(not stateSecret and state or "<secret>"),
                    tostring(stateSecret),
                    tostring(invert)
                ))
            end
        end
    end
    if count > 10 then
        print(string.format("    ... and %d more frames", count - 10))
    end
    if count == 0 then
        print("    |cffff0000No activated frames found!|r")
    end

    -- 9. EvaluateColorValueFromBoolean sanity check
    local ecvfb = C_CurveUtil and C_CurveUtil.EvaluateColorValueFromBoolean
    print(string.format("  EvaluateColorValueFromBoolean: %s", ecvfb and "AVAILABLE" or "|cffff0000MISSING|r"))
    if ecvfb then
        local t1 = ecvfb(true, 1, 0.25)
        local t2 = ecvfb(false, 1, 0.25)
        print(string.format("    test(true,1,0.25)=%.2f  test(false,1,0.25)=%.2f", t1, t2))
    end

    print("|cff00ff00============================|r")
end

-- Live trace: prints every range check for one timer cycle
-- Usage: /bfrangetrace
BF._rangeTraceActive = false

function BF:DebugRangeTrace()
    if self._rangeTraceActive then
        print("|cff00ff00[BF] Range trace already active, wait for it to finish|r")
        return
    end
    self._rangeTraceActive = true
    -- NOTE: this is a FULL-ROSTER probe, not a trace of what the timer does.
    -- The timer sweeps only roster_external (the solo pet); grouped units are
    -- driven by UNIT_IN_RANGE_UPDATE. This command evaluates every roster unit
    -- and writes the cache, so it will also repair a stale cache as a side
    -- effect. Use /bfdebugrange to see the timer's actual scope.
    print("|cff00ff00[BF] Range probe: evaluating every roster unit...|r")
    print(string.format("  timer=%s (sweeps roster_external only)  petCheckUnit=%s",
        self.rangeTimer and "RUNNING" or "STOPPED", tostring(petCheckUnit)))

    local cache = self.rangeCache
    local check = UnitInRangeCheck
    local units = self.roster_guids

    if not units then
        print("  |cffff0000roster_guids is NIL — timer has nothing to iterate|r")
        self._rangeTraceActive = false
        return
    end

    local unitCount = 0
    for _ in next, units do unitCount = unitCount + 1 end
    print(string.format("  roster_guids has %d units", unitCount))

    if unitCount == 0 then
        print("  |cffff0000roster_guids is EMPTY — no units registered|r")
        self._rangeTraceActive = false
        return
    end

    -- Run one manual timer cycle with full trace output
    local ind = self.indicators and self.indicators["rangeAlpha"]
    print(string.format("  rangeAlpha indicator: %s", ind and "found" or "|cffff0000MISSING|r"))

    for unit in next, units do
        local new = check(unit)
        local old = rawget(cache, unit)
        local oldMeta = cache[unit]
        local newSec = (new ~= nil) and issecretvalue(new) or false
        local oldSec = (old ~= nil) and issecretvalue(old) or false
        local oldMetaSec = issecretvalue(oldMeta)
        local changed = issecretvalue(new) or issecretvalue(oldMeta) or new ~= oldMeta

        -- Find frame for this unit
        local bucket = self.frames_of_unit and rawget(self.frames_of_unit, unit)
        local frameAlpha = "no_frame"
        if bucket then
            for frame in next, bucket do
                frameAlpha = string.format("%.2f", frame:GetAlpha())
                break
            end
        end

        print(string.format("  |cffffcc00%-10s|r check=%s(sec=%s) rawCache=%s(sec=%s) metaCache=%s(sec=%s) changed=%s frameAlpha=%s",
            unit,
            not newSec and tostring(new) or "<secret>", tostring(newSec),
            not oldSec and tostring(old) or "<secret>", tostring(oldSec),
            not oldMetaSec and tostring(oldMeta) or "<secret>", tostring(oldMetaSec),
            tostring(changed),
            frameAlpha
        ))

        -- Actually update cache + indicator (same as timer would)
        if changed then
            cache[unit] = new
            if ind and bucket then
                for frame in next, bucket do
                    ind:Update(frame, unit)
                    print(string.format("    → updated alpha to %.2f", frame:GetAlpha()))
                end
            end
        end
    end

    self._rangeTraceActive = false
    print("|cff00ff00[BF] Range trace complete|r")
end

SLASH_BFDEBUGRANGE1 = "/bfdebugrange"
SlashCmdList["BFDEBUGRANGE"] = function() BF:DebugRange() end

SLASH_BFRANGETRACE1 = "/bfrangetrace"
SlashCmdList["BFRANGETRACE"] = function() BF:DebugRangeTrace() end

SLASH_BFRANGETOGGLE1 = "/bfrangetoggle"
SlashCmdList["BFRANGETOGGLE"] = function()
    BF._rangeTrace = not BF._rangeTrace
    print("|cff00ff00[BF] Range trace:", BF._rangeTrace and "ON (will spam)" or "OFF", "|r")
end

-- Perf plan §L5.1 load-time mark: opens the 896 KB UnitFrames runtime block (.toc 167-169).
if BuzzardFrames then BuzzardFrames:LoadMark("chunk:preUF") end
