--[[
BuzzardFrames: Indicators/PingIndicator.lua
Ping pin on raid/party frames.

The ping-pin events (UNIT_PING_PIN_ADDED/REMOVED) and Blizzard's
UnitPingIconFrameTemplate are both closed to addons, so this indicator
holds only the textures. They are driven by the shared ping mirror in
PingMirror.lua (BF:EnsurePingMirror), which watches the default UI's
compact-frame receivers and pushes show/hide + texture kit onto the
matching BuzzardFrames frame by GUID. That mirror is module-neutral: it
runs whether or not the unit frames module is enabled. /bf pingtest drives them
directly for testing.
]]

local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

local UnitExists = UnitExists

local PingIndicator = BF.indicatorPrototype:new("pingIndicator")

local DEFAULT_SIZE = 24
local DEFAULT_POS  = { point = "CENTER", x = 0, y = 0 }

function PingIndicator:Create(parent)
	if parent.pingIndicatorTex then
		parent[self.name] = parent.pingIndicatorFrame
		return
	end

	local ip = BF.rpDB and BF.rpDB.profile and BF.rpDB.profile.icons or {}
	local size = ip.pingIndicatorSize or DEFAULT_SIZE
	local pos  = ip.pingIndicatorPosition or DEFAULT_POS

	local frame = CreateFrame("Frame", nil, parent)
	frame:SetSize(size, size)
	frame:SetPoint(pos.point, parent, pos.point, pos.x, pos.y)
	frame:SetFrameLevel(parent:GetFrameLevel() + 221)
	frame:EnableMouse(false)

	-- Background must sub-layer BELOW the pin (same contract as the
	-- unit-frame widget in oUF_Shared.lua).
	local bg = BF.Texture(frame, nil, "OVERLAY", nil, 1)
	bg:SetAllPoints(frame)
	bg:Hide()
	local pin = BF.Texture(frame, nil, "OVERLAY", nil, 2)
	pin:SetAllPoints(frame)
	pin:Hide()
	pin.Background = bg
	pin.isRaidPin  = true -- gated by icons.showPingIndicator, not the oUF toggle
	-- Same shape as the oUF widget so the mirror can drive both.
	pin.PostUpdate = function(el)
		if el.Background then el.Background:SetShown(el:IsShown()) end
	end

	parent[self.name]         = frame
	parent.pingIndicatorFrame = frame
	parent.pingIndicatorTex   = pin
end

function PingIndicator:Layout(parent)
	local frame = parent[self.name]
	if not frame then return end
	-- Route by frame (preview vs live). See RoleIcon:Layout for rationale.
	local ip = BF:GetSectionProfileForFrame("icons", parent)
	if not ip then return end

	local size = ip.pingIndicatorSize or DEFAULT_SIZE
	frame:SetSize(size, size)
	local pos = ip.pingIndicatorPosition or DEFAULT_POS
	frame:ClearAllPoints()
	frame:SetPoint(pos.point, parent, pos.point, pos.x, pos.y)
end

-- The mirror shows/hides the pin; Update only enforces the toggle and
-- clears a pin whose unit has changed under it (roster shuffles).
function PingIndicator:Update(parent, unit)
	local pin = parent.pingIndicatorTex
	if not pin then return end
	local ip = BF:GetSectionProfileForFrame("icons", parent)
	if not ip or not ip.showPingIndicator or not unit or not UnitExists(unit) then
		pin:Hide(); pin:PostUpdate(nil); pin._mirrorKey = false
		return
	end
	-- v97: secret-safe read (same sanitizer the mirror uses). UnitGUID is a
	-- SECRET under combat secrecy and comparing it raw throws, aborting the
	-- rest of this frame's indicator sweep. Unreadable => cannot be matched
	-- to a receiver => hide, the same arm an absent unit takes.
	local guid = BF.SafePingGUID and BF.SafePingGUID(unit) or nil
	if not guid or (pin._pingGUID and pin._pingGUID ~= guid) then
		pin:Hide(); pin:PostUpdate(nil); pin._mirrorKey = false
	end
	pin._pingGUID = guid
end

BF:RegisterIndicator(PingIndicator)
