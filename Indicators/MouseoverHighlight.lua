--[[
BuzzardFrames: Indicators/MouseoverHighlight.lua
Mouseover highlight — a white overlay on the health bar when hovered.
]]

local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

local MouseoverHighlight = BF.indicatorPrototype:new("mouseoverHighlight")

function MouseoverHighlight:Create(parent)
	if parent.mouseoverHighlight then
		parent[self.name] = parent.mouseoverHighlight
		return
	end

	local hBar = parent.healthBar
	if not hBar then return end

	local tex = BF.Texture(hBar, nil, "OVERLAY", nil, 7)
	tex:SetAllPoints(hBar)
	tex:SetTexture("Interface\\Buttons\\WHITE8x8")
	tex:SetColorTexture(1, 1, 1, 0)

	parent[self.name] = tex
	parent.mouseoverHighlight = tex
end

function MouseoverHighlight:Layout(parent)
	-- Anchored to healthBar via SetAllPoints — no repositioning needed
end

-- Mouseover is driven by OnEnter/OnLeave hooks, not by unit data.
function MouseoverHighlight:Update(parent, unit)
end

function MouseoverHighlight:GetFrame(parent)
	return parent[self.name]
end

BF:RegisterIndicator(MouseoverHighlight)
