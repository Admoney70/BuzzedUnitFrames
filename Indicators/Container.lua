--[[
BuzzardFrames: Indicators/Container.lua
Container indicator — the visible background texture behind the health bar.

Grid2 equivalent: the container texture in GridFrame_Init + Layout().
Grid2 creates it as frame.container in GridFrame_Init, then positions
and colors it in GridFramePrototype:Layout().

This indicator owns:
  - parent.container (Texture)
  - Backdrop (border + fill via SetBackdrop)
]]

local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")
local InCombatLockdown = InCombatLockdown

local Container = BF.indicatorPrototype:new("container")

-- ============================================================
-- Pixel helpers (local copies to avoid cross-file dependency)
-- ============================================================
local function PixelsToUI(n)
	local pixelSize = 768 / select(2, GetPhysicalScreenSize())
	local uiScale = UIParent:GetEffectiveScale()
	local pixelMult = (uiScale > 0) and (pixelSize / uiScale) or 1
	return n * pixelMult
end

-- ============================================================
-- Rounded border styles (Rounded / Rounded (Thick)) — same art +
-- geometry as HealerExternalTracker's bar treatment: nine-sliced white
-- ring art (FrameBorder / FrameBorderThick) tinted at layout time, plus
-- a nine-sliced rounded-rect mask (FrameMask / FrameMaskThick,
-- CLAMPTOBLACKADDITIVE) that pulls the frame content inside the corner
-- radius. Slicing keeps thickness/radius constant at any frame size.
-- The mask lives on the unit frame and is attached to content regions
-- across child frames — the live-proven in-house pattern is the oUF
-- icon cutout mask (oUF_Shared.lua:468-488), including Show/Hide of the
-- MASK to enable/disable masking without Remove churn.
--
-- ART RESOLUTION: 128px source, 32px slice margins. DEDICATED Frame*
-- assets (not HET's Bar* files) so the two never fight over resolution.
-- Margins MUST match the art (ROUND_SLICE).
--
-- GEOMETRY (v56 — all figures in TEXELS of the 128px art): outer corner
-- radius 6.4. Ring BAND = the visible thickness: Rounded 2.0,
-- Rounded (Thick) 3.0 (v56 thinned ~50% from ~3.8/~5.8 and redrawn with
-- HARD edges — AA confined to ≤1 texel; the old art's 2-3 texel soft
-- ramps were the source of the "thick and blurry" look). The masks are
-- the ring's OUTER silhouette offset INWARD uniformly by half the band
-- (FrameMask inset1.0/r5.4, FrameMaskThick inset1.5/r4.9), so the
-- content sits in the MIDDLE of the ring band: far enough out to
-- underlap the ring (no inner gap), far enough in that it never pokes
-- past the ring's outer corner (no sliver). Straight-edge content still
-- runs under the ring. See EffectiveBorderPixels.
-- ============================================================
local ROUND_SLICE = 32
local ROUND_BORDER_TEX = "Interface\\AddOns\\BuzzardFrames\\Media\\FrameBorder"
local ROUND_MASK_TEX = "Interface\\AddOns\\BuzzardFrames\\Media\\FrameMask"
local ROUND_BORDER_THICK_TEX = "Interface\\AddOns\\BuzzardFrames\\Media\\FrameBorderThick"
local ROUND_MASK_THICK_TEX = "Interface\\AddOns\\BuzzardFrames\\Media\\FrameMaskThick"

-- borders.borderStyle: "square" (default 4-edge flat border) |
-- "rounded" | "rounded_thick".
local function IsRoundedStyle(s)
	return s == "rounded" or s == "rounded_thick"
end
BF.IsRoundedBorderStyle = IsRoundedStyle

-- Shared rounded ring art for the border-style HIGHLIGHTS (target,
-- aggro "border", dispel border): they draw their OWN sliced ring on
-- their own (higher-level) frame, tinted with the highlight color, so
-- they replace the base border ring visually exactly as their 4 square
-- edges replace the square border today. They match the FRAME's rounded
-- style (thin/thick) so every ring stays concentric. Returns
-- (ringTexPath, sliceMargin) for a given borderStyle, or nil for square.
function BF:GetRoundedBorderRing(borderStyle)
	if borderStyle == "rounded" then return ROUND_BORDER_TEX, ROUND_SLICE end
	if borderStyle == "rounded_thick" then return ROUND_BORDER_THICK_TEX, ROUND_SLICE end
	return nil
end

-- Slice margin for any highlight-owned ring texture (must match the art).
BF.RoundedBorderSlice = ROUND_SLICE

-- Attach the frame's rounded content mask to a region. Safe to call at
-- CREATE time for any region regardless of the active border style: a
-- hidden mask = masking off (oUF cutout-mask precedent), so regions are
-- attached unconditionally and the rounded style just Shows/Hides the
-- mask. This is the attach path for every region created AFTER the
-- first Container:Layout — lazily-created overlays (buff overlay bars,
-- buff color overlay, OOR darken) and 12.1 aura slot-button textures
-- (dispel overlay, frame-effect tint/overlay). Regions that exist by
-- Layout time are covered by the EachMaskableRegion walk instead; both
-- paths share the _bfRoundMasked attach-once flag.
function BF:AttachFrameRoundMask(parent, region)
	local mask = parent and parent.frameRoundMask
	if mask and region and not region._bfRoundMasked then
		region:AddMaskTexture(mask)
		region._bfRoundMasked = true
	end
end

-- Highlight ring art by PIXEL WIDTH (1..8), so the border-style
-- highlights honor their own width sliders (Target 1-8, Aggro 1-5,
-- Debuff 1-5) instead of being pinned to the frame's rounded thickness.
-- All widths share the frame's outer corner radius (concentric); the
-- band grows INWARD, exactly like the square highlights' 4 edges. The
-- 128px/32-margin format matches the frame ring; the band unit is
-- 2.0 texels per width step (v56 — re-based to equal the thin frame
-- ring band, so a width-1 highlight matches the frame border and the
-- steps scale from there).
local ROUND_HIGHLIGHT_TEX = "Interface\\AddOns\\BuzzardFrames\\Media\\HighlightRing"
function BF:GetHighlightRing(width)
	local w = width and math.floor(width + 0.5) or 2
	if w < 1 then w = 1 elseif w > 8 then w = 8 end
	return ROUND_HIGHLIGHT_TEX .. w
end

-- Border thickness in PIXELS that frame CONTENT is inset by (layout).
-- Rounded styles return 0: the content fills to the frame edge and the
-- ring is drawn OVER it (OVERLAY), with the content masked to the ring's
-- outer corner radius. This UNDERLAP is what guarantees there is never a
-- transparent gap between the health bar and the rounded border at any
-- frame position/scale — the content always extends under the ring, and
-- the ring's opaque band hides its outer edge. The visible rounded
-- border thickness lives entirely in the ring ART (2.0 / 3.0 texels),
-- not in a content inset. Square keeps the classic inset. Shared with
-- PowerBar/NameText so every content inset agrees.
function BF:EffectiveBorderPixels(bp)
	if not bp or bp.enableBorder == false then return 0 end
	local style = bp.borderStyle or "square"
	if IsRoundedStyle(style) then return 0 end
	return bp.borderThickness or 1
end

-- Every content region the rounded mask must cover (approved scope:
-- core layers + absorb/heal-absorb overlays; the 3px overshield glow
-- marker stays square — visually negligible at the corner radius).
-- All regions exist by the first Layout (indicator Create pass runs
-- before any Layout). SetStatusBarTexture(file) re-files the SAME
-- region object, so per-region attach flags survive texture swaps.
local function EachMaskableRegion(parent, fn)
	fn(parent.container)
	local hb = parent.healthBar
	if hb then fn(hb:GetStatusBarTexture()); fn(hb.bg) end
	local pb = parent.powerBar
	if pb then fn(pb:GetStatusBarTexture()); fn(pb.bg) end
	local amh = parent.absorbMissingHealth
	if amh then fn(amh:GetStatusBarTexture()); fn(amh.bg); fn(amh.overlay) end
	local hpr = parent.healPrediction
	if hpr then fn(hpr:GetStatusBarTexture()) end
	local ov = parent.absorbOvershield
	if ov then fn(ov:GetStatusBarTexture()); fn(ov.bg); fn(ov.overlay) end
	local ha = parent.healAbsorb
	if ha then fn(ha:GetStatusBarTexture()) end
	fn(parent.healAbsorbOverlay)
	fn(parent.healAbsorbRightShadow)
	local hab = parent.healAbsorbBar
	if hab then fn(hab:GetStatusBarTexture()) end
	local rm = parent.reducedMaxHealthBar
	if rm then fn(rm:GetStatusBarTexture()) end
	-- Mouseover highlight is a full-fill overlay on the health bar (not a
	-- border); clip it to the rounded shape so it doesn't square off the
	-- corners. Created lazily on hover, so guarded.
	if parent.mouseoverHighlight then fn(parent.mouseoverHighlight) end
	-- Debuff/dispel overlay + buff overlay family (legacy widgets — the
	-- 12.1 slot-button textures attach at their init sites via
	-- BF:AttachFrameRoundMask instead). Several are created lazily, so
	-- their create sites ALSO attach; this walk backstops regions that
	-- already exist when the style switches to rounded.
	-- v67: the buffOverlayBar / buffColorOverlayBar StatusBar walks were
	-- removed (12.1-only). Nothing creates either widget any more —
	-- BF.EnsureBuffOverlayBar went with the deleted buffHighlight indicator
	-- and BF.EnsureBuffColorOverlayBar went in v59 — so both branches were
	-- permanently nil. frame.buffOverlay and frame.buffColorOverlay are
	-- still live (created by Indicators/BuffOverlay.lua and
	-- BF:ShowSingleSpellPreview respectively).
	fn(parent.dispelDebuffOverlay)
	fn(parent.buffOverlay)
	fn(parent.buffColorOverlay)
	-- Out-of-range darken overlay (full-frame fill; lazy — live + preview).
	local oor = parent._oorDarkenFrame
	if oor then fn(oor._tex) end
end

-- Cached backdrop table (mirrors PixelPerfect.lua pattern)
local frameBackdrop = nil
local cachedBorderN = -1

local function BuildBackdrop(borderN)
	if borderN == cachedBorderN then return end
	cachedBorderN = borderN
	if borderN > 0 then
		local edge = PixelsToUI(borderN)
		frameBackdrop = {
			bgFile   = "Interface\\Buttons\\WHITE8X8",
			edgeFile = "Interface\\Buttons\\WHITE8X8",
			edgeSize = edge,
			insets   = { left = edge, right = edge, top = edge, bottom = edge },
		}
	else
		frameBackdrop = nil
	end
end

-- ============================================================
-- Create: the container texture is already created in
-- BuzzardFrame_Init (frame.container = frame:CreateTexture()).
-- This Create just ensures it exists and sets initial properties.
-- ============================================================
function Container:Create(parent)
	-- Skip if already created by BuzzardFrame_Init or legacy InitFrame
	local container = parent.container
	if not container then
		container = BF.Texture(parent, nil, "BACKGROUND")
		parent.container = container
		container:SetTexture("Interface\\Buttons\\WHITE8X8")
	end

	-- Frame border: dedicated frame at a high level so it always renders
	-- above health bars, absorb bars, and other content.
	if not parent.frameBorder then
		local fb = CreateFrame("Frame", nil, parent)
		fb:SetAllPoints(parent)
		fb:SetFrameLevel(parent:GetFrameLevel() + 10)
		fb.top    = BF.Texture(fb, nil, "OVERLAY")
		fb.bottom = BF.Texture(fb, nil, "OVERLAY")
		fb.left   = BF.Texture(fb, nil, "OVERLAY")
		fb.right  = BF.Texture(fb, nil, "OVERLAY")
		for _, edge in ipairs({fb.top, fb.bottom, fb.left, fb.right}) do
			edge:SetColorTexture(0, 0, 0, 1)
		end
		parent.frameBorder = fb
	end

	-- Rounded border ring + content mask (hidden until a rounded
	-- borderStyle selects them in Layout). Both live on a PIXEL HOST
	-- (v58): a child of frameBorder whose SetScale is stamped in Layout
	-- so the host's effective scale == pixelSize, i.e. 1 art texel
	-- renders as EXACTLY 1 physical pixel. That makes the sliced ring
	-- band (2/3 texels) and the mask geometry pixel-perfect at any UI
	-- scale — same guarantee the square borders get from PixelsToUI.
	-- The host rides frameBorder so the ring layers exactly like the
	-- square edges; SetAllPoints(parent) anchors convert across the
	-- scale, so the on-screen rect is unchanged.
	if not parent.frameRoundBorder then
		local host = CreateFrame("Frame", nil, parent.frameBorder)
		host:SetAllPoints(parent)
		host:SetFrameLevel(parent.frameBorder:GetFrameLevel())
		parent.frameRoundHost = host

		local ring = BF.Texture(host, nil, "OVERLAY")
		ring:SetTextureSliceMargins(ROUND_SLICE, ROUND_SLICE, ROUND_SLICE, ROUND_SLICE)
		ring:SetAllPoints(parent)
		ring:Hide()
		parent.frameRoundBorder = ring

		local mask = BF.MaskTexture(host)
		-- BLOCKING LOAD (required): the mask texture is swapped at runtime
		-- when the border style changes (rounded <-> rounded_thick). Without
		-- this, switching to a mask file not yet loaded this session loads it
		-- ASYNC — and a CLAMPTOBLACKADDITIVE mask reads BLACK (alpha 0 =
		-- erases the masked content) until it finishes, so the health bars
		-- vanished until the setting was toggled again. Every other mask in
		-- the addon (aura/HET/oUF) sets this; the frame mask was the one that
		-- swaps textures live, so it needs it most.
		if mask.SetBlockingLoadsRequested then
			mask:SetBlockingLoadsRequested(true)
		end
		mask:SetTextureSliceMargins(ROUND_SLICE, ROUND_SLICE, ROUND_SLICE, ROUND_SLICE)
		mask:SetAllPoints(parent)
		mask:Hide()
		parent.frameRoundMask = mask
	end

	parent[self.name] = container
end

-- ============================================================
-- Layout: position container, apply backdrop, set colors
-- Grid2 equivalent: the container/backdrop section of
-- GridFramePrototype:Layout()
-- ============================================================
-- The content rect's geometry, computed from SETTINGS + the header's frame
-- size -- never measured. One function so the two consumers cannot drift:
-- Container:Layout (which anchors the container by it) and anything that
-- must know the health area's size BEFORE the frame has been laid out.
-- The second consumer is the Frame Effect overlay (BuffsAndContainers
-- RestampFxOverlay): fx slots are created in :Create, ahead of the first
-- frame:Layout, so the health bar still measures 0 there, and the overlay
-- strip is a fraction of the bar -- it needs the number Layout is about to
-- produce, not the whole frame's height (2026-09-11 review: the frame-size
-- stand-in ran the strip a few pixels past the bar inside a keystone, where
-- the corrective re-measure is denied until the key ends).
--
-- Returns w, h (frame), inset, effectivePowerH, borderN, borderUI, rounded,
-- frameScale, pixelSize; or nil when the frame has no healthPower profile.
-- effectivePowerH is 0 without a unit, exactly as Container:Layout reserves.
function BF.ComputeFrameContentGeometry(parent)
	local hp = BF:GetSectionProfileForFrame("healthPower", parent)
	local bp = BF:GetSectionProfileForFrame("borders", parent)
	if not hp then return nil end
	local borderStyle = (bp and bp.borderStyle) or "square"
	local enableBorder = not (bp and bp.enableBorder == false)
	local rounded = enableBorder and IsRoundedStyle(borderStyle)
	-- borderN drives the CONTENT inset only (0 for rounded — the content
	-- underlaps the ring; see EffectiveBorderPixels).
	local borderN = BF:EffectiveBorderPixels(bp)
	-- Use the frame's own effective scale (includes header scale) so
	-- borders remain 1 physical pixel regardless of frame scale setting.
	local frameScale = parent:GetEffectiveScale()
	local pixelSize = 768 / select(2, GetPhysicalScreenSize())
	local borderUI = (frameScale > 0) and (borderN * pixelSize / frameScale) or PixelsToUI(borderN)
	-- Get frame dimensions from parent header (Grid2 pattern)
	local header = parent:GetParent()
	local w = header and header.frameWidth or parent:GetWidth()
	local h = header and header.frameHeight or parent:GetHeight()
	-- Power bar height (container shrinks to make room)
	-- Use BF:Scale to match the exact height the PowerBar indicator uses.
	-- Raid-style twins force the bar from the oUF frame's own showPowerBar
	-- toggle, so the strip must be reserved even with all three flat
	-- filters off (BF:TwinForcesPowerBar, LayoutFrame.lua). Non-twin
	-- frames get nil back and behave exactly as before.
	local anyPowerBar = hp.showAllPowerBars or hp.showPowerBarHealers or hp.showPowerBarBloodDK
		or (BF.TwinForcesPowerBar and BF:TwinForcesPowerBar(parent) == true)
	local rawPowerH = anyPowerBar and (hp.powerBarHeight or 4) or 0
	local powerH = BF.Scale and BF:Scale(rawPowerH) or rawPowerH
	-- When no unit is assigned, or when the unit shouldn't show a power bar, reserve no space.
	local effectivePowerH = (parent.unit and BF.ShouldShowPowerBar and BF:ShouldShowPowerBar(parent.unit, parent)) and powerH or 0
	-- Container is inset by the border width minus a half-pixel overlap
	-- (see the anchor block in Container:Layout for why).
	local halfPx = borderN > 0 and (pixelSize / (frameScale > 0 and frameScale or 1)) * 0.5 or 0
	local inset = borderUI - halfPx
	return w, h, inset, effectivePowerH, borderN, borderUI, rounded, frameScale, pixelSize
end

-- The health area's designed size, for a consumer that runs before the frame
-- is laid out. Same arithmetic Container:Layout publishes as _bf_contentW/H.
function BF.ComputeFrameContentSize(parent)
	local w, h, inset, effectivePowerH = BF.ComputeFrameContentGeometry(parent)
	if not (w and h) then return nil end
	return w - inset * 2, h - inset * 2 - effectivePowerH
end

function Container:Layout(parent)
	local container = parent[self.name]
	if not container then return end

	-- Route healthPower / borders reads via GetSectionProfileForFrame so
	-- preview frames see their own per-layout settings.
	local hp = BF:GetSectionProfileForFrame("healthPower", parent)
	local bp = BF:GetSectionProfileForFrame("borders", parent)
	if not hp then return end

	-- Pixel math -- shared with BF.ComputeFrameContentSize, see above.
	local w, h, inset, effectivePowerH, borderN, borderUI, rounded, frameScale, pixelSize
		= BF.ComputeFrameContentGeometry(parent)
	local borderStyle = (bp and bp.borderStyle) or "square"
	BuildBackdrop(borderN)

	-- NOTE: the cast bar deliberately reserves NOTHING here. It is an
	-- overlay in every anchor mode -- inside the health area it draws on
	-- top, and the two outside modes float above/below the frame entirely.
	-- An earlier design had a "row" placement that carved out its own
	-- strip; it was dropped because reserving only while a cast is live
	-- costs a Container:Layout on every cast start AND stop (~10/sec across
	-- a 20-man raid), makes health bars visibly jitter, and runs unguarded
	-- SetPoint calls under combat lockdown. Reserving permanently instead
	-- left a dead strip on screen whenever nobody was casting. Overlay
	-- placement has neither problem and costs zero per cast.

	-- Rounded ring + content mask. Both live on the frame permanently;
	-- style selection is texture + Show/Hide only (config-time — Layout
	-- never runs per-update). Mask attach is once per region, flagged on
	-- the region object.
	local ring = parent.frameRoundBorder
	local mask = parent.frameRoundMask
	if ring and mask then
		if rounded then
			-- v58 pixel host: host effective scale == pixelSize → 1 art
			-- texel = 1 physical pixel (band exactly 2/3 px, corner
			-- radius a constant ~6 px). Change-guarded; re-stamped every
			-- Layout so UI-scale/frame-scale changes are picked up.
			local host = parent.frameRoundHost
			if host then
				local k = (frameScale > 0) and (pixelSize / frameScale) or 1
				if host._bf_k ~= k then
					host:SetScale(k)
					host._bf_k = k
				end
			end
			local thick = borderStyle == "rounded_thick"
			local bc = bp and bp.borderColor or { r = 0, g = 0, b = 0 }
			-- v69: border opacity folded into borderColor.a (the separate
			-- borderOpacity key was removed); alpha now rides the color table.
			local ba = (bc and bc.a) or 1.0
			ring:SetTexture(thick and ROUND_BORDER_THICK_TEX or ROUND_BORDER_TEX)
			ring:SetVertexColor(bc.r, bc.g, bc.b, ba)
			ring:Show()
			mask:SetTexture(thick and ROUND_MASK_THICK_TEX or ROUND_MASK_TEX,
				"CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
			-- Pixel snap the ring+mask PAIR so the hard texel edges land
			-- on pixel boundaries (crisp at 1 texel = 1 px). Runs AFTER
			-- the SetTexture calls above and overrides the unsnap the
			-- creation funnel applied (BF.Texture, PixelPerfect.lua
			-- section 7). Both regions share identical anchors, so
			-- they snap to the same rect and stay geometrically paired
			-- (mid-band rule intact). Content regions stay UNsnapped —
			-- the mask clips them, so their edges never show.
			ring:SetSnapToPixelGrid(true)
			ring:SetTexelSnappingBias(0)
			mask:SetSnapToPixelGrid(true)
			mask:SetTexelSnappingBias(0)
			EachMaskableRegion(parent, function(tex)
				if tex and not tex._bfRoundMasked then
					tex:AddMaskTexture(mask)
					tex._bfRoundMasked = true
				end
			end)
			mask:Show()
		else
			ring:Hide()
			-- Hidden mask = masking off (oUF cutout-mask precedent);
			-- attachments stay in place for the next rounded switch.
			mask:Hide()
		end
	end

	-- Frame border — rendered via dedicated high-level frame
	local fb = parent.frameBorder
	if fb then
		if borderN > 0 and not IsRoundedStyle(borderStyle) then
			local bc = bp and bp.borderColor or { r = 0, g = 0, b = 0 }
			-- v69: border opacity folded into borderColor.a (see above).
			local ba = (bc and bc.a) or 1.0
			for _, edge in ipairs({fb.top, fb.bottom, fb.left, fb.right}) do
				edge:SetColorTexture(bc.r, bc.g, bc.b, ba)
			end
			fb.top:ClearAllPoints()
			fb.top:SetPoint("TOPLEFT", parent, "TOPLEFT")
			fb.top:SetPoint("TOPRIGHT", parent, "TOPRIGHT")
			fb.top:SetHeight(borderUI)
			fb.bottom:ClearAllPoints()
			fb.bottom:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT")
			fb.bottom:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT")
			fb.bottom:SetHeight(borderUI)
			fb.left:ClearAllPoints()
			fb.left:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -borderUI)
			fb.left:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 0, borderUI)
			fb.left:SetWidth(borderUI)
			fb.right:ClearAllPoints()
			fb.right:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -borderUI)
			fb.right:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, borderUI)
			fb.right:SetWidth(borderUI)
			fb.top:Show(); fb.bottom:Show(); fb.left:Show(); fb.right:Show()
		else
			fb.top:Hide(); fb.bottom:Hide(); fb.left:Hide(); fb.right:Hide()
		end
	end
	-- Remove legacy backdrop if present
	if not BF._inCombat and parent.currentBackdrop then
		parent:SetBackdrop(nil)
		parent.currentBackdrop = nil
	end

	-- Container is inset by the border width minus a half-pixel overlap.
	-- The overlap ensures the container extends slightly under the border
	-- edges, eliminating subpixel rounding gaps when frames sit at
	-- fractional pixel positions (e.g. later raid groups in a chained
	-- layout). The border textures render at OVERLAY level on a high-level
	-- frame, so the overlap is hidden.
	-- (inset computed in BF.ComputeFrameContentGeometry above.)
	container:ClearAllPoints()
	container:SetPoint("TOPLEFT", parent, "TOPLEFT", inset, -inset)
	container:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -inset, effectivePowerH + inset)

	-- Publish the content rect's dimensions.
	--
	-- 12.1: GetWidth/GetHeight on the unit button and its children return
	-- SECRET numbers, and comparing a secret hard-errors. Anything that
	-- needs to size itself relative to the health area must therefore
	-- COMPUTE from the header's frameWidth/frameHeight (which is what `w`
	-- and `h` above already are) rather than measure. Consumer:
	-- Indicators/CastBar.lua, which sizes the cast bar as a fraction of the
	-- health area's height.
	if w and h then
		parent._bf_contentW = w - inset * 2
		parent._bf_contentH = h - inset * 2 - effectivePowerH
	end

	-- Container color
	if hp.useCustomBackgroundColor then
		local c = hp.backgroundColor or { r = 0, g = 0, b = 0 }
		container:SetVertexColor(c.r, c.g, c.b, hp.backgroundAlpha or 1)
	else
		container:SetVertexColor(0, 0, 0, hp.backgroundAlpha or 1)
	end
end

-- ============================================================
-- Update: container doesn't change per-unit — no-op.
-- Grid2's container texture is static; color changes only on
-- profile change (via Layout).
-- ============================================================
function Container:Update(parent, unit)
	-- Intentionally empty. Container is geometry-only.
end

-- ============================================================
-- GetFrame: container is a texture, not a frame — return it
-- directly so Layout/GetFrame checks work.
-- ============================================================
function Container:GetFrame(parent)
	return parent[self.name]
end

BF:RegisterIndicator(Container)
