--[[
BuzzardFrames: Indicators/BuffHighlight.lua
Buff border indicator — shows a colored border when tracked buffs are active.
Also drives buffOverlay and SF_SpecColorActive health bar recoloring.

Grid2 equivalent: IndicatorBorder.lua bound to buff statuses.
Grid2 pattern: status provides data, indicator just renders.

The buffmatch status (Statuses/Auras.lua) caches per-unit match results.
BuffHighlight:Update reads from buffmatch getter methods — zero aura scanning.
]]

local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

local issecretvalue  = issecretvalue  or function() return false end
local C_UnitAuras    = C_UnitAuras
local UnitIsVisible  = UnitIsVisible

local BuffHighlight = BF.indicatorPrototype:new("buffHighlight")

local function MakeEdge(parent)
	local t = parent:CreateTexture(nil, "OVERLAY")
	t:SetColorTexture(0, 0, 0, 0)
	return t
end

local function PixelsToUI(n)
	local pixelSize = 768 / select(2, GetPhysicalScreenSize())
	local uiScale   = UIParent:GetEffectiveScale()
	local pixelMult = (uiScale > 0) and (pixelSize / uiScale) or 1
	return n * pixelMult
end

-- ============================================================
-- Create
-- ============================================================
function BuffHighlight:Create(parent)
	if parent.buffHighlight then
		parent[self.name] = parent.buffHighlight
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

	parent[self.name]   = frame
	parent.buffHighlight = frame
end

-- ============================================================
-- Layout
-- ============================================================
function BuffHighlight:Layout(parent)
	local frame = parent[self.name]
	if not frame then return end
	local p = BF.db and BF.db.profile
	if not p then return end

	local b      = frame
	local buffT  = PixelsToUI(p.buffBorderWidth or 2)
	if b.top and b.bottom and b.left and b.right then
		b.top:ClearAllPoints(); b.top:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0); b.top:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0); b.top:SetHeight(buffT)
		b.bottom:ClearAllPoints(); b.bottom:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 0, 0); b.bottom:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0); b.bottom:SetHeight(buffT)
		b.left:ClearAllPoints(); b.left:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0); b.left:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 0, 0); b.left:SetWidth(buffT)
		b.right:ClearAllPoints(); b.right:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0); b.right:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0); b.right:SetWidth(buffT)
	end
end

-- ============================================================
-- Update: Grid2 Status -> Indicator pattern.
-- Reads from buffmatch status getter methods. Zero aura scanning.
-- ============================================================
-- Helper: clear buff highlight state and restore health bar color.
-- File-level to avoid per-call closure allocation.
local function ClearAllBuffHighlight(parent, unit)
	if parent.buffHighlight then BF:SetBorderColor(parent.buffHighlight, 0, 0, 0, 0) end
	if BF.HideBuffOverlay      then BF.HideBuffOverlay(parent)      end
	if BF.HideBuffColorOverlay then BF.HideBuffColorOverlay(parent) end
	parent._buffBorderActive  = nil
	parent._buffOverlayActive = nil
end

function BuffHighlight:Update(parent, unit)
	local specId = BF.playerSpecID

	if not specId then ClearAllBuffHighlight(parent, unit); return end
	if not UnitIsVisible(unit) then ClearAllBuffHighlight(parent, unit); return end

	-- Read from buffmatch status (Grid2 pattern: status:GetColor).
	local bm = BF.statuses and BF.statuses.buffmatch
	local matchedColor   = bm and bm:GetMatchedColor(unit)
	local matchedBorder  = bm and bm:GetMatchedBorder(unit)
	local matchedOverlay = bm and bm:GetMatchedOverlay(unit)

	if not matchedColor and not matchedBorder and not matchedOverlay then
		if parent._bf_bhClear then return end
		ClearAllBuffHighlight(parent, unit)
		parent._bf_bhClear = true
		return
	end
	parent._bf_bhClear = nil

	-- ============================================================
	-- Health bar color overlay.
	-- Two paths:
	--   Static (no durationMap): a texture on top of the health bar fill.
	--     Covers the full fill; alpha controls opacity.
	--   durationMap: a StatusBar driven by SetTimerDuration. Blizzard's
	--     C-side renderer auto-ticks the value as the aura expires, so
	--     the overlay shrinks toward the bottom without any Lua polling.
	-- Only one is visible at a time; the other is hidden. The StatusBar is
	-- created lazily on first use.
	-- ============================================================
	if matchedColor and parent.healthBar then
		local useDurMap = matchedColor.durationMap and true or false
		if useDurMap then
			-- durationMap path: StatusBar with SetTimerDuration.
			if parent.buffColorOverlay then parent.buffColorOverlay:Hide() end
			local bar = BF.EnsureBuffColorOverlayBar and BF.EnsureBuffColorOverlayBar(parent)
			if bar then
				-- Re-color the fill texture each update (matched color may have changed).
				if bar._bf_fillTex then
					bar._bf_fillTex:SetColorTexture(matchedColor.r, matchedColor.g, matchedColor.b, matchedColor.a or 1)
				end
				-- Bind the duration object to the current aura's expiration.
				-- SetTimerDuration is re-called on every Update so refreshes
				-- (which reset expirationTime) are picked up immediately; the
				-- durationMap carve-out in BuffMatch:UpdateCache guarantees
				-- BuffHighlight:Update runs on every refresh UNIT_AURA.
				local iid = bm and bm:GetColorAuraIID(unit)
				local bound = false
				if iid and bar._bf_durObj and C_UnitAuras and C_UnitAuras.GetAuraDataByAuraInstanceID then
					local data = C_UnitAuras.GetAuraDataByAuraInstanceID(unit, iid)
					if data and data.expirationTime and data.duration
					   and not issecretvalue(data.expirationTime)
					   and not issecretvalue(data.duration)
					   and data.duration > 0 then
						bar._bf_durObj:SetTimeFromEnd(data.expirationTime, data.duration)
						-- direction=1: value shrinks from 1 -> 0 as time elapses.
						bar:SetTimerDuration(bar._bf_durObj, 0, 1)
						bound = true
					end
				end
				if not bound then
					-- No duration info (permanent aura or secret): show full.
					bar:SetValue(1)
				end
				bar:Show()
			end
		else
			-- Static path: existing texture overlay on the health bar fill.
			if parent.buffColorOverlayBar then parent.buffColorOverlayBar:Hide() end
			local overlay = parent.buffColorOverlay
			if not overlay then
				overlay = parent.healthBar:CreateTexture(nil, "OVERLAY", nil, 0)
				parent.buffColorOverlay = overlay
			end
			overlay:SetColorTexture(matchedColor.r, matchedColor.g, matchedColor.b, matchedColor.a or 1)
			local hFill = parent.healthBar:GetStatusBarTexture()
			overlay:ClearAllPoints()
			if hFill then
				overlay:SetPoint("TOPLEFT", hFill, "TOPLEFT", 0, 0)
				overlay:SetPoint("BOTTOMRIGHT", hFill, "BOTTOMRIGHT", 0, 0)
			else
				overlay:SetPoint("TOPLEFT", parent.healthBar, "TOPLEFT", 0, 0)
				overlay:SetPoint("BOTTOMRIGHT", parent.healthBar, "BOTTOMRIGHT", 0, 0)
			end
			overlay:Show()
		end
	else
		if BF.HideBuffColorOverlay then BF.HideBuffColorOverlay(parent) end
	end

	-- ============================================================
	-- Buff border.
	-- ============================================================
	if parent.buffHighlight then
		if matchedBorder then
			-- Resolve thickness: per-match override wins, falls back to the
			-- global p.buffBorderWidth. If the resolved thickness differs from
			-- what's currently applied to the buffHighlight edges, re-apply the
			-- edge geometry. We cache the last-applied value on the buffHighlight
			-- sub-frame so unchanged thickness skips the ClearAllPoints+SetPoint
			-- calls each update.
			local p = BF.db and BF.db.profile
			local thicknessPx = matchedBorder.thickness or (p and p.buffBorderWidth) or 2
			local bh = parent.buffHighlight
			if bh._bf_lastThickness ~= thicknessPx then
				local buffT = PixelsToUI(thicknessPx)
				if bh.top and bh.bottom and bh.left and bh.right then
					bh.top:ClearAllPoints();    bh.top:SetPoint("TOPLEFT",     parent, "TOPLEFT",     0, 0); bh.top:SetPoint("TOPRIGHT",    parent, "TOPRIGHT",    0, 0); bh.top:SetHeight(buffT)
					bh.bottom:ClearAllPoints(); bh.bottom:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 0, 0); bh.bottom:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0); bh.bottom:SetHeight(buffT)
					bh.left:ClearAllPoints();   bh.left:SetPoint("TOPLEFT",    parent, "TOPLEFT",    0, 0); bh.left:SetPoint("BOTTOMLEFT",  parent, "BOTTOMLEFT",  0, 0); bh.left:SetWidth(buffT)
					bh.right:ClearAllPoints();  bh.right:SetPoint("TOPRIGHT",  parent, "TOPRIGHT",  0, 0); bh.right:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0); bh.right:SetWidth(buffT)
				end
				bh._bf_lastThickness = thicknessPx
			end

			local debuffActive = parent.dispelDebuffBorder and parent.dispelDebuffBorder._cr and parent.dispelDebuffBorder._cr > 0
			if debuffActive and not matchedBorder.priority then
				BF:SetBorderColor(parent.buffHighlight, 0, 0, 0, 0)
			else
				-- Border color fallback: read fields directly from matchedBorder.color
				-- when present, else default to bright green. Pre-fix this path
				-- allocated a fresh { r=0, g=1, b=0 } table on every call where the
				-- match config had no explicit color.
				local bc = matchedBorder.color
				local bcR, bcG, bcB
				if bc then bcR, bcG, bcB = bc.r, bc.g, bc.b
				else bcR, bcG, bcB = 0, 1, 0 end
				BF:SetBorderColor(parent.buffHighlight, bcR, bcG, bcB, 1)
				if matchedBorder.priority and parent.dispelDebuffBorder then
					BF:SetBorderColor(parent.dispelDebuffBorder, 0, 0, 0, 0)
				end
			end
			parent._buffBorderActive = true
		else
			BF:SetBorderColor(parent.buffHighlight, 0, 0, 0, 0)
			parent._buffBorderActive = nil
		end
	end

	-- ============================================================
	-- Buff overlay.
	-- Two paths, identical reasoning to the color overlay above:
	--   Static (no durationMap): the original texture with SetHeight.
	--   durationMap: a StatusBar driven by SetTimerDuration. C-side ticks
	--     the fill value as the aura expires -- no Lua polling.
	-- Both buff and debuff overlays can be active simultaneously; priority
	-- controls draw order via sublevel.
	-- ============================================================
	if matchedOverlay then
		-- Overlay color fallback: read matchedOverlay.color fields directly
		-- when present, else fall through to the green default. No per-call
		-- fallback table alloc.
		local oc = matchedOverlay.color
		local ocR, ocG, ocB
		if oc then ocR, ocG, ocB = oc.r, oc.g, oc.b
		else ocR, ocG, ocB = 0, 1, 0 end
		local alpha    = matchedOverlay.alpha or 0.5
		local fillOnly = matchedOverlay.fillOnly
		local useDurMap = matchedOverlay.durationMap and true or false

		if useDurMap then
			-- durationMap path: StatusBar with SetTimerDuration.
			if parent.buffOverlay then parent.buffOverlay:Hide() end
			local bar = BF.EnsureBuffOverlayBar and BF.EnsureBuffOverlayBar(parent)
			if bar and parent.healthBar then
				-- Re-anchor for fillOnly vs full-bar behaviour. The StatusBar
				-- fills its own frame from bottom upward; fillOnly means its
				-- frame spans only the current health bar fill region.
				bar:ClearAllPoints()
				local hFill = parent.healthBar:GetStatusBarTexture()
				if fillOnly and hFill then
					bar:SetPoint("TOPLEFT",     hFill, "TOPLEFT",     0, 0)
					bar:SetPoint("BOTTOMRIGHT", hFill, "BOTTOMRIGHT", 0, 0)
				else
					bar:SetAllPoints(parent.healthBar)
				end
				-- Fill texture color + alpha. The gradient heightmap texture
				-- honors vertex color and alpha like any other texture.
				local fill = bar:GetStatusBarTexture()
				if fill then
					fill:SetVertexColor(ocR, ocG, ocB, 1)
					fill:SetAlpha(alpha)
					-- Priority controls draw order: sublevel 2 draws above the
					-- debuff overlay at sublevel 1. Applied to the fill texture.
					if matchedOverlay.priority then
						fill:SetDrawLayer("OVERLAY", 2)
					else
						fill:SetDrawLayer("OVERLAY", 1)
					end
				end
				-- Bind duration object and hand off to the native timer mode.
				local iid = bm and bm:GetOverlayAuraIID(unit)
				local bound = false
				if iid and bar._bf_durObj and C_UnitAuras and C_UnitAuras.GetAuraDataByAuraInstanceID then
					local data = C_UnitAuras.GetAuraDataByAuraInstanceID(unit, iid)
					if data and data.expirationTime and data.duration
					   and not issecretvalue(data.expirationTime)
					   and not issecretvalue(data.duration)
					   and data.duration > 0 then
						bar._bf_durObj:SetTimeFromEnd(data.expirationTime, data.duration)
						bar:SetTimerDuration(bar._bf_durObj, 0, 1)
						bound = true
					end
				end
				if not bound then
					bar:SetValue(1)
				end
				bar:Show()
			end
			parent._buffOverlayActive = true
		else
			-- Static path: existing texture with SetHeight.
			if parent.buffOverlayBar then parent.buffOverlayBar:Hide() end
			if parent.buffOverlay then
				if matchedOverlay.priority then
					parent.buffOverlay:SetDrawLayer("OVERLAY", 2)
				else
					parent.buffOverlay:SetDrawLayer("OVERLAY", 1)
				end
				parent.buffOverlay:SetTexture("Interface\\AddOns\\BuzzardFrames\\Media\\debuff_overlay_gradient_flipped")
				parent.buffOverlay:SetVertexColor(ocR, ocG, ocB, 1)
				parent.buffOverlay:SetAlpha(alpha)
				if parent.healthBar then
					local hFill = parent.healthBar:GetStatusBarTexture()
					parent.buffOverlay:ClearAllPoints()
					if fillOnly and hFill then
						parent.buffOverlay:SetPoint("BOTTOMLEFT",  hFill, "BOTTOMLEFT",  0, 0)
						parent.buffOverlay:SetPoint("BOTTOMRIGHT", hFill, "BOTTOMRIGHT", 0, 0)
					else
						parent.buffOverlay:SetPoint("BOTTOMLEFT",  parent.healthBar, "BOTTOMLEFT",  0, 0)
						parent.buffOverlay:SetPoint("BOTTOMRIGHT", parent.healthBar, "BOTTOMRIGHT", 0, 0)
					end
					parent.buffOverlay:SetHeight(parent.healthBar:GetHeight() * (matchedOverlay.height or 0.7))
				end
				parent.buffOverlay:Show()
			end
			parent._buffOverlayActive = true
		end
	else
		if BF.HideBuffOverlay then BF.HideBuffOverlay(parent) end
		parent._buffOverlayActive = nil
	end
end

BF:RegisterIndicator(BuffHighlight)