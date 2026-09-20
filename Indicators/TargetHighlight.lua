--[[
BuzzardFrames: Indicators/TargetHighlight.lua
Target highlight border indicator — shows a colored border when the
frame's unit is the player's current target.

Grid2 equivalent: IndicatorBorder.lua bound to StatusTarget.

Each call to Update unconditionally overwrites stale state (Grid2 pattern).
]]

local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

local UnitIsUnit = UnitIsUnit
local UnitExists = UnitExists

local TargetHighlight = BF.indicatorPrototype:new("targetHighlight")

-- ============================================================
local function MakeEdge(parent)
	local t = BF.Texture(parent, nil, "OVERLAY")
	t:SetColorTexture(0, 0, 0, 1)
	return t
end

local function PixelsToUI(n)
	local pixelSize = 768 / select(2, GetPhysicalScreenSize())
	local uiScale = UIParent:GetEffectiveScale()
	local pixelMult = (uiScale > 0) and (pixelSize / uiScale) or 1
	return n * pixelMult
end

-- ============================================================
-- Create
-- ============================================================
function TargetHighlight:Create(parent)
	-- Skip if already created by legacy InitFrame
	if parent.targetHighlight then
		parent[self.name] = parent.targetHighlight
		return
	end

	local frame = CreateFrame("Frame", nil, parent)
	frame:SetAllPoints(parent)
	frame:SetFrameLevel(parent:GetFrameLevel() + 13)
	frame:EnableMouse(false)
	frame.top    = MakeEdge(frame)
	frame.bottom = MakeEdge(frame)
	frame.left   = MakeEdge(frame)
	frame.right  = MakeEdge(frame)

	parent[self.name] = frame
	parent.targetHighlight = frame  -- backward compat alias
end

-- ============================================================
-- Layout
-- ============================================================
function TargetHighlight:Layout(parent)
	local frame = parent[self.name]
	if not frame then return end

	-- Route borders reads via GetSectionProfileForFrame so preview frames
	-- see their own per-layout settings (matches Container.lua pattern).
	local bp = BF:GetSectionProfileForFrame("borders", parent)
	if not bp then return end

	local t = frame.top
	local b = frame.bottom
	local l = frame.left
	local r = frame.right
	if not (t and b and l and r) then return end

	local targetT = PixelsToUI(bp.targetHighlightWidth or 2)

	t:ClearAllPoints()
	t:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
	t:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)
	t:SetHeight(targetT)

	b:ClearAllPoints()
	b:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 0, 0)
	b:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0)
	b:SetHeight(targetT)

	-- Corners inset so top/bottom edges don't overlap left/right
	l:ClearAllPoints()
	l:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -targetT)
	l:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 0, targetT)
	l:SetWidth(targetT)

	r:ClearAllPoints()
	r:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -targetT)
	r:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, targetT)
	r:SetWidth(targetT)
end

-- ============================================================
-- Update: unconditionally overwrite (Grid2 pattern)
-- ============================================================
function TargetHighlight:Update(parent, unit)
	local frame = parent[self.name]
	if not frame then return end

	local bp = BF:GetSectionProfileForFrame("borders", parent)

	-- Grid2 pattern: always recompute, always set color
	local enabled = not bp or bp.enableTargetHighlight ~= false
	local opacity = (bp and bp.targetHighlightOpacity) or 1.0
	local c = (bp and bp.targetHighlightColor) or { r = 1, g = 1, b = 1 }

	-- Read from target status instead of WoW API directly
	local targetStatus = BF.statuses and BF.statuses.target
	-- SetHighlightBorder: rounded border styles draw a tinted nine-slice
	-- ring (matching the frame's rounded thickness) and hide the 4 square
	-- edges; square style behaves exactly as SetBorderColor did.
	-- Raid-style twins never draw the target highlight (plan decision 7.6):
	-- the target twin's token IS "target" so it would be permanently lit,
	-- and player/focus/boss twins follow the same rule. Per FRAME, not per
	-- unit -- in a party the "player" token is shared by the party frame
	-- (which must still light up) and the player twin.
	if enabled and not parent._bf_twinKey and targetStatus and targetStatus:IsActive(unit) then
		BF:SetHighlightBorder(frame, parent, c.r, c.g, c.b, opacity,
			(bp and bp.targetHighlightWidth) or 2)
	else
		BF:SetHighlightBorder(frame, parent, 0, 0, 0, 0)
	end
end

BF:RegisterIndicator(TargetHighlight)
