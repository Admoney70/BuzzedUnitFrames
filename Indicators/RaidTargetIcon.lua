--[[
BuzzardFrames: Indicators/RaidTargetIcon.lua
Raid target marker icon (skull, cross, moon, etc.)
]]

local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

local UnitExists       = UnitExists
local GetRaidTargetIndex = GetRaidTargetIndex

local RaidTargetIcon = BF.indicatorPrototype:new("raidTargetIcon")

function RaidTargetIcon:Create(parent)
	if parent.raidTargetIcon then
		parent[self.name] = parent.raidTargetIcon
		return
	end

	local ip = BF.rpDB and BF.rpDB.profile and BF.rpDB.profile.icons or {}
	local size = ip.raidTargetIconSize or 16
	local rtPos = ip.raidTargetIconPosition or { point = "CENTER", x = 0, y = 0 }

	local frame = CreateFrame("Frame", nil, parent)
	frame:SetSize(size, size)
	frame:SetPoint(rtPos.point, parent, rtPos.point, rtPos.x, rtPos.y)
	frame:SetFrameLevel(parent:GetFrameLevel() + 220)
	frame:Hide()

	local tex = BF.Texture(frame, nil, "ARTWORK")
	tex:SetAllPoints(frame)

	parent[self.name] = frame
	parent.raidTargetIcon = frame
	parent.raidTargetIconTexture = tex
end

function RaidTargetIcon:Layout(parent)
	local frame = parent[self.name]
	if not frame then return end
	-- Route by frame (preview vs live). See RoleIcon:Layout for rationale.
	local ip = BF:GetSectionProfileForFrame("icons", parent)
	if not ip then return end

	frame:SetSize(ip.raidTargetIconSize or 16, ip.raidTargetIconSize or 16)
	local rtPos = ip.raidTargetIconPosition or { point = "CENTER", x = 0, y = 0 }
	frame:ClearAllPoints()
	frame:SetPoint(rtPos.point, parent, rtPos.point, rtPos.x, rtPos.y)
end

function RaidTargetIcon:Update(parent, unit)
	local frame = parent[self.name]
	if not frame then return end
	local ip = BF:GetSectionProfileForFrame("icons", parent)

	if not ip or not ip.showRaidTargetIcon or not unit or not UnitExists(unit) then
		frame:Hide()
		return
	end

	-- Read from raidicon status instead of WoW API directly.
	-- NOTE: `index` is a SECRET number under addon taint (12.1) — truth-test
	-- and render-API use only, never compare it.
	local raidIconStatus = BF.statuses and BF.statuses.raidicon
	local index = raidIconStatus and raidIconStatus:GetIndex(unit)
	if index then
		local tex = parent.raidTargetIconTexture
		if tex then
			tex:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcons")
			tex:SetSpriteSheetCell(index, 4, 4, 64, 64)
		end
		frame:Show()
	else
		frame:Hide()
	end
end

BF:RegisterIndicator(RaidTargetIcon)
