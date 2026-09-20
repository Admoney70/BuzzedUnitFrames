--[[
BuzzardFrames: Indicators/CastBar.lua

Per-unit cast bar for the party/raid frames. Structure mirrors
Indicators/PowerBar.lua (Create / Layout / Update + RegisterIndicator);
the cast-specific behavior follows Libs/oUF/elements/castbar.lua, which
is the reference 12.1 implementation already vendored in this addon.

Grid2 has no cast bar of any kind (zero UNIT_SPELLCAST_* references in
the whole codebase), so there is no Grid2 pattern to mirror here.

DIVISION OF LABOUR -- this is the part that keeps the feature cheap:

  Create  : NO-OP. Widgets are built lazily by EnsureBuilt the first time
            Layout sees the feature enabled, so users who never turn cast
            bars on never pay for the widgets.
  Layout  : ALL styling and anchoring, plus the static options preview.
            Config-time only.
  Update  : per-event. Reads state, flips visibility, sets the timer.
            It must NEVER re-read style options or re-anchor anything.

12.1 ENGINE RULES (see the castbar status in BFStatus.lua for the full
list -- the two that bite hardest here):

  * Bar progress is engine-driven. SetMinMaxValues(0,1) then
    SetTimerDuration(durationObject, interpolation, direction). The
    engine animates. There is NO OnUpdate on this indicator, and there
    must not be: 40 raid frames each ticking every render frame is
    exactly the cost this design exists to avoid. Timer TEXT is likewise
    engine-driven via C_DurationUtil.CreateDurationTextBinding.

  * Interruptibility is not shown at all. These frames only ever display
    party/raid members and their pets, and you do not interrupt a
    friendly player's cast. The status therefore never reads
    notInterruptible and never registers the two INTERRUPTIBLE events.
    (If a hostile-unit mode is ever added, see the note above
    CastBarStatus:OnEnable in BFStatus.lua for the secret-value rule
    that has to come back with it.)
]]

local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

local CreateFrame        = CreateFrame
local UnitIsUnit         = UnitIsUnit
local UnitGroupRolesAssigned = UnitGroupRolesAssigned
local issecretvalue      = issecretvalue or function() return false end
local C_DurationUtil     = C_DurationUtil
local C_StringUtil       = C_StringUtil
local C_Timer            = C_Timer

-- oUF's fallback (Interface\ICONS\Trade_Engineering) -- castbar.lua:88.
local FALLBACK_ICON = 136243

local MAX_PIPS = 5   -- empowered casts cap at 4 stages today; 5 is headroom

-- ------------------------------------------------------------
-- Frame level, as an offset from the unit button's own level.
--
-- The relevant bands on a BF unit button:
--    +1 ..  +6   health bar, absorb / heal-prediction overlays, and the
--                shared aura SLOT-VISUAL band (dispel border/overlay,
--                frame-effect tints) which lifts to offset+1
--   +10 .. +14   frame border, aggro / dispel / target highlights
--  +216 .. +222  every text element, then role / leader / raid-target /
--                status icons
--  +223 .. +228  aura CONTAINERS (223, BigDef/CC 224), their BUTTONS
--                (224 / 225) and each button's cooldown, duration text
--                and glow (up to 228)
--         +250   RangeAlpha's out-of-range dimmer, which must stay on
--                top of everything -- never exceed +249 here
--
-- BELOW = 223 is the only value that is strictly above every text and
-- icon frame yet strictly below every visible aura icon (buttons start
-- at 224). It ties with the aura CONTAINERS, which draw nothing, and
-- with the legacy dispel-dot frame -- and the dispel dot is an aura
-- indicator, so losing to it is the right outcome anyway.
--
-- ABOVE = 230 clears the top of the aura band (228) with slack for
-- future aura sub-frames, and stays well under RangeAlpha.
local LEVEL_BELOW_AURAS = 223
local LEVEL_ABOVE_AURAS = 230

local CastBar = BF.indicatorPrototype:new("castBar")

-- Every layout pass is gated on indicator:GetFrame(frame). Because this
-- indicator's :Create is a no-op, that gate would never let :Layout run
-- and the lazy build could never happen. lazyCreate opts out of the gate.
-- See BF:ShouldLayoutIndicator in BFIndicator.lua.
CastBar.lazyCreate = true

-- ============================================================

local function PixelsToUI(n)
	if BF.PixelsToUI then return BF:PixelsToUI(n) end
	local pixelSize = 768 / select(2, GetPhysicalScreenSize())
	local uiScale = UIParent:GetEffectiveScale()
	local pixelMult = (uiScale > 0) and (pixelSize / uiScale) or 1
	return n * pixelMult
end

-- Park the bar and everything anchored to it. Also drops the per-cast
-- generation stamp so the next cast re-runs the full setup pass.
local function HideCastBar(bar)
	if bar._holdTimer then
		bar._holdTimer:Cancel()
		bar._holdTimer = nil
	end
	bar._gen = nil
	bar:Hide()
	if bar._iconFrame then bar._iconFrame:Hide() end
	if bar._textFrame then bar._textFrame:Hide() end
	local pips = bar._pips
	if pips then
		for i = 1, #pips do pips[i]:Hide() end
	end
end

-- ============================================================
-- Create / EnsureBuilt
--
-- Create is deliberately a NO-OP. The widgets are built lazily by
-- EnsureBuilt, called from Layout the first time the feature is actually
-- enabled for that frame's layout.
--
-- Why: a cast bar is 3 frames, ~10 textures, 2 font strings and a
-- duration binding. Building that eagerly in Create would cost every
-- user 40 frames' worth of it in a full raid whether or not they ever
-- turn the feature on, and the indicator prototype's CanCreate is
-- evaluated once at frame-init time so it cannot express "enabled later".
-- Frame and texture creation is not combat-protected, so building on the
-- first enable -- even mid-pull -- is safe.
-- ============================================================
function CastBar:Create(parent)
	-- Intentionally empty. See EnsureBuilt.
end

local function EnsureBuilt(self, parent)
	if parent[self.name] then return parent[self.name] end

	-- Frame level is stamped in Layout (see LEVEL_ABOVE / LEVEL_BELOW and
	-- the band map above them) because it is user-configurable and because
	-- SetParent resets levels. The value here is a placeholder only.
	local bar = BF.StatusBar(nil, parent)
	bar.indicator = self
	bar:EnableMouse(false)
	BF:DisablePixelSnapRegion(bar)
	bar:SetMinMaxValues(0, 1)
	bar:SetValue(0)
	bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
	bar:Hide()

	local fill = bar:GetStatusBarTexture()
	BF:DisablePixelSnapRegion(fill)

	-- Background: a plain BACKGROUND texture on the bar itself rather than
	-- PowerBar's separate bgFrame. One fewer frame per unit, and the cast
	-- bar has no fill/bg seam problem to solve because it is not driven by
	-- SetValue -- the engine owns the fill geometry.
	local bg = BF.Texture(bar, nil, "BACKGROUND")
	bg:SetAllPoints(bar)
	bg:SetColorTexture(0.08, 0.08, 0.08, 1)
	bar.bg = bg

	-- Square edge textures (cheap 1px border, matching Container's style).
	local edges = {}
	for _, k in ipairs({ "top", "bottom", "left", "right" }) do
		local t = BF.Texture(bar, nil, "OVERLAY", nil, 1)
		t:SetColorTexture(0, 0, 0, 1)
		t:Hide()
		edges[k] = t
	end
	bar._edges = edges

	-- Icon and text are children of the BAR, not of the unit button.
	--
	-- That is deliberate: the whole cast bar occupies ONE frame level, and
	-- a same-level child is guaranteed to draw above its parent, so icon
	-- and text sort above the bar's own textures without consuming levels
	-- and without depending on sibling creation order. This is the idiom
	-- already used by ContainerFactory's dbHost, DispelDebuffBorder's
	-- ringHost and Container's frameRoundHost.
	--
	-- It also means alpha cascades from the bar, so opacity is applied
	-- once rather than to three frames.
	--
	-- Frames are not clipped to their parent, so the icon sitting outside
	-- the bar's rect is fine.
	local iconFrame = CreateFrame("Frame", nil, bar)
	iconFrame:EnableMouse(false)
	iconFrame:Hide()
	local icon = BF.Texture(iconFrame, nil, "ARTWORK")
	icon:SetAllPoints(iconFrame)
	icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)   -- trim the stock icon border
	bar._iconFrame = iconFrame
	bar._icon = icon

	-- Text: same reasoning as the icon frame above. Created after it so
	-- that at equal level the text sorts above the icon.
	local textFrame = CreateFrame("Frame", nil, bar)
	textFrame:EnableMouse(false)
	textFrame:Hide()
	bar._textFrame = textFrame

	local function mkText(justify)
		local fs = textFrame:CreateFontString(nil, "OVERLAY")
		fs:SetFontObject(GameFontNormalSmall)
		local f, s, fl = fs:GetFont()
		fs.SF_defaultFont  = f  or BF.font or "Fonts\\FRIZQT__.TTF"
		fs.SF_defaultSize  = s  or 10
		fs.SF_defaultFlags = fl or ""
		fs:SetShadowOffset(1, -1)
		fs:SetShadowColor(0, 0, 0, 1)
		fs:SetJustifyH(justify)
		fs:SetWordWrap(false)
		return fs
	end
	bar._nameText = mkText("LEFT")
	bar._timeText = mkText("RIGHT")

	-- Engine-driven timer text. Created once; the formatter and the font
	-- string binding never change, only the duration object per cast.
	-- oUF castbar.lua:93-96 and :688-697.
	if C_DurationUtil and C_DurationUtil.CreateDurationTextBinding then
		local binding = C_DurationUtil.CreateDurationTextBinding()
		if C_StringUtil and C_StringUtil.CreateSecondsFormatter then
			local fmt = C_StringUtil.CreateSecondsFormatter()
			fmt:SetDefaultAbbreviation(Enum.SecondsFormatterAbbreviation.OneLetter)
			fmt:SetMinInterval(Enum.SecondsFormatterInterval.Seconds)
			fmt:SetMillisecondsThreshold(60)
			binding:SetFormatter(fmt)
		end
		binding:SetFontString(bar._timeText)
		binding:SetEnabled(true)
		bar._timeBinding = binding
	end

	-- Empower pips: plain textures, created lazily on the first empowered
	-- cast this frame ever shows. oUF uses CastingBarFrameStagePipTemplate
	-- frames; a pip is a two-pixel vertical line, so 40 raid frames' worth
	-- of templated frames buys nothing. Texture/frame creation is not
	-- combat-protected, so lazy creation mid-pull is safe.
	bar._pips = {}

	parent[self.name] = bar
	return bar
end

-- ============================================================
-- Layout -- all styling and anchoring. Config-time only.
-- ============================================================
function CastBar:Layout(parent)
	local cb = BF:GetSectionProfileForFrame("castBar", parent)
	if not cb then return end

	local bar = parent[self.name]

	-- Feature off for this frame's layout: nothing is built, and anything
	-- built by a previous layout is parked hidden.
	if not cb.enabled then
		if bar then
			bar._enabled = false
			HideCastBar(bar)
		end
		return
	end

	bar = bar or EnsureBuilt(self, parent)
	if not bar then return end

	-- ---- Frame level ---------------------------------------------------
	-- Re-stamped on every Layout, not just at build time, because SetParent
	-- resets frame levels. The icon and text frames are children of the bar
	-- at the bar's own level, so they follow it automatically -- a
	-- same-level child always draws above its parent.
	local lvl = (cb.frameLevel == "aboveAuras") and LEVEL_ABOVE_AURAS or LEVEL_BELOW_AURAS
	bar:SetFrameLevel(parent:GetFrameLevel() + lvl)

	local bp = BF:GetSectionProfileForFrame("borders", parent)

	local borderN  = BF:EffectiveBorderPixels(bp)
	local borderUI = PixelsToUI(borderN)

	-- ---- Geometry ------------------------------------------------------
	--
	-- The cast bar is ALWAYS an overlay and never reserves layout space.
	-- Three of the five anchors draw over the health area; the two
	-- "outside" ones float clear of the frame entirely. Either way nothing
	-- else moves when a cast starts or stops, so a cast costs zero layout
	-- work. (An earlier "row" placement that carved out its own strip was
	-- dropped -- see the note in Container:Layout.)
	--
	-- Anchors:
	--   TOP_INSIDE      top edge of the health area, drawn over it
	--   TOP_OUTSIDE     floating just above the frame
	--   CENTER          vertically centered on the health area
	--   BOTTOM_INSIDE   bottom edge of the health area, i.e. ABOVE the
	--                   power bar (the container's bottom already excludes
	--                   the power row -- Container:Layout insets it by
	--                   effectivePowerH -- so no power-bar maths is needed
	--                   here, and this stays correct when the power bar
	--                   shows or hides)
	--   BOTTOM_OUTSIDE  floating just below the frame, under everything
	--
	-- Frames are not clipped to their parent, so the two outside anchors
	-- render fine as children of the unit button.
	bar:ClearAllPoints()

	-- Content rect, inside the border.
	--
	-- Dimensions come from parent._bf_contentW/_bf_contentH, published by
	-- Container:Layout (which always runs first -- indicator order is .toc
	-- order and Container is registered before this one).
	--
	-- They must NOT be measured with GetWidth/GetHeight: on 12.1 those
	-- return SECRET numbers for the unit button and its children, and the
	-- clamp comparisons below would hard-error. The Incoming Casts module
	-- hit exactly that ("attempt to compare local 'barH' (a secret number
	-- value)"). Container derives them arithmetically from the header's
	-- frameWidth/frameHeight instead.
	local anchor = parent.container or parent
	local availH = parent._bf_contentH
	local availW = parent._bf_contentW
	local header = parent:GetParent()
	if not availH then
		availH = (header and header.frameHeight or 0) - borderUI * 2
	end
	if not availW then
		availW = (header and header.frameWidth or 0) - borderUI * 2
	end

	local pct = cb.overlayHeightPct or 0.35
	if pct < 0.05 then pct = 0.05 elseif pct > 1 then pct = 1 end
	local barH = availH * pct

	-- ---- Icon reserve --------------------------------------------------
	-- The icon hangs off one end of the bar, OUTSIDE it. Inset the bar's
	-- anchor on that side by the icon's width plus the gap, so bar + icon
	-- together span exactly the frame width instead of the icon spilling
	-- past the edge.
	--
	-- Icon size derives from barH, which is why this has to be computed
	-- here rather than down in the icon block -- the bar's own anchors
	-- depend on it. The icon block below reuses `iconSize`.
	local showIcon = cb.showIcon and true or false
	local iconSize, iconReserve = 0, 0
	if showIcon then
		local gapPx = BF:Scale(cb.iconGap or 2)
		iconSize = barH * (cb.iconSizePct or 1)
		if iconSize < 1 then iconSize = 1 end
		iconReserve = iconSize + gapPx

		-- Clamp: iconSizePct goes to 300%, and on a short wide frame an
		-- oversized icon could otherwise eat the whole bar and leave it
		-- zero or negative width. Cap the reserve at half the available
		-- width and shrink the ICON to match -- capping the reserve alone
		-- would make gap (= reserve - size) negative and overlap the bar.
		if availW > 0 and iconReserve > availW * 0.5 then
			iconReserve = availW * 0.5
			iconSize = iconReserve - gapPx
			if iconSize < 1 then iconSize = 1 end
		end
	end
	local onRight    = (cb.iconSide == "RIGHT")
	local leftInset  = (showIcon and not onRight) and iconReserve or 0
	local rightInset = (showIcon and onRight)     and iconReserve or 0

	local yOff  = BF:Scale(cb.overlayYOffset or 0)
	local point = cb.overlayAnchor or "BOTTOM_INSIDE"

	if point == "TOP_INSIDE" then
		bar:SetPoint("TOPLEFT",  anchor, "TOPLEFT",   leftInset, yOff)
		bar:SetPoint("TOPRIGHT", anchor, "TOPRIGHT", -rightInset, yOff)
	elseif point == "TOP_OUTSIDE" then
		-- Outside anchors span the FRAME's width, not the content rect's,
		-- so they line up with the frame edges rather than the border inset.
		bar:SetPoint("BOTTOMLEFT",  parent, "TOPLEFT",   leftInset, yOff)
		bar:SetPoint("BOTTOMRIGHT", parent, "TOPRIGHT", -rightInset, yOff)
	elseif point == "CENTER" then
		bar:SetPoint("LEFT",  anchor, "LEFT",   leftInset, yOff)
		bar:SetPoint("RIGHT", anchor, "RIGHT", -rightInset, yOff)
	elseif point == "BOTTOM_OUTSIDE" then
		bar:SetPoint("TOPLEFT",  parent, "BOTTOMLEFT",   leftInset, yOff)
		bar:SetPoint("TOPRIGHT", parent, "BOTTOMRIGHT", -rightInset, yOff)
	else -- BOTTOM_INSIDE
		bar:SetPoint("BOTTOMLEFT",  anchor, "BOTTOMLEFT",   leftInset, yOff)
		bar:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMRIGHT", -rightInset, yOff)
	end
	if barH and barH > 0 then bar:SetHeight(barH) end
	-- Cache the resulting bar width for PlacePips, which cannot measure it
	-- (secret on 12.1). The two OUTSIDE anchors span the frame's full
	-- width; the three inside ones span the content rect. Either way, minus
	-- whichever side the icon reserved.
	local outside = (point == "TOP_OUTSIDE" or point == "BOTTOM_OUTSIDE")
	local spanW = outside and (header and header.frameWidth or availW) or availW
	bar._bf_barW = spanW - leftInset - rightInset

	-- ---- Bar appearance ------------------------------------------------
	local tex = cb.useCustomTexture and BF:ResolveBarTexture(cb.texture)
	            or "Interface\\Buttons\\WHITE8X8"
	bar:SetStatusBarTexture(tex)
	local fill = bar:GetStatusBarTexture()
	if fill then BF:DisablePixelSnapRegion(fill) end

	local c = cb.color
	if c then bar:SetStatusBarColor(c.r, c.g, c.b) end
	-- Icon and text are children of the bar, so alpha cascades -- one call.
	-- Bar opacity is the alpha channel of the bar color (the standalone
	-- opacity slider was removed). Fall back to 1 when unset.
	bar:SetAlpha((c and c.a ~= nil) and c.a or 1)

	if bar.bg then
		local bgA = (cb.bgOpacity ~= nil) and cb.bgOpacity or 1
		local bgc = cb.useCustomBgColor and cb.bgColor
		if bgc then bar.bg:SetColorTexture(bgc.r, bgc.g, bgc.b, bgA)
		else        bar.bg:SetColorTexture(0.08, 0.08, 0.08, bgA) end
	end

	-- ---- Border --------------------------------------------------------
	-- Two mutually exclusive implementations, matching how the rest of the
	-- addon does borders:
	--   square         -- four 1px edge textures on the bar (below)
	--   rounded / thick-- the shared nine-sliced ring + mask kit, via
	--                     BF:ApplyUFBarRoundBorder
	--
	-- The rounded kit is the SAME helper the unit frame cast bar uses. It
	-- normally follows the unit frame border mode and color, so this call
	-- passes an explicit override so the raid cast bar obeys its OWN
	-- borderStyle / borderColor. It also masks the listed regions, which is
	-- what stops the fill and background showing square corners inside the
	-- ring.
	local style       = cb.borderStyle or "square"
	local roundedMode = BF.IsRoundedBorderStyle and BF.IsRoundedBorderStyle(style)
	local wantBorder  = cb.showBorder and true or false

	if BF.ApplyUFBarRoundBorder then
		local rounded = wantBorder and roundedMode and BF:ApplyUFBarRoundBorder(
			bar,
			{ bar:GetStatusBarTexture(), bar.bg },
			bar:GetFrameLevel(),
			nil, nil,
			{ mode = style, color = cb.borderColor }
		)
		if not rounded and bar._bfRoundKit then
			-- Not rounded (or border off): park the kit. Hidden mask means
			-- masking is off; the AddMaskTexture attachments stay for the
			-- next switch back, which is how the frame-level ring behaves too.
			bar._bfRoundKit.ring:Hide()
			bar._bfRoundKit.mask:Hide()
		end
	end

	local e = bar._edges
	if e then
		if wantBorder and not roundedMode then
			local ec = cb.borderColor or { r = 0, g = 0, b = 0 }
			local ea = (ec.a ~= nil) and ec.a or 1
			local w  = PixelsToUI(cb.borderThickness or 1)
			for _, t in pairs(e) do t:SetColorTexture(ec.r, ec.g, ec.b, ea) end
			e.top:ClearAllPoints()
			e.top:SetPoint("TOPLEFT", bar, "TOPLEFT")
			e.top:SetPoint("TOPRIGHT", bar, "TOPRIGHT")
			e.top:SetHeight(w)
			e.bottom:ClearAllPoints()
			e.bottom:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT")
			e.bottom:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT")
			e.bottom:SetHeight(w)
			e.left:ClearAllPoints()
			e.left:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, -w)
			e.left:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", 0, w)
			e.left:SetWidth(w)
			e.right:ClearAllPoints()
			e.right:SetPoint("TOPRIGHT", bar, "TOPRIGHT", 0, -w)
			e.right:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", 0, w)
			e.right:SetWidth(w)
			for _, t in pairs(e) do t:Show() end
		else
			for _, t in pairs(e) do t:Hide() end
		end
	end

	-- ---- Icon ----------------------------------------------------------
	local iconFrame = bar._iconFrame
	if iconFrame then
		bar._showIcon = showIcon
		if showIcon then
			-- iconSize was computed above, before the bar's anchors, because
			-- the bar insets itself by this width. Do NOT recompute it from
			-- bar:GetHeight() here -- the two must agree or the icon will
			-- not fill the space the bar gave up.
			local gap = iconReserve - iconSize
			local xo  = BF:Scale(cb.iconXOffset or 0)
			local yo  = BF:Scale(cb.iconYOffset or 0)
			iconFrame:ClearAllPoints()
			iconFrame:SetSize(iconSize, iconSize)
			-- Anchored across the gap to the bar's outer edge, so the pair
			-- ends flush with the frame edge.
			if onRight then
				iconFrame:SetPoint("LEFT", bar, "RIGHT", gap + xo, yo)
			else
				iconFrame:SetPoint("RIGHT", bar, "LEFT", -gap + xo, yo)
			end
			-- The icon takes the same border style and color as the bar,
			-- via the shared kit in PixelPerfect.lua (same art the aura
			-- icons and the unit frame cast bar's icon use).
			if BF.ApplyIconBorder then
				BF:ApplyIconBorder(iconFrame, bar._icon, style, cb.borderColor,
				                   cb.borderThickness, wantBorder)
			end
		end
	end

	-- ---- Text ----------------------------------------------------------
	local nameFS, timeFS = bar._nameText, bar._timeText
	local pad = PixelsToUI(2)
	if nameFS then
		bar._showName = cb.showSpellName and true or false
		nameFS:SetFont(BF:ResolveFontPath(cb.nameFont) or nameFS.SF_defaultFont,
		               cb.nameFontSize or 9, cb.nameFontBorder or "")
		nameFS:SetJustifyH(cb.nameAlign or "LEFT")
		nameFS:ClearAllPoints()
		nameFS:SetPoint("LEFT",  bar, "LEFT",   pad, 0)
		nameFS:SetPoint("RIGHT", bar, "RIGHT", -pad, 0)
		local tc = cb.nameColor or { r = 1, g = 1, b = 1 }
		nameFS:SetTextColor(tc.r, tc.g, tc.b, tc.a or 1)
	end
	if timeFS then
		bar._showTimer = cb.showTimer and true or false
		timeFS:SetFont(BF:ResolveFontPath(cb.timerFont) or timeFS.SF_defaultFont,
		               cb.timerFontSize or 9, cb.timerFontBorder or "")
		timeFS:SetJustifyH(cb.timerAlign or "RIGHT")
		timeFS:ClearAllPoints()
		timeFS:SetPoint("LEFT",  bar, "LEFT",   pad, 0)
		timeFS:SetPoint("RIGHT", bar, "RIGHT", -pad, 0)
		local tc = cb.timerColor or { r = 1, g = 1, b = 1 }
		timeFS:SetTextColor(tc.r, tc.g, tc.b, tc.a or 1)
	end

	-- ---- Pips ----------------------------------------------------------
	bar._showPips  = cb.showEmpowerPips and true or false
	bar._pipColor  = cb.pipColor
	bar._pipWidth  = PixelsToUI(cb.pipWidth or 1)
	for i = 1, #bar._pips do
		local p = bar._pips[i]
		if bar._pipColor then
			p:SetColorTexture(bar._pipColor.r, bar._pipColor.g, bar._pipColor.b, bar._pipColor.a or 1)
		end
		p:SetWidth(bar._pipWidth)
	end

	-- Cached filters, so Update never touches the profile for them.
	bar._enabled      = true
	bar._showPlayer   = cb.showPlayer ~= false
	bar._showPets     = cb.showPets and true or false
	bar._healersOnly  = cb.healersOnly and true or false
	bar._holdTime     = cb.holdTime or 0.5

	-- ---- Options preview -----------------------------------------------
	-- Preview frames never get a unit, so the status fan-out never reaches
	-- them and Update never runs. Draw a static sample here instead so the
	-- Cast Bar tab's preview is not permanently blank while the user is
	-- tuning size, colors and position. SetValue (rather than
	-- SetTimerDuration) because there is no real cast to time.
	if parent._isPreviewFrame then
		-- Context gate for previews. The live gate lives in
		-- BF:RebindCastBarStatus (which governs event registration, not the
		-- static preview draw), so it has to be mirrored here for the sample
		-- to match what the frame will actually do in game.
		--
		--   partyOnly : a preview represents a specific layout, and a
		--               RAID-type preview stands for a raid context where the
		--               feature is off. Hide the sample there. Party-type
		--               previews are unaffected. The previewed flat's type is
		--               read from parent._flatID (the same id
		--               GetSectionProfileForFrame resolves preview sections
		--               through); a CFG preview never reaches here because CFG
		--               cast bars are force-disabled.
		--   pvpOnly   : a live-instance condition a preview cannot represent
		--               (a preview is never inside an arena / battleground),
		--               so it is deliberately IGNORED for previews -- owner
		--               decision -- otherwise the sample would vanish while
		--               the user is tuning appearance.
		if cb.partyOnly then
			local lp   = BF.rpDB and BF.rpDB.profile and BF.rpDB.profile.layouts
			local fl   = lp and lp.flatLayouts
			local flat = (parent._flatID and fl) and fl[parent._flatID] or nil
			if flat and flat.type == "raid" then
				bar._enabled = false
				HideCastBar(bar)
				return
			end
		end
		bar:SetMinMaxValues(0, 1)
		bar:SetValue(0.62)
		if bar._showIcon and bar._iconFrame then
			bar._icon:SetTexture(FALLBACK_ICON)
			bar._iconFrame:Show()
		elseif bar._iconFrame then
			bar._iconFrame:Hide()
		end
		if bar._nameText then
			if bar._showName then bar._nameText:SetText("Cast Bar") bar._nameText:Show()
			else bar._nameText:SetText("") bar._nameText:Hide() end
		end
		if bar._timeText then
			-- The duration binding owns this font string on live frames;
			-- disable it so a literal sample string survives.
			if bar._timeBinding then bar._timeBinding:SetEnabled(false) end
			if bar._showTimer then bar._timeText:SetText("1.4") bar._timeText:Show()
			else bar._timeText:SetText("") bar._timeText:Hide() end
		end
		if bar._textFrame then bar._textFrame:Show() end
		bar:Show()
		bar._gen = nil
		return
	end

	-- Live frame: make sure the engine-driven timer text owns the font
	-- string. (Symmetry with the preview branch above, which disables it to
	-- write a literal sample. Live and preview frames are distinct objects,
	-- so this is belt-and-braces rather than a required handoff.)
	if bar._timeBinding then bar._timeBinding:SetEnabled(true) end

	-- Drop the per-cast generation stamp.
	--
	-- Update's expensive setup (icon texture, spell name, show/hide of the
	-- icon/name/timer/pips) is guarded by `bar._gen ~= s.generation` so that
	-- a DELAYED / CHANNEL_UPDATE storm cannot redo it on every tick. But the
	-- SAME block is what applies the _showIcon / _showName / _showTimer /
	-- _showPips flags this function just recomputed -- so without clearing
	-- the stamp, toggling "Show Spell Icon" mid-cast would appear to do
	-- nothing until the caster started a new spell.
	bar._gen = nil
end

-- ============================================================
-- Helpers used by Update
-- ============================================================
local function GetPip(bar, i)
	local p = bar._pips[i]
	if not p then
		p = BF.Texture(bar, nil, "OVERLAY", nil, 3)
		local c = bar._pipColor
		if c then p:SetColorTexture(c.r, c.g, c.b, c.a or 1)
		else      p:SetColorTexture(1, 1, 1, 0.8) end
		p:SetWidth(bar._pipWidth or 1)
		bar._pips[i] = p
	end
	return p
end

-- UnitEmpoweredStagePercentages returns PER-STAGE fractions of the bar,
-- not cumulative offsets -- hence the running total. It can also return
-- nil, which stock oUF does not guard (see the UpdatePips override in
-- UnitFrames/oUF_Castbar.lua); the caller checks before we get here.
--
-- Iteration is a numeric loop, deliberately NOT `for k,v in next, stages`
-- as oUF does at castbar.lua:113. Because the offset accumulates,
-- unordered iteration produces wrong pip positions whenever the table's
-- hash part is reached.
local function PlacePips(bar, stages)
	-- Bar width is CACHED by Layout, not measured. bar:GetWidth() returns a
	-- SECRET number on 12.1 (the bar is a child of the unit button), and
	-- the `w <= 0` guard plus the offset arithmetic below would hard-error
	-- on it.
	local w = bar._bf_barW or 0
	if w <= 0 then return end
	local n = #stages
	if n > MAX_PIPS then n = MAX_PIPS end
	local offset = 0
	for i = 1, n do
		local frac = stages[i]
		offset = offset + w * (frac ~= nil and frac or 0)
		local p = GetPip(bar, i)
		p:ClearAllPoints()
		p:SetPoint("TOP",    bar, "TOPLEFT",    offset, 0)
		p:SetPoint("BOTTOM", bar, "BOTTOMLEFT", offset, 0)
		p:Show()
	end
	for i = n + 1, #bar._pips do bar._pips[i]:Hide() end
end

-- ============================================================
-- Update -- per cast event. Hot path.
-- ============================================================
function CastBar:Update(parent, unit)
	local bar = parent[self.name]
	if not bar then return end

	-- Layout has not run yet, or the feature is off for this frame's layout.
	if not bar._enabled then
		if bar:IsShown() then HideCastBar(bar) end
		return
	end

	local status = BF.statuses and BF.statuses.castbar
	local s = status and status:GetState(unit)
	if not s then
		if bar:IsShown() then HideCastBar(bar) end
		return
	end

	-- Cast ended. `failed` means interrupted/failed: linger briefly so the
	-- interrupt is actually visible, then hide. A one-shot C_Timer, not an
	-- OnUpdate countdown.
	if not s.active then
		-- A linger is already running. Leave it alone: this indicator is
		-- also bound to `offline` and `death`, so an unrelated event
		-- arriving mid-hold would otherwise fall through and cut the
		-- interrupt flash short.
		if bar._holdTimer then return end
		if s.failed and bar:IsShown() then
			local hold = bar._holdTime or 0.5
			if hold > 0 then
				bar._holdTimer = C_Timer.NewTimer(hold, function()
					bar._holdTimer = nil
					HideCastBar(bar)
				end)
				return
			end
		end
		if bar:IsShown() then HideCastBar(bar) end
		return
	end

	-- ---- Dead / disconnected --------------------------------------------
	-- This indicator is also bound to the `offline` and `death` statuses,
	-- because neither event reliably produces a UNIT_SPELLCAST_STOP. Without
	-- this check the cast state stays `active` and the bar sits frozen on a
	-- corpse or a disconnected player. Both statuses already do their own
	-- secret-value guarding internally (Death:IsActive treats an unreadable
	-- UnitIsDeadOrGhost as not-dead), so we just ask them.
	local statuses = BF.statuses
	local offlineS, deathS = statuses.offline, statuses.death
	if (offlineS and offlineS:IsActive(unit)) or (deathS and deathS:IsActive(unit)) then
		if bar:IsShown() then HideCastBar(bar) end
		return
	end

	-- ---- Visibility filters (all resolved at Layout time) --------------
	local header = parent:GetParent()
	if header and header.isPetFrame and not bar._showPets then
		if bar:IsShown() then HideCastBar(bar) end
		return
	end
	if not bar._showPlayer and UnitIsUnit(unit, "player") then
		if bar:IsShown() then HideCastBar(bar) end
		return
	end
	-- Healers-only filter. UnitGroupRolesAssigned returns a SECRET value for
	-- secret-identity units on 12.1 (branching on a secret hard-errors), so
	-- guard it; an unreadable role counts as "not a healer" and hides the
	-- bar -- the safe fallback for a whitelist filter. Fires only on cast
	-- events, not per render frame, matching the other filters here.
	if bar._healersOnly then
		local role = UnitGroupRolesAssigned(unit)
		if issecretvalue(role) or role ~= "HEALER" then
			if bar:IsShown() then HideCastBar(bar) end
			return
		end
	end

	-- ---- Per-cast setup, guarded so DELAYED / CHANNEL_UPDATE storms do
	-- ---- not redo icon, text and pip work on every tick.
	if bar._gen ~= s.generation then
		bar._gen = s.generation
		if bar._holdTimer then
			bar._holdTimer:Cancel()
			bar._holdTimer = nil
		end

		if bar._showIcon and bar._iconFrame then
			-- `~= nil` rather than `or`: texture comes off the same info
			-- call as the secret returns, and truth-testing a secret
			-- hard-errors. A nil-check is the only safe form.
			bar._icon:SetTexture(s.texture ~= nil and s.texture or FALLBACK_ICON)
			bar._iconFrame:Show()
		elseif bar._iconFrame then
			bar._iconFrame:Hide()
		end

		if bar._showName and bar._nameText then
			bar._nameText:SetText(s.displayName)
			bar._nameText:Show()
		elseif bar._nameText then
			bar._nameText:SetText("")
			bar._nameText:Hide()
		end
		if bar._timeText then
			if bar._showTimer then bar._timeText:Show() else bar._timeText:Hide() end
		end
		if bar._textFrame then bar._textFrame:Show() end

		-- Empower pips are placed once at cast start. There is no API for
		-- the CURRENT stage on 12.1 (oUF's PostUpdateStage is commented
		-- out upstream as unobtainable), so they never need re-placing.
		if bar._showPips and s.isEmpowered and s.stages then
			PlacePips(bar, s.stages)
		else
			local pips = bar._pips
			for i = 1, #pips do pips[i]:Hide() end
		end
	end

	-- ---- Timer: re-applied on every event, because DELAYED /
	-- ---- CHANNEL_UPDATE / EMPOWER_UPDATE replace the duration object.
	-- `~= nil`, not a truth-test: the duration object rides alongside the
	-- secret returns of the info calls (see ReadCast in BFStatus.lua).
	if s.duration ~= nil then
		bar:SetMinMaxValues(0, 1)
		bar:SetTimerDuration(s.duration, Enum.StatusBarInterpolation.Immediate, s.direction)
		if bar._timeBinding then bar._timeBinding:SetDuration(s.duration) end
	end

	bar:Show()
end

-- ============================================================
-- Disable / Release
-- ============================================================
function CastBar:Disable(parent)
	local bar = parent[self.name]
	if bar then HideCastBar(bar) end
end

BF:RegisterIndicator(CastBar)
