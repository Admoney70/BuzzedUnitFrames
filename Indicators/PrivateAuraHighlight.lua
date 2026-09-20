--[[
BuzzardFrames: Indicators/PrivateAuraHighlight.lua
Private aura border indicator.
]]

local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

local PrivateAuraHighlight = BF.indicatorPrototype:new("privateAuraHighlight")

local function MakeEdge(parent)
	local t = parent:CreateTexture(nil, "OVERLAY")
	t:SetColorTexture(0, 0, 0, 0)
	return t
end

local function PixelsToUI(n)
	local pixelSize = 768 / select(2, GetPhysicalScreenSize())
	local uiScale = UIParent:GetEffectiveScale()
	local pixelMult = (uiScale > 0) and (pixelSize / uiScale) or 1
	return n * pixelMult
end

function PrivateAuraHighlight:Create(parent)
	if parent.privateAuraHighlight then
		parent[self.name] = parent.privateAuraHighlight
		return
	end

	local frame = CreateFrame("Frame", nil, parent)
	frame:SetAllPoints(parent)
	frame:SetFrameLevel(parent:GetFrameLevel() + 12)
	frame:EnableMouse(false)
	frame.top    = MakeEdge(frame)
	frame.bottom = MakeEdge(frame)
	frame.left   = MakeEdge(frame)
	frame.right  = MakeEdge(frame)

	parent[self.name] = frame
	parent.privateAuraHighlight = frame
end

function PrivateAuraHighlight:Layout(parent)
	local frame = parent[self.name]
	if not frame then return end
	local p = BF.db and BF.db.profile
	if not p then return end

	local pa = frame
	local paT = PixelsToUI(p.privateAuraBorderWidth or 2)
	if pa.top and pa.bottom and pa.left and pa.right then
		pa.top:ClearAllPoints(); pa.top:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0); pa.top:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0); pa.top:SetHeight(paT)
		pa.bottom:ClearAllPoints(); pa.bottom:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 0, 0); pa.bottom:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0); pa.bottom:SetHeight(paT)
		pa.left:ClearAllPoints(); pa.left:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0); pa.left:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 0, 0); pa.left:SetWidth(paT)
		pa.right:ClearAllPoints(); pa.right:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0); pa.right:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0); pa.right:SetWidth(paT)
	end
end

function PrivateAuraHighlight:Update(parent, unit)
	local frame = parent[self.name]
	if not frame then return end
	local p = BF.db and BF.db.profile
	local enabled = p and p.enablePrivateAuraBorder
	local active  = parent._privateAuraActive
	if enabled and active then
		local c = (p and p.privateAuraBorderColor) or { r=1, g=0.5, b=0, a=1 }
		BF:SetBorderColor(frame, c.r, c.g, c.b, c.a or 1)
	else
		BF:SetBorderColor(frame, 0, 0, 0, 0)
	end
end

BF:RegisterIndicator(PrivateAuraHighlight)
