-- ============================================================
-- BuzzardFrames: BFStatus.lua
-- Status prototype + status definitions — Grid2 architecture.
--
-- A "status" represents a piece of unit data (health, power,
-- range, threat, target, name, etc.).  Each status:
--   * provides data methods (IsActive, GetPercent, GetColor, etc.)
--   * knows which indicators are bound to it (self.indicators)
--   * provides UpdateIndicators(unit) which iterates only the
--     bound indicators for all frames showing that unit
--   * will own event registrations (OnEnable/OnDisable) in Phase 5
--
-- Indicators call status data methods to get their display values
-- rather than calling WoW APIs directly. This allows any future
-- indicator to bind to an existing status and get data from it.
-- ============================================================

local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")
local next = next
local pairs = pairs
local rawget = rawget

-- WoW API upvalues
local UnitExists              = UnitExists
local UnitHealth              = UnitHealth
local UnitHealthMax           = UnitHealthMax
local UnitHealthPercent       = UnitHealthPercent
local UnitHealthMissing       = UnitHealthMissing
local UnitPowerType           = UnitPowerType
local UnitPowerPercent        = UnitPowerPercent
local UnitClass               = UnitClass
local UnitName                = UnitName
local UnitIsUnit              = UnitIsUnit
local UnitIsDeadOrGhost       = UnitIsDeadOrGhost
local UnitIsGhost             = UnitIsGhost
local UnitIsAFK               = UnitIsAFK
local UnitCanAttack           = UnitCanAttack
local UnitIsVisible           = UnitIsVisible
local UnitExists              = UnitExists
local UnitThreatSituation     = UnitThreatSituation
local UnitGroupRolesAssigned  = UnitGroupRolesAssigned
local UnitIsGroupLeader       = UnitIsGroupLeader
local UnitIsGroupAssistant    = UnitIsGroupAssistant
local UnitHasVehicleUI        = UnitHasVehicleUI
local UnitUsingVehicle        = UnitUsingVehicle
local UnitInVehicle           = UnitInVehicle
local UnitPhaseReason         = UnitPhaseReason
local GetRaidTargetIndex      = GetRaidTargetIndex
local GetReadyCheckStatus     = GetReadyCheckStatus
local GetSpecialization       = GetSpecialization
local GetSpecializationRole   = GetSpecializationRole
local UnitGetTotalAbsorbs     = UnitGetTotalAbsorbs
local UnitGetTotalHealAbsorbs = UnitGetTotalHealAbsorbs

-- ============================================================
-- 12.1 SECRET-VALUE SANITIZER
-- Several Unit APIs (UnitClass, UnitGroupRolesAssigned, UnitPhaseReason,
-- UnitIsGroupLeader/Assistant, ...) return SECRET values when the unit's
-- identity is secret (PvP / secret units). A secret cannot be branched
-- on, compared, or used as a table key — doing so hard-errors. Sanitize
-- at the CAPTURE site so downstream logic never sees a secret; the
-- substituted default is the safe display fallback ("don't know" ⇒
-- default color / no icon / not phased).
-- ============================================================
local issecretvalue = issecretvalue
local function NotSecretOr(v, default)
    if issecretvalue(v) then return default end
    return v
end
local UnitGetDetailedHealPrediction = UnitGetDetailedHealPrediction
local UnitHasIncomingResurrection = UnitHasIncomingResurrection
local AbbreviateLargeNumbers  = AbbreviateLargeNumbers
local issecretvalue           = issecretvalue  or function() return false end
local canaccessvalue          = canaccessvalue or function() return true  end
local ScaleTo100              = CurveConstants and CurveConstants.ScaleTo100

BF.statuses = {}   -- name -> status

-- ============================================================
-- STATUS PROTOTYPE
-- ============================================================
local statusProto = {}
statusProto.__index = statusProto

function statusProto:new(name)
	local e = setmetatable({}, self)
	LibStub("AceEvent-3.0"):Embed(e)
	e.name          = name
	e.indicators    = {}   -- indicator -> true  (hash for O(1) lookup)
	e.indicatorList = {}   -- indicator array    (ordered for deterministic iteration)
	e.enabled       = false
	return e
end

-- Grid2 pattern: UpdateIndicators(unit)
-- Uses indicatorList (ordered array) instead of pairs(self.indicators)
-- so that execution order is deterministic. Grid2 uses pairs() because
-- its indicators are independent; BF keeps the ordered list so any future
-- data dependency between indicators bound to the same status is
-- expressible. (v67: the original reason — BuffIcons populating the
-- BuffMatch cache before BuffHighlight read it — no longer exists; both
-- that producer and that consumer are gone.)
function statusProto:UpdateIndicators(unit)
	local fou = BF.frames_of_unit
	if not fou then return end
	local bucket = rawget(fou, unit)
	if bucket then
		local list = self.indicatorList
		for parent in next, bucket do
			for i = 1, #list do
				list[i]:Update(parent, unit)
			end
		end
	end
end

-- Grid2 pattern: RegisterIndicator
-- Adds to both hash (O(1) lookup) and ordered array (deterministic iteration).
function statusProto:RegisterIndicator(indicator)
	if not self.indicators[indicator] then
		self.indicators[indicator] = true
		self.indicatorList[#self.indicatorList + 1] = indicator
		if not self.enabled then
			self.enabled = true
			if self.OnEnable then self:OnEnable() end
		end
	end
end

-- Grid2 pattern: UnregisterIndicator
function statusProto:UnregisterIndicator(indicator)
	if self.indicators[indicator] then
		self.indicators[indicator] = nil
		-- Remove from ordered list
		local list = self.indicatorList
		for i = #list, 1, -1 do
			if list[i] == indicator then
				table.remove(list, i)
				break
			end
		end
		if not next(self.indicators) then
			self.enabled = false
			if self.OnDisable then self:OnDisable() end
		end
	end
end

-- Default data methods — overridden per status
function statusProto:IsActive(unit) return false end
function statusProto:GetPercent(unit) return 0 end
function statusProto:GetColor(unit) return 0, 0, 0, 1 end
function statusProto:GetText(unit) return "" end
function statusProto:OnEnable() end
function statusProto:OnDisable() end

-- Grid2 pattern: embed RegisterRosterUnitEvent / UnregisterRosterUnitEvent
-- so statuses can call self:RegisterRosterUnitEvent(event, handler).
-- These are runtime lookups because BF.RegisterRosterUnitEvent is defined
-- in Initialization.lua which loads after BFStatus.lua.
function statusProto:RegisterRosterUnitEvent(event, method)
	BF.RegisterRosterUnitEvent(self, event, method)
end
function statusProto:UnregisterRosterUnitEvent(event)
	BF.UnregisterRosterUnitEvent(self, event)
end

BF.statusPrototype = statusProto

-- ============================================================
-- getTextProfile: route text-section reads via the cached section
-- profile (Perf 1A). Used by status :GetColor methods (Death, Flags)
-- that read text-section color keys. See Core_ProfileAPI.lua's
-- GetCachedSection contract. Invalidated by InvalidateRaidProfileCache
-- on every context change, so correctness matches the old inline
-- GetRaidProfile / GetActivePartyProfile + GetSectionProfile chain.
-- ============================================================
local function getTextProfile()
	return BF:GetCachedSection("text")
end

-- ============================================================
-- STATUS REGISTRATION
-- ============================================================
function BF:RegisterStatus(statusObj)
	self.statuses[statusObj.name] = statusObj
	return statusObj
end

function BF:GetStatusByName(name)
	return self.statuses[name]
end


-- ============================================================
-- ============================================================
--
--              INDIVIDUAL STATUS DEFINITIONS
--
-- Each status provides data methods that any indicator can call.
-- Grid2 equivalent: modules/Status*.lua files.
--
-- ============================================================
-- ============================================================


-- ============================================================
-- STATUS: health
-- Grid2: StatusHealth.lua
-- Data: health values, class color, dead/alive state
-- ============================================================
local Health = statusProto:new("health")

-- Color curves for health-based gradients (Grid2 StatusHealth.lua pattern).
-- UnitHealthPercent(unit, true, curve) evaluates the curve at the unit's
-- health percent and returns a secret-safe color via :GetRGBA().
-- Grid2 ref: StatusHealth.lua Health.colorCurve + Health:UpdateDB()
local healthGradientCurve = C_CurveUtil.CreateColorCurve()
local bgGradientCurve     = C_CurveUtil.CreateColorCurve()

local function BuildGradientCurve(curve, lowColor, midColor, highColor)
	curve:ClearPoints()
	curve:SetType(Enum.LuaCurveType.Linear)
	curve:AddPoint(0,   CreateColor(lowColor.r,  lowColor.g,  lowColor.b,  lowColor.a  or 1))
	curve:AddPoint(0.5, CreateColor(midColor.r,  midColor.g,  midColor.b,  midColor.a  or 1))
	curve:AddPoint(1,   CreateColor(highColor.r, highColor.g, highColor.b, highColor.a or 1))
end

function BF:RebuildHealthGradientCurves()
	-- Gradient COLORS are global (rpDB.profile.colors); the useHealthGradient
	-- / useBgGradient TOGGLES remain per-layout in healthPower.
	local cp = self.rpDB and self.rpDB.profile and self.rpDB.profile.colors
	local hp = self:GetCachedSection("healthPower")
	      or (self.rpDB and self.rpDB.profile and self.rpDB.profile.healthPower)
	if not cp then return end
	-- Build the health gradient curve when EITHER the raid/party toggle or
	-- either unit frames dropdown is set to "gradient".
	local ufp = self.ufDB and self.ufDB.profile
	local ufGradient = ufp and (
		(ufp.globalPlayerHealthColorMode or "class") == "gradient" or
		(ufp.globalNpcHealthColorMode or "classification") == "gradient" or
		(ufp.separatePlayerFrameColor and (ufp.playerFrameHealthColorMode or "class") == "gradient")
	)
	if (hp and hp.useHealthGradient) or ufGradient then
		BuildGradientCurve(healthGradientCurve,
			cp.healthGradientLow, cp.healthGradientMid, cp.healthGradientHigh)
	end
	local ufBgGradient = ufp and ufp.oufUseCustomBackgroundColor
		and (ufp.oufBackgroundColorMode or "static") == "gradient"
	if (hp and hp.useBgGradient) or ufBgGradient then
		BuildGradientCurve(bgGradientCurve,
			cp.bgGradientLow, cp.bgGradientMid, cp.bgGradientHigh)
	end
end

-- Expose curves for HealthBar indicator (bg gradient)
BF.healthGradientCurve = healthGradientCurve
BF.bgGradientCurve     = bgGradientCurve

function Health:IsActive(unit)
	return unit and UnitExists(unit)
end

function Health:GetHealth(unit)
	return UnitHealth(unit)
end

function Health:GetMaxHealth(unit)
	return UnitHealthMax(unit)
end

function Health:GetPercent(unit)
	return UnitHealthPercent(unit, true)
end

function Health:GetPercentText(unit)
	return UnitHealthPercent(unit, true, ScaleTo100)
end

function Health:GetMissing(unit)
	return UnitHealthMissing(unit)
end

function Health:GetMissingText(unit)
	return AbbreviateLargeNumbers(UnitHealthMissing(unit))
end

function Health:GetCurrentText(unit)
	return AbbreviateLargeNumbers(UnitHealth(unit))
end

-- ============================================================
-- GetClassHealthColor(r, g, b, hasCustomTexture)
--
-- Single source of truth for the darkening/desaturation applied
-- to class colors on health bars.
--
-- When the bar uses the default flat-white texture (WHITE8X8),
-- raw class colors look oversaturated compared to Blizzard's
-- default raid frames. A brightness + desaturation pass brings
-- them in line.
--
-- When the user has selected a custom SharedMedia texture, the
-- texture's own shading provides visual depth and the darkening
-- makes the bar too dim, so we return the raw color.
--
-- Both the raid/party frames (Health:GetColor below) and the oUF
-- unit frames (oUF_Shared.lua _GetOUFHealthColor) call this.
-- ============================================================
function BF:GetClassHealthColor(r, g, b, hasCustomTexture)
    if hasCustomTexture then
        return r, g, b
    end
    local brightness = 0.7
    local desat      = 0.90
    return r * desat * brightness,
           g * desat * brightness,
           b * desat * brightness
end

-- Returns r, g, b for the health bar based on profile settings.
-- Encapsulates class color, custom color, hostile color logic.
-- Optional `frame` parameter enables per-frame section resolution
-- (CFG overrides, per-layout). Callers that have a frame reference
-- (e.g. HealthBarColor:Update) should pass it so CFG frames read
-- from their own healthPower section instead of the global.
function Health:GetColor(unit, frame)
	-- Use the cached section profile so per-layout healthPower settings
	-- (including useCustomHealthBarTexture) are respected. Falls back
	-- to the global when per-layout is OFF.
	local hp = BF:GetCachedSection("healthPower", frame)
	      or (BF.rpDB and BF.rpDB.profile and BF.rpDB.profile.healthPower)
	if not hp then return 0.24, 0.78, 0.24, 1 end

	-- 2026-08-27: HOSTILE FIRST. A mind-controlled / charmed member must read
	-- hostile regardless of how bars are otherwise painted (custom color,
	-- gradient or class). This used to sit BELOW the custom-health-color
	-- branch, so any flat resolving useCustomHealthColor = true silently
	-- disabled the hostile color -- which is how the 08-24 per-subtab
	-- toggle split (flat data now reachable where the global used to answer)
	-- turned it off in the field with no code change on this path.
	if hp.useCustomHostileColor and UnitCanAttack("player", unit) then
		local c = hp.hostileColor
		if c then return c.r, c.g, c.b, 1 end
		return 0.624, 0.027, 0.043, 1   -- Defaults_RaidPartyFrames hostileColor
	end

	if hp.useCustomHealthColor then
		if hp.useHealthGradient then
			-- Gradient colors are global; always use the single global curve.
			return UnitHealthPercent(unit, true, healthGradientCurve):GetRGBA()
		end
		local c = hp.healthColor
		return c.r, c.g, c.b, 1
	else
		local r, g, b = self:GetClassColor(unit, hp.useCustomHealthBarTexture)
		return r, g, b, 1
	end
end

-- ============================================================
-- Health:GetClassColor(unit, hasCustomTexture)
--
-- Single source of truth for resolving a unit's class color for
-- health-bar painting. Returns r, g, b (no alpha) and applies the
-- GetClassHealthColor darkening/desaturation unless hasCustomTexture
-- is true. Used by Health:GetColor (fill, class mode) and by the
-- HealthBar background class-color mode (which always passes
-- hasCustomTexture=false so the bg is always darkened).
-- ============================================================
function Health:GetClassColor(unit, hasCustomTexture)
	-- Resolve to owner for pet units so pet frames get the
	-- owner's class color when class colors are enabled.
	local classUnit = BF.owner_of_unit and BF.owner_of_unit[unit] or unit
	local _, className = UnitClass(classUnit)
	className = NotSecretOr(className, nil)  -- 12.1: secret identity ⇒ default color
	-- Grid2 pattern: prefer CUSTOM_CLASS_COLORS (addon-overridden palette)
	-- then fall back to RAID_CLASS_COLORS. BF.classColors is populated in
	-- OnEnable from RAID_CLASS_COLORS only, so look up the live global tables
	-- directly here to avoid a timing gap at startup.
	--
	-- EXCEPTION: when the user has turned on "Use Custom Class Colors"
	-- in the Colors nav, BF.classColors contains their overrides overlaid
	-- on RAID_CLASS_COLORS. In that mode we MUST read from BF.classColors
	-- so the raid/party health bars match the Unit Frames (which always
	-- read from BF.classColors). When the toggle is off, BF.classColors
	-- equals RAID_CLASS_COLORS and we keep the live-globals path so any
	-- external class-color addon (phanxClassColors, etc.) still wins.
	if className then
		local cp = BF.rpDB and BF.rpDB.profile and BF.rpDB.profile.colors
		local useCustom = cp and cp.useCustomClassColors
		local src
		if useCustom then
			src = BF.classColors and BF.classColors[className]
		end
		if not src then
			src = (CUSTOM_CLASS_COLORS and CUSTOM_CLASS_COLORS[className])
			   or (RAID_CLASS_COLORS  and RAID_CLASS_COLORS[className])
		end
		if src then
			return BF:GetClassHealthColor(src.r, src.g, src.b, hasCustomTexture)
		end
	end
	return 0.24, 0.78, 0.24
end

-- Returns className for the unit (cached on frame by HealthBar indicator)
function Health:GetClass(unit)
	-- Resolve to owner for pet units so pet frames get the
	-- owner's class for class-colored health bars.
	local classUnit = BF.owner_of_unit and BF.owner_of_unit[unit] or unit
	local _, className = UnitClass(classUnit)
	return NotSecretOr(className, nil)  -- 12.1: secret identity ⇒ nil (default color)
end

-- Grid2 pattern: register per-unit events when indicators are bound.
-- Health owns UNIT_HEALTH and UNIT_MAXHEALTH only. UNIT_PORTRAIT_UPDATE
-- moved to the classcolor status (Perf 3B / Grid2 StatusColor.lua pattern).
-- Before 3B, Health owned UNIT_PORTRAIT_UPDATE too, but the class-color
-- split means color updates flow through classcolor -> healthBarColor,
-- so Health firing UNIT_PORTRAIT_UPDATE is redundant (Health is now value-
-- only; its bound indicators don't need class info).
function Health:OnEnable()
	self:RegisterRosterUnitEvent("UNIT_HEALTH",    function(_, ev, unit, ...) BF:UNIT_HEALTH(ev, unit, ...) end)
	self:RegisterRosterUnitEvent("UNIT_MAXHEALTH",  function(_, ev, unit, ...) BF:UNIT_MAXHEALTH(ev, unit, ...) end)
end
function Health:OnDisable()
	self:UnregisterRosterUnitEvent("UNIT_HEALTH")
	self:UnregisterRosterUnitEvent("UNIT_MAXHEALTH")
end

BF:RegisterStatus(Health)


-- ============================================================
-- STATUS: classcolor
-- Grid2: StatusColor.lua (ClassColor)
-- Data: triggers color updates when class info becomes available or
-- when fixed-color profile settings change.
--
-- Grid2 splits ClassColor from Health so that UNIT_HEALTH only fires
-- value-update work, never color-update work. BF's Perf 3B mirrors
-- that: classcolor owns UNIT_PORTRAIT_UPDATE (late-arriving class
-- data) and is the sidekick binding for the color indicator. The
-- eager color cache (class/custom/hostile color) is computed lazily
-- by Health:GetColor at display time -- this status provides the
-- trigger, not the data.
--
-- Note: when healthBarColor is also bound to the `health` status
-- (gradient mode ON), UNIT_HEALTH will fire color updates through
-- that binding. classcolor's bindings are independent and fire
-- additionally on UNIT_PORTRAIT_UPDATE regardless of gradient mode.
-- ============================================================
local ClassColor = statusProto:new("classcolor")

function ClassColor:IsActive(unit)
	return unit and UnitExists(unit)
end

-- v86 (event refactor stage 1): roster-scoped repaint. One handler for all
-- four events -- they differ only in what made the unit's color stale.
function ClassColor:OnRosterUnitEvent(event, unit)
	if not self.enabled then return end
	if unit and BF.roster_guids and BF.roster_guids[unit] then
		self:UpdateIndicators(unit)
	end
end

function ClassColor:OnEnable()
	-- v86 (event refactor stage 1): this used to build a dedicated
	-- CreateFrame because "BF:RegisterEvent only allows one method handler
	-- per event on the addon object". True of the BF object -- Role owns
	-- UNIT_PORTRAIT_UPDATE and Flags owns UNIT_FLAGS there -- but
	-- irrelevant here: CallbackHandler keys callbacks by the REGISTERING
	-- OBJECT (events[event][self]), and statusProto:new embeds AceEvent on
	-- every status (see :new above). So each status is already its own
	-- listener and can hold any event without clobbering a sibling. The
	-- private frame bought nothing and made this one of 27 hand-rolled
	-- event frames, each re-deriving its own unit-scope contract -- the
	-- pattern that produced the PLAYER_SPECIALIZATION_CHANGED bug.
	--
	-- Event set mirrors Grid2's StatusColor.lua Shared:OnEnable
	-- (UNIT_CLASSIFICATION_CHANGED, UNIT_PORTRAIT_UPDATE, UNIT_FLAGS,
	-- UNIT_FACTION). Roster-guid guard matches Grid2's Shared:UpdateUnit.
	self:RegisterEvent("UNIT_CLASSIFICATION_CHANGED", "OnRosterUnitEvent")
	self:RegisterEvent("UNIT_PORTRAIT_UPDATE",        "OnRosterUnitEvent")
	self:RegisterEvent("UNIT_FLAGS",                  "OnRosterUnitEvent")
	self:RegisterEvent("UNIT_FACTION",                "OnRosterUnitEvent")
end

function ClassColor:OnDisable()
	-- Explicit per-event teardown rather than UnregisterAllEvents. Both are
	-- correct today, but the blunt form silently kills any future
	-- conditional subscription this status might take, and it stops naming
	-- what it owns. Unregistering an event that is not registered is a no-op.
	self:UnregisterEvent("UNIT_CLASSIFICATION_CHANGED")
	self:UnregisterEvent("UNIT_PORTRAIT_UPDATE")
	self:UnregisterEvent("UNIT_FLAGS")
	self:UnregisterEvent("UNIT_FACTION")
end

-- Called by RefreshProfileCache hook (see below) to push a color
-- refresh when the user flips useCustomHealthColor / useCustomHostileColor
-- / healthColor / hostileColor / useHealthGradient / useBgGradient.
-- Since these don't fire any WoW unit events, we sweep all activated
-- frames and call UpdateIndicators for each.
function ClassColor:UpdateAllUnits()
	if not self.enabled then return end
	local activatedFrames = BF.activatedFrames
	if activatedFrames then
		for _, unit in pairs(activatedFrames) do
			if unit then self:UpdateIndicators(unit) end
		end
	end
end

BF:RegisterStatus(ClassColor)

-- Hook RefreshProfileCache so toggling fg-color-related settings pushes
-- a color refresh through the classcolor binding. Mirrors the Range
-- status's hooksecurefunc pattern further down.
hooksecurefunc(BF, "RefreshProfileCache", function(self)
	ClassColor:UpdateAllUnits()
end)


-- ============================================================
-- STATUS: power
-- Grid2: StatusMana.lua
-- Data: power values, power type, power color
-- ============================================================
local Power = statusProto:new("power")

-- Resto Druids should always show mana on the power bar, even in
-- cat/bear form. Grid2's mana status uses UnitPower(unit, 0) to
-- always read mana regardless of current power type. We replicate
-- that by checking if the unit is a healer druid and forcing
-- powerType 0 (Mana) in GetPercent and GetColor.

local function GetEffectivePowerType(unit)
	local powerType = UnitPowerType(unit)
	if powerType and powerType ~= 0 then
		local _, className = UnitClass(unit)
		className = NotSecretOr(className, nil)  -- 12.1: secret identity ⇒ no druid special-case
		if className == "DRUID" then
			local role = NotSecretOr(UnitGroupRolesAssigned(unit), "NONE")
			if role == "HEALER" then
				return 0
			end
			if UnitIsUnit(unit, "player") then
				local spec = GetSpecialization()
				if spec and GetSpecializationRole(spec) == "HEALER" then
					return 0
				end
			end
		end
	end
	return powerType
end

-- `frame` is optional and forwarded for parity with BF:ShouldShowPowerBar.
function Power:IsActive(unit, frame)
	return unit and UnitExists(unit) and BF.ShouldShowPowerBar and BF:ShouldShowPowerBar(unit, frame)
end

-- PERF: GetPercent/GetColor/GetPowerType accept an optional pre-resolved
-- effective power type. PowerBar:Update calls all three per power event —
-- without the pass-through each recomputed GetEffectivePowerType
-- (UnitPowerType + the druid class/role probe), i.e. 3x per tick per unit.
-- Omitting the argument keeps the old behavior for every other caller.
function Power:GetPercent(unit, powerType)
	powerType = powerType or GetEffectivePowerType(unit)
	if not powerType then return 0 end
	-- When forcing mana for a healer druid in shapeshift form:
	-- Player: use "player" token directly (always accessible).
	-- Party member: check if the value is accessible; if not, return
	-- nil so the indicator skips the update and keeps the last value.
	if powerType == 0 and UnitPowerType(unit) ~= 0 then
		if UnitIsUnit(unit, "player") then
			return UnitPowerPercent("player", 0, false)
		end
		local pct = UnitPowerPercent(unit, 0, false)
		if not canaccessvalue(pct) then return nil end
		return pct
	end
	return UnitPowerPercent(unit, powerType, false)
end

function Power:GetPowerType(unit)
	return GetEffectivePowerType(unit)
end

function Power:GetColor(unit, powerType)
	powerType = powerType or GetEffectivePowerType(unit)
	if powerType == 0 then
		local c = BF.PowerTypeColors.MANA
		return c.r, c.g, c.b, c.a or 1
	end
	return BF:GetPowerColor(unit)
end

-- Grid2 pattern: power events only registered when power bar indicator is bound.
function Power:OnEnable()
	self:RegisterRosterUnitEvent("UNIT_POWER_UPDATE",  function(_, ev, unit, ...) BF:UNIT_POWER_UPDATE(ev, unit, ...) end)
	self:RegisterRosterUnitEvent("UNIT_MAXPOWER",      function(_, ev, unit, ...) BF:UNIT_MAXPOWER(ev, unit, ...) end)
	self:RegisterRosterUnitEvent("UNIT_DISPLAYPOWER",  function(_, ev, unit, ...) BF:UNIT_DISPLAYPOWER(ev, unit, ...) end)
end
function Power:OnDisable()
	self:UnregisterRosterUnitEvent("UNIT_POWER_UPDATE")
	self:UnregisterRosterUnitEvent("UNIT_MAXPOWER")
	self:UnregisterRosterUnitEvent("UNIT_DISPLAYPOWER")
end

BF:RegisterStatus(Power)


-- ============================================================
-- STATUS: druidMana
-- Shows mana as a secondary resource for healer druids in form.
-- Grid2 equivalent: StatusMana.lua with displayType=2 (secondary only).
-- Active only for the player when they are a healer druid in a
-- non-mana shapeshift form (cat, bear, travel, moonkin with astral).
-- ============================================================
local DruidMana = statusProto:new("druidMana")

function DruidMana:IsActive(unit)
	if not unit or not UnitExists(unit) then return false end
	local ufp = BF.ufDB and BF.ufDB.profile
	if not ufp or not ufp.showAltPowerBar then return false end
	-- Only active for the player's own unit
	if not UnitIsUnit(unit, "player") then return false end
	-- Only when current power type is NOT mana (i.e. in a form)
	if UnitPowerType(unit) == 0 then return false end
	-- Must be a druid
	local _, className = UnitClass("player")
	if className ~= "DRUID" then return false end
	-- Must be healer spec
	local role = UnitGroupRolesAssigned("player")
	if role == "HEALER" then return true end
	local spec = GetSpecialization()
	if spec and GetSpecializationRole(spec) == "HEALER" then return true end
	return false
end

function DruidMana:GetPercent(unit)
	return UnitPowerPercent("player", 0, false)
end

function DruidMana:GetColor(unit)
	local c = BF.PowerTypeColors and BF.PowerTypeColors.MANA
	if c then return c.r, c.g, c.b, c.a or 1 end
	return 0, 0, 0.8, 1
end

-- OnEnable/OnDisable not needed: the druid mana bar is updated from
-- the oUF Power PostUpdate, not from its own event registrations.
function DruidMana:OnEnable() end
function DruidMana:OnDisable() end

BF:RegisterStatus(DruidMana)


-- ============================================================
-- STATUS: range
-- Grid2: StatusRange.lua
-- Data: in-range boolean, fade alpha
-- Note: Range.lua already manages BF.rangeCache and calls
-- UpdateRangeIndicator. This status provides the data interface.
-- ============================================================
-- Grid2 verbatim: StatusRange
local Range = statusProto:new("range")

-- Grid2 verbatim: curAlpha stores the configured fade opacity
Range.curAlpha = 0.25

-- Grid2 verbatim: IsActiveR
function Range:IsActive(unit)
	return BF.rangeCache[unit], true
end

-- Grid2 verbatim: GetPercent returns curAlpha
function Range:GetPercent()
	return self.curAlpha
end

-- Grid2 pattern: range event only registered when range indicator is bound.
function Range:OnEnable()
	self:RegisterRosterUnitEvent("UNIT_IN_RANGE_UPDATE", function(_, ev, unit, ...) BF:UNIT_IN_RANGE_UPDATE(ev, unit, ...) end)
end
function Range:OnDisable()
	self:UnregisterRosterUnitEvent("UNIT_IN_RANGE_UPDATE")
end

BF:RegisterStatus(Range)

-- Update curAlpha from profile when settings change
hooksecurefunc(BF, "RefreshProfileCache", function(self)
	-- Per-layout aware: use the cached section profile so per-flat
	-- rangeFadeAlpha is respected. Falls back to global when per-layout
	-- is OFF or cache is not yet populated.
	local hp = self:GetCachedSection("healthPower")
	      or (self.rpDB and self.rpDB.profile and self.rpDB.profile.healthPower)
	if hp then
		Range.curAlpha = hp.rangeFadeAlpha or 0.25
	end
end)


-- ============================================================
-- STATUS: threat
-- Grid2: StatusThreat.lua
-- Data: threat level (0-3)
-- ============================================================
local Threat = statusProto:new("threat")

function Threat:IsActive(unit)
	if not unit or not UnitExists(unit) then return false end
	-- A dead unit holds no threat. UNIT_THREAT_SITUATION_UPDATE does not
	-- reliably fire on death, so without this the highlight lingers until
	-- some unrelated event refreshes the frame. Dead state is read from the
	-- death status (its cache), never from the unit APIs; aggroHighlight is
	-- bound to that status so the transition itself repaints it.
	local deathStatus = BF.statuses and BF.statuses.death
	if deathStatus and deathStatus:IsActive(unit) then return false end
	local status = UnitThreatSituation(unit)
	return status and status > 0
end

function Threat:GetThreatLevel(unit)
	return UnitThreatSituation(unit) or 0
end

function Threat:GetColor(unit)
	local level = UnitThreatSituation(unit) or 0
	if level >= 3 then return 1, 0, 0, 1          -- securely tanking
	elseif level >= 2 then return 1, 0.5, 0, 1    -- insecure
	elseif level >= 1 then return 1, 0.94, 0, 1   -- high threat
	else return 0, 0, 0, 0 end
end

function Threat:OnEnable()
	BF:RegisterEvent("UNIT_THREAT_SITUATION_UPDATE", function(_, unit)
		if self.enabled then self:UpdateIndicators(unit) end
	end)
	-- v92 PERF: the UNIT_HEALTH dead-transition tracker that lived here
	-- (per-tick UnitGUID + dead-state read + a GUID-keyed _deadSeen cache
	-- on the addon's hottest event) is DELETED. Its job — clearing a
	-- lingering highlight on a corpse, since death fires no
	-- UNIT_THREAT_SITUATION_UPDATE — is covered by binding aggroHighlight
	-- to the death status (see BindIndicators), which repaints it once on
	-- every alive<->dead transition; Threat:IsActive reads the death
	-- status' cache and reports no threat for a dead unit.
end

function Threat:OnDisable()
	BF:UnregisterEvent("UNIT_THREAT_SITUATION_UPDATE")
end

BF:RegisterStatus(Threat)


-- ============================================================
-- STATUS: absorbs
-- Grid2: StatusShields.lua
-- Data: total absorb amount
-- ============================================================
local Absorbs = statusProto:new("absorbs")

function Absorbs:IsActive(unit)
	if not unit or not UnitExists(unit) then return false end
	local val = UnitGetTotalAbsorbs(unit)
	return val and val > 0
end

function Absorbs:GetAmount(unit)
	return UnitGetTotalAbsorbs(unit) or 0
end

function Absorbs:GetMaxHealth(unit)
	return UnitHealthMax(unit)
end

-- Grid2 pattern: absorb events only registered when absorb indicator is bound.
function Absorbs:OnEnable()
	self:RegisterRosterUnitEvent("UNIT_ABSORB_AMOUNT_CHANGED", function(_, ev, unit, ...) BF:UNIT_ABSORB_AMOUNT_CHANGED(ev, unit, ...) end)
end
function Absorbs:OnDisable()
	self:UnregisterRosterUnitEvent("UNIT_ABSORB_AMOUNT_CHANGED")
end

BF:RegisterStatus(Absorbs)


-- ============================================================
-- STATUS: shieldsOverflow
-- Grid2: StatusShields.lua ("shields-overflow")
--
-- Registers UNIT_HEALTH only when at least one indicator is bound to it.
-- The absorb overlay's damage-absorb bar clamping depends on the current
-- missing-health gap, which changes on every UNIT_HEALTH tick. Without
-- this status, BF:UNIT_HEALTH had to call _UpdateAbsorbOverlayHealth on
-- every frame on every health tick even when absorb bars were disabled.
--
-- Now the cost is paid only when the absorb indicator is actually bound
-- (via BF:RebindAbsorbStatuses, which checks showAbsorbsMissingHealth).
-- When absorbs are off in all flats, UNIT_HEALTH never dispatches here.
-- ============================================================
local ShieldsOverflow = statusProto:new("shieldsOverflow")

function ShieldsOverflow:IsActive(unit)
	return unit and UnitExists(unit)
end

function ShieldsOverflow:OnEnable()
	self:RegisterRosterUnitEvent("UNIT_HEALTH", function(_, ev, unit, ...)
		if ShieldsOverflow.enabled then ShieldsOverflow:UpdateIndicators(unit) end
	end)
end

function ShieldsOverflow:OnDisable()
	self:UnregisterRosterUnitEvent("UNIT_HEALTH")
end

BF:RegisterStatus(ShieldsOverflow)


-- ============================================================
-- STATUS: reducedmaxhealth
-- Temporary reduced max health modifier (e.g. M+ affixes).
-- Uses UNIT_MAX_HEALTH_MODIFIERS_CHANGED which only fires when
-- the modifier percentage actually changes — not on every
-- UNIT_HEALTH or UNIT_ABSORB_AMOUNT_CHANGED.
-- ============================================================
local ReducedMaxHealth = statusProto:new("reducedmaxhealth")

function ReducedMaxHealth:IsActive(unit)
	if not GetUnitTotalModifiedMaxHealthPercent then return false end
	local pct = GetUnitTotalModifiedMaxHealthPercent(unit)
	if not pct or issecretvalue(pct) then return false end
	return pct > 0
end

function ReducedMaxHealth:OnEnable()
	-- Cache indicator lookups once at enable time (not per-event).
	local absorbInd = BF:GetIndicatorByName("absorbBars")
	local textInd   = BF:GetIndicatorByName("reducedMaxHealthText")
	self:RegisterRosterUnitEvent("UNIT_MAX_HEALTH_MODIFIERS_CHANGED", function(_, ev, unit)
		-- Targeted calls: only update reduced max health bar + text.
		-- Does NOT run heal prediction, absorb overlay, or heal absorb.
		local bucket = BF.frames_of_unit and rawget(BF.frames_of_unit, unit)
		if bucket then
			for f in pairs(bucket) do
				if f.unit == unit then
					if absorbInd and absorbInd._UpdateReducedMaxHealth then
						absorbInd:_UpdateReducedMaxHealth(f, unit)
					end
					if textInd then textInd:Update(f, unit) end
				end
			end
		end
	end)
end
function ReducedMaxHealth:OnDisable()
	self:UnregisterRosterUnitEvent("UNIT_MAX_HEALTH_MODIFIERS_CHANGED")
end

BF:RegisterStatus(ReducedMaxHealth)


-- ============================================================
-- STATUS: healabsorb
-- Grid2: (part of StatusHealAbsorbs.lua)
-- Data: total heal absorb amount
-- ============================================================
local HealAbsorb = statusProto:new("healabsorb")

function HealAbsorb:IsActive(unit)
	if not unit or not UnitExists(unit) then return false end
	local val = UnitGetTotalHealAbsorbs(unit)
	return val and val > 0
end

function HealAbsorb:GetAmount(unit)
	return UnitGetTotalHealAbsorbs(unit) or 0
end

function HealAbsorb:OnEnable()
	self:RegisterRosterUnitEvent("UNIT_HEAL_ABSORB_AMOUNT_CHANGED", function(_, ev, unit, ...) BF:UNIT_HEAL_ABSORB_AMOUNT_CHANGED(ev, unit, ...) end)
end
function HealAbsorb:OnDisable()
	self:UnregisterRosterUnitEvent("UNIT_HEAL_ABSORB_AMOUNT_CHANGED")
end

BF:RegisterStatus(HealAbsorb)


-- ============================================================
-- STATUS: healprediction
-- Grid2: StatusHealth.lua (heals-incoming)
-- Data: incoming heal amount
-- ============================================================
local HealPrediction = statusProto:new("healprediction")

function HealPrediction:IsActive(unit)
	return unit and UnitExists(unit)
end

function HealPrediction:GetIncomingHeals(unit)
	if not BF.HealthCalc then return 0 end
	UnitGetDetailedHealPrediction(unit, "player", BF.HealthCalc)
	local _, incoming = BF.HealthCalc:GetIncomingHeals()
	return incoming or 0
end

function HealPrediction:OnEnable()
	self:RegisterRosterUnitEvent("UNIT_HEAL_PREDICTION", function(_, ev, unit, ...) BF:UNIT_HEAL_PREDICTION(ev, unit, ...) end)
end
function HealPrediction:OnDisable()
	self:UnregisterRosterUnitEvent("UNIT_HEAL_PREDICTION")
end

BF:RegisterStatus(HealPrediction)


-- ============================================================
-- STATUS: name
-- Grid2: StatusName.lua
-- Data: unit name (with vehicle remapping)
-- ============================================================
local Name = statusProto:new("name")

-- Grid2 verbatim: StatusName.lua:8 `Name.IsActive = Grid2.statusLibrary.IsActive`,
-- which is a literal `return true` (GridUtils.lua:221-223). The name status is
-- ALWAYS active in Grid2 — there is no condition under which it reports inactive.
--
-- Do NOT gate this on UnitExists. That was the first-login blank-name bug:
--   1. At a cold login UnitExists("player") is transiently false, so this
--      returned false and NameText.lua:262-266 wrote fs:SetText("") — a
--      destructive blank with no Grid2 analog.
--   2. The player is the ONLY unit whose UnitName is a plain string; every other
--      unit's is a secret value in 12.0, so they short-circuit at
--      NameText.lua:299 (issecretvalue -> unconditional SetText) and never reach
--      the blanking branches at all.
--   3. Worse, Initialization.lua:1030 treats a secret name as unconditionally
--      `modified`, so every other unit gets a free repaint on EVERY roster sweep
--      and self-heals from a bad first paint within a frame. The player's plain
--      name only repaints if it actually CHANGES — and it never does, because
--      RegisterRosterUnit already seeded roster_names["player"] with it.
-- Net: the player was blanked once and never repainted. /reload masked it because
-- UnitExists is true from the first paint.
--
-- UnitExists is also unguarded against secret values here, unlike the
-- canaccessvalue() wrappers NameText uses a few lines later for
-- UnitIsDeadOrGhost/UnitIsAFK.
function Name:IsActive()
	return true
end

-- ============================================================
-- Grid2 verbatim: strCyr2Lat (GridUtils.lua:170-184).
-- gsub with a Cyrillic-pair mapping; non-Cyrillic text passes through
-- unchanged. canaccessvalue-guarded: secret strings are returned as-is.
-- ============================================================
local strCyr2Lat
do
	local gsub = string.gsub
	local canaccessvalue = canaccessvalue or function() return true end
	local Cyr2Lat = {
		["А"] = "A", ["а"] = "a", ["Б"] = "B", ["б"] = "b", ["В"] = "V", ["в"] = "v", ["Г"] = "G", ["г"] = "g", ["Д"] = "D", ["д"] = "d", ["Е"] = "E",
		["е"] = "e", ["Ё"] = "e", ["ё"] = "e", ["Ж"] = "Zh", ["ж"] = "zh", ["З"] = "Z", ["з"] = "z", ["И"] = "I", ["и"] = "i", ["Й"] = "Y", ["й"] = "y",
		["К"] = "K", ["к"] = "k", ["Л"] = "L", ["л"] = "l", ["М"] = "M", ["м"] = "m", ["Н"] = "N", ["н"] = "n", ["О"] = "O", ["о"] = "o", ["П"] = "P",
		["п"] = "p", ["Р"] = "R", ["р"] = "r", ["С"] = "S", ["с"] = "s", ["Т"] = "T", ["т"] = "t", ["У"] = "U", ["у"] = "u", ["Ф"] = "F", ["ф"] = "f",
		["Х"] = "Kh", ["х"] = "kh", ["Ц"] = "Ts", ["ц"] = "ts", ["Ч"] = "Ch", ["ч"] = "ch", ["Ш"] = "Sh", ["ш"] = "sh", ["Щ"] = "Shch",	["щ"] = "shch",
		["Ъ"] = "", ["ъ"] = "", ["Ы"] = "Y", ["ы"] = "y", ["Ь"] = "", ["ь"] = "", ["Э"] = "E", ["э"] = "e", ["Ю"] = "Yu", ["ю"] = "yu", ["Я"] = "Ya",
		["я"] = "ya"
	}
	strCyr2Lat = function(str)
		return canaccessvalue(str) and gsub(str, "..", Cyr2Lat) or str
	end
end
BF.strCyr2Lat = strCyr2Lat -- exposed for preview code

-- ============================================================
-- Composed name-text entries — Grid2's UpdateDB closure swap
-- (StatusName.lua:48-55), adapted for BF's per-flat profile model.
--
-- Grid2 resolves name options into module upvalues once in UpdateDB
-- because ONE profile serves all frames. BF resolves the text section
-- PER FRAME (GetSectionProfileForFrame): custom-frame-group frames can
-- render alongside raid/party frames with DIFFERENT text settings, so a
-- single set of module upvalues cannot work (refactor review, blocker B1).
--
-- Instead: compose a closure per SECTION TABLE and memoize by table
-- identity (weak-keyed). Frames sharing a flat share one entry; CFG flats
-- get their own. Per paint this costs one memoized section lookup (as
-- today) plus one table read — zero per-paint composition or branching,
-- which is the entire point of Grid2's pattern.
--
-- Invalidation: section tables are long-lived AceDB tables mutated in
-- place by the options UI, so entries MUST be dropped when options
-- change. Wired into RefreshProfileCache (below) and RefreshAllNames
-- (LayoutFrame.lua) — the two funnels all text-option setters already
-- call. Entries are plain caches; wiping is always safe.
-- ============================================================
local composedName = setmetatable({}, { __mode = "k" })
local issecret_c = issecretvalue or function() return false end

local function BuildComposedName(tp)
	-- Grid2 GetText1/GetText2 shapes (StatusName.lua:15-22).
	-- defaultName: nil on default config, exactly like Grid2's shipped
	-- DbSetStatusDefaultValue("name", {type="name"}) — parity, not a fix.
	local defaultName = tp.defaultName
	local getText
	if tp.transliterateCyrillicNames then
		getText = function(unit)
			local name = UnitName(unit)
			return (name and strCyr2Lat(name)) or (defaultName == 1 and unit) or defaultName
		end
	else
		getText = function(unit)
			return UnitName(unit) or (defaultName == 1 and unit) or defaultName
		end
	end
	-- BF-only extra, same composition pattern: capitalize.
	if tp.capitalizeNames then
		local base = getText
		getText = function(unit)
			local name = base(unit)
			if name and not issecret_c(name) then return name:upper() end
			return name
		end
	end

	local entry = {
		getText           = getText,
		-- Truncation is GATED on abbreviateNames (default false), unlike
		-- Grid2's unconditional textlength cut — porting the Grid2 shape
		-- ungated would clip every name to maxNameChars' default of 9
		-- (refactor review, blocker B3).
		maxChars          = (tp.abbreviateNames and (tp.maxNameChars or 99)) or nil,
		showName          = tp.showName ~= false,
		append            = tp.appendStatusTextToNames or false,
		showAFK           = tp.showAFKStatus or false,
		adjustColors      = tp.adjustNameColors or false,
		classColor        = tp.classColorNames or false,
		nameColor         = tp.nameColor, -- table ref or nil
		applyStatusColors = tp.applyStatusColorsToNames or false,
		translit          = tp.transliterateCyrillicNames or false,
		-- Color-companion keys (nameText color consolidation — plan 2.3/3.4):
		fadeOfflineName   = tp.fadeOfflineNameText or false,
		offlineUseClass   = tp.offlineColorUseClassColor or false,
		offlineColor      = tp.offlineColor,  -- table ref or nil
		deadUseClass      = tp.deadColorUseClassColor or false,
		deadColor         = tp.deadColor,     -- table ref or nil
	}
	composedName[tp] = entry
	return entry
end

function Name:GetComposed(tp)
	return composedName[tp] or BuildComposedName(tp)
end

function BF:InvalidateComposedNameText()
	wipe(composedName)
end

hooksecurefunc(BF, "RefreshProfileCache", function()
	wipe(composedName)
end)

-- Kept for external compatibility; NameText resolves per-frame pet
-- semantics itself now (frame-cached, no per-paint scan).
function Name:GetText(unit)
	local owner = BF.owner_of_unit and BF.owner_of_unit[unit]
	return UnitName(owner or unit) or ""
end

function Name:GetClass(unit)
	-- For class color purposes, always resolve to the owner
	-- (pets don't have a player class, but we want the owner's
	-- class color on pet frame headers).
	local nameUnit = BF.owner_of_unit and BF.owner_of_unit[unit] or unit
	local _, className = UnitClass(nameUnit)
	return NotSecretOr(className, nil)  -- 12.1: secret identity ⇒ nil (default color)
end

function Name:GetClassColor(unit)
	local className = self:GetClass(unit)
	if className and BF.classColors and BF.classColors[className] then
		local c = BF.classColors[className]
		return c.r, c.g, c.b, 1
	end
	return 1, 1, 1, 1
end

-- Status-level handler: refreshes only indicators bound to `name`
-- (nameText, roleIcon). Mirrors Grid2's StatusName.lua Name:UNIT_NAME_UPDATE
-- VERBATIM — registered via the per-unit roster event system
-- (RegisterRosterUnitEvent), exactly like every other per-unit status in
-- this file (health, power, range, absorbs, ...). Because the event is
-- registered on the unit's own frame at roster-join time
-- (RegisterRosterUnit → RegisterUnitEventFrame), it only ever fires for
-- units already in the roster, so it needs NO roster_guids guard.
--
-- Fix: the previous implementation diverged from Grid2 by registering on
-- the global AceEvent bus (self:RegisterEvent) and bolting on a
-- `BF.roster_guids[unit]` guard. At a fresh login the player's OWN
-- UNIT_NAME_UPDATE could fire before the player was added to roster_guids,
-- so the guard dropped the event and nothing ever repainted the name —
-- the player's name stayed blank on his raid/party frame until /reload.
-- Grid2 never has this problem because per-unit registration happens as
-- part of the join, guaranteeing delivery of the player's first name update.
function Name:UNIT_NAME_UPDATE(_, unit)
	self:UpdateIndicators(unit)
end

function Name:OnEnable()
	self:RegisterRosterUnitEvent("UNIT_NAME_UPDATE")
end

function Name:OnDisable()
	self:UnregisterRosterUnitEvent("UNIT_NAME_UPDATE")
end

BF:RegisterStatus(Name)


-- ============================================================
-- STATUS: target
-- Grid2: StatusTarget.lua
-- Data: is-target boolean
-- ============================================================
local Target = statusProto:new("target")

local _targetUnit = nil     -- cached displayed unit token of the current target
                            -- (Grid2 StatusTarget pattern; mirrors _leaderUnit)

function Target:IsActive(unit)
	return unit and UnitExists(unit) and UnitIsUnit(unit, "target")
end

-- Scan the displayed units for the one that is the player's target.
-- One cheap UnitIsUnit identity check per frame — same call IsActive
-- already relies on. Returns nil when the target is off-frame (enemy,
-- NPC, nobody).
local function CalculateTarget()
	if not UnitExists("target") then return nil end
	local activatedFrames = BF.activatedFrames
	if not activatedFrames then return nil end
	for frame, unit in pairs(activatedFrames) do
		-- Skip raid-style twins. The target twin's token IS "target", so it
		-- would win this scan for every target and _targetUnit would never
		-- change -- the prev/new diff in the event handler would then early
		-- out and no frame would ever repaint its highlight. Twins draw no
		-- highlight anyway (Indicators/TargetHighlight.lua).
		if unit and not frame._bf_twinKey and UnitIsUnit(unit, "target") then
			return unit
		end
	end
	return nil
end

function Target:OnEnable()
	BF:RegisterEvent("PLAYER_TARGET_CHANGED", function()
		if not self.enabled then return end
		-- PERF (scoped refresh): a target swap changes is-target state on at
		-- most two displayed units — the previous target and the new one.
		-- The old handler dispatched UpdateIndicators for EVERY activated
		-- frame (full TargetHighlight repaint × 40 frames, several times a
		-- second while tab-targeting). Same prev/new diff the Leader status
		-- uses below (UpdateLeader). Retargeting the same unit, or swapping
		-- between off-frame enemies (the most common combat case), is a
		-- no-op after the identity scan.
		local newTarget = CalculateTarget()
		local prev = _targetUnit
		if newTarget == prev then return end
		_targetUnit = newTarget
		if prev then self:UpdateIndicators(prev) end
		if newTarget then self:UpdateIndicators(newTarget) end
	end)
	_targetUnit = CalculateTarget()
end

function Target:OnDisable()
	BF:UnregisterEvent("PLAYER_TARGET_CHANGED")
	_targetUnit = nil
end

BF:RegisterStatus(Target)


-- STATUS: offline is defined in Statuses/Offline.lua (separate file)


-- ============================================================
-- STATUS: death
-- Data: dead/ghost state from BF.unitWasDeadCache, the ONE dead-state
-- cache:  unit -> "Dead" | "Ghost" | false | nil
--
-- One event, one cache. UNIT_HEALTH re-reads the unit and only a CHANGE
-- writes the cache and broadcasts BF_UnitDeadUpdated; this status'
-- own subscriber then repaints its BOUND indicators. 99% of UNIT_HEALTH
-- events are health ticks, not death transitions, so the common path is
-- one API read plus one table compare.
--
-- The cache is seeded when a unit is added to the roster and refreshed
-- when the roster sweep detects a new occupant on a token (both in
-- Initialization.lua), and nil'd when the unit leaves — so a unit that was
-- already dead at /reload reads dead without waiting for a tick.
--
-- IsActive/GetState are pure cache reads. Consumers read THEM; they must
-- not read the dead/ghost APIs or per-frame render state for this.
-- ============================================================
local Death = statusProto:new("death")

-- Returns "Dead", "Ghost" or false. The single dead-state reader: nothing
-- else in the death path touches the unit APIs.
local function UnitDeadState(unit)
	return UnitIsDeadOrGhost(unit) and (UnitIsGhost(unit) and "Ghost" or "Dead") or false
end
-- Exposed for the roster seed in Initialization.lua (loads after this file).
BF.UnitDeadState = UnitDeadState

function Death:IsActive(unit)
	return not not BF.unitWasDeadCache[unit]
end

-- Returns "Dead", "Ghost", or nil
function Death:GetState(unit)
	return BF.unitWasDeadCache[unit] or nil
end

function Death:GetColor(unit)
	local tp = getTextProfile()
	-- Per-layout aware: route through cached section profile so per-flat
	-- useCustomDeadColor is respected.
	local hp = BF:GetCachedSection("healthPower")
	      or (BF.rpDB and BF.rpDB.profile and BF.rpDB.profile.healthPower)
	local _, cn = UnitClass(unit)
	cn = NotSecretOr(cn, nil)  -- 12.1: secret identity ⇒ profile/default color
	local classColor = tp and tp.deadColorUseClassColor and cn and BF.classColors and BF.classColors[cn]
	-- Color fallback: class color first, then profile deadColor (gated on
	-- useCustomDeadColor), then red default. Pre-fix this returned a fresh
	-- { r=0.8, g=0.1, b=0.1 } table on every call where both were nil.
	local c = classColor or (hp and hp.useCustomDeadColor and tp and tp.deadColor)
	if c then return c.r, c.g, c.b, 1 end
	return 0.8, 0.1, 0.1, 1
end

-- The only writer of the dead-state cache. Change-guarded: a plain health
-- tick costs one read and one compare and stops here.
function Death:UNIT_HEALTH(_, unit)
	local d = UnitDeadState(unit)
	if d ~= BF.unitWasDeadCache[unit] then
		BF.unitWasDeadCache[unit] = d
		BF:SendMessage("BF_UnitDeadUpdated", unit, d)
	end
end

function Death:BF_UnitDeadUpdated(_, unit)
	self:UpdateIndicators(unit)
end

function Death:OnEnable()
	self:RegisterRosterUnitEvent("UNIT_HEALTH")
	self:RegisterMessage("BF_UnitDeadUpdated")
end

function Death:OnDisable()
	self:UnregisterRosterUnitEvent("UNIT_HEALTH")
	self:UnregisterMessage("BF_UnitDeadUpdated")
end

BF:RegisterStatus(Death)


-- ============================================================
-- STATUS: flags (AFK, DND)
-- Grid2: StatusAFK.lua
-- Data: AFK state
-- ============================================================
local Flags = statusProto:new("flags")

function Flags:IsActive(unit)
	return self:IsAFK(unit)
end

function Flags:IsAFK(unit)
	if not UnitIsAFK then return false end
	local v = UnitIsAFK(unit)
	return canaccessvalue(v) and v == true
end

function Flags:GetColor(unit)
	local tp = getTextProfile()
	local _, cn = UnitClass(unit)
	cn = NotSecretOr(cn, nil)  -- 12.1: secret identity ⇒ profile/default color
	local classColor = tp and tp.afkColorUseClassColor and cn and BF.classColors and BF.classColors[cn]
	-- Color fallback: class color first, then profile afkColor, then yellow
	-- default. Pre-fix this returned a fresh { r=0.8, g=0.6, b=0 } table
	-- on every call where both were nil.
	local c = classColor or (tp and tp.afkColor)
	if c then return c.r, c.g, c.b, 1 end
	return 0.8, 0.6, 0, 1
end

local function FlagsHandler(_, unit)
	if not Flags.enabled then return end
	Flags:UpdateIndicators(unit)
end

function Flags:OnEnable()
	BF:RegisterEvent("UNIT_FLAGS", FlagsHandler)
	BF:RegisterEvent("PLAYER_FLAGS_CHANGED", FlagsHandler)
end

function Flags:OnDisable()
	BF:UnregisterEvent("UNIT_FLAGS")
	BF:UnregisterEvent("PLAYER_FLAGS_CHANGED")
end

BF:RegisterStatus(Flags)


-- ============================================================
-- STATUS: raidicon
-- Grid2: StatusRaidIcon.lua
-- Data: raid target index (1-8 or nil)
-- ============================================================
local RaidIcon = statusProto:new("raidicon")

-- NOTE (perf review follow-up): a per-unit marker-index diff was tried here
-- and REVERTED — GetRaidTargetIndex returns a SECRET number under addon
-- taint (12.1), so index values can be truth-tested and passed to render
-- APIs but never compared. RAID_TARGET_UPDATE therefore cannot be scoped to
-- changed units; the full dispatch below is the correct behavior.

function RaidIcon:IsActive(unit)
	return unit and UnitExists(unit) and GetRaidTargetIndex(unit) ~= nil
end

function RaidIcon:GetIndex(unit)
	return GetRaidTargetIndex(unit)
end

function RaidIcon:OnEnable()
	BF:RegisterEvent("RAID_TARGET_UPDATE", function()
		if not self.enabled then return end
		local activatedFrames = BF.activatedFrames
		if activatedFrames then
			for frame, unit in pairs(activatedFrames) do
				self:UpdateIndicators(unit)
			end
		end
	end)
end

function RaidIcon:OnDisable()
	BF:UnregisterEvent("RAID_TARGET_UPDATE")
end

BF:RegisterStatus(RaidIcon)


-- ============================================================
-- STATUS: leader
-- Grid2: StatusRole.lua (leader portion)
-- Data: leader/assistant state
-- Grid2 pattern: tracks a single raidLeader variable. On PARTY_LEADER_CHANGED,
-- CalculateLeader() scans the roster to find the one unit where
-- UnitIsGroupLeader() is true. Updates indicators only on the previous
-- leader and the new leader. IsActive checks unit == raidLeader.
-- This prevents transient double-leader display during roster transitions
-- (e.g. leaving delves) where UnitIsGroupLeader may briefly return true
-- for multiple units.
-- ============================================================
local Leader = statusProto:new("leader")

local _leaderUnit = nil     -- cached leader unit token (Grid2: raidLeader)

-- 12.1: UnitIsGroupLeader/UnitIsGroupAssistant return secret booleans for
-- identity-secret units — sanitize to false (no crown/assist icon).
local function IsGroupLeaderSafe(unit)
    return NotSecretOr(UnitIsGroupLeader(unit), false) and true or false
end
local function IsGroupAssistantSafe(unit)
    return NotSecretOr(UnitIsGroupAssistant(unit), false) and true or false
end

-- Raid-style twins are excluded from the leader scan so _leaderUnit only
-- ever holds a ROSTER token. Otherwise the same person shown twice (raid
-- frame + twin) could park the cache on the twin's token, and the raid
-- frame -- comparing unit == _leaderUnit -- would drop its crown and read
-- as an assistant. Twins answer from the API instead (IsTwinToken below).
local function CalculateLeader()
    local activatedFrames = BF.activatedFrames
    if not activatedFrames then return nil end
    for frame, unit in pairs(activatedFrames) do
        if unit and not frame._bf_twinKey and UnitExists(unit) and IsGroupLeaderSafe(unit) then
            return unit
        end
    end
    return nil
end

-- True when this token is displayed by a LIVE twin. IsLeader/IsAssistant get
-- a token, not a frame, so the test has to be token-side. "player" in a party
-- is shared by the party frame and the player twin, but the direct API is
-- the right answer for both, so routing that token here changes nothing.
-- _bf_twinActive, not the map lookup: BF:GetTwinFrame keeps returning a
-- built-once twin after its option is turned off, and that stale hit would
-- cost the party player frame its _leaderUnit cache for the rest of the
-- session. Package A sets the flag on activation and clears it on teardown.
local function IsTwinToken(unit)
    local t = unit and BF.GetTwinFrame and BF:GetTwinFrame(unit)
    return (t ~= nil and t._bf_twinActive == true) and true or false
end

function Leader:IsActive(unit)
    return unit and UnitExists(unit) and (IsGroupLeaderSafe(unit) or IsGroupAssistantSafe(unit))
end

function Leader:IsLeader(unit)
    -- Twin tokens are never the cached leader (CalculateLeader skips them),
    -- so they must read the API or a twin would never show the crown.
    if IsTwinToken(unit) then
        return IsGroupLeaderSafe(unit)
    end
    -- Use the cached leader when available (prevents transient double-leader
    -- during roster transitions). Fall back to live API when cache is empty
    -- (e.g. during initial frame population before events fire).
    if _leaderUnit then
        return unit == _leaderUnit
    end
    return IsGroupLeaderSafe(unit)
end

function Leader:IsAssistant(unit)
    if IsTwinToken(unit) then
        return IsGroupAssistantSafe(unit) and not IsGroupLeaderSafe(unit)
    end
    if _leaderUnit then
        return unit ~= _leaderUnit and IsGroupAssistantSafe(unit)
    end
    return IsGroupAssistantSafe(unit) and not IsGroupLeaderSafe(unit)
end

-- Grid2 pattern: UpdateLeader recalculates and updates only affected frames.
local function UpdateLeader()
    local prevLeader = _leaderUnit
    _leaderUnit = CalculateLeader()
    if _leaderUnit ~= prevLeader then
        if prevLeader then Leader:UpdateIndicators(prevLeader) end
        if _leaderUnit then Leader:UpdateIndicators(_leaderUnit) end
    end
    -- Also refresh all activated frames for assistant changes.
    -- Assistants use the live API so this just triggers indicator redraws.
    local activatedFrames = BF.activatedFrames
    if activatedFrames then
        for _, unit in pairs(activatedFrames) do
            if unit ~= _leaderUnit and unit ~= prevLeader then
                Leader:UpdateIndicators(unit)
            end
        end
    end
end

function Leader:OnLeaderEvent()
    if not self.enabled then return end
    UpdateLeader()
end

function Leader:OnEnable()
    -- v86 (event refactor stage 1): the dedicated frame existed to "avoid
    -- conflicting with BF:RegisterEvent handlers for GROUP_ROSTER_UPDATE".
    -- The conflict is real on the BF object, but CallbackHandler keys
    -- callbacks by the registering object, and statusProto:new embeds
    -- AceEvent on every status -- so this status registering
    -- GROUP_ROSTER_UPDATE cannot touch BF's own handler. Both are called.
    --
    -- Ordering note: this is one of five GROUP_ROSTER_UPDATE listeners and
    -- AceEvent dispatch order is hash order. That is not a new hazard --
    -- the previous frame had no ordering guarantee against BF's handler
    -- either -- and UpdateLeader depends on nothing the others produce.
    self:RegisterEvent("PARTY_LEADER_CHANGED", "OnLeaderEvent")
    self:RegisterEvent("GROUP_ROSTER_UPDATE",  "OnLeaderEvent")
    _leaderUnit = CalculateLeader()
end

function Leader:OnDisable()
    self:UnregisterEvent("PARTY_LEADER_CHANGED")
    self:UnregisterEvent("GROUP_ROSTER_UPDATE")
    _leaderUnit = nil
end

BF:RegisterStatus(Leader)


-- ============================================================
-- STATUS: role
-- Grid2: StatusRole.lua (dungeon-role)
-- Data: TANK/HEALER/DAMAGER/NONE
--
-- Grid2 pattern (verbatim): DungeonRole:UpdateAllUnits is the generic
-- statusLibrary.UpdateAllUnits sweep -- walk every activated unit and
-- call UpdateIndicators unconditionally. PLAYER_ROLES_ASSIGNED fires
-- with no unit arg so we have no way to know which specific unit changed;
-- the sweep is the simplest correct behavior.
-- ============================================================
local Role = statusProto:new("role")

function Role:IsActive(unit)
	local role = self:GetRole(unit)
	return role and role ~= "NONE"
end

function Role:GetRole(unit)
	if not unit or not UnitExists(unit) then return "NONE" end
	local roleUnit = BF.owner_of_unit and BF.owner_of_unit[unit] or unit
	local role = NotSecretOr(UnitGroupRolesAssigned(roleUnit), "NONE")  -- 12.1: secret identity ⇒ no icon
	-- Solo: infer from spec
	if (not role or role == "NONE") and UnitIsUnit(roleUnit, "player") then
		local specIndex = GetSpecialization()
		if specIndex then
			role = GetSpecializationRole(specIndex)
		end
	end
	return role or "NONE"
end

-- Grid2 pattern: dungeon-role listens to Grid_PlayerRolesAssigned
-- which is sent from the core PLAYER_ROLES_ASSIGNED handler.
-- BF's PLAYER_ROLES_ASSIGNED handler (Initialization.lua) calls
-- Role:UpdateAllUnits() to sweep all frames, matching Grid2's pattern.
-- UNIT_PORTRAIT_UPDATE is kept as a secondary per-unit trigger.
function Role:UpdateAllUnits()
	if not self.enabled then return end
	local activatedFrames = BF.activatedFrames
	if activatedFrames then
		for _, unit in pairs(activatedFrames) do
			if unit then self:UpdateIndicators(unit) end
		end
	end
end

function Role:OnEnable()
	BF:RegisterEvent("UNIT_PORTRAIT_UPDATE", function(_, unit)
		if self.enabled then self:UpdateIndicators(unit) end
	end)
end

function Role:OnDisable()
	BF:UnregisterEvent("UNIT_PORTRAIT_UPDATE")
end

BF:RegisterStatus(Role)


-- ============================================================
-- STATUS: readycheck
-- Grid2: StatusReadyCheck.lua
-- Data: ready check status string
-- ============================================================
local ReadyCheck = statusProto:new("readycheck")

function ReadyCheck:IsActive(unit)
	return unit and GetReadyCheckStatus(unit) ~= nil
end

function ReadyCheck:GetStatus(unit)
	return GetReadyCheckStatus(unit)
end

local function ReadyCheck_UpdateAll()
	if not ReadyCheck.enabled then return end
	local activatedFrames = BF.activatedFrames
	if activatedFrames then
		for frame, unit in pairs(activatedFrames) do
			ReadyCheck:UpdateIndicators(unit)
		end
	end
end

function ReadyCheck:OnEnable()
	BF:RegisterEvent("READY_CHECK", ReadyCheck_UpdateAll)
	BF:RegisterEvent("READY_CHECK_CONFIRM", function(_, unit)
		if self.enabled then self:UpdateIndicators(unit) end
	end)
	BF:RegisterEvent("READY_CHECK_FINISHED", function()
		ReadyCheck_UpdateAll()
		-- Force-restart hide timers on all frames
		for frame in pairs(BF.activeFrames or {}) do
			if frame.unit and frame.readyCheckCachedStatus then
				if frame.readyCheckHideTimer then
					frame.readyCheckHideTimer:Cancel()
					frame.readyCheckHideTimer = nil
				end
				frame.readyCheckHideTimer = C_Timer.NewTimer(10, function()
					frame.readyCheckIcon:Hide()
					frame.readyCheckCachedStatus = nil
					frame.readyCheckHideTimer = nil
				end)
			end
		end
	end)
end

function ReadyCheck:OnDisable()
	BF:UnregisterEvent("READY_CHECK")
	BF:UnregisterEvent("READY_CHECK_CONFIRM")
	BF:UnregisterEvent("READY_CHECK_FINISHED")
end

BF:RegisterStatus(ReadyCheck)


-- ============================================================
-- STATUS: resurrect
-- Grid2: StatusRes.lua
-- Data: incoming resurrection
-- ============================================================
local Resurrect = statusProto:new("resurrect")

function Resurrect:IsActive(unit)
	return unit and UnitHasIncomingResurrection and UnitHasIncomingResurrection(unit)
end

function Resurrect:OnEnable()
	BF:RegisterEvent("INCOMING_RESURRECT_CHANGED", function(_, unit)
		if self.enabled then self:UpdateIndicators(unit) end
	end)
end

function Resurrect:OnDisable()
	BF:UnregisterEvent("INCOMING_RESURRECT_CHANGED")
end

BF:RegisterStatus(Resurrect)


-- ============================================================
-- STATUS: phased
-- Grid2: StatusPhased.lua
-- Data: phase reason (cached, polled on a 1s timer)
--
-- Mirrors Grid2's pattern exactly:
--   • Cache updated on UNIT_PHASE, UNIT_FLAGS, UNIT_OTHER_PARTY_CHANGED
--   • Cache reset on BF_UnitUpdated (unit reassignment) and BF_UnitLeft
--   • 1s timer polls UnitPhaseReason for all group members to catch
--     stale values (e.g. after /reload, UnitPhaseReason returns bogus
--     data during loading and no follow-up UNIT_PHASE fires to clear it)
-- ============================================================
local Phased = statusProto:new("phased")

local phaseCache = {}

-- Last UnitIsVisible reading per roster unit, for the ticker's visibility-
-- transition backstop. Separate from phaseCache because the two answer
-- different questions and change on different edges: a unit can cross the
-- visibility boundary with NO phase reason at all (a different zone inside
-- the same instance is the case that motivated this), and a phase change can
-- land while visibility never moves. nil = not sampled yet, which deliberately
-- reads as a transition on the next tick so a freshly assigned token re-gates.
local visCache = {}

local function UpdatePhaseUnit(_, unit)
	-- 12.1: UnitPhaseReason returns a secret for identity-secret units —
	-- sanitize to nil (treat as not phased) before compare/branch.
	local phased = NotSecretOr(UnitPhaseReason(unit), nil)
	if phased ~= phaseCache[unit] then
		phaseCache[unit] = phased
		-- Sync BF.phaseCache (used by Phased status indicator)
		if BF.phaseCache then
			BF.phaseCache[unit] = phased and true or nil
		end
		Phased:UpdateIndicators(unit)
		-- Full aura refresh: phase change affects reachability.
		local bucket = BF.frames_of_unit and rawget(BF.frames_of_unit, unit)
		if bucket then
			for frame in next, bucket do
				if frame.unit == unit then
					BF:UpdateStandardAuras(frame)
				end
			end
		end
	end
end

local function ResetPhaseUnit(_, unit)
	-- Unconditional, and OUTSIDE the phaseCache guard below: a token that was
	-- never phased has no phaseCache entry, so folding this in there would
	-- leave the stale visibility sample of the PREVIOUS occupant behind on
	-- exactly the common case (roster shuffle, no phasing involved).
	visCache[unit] = nil
	if phaseCache[unit] ~= nil then
		phaseCache[unit] = nil
		if BF.phaseCache then BF.phaseCache[unit] = nil end
		Phased:UpdateIndicators(unit)
	end
end

function Phased:IsActive(unit)
	return not not phaseCache[unit]
end

function Phased:GetPhaseReason(unit)
	return phaseCache[unit]
end

-- v86 (event refactor stage 1): roster-scoped phase update.
--
-- The roster guard is NEW and is a bug fix. The old handler had none, while
-- its own comment claimed to match "the ClassColor status pattern above" --
-- which does guard (`BF.roster_guids[unit]`). Unguarded, UNIT_FLAGS fires for
-- every combat-flag flip on every target, focus, nameplate, boss and mob in
-- the world, so UpdatePhaseUnit ran a live UnitPhaseReason call for each and
-- wrote phaseCache["nameplate12"]-style entries that nothing ever evicts --
-- ResetPhaseUnit is driven by BF_UnitUpdated / BF_UnitLeft, which only fire
-- for roster units. Cost was sustained combat, not group join.
-- v99c: one visibility sample -- UnitIsVisible against the cache, and the
-- aura-container gate re-run only on an edge. Shared by the 1 s backstop
-- above and by the roster sweep (Initialization.lua): GROUP_ROSTER_UPDATE is
-- the event the game fires when a member changes ZONE / instance, which is
-- the trigger behind "unfiltered buffs flash on a member who just left the
-- instance" -- so the sweep re-samples every roster unit, edge-driven.
local function ResampleUnitVisibility(unit)
	local vis = UnitIsVisible(unit) and true or false
	if visCache[unit] ~= vis then
		visCache[unit] = vis
		if BF.RefreshAuraContainerVisibilityForUnit then
			BF:RefreshAuraContainerVisibilityForUnit(unit)
		end
	end
end
BF.ResampleUnitVisibility = ResampleUnitVisibility

function Phased:OnPhaseEvent(event, unit)
	if not self.enabled then return end
	if not (unit and BF.roster_guids and BF.roster_guids[unit]) then return end
	if event == "UNIT_PHASE" then
		if BF.RebuildTrackedInstanceIDs then BF:RebuildTrackedInstanceIDs(unit) end
	end
	UpdatePhaseUnit(nil, unit)
	-- Re-run the aura-container visibility gate on the phase-boundary
	-- events, keyed on UnitIsVisible DIRECTLY (fresh read inside
	-- RefreshAuraContainerVisibilityForUnit, change-guarded writes).
	-- UpdatePhaseUnit alone cannot cover this: its refresh only fires
	-- when the SANITIZED UnitPhaseReason value changes, and that value
	-- is nil-vs-nil for a unit in a different instance (absent, not
	-- "phased") and for identity-secret units in combat (secret →
	-- sanitized to nil) — so the gate stayed at alpha 1 and the engine
	-- repainted junk auras (owner-observed on the bigDef container).
	-- The EVENT still fires on those transitions even when the value
	-- reads nil, which is what makes this event-driven rather than
	-- polled. UNIT_FLAGS is deliberately excluded: it fires per combat
	-- flag flip and carries no visibility semantics.
	if event ~= "UNIT_FLAGS" and BF.RefreshAuraContainerVisibilityForUnit then
		BF:RefreshAuraContainerVisibilityForUnit(unit)
	end
end

function Phased:OnEnable()
	-- v86 (event refactor stage 1): the comment that used to sit here said
	-- "BF's statusPrototype doesn't embed AceEvent. Use a dedicated frame
	-- instead." That was wrong — statusProto:new has always called
	-- LibStub("AceEvent-3.0"):Embed(e), and the self:RegisterMessage calls
	-- eight lines below disproved it in the same function. The rest of the
	-- reasoning was right: registering UNIT_FLAGS on the BF object WOULD
	-- clobber the Flags status' AFK handler, because CallbackHandler keys
	-- callbacks by the registering object. Registering on the status object
	-- is exactly the fix.
	self:RegisterEvent("UNIT_PHASE",               "OnPhaseEvent")
	self:RegisterEvent("UNIT_FLAGS",               "OnPhaseEvent")
	self:RegisterEvent("UNIT_OTHER_PARTY_CHANGED", "OnPhaseEvent")
	-- Reset cache on unit reassignment / departure (Grid2 pattern).
	self:RegisterMessage("BF_UnitUpdated", ResetPhaseUnit)
	self:RegisterMessage("BF_UnitLeft", ResetPhaseUnit)
	-- 1s polling timer — catches stale UnitPhaseReason after /reload.
	-- Grid2 uses this to handle cases where events alone aren't enough.
	if not self._timer then
		self._timer = C_Timer.NewTicker(1, function()
			if not Phased.enabled then return end
			local units = BF.roster_guids
			if not units then return end
			for unit in next, units do
				UpdatePhaseUnit(nil, unit)
				-- VISIBILITY-TRANSITION BACKSTOP (2026-08-20). The aura
				-- container visibility gate keys on UnitIsVisible, and its
				-- event triggers are all documented-unreliable for the case
				-- that motivated this: a group member in a DIFFERENT ZONE OF
				-- THE SAME INSTANCE. PARTY_MEMBER_ENABLE/DISABLE do cross the
				-- UnitIsVisible boundary, but only fire "when in party" and
				-- while the unit is near (StatusOffline's own comment, copied
				-- from Grid2, calls the connection API "completelly bugged");
				-- UNIT_PHASE fires on phase boundaries, and a different zone
				-- inside one instance is not a phase change -- UnitPhaseReason
				-- reads nil on both sides. So no event need ever fire, the
				-- gate never re-runs, and the container keeps whatever the
				-- engine last painted on it -- which for a unit whose assist
				-- relation has degraded is every aura, unfiltered. That is the
				-- reported bug.
				--
				-- No dedicated event exists (Blizzard's own CompactUnitFrame
				-- re-reads visibility on every update rather than binding it to
				-- one), so this sweep -- which already touches every roster
				-- unit once a second for the phase read -- samples it too. One
				-- UnitIsVisible call and one table compare per unit per second;
				-- the refresh only runs on an actual edge, and its writes are
				-- change-guarded underneath that. Same "events alone aren't
				-- enough" rationale this ticker already exists for.
				ResampleUnitVisibility(unit)
			end
		end)
	end
end

function Phased:OnDisable()
	-- Explicit per-event teardown; see ClassColor:OnDisable. Events and
	-- messages are separate CallbackHandler registries either way, so the
	-- two messages below need their own calls, exactly as before.
	self:UnregisterEvent("UNIT_PHASE")
	self:UnregisterEvent("UNIT_FLAGS")
	self:UnregisterEvent("UNIT_OTHER_PARTY_CHANGED")
	self:UnregisterMessage("BF_UnitUpdated")
	self:UnregisterMessage("BF_UnitLeft")
	if self._timer then
		self._timer:Cancel()
		self._timer = nil
	end
	wipe(phaseCache)
	wipe(visCache)
	wipe(BF.phaseCache)
end

BF:RegisterStatus(Phased)


-- ============================================================
-- STATUS: summon
-- Grid2: StatusSummon.lua
-- Data: incoming summon state
-- ============================================================
local Summon = statusProto:new("summon")

function Summon:IsActive(unit)
	return unit and C_IncomingSummon and C_IncomingSummon.HasIncomingSummon(unit)
end

function Summon:GetState(unit)
	if C_IncomingSummon then
		return C_IncomingSummon.IncomingSummonStatus(unit)
	end
	return nil
end

function Summon:OnEnable()
	BF:RegisterEvent("INCOMING_SUMMON_CHANGED", function(_, unit)
		if self.enabled then self:UpdateIndicators(unit) end
	end)
end

function Summon:OnDisable()
	BF:UnregisterEvent("INCOMING_SUMMON_CHANGED")
end

BF:RegisterStatus(Summon)


-- ============================================================
-- STATUS: vehicle
-- Grid2: StatusVehicle.lua
-- Data: vehicle UI state
-- ============================================================
local Vehicle = statusProto:new("vehicle")

-- 12.1 vehicles come in TWO flavours. UI vehicles flip UnitHasVehicleUI and
-- remap the secure unit (the only kind Grid2's StatusVehicle sees). Multi-seat
-- transport vehicles flip only UnitUsingVehicle/UnitInVehicle — no vehicle
-- bar, no unit remap — and were invisible to this status (owner-reported on
-- PTR: name + icon dead while the oUF pet frame, which follows the pet slot
-- natively, showed the vehicle fine). Test all three; plain booleans, cheap,
-- deliberate divergence from Grid2.
local function UnitInAnyVehicle(u)
	if not u then return false end
	if UnitHasVehicleUI and UnitHasVehicleUI(u) then return true end
	if UnitUsingVehicle and UnitUsingVehicle(u) then return true end
	if UnitInVehicle and UnitInVehicle(u) then return true end
	return false
end

function Vehicle:IsActive(unit)
	if not unit then return false end
	local owner = BF.owner_of_unit and BF.owner_of_unit[unit]
	if owner and UnitInAnyVehicle(owner) then return true end
	return UnitInAnyVehicle(unit)
end

function Vehicle:GetOwnerName(unit)
	local owner = BF.owner_of_unit and BF.owner_of_unit[unit]
	if owner and UnitExists(owner) then
		return UnitName(owner)
	end
	return nil
end

function Vehicle:GetVehicleName(unit)
	-- Remapped frame (UI vehicle): `unit` IS the vehicle/pet unit — its name
	-- is the vehicle's. (The player's own remap token "vehicle" isn't in
	-- owner_of_unit; it falls through to the UnitName fallback, also correct.)
	if BF.owner_of_unit and BF.owner_of_unit[unit] then
		return UnitExists(unit) and UnitName(unit) or nil
	end
	-- Non-remapped frame (multi-seat vehicle): the frame kept the OWNER unit,
	-- and the vehicle occupies that unit's PET slot — the same mapping that
	-- makes the oUF pet frame show the vehicle name.
	local pet = BF.pet_of_unit and BF.pet_of_unit[unit]
	if pet and UnitExists(pet) then
		return UnitName(pet)
	end
	return UnitExists(unit) and UnitName(unit) or nil
end

BF:RegisterStatus(Vehicle)


-- ============================================================
-- STATUS: castbar
--
-- Per-unit spell cast / channel / empower state for the castBar
-- indicator. Grid2 has no analogous status (Grid2 ships no cast
-- code at all), so the shape follows BF's own power status and the
-- 12.1 call sequence used by Libs/oUF/elements/castbar.lua.
--
-- 12.1 ENGINE RULES ENCODED HERE -- do not "simplify" these:
--
--  * startTime / endTime (returns 4 and 5 of both info calls) are
--    SECRET for any unit whose identity is secret. They are never
--    read. Progress comes from the opaque DurationObject returned by
--    UnitCastingDuration / UnitChannelDuration /
--    UnitEmpoweredChannelDuration, handed straight to
--    StatusBar:SetTimerDuration by the indicator. No Lua math, no
--    OnUpdate.
--
--  * Interruptibility is NOT tracked -- these frames only show friendly
--    group members, whose casts nobody interrupts. See the note above
--    OnEnable for what to restore if that ever changes.
--
--  * UnitEmpoweredStagePercentages can return nil (stock oUF errors
--    on this; see the guard override in UnitFrames/oUF_Castbar.lua).
--
--  * There is no API for the CURRENT empower stage -- oUF's
--    PostUpdateStage is commented out upstream as unobtainable. Pips
--    are static.
--
-- ============================================================
local UnitCastingInfo             = UnitCastingInfo
local UnitChannelInfo             = UnitChannelInfo
local UnitCastingDuration         = UnitCastingDuration
local UnitChannelDuration         = UnitChannelDuration
local UnitEmpoweredChannelDuration = UnitEmpoweredChannelDuration
local UnitEmpoweredStagePercentages = UnitEmpoweredStagePercentages

local CastBarStatus = statusProto:new("castbar")

-- [unit] = state table. Tables are reused in place across casts so a
-- busy raid allocates nothing per cast.
local castState = {}
CastBarStatus.state = castState

local CAST_KIND_CAST    = 1
local CAST_KIND_CHANNEL = 2
local CAST_KIND_EMPOWER = 3

local function GetOrMakeState(unit)
	local s = castState[unit]
	if not s then
		s = {}
		castState[unit] = s
	end
	return s
end

function CastBarStatus:GetState(unit)
	return castState[unit]
end

function CastBarStatus:IsActive(unit)
	local s = castState[unit]
	return (s and s.active) and true or false
end

-- Clear a unit's state entirely. Called on roster leave so castState
-- does not accumulate entries for units that left the group.
function CastBarStatus:ClearUnit(unit)
	local s = castState[unit]
	if not s then return end
	s.active = false
	s.castID = nil
	s.duration = nil
	s.stages = nil
	castState[unit] = nil
end

-- ------------------------------------------------------------
-- Readers
-- ------------------------------------------------------------
-- Returns true if the unit has a live cast/channel/empower and fills
-- `s`. The "is casting" test is the presence of a DurationObject
-- rather than truthiness of `name`: the name return can be secret for
-- secret-identity units, and truth-testing a secret hard-errors.
-- (Stock oUF does `if(name) then` at castbar.lua:200 -- that is the
-- known-risky form we are deliberately not copying.)
local function ReadCast(unit, s)
	local castDur = UnitCastingDuration(unit)
	if castDur ~= nil then
		-- Returns: 1 name, 2 displayName, 3 texture, 4 startTime,
		-- 5 endTime, 6 isTradeSkill, 7 unused, 8 notInterruptible,
		-- 9 spellID, 10 castID. startTime/endTime are secret and unused;
		-- notInterruptible is not read at all (see the note on
		-- OnEnable below).
		local _, displayName, texture, _, _, _, _, _, spellID, castID = UnitCastingInfo(unit)
		s.kind             = CAST_KIND_CAST
		s.duration         = castDur
		s.direction        = Enum.StatusBarTimerDirection.ElapsedTime
		s.displayName      = displayName
		s.texture          = texture
		s.spellID          = spellID
		s.castID           = castID
		s.isEmpowered      = false
		s.stages           = nil
		s.active           = true
		return true
	end

	-- Channel or empowered channel. Returns: 1 name, 2 displayName,
	-- 3 texture, 4 startTime, 5 endTime, 6 isTradeSkill,
	-- 7 notInterruptible, 8 spellID, 9 isEmpowered, 10 numStages,
	-- 11 castID. isEmpowered is combat-safe (not secret).
	local _, displayName, texture, _, _, _, _, spellID, isEmpowered, _, castID = UnitChannelInfo(unit)
	local dur
	if isEmpowered then
		dur = UnitEmpoweredChannelDuration(unit)
	else
		dur = UnitChannelDuration(unit)
	end
	if dur == nil then
		s.active = false
		return false
	end

	s.kind             = isEmpowered and CAST_KIND_EMPOWER or CAST_KIND_CHANNEL
	s.duration         = dur
	-- Empowered channels fill UP (ElapsedTime); plain channels drain
	-- DOWN (RemainingTime). oUF castbar.lua:206-213.
	s.direction        = isEmpowered and Enum.StatusBarTimerDirection.ElapsedTime
	                                 or  Enum.StatusBarTimerDirection.RemainingTime
	s.displayName      = displayName
	s.texture          = texture
	s.spellID          = spellID
	s.castID           = castID
	s.isEmpowered      = isEmpowered and true or false
	-- Per-stage FRACTIONS of the bar (not cumulative). Can be nil.
	s.stages           = isEmpowered and UnitEmpoweredStagePercentages(unit) or nil
	s.active           = true
	return true
end

-- ------------------------------------------------------------
-- Event handlers
-- ------------------------------------------------------------
local function CastStart(self, _, unit)
	local s = GetOrMakeState(unit)
	s.failed = false
	s.holdUntil = nil
	if ReadCast(unit, s) then
		s.generation = (s.generation or 0) + 1
	end
	self:UpdateIndicators(unit)
end

-- DELAYED / CHANNEL_UPDATE / EMPOWER_UPDATE: the duration object is
-- replaced, everything else is unchanged. Re-read but keep the same
-- generation so the indicator does not redo icon/text/pip work.
local function CastUpdate(self, _, unit)
	local s = castState[unit]
	if not s or not s.active then return end
	ReadCast(unit, s)
	self:UpdateIndicators(unit)
end

-- STOP / CHANNEL_STOP / EMPOWER_STOP. Payloads differ:
--   STOP           (unit, castGUID, spellID, castID)
--   CHANNEL_STOP   (unit, castGUID, spellID, interruptedBy, castID)
--   EMPOWER_STOP   (unit, castGUID, spellID, empowerComplete, interruptedBy, castID)
-- Is this STOP/FAIL event for the cast we are currently showing?
--
-- Both castIDs may be secret for a secret-identity unit, and a
-- secret-vs-secret comparison THROWS -- so the guard is: nil-check both
-- (safe), then refuse to compare unless both are readable. When either
-- is secret we accept the event rather than drop it: a stale STOP
-- clearing the bar a fraction early is a far better failure than a real
-- STOP being ignored and the bar sticking forever.
--
-- (Stock oUF does the bare `STATE[element].castID ~= castID` at
-- castbar.lua:318/394/452. That is upstream-sanctioned but inconsistent
-- with the care ReadCast takes above, so it is not copied here.)
local function IsStaleCast(s, castID)
	if castID == nil or s.castID == nil then return false end
	if issecretvalue(castID) or issecretvalue(s.castID) then return false end
	return castID ~= s.castID
end

local function CastStop(self, event, unit, _, _, a, b, c)
	local s = castState[unit]
	if not s or not s.active then return end
	local castID
	if event == "UNIT_SPELLCAST_STOP" then
		castID = a
	elseif event == "UNIT_SPELLCAST_CHANNEL_STOP" then
		castID = b
	else -- UNIT_SPELLCAST_EMPOWER_STOP
		castID = c
	end
	-- Stale STOP for a cast we are no longer showing.
	if IsStaleCast(s, castID) then return end
	s.active   = false
	s.failed   = false
	s.stages   = nil
	s.duration = nil
	self:UpdateIndicators(unit)
end

-- FAILED       (unit, castGUID, spellID, castID)
-- INTERRUPTED  (unit, castGUID, spellID, interruptedBy, castID)
local function CastFail(self, event, unit, _, _, a, b)
	local s = castState[unit]
	if not s or not s.active then return end
	local castID = (event == "UNIT_SPELLCAST_FAILED") and a or b
	if IsStaleCast(s, castID) then return end
	s.active   = false
	s.failed   = true      -- indicator applies the hold-then-hide linger
	s.stages   = nil
	s.duration = nil
	self:UpdateIndicators(unit)
end

-- NOT TRACKED: interruptibility.
--
-- These frames only ever show party/raid members and their pets, and a
-- friendly player's cast is not something you interrupt -- so
-- notInterruptible has no meaning here. It is therefore not read from
-- either info call, and UNIT_SPELLCAST_INTERRUPTIBLE /
-- _NOT_INTERRUPTIBLE are not registered at all. That is 2 of what would
-- otherwise be 13 per-unit events, gone.
--
-- (The oUF unit frames DO track it -- see UnitFrames/oUF_Castbar.lua --
-- because target/focus can be a hostile caster. If this indicator ever
-- grows a hostile-unit mode, the rule to restore is: notInterruptible
-- is a SECRET boolean, never truth-tested, only fed to
-- SetAlphaFromBoolean or C_CurveUtil.EvaluateColorFromBoolean.)

function CastBarStatus:OnEnable()
	self:RegisterRosterUnitEvent("UNIT_SPELLCAST_START",             CastStart)
	self:RegisterRosterUnitEvent("UNIT_SPELLCAST_CHANNEL_START",     CastStart)
	self:RegisterRosterUnitEvent("UNIT_SPELLCAST_EMPOWER_START",     CastStart)
	self:RegisterRosterUnitEvent("UNIT_SPELLCAST_DELAYED",           CastUpdate)
	self:RegisterRosterUnitEvent("UNIT_SPELLCAST_CHANNEL_UPDATE",    CastUpdate)
	self:RegisterRosterUnitEvent("UNIT_SPELLCAST_EMPOWER_UPDATE",    CastUpdate)
	self:RegisterRosterUnitEvent("UNIT_SPELLCAST_STOP",              CastStop)
	self:RegisterRosterUnitEvent("UNIT_SPELLCAST_CHANNEL_STOP",      CastStop)
	self:RegisterRosterUnitEvent("UNIT_SPELLCAST_EMPOWER_STOP",      CastStop)
	self:RegisterRosterUnitEvent("UNIT_SPELLCAST_FAILED",            CastFail)
	self:RegisterRosterUnitEvent("UNIT_SPELLCAST_INTERRUPTED",       CastFail)
	-- v97 (2026-08-27): same token, new occupant. castState is per TOKEN,
	-- and a roster shuffle moves the previous occupant's in-flight cast to
	-- whoever inherits the token: the old caster's STOP arrives on THEIR new
	-- token, and the new occupant's first STOP-without-START is dropped by
	-- IsStaleCast, so the bar froze on the old name/icon until the new
	-- occupant cast something. BF_UnitUpdated fires from the roster sweep
	-- right before it repaints the frame; clearing here means that repaint
	-- sees no cast. (BF_UnitLeft is already covered by UnregisterRosterUnit
	-- -> ClearUnit.)
	self:RegisterMessage("BF_UnitUpdated", function(_, unit) CastBarStatus:ClearUnit(unit) end)
end

function CastBarStatus:OnDisable()
	self:UnregisterMessage("BF_UnitUpdated")
	self:UnregisterRosterUnitEvent("UNIT_SPELLCAST_START")
	self:UnregisterRosterUnitEvent("UNIT_SPELLCAST_CHANNEL_START")
	self:UnregisterRosterUnitEvent("UNIT_SPELLCAST_EMPOWER_START")
	self:UnregisterRosterUnitEvent("UNIT_SPELLCAST_DELAYED")
	self:UnregisterRosterUnitEvent("UNIT_SPELLCAST_CHANNEL_UPDATE")
	self:UnregisterRosterUnitEvent("UNIT_SPELLCAST_EMPOWER_UPDATE")
	self:UnregisterRosterUnitEvent("UNIT_SPELLCAST_STOP")
	self:UnregisterRosterUnitEvent("UNIT_SPELLCAST_CHANNEL_STOP")
	self:UnregisterRosterUnitEvent("UNIT_SPELLCAST_EMPOWER_STOP")
	self:UnregisterRosterUnitEvent("UNIT_SPELLCAST_FAILED")
	self:UnregisterRosterUnitEvent("UNIT_SPELLCAST_INTERRUPTED")
	wipe(castState)
end

BF:RegisterStatus(CastBarStatus)


-- ============================================================
-- INDICATOR BINDING
--
-- Wire up which indicators care about which statuses.
-- This is BF's equivalent of Grid2's profile-driven binding,
-- hardcoded since BF doesn't have user-configurable assignments.
-- ============================================================
local function BindIndicators()
	local function bind(statusName, ...)
		local s = BF.statuses[statusName]
		if not s then return end
		for i = 1, select("#", ...) do
			local indName = select(i, ...)
			local ind = BF.indicators[indName]
			if ind then
				s:RegisterIndicator(ind)
			end
		end
	end

	-- Health changes → health bar VALUE ONLY, health text, status overlay.
	-- healthBar is now value-only (Perf 3B). Color is owned by the
	-- healthBarColor sidekick which has its own binding set.
	-- NOTE: absorbBars was removed from this binding (performance optimization).
	-- Grid2's shields status only registers UNIT_ABSORB_AMOUNT_CHANGED + UNIT_MAXHEALTH,
	-- not UNIT_HEALTH. The absorb overlay's health-dependent clamping is handled by a
	-- targeted _UpdateAbsorbOverlay call in the UNIT_HEALTH handler (Initialization.lua),
	-- avoiding unnecessary sub-method calls on every health tick.
	-- _UpdateReducedMaxHealth is handled separately by the reducedmaxhealth status
	-- (UNIT_MAX_HEALTH_MODIFIERS_CHANGED only).
	bind("health",         "healthBar", "healthText", "statusOverlay")
	-- Class color changes → color sidekick. Fires on UNIT_PORTRAIT_UPDATE
	-- (late-arriving class info) and on fg-color profile setting flips
	-- (via RefreshProfileCache hook in the classcolor status).
	bind("classcolor",     "healthBarColor")
	-- Power changes → power bar
	bind("power",          "powerBar")
	-- Range changes → range alpha
	bind("range",          "rangeAlpha")
	-- Threat changes → aggro highlight
	bind("threat",         "aggroHighlight")
	-- Absorb / heal absorb / heal prediction / reduced max health bindings
	-- are dynamic — handled by BF:RebindAbsorbStatuses() so each status only
	-- enables (and registers its per-unit event) when the matching profile
	-- toggle is on in ANY flat. Grid2 pattern: StatusShields, StatusHealAbsorbs,
	-- heals-incoming each register their events only when an indicator is
	-- linked. Mirrored here by gating the bind per toggle:
	--   absorbs          → showAbsorbsMissingHealth (master: also gates overshield)
	--   healabsorb       → showHealAbsorb
	--   healprediction   → showHealPrediction
	--   reducedmaxhealth → showReducedMaxHealth
	-- See RebindAbsorbStatuses below. Event handlers in Initialization.lua
	-- stay targeted (one sub-method per event), unchanged.
	-- castbar → castBar is also DYNAMIC (BF:RebindCastBarStatus): binding it
	-- unconditionally would register 13 UNIT_SPELLCAST_* events on every
	-- roster unit for users who never turn the feature on. Same gating
	-- pattern as the absorb binds above.
	-- Name changes → name text, role icon
	bind("name",           "nameText", "roleIcon")
	-- Level changes → level text
	bind("level",          "levelText")
	-- Target changes → target highlight
	bind("target",         "targetHighlight")
	-- Offline changes → status overlay, name text, healthBar (value reset on
	-- offline transition), healthBarColor (color ownership handoff to
	-- StatusOverlay), powerBar, debuff highlight.
	-- dispelDebuffBorder/Overlay/Indicator must be included so that any
	-- active debuff overlay is cleared when a unit goes offline. No more
	-- UNIT_AURA events fire for disconnected units, so without this binding
	-- the overlays get stuck visible.
	-- v67: buffHighlight dropped from this list — the indicator is gone.
	-- rangeAlpha is included because BF (unlike Grid2) forces offline frames
	-- to full alpha (RangeAlpha's offline early-return, a BF feature). That
	-- creates an obligation Grid2 doesn't have: on RECONNECT something must
	-- re-run RangeAlpha to restore range-based alpha, or a member who comes
	-- back online out of range keeps the forced alpha-1 and reads as
	-- in-range. UNIT_IN_RANGE_UPDATE can't be relied on for this (no event
	-- fires if the cached range state didn't change across the disconnect).
	-- castBar is included so a bar clears when its owner disconnects: a
	-- disconnect does not reliably produce a UNIT_SPELLCAST_STOP, so without
	-- this the bar would sit frozen at whatever the engine timer last drew.
	-- Cheap when the feature is off -- CastBar:Update early-returns on its
	-- cached _enabled flag before touching anything.
	-- missingRaidBuff is included for the same stuck-visible reason as the
	-- dispel overlays: its only other binding is "buffs" (UNIT_AURA), which
	-- goes silent for a disconnected unit, so an icon shown at (or just
	-- before) the disconnect persisted on the offline frame. Its Update
	-- already has the UnitIsConnected guard — this binding just makes the
	-- guard run on the offline transition (and re-evaluate on reconnect).
	-- healthText is included so the overlay never has to cross-call it: the
	-- reconnect transition hides/shows health text, and HealthText owns that
	-- text on every other tick.
	bind("offline",        "statusOverlay", "nameText", "healthBar", "healthBarColor", "healthText", "powerBar", "castBar", "rangeAlpha", "dispelDebuffBorder", "dispelDebuffOverlay", "dispelDebuffIndicator", "missingRaidBuff")
	-- Death state changes → status overlay, name text, healthBar (value),
	-- healthBarColor (color handoff), health text, cast bar.
	-- absorbBars, rangeAlpha and aggroHighlight are bound here because they
	-- all render differently for a dead unit (absorb bars suppressed,
	-- dead-colored status text re-tinted out of range, threat highlight
	-- cleared). They used to get that repaint from a full per-frame
	-- indicator sweep run on every death transition; the binding gives each
	-- of them exactly one Update instead, and each is change-guarded
	-- internally. powerBar is NOT bound: its visibility does not depend on
	-- death (see BF:ShouldShowPowerBar), so a death dispatch would be wasted.
	bind("death",          "statusOverlay", "nameText", "healthBar", "healthBarColor", "healthText", "castBar", "absorbBars", "rangeAlpha", "aggroHighlight")
	-- Flag changes (AFK) → status overlay, healthBarColor (AFK color override),
	-- nameText (refactor review M1: AFK append-to-name and AFK name color were
	-- previously repainted only via StatusText_Overlay's per-UNIT_HEALTH
	-- nameText cross-call; with that removed, AFK transitions must repaint the
	-- name directly, matching how death/offline are already bound above).
	-- healthText is included for the same reason as on the offline bind: the
	-- AFK branch hides it and the alive branch must bring it back, without
	-- the overlay cross-calling another indicator.
	-- ORDER IS LOAD-BEARING HERE, and only here. HealthText decides its own
	-- visibility from the health/offline/death statuses; AFK is the one
	-- state it does not know about, so the overlay's AFK branch hides the
	-- health text and must run LAST or its Hide() is undone in the same
	-- dispatch. Listing healthText first reproduces the order the `health`
	-- binding already relies on (healthBar, healthText, statusOverlay).
	bind("flags",          "healthText", "statusOverlay", "healthBarColor", "nameText")
	-- Raid icon → raid target icon
	bind("raidicon",       "raidTargetIcon")
	-- Leader → leader icon
	bind("leader",         "leaderIcon")
	-- Role → role icon
	bind("role",           "roleIcon")
	-- Ready check → status icons
	bind("readycheck",     "statusIcons")
	-- Resurrect → status icons
	bind("resurrect",      "statusIcons")
	-- Phased → status icons
	bind("phased",         "statusIcons")
	-- Summon → status icons
	bind("summon",         "statusIcons")
	-- Vehicle → status icons, vehicle text
	bind("vehicle",        "statusIcons", "vehicleText")
    -- Aura statuses (Grid2 pattern: each status owns its own UNIT_AURA
    -- handler and only does its own cache rebuild work).
    --
    -- Buffs → unified icon rendering (default buffs + custom containers)
    -- + missing raid buff. missingRaidBuff runs independently (cheap
    -- GetAuraDataBySpellName).
    -- v67: the buffmatch half of this comment is gone — BuffMatch:UpdateCache
    -- and the buffHighlight indicator it fed no longer exist, so there is no
    -- ordering constraint between the two indicators below.
    bind("buffs",          "buffsAndContainers", "missingRaidBuff")
    -- v67: bind("buffmatch", "buffHighlight") removed. The buffHighlight
    -- indicator is gone and the buffmatch status is inert (its producer,
    -- BuffMatch:UpdateCache, had no caller left) — the binding would have
    -- enabled a status that can never become active.
    -- Big defensive → icon rendering only.
    bind("bigdef",         "bigDefIcons")
    -- Debuff changes → icon rendering + border/overlay/dot.
    -- All three dispel-debuff indicators are bound here (in addition to dispel)
    -- so that "all"/"allDispellable" modes update on every debuff change.
    -- Each indicator's own feature gate + change guard ensures no widget work
    -- when the feature is off or nothing relevant changed.
    -- v67: the old ordering note here claimed debuffIcons is listed first so
    -- Debuffs:GetIcons populates caches before the highlight indicators read
    -- them via Debuffs:GetHarmful. Neither runs any more (both were deleted
    -- with the rest of the legacy debuff data path); the order is now
    -- arbitrary and carries no dependency.
    bind("debuffs",        "debuffIcons", "dispelDebuffBorder", "dispelDebuffOverlay", "dispelDebuffIndicator")
    -- Dispel changes → border/overlay/dot.
    -- v67: the dispel status no longer registers UNIT_AURA (all three dispel
    -- visuals are slot-visual AuraContainers on 12.1), so this binding is
    -- driven only by full-refresh passes.
    bind("dispel",         "dispelDebuffBorder", "dispelDebuffOverlay", "dispelDebuffIndicator")
    -- v69: bind("crowdcontrol", ...) removed — the dedicated Crowd Control
    -- feature is now a seeded custom debuff container (crowdControl preset).
end

-- Public init function — called once after all indicators are registered
function BF:InitStatusSystem()
	BindIndicators()
	-- Wire up the dynamic gradient-dependent binding of healthBarColor to
	-- the health status. Must run AFTER BindIndicators so the indicator
	-- already has its static bindings in place.
	self:RebindHealthBarColor()
	-- Wire up the dynamic absorb-toggle-dependent binding of the four absorb
	-- statuses to the absorbBars indicator. Must run AFTER BindIndicators for
	-- the same reason (though the absorb statuses have no static bindings).
	self:RebindAbsorbStatuses()
	-- Same for the castbar status ↔ castBar indicator.
	self:RebindCastBarStatus()
end

-- ============================================================
-- BF:RebindCastBarStatus()
--
-- The castbar status registers THIRTEEN UNIT_SPELLCAST_* events on
-- every roster unit frame. That is by far the largest event surface any
-- BF status opens, so it is bound only when the cast bar is actually
-- enabled somewhere -- the global pseudo-layout, any per-Layout flat
-- (when the castBar per-layout toggle is on), or any Custom Frame Group
-- that overrides the castBar section.
--
-- With the feature off: no bind, so statusProto:RegisterIndicator never
-- flips `enabled`, OnEnable never runs, and not one event is registered.
-- Cost is exactly zero.
--
-- Idempotent; safe to call at any time. Also re-run on instance
-- transitions (see PLAYER_ENTERING_WORLD / ZONE_CHANGED_NEW_AREA in
-- Initialization.lua) so the context gates below open or close the event
-- registration when you enter or leave a raid or a PvP instance.
-- ============================================================

-- Context gates. A cast bar source (global, a per-Layout flat, or a CFG
-- section) only counts as "needed" when its context toggles allow the
-- CURRENT game context. Because the whole point is to pay nothing when
-- the context does not match, these are checked HERE -- if they fail, the
-- UNIT_SPELLCAST_* events are never registered -- rather than per cast in
-- the indicator.
--
--   partyOnly : only in a party group, never in a raid. Uses IsInRaid(),
--               the same test GroupChanged uses to pick party vs raid.
--   pvpOnly   : only inside a PvP instance. Uses the SAME instanceType
--               test the layout system uses to select a PvP slot
--               (resolveSlotFromContext in Core_ProfileAPI.lua: "arena"
--               for arenas, "pvp" for battlegrounds). Deliberately NOT
--               combined with partyOnly -- each gate stands alone, so an
--               arena (which is a party group) satisfies both.
--
-- Neither call is combat-protected and neither reads a secret value.
local function CastBarContextAllows(cb)
	if cb.partyOnly and IsInRaid() then
		return false
	end
	if cb.pvpOnly then
		local _, instanceType = GetInstanceInfo()
		if instanceType ~= "arena" and instanceType ~= "pvp" then
			return false
		end
	end
	return true
end

function BF:RebindCastBarStatus()
	local status = self.statuses and self.statuses.castbar
	local ind    = self.indicators and self.indicators.castBar
	if not status or not ind then return end

	local needed = false
	local rpp = self.rpDB and self.rpDB.profile

	if rpp then
		-- Global pseudo-layout.
		local g = rpp.castBar
		if g and g.enabled and CastBarContextAllows(g) then needed = true end

		-- Per-Layout flats, only when the castBar per-layout toggle is on.
		if not needed then
			local lp = rpp.layouts
			local toggles = lp and lp.perLayoutToggles
			if toggles and toggles.castBar and lp.flatLayouts then
				for _, flat in pairs(lp.flatLayouts) do
					local fcb = type(flat) == "table" and rawget(flat, "castBar")
					if fcb and fcb.enabled and CastBarContextAllows(fcb) then
						needed = true
						break
					end
				end
			end
		end
	end

	-- Custom Frame Groups that override the castBar section. (No options UI
	-- creates these any more -- the CFG Cast Bars tab was removed 2026-08-13
	-- -- but pre-existing dormant data is still honored, gates included.)
	if not needed then
		local cfgp   = self.cfgDB and self.cfgDB.profile
		local groups = cfgp and cfgp.customFrameGroups
		if groups then
			for _, grp in ipairs(groups) do
				if type(grp) == "table" and grp.overrideCastBar then
					local gflat = grp.flat
					local gcb = type(gflat) == "table" and rawget(gflat, "castBar")
					if gcb and gcb.enabled and CastBarContextAllows(gcb) then
						needed = true
						break
					end
				end
			end
		end
	end

	if needed then
		status:RegisterIndicator(ind)
	else
		status:UnregisterIndicator(ind)
	end
end

-- ============================================================
-- BF:RebindHealthBarColor() -- Perf 3B dynamic binding
--
-- The healthBarColor sidekick is statically bound to `classcolor`,
-- `offline`, `death`, and `flags` (see BindIndicators above). When
-- either health-bar gradient (useHealthGradient) or background gradient
-- (useBgGradient) is ENABLED, the color output tracks health percent and
-- must re-fire on every UNIT_HEALTH. In that case we additionally bind
-- healthBarColor to the `health` status.
--
-- When BOTH gradients are disabled (the common default), the color
-- output is static per-unit (class color / custom color / hostile color)
-- and does NOT need to re-evaluate on UNIT_HEALTH -- the static
-- bindings are sufficient. Unbinding from `health` here is the whole
-- point of 3B: it removes ~44 color-update calls per second per frame
-- from the gradient-off user's hot path.
--
-- Safe to call at any time; register/unregister are idempotent when
-- the indicator is already in the target state. Health status never
-- fully disables because other indicators (healthBar, healthText,
-- statusOverlay) remain bound.
-- ============================================================
function BF:RebindHealthBarColor()
	local healthStatus = self.statuses and self.statuses.health
	local colorInd = self.indicators and self.indicators.healthBarColor
	if not healthStatus or not colorInd then return end

	-- Read gradient settings from the global pseudo-layout. Per-layout
	-- doesn't make this decision cleanly because different flats can have
	-- different gradient settings; we'd have to rebind on every context
	-- switch. Instead, if ANY flat (or the global) has a gradient
	-- enabled, we bind to health -- worst case is we fire more updates
	-- than strictly needed when the user switches to a flat with
	-- gradients off, which is the pre-3B baseline behavior anyway.
	local needsHealth = false
	local rpp = self.rpDB and self.rpDB.profile
	if rpp then
		local hp = rpp.healthPower
		if hp and (hp.useHealthGradient or hp.useBgGradient) then
			needsHealth = true
		end
		-- Also check per-flat overrides when the healthPower per-layout
		-- toggle is ON. Any flat with a gradient on means we must fire
		-- color updates on UNIT_HEALTH (the active flat might be any of
		-- them at runtime).
		if not needsHealth then
			local lp = rpp.layouts
			-- 2026-08-24: healthPower toggles are per-subtab now; the coarse
			-- alias ("any subtab per-Layout") is the right gate here -- a
			-- false positive only costs this scan.
			if BF:IsPerLayoutSection("healthPower") then
				local fl = lp.flatLayouts
				if fl then
					for _, flat in pairs(fl) do
						local fhp = type(flat) == "table" and rawget(flat, "healthPower")
						if fhp and (fhp.useHealthGradient or fhp.useBgGradient) then
							needsHealth = true
							break
						end
					end
				end
			end
		end
	end

	if needsHealth then
		healthStatus:RegisterIndicator(colorInd)
	else
		healthStatus:UnregisterIndicator(colorInd)
	end
end

-- Hook RefreshProfileCache so profile switches / layout changes pick up
-- whether the new active settings need UNIT_HEALTH color updates.
hooksecurefunc(BF, "RefreshProfileCache", function(self)
	if self.RebindHealthBarColor then self:RebindHealthBarColor() end
end)

-- ============================================================
-- BF:RebindAbsorbStatuses() -- dynamic absorb-toggle-dependent binding
--
-- Grid2 splits absorbs / heal-absorbs / heals-incoming into separate
-- statuses, each registering its per-unit event only when an indicator is
-- linked. BF has the same statuses (absorbs / healabsorb / healprediction /
-- reducedmaxhealth) but one shared indicator (absorbBars), so statuses
-- enable in lockstep with the indicator. To match Grid2's event-level
-- gating we rebind dynamically based on profile toggles:
--
--   showAbsorbsMissingHealth → absorbs          (UNIT_ABSORB_AMOUNT_CHANGED)
--   showHealAbsorb           → healabsorb       (UNIT_HEAL_ABSORB_AMOUNT_CHANGED)
--   showHealPrediction       → healprediction   (UNIT_HEAL_PREDICTION)
--   showReducedMaxHealth     → reducedmaxhealth (UNIT_MAX_HEALTH_MODIFIERS_CHANGED)
--
-- showAbsorbsMissingHealth is the master for damage absorbs: it also
-- controls whether overshield renders, because overshield is computed
-- from the same UNIT_ABSORB_AMOUNT_CHANGED event. If the master is off,
-- the `absorbs` status is unbound regardless of showOvershield. The UI
-- enforces the same invariant by hiding overshield controls.
--
-- Per-layout check mirrors RebindHealthBarColor exactly: if ANY flat (or
-- the global pseudo-layout) has a toggle on, we keep the matching status
-- bound. Worst case when switching to a flat with a toggle off, we fire
-- more events than strictly needed -- same conservative behavior as
-- RebindHealthBarColor and the pre-rebind baseline.
--
-- Defaults: showAbsorbsMissingHealth and showReducedMaxHealth are
-- implicitly true (absent or ~= false). showHealAbsorb, showHealPrediction,
-- and showOvershield are plain booleans (nil = off).
--
-- Custom frame groups intentionally defer to global absorb settings
-- (moduleShowAbsorbs is an all-or-nothing render-level umbrella applied
-- in AbsorbBars.lua; it does not introduce new event sources).
--
-- Safe to call at any time; register/unregister are idempotent.
-- ============================================================
function BF:RebindAbsorbStatuses()
	local absorbInd = self.indicators and self.indicators.absorbBars
	if not absorbInd then return end
	local statuses = self.statuses
	if not statuses then return end

	local function anyFlatHas(predicate)
		local rpp = self.rpDB and self.rpDB.profile
		if not rpp then return false end
		-- Global pseudo-layout (rpDB.profile.absorbs).
		local ab = rpp.absorbs
		if ab and predicate(ab) then return true end
		-- Per-flat overrides, only when per-layout-absorbs is on.
		local lp = rpp.layouts
		-- 2026-08-24: per-subtab toggles -- coarse alias, same as the
		-- healthPower gate above.
		if BF:IsPerLayoutSection("absorbs") then
			local fl = lp.flatLayouts
			if fl then
				for _, flat in pairs(fl) do
					local fab = type(flat) == "table" and rawget(flat, "absorbs")
					if fab and predicate(fab) then return true end
				end
			end
		end
		return false
	end

	-- showAbsorbsMissingHealth and showReducedMaxHealth are true by default
	-- (the absence of the key, or any value that is not literally false,
	-- counts as on). Match the Options setters' `ip and ip.foo ~= false` idiom.
	-- v94: bind absorb events (UNIT_ABSORB_AMOUNT_CHANGED) when the missing-
	-- health bar OR overshield is on -- overshield now renders independently of
	-- the missing-health master and needs absorb-change updates.
	local needAbsorbs = anyFlatHas(function(ab)
		return ab.showAbsorbsMissingHealth ~= false or (ab.showOvershield and true or false)
	end)
	local needReduced = anyFlatHas(function(ab) return ab.showReducedMaxHealth     ~= false end)
	-- showHealAbsorb and showHealPrediction are plain booleans (default nil = off).
	local needHealAbs = anyFlatHas(function(ab) return ab.showHealAbsorb           and true or false end)
	local needHealPred = anyFlatHas(function(ab) return ab.showHealPrediction      and true or false end)
	-- v94 PERF (Win 5): overshield is now the ONLY health-tick absorb work --
	-- the missing-health bar became geometric (unclamped total + absorbClip;
	-- see AbsorbBars). So shieldsOverflow (UNIT_HEALTH) binds on the overshield
	-- gate, not the broader absorbs gate.
	-- v94: shieldsOverflow (the UNIT_HEALTH clamp) is needed only for the
	-- HEALTH-DEPENDENT overshield -- the excess amount. LEFT overshield with
	-- the missing-health bar off shows the health-independent TOTAL, so it
	-- needs absorb events but not the per-tick UNIT_HEALTH clamp.
	local needOvershield = anyFlatHas(function(ab)
		if not (ab.showOvershield and true or false) then return false end
		local leftTotal = ab.overshieldStyle ~= "Glow"
		               and ab.overshieldAnchor == "LEFT"
		               and ab.showAbsorbsMissingHealth == false
		return not leftTotal
	end)

	local function apply(statusName, needed)
		local s = statuses[statusName]
		if not s then return end
		if needed then
			s:RegisterIndicator(absorbInd)
		else
			s:UnregisterIndicator(absorbInd)
		end
	end

	apply("absorbs",          needAbsorbs)
	apply("healabsorb",       needHealAbs)
	apply("healprediction",   needHealPred)
	apply("reducedmaxhealth", needReduced)

	-- shieldsOverflow (UNIT_HEALTH -> absorbBarsHealthClamp sidekick) now binds
	-- on the OVERSHIELD gate. The missing-health bar left this path (it feeds
	-- the unclamped total on UNIT_ABSORB_AMOUNT_CHANGED and clips geometrically),
	-- so overshield is the only health-dependent absorb work left. Overshield
	-- off => shieldsOverflow disabled => UNIT_HEALTH never registered for it =>
	-- zero per-health-tick absorb cost. Grid2 pattern: the shields-overflow
	-- status toggles UNIT_HEALTH on/off the same way.
	local shieldsOverflowStatus = statuses.shieldsOverflow
	local clampInd = self.indicators and self.indicators.absorbBarsHealthClamp
	if shieldsOverflowStatus and clampInd then
		if needOvershield then
			shieldsOverflowStatus:RegisterIndicator(clampInd)
		else
			shieldsOverflowStatus:UnregisterIndicator(clampInd)
		end
	end

	-- reducedmaxhealth → nameText, ONLY while the reduced-max percentage is
	-- appended to the name (refactor review M2). NameText composes the
	-- "(85%)" suffix from parent._reducedMaxPct; with the per-UNIT_HEALTH
	-- nameText cross-call removed, a _reducedMaxPct change must repaint the
	-- name itself or the suffix goes stale. Bound conditionally so users
	-- without the option pay nothing — same pattern as the absorb binds above.
	local nameInd = self.indicators and self.indicators.nameText
	local reducedStatus = statuses.reducedmaxhealth
	if nameInd and reducedStatus then
		local needNameAppend = anyFlatHas(function(ab)
			return ab.showReducedMaxHealthText and ab.appendReducedMaxText
			   and ab.appendReducedMaxTarget == "name"
		end)
		if needNameAppend then
			reducedStatus:RegisterIndicator(nameInd)
		else
			reducedStatus:UnregisterIndicator(nameInd)
		end
	end
end

-- Hook RefreshProfileCache so profile switches / layout changes pick up
-- whether the new active settings need absorb-related events. Absorb
-- toggle setters (in Options_Absorbs.lua) don't go through RefreshProfileCache,
-- so they call BF:RebindAbsorbStatuses() directly via the RefreshAll*
-- helpers in Core_Refresh.lua. This hook covers profile/context switches.
hooksecurefunc(BF, "RefreshProfileCache", function(self)
	if self.RebindAbsorbStatuses then self:RebindAbsorbStatuses() end
	-- Same coverage for the cast bar: a profile/context switch can move
	-- between layouts where castBar.enabled differs, which must open or
	-- close the 13-event UNIT_SPELLCAST_* registration. The castBar option
	-- setters call BF:RefreshAllCastBars() directly for the in-place case.
	if self.RebindCastBarStatus then self:RebindCastBarStatus() end
end)

-- Perf plan §L5.1 load-time mark: 101 KB (.toc 103-107).
if BuzzardFrames then BuzzardFrames:LoadMark("chunk:bfStatus") end
