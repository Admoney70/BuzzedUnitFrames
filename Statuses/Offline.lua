-- Grid2: modules/StatusOffline.lua — copied verbatim.
-- Only mechanical substitutions: Grid2 → BF, Grid2:CreateTimer → C_Timer,
-- Grid2:CancelTimer → timer:Cancel(), Grid2:IsPlayerInRaid → BF.roster_guids,
-- Grid_UnitUpdated → BF_UnitUpdated, Grid_UnitLeft → BF_UnitLeft.
-- BF-specific data methods (GetColor, GetPercent) at the bottom.

local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

local Offline = BF.statusPrototype:new("offline")

local next = next
local GetTime = GetTime
local UnitIsConnected = UnitIsConnected
local UnitClass = UnitClass
-- 12.1: a secret class name is truthy but cannot index a table — guard
-- before the BF.classColors[cn] lookup in GetColor.
local canaccessvalue = canaccessvalue or function() return true end

-- cache management variables
local timer
local offline = {}

-- workaround to blizzard bugs
local function TimerEvent()
	local ct = GetTime()
	for unit,dt in next,offline do
		if UnitIsConnected(unit) and (ct-dt)>=25 then
			offline[unit] = nil
			-- Reconnect: re-prime the range cache BEFORE repainting. The
			-- cached value can be stale from before the disconnect and no
			-- UNIT_IN_RANGE_UPDATE fires unless the state actually changes,
			-- so the rangeAlpha repaint (bound to this status) would
			-- otherwise apply a stale in/out-of-range alpha.
			if BF.PrimeRangeForUnit then BF:PrimeRangeForUnit(unit) end
			-- Reconnect: re-run the aura-container visibility gate (the
			-- gate is otherwise UNIT_AURA-driven; see ContainerFactory's
			-- RefreshAuraContainerVisibilityForUnit).
			if BF.RefreshAuraContainerVisibilityForUnit then
				BF:RefreshAuraContainerVisibilityForUnit(unit)
			end
			Offline:UpdateIndicators(unit)
		end
	end
	if not next(offline) then
		if timer then timer:Cancel() end
		timer = nil
	end
end

-- set offline cache
local function SetOfflineCache(unit, off)
	if off then timer = timer or C_Timer.NewTicker(3, TimerEvent) end
	offline[unit] = off and GetTime() or nil
end

-- Blizzard connection API is completelly bugged, this is a mess, behavior at 2019/09/21:
-- UNIT_CONNECTION fires erratically, usually only whe a player is far away, so we have to rely on PARTY_MEMBER_ENABLE & PARTY_MEMBER_DISABLE when in party
-- PARTY_MEMBER_ENABLE & PARTY_MEMBER_DISABLE fire when a player dies, or disconnects, but only if the player is near (visible range)
--  This two events are fired too when the player cross the UnitIsVisible() limit, ENABLE when a player becomes visible, DISABLE in reverse case.
--  We cannot use UnitIsConnected() inside ENABLE events (can returns wrong values too), so we use some heuristic:
--   On ENABLE  we assume the player is connected without any further check.
--   On DISABLE we check UnitIsConnected() (Only works in party, not in raid)
-- This heuristic does not detect all cases.
function Offline:UNIT_CONNECTION(event, unit, hasConnected)
	if BF.roster_guids[unit] then
		if event == 'UNIT_CONNECTION' then -- hasConnected is only available on this event
			self:SetOffline(unit, not hasConnected)
		elseif event == 'PARTY_MEMBER_ENABLE' then -- always connected on this event.
			self:SetOffline(unit, false)
		elseif not UnitIsConnected(unit) then -- PARTY_MEMBER_DISABLE
			self:SetOffline(unit, true)
		end
		-- PARTY_MEMBER_ENABLE/DISABLE also fire when the unit crosses the
		-- UnitIsVisible() boundary (see the heuristic comment above) — and
		-- for a still-connected unit the branches above do nothing, so the
		-- aura-container visibility gate never heard about the crossing and
		-- kept rendering engine junk on non-visible units. Re-run it
		-- unconditionally: it reads UnitIsVisible fresh and its writes are
		-- change-guarded, so a connection-only firing (where SetOffline
		-- already refreshed) is a few table compares. Event-driven — the
		-- phase-boundary events in the Phased status (BFStatus.lua) cover
		-- the raid/instance/shard transitions these party events may miss.
		if BF.RefreshAuraContainerVisibilityForUnit then
			BF:RefreshAuraContainerVisibilityForUnit(unit)
		end
	end
end

function Offline:BF_UnitUpdated(_, unit)
	-- Guard: during roster shuffles, the unit token may not yet resolve
	-- correctly. UnitIsConnected returns nil for non-existent units,
	-- which would incorrectly mark the unit as offline. Skip the check
	-- if the unit doesn't exist — the deferred roster update will
	-- re-evaluate once the roster has settled.
	if not UnitExists(unit) then return end
	-- The player can never be offline from their own perspective.
	if UnitIsUnit(unit, "player") then
		offline[unit] = nil
		return
	end
	local isOff = not UnitIsConnected(unit)
	SetOfflineCache(unit, isOff)
	-- Clear stale dispel caches when newly detected as offline.
	if isOff then
		local S_DISPEL = BF.statuses and BF.statuses.dispel
		if S_DISPEL and S_DISPEL.ClearCachesForUnit then
			S_DISPEL:ClearCachesForUnit(unit)
		end
	end
end

function Offline:BF_UnitLeft(_, unit)
	offline[unit] = nil
end

function Offline:SetOffline(unit, off)
	if not offline[unit] == off then
		SetOfflineCache(unit, off)
		-- Refresh the range cache on BOTH transitions before the bound
		-- indicators (incl. rangeAlpha) repaint — see TimerEvent for why.
		-- The disconnect direction matters for users with fadeOfflineFrames
		-- enabled: their offline frames follow range fading, so the repaint
		-- at disconnect should read a fresh value too, not one cached from
		-- before the disconnect.
		if BF.PrimeRangeForUnit then BF:PrimeRangeForUnit(unit) end
		-- Both transitions: re-run the aura-container visibility gate NOW.
		-- The gate is otherwise UNIT_AURA-driven, and UNIT_AURA goes silent
		-- for a disconnected unit — a cross-faction member's containers
		-- stayed at alpha 1 while the engine repainted them with junk
		-- (offline = assist relation fully degraded). See ContainerFactory's
		-- RefreshAuraContainerVisibilityForUnit.
		if BF.RefreshAuraContainerVisibilityForUnit then
			BF:RefreshAuraContainerVisibilityForUnit(unit)
		end
		-- Clear stale dispel caches when a unit goes offline.
		-- UNIT_AURA never fires for disconnected units, so _dispelColor[unit]
		-- retains a secret color object from a now-invalid aura. Without this,
		-- DebuffHighlight:Update reads the stale color and renders a black overlay.
		if off then
			local S_DISPEL = BF.statuses and BF.statuses.dispel
			if S_DISPEL and S_DISPEL.ClearCachesForUnit then
				S_DISPEL:ClearCachesForUnit(unit)
			end
		end
		self:UpdateIndicators(unit)
	end
end

function Offline:OnEnable()
	self:RegisterEvent("UNIT_CONNECTION")
	self:RegisterEvent('PARTY_MEMBER_ENABLE',  'UNIT_CONNECTION')
	self:RegisterEvent('PARTY_MEMBER_DISABLE', 'UNIT_CONNECTION')
	self:RegisterMessage("BF_UnitUpdated")
	self:RegisterMessage("BF_UnitLeft")
end

function Offline:OnDisable()
	self:UnregisterEvent("UNIT_CONNECTION")
	self:UnregisterEvent('PARTY_MEMBER_ENABLE')
	self:UnregisterEvent('PARTY_MEMBER_DISABLE')
	self:UnregisterMessage("BF_UnitUpdated")
	self:UnregisterMessage("BF_UnitLeft")
	wipe(offline)
end

function Offline:IsActive(unit)
	return offline[unit]~=nil
end

function Offline:GetStartTime(unit)
	return offline[unit]
end

-- BF-specific: GetPercent returns fade alpha from profile
function Offline:GetPercent(unit)
	local p = BF.db and BF.db.profile
	return p and p.rangeFadeAlpha or 0.25
end

-- BF-specific: GetColor returns offline text color from profile.
-- Route via GetSectionProfile("text", …) — pre-v25 this read from
-- BF.db.profile (the CORE profile) but offlineColor /
-- offlineColorUseClassColor live on rpDB.profile.text. Classic
-- data-location bug: set the offline color in the UI, it writes to
-- rp.text, but this reader consults db.profile and always got the
-- default gray. Fixed as part of the v25 text rollout.
function Offline:GetColor(unit)
	local isRaid = BF:ResolveActiveIsRaid()
	local activeFlat = isRaid and BF:GetRaidProfile() or BF:GetActivePartyProfile()
	local tp = BF:GetSectionProfile("text", activeFlat)
	local _, cn = UnitClass(unit)
	if not canaccessvalue(cn) then cn = nil end
	local classColor = tp and tp.offlineColorUseClassColor and cn and BF.classColors and BF.classColors[cn]
	-- Color fallback: prefer class color, then profile offlineColor, then gray
	-- default. Pre-fix this returned a fresh { r=0.5, g=0.5, b=0.5 } table
	-- whenever both class color and profile color were nil.
	local c = classColor or (tp and tp.offlineColor)
	if c then return c.r, c.g, c.b, 1 end
	return 0.5, 0.5, 0.5, 1
end

BF:RegisterStatus(Offline)
