--[[
BuzzardFrames: Indicators/LeaderIcon.lua
Leader and assistant icons.
]]

local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

local UnitExists            = UnitExists
local UnitIsGroupLeader     = UnitIsGroupLeader
local UnitIsGroupAssistant  = UnitIsGroupAssistant

local LeaderIcon = BF.indicatorPrototype:new("leaderIcon")

function LeaderIcon:Create(parent)
	if parent.leaderIcon then
		parent[self.name] = parent.leaderIcon
		return
	end

	local ip = BF.rpDB and BF.rpDB.profile and BF.rpDB.profile.icons or {}

	-- Leader icon
	local lFrame = CreateFrame("Frame", nil, parent)
	lFrame:SetSize(ip.leaderIconSize or 12, ip.leaderIconSize or 12)
	local lPos = ip.leaderIconPosition or { point = "TOPLEFT", x = 2, y = -2 }
	lFrame:SetPoint(lPos.point, parent, lPos.point, lPos.x, lPos.y)
	lFrame:SetFrameLevel(parent:GetFrameLevel() + 219)
	local lTex = BF.Texture(lFrame, nil, "ARTWORK")
	lTex:SetAllPoints(lFrame)
	lTex:SetTexture("Interface\\GroupFrame\\UI-Group-LeaderIcon")
	lFrame:Hide()
	parent.leaderIcon = lFrame
	parent.leaderIconTexture = lTex

	-- Assistant icon
	local aFrame = CreateFrame("Frame", nil, parent)
	aFrame:SetSize(ip.assistantIconSize or 12, ip.assistantIconSize or 12)
	local aPos = ip.assistantIconPosition or { point = "TOPLEFT", x = 2, y = -2 }
	aFrame:SetPoint(aPos.point, parent, aPos.point, aPos.x, aPos.y)
	aFrame:SetFrameLevel(parent:GetFrameLevel() + 219)
	local aTex = BF.Texture(aFrame, nil, "ARTWORK")
	aTex:SetAllPoints(aFrame)
	aTex:SetTexture("Interface\\GroupFrame\\UI-Group-AssistantIcon")
	aFrame:Hide()
	parent.assistantIcon = aFrame
	parent.assistantIconTexture = aTex

	parent[self.name] = lFrame
end

function LeaderIcon:Layout(parent)
	-- Route by frame (preview vs live). See RoleIcon:Layout for rationale.
	local ip = BF:GetSectionProfileForFrame("icons", parent)
	if not ip then return end

	if parent.leaderIcon then
		parent.leaderIcon:SetSize(ip.leaderIconSize or 12, ip.leaderIconSize or 12)
		local lPos = ip.leaderIconPosition or { point = "TOPLEFT", x = 2, y = -2 }
		parent.leaderIcon:ClearAllPoints()
		parent.leaderIcon:SetPoint(lPos.point, parent, lPos.point, lPos.x, lPos.y)
	end
	if parent.assistantIcon then
		parent.assistantIcon:SetSize(ip.assistantIconSize or 12, ip.assistantIconSize or 12)
		local aPos = ip.assistantIconPosition or { point = "TOPLEFT", x = 2, y = -2 }
		parent.assistantIcon:ClearAllPoints()
		parent.assistantIcon:SetPoint(aPos.point, parent, aPos.point, aPos.x, aPos.y)
	end
end

function LeaderIcon:Update(parent, unit)
	if not unit or not UnitExists(unit) then
		if parent.leaderIcon then parent.leaderIcon:Hide() end
		if parent.assistantIcon then parent.assistantIcon:Hide() end
		return
	end
	local ip = BF:GetSectionProfileForFrame("icons", parent)

	-- Read from leader status instead of WoW API directly
	local leaderStatus = BF.statuses and BF.statuses.leader

	-- Leader
	if parent.leaderIcon then
		if ip and ip.showLeaderIcon and leaderStatus and leaderStatus:IsLeader(unit) then
			parent.leaderIcon:Show()
		else
			parent.leaderIcon:Hide()
		end
	end

	-- Assistant
	if parent.assistantIcon then
		if ip and ip.showAssistantIcon and leaderStatus and leaderStatus:IsAssistant(unit) then
			parent.assistantIcon:Show()
		else
			parent.assistantIcon:Hide()
		end
	end
end

BF:RegisterIndicator(LeaderIcon)
