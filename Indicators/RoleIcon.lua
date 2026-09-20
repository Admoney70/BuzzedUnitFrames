--[[
BuzzardFrames: Indicators/RoleIcon.lua
Role icon indicator — shows tank/healer/dps icon per unit.

Grid2 equivalent: IndicatorIcon.lua bound to StatusRole.

Each call to Update unconditionally overwrites stale state (Grid2 pattern).
]]

local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

local UnitExists              = UnitExists
local UnitIsUnit              = UnitIsUnit
local UnitGroupRolesAssigned  = UnitGroupRolesAssigned
local GetSpecialization       = GetSpecialization
local GetSpecializationRole   = GetSpecializationRole

local RoleIcon = BF.indicatorPrototype:new("roleIcon")

-- ============================================================
-- Create
-- ============================================================
function RoleIcon:Create(parent)
	-- Skip if already created by legacy InitFrame
	if parent.roleIcon then
		parent[self.name] = parent.roleIcon
		return
	end

	-- Use a dedicated Frame parented directly to the unit frame (not nameClip)
	-- so the icon is never clipped when it extends outside the frame bounds.
	-- This matches the LeaderIcon pattern.
	local ip = BF.rpDB and BF.rpDB.profile and BF.rpDB.profile.icons
	local size = ip and ip.roleIconSize or 12

	local iconFrame = CreateFrame("Frame", nil, parent)
	iconFrame:SetSize(size, size)
	iconFrame:SetPoint("TOPLEFT", parent.healthBar or parent, "TOPLEFT", 1, -1)
	iconFrame:SetFrameLevel(parent:GetFrameLevel() + 218)
	local tex = BF.Texture(iconFrame, nil, "ARTWORK")
	tex:SetAllPoints(iconFrame)
	iconFrame.texture = tex
	iconFrame:Hide()

	parent[self.name] = iconFrame
	parent.roleIcon = iconFrame  -- backward compat alias
end

-- ============================================================
-- Layout
-- ============================================================
function RoleIcon:Layout(parent)
	local icon = parent[self.name]
	if not icon then return end

	-- Route by frame: preview frames resolve to their own flat (set via
	-- parent._flatID) so the options preview reflects per-layout edits;
	-- live frames resolve via active game context, matching RoleIcon:Update.
	local ip = BF:GetSectionProfileForFrame("icons", parent)
	if not ip then return end

	icon:SetSize(ip.roleIconSize or 12, ip.roleIconSize or 12)
	icon:ClearAllPoints()

	local rp = ip.roleIconPosition or { point = "TOPLEFT", x = 2, y = -2 }
	icon:SetPoint(rp.point, parent, rp.point, rp.x, rp.y)
end

-- ============================================================
-- Name repositioning when role icon is hidden for this unit.
-- NameText:Layout sets the name offset assuming the role icon
-- is visible. When the icon is hidden (globally, per-role, or
-- per-CF-module), we reposition the name with a small inset
-- so it doesn't sit flush against the frame edge.
-- ============================================================
local HIDDEN_ROLE_NAME_INSET = 3

local function AdjustNameForHiddenRole(parent)
	local fs = parent.nameText
	if not fs then return end
	-- Route by frame so preview frames see their own flat's text+icons
	-- sections while live frames see the active game context's flat.
	-- Matches NameText:Layout routing exactly.
	local tp = BF:GetSectionProfileForFrame("text",  parent)
	local ip = BF:GetSectionProfileForFrame("icons", parent)
	if not tp or not tp.namePosition or (tp and tp.linkNameAndRole) then return end
	local np = tp.namePosition
	local rp = ip and ip.roleIconPosition or { point = "TOPLEFT", x = 2, y = -2 }
	if np.point ~= rp.point then return end

	local nameX = np.x or 0
	local nameY = np.y or 0
	if np.point:find("LEFT") then
		nameX = nameX + HIDDEN_ROLE_NAME_INSET
	elseif np.point:find("RIGHT") then
		nameX = nameX - HIDDEN_ROLE_NAME_INSET
	end

	local anchorPoint = np.point or "CENTER"
	local vAnchor
	if anchorPoint:find("TOP") then vAnchor = "TOP"
	elseif anchorPoint:find("BOTTOM") then vAnchor = "BOTTOM"
	else vAnchor = "" end
	local pinPoint = vAnchor ~= "" and (vAnchor .. "LEFT") or "LEFT"
	local anchor = parent.container or parent.healthBar or parent
	fs:ClearAllPoints()
	fs:SetPoint(pinPoint, anchor, pinPoint, nameX, nameY)
	parent._roleIconNameAdjusted = true
end

-- Exposed for NameText:Layout: when a frame is flagged
-- _roleIconNameAdjusted (this unit's role icon is hidden), a full
-- re-Layout must re-apply the hidden-role name position itself —
-- there is no role event after e.g. a border-color setter's
-- LayoutFrame sweep to run RoleIcon:Update again (field report: the
-- names of DPS units snapped back to the icon-offset position when
-- any unrelated setting re-ran LayoutFrame).
function BF:ReapplyHiddenRoleNameAdjust(parent)
	AdjustNameForHiddenRole(parent)
end

local function RestoreNameForShownRole(parent)
	if not parent._roleIconNameAdjusted then return end
	parent._roleIconNameAdjusted = nil
	-- Re-run NameText:Layout to restore the icon-offset position
	local nameInd = BF:GetIndicatorByName("nameText")
	if nameInd then nameInd:Layout(parent) end
end

-- ============================================================
-- Update: unconditionally overwrite (Grid2 pattern)
-- ============================================================
function RoleIcon:Update(parent, unit)
	local icon = parent[self.name]
	if not icon then return end

	local ip = BF:GetSectionProfileForFrame("icons", parent)

	-- Grid2 pattern: always overwrite — no cached state
	if not ip or not ip.showRoleIcons or not unit or not UnitExists(unit) then
		icon:Hide()
		AdjustNameForHiddenRole(parent)
		return
	end

	-- Pet frames: pets don't have roles
	local header = parent:GetParent()
	if header and header.isPetFrame then
		icon:Hide()
		AdjustNameForHiddenRole(parent)
		return
	end

	-- Read from role status instead of WoW API directly
	local roleStatus = BF.statuses and BF.statuses.role
	local role = roleStatus and roleStatus:GetRole(unit) or "NONE"

	-- Per-role visibility filter (Grid2 isValidRole pattern)
	if role == "TANK" and not ip.showRoleIconTank then
		icon:Hide()
		AdjustNameForHiddenRole(parent)
		return
	elseif role == "HEALER" and not ip.showRoleIconHealer then
		icon:Hide()
		AdjustNameForHiddenRole(parent)
		return
	elseif role == "DAMAGER" and not ip.showRoleIconDPS then
		icon:Hide()
		AdjustNameForHiddenRole(parent)
		return
	end

	-- Show the icon before restoring name position, so NameText:Layout
	-- sees the icon as visible when it re-runs.
	icon:Show()
	RestoreNameForShownRole(parent)

	local tex = icon.texture
	if ip.roleIconStyle == "TINY" then
		tex:SetTexture(nil)
		tex:SetTexCoord(0, 1, 0, 1)
		if role == "TANK" then
			tex:SetAtlas("roleicon-tiny-tank", false)
		elseif role == "HEALER" then
			tex:SetAtlas("roleicon-tiny-healer", false)
		elseif role == "DAMAGER" then
			tex:SetAtlas("roleicon-tiny-dps", false)
		else
			icon:Hide()
			AdjustNameForHiddenRole(parent)
		end
	elseif ip.roleIconStyle == "MODERN" then
		tex:SetTexture(nil)
		tex:SetTexCoord(0, 1, 0, 1)
		if role == "TANK" then
			tex:SetAtlas("UI-LFG-RoleIcon-Tank-Micro-GroupFinder", false)
		elseif role == "HEALER" then
			tex:SetAtlas("UI-LFG-RoleIcon-Healer-Micro-GroupFinder", false)
		elseif role == "DAMAGER" then
			tex:SetAtlas("UI-LFG-RoleIcon-DPS-Micro-GroupFinder", false)
		else
			icon:Hide()
			AdjustNameForHiddenRole(parent)
		end
	elseif ip.roleIconStyle == "GLASS" then
		-- Glass style (owner-supplied art): per-role TGA files with real
		-- alpha — translucent glass panes with colored rims.
		tex:SetTexCoord(0, 1, 0, 1)
		if role == "TANK" then
			tex:SetTexture("Interface\\AddOns\\BuzzardFrames\\Media\\role_glass_tank")
		elseif role == "HEALER" then
			tex:SetTexture("Interface\\AddOns\\BuzzardFrames\\Media\\role_glass_healer")
		elseif role == "DAMAGER" then
			tex:SetTexture("Interface\\AddOns\\BuzzardFrames\\Media\\role_glass_dps")
		else
			icon:Hide()
			AdjustNameForHiddenRole(parent)
		end
	else
		local roleTex = "Interface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES"
		if role == "TANK" then
			tex:SetTexture(roleTex); tex:SetTexCoord(0, 19/64, 22/64, 41/64)
		elseif role == "HEALER" then
			tex:SetTexture(roleTex); tex:SetTexCoord(20/64, 39/64, 1/64, 20/64)
		elseif role == "DAMAGER" then
			tex:SetTexture(roleTex); tex:SetTexCoord(20/64, 39/64, 22/64, 41/64)
		else
			icon:Hide()
			AdjustNameForHiddenRole(parent)
		end
	end
end

BF:RegisterIndicator(RoleIcon)
