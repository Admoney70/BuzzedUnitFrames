--[[
BuzzardFrames: BFIndicator.lua
Modular indicator framework — mirrors Grid2's GridIndicator.lua.

Each indicator is a table with:
  .name          string   unique key (e.g. "healthbar", "nametext")
  :CanCreate(f)  bool     should this indicator exist on frame f?
  :Create(f)     void     create widgets on frame f
  :Layout(f)     void     position / size widgets on frame f
  :Update(f, u)  void     refresh widget data for unit u on frame f
  :GetFrame(f)   frame    returns the widget on frame f (or nil)

Registration:
  BF:RegisterIndicator(indicator)   adds to sorted + enabled lists
  BF:GetIndicatorsSorted()          returns ordered creation list
  BF:GetIndicatorsEnabled()         returns ordered update list
]]

local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

local next = next
local pairs = pairs
local ipairs = ipairs
local tinsert = table.insert

-- ============================================================
-- INDICATOR STORAGE
-- ============================================================
BF.indicators        = {}   -- name -> indicator
BF.indicatorSorted   = {}   -- ordered list for Create (load order)
BF.indicatorEnabled  = {}   -- ordered list for Layout / Update

-- ============================================================
-- INDICATOR PROTOTYPE
-- ============================================================
local indicatorPrototype = {}
indicatorPrototype.__index = indicatorPrototype

function indicatorPrototype:new(name)
	local e = setmetatable({}, self)
	e.name = name
	return e
end

-- Default implementations — overridden per indicator
function indicatorPrototype:CanCreate(parent)
	return true
end

function indicatorPrototype:Create(parent)
end

function indicatorPrototype:Layout(parent)
end

function indicatorPrototype:Update(parent, unit)
end

-- Grid2 parity: UpdateDB. Called by RefreshIndicatorSettings on
-- every profile/context switch so indicators can re-read cached
-- settings (e.g. register/unregister event handlers).
function indicatorPrototype:UpdateSettings()
end

function indicatorPrototype:GetFrame(parent)
	return parent[self.name]
end

-- ------------------------------------------------------------
-- lazyCreate: opt-in flag for indicators that build their widgets on
-- first use rather than in :Create.
--
-- Every layout pass in the addon is gated on `indicator:GetFrame(frame)`
-- -- the standard "this indicator has nothing on this frame, skip it"
-- test. An indicator whose :Create is a no-op therefore never gets a
-- :Layout call, so it can never build anything: the gate and the lazy
-- build deadlock each other.
--
-- Setting `indicator.lazyCreate = true` makes the gate let :Layout run
-- anyway, so :Layout can decide for itself whether to build. Such an
-- indicator MUST tolerate GetFrame(parent) == nil in Layout, Update and
-- Disable.
--
-- Used by: castBar (the widgets are only built once the user actually
-- enables cast bars, so users who never do pay nothing for them).
-- ------------------------------------------------------------
function BF:ShouldLayoutIndicator(indicator, frame)
	return indicator.lazyCreate or indicator:GetFrame(frame) ~= nil
end

-- Disable: hide the widget (called when indicator is suspended)
function indicatorPrototype:Disable(parent)
	local f = parent[self.name]
	if f and f.Hide then f:Hide() end
end

-- Release: remove widget from frame (called on full teardown)
function indicatorPrototype:Release(parent)
	local f = parent[self.name]
	if f and f ~= parent then
		f:Hide()
		f:ClearAllPoints()
		f:SetParent(nil)
	end
	parent[self.name] = nil
end

-- Convenience: run Layout on every registered frame
function indicatorPrototype:LayoutAllFrames()
	for _, frame in next, BF.registeredFrames do
		if self:GetFrame(frame) then
			self:Layout(frame)
		end
	end
end

-- Convenience: run Update on every activated frame
function indicatorPrototype:UpdateAllFrames()
	for frame, unit in next, BF.activatedFrames do
		self:Update(frame, unit)
	end
end

BF.indicatorPrototype = indicatorPrototype

-- ============================================================
-- DEFERRED (BATCHED) UPDATES — Grid2 IndicatorIcons.lua pattern
--
-- Grid2 reference: IndicatorIcons.lua — updates{}, updateFrame,
-- Icon_Update (mark dirty), Icon_OnFrameUpdate (real work).
--
-- Grid2 iterates per-frame then per-status:
--   for f in next, updates do Icon_OnFrameUpdate(f) end
--   Icon_OnFrameUpdate: for _, status in ipairs(self.statuses) do ...
--
-- BF mirrors this: the outer loop iterates dirty frames; the inner
-- loop iterates deferred indicators in registration order and runs
-- each indicator that is dirty for that frame. This ensures all
-- indicators for a given unit run before moving to the next unit,
-- so cached scratch tables (e.g. _buffResult) are consumed before
-- being overwritten by the next unit's FetchBuffData call.
--
-- Previous (incorrect) approach iterated per-indicator then
-- per-frame, which overwrote shared scratch tables across units
-- before downstream indicators could read them.
-- ============================================================

-- Ordered list of deferred indicators (registration order = load order).
local deferredIndicators = {}  -- { indicator, indicator, ... }

-- Single shared dirty-frame set (Grid2 IndicatorIcons.lua pattern:
-- updates[f] = true). Stores frames only, NOT (frame, unit) pairs.
--
-- The unit is read live from frame.unit at flush time, not captured
-- when mark-dirty was called. This matches Grid2's Icon_OnFrameUpdate
-- (modules/IndicatorIcons.lua:25-27) which reads `local unit = f.myFrame.unit`
-- at the top of every dispatch and bails if nil.
--
-- Why this matters: between mark-dirty and flush, a frame's .unit can
-- change (raid composition shuffle, header re-anchor) or be cleared
-- (SetFrameUnit(nil)). The old design captured the unit at mark-dirty
-- and silently dropped the queued work when frame.unit didn't match
-- at flush -- producing a residual correctness gap where stale widget
-- state could persist on recycled frames. The Grid2 pattern dispatches
-- for whichever unit the frame currently shows, so the next render
-- always reflects live state regardless of what changed between marks.
local dirtyFrames = {}

-- Per-indicator dirty sets. indicator._deferDirty[frame] = true
-- marks that this specific indicator needs to run for this frame.
-- Checked in the inner loop to skip indicators not triggered for
-- a given frame (e.g. UNIT_AURA may only dirty buff indicators,
-- not debuff indicators, for the same frame).

local deferHasPending = false
local deferFrame = CreateFrame("Frame")
deferFrame:Hide()
-- Profiler.lua script-wrap registry: lets '/bf prof' time this OnUpdate.
BF._profFrames = BF._profFrames or {}
BF._profFrames["Indicator defer"] = deferFrame
deferFrame:SetScript("OnUpdate", function()
    deferHasPending = false
    deferFrame:Hide()
    -- Grid2 pattern: iterate frames (outer), indicators (inner).
    -- All indicators for one unit complete before the next unit starts.
    local nInd = #deferredIndicators
    for frame in next, dirtyFrames do
        -- Read the unit live (Grid2 IndicatorIcons.lua:26 pattern).
        -- If the frame has been unassigned (SetFrameUnit(nil) /
        -- header re-anchor without reassignment), skip dispatch but
        -- still clear the per-indicator dirty flags so they don't
        -- leak across recycles.
        local unit = frame.unit
        if unit then
            for i = 1, nInd do
                local ind = deferredIndicators[i]
                if ind._deferDirty[frame] then
                    ind._deferDirty[frame] = nil
                    ind:_DoUpdate(frame, unit)
                end
            end
        else
            for i = 1, nInd do
                deferredIndicators[i]._deferDirty[frame] = nil
            end
        end
    end
    wipe(dirtyFrames)
end)

-- Opt in to deferred updates. Called once per indicator after
-- its Update function is defined (typically at the end of the
-- indicator file, after RegisterIndicator).
-- Stores the real Update as _DoUpdate and replaces Update with
-- a mark-dirty stub.
function indicatorPrototype:EnableDeferredUpdates()
    -- Store original Update as _DoUpdate for direct calls
    -- (e.g. UpdateAllFrames, or manual refresh from options).
    self._DoUpdate = self.Update

    -- Per-indicator dirty set.
    local dirty = {}
    self._deferDirty = dirty
    deferredIndicators[#deferredIndicators + 1] = self

    -- Replace Update with mark-dirty (Grid2 Icon_Update pattern).
    -- Marks both the shared dirtyFrames set and this indicator's
    -- per-indicator dirty set. The `unit` arg is intentionally not
    -- captured -- the flush reads frame.unit live so the dispatch
    -- always reflects the frame's current unit, even if it changed
    -- between mark-dirty and flush.
    self.Update = function(_, frame, unit)
        dirty[frame] = true
        dirtyFrames[frame] = true
        if not deferHasPending then
            deferHasPending = true
            deferFrame:Show()
        end
    end
end

-- Force-flush all pending deferred updates immediately.
-- Called from paths that need indicators to be up-to-date synchronously
-- (e.g. before a screenshot, or during ReloadLayout's deferred tail).
function BF:FlushDeferredIndicatorUpdates()
    if deferHasPending then
        deferFrame:GetScript("OnUpdate")(deferFrame)
    end
end

-- ============================================================
-- REGISTRATION
-- ============================================================
function BF:RegisterIndicator(indicator)
	local name = indicator.name
	if self.indicators[name] then
		-- Already registered — replace in-place
		self.indicators[name] = indicator
		for i, ind in ipairs(self.indicatorSorted) do
			if ind.name == name then self.indicatorSorted[i] = indicator; break end
		end
		for i, ind in ipairs(self.indicatorEnabled) do
			if ind.name == name then self.indicatorEnabled[i] = indicator; break end
		end
		return indicator
	end
	self.indicators[name] = indicator
	tinsert(self.indicatorSorted, indicator)
	tinsert(self.indicatorEnabled, indicator)
	return indicator
end

function BF:UnregisterIndicator(indicator)
	local name = indicator.name
	self.indicators[name] = nil
	for i, ind in ipairs(self.indicatorSorted) do
		if ind.name == name then table.remove(self.indicatorSorted, i); break end
	end
	for i, ind in ipairs(self.indicatorEnabled) do
		if ind.name == name then table.remove(self.indicatorEnabled, i); break end
	end
end

function BF:GetIndicatorByName(name)
	return self.indicators[name]
end

function BF:GetIndicatorsSorted()
	return self.indicatorSorted
end

function BF:GetIndicatorsEnabled()
	return self.indicatorEnabled
end

-- ============================================================
-- DISPATCH HELPERS
-- ============================================================
-- Layout and Update per-frame dispatchers used by Auras.lua refresh
-- paths and other consumers (11 files). The Create-side equivalents
-- (formerly CreateFrameIndicators and CreateAllIndicators) lived here
-- as duplicates of BuzzardFramePrototype:CreateIndicators (BFLayout.lua:535)
-- and BF:CreateAllFrameIndicators (BFLayout.lua:619) — never called
-- from anywhere — and were deleted as part of the per-indicator
-- aura-icon refactor. The frame-prototype versions in BFLayout.lua
-- are the live init wiring.

-- Layout all indicators on a frame (called on resize / profile change)
function BF:LayoutFrameIndicators(frame)
	local indicators = self:GetIndicatorsEnabled()
	for i = 1, #indicators do
		local indicator = indicators[i]
		if BF:ShouldLayoutIndicator(indicator, frame) then
			indicator:Layout(frame)
		end
	end
end

-- Update all indicators on a frame for a unit (called on unit change / event)
function BF:UpdateFrameIndicators(frame, unit)
	if unit then
		local indicators = self:GetIndicatorsEnabled()
		for i = 1, #indicators do
			indicators[i]:Update(frame, unit)
		end
	end
end

-- Grid2 parity (RefreshIndicators with update=true): call UpdateSettings
-- on every enabled indicator so they re-read profile settings and
-- register/unregister event handlers for the new context.
function BF:RefreshIndicatorSettings()
	local indicators = self:GetIndicatorsEnabled()
	for i = 1, #indicators do
		indicators[i]:UpdateSettings()
	end
end

-- Layout indicators on ALL frames in active headers
function BF:LayoutAllIndicators(notify)
	for _, header in ipairs(self.groupsUsed or {}) do
		for _, frame in ipairs(header) do
			self:LayoutFrameIndicators(frame)
		end
	end
	-- Raid-style twins (UnitFrames/Twins.lua) are registered frames with a
	-- unit, but they hang off their own holder rather than a header, so the
	-- groupsUsed walk above never reaches them.
	if self.twinFrames then
		for _, twin in ipairs(self.twinFrames) do
			self:LayoutFrameIndicators(twin)
		end
	end
	if notify then self:SendMessage("BF_UpdateLayoutSize") end
end

-- Update indicators on ALL activated frames
function BF:UpdateAllIndicators()
	for frame in next, self.activatedFrames do
		local unit = frame.unit
		if unit then
			self:UpdateFrameIndicators(frame, unit)
		end
	end
end
