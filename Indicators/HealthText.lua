--[[
BuzzardFrames: Indicators/HealthText.lua
Health text indicator — shows current HP as percent/current/deficit.

Grid2 equivalent: IndicatorText.lua bound to StatusHealth.

Each call to Update unconditionally overwrites stale state (Grid2 pattern).
]]

local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

local UnitHealth          = UnitHealth
local UnitHealthMax       = UnitHealthMax
local UnitHealthPercent   = UnitHealthPercent
local UnitHealthMissing   = UnitHealthMissing
local UnitExists          = UnitExists
local UnitClass           = UnitClass
local AbbreviateLargeNumbers = AbbreviateLargeNumbers
local issecretvalue       = issecretvalue or function() return false end
local ScaleTo100          = CurveConstants and CurveConstants.ScaleTo100

local HealthText = BF.indicatorPrototype:new("healthText")

-- v99 PERF: status handles, resolved once. Update re-read
-- `BF.statuses and BF.statuses.health` (and .offline and .death) on every
-- health tick for every frame -- six table lookups x 42,585 calls in a 456 s
-- raid window. Initialization.lua already hoists these exact objects as
-- S_HEALTH / S_POWER / S_ABSORBS; this indicator just never did.
-- Resolved LAZILY, not at file scope: BF.statuses is populated by
-- BF:RegisterStatus as BFStatus.lua loads, which is not guaranteed to have
-- run when this file is parsed. First Update after the statuses exist binds
-- them for the rest of the session (statuses are created once at load and
-- never replaced -- only enabled/disabled, which these handles do not cache).
local S_HEALTH, S_OFFLINE, S_DEATH
local function ResolveStatuses()
	local st = BF.statuses
	if not st then return false end
	S_HEALTH  = st.health
	S_OFFLINE = st.offline
	S_DEATH   = st.death
	return S_HEALTH ~= nil
end

-- ============================================================
-- Create
-- ============================================================
function HealthText:Create(parent)
	-- Skip if already created by legacy InitFrame
	if parent.healthText then
		parent[self.name] = parent.healthText
		return
	end

	local textFrame = parent.textFrame
	if not textFrame then
		textFrame = CreateFrame("Frame", nil, parent)
		textFrame:SetAllPoints(parent)
		textFrame:SetFrameLevel(parent:GetFrameLevel() + 216)
		textFrame:EnableMouse(false)
		parent.textFrame = textFrame
	end

	local fs = textFrame:CreateFontString(nil, "OVERLAY")
	fs:SetFontObject(GameFontNormalSmall)
	local font, size, flags = fs:GetFont()
	font  = font  or BF.font or "Fonts\\FRIZQT__.TTF"
	size  = size  or 10
	flags = flags or ""
	fs.SF_defaultFont  = font
	fs.SF_defaultSize  = size
	fs.SF_defaultFlags = flags
	fs:SetShadowOffset(1, -1)
	fs:SetShadowColor(0, 0, 0, 1)
	fs:SetJustifyH("CENTER")

	local hBar = parent.healthBar
	-- Route via GetSectionProfile for the initial position / color read -- Create
	-- is called once per frame, typically early enough that the active context
	-- isn't set yet; fall back to the global via activeFlat=nil.
	local tpInit = BF:GetSectionProfile("text", nil)
	local pos = (tpInit and tpInit.healthTextPosition) or "CENTER"
	local anchor = parent.container or hBar or parent
	fs:SetPoint(pos, anchor, pos, 0, 0)

	local c = (tpInit and tpInit.healthTextColor) or { r = 1, g = 1, b = 1 }
	fs:SetTextColor(c.r, c.g, c.b, c.a or 1)

	parent[self.name] = fs
	parent.healthText = fs  -- backward compat alias
end

-- ============================================================
-- _StampConfig (v94 PERF, Win 4)
-- ============================================================
-- Resolve the text + absorbs section config ONCE and cache it on the frame
-- as _bf_htCfg, so per-tick Update reads plain fields instead of two
-- GetCachedSection calls + a rebuilt percent format + the reduced-max
-- toggle test every UNIT_HEALTH tick. Same source as the old Update path.
-- Staleness is handled exactly like AbsorbBars._absorbStyleGen: _bf_htCfgGen
-- is stamped from BF._sectionCfgGen, which Core_ProfileAPI bumps on every
-- section-cache invalidation (settings edit OR party<->raid context change);
-- Update re-stamps when the two differ. Returns the cfg table, or nil when
-- the text section is unavailable (mirrors the old "not tp" hide path).
function HealthText:_StampConfig(parent)
	local tp = BF:GetCachedSection("text", parent)
	if not tp then parent._bf_htCfg = nil return nil end
	local ab = BF:GetCachedSection("absorbs", parent)

	local cfg = parent._bf_htCfg
	if not cfg then cfg = {} parent._bf_htCfg = cfg end
	cfg.show        = tp.showHealthText and true or false
	cfg.format      = tp.healthTextFormat
	cfg.pctFmt      = (tp.healthTextPctSymbol ~= false) and "%d%%" or "%d"
	cfg.adjustColor = tp.adjustHealthTextColor and true or false
	cfg.classColor  = tp.classColorHealthText and true or false
	local col = tp.healthTextColor
	cfg.colR = col and col.r or 1
	cfg.colG = col and col.g or 1
	cfg.colB = col and col.b or 1
	cfg.colA = col and col.a or 1
	cfg.appendReducedMax = (ab and ab.showReducedMaxHealthText and ab.appendReducedMaxText
	                        and (ab.appendReducedMaxTarget or "health") == "health") and true or false
	local rmc = ab and ab.reducedMaxHealthTextColor
	if rmc then
		cfg.rmR, cfg.rmG, cfg.rmB, cfg.rmA = rmc.r, rmc.g, rmc.b, rmc.a or 1
	else
		cfg.rmR = nil
	end
	parent._bf_htCfgGen = BF._sectionCfgGen or 0
	return cfg
end

-- ============================================================
-- Layout
-- ============================================================
function HealthText:Layout(parent)
	local fs = parent[self.name]
	if not fs then return end

	-- Route by frame: preview frames → own flat; live frames → active
	-- game context. See BF:GetSectionProfileForFrame.
	local tp = BF:GetSectionProfileForFrame("text", parent)
	if not tp then return end

	local origFont  = fs.SF_defaultFont  or "Fonts\\FRIZQT__.TTF"
	local origSize  = fs.SF_defaultSize  or 10
	local origFlags = fs.SF_defaultFlags or ""
	if tp.adjustHealthFont then
		local fontPath = BF:ResolveFontPath(tp.healthFont)
		fs:SetFont(fontPath, tp.healthFontSize, tp.healthFontBorder or "")
	else
		fs:SetFont(origFont, origSize, origFlags)
	end

	local hBar = parent.healthBar
	local htPos = tp.healthTextPosition or "CENTER"
	fs:ClearAllPoints()
	local anchor = parent.container or hBar or parent
	fs:SetPoint(htPos, anchor, htPos, tp.healthTextX or 0, tp.healthTextY or 0)

	-- Static color (class color is applied per-unit in Update)
	if tp.adjustHealthTextColor and not tp.classColorHealthText then
		local c = tp.healthTextColor or { r = 1, g = 1, b = 1 }
		fs:SetTextColor(c.r, c.g, c.b, c.a or 1)
	elseif not tp.adjustHealthTextColor then
		fs:SetTextColor(1, 1, 1)
	end

	-- v94 PERF (Win 4): stamp text config so Update reads plain fields.
	HealthText:_StampConfig(parent)
end

-- ============================================================
-- Update: unconditionally overwrite (Grid2 pattern)
-- ============================================================
-- v99: the shared hide path for every early return in Update. Guarded so a
-- dead or offline unit stops paying two widget calls per health tick. Text is
-- cleared only on the transition into hidden; a hidden FontString shows
-- nothing regardless of what it holds, and the show path always rewrites it.
--
-- The guard READS THE WIDGET rather than caching a flag on the frame, and
-- that is deliberate. StatusText_Overlay hides parent.healthText directly at
-- three sites (and the preview data path Shows/Hides it too), all behind this
-- indicator's back. A cached "is shown" flag would go stale the moment the
-- overlay hid it: the flag would still read shown, the show path below would
-- skip its Show(), and the health text would stay invisible until something
-- unrelated reset it. IsShown() is a plain C getter, not a secret value, and
-- it is also immune to frame recycling -- no reset hook to remember anywhere.
local function HideText(fs)
	if fs:IsShown() then
		fs:SetText("")
		fs:Hide()
	end
end

function HealthText:Update(parent, unit)
	local fs = parent[self.name]
	if not fs then return end

	-- v94 PERF (Win 4): read stamped per-frame config instead of two
	-- GetCachedSection calls per tick. Gen gate (mirrors AbsorbBars): re-
	-- stamp when the frame cfg is missing or BF._sectionCfgGen has moved
	-- (any settings edit or party<->raid context change bumps it).
	local cfg = parent._bf_htCfg
	if cfg == nil or parent._bf_htCfgGen ~= (BF._sectionCfgGen or 0) then
		cfg = HealthText:_StampConfig(parent)
	end

	-- Read from statuses instead of WoW APIs directly (v99: hoisted upvalues).
	local healthStatus = S_HEALTH
	if healthStatus == nil and ResolveStatuses() then healthStatus = S_HEALTH end
	local offlineStatus, deathStatus = S_OFFLINE, S_DEATH

	-- Grid2 pattern: always overwrite — decide visibility fresh every call
	if not cfg or not cfg.show or not unit
	   or not healthStatus or not healthStatus:IsActive(unit) then
		HideText(fs)
		return
	end

	local maxHealth = healthStatus:GetMaxHealth(unit)
	-- Hide when maxHealth is 0 (unit data not yet available)
	if not issecretvalue(maxHealth) and maxHealth <= 0 then
		HideText(fs)
		return
	end

	-- Dead/offline units: hide health text (other indicators own the dead/offline display)
	if offlineStatus and offlineStatus:IsActive(unit) then
		HideText(fs)
		return
	end
	if deathStatus and deathStatus:IsActive(unit) then
		HideText(fs)
		return
	end

	-- v99 PERF: transition-gated (see HideText for why this reads the widget
	-- instead of caching). Show() ran unconditionally on every health tick, and
	-- each hide path paid SetText("") + Hide() every tick for as long as a unit
	-- stayed dead or offline.
	if not fs:IsShown() then
		fs:Show()
	end

	-- Color: always set the normal health text color (mirrors NameText pattern).
	-- This ensures the color is restored every Update cycle, so transient
	-- overrides (e.g. reduced max health) don't persist once the status clears.
	if cfg.adjustColor and cfg.classColor then
		local className = healthStatus:GetClass(unit)
		if className and BF.classColors and BF.classColors[className] then
			local c = BF.classColors[className]
			fs:SetTextColor(c.r, c.g, c.b, c.a or 1)
		end
	elseif cfg.adjustColor then
		fs:SetTextColor(cfg.colR, cfg.colG, cfg.colB, cfg.colA)
	else
		fs:SetTextColor(1, 1, 1)
	end

	-- Format: read values from health status
	local fmt = cfg.format
	local baseText
	if fmt == "percent" then
		baseText = string.format(cfg.pctFmt, healthStatus:GetPercentText(unit))
	elseif fmt == "current" then
		baseText = healthStatus:GetCurrentText(unit)
	elseif fmt == "deficit" then
		baseText = "-" .. healthStatus:GetMissingText(unit)
	end

	-- Append reduced max health text if option is enabled and target is health
	local _reducedMaxAppendedToHealth = false
	local rPct = parent._reducedMaxPct
	if baseText and cfg.appendReducedMax
	   and rPct and not issecretvalue(rPct) and rPct > 0 then
		local remainPct = math.floor((1 - rPct) * 100 + 0.5)
		baseText = baseText .. string.format(" (%d%%)", remainPct)
		_reducedMaxAppendedToHealth = true
	end

	-- Set the final text (base, or base + reduced max suffix)
	if baseText then
		fs:SetText(baseText)
	end

	-- Override color with reduced max health text color if appended
	if _reducedMaxAppendedToHealth and cfg.rmR then
		fs:SetTextColor(cfg.rmR, cfg.rmG, cfg.rmB, cfg.rmA)
	end
end

BF:RegisterIndicator(HealthText)
