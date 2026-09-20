--[[
BuzzardFrames: Indicators/StatusIcons.lua
Status icons — ready check, phased, summon pending, rez pending, vehicle.
All share the same anchor point and size from profile settings.

Grid2 equivalent: IndicatorIcon.lua instances for each status.
Each call to Update unconditionally overwrites stale state (Grid2 pattern).
]]

local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

local UnitExists          = UnitExists
local UnitIsConnected     = UnitIsConnected
local UnitHasVehicleUI    = UnitHasVehicleUI
local UnitName            = UnitName
local GetReadyCheckStatus = GetReadyCheckStatus

-- ============================================================
-- Helper: offline check (same pattern as LayoutFrame.lua)
-- ============================================================
local function SafeIsConnected(unit)
	return UnitIsConnected(unit) and "connected" or false
end


-- ============================================================

local StatusIcons = BF.indicatorPrototype:new("statusIcons")

-- ============================================================
-- Create
-- ============================================================
function StatusIcons:Create(parent)
	-- Skip if legacy InitFrame already created these
	if parent.readyCheckIcon then
		parent[self.name] = parent.readyCheckIcon
		return
	end

	local ip = BF.rpDB and BF.rpDB.profile and BF.rpDB.profile.icons or {}
	local siSize = ip.statusIconSize or 24
	local siPos = ip.statusIconPosition or { point = "CENTER", x = 0, y = 0 }

	local statusIconFrame = CreateFrame("Frame", nil, parent)
	statusIconFrame:SetAllPoints(parent)
	statusIconFrame:SetFrameLevel(parent:GetFrameLevel() + 221)
	statusIconFrame:EnableMouse(false)

	-- Ready check
	local rcFrame = CreateFrame("Frame", nil, statusIconFrame)
	rcFrame:SetSize(siSize, siSize)
	rcFrame:SetPoint(siPos.point, parent, siPos.point, siPos.x, siPos.y)
	rcFrame:SetFrameLevel(statusIconFrame:GetFrameLevel())
	local rcTex = BF.Texture(rcFrame, nil, "ARTWORK")
	rcTex:SetAllPoints(rcFrame)
	rcFrame:Hide()
	parent.readyCheckIcon = rcFrame
	parent.readyCheckIconTexture = rcTex

	-- Rez pending icon (legacy alias: resIcon)
	local resIcon = BF.Texture(statusIconFrame, nil, "OVERLAY")
	resIcon:SetSize(siSize, siSize)
	resIcon:SetPoint(siPos.point, parent, siPos.point, siPos.x, siPos.y)
	resIcon:SetAtlas("RaidFrame-Icon-Rez")
	resIcon:Hide()
	parent.resIcon = resIcon

	-- Phased
	local phasedIcon = BF.Texture(statusIconFrame, nil, "OVERLAY")
	phasedIcon:SetSize(siSize, siSize)
	phasedIcon:SetPoint(siPos.point, parent, siPos.point, siPos.x, siPos.y)
	phasedIcon:SetAtlas("RaidFrame-Icon-Phasing")
	phasedIcon:Hide()
	parent.phasedIcon = phasedIcon

	-- Summon pending
	local summonIcon = BF.Texture(statusIconFrame, nil, "OVERLAY")
	summonIcon:SetSize(siSize, siSize)
	summonIcon:SetPoint(siPos.point, parent, siPos.point, siPos.x, siPos.y)
	summonIcon:Hide()
	parent.summonIcon = summonIcon

	-- Resurrect pending
	local rezPendingIcon = BF.Texture(statusIconFrame, nil, "OVERLAY")
	rezPendingIcon:SetSize(siSize, siSize)
	rezPendingIcon:SetPoint(siPos.point, parent, siPos.point, siPos.x, siPos.y)
	rezPendingIcon:SetAtlas("RaidFrame-Icon-Rez")
	rezPendingIcon:Hide()
	parent.rezPendingIcon = rezPendingIcon

	-- Vehicle
	local vehicleIcon = BF.Texture(statusIconFrame, nil, "OVERLAY")
	vehicleIcon:SetSize(siSize, siSize)
	vehicleIcon:SetPoint(siPos.point, parent, siPos.point, siPos.x, siPos.y)
	vehicleIcon:SetAtlas("RaidFrame-Icon-Vehicle")
	vehicleIcon:Hide()
	parent.vehicleIcon = vehicleIcon

	parent[self.name] = rcFrame
end

-- ============================================================
-- Layout
-- ============================================================
function StatusIcons:Layout(parent)
	-- Route by frame (preview vs live). See RoleIcon:Layout for rationale.
	-- Pre-v26 this read from BF.db.profile.statusIcon{Position,Size} but
	-- those keys have always lived on rpDB.icons since v15 migration --
	-- the db.profile reads returned nil and fell through to the defaults.
	local ip = BF:GetSectionProfileForFrame("icons", parent)
	if not ip then return end

	local siPos  = ip.statusIconPosition or { point = "CENTER", x = 0, y = 0 }
	local siSize = ip.statusIconSize or 24

	for _, icon in pairs({ parent.readyCheckIcon, parent.resIcon, parent.phasedIcon,
	                        parent.summonIcon, parent.rezPendingIcon, parent.vehicleIcon }) do
		if icon then
			icon:SetSize(siSize, siSize)
			icon:ClearAllPoints()
			icon:SetPoint(siPos.point, parent, siPos.point, siPos.x, siPos.y)
		end
	end
end

-- ============================================================
-- Update: dispatches all five sub-indicators unconditionally
-- (Grid2 pattern — each sub-update always overwrites its own widget)
-- ============================================================
function StatusIcons:Update(parent, unit)
	-- Suppress during the first render frame after a unit assignment.
	-- UnitPhaseReason and UnitIsConnected return transient values for
	-- newly-assigned units, causing phased icons and other status icons
	-- to flash briefly. Hide all status icons and let the deferred pass
	-- re-run us with real data.
	if parent._unitJustChanged then
		if parent.readyCheckIcon then parent.readyCheckIcon:Hide() end
		if parent.phasedIcon     then parent.phasedIcon:Hide()     end
		if parent.summonIcon     then parent.summonIcon:Hide()     end
		if parent.rezPendingIcon then parent.rezPendingIcon:Hide() end
		if parent.vehicleIcon    then parent.vehicleIcon:Hide()    end
		return
	end
	self:_UpdateReadyCheck(parent, unit)
	self:_UpdatePhased(parent, unit)
	self:_UpdateSummonPending(parent, unit)
	self:_UpdateResurrectPending(parent, unit)
	self:_UpdateVehicle(parent, unit)
end

-- ============================================================
-- Sub-updates (ported from BF:UpdateReadyCheck / UpdatePhased /
-- UpdateSummonPending / UpdateResurrectPending / UpdateVehicle
-- in LayoutFrame.lua)
-- ============================================================

function StatusIcons:_UpdateReadyCheck(parent, unit)
	if not parent.readyCheckIcon or not parent.readyCheckIconTexture then return end
	local ip = BF:GetSectionProfileForFrame("icons", parent)
	if not (ip and ip.showReadyCheck) then
		parent.readyCheckIcon:Hide()
		if parent.readyCheckHideTimer then
			parent.readyCheckHideTimer:Cancel()
			parent.readyCheckHideTimer = nil
		end
		parent.readyCheckCachedStatus = nil
		return
	end

	-- Test mode: show "waiting". Preview frames only — real frames never
	-- show test icons so the game UI stays clean when the user is just
	-- previewing appearance in the options panel.
	if parent._isPreviewFrame and BF.db.global.testReadyCheck then
		parent.readyCheckIconTexture:SetTexture("Interface\\RaidFrame\\ReadyCheck-Waiting")
		parent.readyCheckIcon:Show()
		return
	end

	local status = GetReadyCheckStatus(unit)
	if status then
		parent.readyCheckCachedStatus = status
		if parent.readyCheckHideTimer then
			parent.readyCheckHideTimer:Cancel()
			parent.readyCheckHideTimer = nil
		end
		if status == "ready" then
			parent.readyCheckIconTexture:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready")
		elseif status == "notready" then
			parent.readyCheckIconTexture:SetTexture("Interface\\RaidFrame\\ReadyCheck-NotReady")
		elseif status == "waiting" then
			parent.readyCheckIconTexture:SetTexture("Interface\\RaidFrame\\ReadyCheck-Waiting")
		end
		parent.readyCheckIcon:Show()
	else
		local cachedStatus = parent.readyCheckCachedStatus
		if cachedStatus then
			if cachedStatus == "waiting" then cachedStatus = "notready" end
			if cachedStatus == "ready" then
				parent.readyCheckIconTexture:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready")
			elseif cachedStatus == "notready" then
				parent.readyCheckIconTexture:SetTexture("Interface\\RaidFrame\\ReadyCheck-NotReady")
			end
			parent.readyCheckIcon:Show()
			if not parent.readyCheckHideTimer then
				parent.readyCheckHideTimer = C_Timer.NewTimer(10, function()
					parent.readyCheckIcon:Hide()
					parent.readyCheckCachedStatus = nil
					parent.readyCheckHideTimer = nil
				end)
			end
		else
			parent.readyCheckIcon:Hide()
		end
	end
end

function StatusIcons:_UpdatePhased(parent, unit)
	if not parent.phasedIcon then return end
	local ip = BF:GetSectionProfileForFrame("icons", parent)
	if not (ip and ip.showPhased) then
		parent.phasedIcon:Hide()
		return
	end
	local isPhased
	if parent._isPreviewFrame and BF.db.global.testPhased then
		isPhased = true
	else
		-- Read from phased status instead of cache directly
		local phasedStatus = BF.statuses and BF.statuses.phased
		isPhased = phasedStatus and phasedStatus:IsActive(unit)
	end
	if isPhased then
		parent.phasedIcon:Show()
	else
		parent.phasedIcon:Hide()
	end
end

function StatusIcons:_UpdateSummonPending(parent, unit)
	if not parent.summonIcon then return end
	local ip = BF:GetSectionProfileForFrame("icons", parent)
	if not (ip and ip.showSummonPending) then
		parent.summonIcon:Hide()
		return
	end
	-- Read from summon status. Test toggle applies to preview frames only.
	local summonStatus = BF.statuses and BF.statuses.summon
	local testActive = parent._isPreviewFrame and BF.db.global.testSummonPending
	local hasSummon  = testActive or (summonStatus and summonStatus:IsActive(unit))
	if hasSummon then
		local state = (not testActive and summonStatus and summonStatus:GetState(unit)) or 1
		if state == 2 then
			parent.summonIcon:SetAtlas("RaidFrame-Icon-SummonAccepted")
		elseif state == 3 then
			parent.summonIcon:SetAtlas("RaidFrame-Icon-SummonDeclined")
		else
			parent.summonIcon:SetAtlas("RaidFrame-Icon-SummonPending")
		end
		parent.summonIcon:Show()
	else
		parent.summonIcon:Hide()
	end
end

function StatusIcons:_UpdateResurrectPending(parent, unit)
	if not parent.rezPendingIcon then return end
	local ip = BF:GetSectionProfileForFrame("icons", parent)
	if not (ip and ip.showResurrectPending) then
		parent.rezPendingIcon:Hide()
		return
	end
	-- Read from resurrect status. Test toggle applies to preview frames only.
	local resStatus = BF.statuses and BF.statuses.resurrect
	local testActive = parent._isPreviewFrame and BF.db.global.testResurrectPending
	if testActive or (resStatus and resStatus:IsActive(unit)) then
		-- Apply icon style from profile
		local style = ip and ip.resurrectPendingIconStyle or "blizzard"
		local siSize = (ip and ip.statusIconSize) or 24
		if style == "buzzard" then
			parent.rezPendingIcon:SetAtlas(nil)
			-- TRILINEAR = mipmapped filtering so the 128px art doesn't
			-- alias/jag when drawn into the small icon slot.
			parent.rezPendingIcon:SetTexture("Interface\\AddOns\\BuzzardFrames\\Media\\buzzardRes", nil, nil, "TRILINEAR")
			parent.rezPendingIcon:SetTexCoord(0, 1, 0, 1)
			-- Buzzard art fills the full texture bounds; render it a touch
			-- smaller than the Blizzard atlas (which carries its own padding).
			parent.rezPendingIcon:SetSize(siSize * 0.85, siSize * 0.85)
		else
			parent.rezPendingIcon:SetTexture(nil)
			parent.rezPendingIcon:SetTexCoord(0, 1, 0, 1)
			parent.rezPendingIcon:SetAtlas("RaidFrame-Icon-Rez")
			parent.rezPendingIcon:SetSize(siSize, siSize)
		end
		parent.rezPendingIcon:Show()
	else
		parent.rezPendingIcon:Hide()
	end
end

function StatusIcons:_UpdateVehicle(parent, unit)
	local ip = BF:GetSectionProfileForFrame("icons", parent)
	local tp = BF:GetSectionProfileForFrame("text",  parent)
	-- Read from vehicle status. Test toggle applies to preview frames only.
	local vehicleStatus = BF.statuses and BF.statuses.vehicle
	local testActive = parent._isPreviewFrame and BF.db.global.testVehicleIcon
	local inVehicle = (ip and testActive)
		or (vehicleStatus and vehicleStatus:IsActive(unit))

	if parent.vehicleIcon then
		if ip and ip.showVehicleIcon and inVehicle then
			parent.vehicleIcon:Show()
		else
			parent.vehicleIcon:Hide()
		end
	end

	if parent.vehicleText then
		-- v68 FIX: this branch used to require `owner and UnitExists(owner)`
		-- where `owner` was an UNDEFINED global (always nil) — the vehicle
		-- name could never show, for ANY vehicle type. Name resolution now
		-- goes through the status, which handles both remapped UI-vehicle
		-- units and non-remapped multi-seat vehicles (pet-slot lookup).
		if tp and tp.showVehicleName and inVehicle then
			local vehicleName = (vehicleStatus and vehicleStatus:GetVehicleName(unit))
				or (UnitExists(unit) and UnitName(unit)) or ""
			if tp.abbreviateVehicleNames and #vehicleName > (tp.maxVehicleNameChars or 8) then
				vehicleName = vehicleName:sub(1, tp.maxVehicleNameChars or 8)
			end
			parent.vehicleText:SetText(vehicleName)
			parent.vehicleText:SetTextColor(1, 1, 1)
			parent.vehicleText:Show()
		else
			parent.vehicleText:Hide()
		end
	end
end

BF:RegisterIndicator(StatusIcons)
