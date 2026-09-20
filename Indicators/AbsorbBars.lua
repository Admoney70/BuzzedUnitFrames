--[[
BuzzardFrames: Indicators/AbsorbBars.lua

IMPORTANT: Preview frames (Options_Preview.lua) have parallel rendering
logic for absorbs and heal absorbs. When changing how any setting renders
here, the corresponding ApplyPreview* function in Options_Preview.lua
must be updated to match.
Absorb bar indicators — owns all absorb-related widgets:
  - absorbClip            (clip frame; limits absorb bars to the unfilled health gap)
  - healPrediction        (incoming heal bar)
  - absorbMissingHealth   (damage absorb bar in missing health gap)
  - absorbOvershield      (overshield overlay, reverse-fill from right edge)
  - overshieldGlow        (glow strip)
  - healAbsorb            (heal absorb overlay)
  - healAbsorbBar         (heal absorb top-strip bar)
  - frameClip             (clip frame for heal absorb)

Grid2 equivalent: IndicatorBar.lua instances for shields + heals.

Each call to Update unconditionally overwrites stale state (Grid2 pattern).
Ported from BF:UpdateAbsorbOverlay, BF:UpdateHealPrediction,
BF:UpdateHealAbsorb (LayoutFrame.lua).
]]

local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

local UnitExists              = UnitExists
local UnitHealthMax           = UnitHealthMax
local UnitGetTotalAbsorbs     = UnitGetTotalAbsorbs
local UnitGetTotalHealAbsorbs = UnitGetTotalHealAbsorbs
local UnitGetDetailedHealPrediction = UnitGetDetailedHealPrediction
local issecretvalue = issecretvalue or function() return false end

-- ============================================================
-- BF:IsOvershieldActive(ab) -- overshield master-gate helper
--
-- Overshield rendering is gated by BOTH showAbsorbsMissingHealth (the
-- master) and showOvershield (the per-feature toggle). When the master
-- is off, overshield is forced off regardless of its own toggle.
--
-- Exposed on BF so oUF_Absorbs.lua, Options_Absorbs.lua, and
-- Options_Preview.lua share the same semantics -- any divergence would
-- cause overshield rendering on unit frames or preview frames to contradict
-- the raid/party behavior when the master is off.
--
-- The `absorbs` status binding (see BFStatus.lua RebindAbsorbStatuses)
-- already enforces the master at the event level: when
-- showAbsorbsMissingHealth is off in all flats, UNIT_ABSORB_AMOUNT_CHANGED
-- is unregistered and no updates fire. This helper enforces the same
-- invariant at the render level, for the cases where an update is called
-- via a refresh sweep or direct call path rather than via the event.
-- ============================================================
function BF:IsOvershieldActive(ab)
	-- v94: overshield is independent of the missing-health master. It renders
	-- whenever showOvershield is on; the missing-health toggle only changes
	-- WHAT the LEFT overshield bar shows -- the excess when the missing-health
	-- bar is on, the full total absorb when it is off (see _ApplyAbsorbStyle
	-- ovLeftTotal).
	return ab ~= nil and ab.showOvershield and true or false
end


-- ============================================================
-- BF.SetAbsorbSuppressed(parent, suppressed) -- transient visibility
--
-- TRANSIENT state suppression for the absorb regions: dead, offline, or
-- "unit doesn't exist right now". Distinct from CONFIG visibility, which
-- _ApplyAbsorbStyle owns via Show()/Hide() on _absorbCfg_missingBarHidden.
--
-- Those two owners must not share a channel. They used to: the dead and
-- offline branches of Indicators/StatusText_Overlay.lua called
-- absorbMissingHealth:Hide() directly, and NOTHING ever called Show()
-- again except _ApplyAbsorbStyle -- which Update only runs when
-- BF._absorbStyleGen changes (a settings edit or a Layout). The result was
-- that the first death permanently blanked the missing-health absorb bar
-- on that frame: _UpdateAbsorbOverlay kept writing its value (it has no
-- visibility gate by design, see its SetValue comment) into a Hide()'d
-- frame, so the bar stayed invisible until a settings change or /reload --
-- and because frames are recycled, for every unit that later inherited it.
--
-- Alpha is the transient channel. Nothing else in the addon writes alpha on
-- absorbMissingHealth, so config Show/Hide and state suppression compose
-- cleanly: a config-hidden bar stays hidden whatever the alpha, and
-- un-suppressing never resurrects a bar the config disabled.
--
-- absorbMissingHealth ONLY, deliberately. absorbOvershield and
-- overshieldGlow look like they belong here, but their alpha is already
-- owned -- _UpdateAbsorbOverlay drives both with SetAlphaFromBoolean(r2,...)
-- on every absorb event. Forcing alpha 1 on them here would paint an
-- overshield that is not there until the next absorb event corrected it.
-- Their transient hiding self-heals through that same updater instead.
--
-- The parent's alpha multiplies through its regions (bg, overlay,
-- leftShadow), so the per-region Hide() calls the old path made -- with no
-- corresponding Show() anywhere -- are unnecessary as well as unsafe.
--
-- State is cached on parent._absorbSuppressed so steady-state ticks write
-- nothing; the nil initial value makes the first call always take effect.
function BF.SetAbsorbSuppressed(parent, suppressed)
	suppressed = suppressed and true or false
	if parent._absorbSuppressed == suppressed then return end
	parent._absorbSuppressed = suppressed
	if parent.absorbMissingHealth then
		parent.absorbMissingHealth:SetAlpha(suppressed and 0 or 1)
	end
end

-- ============================================================

local AbsorbBars = BF.indicatorPrototype:new("absorbBars")

-- ============================================================
-- Create
-- ============================================================
function AbsorbBars:Create(parent)
	if parent.absorbMissingHealth then
		parent[self.name] = parent.absorbMissingHealth
		return
	end

	local hBar = parent.healthBar
	if not hBar then return end
	local hBarTex = hBar:GetStatusBarTexture()

	-- Absorb clip: spans the full health bar so both absorbMissingHealth
	-- and absorbOvershield share the same clip context for correct draw ordering.
	local absorbClip = CreateFrame("Frame", nil, parent)
	absorbClip:SetAllPoints(hBar)
	absorbClip:SetClipsChildren(true)
	-- Parented to the UNIT FRAME, not hBar: the health bar lives inside its own
	-- SetClipsChildren render group (healthClip), which bounds the z-order of
	-- everything nested under it -- so absorbs parented under hBar could never rise
	-- above the aura-slot health tint/overlay effects regardless of their level.
	-- Anchored to hBar (geometry/clipping unchanged), leveled on the unit frame.
	-- Group level = parent+7 (overshield overlay + heal-prediction band).
	absorbClip:SetFrameLevel(hBar:GetFrameLevel() + 6)
	parent.absorbClip = absorbClip

	-- Heal prediction
	local healPred = BF.StatusBar(nil, absorbClip)
	healPred:EnableMouse(false)
	BF:DisablePixelSnapRegion(healPred)
	if hBarTex then
		healPred:SetPoint("TOPLEFT",    hBarTex, "TOPRIGHT")
		healPred:SetPoint("BOTTOMLEFT", hBarTex, "BOTTOMRIGHT")
	end
	healPred:SetStatusBarTexture("Interface\\RaidFrame\\Raid-Bar-Hp-Fill")
	healPred:SetStatusBarColor(0, 0.7, 0, 0.6)
	healPred:SetMinMaxValues(0, 1)
	healPred:SetValue(0)
	healPred:SetFrameLevel(hBar:GetFrameLevel() + 6)
	healPred:SetAlpha(0)
	healPred:Show()
	parent.healPrediction = healPred

	-- Absorb missing health (damage absorb bar in the missing health gap)
	local absorbMissingHealth = BF.StatusBar(nil, absorbClip)
	absorbMissingHealth:EnableMouse(false)
	BF:DisablePixelSnapRegion(absorbMissingHealth)
	if hBarTex then
		absorbMissingHealth:SetPoint("TOPLEFT",    hBarTex, "TOPRIGHT")
		absorbMissingHealth:SetPoint("BOTTOMLEFT", hBarTex, "BOTTOMRIGHT")
	end
	absorbMissingHealth:SetWidth(hBar:GetWidth())
	-- +7: within the absorbClip render group, this only orders the missing-health
	-- absorb ABOVE the overshield + heal-prediction (both hBar+6); the whole clip
	-- still sits at its own level, so nothing outside it is affected.
	absorbMissingHealth:SetFrameLevel(hBar:GetFrameLevel() + 7)
	local parentName = parent:GetName() or ""
	-- Base absorb texture
	-- Blizzard parity: totalAbsorb uses the "raidframe-shield-fill" atlas
	-- (FDID 7539076), NOT the overlay art. 7539079 is the separate
	-- totalAbsorbOverlay stacked above (see ~:144). Matches the _default
	-- branch of _ApplyAbsorbStyle (~:540), which was already correct.
	local absorbTex = BF.Texture(absorbMissingHealth, parentName ~= "" and (parentName .. "AbsorbBase") or nil, "ARTWORK")
	absorbTex:SetTexture(7539076, "REPEAT", "REPEAT")
	absorbTex:SetHorizTile(true)
	absorbTex:SetVertTile(true)
	absorbMissingHealth:SetStatusBarTexture(absorbTex)
	absorbMissingHealth:SetStatusBarColor(1, 1, 1, 0.8)
	absorbMissingHealth:SetMinMaxValues(0, 1)
	absorbMissingHealth:SetValue(0)
	absorbMissingHealth:Hide()
	-- Background: uses Grid2 pattern — sublayer-1 relative to fill texture,
	-- anchored to fill texture + bar edges to cover the fill area.
	local absorbMissingHealthBg = BF.Texture(absorbMissingHealth, parentName ~= "" and (parentName .. "AbsorbBg") or nil)
	absorbMissingHealthBg:SetColorTexture(0, 0, 0, 1)
	local layer, sublayer = absorbTex:GetDrawLayer()
	absorbMissingHealthBg:SetDrawLayer(layer, sublayer - 1)
	absorbMissingHealthBg:SetAllPoints(absorbTex)
	-- Overlay absorb texture: sublayer+1 relative to fill texture
	local absorbMissingHealthOverlay = BF.Texture(absorbMissingHealth, parentName ~= "" and (parentName .. "AbsorbOverlay") or nil)
	absorbMissingHealthOverlay:SetTexture(7539079, "REPEAT", "REPEAT")
	absorbMissingHealthOverlay:SetHorizTile(true)
	absorbMissingHealthOverlay:SetVertTile(true)
	absorbMissingHealthOverlay:SetDrawLayer(layer, sublayer + 1)
	absorbMissingHealthOverlay:SetAllPoints(absorbTex)
	absorbMissingHealthOverlay:Show()
	absorbMissingHealth.overlay = absorbMissingHealthOverlay
	absorbMissingHealth.bg = absorbMissingHealthBg
	-- Blizzard parity: TotalAbsorbLeftShadow (CompactUnitFrame.xml ~:23) --
	-- the shadow where the shield meets the health bar. Verbatim recipe:
	-- atlas "!raidframe-absorb-edge" (leading ! = vertically tiling strip),
	-- useAtlasSize=true so the WIDTH comes from the art (never SetWidth),
	-- anchored TOPLEFT+BOTTOMLEFT to the absorb fill ONLY -- two anchors, so
	-- it sits INSIDE the absorb's left edge and stretches vertically.
	-- Same sublevel as the overlay (BORDER+6 in Blizzard's layer table).
	-- Static geometry: Blizzard only Show/Hides it, never re-anchors.
	local absorbMissingHealthEdge = BF.Texture(absorbMissingHealth,
		parentName ~= "" and (parentName .. "AbsorbLeftShadow") or nil)
	absorbMissingHealthEdge:SetAtlas("!raidframe-absorb-edge", true)
	absorbMissingHealthEdge:SetDrawLayer(layer, sublayer + 1)
	absorbMissingHealthEdge:SetPoint("TOPLEFT",    absorbTex, "TOPLEFT")
	absorbMissingHealthEdge:SetPoint("BOTTOMLEFT", absorbTex, "BOTTOMLEFT")
	BF:DisablePixelSnapRegion(absorbMissingHealthEdge)
	absorbMissingHealthEdge:Hide()
	absorbMissingHealth.leftShadow = absorbMissingHealthEdge
	parent.absorbMissingHealth = absorbMissingHealth

	-- Frame clip for heal absorb
	local frameClip = CreateFrame("Frame", nil, parent)
	frameClip:SetAllPoints(parent)
	frameClip:SetClipsChildren(true)
	-- Same reparent rationale as absorbClip. Heal-absorb group level = parent+9.
	--
	-- v93 (owner-reported: heal absorb drawing OVER the frame border): this
	-- group sat at hBar+10 = parent+11, one level ABOVE the frame border
	-- (Container.lua ~:226, parent+10). Historically the whole absorb stack
	-- lived at hBar+1..+5; a later blanket +5 bump pushed heal absorb past the
	-- border while every sibling stayed under it. +8 = parent+9 restores the
	-- invariant: above every other absorb widget (missing-health +7,
	-- overshield glow +7, heal prediction +6) and below the border.
	frameClip:SetFrameLevel(hBar:GetFrameLevel() + 8)
	parent.frameClip = frameClip

	-- Absorb overshield (reverse-fill bar from right edge of container)
	-- Parented to parent, anchored to hBar, SetReverseFill(true), frame level +2.
	-- Uses clamp-mode-2 calculator. Blizzard textures applied via cached switching in Update.
	local absorbOvershield = BF.StatusBar(nil, absorbClip)
	absorbOvershield:EnableMouse(false)
	BF:DisablePixelSnapRegion(absorbOvershield)
	absorbOvershield:SetAllPoints(hBar)
	absorbOvershield:SetFrameLevel(hBar:GetFrameLevel() + 6)
	-- Base fill = shield-fill (7539076), matching the _default branch of
	-- _ApplyAbsorbStyle (~:631). The overlay art (7539079) is the separate
	-- texture stacked above at ~:181.
	local absorbOvershieldTex = BF.Texture(absorbOvershield, parentName ~= "" and (parentName .. "OvershieldAbsorb") or nil, "ARTWORK")
	absorbOvershieldTex:SetTexture(7539076, "REPEAT", "REPEAT")
	absorbOvershieldTex:SetHorizTile(true)
	absorbOvershieldTex:SetVertTile(true)
	absorbOvershield:SetStatusBarTexture(absorbOvershieldTex)
	absorbOvershield:SetStatusBarColor(1, 1, 1, 0.8)
	absorbOvershield:SetReverseFill(true)
	absorbOvershield:SetMinMaxValues(0, 1)
	absorbOvershield:SetValue(0)
	-- Blizzard overlay texture (7539079) — hidden by default, shown via cached switching in Update
	local absorbOvershieldOverlay = BF.Texture(absorbOvershield, parentName ~= "" and (parentName .. "OvershieldAbsorbOverlay") or nil, "ARTWORK", nil, 1)
	absorbOvershieldOverlay:SetTexture(7539079, "REPEAT", "REPEAT")
	absorbOvershieldOverlay:SetHorizTile(true)
	absorbOvershieldOverlay:SetVertTile(true)
	absorbOvershieldOverlay:SetBlendMode("BLEND")
	absorbOvershieldOverlay:SetAllPoints(absorbOvershieldTex)
	absorbOvershieldOverlay:Hide()
	absorbOvershield.overlay = absorbOvershieldOverlay
	local absorbOvershieldBg = BF.Texture(absorbOvershield, nil, "ARTWORK", nil, -1)
	absorbOvershieldBg:SetColorTexture(1, 1, 1, 0.7)
	absorbOvershieldBg:Hide()
	absorbOvershield.bg = absorbOvershieldBg
	absorbOvershield:Hide()
	parent.absorbOvershield = absorbOvershield

	-- Overshield glow ("Glow" style) — mirror of Blizzard's overAbsorbGlow
	-- on the compact raid frames. Authoritative art from the 12.1
	-- CompactUnitFrameLayout_SetupAbsorbElement source: atlas
	-- RaidFrame-Shield-Overshield, IgnoreAtlasSize, Clamp address mode, ADD
	-- blend. Geometry from the compact frame layout: 16 wide, FULL health-bar
	-- height (top+bottom anchored), left edge 7px inside the bar's right edge
	-- so the feathered glow straddles the edge. The old shape (3px strip
	-- centered on the edge at 90% height) read as a thin line, not a glow.
	-- _ApplyAbsorbStyle re-applies this geometry and mirrors it for
	-- overshieldAnchor == "LEFT".
	local overshieldGlow = CreateFrame("Frame", nil, parent)
	overshieldGlow:SetPoint("TOPLEFT", hBar, "TOPRIGHT", -7, 0)
	overshieldGlow:SetPoint("BOTTOMLEFT", hBar, "BOTTOMRIGHT", -7, 0)
	overshieldGlow:SetWidth(16)
	overshieldGlow:SetFrameLevel(hBar:GetFrameLevel() + 7)
	local glowTex = BF.Texture(overshieldGlow, nil, "ARTWORK")
	glowTex:SetAllPoints(overshieldGlow)
	glowTex:SetAtlas("RaidFrame-Shield-Overshield", false)
	glowTex:SetBlendMode("ADD")
	glowTex:SetVertexColor(1, 1, 1, 1)
	overshieldGlow:SetAlpha(0)
	overshieldGlow:Show()
	parent.overshieldGlow    = overshieldGlow
	parent.overshieldGlowTex = glowTex

	-- Heal absorb overlay
	-- v93 (owner-reported: a 1px column at the health fill's right edge,
	-- transient, most obvious in OverlayBlizzard style where the bright
	-- plus-symbol overlay sits on top). Root cause and fix are at the
	-- SetWidth call in _UpdateHealAbsorb -- see the comment there.
	local healAbsorb = BF.StatusBar(nil, frameClip)
	healAbsorb:EnableMouse(false)
	BF:DisablePixelSnapRegion(healAbsorb)
	healAbsorb:SetFrameLevel(hBar:GetFrameLevel() + 8)  -- v93: under the frame border (see frameClip)
	-- Blizzard parity: myHealAbsorb uses the "raidframe-absorb-fill" atlas
	-- (FDID 7539017) with wrap on both axes -- same asset the Overlay /
	-- OverlayBlizzard styles already stamp in _UpdateHealAbsorb (~:790).
	local healAbsorbTex = BF.Texture(healAbsorb, parent:GetName() and (parent:GetName() .. "MyHealAbsorb") or nil, "ARTWORK")
	healAbsorbTex:SetTexture(7539017, "REPEAT", "REPEAT")
	healAbsorbTex:SetHorizTile(true)
	healAbsorbTex:SetVertTile(true)
	healAbsorb:SetStatusBarTexture(healAbsorbTex)
	healAbsorb:SetStatusBarColor(1, 0, 0, 0.5)
	healAbsorb:SetReverseFill(true)
	healAbsorb:SetMinMaxValues(0, 1)
	healAbsorb:SetValue(0)
	healAbsorb:SetAlpha(0)
	healAbsorb:Show()
	parent.healAbsorb = healAbsorb

	-- Blizzard-style heal absorb plus symbols overlay (texture 7539063)
	local healAbsorbOverlay = BF.Texture(healAbsorb, parent:GetName() and (parent:GetName() .. "MyHealAbsorbOverlay") or nil, "ARTWORK", nil, 1)
	healAbsorbOverlay:SetTexture(7539063, "REPEAT", "REPEAT")
	healAbsorbOverlay:SetHorizTile(true)
	healAbsorbOverlay:SetVertTile(true)
	healAbsorbOverlay:SetAllPoints(healAbsorbTex)
	-- v93: alpha 1 here; the plus-symbol ALPHA now comes from the
	-- healAbsorbSymbolColor picker via SetVertexColor at style time.
	-- Leaving the old 0.2 would MULTIPLY with the picker's alpha
	-- (0.2 x 0.2 = 0.04) and render the symbols nearly invisible.
	healAbsorbOverlay:SetAlpha(1)
	healAbsorbOverlay:Hide()
	parent.healAbsorbOverlay = healAbsorbOverlay

	-- Blizzard-style heal absorb right shadow (texture 898248)
	local healAbsorbRightShadow = BF.Texture(healAbsorb, parent:GetName() and (parent:GetName() .. "MyHealAbsorbRightShadow") or nil, "ARTWORK", nil, 2)
	healAbsorbRightShadow:SetTexture(898248)
	healAbsorbRightShadow:Hide()
	parent.healAbsorbRightShadow = healAbsorbRightShadow

	-- Heal absorb bar (top strip)
	local healAbsorbBar = BF.StatusBar(nil, parent)
	healAbsorbBar:EnableMouse(false)
	BF:DisablePixelSnapRegion(healAbsorbBar)
	healAbsorbBar:SetFrameLevel(hBar:GetFrameLevel() + 8)  -- v93: under the frame border (see frameClip)
	-- Bar / BarBlizzard strip: same absorb-fill base as the overlay styles
	-- (~:218), so the tiling plus-symbols overlay below sits on matching art
	-- instead of a stretched flat fill.
	local healAbsorbBarTex = BF.Texture(healAbsorbBar, nil, "ARTWORK")
	healAbsorbBarTex:SetTexture(7539017, "REPEAT", "REPEAT")
	healAbsorbBarTex:SetHorizTile(true)
	healAbsorbBarTex:SetVertTile(true)
	healAbsorbBar:SetStatusBarTexture(healAbsorbBarTex)
	healAbsorbBar:SetStatusBarColor(1, 0, 0, 0.75)
	healAbsorbBar:SetReverseFill(false)
	healAbsorbBar:SetMinMaxValues(0, 1)
	healAbsorbBar:SetValue(0)
	healAbsorbBar:SetAlpha(0)
	healAbsorbBar:Show()
	-- Blizzard plus-symbols overlay for BarBlizzard style
	local healAbsorbBarOverlay = BF.Texture(healAbsorbBar, nil, "ARTWORK", nil, 1)
	healAbsorbBarOverlay:SetTexture(7539063, "REPEAT", "REPEAT")
	healAbsorbBarOverlay:SetHorizTile(true)
	healAbsorbBarOverlay:SetVertTile(true)
	healAbsorbBarOverlay:SetAllPoints(healAbsorbBarTex)
	-- v93: alpha 1 here; the plus-symbol ALPHA now comes from the
	-- healAbsorbSymbolColor picker via SetVertexColor at style time.
	-- Leaving the old 0.2 would MULTIPLY with the picker's alpha
	-- (0.2 x 0.2 = 0.04) and render the symbols nearly invisible.
	healAbsorbBarOverlay:SetAlpha(1)
	healAbsorbBarOverlay:Hide()
	healAbsorbBar._overlay = healAbsorbBarOverlay
	parent.healAbsorbBar = healAbsorbBar

	-- Reduced max health bar
	local container = parent.container
	local reducedMaxBar = BF.StatusBar(nil, parent)
	reducedMaxBar:EnableMouse(false)
	BF:DisablePixelSnapRegion(reducedMaxBar)
	if container then
		reducedMaxBar:SetAllPoints(container)
	else
		reducedMaxBar:SetAllPoints(hBar)
	end
	reducedMaxBar:SetFrameLevel(hBar:GetFrameLevel() + 1)
	reducedMaxBar:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
	reducedMaxBar:SetStatusBarColor(0.3, 0.3, 0.3, 0.8)
	reducedMaxBar:SetReverseFill(true)
	reducedMaxBar:SetMinMaxValues(0, 1)
	reducedMaxBar:SetValue(0)
	reducedMaxBar:Show()
	parent.reducedMaxHealthBar = reducedMaxBar

	parent[self.name] = absorbMissingHealth
end

-- ============================================================
-- Layout
-- ============================================================
function AbsorbBars:Layout(parent)
	local hBar = parent.healthBar
	if not hBar then return end
	local hFill = hBar:GetStatusBarTexture()
	-- Route absorbs reads via GetSectionProfileForFrame: on preview frames
	-- this resolves to the preview's flat.absorbs (or the global when per-layout
	-- is OFF); on live frames it resolves to the active flat's absorbs.
	local ab    = BF:GetSectionProfileForFrame("absorbs", parent)

	if parent.absorbClip then
		parent.absorbClip:ClearAllPoints()
		parent.absorbClip:SetAllPoints(hBar)
	end

	if parent.absorbMissingHealth and hFill then
		parent.absorbMissingHealth:ClearAllPoints()
		parent.absorbMissingHealth:SetPoint("TOPLEFT",    hFill, "TOPRIGHT")
		parent.absorbMissingHealth:SetPoint("BOTTOMLEFT", hFill, "BOTTOMRIGHT")
		-- v93: whole-pixel width, same reason as the heal-absorb bar (see
		-- _UpdateHealAbsorb) -- a fractional bar width leaves its remainder
		-- as a sub-pixel fill at value 0, which still lights a pixel column
		-- at the health fill's right edge. This one showed as a dark line
		-- (absorbMissingHealth.bg is an opaque black texture).
		parent.absorbMissingHealth:SetWidth(math.floor(hBar:GetWidth()))
	end

	if parent.healPrediction and hFill then
		parent.healPrediction:ClearAllPoints()
		parent.healPrediction:SetPoint("TOPLEFT",    hFill, "TOPRIGHT")
		parent.healPrediction:SetPoint("BOTTOMLEFT", hFill, "BOTTOMRIGHT")
		parent.healPrediction:SetWidth(hBar:GetWidth())
		parent._healPredAnchor = nil
	end

	if parent.healAbsorbBar and ab then
		local hStyle = ab.healAbsorbStyle
		local barH = (ab.showHealAbsorb and (hStyle == "Bar" or hStyle == "BarBlizzard") and ab.healAbsorbBarHeight) or 0
		local header = parent:GetParent()
		local frameH = header and header.frameHeight or parent:GetHeight() or 40
		barH = math.min(barH, frameH)
		-- Anchor to the clip frame (visible container bounds), not hBar
		-- itself, because hBar is oversized by 1px beyond the clip frame.
		local anchor = (hBar.clipFrame) or parent.container or hBar
		parent.healAbsorbBar:ClearAllPoints()
		parent.healAbsorbBar:SetPoint("TOPLEFT",  anchor, "TOPLEFT",  0, 0)
		parent.healAbsorbBar:SetPoint("TOPRIGHT", anchor, "TOPRIGHT", 0, 0)
		parent.healAbsorbBar:SetHeight(math.max(barH, 1))
	end

	parent._healPredAnchor    = nil
	parent._absorbGlowGeomKey = nil

	-- Precompute all settings-derived absorb state (Grid2 pattern).
	self:_ApplyAbsorbStyle(parent)

end

-- ============================================================
-- Update
-- ============================================================
function AbsorbBars:Update(parent, unit)
	-- PERF (style generation gate): _ApplyAbsorbStyle is a full settings
	-- pass (2 section resolutions + ~8 texture/color writes). Update runs
	-- on every UNIT_MAXHEALTH, death/offline transition, and full-frame
	-- indicator sweep (roster shuffles hit all 40 frames in one burst) —
	-- none of which change settings. Settings paths route through the
	-- LayoutFrame shims (BF:UpdateAbsorbOverlay / UpdateHealPrediction /
	-- UpdateHealAbsorb), which bump BF._absorbStyleGen so the next Update
	-- re-styles — including the in-combat setter path, where
	-- RefreshAllHealAbsorbs skips the destructive Layout. Layout itself
	-- still calls _ApplyAbsorbStyle unconditionally.
	if parent._absorbStyleGen ~= (BF._absorbStyleGen or 1) then
		self:_ApplyAbsorbStyle(parent)
	end
	self:_UpdateHealPrediction(parent, unit)
	self:_UpdateAbsorbOverlay(parent, unit)
	self:_UpdateHealAbsorb(parent, unit)
	-- _UpdateReducedMaxHealth removed from here: it now runs only on
	-- UNIT_MAX_HEALTH_MODIFIERS_CHANGED via the reducedmaxhealth status.
end

-- ============================================================
-- _UpdateHealPrediction
-- ============================================================
function AbsorbBars:_UpdateHealPrediction(parent, unit)
	if not parent.healPrediction then return end
	-- PERF: per-event path reads only the _absorbCfg_* fields resolved by
	-- _ApplyAbsorbStyle — no section resolution, color, or texture work here
	-- (UNIT_HEAL_PREDICTION fires at UNIT_HEALTH-burst rates in raid healing).

	if not parent._absorbCfg_showHealPred then
		parent.healPrediction:SetAlpha(0)
		return
	end

	local deathStatus = BF.statuses and BF.statuses.death
	if not unit or not UnitExists(unit) or (deathStatus and deathStatus:IsActive(unit)) then
		parent.healPrediction:SetAlpha(0)
		return
	end

	local anchor = parent._absorbCfg_healPredAnchor or "RIGHT"
	local hBar  = parent.healthBar
	local hFill = hBar and hBar:GetStatusBarTexture()

	if parent._healPredAnchor ~= anchor and hBar and hFill then
		parent.healPrediction:ClearAllPoints()
		if anchor == "LEFT" then
			parent.healPrediction:SetParent(parent.absorbClip)
			parent.healPrediction:SetPoint("TOPLEFT",    hBar, "TOPLEFT")
			parent.healPrediction:SetPoint("BOTTOMLEFT", hBar, "BOTTOMLEFT")
			parent.healPrediction:SetFrameLevel(hBar:GetFrameLevel() + 6)
		else
			if parent.absorbClip then
				parent.healPrediction:SetParent(parent.absorbClip)
			end
			parent.healPrediction:SetPoint("TOPLEFT",    hFill, "TOPRIGHT")
			parent.healPrediction:SetPoint("BOTTOMLEFT", hFill, "BOTTOMRIGHT")
			parent.healPrediction:SetFrameLevel(hBar:GetFrameLevel() + 6)
		end
		parent.healPrediction:SetWidth(hBar:GetWidth())
		parent._healPredAnchor = anchor
	end

	-- Color + texture applied by _ApplyAbsorbStyle (pure config).

	local maxHealth = UnitHealthMax(unit)
	BF.HealthCalc:SetIncomingHealClampMode(anchor == "LEFT" and 1 or 0)
	UnitGetDetailedHealPrediction(unit, "player", BF.HealthCalc)
	local _, incomingHeals = BF.HealthCalc:GetIncomingHeals()

	parent.healPrediction:SetMinMaxValues(0, maxHealth)
	parent.healPrediction:SetValue(incomingHeals)
	parent.healPrediction:SetAlpha(1)
end

-- ============================================================
-- _UpdateAbsorbOverlayHealth
-- Lightweight health-only update for UNIT_HEALTH events.
-- Only recalculates the health-dependent clamping values
-- (SetMinMaxValues/SetValue) and overshield alpha. Does NOT
-- re-resolve settings, textures, or colors — those only change
-- on settings edits and are handled by the full _UpdateAbsorbOverlay
-- (called from UNIT_ABSORB_AMOUNT_CHANGED).
--
-- Grid2 equivalent: shields-overflow registers UNIT_HEALTH with
-- UpdateIndicatorsFromEvent which calls a color-only IsActive check.
-- BF needs to update bar values because the absorb bar's fill area
-- depends on current health (clamping to the missing health gap).
-- ============================================================
function AbsorbBars:_UpdateAbsorbOverlayHealth(parent, unit)
	if not parent.absorbMissingHealth then return end
	if not unit then return end

	-- v94 PERF (Win 5): the missing-health bar + its left shadow no longer
	-- update here. They feed the UNCLAMPED total on UNIT_ABSORB_AMOUNT_CHANGED
	-- and are clamped geometrically by absorbClip + the fill-edge anchor (see
	-- _UpdateAbsorbOverlay). Only OVERSHIELD -- the absorb exceeding the current
	-- missing-health gap -- is genuinely health-dependent, so it is all that
	-- stays on the UNIT_HEALTH path. And this function only runs when overshield
	-- is active: RebindAbsorbStatuses binds the shieldsOverflow (UNIT_HEALTH)
	-- status on the overshield gate, so with overshield off there is ZERO
	-- per-health-tick absorb work.
	if not parent._absorbCfg_overshieldActive then return end
	-- v94: LEFT overshield showing the TOTAL absorb (missing-health bar off)
	-- is health-independent -- its value is set on absorb events, nothing to
	-- recompute per tick.
	if parent._absorbCfg_ovLeftTotal then return end

	local maxHealth = UnitHealthMax(unit)
	UnitGetDetailedHealPrediction(unit, "player", BF.AbsorbCalc)
	local _, r2 = BF.AbsorbCalc:GetDamageAbsorbs()

	if parent._absorbCfg_ovStyle == "Glow" then
		if parent.overshieldGlow then
			parent.overshieldGlow:SetAlphaFromBoolean(r2, 1, 0)
		end
	elseif parent.absorbOvershield then
		-- v94: LEFT is now r2-gated too (see _UpdateAbsorbOverlay) so the left
		-- overshield bar hides when there is no excess, instead of double-drawing
		-- the absorb the missing-health bar already shows.
		parent.absorbOvershield:SetAlphaFromBoolean(r2, 1, 0)
		UnitGetDetailedHealPrediction(unit, "player", BF.OvershieldCalc)
		local ovAbsorbed = BF.OvershieldCalc:GetDamageAbsorbs()
		parent.absorbOvershield:SetMinMaxValues(0, maxHealth)
		parent.absorbOvershield:SetValue(ovAbsorbed)
	end
end

-- ============================================================
-- _UpdateAbsorbOverlay
-- ============================================================
-- _ApplyAbsorbStyle: precompute all settings-derived state.
-- Grid2 pattern: resolve config at init/layout time, not per-event.
-- Called from Layout() and on settings changes. Caches results on
-- the frame as _absorbCfg_* fields so _UpdateAbsorbOverlay can
-- skip all profile lookups, texture resolution, and color work.
-- ============================================================
function AbsorbBars:_ApplyAbsorbStyle(parent)
	if not parent.absorbMissingHealth then return end
	local ab = BF:GetSectionProfileForFrame("absorbs", parent)
	local hp = BF:GetSectionProfileForFrame("healthPower", parent)

	local ovStyle          = ab and ab.overshieldStyle or "Overlay"
	local overshieldActive = BF:IsOvershieldActive(ab)
	local ovAnchor         = ab and ab.overshieldAnchor or "RIGHT"
	local showMissing      = ab and ab.showAbsorbsMissingHealth ~= false

	-- Cache resolved settings on the frame
	parent._absorbCfg_ovStyle          = ovStyle
	parent._absorbCfg_overshieldActive = overshieldActive
	parent._absorbCfg_ovAnchor         = ovAnchor
	parent._absorbCfg_showMissing      = showMissing
	-- Heal-pred / heal-absorb resolved settings (consumed by the per-event
	-- _UpdateHealPrediction / _UpdateHealAbsorb, which no longer resolve
	-- the absorbs section at all).
	parent._absorbCfg_showHealPred     = (ab and ab.showHealPrediction) and true or false
	parent._absorbCfg_healPredAnchor   = ab and ab.healPredictionAnchor or "RIGHT"
	parent._absorbCfg_showHealAbsorb   = (ab and ab.showHealAbsorb) and true or false
	parent._absorbCfg_healAbsorbStyle  = ab and ab.healAbsorbStyle or "Overlay"
	-- Stamp the style generation consumed by Update's gate.
	parent._absorbStyleGen = BF._absorbStyleGen or 1

	-- Missing-health absorb bar: hidden only when the missing-health feature
	-- itself is off. (It used to also be force-hidden in Overlay LEFT mode on
	-- the theory that "overshield covers everything" -- but the LEFT overshield
	-- bar only carries the EXCESS, so hiding the missing bar meant the in-gap
	-- absorb never showed in LEFT mode. Now both coexist: the missing bar shows
	-- the absorb over the gap; the LEFT overshield bar shows the excess spill.)
	local missingBarHidden = not showMissing
	parent._absorbCfg_missingBarHidden = missingBarHidden
	-- v94: LEFT overshield with the missing-health bar OFF -> the overshield
	-- bar is the sole absorb display, so it carries the UNCLAMPED TOTAL (and
	-- is health-independent). With the missing bar on it carries only the
	-- excess. Overlay + LEFT only; Glow and RIGHT are unaffected.
	parent._absorbCfg_ovLeftTotal = (ovStyle ~= "Glow" and overshieldActive
	                                 and ovAnchor == "LEFT" and not showMissing) and true or false
	-- Symmetric visibility (mirrors overshield branch ~:594): _ApplyAbsorbStyle
	-- is the authoritative cfg-driven visibility setter. Without an explicit
	-- Show() in the not-hidden branch, the bar stays in the Hide()'d state
	-- from Create (line ~133), and the only path that would un-hide it is
	-- _UpdateAbsorbOverlay (the UNIT_ABSORB_AMOUNT_CHANGED handler) — which
	-- doesn't fire if the absorb is steady-state at frame creation (e.g.
	-- Power Word: Shield holding across a reload). The UNIT_HEALTH clamp
	-- sidekick _UpdateAbsorbOverlayHealth updates the bar's value but does
	-- not call Show(), so without this branch the bar updates internally
	-- while invisible forever.
	if missingBarHidden then
		parent.absorbMissingHealth:Hide()
	else
		parent.absorbMissingHealth:Show()
	end

	-- Absorb missing-health texture
	local absorbTexKey = (ab and ab.useCustomAbsorbBarTexture and ab.absorbBarTexture) or "_default"
	if parent._absorbMissingHealthTexStyle ~= absorbTexKey then
		local arTex = parent.absorbMissingHealth:GetStatusBarTexture()
		if arTex then
			if absorbTexKey ~= "_default" then
				local path = BF:ResolveBarTexture(absorbTexKey)
				arTex:SetTexture(path)
				arTex:SetHorizTile(false)
				arTex:SetVertTile(false)
				if parent.absorbMissingHealth.overlay then parent.absorbMissingHealth.overlay:Hide() end
			else
				arTex:SetTexture(7539076, "REPEAT", "REPEAT")
				arTex:SetHorizTile(true)
				arTex:SetVertTile(true)
				if parent.absorbMissingHealth.overlay then parent.absorbMissingHealth.overlay:Show() end
			end
		end
		parent._absorbMissingHealthTexStyle = absorbTexKey
	end

	-- Absorb base texture color
	if ab and ab.useCustomAbsorbColor then
		local bc = ab.absorbBaseColor
		if bc then
			parent.absorbMissingHealth:SetStatusBarColor(bc.r, bc.g, bc.b, bc.a or 1)
		else
			parent.absorbMissingHealth:SetStatusBarColor(0.941, 0.941, 0.937, 1.0)
		end
	else
		parent.absorbMissingHealth:SetStatusBarColor(0.941, 0.941, 0.937, 1.0) -- #f0f0ef @ 100%
	end
	-- Absorb left shadow: opt-in visibility + tint. Deliberately NOT gated on
	-- useCustomAbsorbBarTexture -- the seam shadow should be available on any
	-- bar texture, custom or default. Cached so the update path only alphas.
	parent._absorbCfg_showShadow = (ab == nil) or (ab.showAbsorbShadow ~= false)
	if parent.absorbMissingHealth.leftShadow then
		local sc = ab and ab.absorbShadowColor
		parent.absorbMissingHealth.leftShadow:SetVertexColor(
			sc and sc.r or 1, sc and sc.g or 1, sc and sc.b or 1, sc and sc.a or 1)
		if not parent._absorbCfg_showShadow then
			parent.absorbMissingHealth.leftShadow:Hide()
		end
	end
	-- Absorb overlay texture color
	if parent.absorbMissingHealth.overlay then
		if ab and ab.useCustomAbsorbColor then
			local oc = ab.absorbOverlayColor
			if oc then
				parent.absorbMissingHealth.overlay:SetVertexColor(oc.r, oc.g, oc.b, oc.a or 1)
			else
				parent.absorbMissingHealth.overlay:SetVertexColor(1, 1, 1, 0.66)
			end
		else
			parent.absorbMissingHealth.overlay:SetVertexColor(1, 1, 1, 0.66) -- #ffffff @ 66%
		end
	end
	-- Background color
	if parent.absorbMissingHealth.bg then
		if hp and hp.useCustomBackgroundColor then
			local bgc = hp.backgroundColor or { r = 0, g = 0, b = 0 }
			parent.absorbMissingHealth.bg:SetColorTexture(bgc.r, bgc.g, bgc.b, 1)
		else
			parent.absorbMissingHealth.bg:SetColorTexture(0, 0, 0, 1)
		end
	end

	-- Heal prediction style (PERF: moved from _UpdateHealPrediction, which
	-- re-applied color and an LSM texture resolve + SetStatusBarTexture on
	-- every UNIT_HEAL_PREDICTION — all pure config).
	if parent.healPrediction then
		local c = ab and ab.healPredictionColor
		if c then
			parent.healPrediction:SetStatusBarColor(c.r, c.g, c.b, c.a or 0.6)
		else
			parent.healPrediction:SetStatusBarColor(0, 0.7, 0, 0.6)
		end
		if ab and ab.useCustomHealPredictionTexture then
			parent.healPrediction:SetStatusBarTexture(BF:ResolveBarTexture(ab.healPredictionTexture or "Solid"))
		else
			parent.healPrediction:SetStatusBarTexture("Interface\\RaidFrame\\Raid-Bar-Hp-Fill")
		end
	end

	-- Heal absorb style (PERF: moved from _UpdateHealAbsorb, which re-stamped
	-- fill texture + blend + color and re-anchored the overlay bar to the
	-- health fill on every UNIT_HEAL_ABSORB_AMOUNT_CHANGED — all config, and
	-- the anchor targets are fixed between layout passes: the health fill
	-- TEXTURE OBJECT and the bar width. The fill object is replaced when the
	-- health texture setting changes, but that path re-runs Layout → here).
	do
		local haStyle = parent._absorbCfg_healAbsorbStyle
		-- v93: custom heal-absorb fill texture. nil = keep the style's own
		-- default art (7539017 / WHITE8x8); a path replaces the BASE FILL
		-- only -- the plus-symbol overlay and right shadow are untouched.
		local haCustomTex = (ab and ab.useCustomHealAbsorbTexture)
			and BF:ResolveBarTexture(ab.healAbsorbTexture or "Solid") or nil
		-- v93: plus-symbol tint. The overlay used to be baked white at alpha
		-- 0.2 at creation and never re-stamped, so on a bright heal-absorb
		-- color the symbols vanished into the fill (owner-reported). Opt-in:
		-- with the toggle off this is the white-at-0.2 the overlay always had.
		local hsc = (ab and ab.useCustomHealAbsorbSymbolColor and ab.healAbsorbSymbolColor)
			or { r = 1, g = 1, b = 1, a = 0.2 }
		if haStyle == "Bar" or haStyle == "BarBlizzard" then
			if parent.healAbsorbBar then
				local tex = parent.healAbsorbBar:GetStatusBarTexture()
				if haStyle == "BarBlizzard" then
					if tex then
						tex:SetTexture(haCustomTex or 7539017)
						if haCustomTex then
							tex:SetHorizTile(false)
							tex:SetVertTile(false)
						end
						BF:DisablePixelSnapRegion(tex)
						tex:SetBlendMode("BLEND")
					end
					local c = ab and ab.healAbsorbColor
					if c then
						parent.healAbsorbBar:SetStatusBarColor(c.r, c.g, c.b, c.a or 1)
					else
						parent.healAbsorbBar:SetStatusBarColor(1, 1, 1, 1)
					end
				else
					if tex then
						tex:SetTexture(haCustomTex or "Interface\\Buttons\\WHITE8x8")
						if haCustomTex then
							tex:SetHorizTile(false)
							tex:SetVertTile(false)
						end
						BF:DisablePixelSnapRegion(tex)
						tex:SetBlendMode("BLEND")
					end
					local c = ab and ab.healAbsorbColor
					if c then
						parent.healAbsorbBar:SetStatusBarColor(c.r, c.g, c.b, c.a or 0.5)
					else
						parent.healAbsorbBar:SetStatusBarColor(1, 0, 0, 0.5)
					end
				end
				-- Plus-symbol overlay rides the bar's alpha; shown-state is
				-- style-static (BarBlizzard only).
				if parent.healAbsorbBar._overlay then
					parent.healAbsorbBar._overlay:SetShown(haStyle == "BarBlizzard")
					parent.healAbsorbBar._overlay:SetVertexColor(hsc.r, hsc.g, hsc.b, hsc.a or 0.2)
				end
			end
		else -- "Overlay" / "OverlayBlizzard"
			if parent.healAbsorb then
				local tex = parent.healAbsorb:GetStatusBarTexture()
				if tex then
					tex:SetTexture(haCustomTex or 7539017)
					if haCustomTex then
						tex:SetHorizTile(false)
						tex:SetVertTile(false)
					end
					BF:DisablePixelSnapRegion(tex)
					tex:SetBlendMode("BLEND")
				end
				local c = ab and ab.healAbsorbColor
				if c then
					parent.healAbsorb:SetStatusBarColor(c.r, c.g, c.b, c.a or 1)
				else
					parent.healAbsorb:SetStatusBarColor(1, 1, 1, 1)
				end
				if parent.healAbsorbOverlay then
					parent.healAbsorbOverlay:SetVertexColor(hsc.r, hsc.g, hsc.b, hsc.a or 0.2)
				end
				-- Right shadow tracks the heal-absorb's own fill texture
				-- object — stable between style passes.
				if parent.healAbsorbRightShadow and tex then
					parent.healAbsorbRightShadow:ClearAllPoints()
					parent.healAbsorbRightShadow:SetAllPoints(tex)
				end
				-- Bar-to-health-fill anchors: INVALIDATE here, stamp LAZILY in
				-- _UpdateHealAbsorb. A direct style-time stamp was tried and
				-- reverted (owner-reported: overlay painted across the frame/
				-- aggro borders) — during a build pass this runs before the
				-- health bar's final size lands. Clearing the guard makes the
				-- next heal-absorb event re-anchor once with settled geometry;
				-- every event after that is one reference compare. Same lazy
				-- idiom as _healPredAnchor above.
				parent.healAbsorb._bfAnchorTex = nil
			end
		end
	end

	-- Overshield: hide unused widgets and apply static config
	if not overshieldActive then
		if parent.absorbOverflow then parent.absorbOverflow:SetAlpha(0) end
		if parent.overshieldGlow then parent.overshieldGlow:SetAlpha(0) end
		if parent.absorbOvershield then parent.absorbOvershield:Hide() end
	elseif ovStyle == "Glow" then
		if parent.absorbOverflow then parent.absorbOverflow:SetAlpha(0) end
		if parent.absorbOvershield then parent.absorbOvershield:Hide() end
		if parent.overshieldGlow then
			-- Blizzard overAbsorbGlow parity (see the creation site): atlas
			-- RaidFrame-Shield-Overshield, ADD, 16 wide, full bar height,
			-- straddling the bar edge 7px in. Height rides the top+bottom
			-- anchors, so the key only carries the anchor side. LEFT mirrors
			-- the geometry and flips the art via the legacy file + texcoord
			-- flip (SetTexCoord would override an atlas's coords; switching
			-- back to RIGHT re-establishes them through SetAtlas).
			local glowKey = "blz." .. ovAnchor
			if parent._absorbGlowGeomKey ~= glowKey then
				parent._absorbGlowGeomKey = glowKey
				local hBar = parent.healthBar
				local g = parent.overshieldGlow
				local t = parent.overshieldGlowTex
				g:ClearAllPoints()
				g:SetWidth(16)
				if ovAnchor == "LEFT" then
					g:SetPoint("TOPRIGHT", hBar, "TOPLEFT", 7, 0)
					g:SetPoint("BOTTOMRIGHT", hBar, "BOTTOMLEFT", 7, 0)
					if t then
						t:SetTexture("Interface\\RaidFrame\\Shield-Overshield")
						t:SetTexCoord(1, 0, 0, 1)
					end
				else
					g:SetPoint("TOPLEFT", hBar, "TOPRIGHT", -7, 0)
					g:SetPoint("BOTTOMLEFT", hBar, "BOTTOMRIGHT", -7, 0)
					if t then
						t:SetAtlas("RaidFrame-Shield-Overshield", false)
					end
				end
				if t then
					t:SetBlendMode("ADD")
					t:SetVertexColor(1, 1, 1, 1)
				end
			end
		end
	else
		-- "Overlay" mode
		if parent.absorbOverflow then parent.absorbOverflow:SetAlpha(0) end
		if parent.overshieldGlow then parent.overshieldGlow:SetAlpha(0) end
		if parent.absorbOvershield then
			parent.absorbOvershield:SetReverseFill(ovAnchor == "RIGHT")
			parent.absorbOvershield:Show()

			-- Overshield texture
			local overshieldTexKey = (ab and ab.useCustomOvershieldBarTexture and ab.overshieldBarTexture) or "_default"
			if parent._absorbOvershieldTexStyle ~= overshieldTexKey then
				local otTex = parent.absorbOvershield:GetStatusBarTexture()
				if otTex then
					if overshieldTexKey ~= "_default" then
						local path = BF:ResolveBarTexture(overshieldTexKey)
						otTex:SetTexture(path)
						otTex:SetHorizTile(false)
						otTex:SetVertTile(false)
						if parent.absorbOvershield.overlay then parent.absorbOvershield.overlay:Hide() end
					else
						otTex:SetTexture(7539076, "REPEAT", "REPEAT")
						otTex:SetHorizTile(true)
						otTex:SetVertTile(true)
						if parent.absorbOvershield.overlay then parent.absorbOvershield.overlay:Show() end
					end
				end
				parent._absorbOvershieldTexStyle = overshieldTexKey
			end

			-- Overshield base texture color
			if ab and ab.useCustomOvershieldColor then
				local obc = ab.overshieldBaseColor
				if obc then
					parent.absorbOvershield:SetStatusBarColor(obc.r, obc.g, obc.b, obc.a or 1)
				else
					parent.absorbOvershield:SetStatusBarColor(0.937, 0.941, 0.855, 0.36)
				end
			else
				parent.absorbOvershield:SetStatusBarColor(0.937, 0.941, 0.855, 0.36) -- #eff0da @ 36%
			end
			-- Overshield overlay texture color
			if parent.absorbOvershield.overlay then
				if ab and ab.useCustomOvershieldColor then
					local ooc = ab.overshieldOverlayColor
					if ooc then
						parent.absorbOvershield.overlay:SetVertexColor(ooc.r, ooc.g, ooc.b, ooc.a or 1)
					else
						parent.absorbOvershield.overlay:SetVertexColor(1, 1, 1, 0.66)
					end
				else
					parent.absorbOvershield.overlay:SetVertexColor(1, 1, 1, 0.66) -- #ffffff @ 66%
				end
			end
		end
	end
end

-- ============================================================
-- Per-event update for UNIT_ABSORB_AMOUNT_CHANGED.
-- Grid2 pattern: only API calls + SetValue per event; all config
-- was precomputed by _ApplyAbsorbStyle.
-- ============================================================
function AbsorbBars:_UpdateAbsorbOverlay(parent, unit)
	if not parent.absorbMissingHealth then return end

	if not unit or not UnitExists(unit) then
		-- Suppress, do NOT Hide(). Hide() here was the same trap as the
		-- death path: only _ApplyAbsorbStyle calls Show(), and Update runs
		-- it only on a style-generation bump, so a frame that ever saw a
		-- missing unit kept its absorb bar invisible for whatever unit it
		-- was recycled onto. See BF.SetAbsorbSuppressed above.
		BF.SetAbsorbSuppressed(parent, true)
		if parent.absorbMissingHealth.leftShadow then parent.absorbMissingHealth.leftShadow:Hide() end
		if parent.absorbOverflow then parent.absorbOverflow:SetAlpha(0) end
		if parent.overshieldGlow then parent.overshieldGlow:SetAlpha(0) end
		-- absorbOvershield keeps Hide() -- its alpha is the updater's
		-- channel (SetAlphaFromBoolean below), and _ApplyAbsorbStyle's
		-- Show() at the overshield branch is its restore path.
		if parent.absorbOvershield then parent.absorbOvershield:Hide() end
		return
	end

	-- Live unit: lift any suppression left over from a death, a disconnect,
	-- or a missing-unit tick. Cached, so this is a no-op on steady state.
	BF.SetAbsorbSuppressed(parent, false)

	local maxHealth = UnitHealthMax(unit)

	-- v94 PERF (Win 5): feed the UNCLAMPED total absorb. The bar is a child
	-- of absorbClip (SetClipsChildren, bounded to the health bar) and anchored
	-- TOPLEFT->hFill TOPRIGHT, so the clip + fill-edge anchor reproduce the
	-- missing-health clamp geometrically -- min(total, missingHealth) on screen
	-- -- WITHOUT a per-UNIT_HEALTH recompute. This is Grid2's `shields` pattern
	-- (UnitGetTotalAbsorbs, no UNIT_HEALTH registration). The value changes
	-- only on UNIT_ABSORB_AMOUNT_CHANGED, so the bar leaves the health tick
	-- entirely (see _UpdateAbsorbOverlayHealth, now overshield-only).
	local totalAbsorb = UnitGetTotalAbsorbs(unit)
	if not parent._absorbCfg_missingBarHidden then
		parent.absorbMissingHealth:SetMinMaxValues(0, maxHealth)
		parent.absorbMissingHealth:SetValue(totalAbsorb)
		-- Left shadow: same secret-safe boolean, now off the total. The edge
		-- texture is anchored to the fill's left edge inside absorbClip, so it
		-- clips away at full health just like the bar -- no health-tick needed.
		local ls = parent.absorbMissingHealth.leftShadow
		if ls and parent._absorbCfg_showShadow then
			ls:Show()
			ls:SetAlphaFromBoolean(totalAbsorb, 1, 0)
		end
	end

	-- Overshield (gated by cached config). Only overshield still needs the
	-- clamp-mode calculators (the excess bit r2 + the clamp-2 amount), and
	-- both read current health, so they -- and only they -- stay health-driven.
	if not parent._absorbCfg_overshieldActive then
		return
	end

	UnitGetDetailedHealPrediction(unit, "player", BF.AbsorbCalc)
	local _, r2 = BF.AbsorbCalc:GetDamageAbsorbs()

	if parent._absorbCfg_ovStyle == "Glow" then
		if parent.overshieldGlow then
			parent.overshieldGlow:SetAlphaFromBoolean(r2, 1, 0)
		end
	else
		-- "Overlay" mode
		if parent.absorbOvershield then
			if parent._absorbCfg_ovLeftTotal then
				-- Missing-health bar off + LEFT: this bar IS the absorb display,
				-- so it carries the unclamped TOTAL (shown whenever any absorb
				-- exists), not the excess. Health-independent.
				local totalAbsorb = UnitGetTotalAbsorbs(unit)
				parent.absorbOvershield:SetAlphaFromBoolean(totalAbsorb, 1, 0)
				parent.absorbOvershield:SetMinMaxValues(0, maxHealth)
				parent.absorbOvershield:SetValue(totalAbsorb)
			else
				-- Excess overshield: gate on r2 (overshield-exists), same as RIGHT;
				-- the missing-health bar shows the in-gap portion.
				parent.absorbOvershield:SetAlphaFromBoolean(r2, 1, 0)
				UnitGetDetailedHealPrediction(unit, "player", BF.OvershieldCalc)
				local ovAbsorbed = BF.OvershieldCalc:GetDamageAbsorbs()
				parent.absorbOvershield:SetMinMaxValues(0, maxHealth)
				parent.absorbOvershield:SetValue(ovAbsorbed)
			end
		end
	end
end

-- ============================================================
-- _UpdateHealAbsorb
-- ============================================================
function AbsorbBars:_UpdateHealAbsorb(parent, unit)
	if parent.healAbsorb    then parent.healAbsorb:SetAlpha(0)    end
	if parent.healAbsorbBar then parent.healAbsorbBar:SetAlpha(0) end
	if parent.healAbsorbOverlay     then parent.healAbsorbOverlay:Hide()     end
	if parent.healAbsorbRightShadow then parent.healAbsorbRightShadow:Hide() end

	-- PERF: style (fill texture/blend/color, plus-overlay shown-state, and
	-- the anchor of the overlay bar to the health fill) moved to
	-- _ApplyAbsorbStyle — it was re-stamped here on every
	-- UNIT_HEAL_ABSORB_AMOUNT_CHANGED, which fires per damage/heal tick
	-- against the absorb on heal-absorb fights. Per-event work is now:
	-- values, alpha, and re-showing the widgets the reset above hid.
	if not parent._absorbCfg_showHealAbsorb then return end
	if not unit or not UnitExists(unit) then return end

	local maxHealth = UnitHealthMax(unit)
	local healAbsorb = UnitGetTotalHealAbsorbs(unit)
	if not healAbsorb then return end

	local style = parent._absorbCfg_healAbsorbStyle or "Overlay"

	if style == "Bar" or style == "BarBlizzard" then
		if parent.healAbsorbBar then
			parent.healAbsorbBar:SetMinMaxValues(0, maxHealth)
			parent.healAbsorbBar:SetValue(healAbsorb)
			parent.healAbsorbBar:SetAlpha(1)
		end
	else
		if parent.healAbsorb then
			if style == "OverlayBlizzard" and parent.healAbsorbOverlay then
				parent.healAbsorbOverlay:Show()
			end
			if parent.healAbsorbRightShadow then
				parent.healAbsorbRightShadow:Show()
			end
			-- PERF (lazy anchor guard): anchors target the health fill
			-- texture OBJECT + the bar width — stable until a Layout/settings
			-- pass, which clears _bfAnchorTex (_ApplyAbsorbStyle) so the next
			-- event re-stamps with settled geometry. Reference compare only;
			-- object handles are never secret values. NOT stamped at style
			-- time — during builds the bar isn't sized yet (owner-reported
			-- border-overlap regression).
			local hFill = parent.healthBar and parent.healthBar:GetStatusBarTexture()
			if hFill and parent.healAbsorb._bfAnchorTex ~= hFill then
				parent.healAbsorb._bfAnchorTex = hFill
				parent.healAbsorb:ClearAllPoints()
				parent.healAbsorb:SetPoint("TOPRIGHT",    hFill, "TOPRIGHT")
				parent.healAbsorb:SetPoint("BOTTOMRIGHT", hFill, "BOTTOMRIGHT")
				-- v93 ROOT CAUSE (measured): at value 0 this bar's fill
				-- rendered at exactly the FRACTIONAL PART of the bar's width
				-- -- barW 106.13600921631 gave fillW 0.13601562380791 -- and
				-- a sub-pixel width still lights a whole pixel column at the
				-- health fill's right edge. Nothing to do with secret values:
				-- the oUF frames simply happen to land on whole-pixel widths.
				-- Rounding the width to a whole pixel leaves no remainder, so
				-- a zero-value fill is genuinely zero-width.
				parent.healAbsorb:SetWidth(
					math.floor(parent.healthBar:GetWidth()))
			end
			parent.healAbsorb:SetMinMaxValues(0, maxHealth)
			parent.healAbsorb:SetValue(healAbsorb)
			parent.healAbsorb:SetAlpha(1)
		end
	end
end

-- ============================================================
-- _UpdateReducedMaxHealth
-- ============================================================
local function RestoreHealthBarAnchors(parent)
	if parent._reducedMaxHealthActive then
		local hBar = parent.healthBar
		local container = parent.container
		if hBar and container then
			local clip = hBar.clipFrame
			if clip then
				clip:ClearAllPoints()
				clip:SetAllPoints(container)
				hBar:ClearAllPoints()
				hBar:SetAllPoints(clip)
			else
				hBar:ClearAllPoints()
				hBar:SetAllPoints(container)
			end
		end
		parent._reducedMaxHealthActive = nil
	end
end

function AbsorbBars:_UpdateReducedMaxHealth(parent, unit)
	local bar = parent.reducedMaxHealthBar
	if not bar then return end

	local ab = BF:GetSectionProfileForFrame("absorbs", parent)
	if not (ab and ab.showReducedMaxHealth) then
		bar:Hide()
		parent._reducedMaxPct = nil
		RestoreHealthBarAnchors(parent)
		return
	end

	local deathStatus = BF.statuses and BF.statuses.death
	if not unit or not UnitExists(unit) or (deathStatus and deathStatus:IsActive(unit)) then
		bar:Hide()
		parent._reducedMaxPct = nil
		RestoreHealthBarAnchors(parent)
		return
	end

	local pct
	if GetUnitTotalModifiedMaxHealthPercent then
		pct = GetUnitTotalModifiedMaxHealthPercent(unit)
	end

	if not pct then
		bar:Hide()
		parent._reducedMaxPct = nil
		RestoreHealthBarAnchors(parent)
		return
	end

	if BF._debugReducedMax then
		local pctStr = issecretvalue(pct) and "<secret>" or tostring(pct)
		print("|cffff00ff[ReducedMax]|r unit=" .. tostring(unit) .. " pct=" .. pctStr)
	end

	-- Texture work is settings-derived, not unit-derived: guard it behind a
	-- style key so a repeat event skips the LSM fetch / SetAtlas entirely.
	-- Same pattern as _absorbMissingHealthTexStyle (~:530) and
	-- _absorbOvershieldTexStyle (~:621). Colors stay OUTSIDE the guard --
	-- they're live color-picker values and must reach the bar on every pass.
	local reducedTexKey = (ab and ab.useCustomReducedMaxTexture
		and (ab.reducedMaxHealthTexture or "Solid")) or "_default"
	if parent._reducedMaxTexStyle ~= reducedTexKey then
		if reducedTexKey ~= "_default" then
			bar:SetStatusBarTexture(BF:ResolveBarTexture(reducedTexKey))
			local rtex = bar:GetStatusBarTexture()
			if rtex then
				rtex:SetHorizTile(false)
				rtex:SetVertTile(false)
			end
		else
			-- Blizzard parity (12.1 CompactUnitFrameLayout_SetupAbsorbElement,
			-- the TempMaxHealthLoss line): the reduced-max art is the
			-- "raidframe-MaximumHealthReduction-Overlay" atlas applied to the
			-- StatusBar's FILL texture with IgnoreAtlasSize + AddressModeWrap
			-- on both axes. The wrap address mode is what makes the pattern
			-- repeat at native size instead of scaling with the band width --
			-- without it the art stretches and its apparent angle skews as the
			-- reduction changes. Same recipe as the absorb fills (~:540).
			local tex = bar:GetStatusBarTexture()
			if tex then
				tex:SetAtlas("raidframe-MaximumHealthReduction-Overlay", false)
				tex:SetHorizTile(true)
				tex:SetVertTile(true)
			end
		end
		parent._reducedMaxTexStyle = reducedTexKey
	end

	-- Color: live color-picker value, applied every pass (outside the guard).
	if reducedTexKey ~= "_default" then
		local c = ab and ab.reducedMaxHealthColor
		if c then
			bar:SetStatusBarColor(c.r, c.g, c.b, c.a or 0.8)
		else
			bar:SetStatusBarColor(0.3, 0.3, 0.3, 0.8)
		end
	else
		bar:SetStatusBarColor(1, 1, 1, 1)
	end

	bar:SetMinMaxValues(0, 1)
	bar:SetValue(pct)
	bar:Show()

	local hBar = parent.healthBar
	local container = parent.container
	local reducedTex = bar:GetStatusBarTexture()
	if hBar and container and reducedTex then
		local clip = hBar.clipFrame
		if clip then
			clip:ClearAllPoints()
			clip:SetPoint("TOPLEFT", container, "TOPLEFT")
			clip:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT")
			clip:SetPoint("TOPRIGHT", reducedTex, "TOPLEFT")
			clip:SetPoint("BOTTOMRIGHT", reducedTex, "BOTTOMLEFT")
			hBar:ClearAllPoints()
			hBar:SetAllPoints(clip)
		else
			hBar:ClearAllPoints()
			hBar:SetPoint("TOPLEFT", container, "TOPLEFT")
			hBar:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT")
			hBar:SetPoint("TOPRIGHT", reducedTex, "TOPLEFT")
			hBar:SetPoint("BOTTOMRIGHT", reducedTex, "BOTTOMLEFT")
		end
		parent._reducedMaxHealthActive = true
	end

	parent._reducedMaxPct = pct
end

-- ============================================================
function AbsorbBars:GetFrame(parent)
	return parent.absorbMissingHealth
end

BF:RegisterIndicator(AbsorbBars)


-- ============================================================
-- AbsorbBarsHealthClamp: UNIT_HEALTH sidekick (Grid2 shields-overflow pattern)
--
-- Grid2 equivalent: the shields-overflow status in StatusShields.lua, which
-- registers UNIT_HEALTH and triggers a lightweight update that clamps the
-- absorb bar fill to the current missing-health gap.
--
-- Structure follows the healthBarColor sidekick (Indicators/HealthBar.lua):
-- no widgets of its own (Create/Layout/Disable/Release are no-ops), shares
-- the widgets owned by AbsorbBars via parent.absorbMissingHealth et al.
-- Update only runs _UpdateAbsorbOverlayHealth — the lightweight
-- health-dependent-clamping subset that used to run unconditionally inline
-- inside BF:UNIT_HEALTH. Full absorb resolution (settings, textures,
-- colors) still runs via AbsorbBars:Update on UNIT_ABSORB_AMOUNT_CHANGED.
--
-- Bound to the `shieldsOverflow` status by BF:RebindAbsorbStatuses, which
-- enables the status only when showAbsorbsMissingHealth is on in any flat.
-- When absorbs are disabled everywhere, the shieldsOverflow status stays
-- disabled, UNIT_HEALTH is never registered for it, and this sidekick pays
-- nothing per frame per event.
-- ============================================================
local AbsorbBarsHealthClamp = BF.indicatorPrototype:new("absorbBarsHealthClamp")

function AbsorbBarsHealthClamp:Create(parent) end
function AbsorbBarsHealthClamp:Layout(parent) end
function AbsorbBarsHealthClamp:Disable(parent) end
function AbsorbBarsHealthClamp:Release(parent) end
function AbsorbBarsHealthClamp:GetFrame(parent) return parent.absorbMissingHealth end

-- v99 PERF: call the same-file upvalue directly. This ran the registry
-- lookup `BF.indicators.absorbBars` plus a method-existence check on EVERY
-- health tick for every frame -- 41,601 times in a 456 s raid window -- to
-- reach a function that is fixed at load. Measured as the gap between this
-- row (681.04 ms inclusive) and its only child (627.82 ms): 53 ms of pure
-- indirection. AbsorbBars is a local in this file, declared above, so there
-- is nothing to resolve and nothing to go stale.
function AbsorbBarsHealthClamp:Update(parent, unit)
	return AbsorbBars:_UpdateAbsorbOverlayHealth(parent, unit)
end

BF:RegisterIndicator(AbsorbBarsHealthClamp)
