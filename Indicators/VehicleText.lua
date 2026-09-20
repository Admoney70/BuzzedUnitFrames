--[[
BuzzardFrames: Indicators/VehicleText.lua
Vehicle text — shows the vehicle name when a unit is in a vehicle.

Vehicle icon visibility and vehicle text are driven by StatusIcons:_UpdateVehicle.
]]

local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

local VehicleText = BF.indicatorPrototype:new("vehicleText")

function VehicleText:Create(parent)
	if parent.vehicleText then
		parent[self.name] = parent.vehicleText
		return
	end

	local clipParent = parent.nameClip or parent
	local hBar = parent.healthBar

	local fs = clipParent:CreateFontString(nil, "OVERLAY")
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

	local tp = BF:GetSectionProfileForFrame("text", parent) or {}
	local vnp = tp.vehicleNamePosition or { point = "CENTER", x = 0, y = 0 }
	fs:SetPoint(vnp.point, hBar or parent, vnp.point, vnp.x, vnp.y)
	fs:SetJustifyH("CENTER")
	fs:SetWordWrap(false)
	fs:Hide()

	parent[self.name] = fs
	parent.vehicleText = fs
end

function VehicleText:Layout(parent)
	local fs = parent[self.name]
	if not fs then return end
	-- Route by frame so preview frames reflect per-layout edits. See
	-- BF:GetSectionProfileForFrame.
	local tp = BF:GetSectionProfileForFrame("text", parent)
	if not tp then return end

	local hBar = parent.healthBar
	local vnp = tp.vehicleNamePosition or { point = "CENTER", x = 0, y = 0 }
	fs:ClearAllPoints()
	fs:SetPoint(vnp.point, hBar or parent, vnp.point, vnp.x, vnp.y)

	local origFont  = fs.SF_defaultFont  or "Fonts\\FRIZQT__.TTF"
	local origSize  = fs.SF_defaultSize  or 10
	local origFlags = fs.SF_defaultFlags or ""
	if tp.adjustVehicleFont then
		local fontPath = BF:ResolveFontPath(tp.vehicleFont)
		fs:SetFont(fontPath, tp.vehicleFontSize or origSize, tp.vehicleFontBorder or "")
	else
		fs:SetFont(origFont, origSize, origFlags)
	end
end

-- Vehicle text content is set by StatusIcons:_UpdateVehicle.
function VehicleText:Update(parent, unit)
end

BF:RegisterIndicator(VehicleText)
