--[[
BuzzardFrames: Indicators/AggroHighlight.lua
Aggro/threat highlight border indicator.

Grid2 equivalent: IndicatorBorder.lua bound to StatusThreat.

Each call to Update unconditionally overwrites stale state (Grid2 pattern).
]]

local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

local UnitThreatSituation = UnitThreatSituation
local UnitExists          = UnitExists

local AggroHighlight = BF.indicatorPrototype:new("aggroHighlight")

-- Chevron texture aspect ratio (width/height). The single-chevron texture
-- is 64x128 and the double is 128x128; this ratio describes the visible
-- content shape so the arrow isn't stretched when displayed.
local ARROW_SINGLE_ASPECT = 87 / 112  -- ≈ 0.777
local ARROW_DOUBLE_ASPECT = 1         -- 128x128, content fills square

-- ============================================================
local function MakeEdge(parent)
	local t = BF.Texture(parent, nil, "OVERLAY")
	t:SetColorTexture(0, 0, 0, 0)
	return t
end

local function PixelsToUI(n)
	local pixelSize = 768 / select(2, GetPhysicalScreenSize())
	local uiScale = UIParent:GetEffectiveScale()
	local pixelMult = (uiScale > 0) and (pixelSize / uiScale) or 1
	return n * pixelMult
end

-- ============================================================
-- Create
-- ============================================================
function AggroHighlight:Create(parent)
	-- Skip if already created by legacy InitFrame
	if parent.aggroHighlight then
		parent[self.name] = parent.aggroHighlight
		return
	end

	local frame = CreateFrame("Frame", nil, parent)
	frame:SetAllPoints(parent)
	frame:SetFrameLevel(parent:GetFrameLevel() + 11)
	frame:EnableMouse(false)
	frame.top    = MakeEdge(frame)
	frame.bottom = MakeEdge(frame)
	frame.left   = MakeEdge(frame)
	frame.right  = MakeEdge(frame)

	-- Blizzard-style aggro border: 4 fixed-size CORNER tiles + 4 EDGE tiles
	-- that stretch on ONE axis only. A single stretched texture cannot work
	-- here -- a square texture on a 70x40 frame compresses horizontally and
	-- stretches vertically, so edge thickness differs per side and the corner
	-- blocks distort. Corners never stretch, so the square insets stay crisp
	-- at any frame size, and edge thickness is exact pixels via PixelsToUI.
	-- One corner texture serves all four via SetTexCoord flips.
	local bz = {}
	for _, key in ipairs({ "tl", "tr", "bl", "br", "top", "bottom", "left", "right" }) do
		local t = BF.Texture(frame, nil, "OVERLAY")
		t:SetVertexColor(0.8, 0.478, 0)
		t:SetAlpha(0)
		bz[key] = t
	end
	-- TexCoords (per-corner flips AND the content crop) are stamped in
	-- :Layout, where the width is known -- the tiles are 32px files whose art
	-- occupies only the first (w+5) texels, so the crop depends on w.
	frame.blizzardParts = bz

	-- Glow Border style: opaque rim with an eased inward falloff. Square
	-- border styles only (see the rounded guard in :Update) -- the falloff is
	-- rectangular and cannot follow a rounded ring.
	local glowBorder = BF.Texture(frame, nil, "OVERLAY")
	glowBorder:SetAllPoints(frame)
	glowBorder:SetTexture("Interface\\AddOns\\BuzzardFrames\\Media\\aggro_border_glow_v3_2px")
	glowBorder:SetVertexColor(0.8, 0.478, 0)
	glowBorder:SetAlpha(0)
	frame.glowBorder = glowBorder

	-- Corners overlay — own frame at parent+14 so it renders above all
	-- border indicators (+12) and target highlight (+13).
	local cornersFrame = CreateFrame("Frame", nil, parent)
	cornersFrame:SetFrameLevel(parent:GetFrameLevel() + 14)
	cornersFrame:EnableMouse(false)
	local inset = -PixelsToUI(1)
	cornersFrame:SetPoint("TOPLEFT", parent, "TOPLEFT", inset, -inset)
	cornersFrame:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -inset, inset)
	local corners = BF.Texture(cornersFrame, nil, "OVERLAY")
	corners:SetAllPoints(cornersFrame)
	corners:SetTexture("Interface\\AddOns\\BuzzardFrames\\Media\\aggro_corners_lg")
	corners:SetVertexColor(0.8, 0.478, 0)
	corners:SetAlpha(0)
	frame.cornersTex = corners

	-- Arrow indicator texture (chevron)
	-- Parented to textFrame so it renders above bars.
	-- Single texture per style, rotated via SetRotation for direction.
	local textParent = parent.textFrame or frame
	local arrowTex = BF.Texture(textParent, nil, "OVERLAY")
	arrowTex:SetTexture("Interface\\AddOns\\BuzzardFrames\\Media\\aggro_arrow")
	arrowTex:SetSize(11, 16)
	arrowTex:SetAlpha(0)
	frame.arrowTex = arrowTex

	parent[self.name] = frame
	parent.aggroHighlight = frame  -- backward compat alias
end

-- ============================================================
-- Anchor-point map for arrow positions
-- ============================================================
local ARROW_ANCHORS = {
	TOPLEFT     = { point = "TOPLEFT",     relPoint = "TOPLEFT"     },
	TOP         = { point = "TOP",         relPoint = "TOP"         },
	TOPRIGHT    = { point = "TOPRIGHT",    relPoint = "TOPRIGHT"    },
	LEFT        = { point = "LEFT",        relPoint = "LEFT"        },
	CENTER      = { point = "CENTER",      relPoint = "CENTER"      },
	RIGHT       = { point = "RIGHT",       relPoint = "RIGHT"       },
	BOTTOMLEFT  = { point = "BOTTOMLEFT",  relPoint = "BOTTOMLEFT"  },
	BOTTOM      = { point = "BOTTOM",      relPoint = "BOTTOM"      },
	BOTTOMRIGHT = { point = "BOTTOMRIGHT", relPoint = "BOTTOMRIGHT" },
}

-- ============================================================
-- Layout
-- ============================================================
function AggroHighlight:Layout(parent)
	local frame = parent[self.name]
	if not frame then return end
	-- v92: config may have changed — invalidate the Update guard so the
	-- next threat event repaints with the new style/colors/scale.
	frame._bfThreatKey = nil

	-- Route borders reads via GetSectionProfileForFrame: on preview frames
	-- this resolves to the preview's flat.borders (or the global when
	-- per-layout is OFF); on live frames it resolves to the active flat's
	-- borders (matches Container.lua / PowerBar.lua v28 pattern).
	local bp = BF:GetSectionProfileForFrame("borders", parent)
	if not bp then return end

	local a = frame
	local borderW = bp.aggroBorderWidth or 2
	local aggroT = PixelsToUI(borderW)

	if a.top and a.bottom and a.left and a.right then
		a.top:ClearAllPoints(); a.top:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0); a.top:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0); a.top:SetHeight(aggroT)
		a.bottom:ClearAllPoints(); a.bottom:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 0, 0); a.bottom:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0); a.bottom:SetHeight(aggroT)
		a.left:ClearAllPoints(); a.left:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0); a.left:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 0, 0); a.left:SetWidth(aggroT)
		a.right:ClearAllPoints(); a.right:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0); a.right:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0); a.right:SetWidth(aggroT)
	end

	-- Blizzard style: stamp the 8 parts. Corner tiles are fixed-size so the
	-- square insets never distort; edges span between them and stretch on one
	-- axis only, so thickness is exact pixels on every side at any frame size.
	local bz = a.blizzardParts
	local bzW   = math.max(1, math.min(5, borderW))
	local bzCs   = PixelsToUI(bzW + 5)  -- corner block (w+3) + 2px shadow skirt
	local bzBand = PixelsToUI(bzW + 2)  -- edge run + its shadow skirt
	if bz then
		local w, cs, band = bzW, bzCs, bzBand
		local MEDIA = "Interface\\AddOns\\BuzzardFrames\\Media\\"
		local cTex  = MEDIA .. "AggroCorner" .. w
		local hTex  = MEDIA .. "AggroEdgeH"  .. w
		local vTex  = MEDIA .. "AggroEdgeV"  .. w
		-- The tiles are 32x32 FILES whose art occupies only the first (w+5)
		-- texels; the rest is empty. Drawing the whole file at (w+5) px would
		-- squash it ~0.2x and the border all but vanishes. Crop to the content
		-- region with SetTexCoord so 1 texel renders as 1 pixel.
		local TILE = 32
		local uv   = (w + 5) / TILE
		for _, k in ipairs({ "tl", "tr", "bl", "br" }) do
			bz[k]:SetTexture(cTex)
			bz[k]:SetSize(cs, cs)
			bz[k]:ClearAllPoints()
		end
		-- Re-apply per-corner flips against the cropped region.
		bz.tl:SetTexCoord(0,  uv, 0,  uv)
		bz.tr:SetTexCoord(uv, 0,  0,  uv)
		bz.bl:SetTexCoord(0,  uv, uv, 0 )
		bz.br:SetTexCoord(uv, 0,  uv, 0 )
		bz.tl:SetPoint("TOPLEFT",     parent, "TOPLEFT")
		bz.tr:SetPoint("TOPRIGHT",    parent, "TOPRIGHT")
		bz.bl:SetPoint("BOTTOMLEFT",  parent, "BOTTOMLEFT")
		bz.br:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT")
		-- Edges: crop the THICKNESS axis to the (w+2) band so it renders 1:1;
		-- the LENGTH axis keeps the full 0..1 range and stretches freely.
		local ev = (w + 2) / TILE
		bz.top:SetTexture(hTex);    bz.top:ClearAllPoints()
		bz.top:SetTexCoord(0, 1, 0, ev)
		bz.top:SetPoint("TOPLEFT",  bz.tl, "TOPRIGHT")
		bz.top:SetPoint("TOPRIGHT", bz.tr, "TOPLEFT")
		bz.top:SetHeight(band)
		bz.bottom:SetTexture(hTex); bz.bottom:ClearAllPoints()
		bz.bottom:SetTexCoord(0, 1, ev, 0)   -- flipped vertically
		bz.bottom:SetPoint("BOTTOMLEFT",  bz.bl, "BOTTOMRIGHT")
		bz.bottom:SetPoint("BOTTOMRIGHT", bz.br, "BOTTOMLEFT")
		bz.bottom:SetHeight(band)
		bz.left:SetTexture(vTex);   bz.left:ClearAllPoints()
		bz.left:SetTexCoord(0, ev, 0, 1)
		bz.left:SetPoint("TOPLEFT",    bz.tl, "BOTTOMLEFT")
		bz.left:SetPoint("BOTTOMLEFT", bz.bl, "TOPLEFT")
		bz.left:SetWidth(band)
		bz.right:SetTexture(vTex);  bz.right:ClearAllPoints()
		bz.right:SetTexCoord(ev, 0, 0, 1)    -- flipped horizontally
		bz.right:SetPoint("TOPRIGHT",    bz.tr, "BOTTOMRIGHT")
		bz.right:SetPoint("BOTTOMRIGHT", bz.br, "TOPRIGHT")
		bz.right:SetWidth(band)
	end
	-- Glow border: single full-bleed texture, so only the width can change it.
	if a.glowBorder then
		local gpx = math.max(2, math.min(5, borderW))
		if a._glowGeomSig ~= gpx then
			a._glowGeomSig = gpx
			a.glowBorder:SetTexture("Interface\\AddOns\\BuzzardFrames\\Media\\aggro_border_glow_v3_" .. gpx .. "px")
		end
	end

	-- Arrow texture layout
	local arrowTex = a.arrowTex
	if arrowTex then
		local dir  = (bp and bp.aggroArrowDirection) or "right"
		local sz   = (bp and bp.aggroArrowSize) or 16
		local style = (bp and bp.aggroStyle) or "border"
		local texName = (style == "arrowSingle") and "aggro_arrow_single" or "aggro_arrow"
		arrowTex:SetTexture("Interface\\AddOns\\BuzzardFrames\\Media\\" .. texName)
		local aspect = (style == "arrowSingle") and ARROW_SINGLE_ASPECT or ARROW_DOUBLE_ASPECT
		-- SetRotation turns the texture COUNTER-clockwise and the art
		-- points RIGHT at 0, so a quarter turn points it UP. See the twin
		-- of this block below; they were both inverted.
		local dirRad = dir == "right" and 0
		             or dir == "up"    and math.pi * 0.5
		             or dir == "left"  and math.pi
		             or dir == "down"  and math.pi * 1.5
		             or 0
		arrowTex:SetRotation(dirRad)
		if dir == "up" or dir == "down" then
			arrowTex:SetSize(sz, sz * aspect)
		else
			arrowTex:SetSize(sz * aspect, sz)
		end

		local pos  = (bp and bp.aggroArrowPosition) or "LEFT"
		local offX = (bp and bp.aggroArrowOffsetX) or 0
		local offY = (bp and bp.aggroArrowOffsetY) or 0
		arrowTex:ClearAllPoints()
		local anchor = ARROW_ANCHORS[pos]
		if anchor then
			arrowTex:SetPoint(anchor.point, parent, anchor.relPoint, offX, offY)
		else
			arrowTex:SetPoint("LEFT", parent, "LEFT", offX, offY)
		end
	end
end

-- Show/hide + tint the 8 Blizzard-style parts as one unit.
local BZ_KEYS = { "tl", "tr", "bl", "br", "top", "bottom", "left", "right" }
local function SetBlizzardParts(a, alpha, r, g, b)
	local bz = a.blizzardParts
	if not bz then return end
	for i = 1, #BZ_KEYS do
		local t = bz[BZ_KEYS[i]]
		if t then
			if r then t:SetVertexColor(r, g, b) end
			t:SetAlpha(alpha)
		end
	end
end

-- ============================================================
-- Helper: clear all visual layers
-- ============================================================
local function ClearAllStyles(a)
	BF:SetBorderColor(a, 0, 0, 0, 0)
	if a.roundRing      then a.roundRing:Hide() end
	SetBlizzardParts(a, 0)
	if a.glowBorder     then a.glowBorder:SetAlpha(0) end
	if a.cornersTex     then a.cornersTex:SetAlpha(0) end
	if a.arrowTex       then a.arrowTex:SetAlpha(0) end
end

-- ============================================================
-- Update: unconditionally overwrite (Grid2 pattern)
-- ============================================================
function AggroHighlight:Update(parent, unit)
	local a = parent[self.name]
	if not a then return end

	local bp = BF:GetSectionProfileForFrame("borders", parent)

	local enabled  = not bp or bp.aggroEnabled ~= false
	local style    = (bp and bp.aggroStyle) or "border"
	-- Blizzard style is incompatible with rounded frame borders (its
	-- atlas can't be the rounded ring) — render it as Border. Belt to
	-- the options auto-swap, covering profiles saved before that.
	-- Glow Border is square-only for the same reason (rectangular falloff).
	-- Gate on the rounded ring actually being DRAWN: a rounded borderStyle
	-- with the border switched off renders nothing, so the rectangular art
	-- is fine there (matches Container.lua:298).
	if (style == "blizzard" or style == "glowBorder")
		and bp and bp.enableBorder ~= false
		and BF.IsRoundedBorderStyle and BF.IsRoundedBorderStyle(bp.borderStyle) then
		style = "border"
	end
	-- Read from threat status instead of WoW API directly
	local threatStatus = BF.statuses and BF.statuses.threat
	local isActive = threatStatus and threatStatus:IsActive(unit)

	if not (enabled and isActive) then
		-- v92 PERF: -1 = "cleared". Threat events arrive in bursts (pulls,
		-- tank swaps, AoE packs) and most deliver the same level; the paint
		-- below depends only on (level, config), and config changes re-run
		-- Layout, which resets the guard. So a same-state event is one
		-- compare instead of a full style re-stamp (~8 texture writes plus
		-- a texture-path concat in the corners/arrow styles).
		if a._bfThreatKey ~= -1 then
			a._bfThreatKey = -1
			ClearAllStyles(a)
		end
		return
	end

	-- Resolve threat color by level
	local alpha = (bp and bp.aggroScale) or 0.6
	local level = threatStatus:GetThreatLevel(unit)
	-- v92 PERF: same-level repaint guard (see the cleared arm above).
	-- `level` is a plain readable number (the >= compares below shipped).
	if a._bfThreatKey == level then return end
	a._bfThreatKey = level
	local c
	if level >= 3 then
		c = bp and bp.aggroColor3 or { r=1, g=0.306, b=0 }
	elseif level >= 2 then
		c = bp and bp.aggroColor2 or { r=1, g=0.5, b=0 }
	else
		c = bp and bp.aggroColor1 or { r=1, g=0.94, b=0 }
	end

	-- ---- Style: border ----
	if style == "border" then
		-- Rounded-aware: tints the nine-slice ring (at the aggro border
		-- width) for rounded frame styles, square edges otherwise.
		BF:SetHighlightBorder(a, parent, c.r, c.g, c.b, alpha,
			(bp and bp.aggroBorderWidth) or 2)
		SetBlizzardParts(a, 0)
		if a.glowBorder     then a.glowBorder:SetAlpha(0) end
		if a.cornersTex     then a.cornersTex:SetAlpha(0) end
		if a.arrowTex       then a.arrowTex:SetAlpha(0) end

	-- ---- Style: blizzard ----
	elseif style == "blizzard" then
		BF:SetBorderColor(a, 0, 0, 0, 0)
		if a.roundRing then a.roundRing:Hide() end
		SetBlizzardParts(a, alpha, c.r, c.g, c.b)
		if a.glowBorder     then a.glowBorder:SetAlpha(0) end
		if a.cornersTex     then a.cornersTex:SetAlpha(0) end
		if a.arrowTex       then a.arrowTex:SetAlpha(0) end

	-- ---- Style: glowBorder ----
	elseif style == "glowBorder" then
		BF:SetBorderColor(a, 0, 0, 0, 0)
		if a.roundRing then a.roundRing:Hide() end
		SetBlizzardParts(a, 0)
		if a.glowBorder then a.glowBorder:SetVertexColor(c.r, c.g, c.b); a.glowBorder:SetAlpha(alpha) end
		if a.cornersTex     then a.cornersTex:SetAlpha(0) end
		if a.arrowTex       then a.arrowTex:SetAlpha(0) end

	-- ---- Style: corners ----
	elseif style == "corners" then
		BF:SetBorderColor(a, 0, 0, 0, 0)
		if a.roundRing then a.roundRing:Hide() end
		SetBlizzardParts(a, 0)
		if a.glowBorder     then a.glowBorder:SetAlpha(0) end
		if a.cornersTex then
			local scale = (bp and bp.aggroCornersScale) or "lg"
			a.cornersTex:SetTexture("Interface\\AddOns\\BuzzardFrames\\Media\\aggro_corners_" .. scale)
			a.cornersTex:SetVertexColor(c.r, c.g, c.b)
			a.cornersTex:SetAlpha(alpha)
		end
		if a.arrowTex       then a.arrowTex:SetAlpha(0) end

	-- ---- Style: arrow (double) / arrowSingle ----
	elseif style == "arrow" or style == "arrowSingle" then
		BF:SetBorderColor(a, 0, 0, 0, 0)
		if a.roundRing then a.roundRing:Hide() end
		SetBlizzardParts(a, 0)
		if a.glowBorder     then a.glowBorder:SetAlpha(0) end
		if a.cornersTex     then a.cornersTex:SetAlpha(0) end
		if a.arrowTex then
			local dir = (bp and bp.aggroArrowDirection) or "right"
			local sz  = (bp and bp.aggroArrowSize) or 16
			local texName = (style == "arrowSingle") and "aggro_arrow_single" or "aggro_arrow"
			a.arrowTex:SetTexture("Interface\\AddOns\\BuzzardFrames\\Media\\" .. texName)
			local aspect = (style == "arrowSingle") and ARROW_SINGLE_ASPECT or ARROW_DOUBLE_ASPECT
			-- SetRotation turns the texture COUNTER-clockwise, and the
			-- art points RIGHT at 0 -- so a quarter turn (0.5 pi) points
			-- it UP, not down. The two were the wrong way round here, and
			-- picking "Down" gave an arrow pointing up.
			local dirRad = dir == "right" and 0
			             or dir == "up"    and math.pi * 0.5
			             or dir == "left"  and math.pi
			             or dir == "down"  and math.pi * 1.5
			             or 0
			a.arrowTex:SetRotation(dirRad)
			if dir == "up" or dir == "down" then
				a.arrowTex:SetSize(sz, sz * aspect)
			else
				a.arrowTex:SetSize(sz * aspect, sz)
			end
			a.arrowTex:SetVertexColor(c.r, c.g, c.b)
			a.arrowTex:SetAlpha(1)
		end

	-- ---- Unknown style: clear everything ----
	else
		ClearAllStyles(a)
	end
end

BF:RegisterIndicator(AggroHighlight)
