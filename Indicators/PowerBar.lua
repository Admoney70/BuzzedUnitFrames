--[[
BuzzardFrames: Indicators/PowerBar.lua
Power bar indicator — mirrors Grid2's IndicatorBar.lua pattern.

Creates a StatusBar at the bottom of the frame for mana/energy/etc.
Visibility is conditional: only shown when BF:ShouldShowPowerBar(unit) is true.

Each call to Update unconditionally overwrites stale state (Grid2 pattern).
]]

local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

local UnitPowerType       = UnitPowerType
local UnitPowerPercent    = UnitPowerPercent
local UnitExists          = UnitExists
local InCombatLockdown    = InCombatLockdown
local PowerBarColor       = PowerBarColor
local issecretvalue       = issecretvalue or function() return false end

local PowerBar = BF.indicatorPrototype:new("powerBar")

-- ============================================================

local function PixelsToUI(n)
	local pixelSize = 768 / select(2, GetPhysicalScreenSize())
	local uiScale = UIParent:GetEffectiveScale()
	local pixelMult = (uiScale > 0) and (pixelSize / uiScale) or 1
	return n * pixelMult
end

-- ============================================================
-- Create
-- ============================================================
function PowerBar:Create(parent)
	-- Skip if already created by legacy InitFrame
	if parent.powerBar then
		parent[self.name] = parent.powerBar
		return
	end

	local bar = BF.StatusBar(nil, parent)
	bar.indicator = self
	bar:EnableMouse(false)
	BF:DisablePixelSnapRegion(bar)
	bar:SetMinMaxValues(0, 1)
	bar:SetValue(0)
	local _p = BF.db and BF.db.profile
	local pbTex = (_p and _p.useCustomPowerBarTexture) and BF:ResolveBarTexture(_p.powerBarTexture) or "Interface\\Buttons\\WHITE8X8"
	bar:SetStatusBarTexture(pbTex)
	bar:Hide()

	local tex = bar:GetStatusBarTexture()
	if tex then
		BF:DisablePixelSnapRegion(tex)
		tex:ClearAllPoints()
		tex:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, 0)
		tex:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", 0, 0)
	end

	-- Background frame + texture
	local bgFrame = CreateFrame("Frame", nil, parent)
	bgFrame:SetAllPoints(bar)
	bgFrame:Hide()
	local bgTex = BF.Texture(bgFrame, nil, "BACKGROUND")
	bgTex:SetAllPoints(bgFrame)
	bgTex:SetColorTexture(0.08, 0.08, 0.08, 1.0)
	bar.bg = bgTex
	bar.bgFrame = bgFrame

	parent[self.name] = bar
	parent.powerBar = bar  -- backward compat alias
end

-- ============================================================
-- Layout
-- ============================================================
function PowerBar:Layout(parent)
	local bar = parent[self.name]
	if not bar then return end

	-- Route healthPower / borders reads via GetSectionProfileForFrame so
	-- preview frames see their own per-layout settings.
	local hp = BF:GetSectionProfileForFrame("healthPower", parent)
	local bp = BF:GetSectionProfileForFrame("borders", parent)
	if not hp then return end

	-- EffectiveBorderPixels: rounded border styles use a FIXED art
	-- thickness (2/3px) regardless of the square-border thickness
	-- slider — must match Container:Layout's content inset.
	local borderN = BF:EffectiveBorderPixels(bp)
	local borderUI = PixelsToUI(borderN)
	-- Always set the full height — visibility is controlled by Update, not Layout.
	-- This prevents a height=0 bar when Layout runs while showPowerBar is off
	-- but a unit later becomes eligible for a power bar.
	local powerH = BF:Scale(hp.powerBarHeight or 4)

	bar:ClearAllPoints()
	bar:SetPoint("BOTTOMLEFT",  parent, "BOTTOMLEFT",  borderUI,  borderUI)
	bar:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -borderUI,  borderUI)
	bar:SetHeight(powerH)

	-- Apply bar texture from profile (Grid2 pattern: Bar_Layout sets self.texture)
	local pbTex = hp.useCustomPowerBarTexture and BF:ResolveBarTexture(hp.powerBarTexture) or "Interface\\Buttons\\WHITE8X8"
	bar:SetStatusBarTexture(pbTex)

	-- Background color from settings (PERF: moved here from Update — it is
	-- pure config, and Update ran it on every UNIT_POWER_UPDATE per unit).
	if bar.bg then
		local bgA = (hp.powerBarBgOpacity ~= nil) and hp.powerBarBgOpacity or 1.0
		if hp.useCustomPowerBarBgColor then
			-- Bg color fallback: read fields directly when present, else fall
			-- through to the 0.08 gray default (no fallback table alloc).
			local c = hp.powerBarBgColor
			if c then bar.bg:SetColorTexture(c.r, c.g, c.b, bgA)
			else      bar.bg:SetColorTexture(0.08, 0.08, 0.08, bgA) end
		else
			bar.bg:SetColorTexture(0.08, 0.08, 0.08, bgA)
		end
	end

	-- Fix texture snap
	local tex = bar:GetStatusBarTexture()
	if tex then
		BF:DisablePixelSnapRegion(tex)
		tex:ClearAllPoints()
		tex:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, 0)
		tex:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", 0, 0)
	end
end

-- ============================================================
-- Update: unconditionally overwrite (Grid2 pattern)
-- ============================================================
function PowerBar:Update(parent, unit)
	local bar = parent[self.name]
	if not bar then return end

	-- Pet frames: hide power bar (pets don't show power in raid frames)
	-- v93 (A2): read the cached parent header rather than calling GetParent()
	-- again. Not a meaningful saving on its own -- GetParent is a trivial C
	-- getter, so ~1-3 ms across the 31052 calls in the v93 profile -- but this
	-- function already resolves the header a second way two lines down, via
	-- ShouldShowPowerBar -> GetCachedSection/GetSectionProfileForFrame, both of
	-- which read _bf_parentHeader. One source, populated the same way they do.
	-- The cache stores `header or false`, so nil means "not resolved yet" and
	-- false is a valid "no parent" answer -- test for nil, never truthiness.
	local header = parent._bf_parentHeader
	if header == nil then
		header = parent:GetParent()
		parent._bf_parentHeader = header or false
	end
	if header and header.isPetFrame then
		bar:Hide()
		if bar.bgFrame then bar.bgFrame:Hide() end
		parent._bf_powerBarShown = false
		return
	end

	-- Check power bar visibility with frame awareness for CFG section overrides.
	if not BF:ShouldShowPowerBar(unit, parent) then
		local wasShown = bar:IsShown()
		bar:Hide()
		if bar.bgFrame then bar.bgFrame:Hide() end
		parent._powerColorType = nil
		-- Re-layout container so health bar reclaims the power bar space
		if wasShown then
			local containerInd = BF:GetIndicatorByName("container")
			if containerInd then containerInd:Layout(parent) end
			-- Power bar just disappeared: invalidate aura icon position caches
			-- so ScanAndDisplay re-anchors them to frame instead of
			-- healthBar.clipFrame (when aurasAbovePowerBar is enabled).
			BF:InvalidateAuraPositionCache(parent)
		end
		-- Maintain pre-resolved per-frame visibility flag used by the
		-- unified aura render path (RenderAuraGroup).
		parent._bf_powerBarShown = false
		return
	end

	local wasHidden = not bar:IsShown()
	bar:Show()
	if bar.bgFrame then bar.bgFrame:Show() end
	-- Re-layout container so health bar shrinks to make room
	if wasHidden then
		local containerInd = BF:GetIndicatorByName("container")
		if containerInd then containerInd:Layout(parent) end
		-- Power bar just appeared: invalidate aura icon position caches
		-- so ScanAndDisplay re-anchors them to healthBar.clipFrame
		-- instead of frame (when aurasAbovePowerBar is enabled).
		BF:InvalidateAuraPositionCache(parent)
	end
	-- Maintain pre-resolved per-frame visibility flag used by the
	-- unified aura render path (RenderAuraGroup).
	parent._bf_powerBarShown = true

	-- Background color is applied in Layout (pure config — see there).

	local powerStatus = BF.statuses and BF.statuses.power
	if not powerStatus then return end

	-- PERF: resolve the effective power type ONCE and hand it to the
	-- getters. GetPercent + GetColor each used to recompute it internally
	-- (UnitPowerType + druid class/role probe), so every UNIT_POWER_UPDATE
	-- paid the probe three times per unit.
	local powerType = powerStatus:GetPowerType(unit)

	-- Value from status (nil = inaccessible, keep last value)
	local pct = powerStatus:GetPercent(unit, powerType)
	if pct ~= nil then
		bar:SetMinMaxValues(0, 1)
		bar:SetValue(pct)
	end

	-- Color from status.
	-- PERF: power color + alpha depend only on the power TYPE (mana vs
	-- energy etc.), never on the per-tick value, so they change at most on a
	-- power-type / unit swap -- not on every UNIT_POWER_UPDATE. Guard the two
	-- widget writes (and the GetColor -> GetPowerColor lookup behind them) on
	-- the type key this function already maintains, mirroring the oUF side's
	-- _bf_powerCType guard (oUF_Shared.lua Power.PostUpdate). SetValue stays
	-- unconditional above -- the value genuinely changes every tick.
	-- Invalidation of the key: BFLayout clears it on unit recycle, the hide
	-- branch clears it above, and BF:UpdatePower clears it so a custom
	-- power-color settings edit still repaints (same-type refresh).
	if parent._powerColorType ~= powerType then
		parent._powerColorType = powerType
		local r, g, b, a = powerStatus:GetColor(unit, powerType)
		bar:SetStatusBarColor(r, g, b)
		bar:SetAlpha(a or 0.9)
	end
end

BF:RegisterIndicator(PowerBar)
