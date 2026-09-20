--[[
BuzzardFrames: Indicators/Tooltip.lua
Tooltip hooks — shows the unit tooltip on hover.
Hooks OnEnter/OnLeave on the frame. Also drives mouseover highlight.

This indicator has no widget — it installs script hooks at Create time.
]]

local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

local UnitExists = UnitExists
local UnitGUID = UnitGUID
local UnitTokenFromGUID = UnitTokenFromGUID
local issecretvalue = issecretvalue
local InCombatLockdown = InCombatLockdown
local GameTooltip = GameTooltip
-- NOTE: Do NOT upvalue GameTooltip_SetDefaultAnchor.
-- Third-party tooltip addons SecureHook the global after addon load.
-- Upvaluing captures the original before the hook, bypassing their
-- tooltip repositioning. Use the global so hooks fire correctly.

-- 12.0 Midnight: secure-attribute unit tokens propagate taint into
-- GameTooltip:GetUnit(). Resolve a clean token via the frame's GUID;
-- if the tooltip's stored unit still ends up secret, hand the
-- GUID-backed token to RaiderIO directly, since its
-- TooltipDataProcessor filters secret values out.
local function ResolveUntaintedUnit(frame)
	local unit = frame.unit
	if not unit then return nil end
	local guid = UnitGUID(unit)
	if not guid or issecretvalue(guid) then return nil end
	-- UnitTokenFromGUID can itself return a secret token in 12.0 Midnight.
	-- Guard it: SetUnit() rejects secret arguments (C_TooltipInfo.GetUnit
	-- throws "Secret values are only allowed during untainted execution"),
	-- so only return a token we've proven is non-secret.
	local token = UnitTokenFromGUID(guid)
	if not token or issecretvalue(token) then return nil end
	return token
end

local Tooltip = BF.indicatorPrototype:new("tooltip")

function Tooltip:Create(parent)
	-- Skip if already hooked
	if parent._tooltipHooked then
		parent[self.name] = parent
		return
	end

	parent:HookScript("OnEnter", function(self)
		-- Mouseover highlight
		if self.mouseoverHighlight then
			local bp = BF:GetSectionProfileForFrame("borders", self)
			if bp and bp.enableMouseoverHighlight ~= false then
				local c = bp.mouseoverHighlightColor or { r=1, g=1, b=1 }
				local a = bp.mouseoverHighlightOpacity or 0.15
				self.mouseoverHighlight:SetColorTexture(c.r, c.g, c.b, a)
			end
		end
		-- Tooltip
		if self.SF_AuraTooltipActive then return end
		local ttp = BF:GetSectionProfileForFrame("tooltips", self)
		if not ttp or not ttp.showUnitTooltip then return end
		if BF._inCombat and not ttp.showUnitTooltipInCombat then return end
		if self.unit and UnitExists(self.unit) then
			if ttp.unitTooltipPosition == "icon" then
				GameTooltip:SetOwner(self, "ANCHOR_NONE")
				local cx, cy = GetCursorPosition()
				local scale = GameTooltip:GetEffectiveScale()
				GameTooltip:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", cx / scale + 12, cy / scale - 12)
			elseif ttp.unitTooltipPosition == "iconTR" then
				GameTooltip:SetOwner(self, "ANCHOR_CURSOR_RIGHT")
			elseif ttp.unitTooltipPosition == "frame" then
				GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
			else
				GameTooltip_SetDefaultAnchor(GameTooltip, UIParent)
			end
			-- 12.0 taint workaround. SetUnit() rejects secret arguments.
			-- Pick a token that's safe to pass: prefer the GUID-resolved
			-- non-secret token, else self.unit when it isn't secret. Only
			-- when neither is safe do we skip SetUnit and let RaiderIO take
			-- self.unit directly (its TooltipDataProcessor filters secrets).
			--
			-- A successful SetUnit() already runs RaiderIO's tooltip data
			-- processor, so do NOT call ShowProfile after it. GameTooltip:GetUnit()
			-- returning nil or a secret value under 12.0 is normal and does not
			-- mean the profile was skipped; calling ShowProfile on that signal
			-- rendered the profile block twice.
			local resolved = ResolveUntaintedUnit(self)
			local safeUnit = resolved
			if not safeUnit and not issecretvalue(self.unit) then
				safeUnit = self.unit
			end
			if safeUnit then
				GameTooltip:SetUnit(safeUnit)
			elseif _G.RaiderIO and _G.RaiderIO.ShowProfile then
				_G.RaiderIO.ShowProfile(GameTooltip, self.unit)
			end
			GameTooltip:Show()
		end
	end)

	parent:HookScript("OnLeave", function(self)
		if self.mouseoverHighlight then
			self.mouseoverHighlight:SetColorTexture(1, 1, 1, 0)
		end
		if not self.SF_AuraTooltipActive then
			GameTooltip:Hide()
		end
	end)

	parent._tooltipHooked = true
	parent[self.name] = parent
end

function Tooltip:Layout(parent)
end

function Tooltip:Update(parent, unit)
end

function Tooltip:GetFrame(parent)
	return parent[self.name]
end

BF:RegisterIndicator(Tooltip)
