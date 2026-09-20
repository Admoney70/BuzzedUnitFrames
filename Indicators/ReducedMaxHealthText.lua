--[[
BuzzardFrames: Indicators/ReducedMaxHealthText.lua
Temporary Reduced Max Health % text — shows the current max health
reduction percentage as a separate, independently positioned text element.

Reads parent._reducedMaxPct set by AbsorbBars:_UpdateReducedMaxHealth.
]]

local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

local UnitExists    = UnitExists
local issecretvalue = issecretvalue or function() return false end

local ReducedMaxHealthText = BF.indicatorPrototype:new("reducedMaxHealthText")

-- ============================================================
-- Create
-- ============================================================
function ReducedMaxHealthText:Create(parent)
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
	size  = size  or 9
	flags = flags or ""
	fs.SF_defaultFont  = font
	fs.SF_defaultSize  = size
	fs.SF_defaultFlags = flags
	fs:SetShadowOffset(1, -1)
	fs:SetShadowColor(0, 0, 0, 1)
	fs:SetJustifyH("CENTER")
	fs:SetTextColor(1, 0.8, 0.2)
	fs:Hide()

	parent[self.name] = fs
	parent.reducedMaxHealthText = fs
end

-- ============================================================
-- Layout
-- ============================================================
function ReducedMaxHealthText:Layout(parent)
	local fs = parent[self.name]
	if not fs then return end

	local ab = BF:GetSectionProfileForFrame("absorbs", parent)
	if not ab then return end

	-- Font
	local fontPath = BF.ResolveFontPath and BF:ResolveFontPath(ab.reducedMaxHealthFont) or fs.SF_defaultFont
	local fontSize = ab.reducedMaxHealthFontSize or fs.SF_defaultSize or 9
	local fontBorder = ab.reducedMaxHealthFontBorder or ""
	fs:SetFont(fontPath, fontSize, fontBorder)

	-- Position
	local pos = ab.reducedMaxHealthTextPosition or "BOTTOMRIGHT"
	local anchor = parent.container or parent.healthBar or parent
	fs:ClearAllPoints()
	fs:SetPoint(pos, anchor, pos, ab.reducedMaxHealthTextX or 0, ab.reducedMaxHealthTextY or 0)

	-- Color
	local c = ab.reducedMaxHealthTextColor or { r = 1, g = 0.8, b = 0.2 }
	fs:SetTextColor(c.r, c.g, c.b)
end

-- ============================================================
-- Update
-- ============================================================
function ReducedMaxHealthText:Update(parent, unit)
	local fs = parent[self.name]
	if not fs then return end

	local ab = BF:GetSectionProfileForFrame("absorbs", parent)
	if not ab or not ab.showReducedMaxHealthText or ab.appendReducedMaxText then
		fs:SetText("")
		fs:Hide()
		return
	end

	if not unit or not UnitExists(unit) then
		fs:SetText("")
		fs:Hide()
		return
	end

	local rPct = parent._reducedMaxPct
	if not rPct or issecretvalue(rPct) then
		fs:SetText("")
		fs:Hide()
		return
	end

	-- rPct is the reduction amount (0.04 = 4% reduced).
	-- Show the remaining max health: (1 - rPct) * 100
	if rPct > 0 then
		local remainPct = math.floor((1 - rPct) * 100 + 0.5)
		fs:SetFormattedText("(%d%%)", remainPct)
		fs:Show()
	else
		fs:SetText("")
		fs:Hide()
	end
end

BF:RegisterIndicator(ReducedMaxHealthText)
