-- ============================================================
-- BuzzardFrames: oUF_AltPowerBar.lua
-- Standalone detachable alt power bar for the oUF player frame.
-- Shows mana for Druids in shapeshift form (cat/bear/moonkin).
-- Which specs activate the bar is controlled by altPowerBarDruidSpecs.
-- Modeled on oUF_DetachedPowerBar.lua's architecture.
--
-- Attached: sits on the oUF player frame above the power bar.
-- Detached: shown as an independent, draggable StatusBar
--           re-parented to UIParent.
-- ============================================================
local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

local format = string.format
local UnitPower = UnitPower
local UnitPowerMax = UnitPowerMax
local UnitPowerType = UnitPowerType
local UnitPowerPercent = UnitPowerPercent
local UnitExists = UnitExists

-- v86 (event refactor stage 2): this file's event owner, created at load so
-- it exists exactly once regardless of when the bar is built. Subscriptions
-- live in BF:BuildOUFAltPowerBar.
BF.oufAltPowerBarEvents = BF:EventOwner("oufAltPowerBar")

-- Single handler. BFEvents normalizes the shape to (owner, event, ...).
local function UpdateAltPowerBar(_, event)
    -- v92: UpdateOUFAltPowerBar runs the geometry pass itself on an
    -- active-state EDGE (form picked up / dropped the strip). Flag it so the
    -- UNIT_DISPLAYPOWER branch below doesn't run the same full pass a second
    -- time in the same event (icon-inset chord math, bar re-anchors, border
    -- kit walk, absorb relayout — twice per shapeshift for cat-weavers).
    BF._altEdgeGeomRan = nil
    BF:UpdateOUFAltPowerBar()
    if not BF.oufPlayer then return end
    if event == "PLAYER_SPECIALIZATION_CHANGED" then
        -- A spec change can change what is RESERVED (a spec with the bar
        -- toggled off reserves nothing), so the frame's height really does
        -- move and the full, protected layout is required. Specs cannot be
        -- changed in combat, so RunSecure never has to swallow this one.
        BF:ApplyOUFPlayerLayout()
    elseif event == "UNIT_DISPLAYPOWER" then
        -- A FORM change. v91: this no longer alters the frame's height -- the
        -- strip is already reserved -- so it needs only the unprotected half,
        -- which is legal in combat. Calling ApplyOUFPlayerLayout here was the
        -- bug: RunSecure swallowed it for the whole fight while
        -- UpdateOUFAltPowerBar above went ahead and resized the bar anyway.
        -- v92: skip when the edge inside UpdateOUFAltPowerBar just ran it.
        if not BF._altEdgeGeomRan then
            BF:ApplyOUFPlayerBarGeometry()
        end
    end
end

-- ============================================================
-- BUILD
-- ============================================================
function BF:BuildOUFAltPowerBar()
    if self.oufAltPowerBar then return end

    local f = self.oufPlayer or UIParent
    local mb = BF.StatusBar("BuzzardFrames_oUFAltPowerBar", f)
    mb:SetFrameLevel(f:GetFrameLevel() + 3)
    mb:SetFrameStrata("MEDIUM")
    mb:EnableMouse(false)
    mb:SetMovable(true)
    mb:SetClampedToScreen(true)
    mb:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    mb:SetStatusBarColor(0.00, 0.44, 1.00)
    mb:Hide()

    -- Background
    local bg = BF.Texture(mb, nil, "BACKGROUND", nil, -1)
    bg:SetAllPoints(mb)
    bg:SetColorTexture(0, 0, 0.15, 0.8)
    mb._bg = bg

    -- Border (4-edge box)
    local border = CreateFrame("Frame", nil, mb)
    border:SetAllPoints(mb)
    border:SetFrameLevel(mb:GetFrameLevel() + 3)
    border:EnableMouse(false)
    border:Hide()
    local function MakeEdge()
        local t = BF.Texture(border, nil, "OVERLAY", nil, 3)
        t:SetColorTexture(0, 0, 0, 1)
        return t
    end
    border.top    = MakeEdge()
    border.bottom = MakeEdge()
    border.left   = MakeEdge()
    border.right  = MakeEdge()
    mb._border = border

    -- Text overlay frame
    -- v90.9: +7, not +5. Attached, this bar sits at player+3, so +5 put
    -- the text at player+8 — the exact level the per-bar rounded kits
    -- resolve to, and the POWER slot's kit rect overlaps this bar's
    -- bottom band width (shared-edge overlap). A tie there is broken by
    -- creation order, so the border could take the text. +7 clears it,
    -- matching the unit frame's own text level (player+10).
    local textFrame = CreateFrame("Frame", nil, mb)
    textFrame:SetAllPoints(mb)
    textFrame:SetFrameLevel(mb:GetFrameLevel() + 7)
    textFrame:EnableMouse(false)

    local pctText = textFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pctText:SetTextColor(1, 1, 1, 1)
    pctText:SetPoint("RIGHT", mb, "RIGHT", -3, 0)
    pctText:SetJustifyH("RIGHT")
    mb._pctText = pctText

    local valText = textFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    valText:SetTextColor(1, 1, 1, 1)
    valText:SetPoint("LEFT", mb, "LEFT", 3, 0)
    valText:SetJustifyH("LEFT")
    mb._valText = valText

    -- Drag handle
    local handle = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    handle:SetFrameStrata("MEDIUM")
    handle:SetFrameLevel(110)
    handle:SetBackdrop({ bgFile="Interface\\Buttons\\White8x8",
                         edgeFile="Interface\\Buttons\\White8x8", edgeSize=1 })
    handle:SetBackdropColor(0.1, 0.3, 0.6, 0.8)
    handle:SetBackdropBorderColor(0.2, 0.5, 0.9, 1)
    handle:EnableMouse(true)
    handle:SetMovable(false)
    handle:RegisterForDrag("LeftButton")
    local lbl = handle:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lbl:SetPoint("CENTER")
    lbl:SetText("Alt Power Bar")
    lbl:SetTextColor(1, 1, 1)
    handle:SetScript("OnDragStart", function() mb:StartMoving() end)
    handle:SetScript("OnDragStop", function()
        mb:StopMovingOrSizing()
        local x, y   = mb:GetCenter()
        local ux, uy = UIParent:GetCenter()
        BF:SetUFAnchor("playerAltPowerBar", x - ux, y - uy)
        BF:_SnapOUFAltPowerBarHandle()
    end)
    handle:Hide()
    mb._handle = handle

    self.oufAltPowerBar = mb

    -- Event driver.
    --
    -- v86 (event refactor stage 2): was a private CreateFrame with a
    -- hand-written unit guard. PLAYER_SPECIALIZATION_CHANGED carries a unit
    -- and fires once per GROUP MEMBER, so unfiltered it ran
    -- ApplyOUFPlayerLayout ~20 times per raid join for other people's specs
    -- (27 calls / 50 ms measured). Now declared as scope "player" and
    -- filtered by the engine, alongside the three UNIT_* events that already
    -- were. See the owner and handler at the top of this file.
    BF.oufAltPowerBarEvents:Sub("PLAYER_ENTERING_WORLD",         UpdateAltPowerBar, "unitless")
    BF.oufAltPowerBarEvents:Sub("PLAYER_SPECIALIZATION_CHANGED", UpdateAltPowerBar, "player")
    -- PERF: the bar is druid-only (druid mana while shapeshifted), and class
    -- is session-static — non-druids never activate it, so they don't pay
    -- the 10-20x/sec UNIT_POWER_FREQUENT handler (or the vehicle-transition
    -- UNIT_DISPLAYPOWER geometry pass) at all. PEW + spec stay subscribed
    -- for everyone: they run the cheap collapse pass and the layout hooks.
    do
        local _, playerClass = UnitClass("player")
        if playerClass == "DRUID" then
            BF.oufAltPowerBarEvents:Sub("UNIT_POWER_FREQUENT", UpdateAltPowerBar, "player")
            BF.oufAltPowerBarEvents:Sub("UNIT_DISPLAYPOWER",   UpdateAltPowerBar, "player")
            BF.oufAltPowerBarEvents:Sub("UNIT_MAXPOWER",       UpdateAltPowerBar, "player")
        end
    end

    self:ApplyOUFAltPowerBarLayout()
end

-- ============================================================
-- QUERY: is the alt bar currently active?
-- Returns true if the bar is enabled, attached, and the druid
-- is in a shapeshift form with the current spec toggled on.
-- ============================================================
local DRUID_SPEC_KEYS = { [1] = "balance", [2] = "feral", [3] = "guardian", [4] = "restoration" }

-- ELIGIBLE = everything except "is the player actually in a form right now".
-- The distinction is the whole of the v91 sizing model: the space the bar will
-- need is reserved from the health bar whenever the bar COULD appear, so that
-- entering a form costs no layout change at all. ACTIVE (below) is eligible
-- plus in-form, and drives what is drawn.
function BF:IsAltPowerBarEligible()
    local p = self.ufDB.profile
    if not p.showAltPowerBar then return false end
    if p.altPowerBarDetached then return false end
    local _, playerClass = UnitClass("player")
    if playerClass ~= "DRUID" then return false end
    local specIdx = GetSpecialization()
    local specKey = specIdx and DRUID_SPEC_KEYS[specIdx]
    local druidSpecs = p.altPowerBarDruidSpecs
    return (specKey and druidSpecs and druidSpecs[specKey]) and true or false
end

function BF:IsAltPowerBarActive()
    if not self:IsAltPowerBarEligible() then return false end
    if UnitPowerType("player") == 0 then return false end -- mana is primary, no form
    return true
end

-- ============================================================
-- QUERY: effective height for frame sizing
-- Returns altH when the bar is active on the player frame,
-- 0 otherwise.
-- ============================================================
function BF:GetAltPowerBarEffectiveHeight()
    if not self:IsAltPowerBarActive() then return 0 end
    return self.ufDB.profile.altPowerBarHeight or 3
end

-- ============================================================
-- v91: RESERVED HEIGHT, and the health band it widens.
--
-- Reserved is the space the alt bar will occupy WHEN the player shifts --
-- claimed whether or not they currently have. It is the eligible height, not
-- the active one, and it is what makes a form change free: the strip already
-- exists, so shifting only decides who draws in it.
--
-- The health bar's configured height is then AUTO-INCREASED by that amount
-- rather than being eaten into. In form, the health bar renders at exactly
-- the height the user configured and the alt bar sits in the added strip; out
-- of form the health bar simply fills the strip as well. So the setting means
-- "how tall is my health bar" in the state that matters, and a druid does not
-- have to keep a different number there from every other class.
--
-- Non-druids, a spec with the bar toggled off, the bar disabled, or the bar
-- detached all reserve nothing, and their frames are byte-identical to before.
-- ============================================================
function BF:GetAltPowerBarReservedHeight()
    if not self:IsAltPowerBarEligible() then return 0 end
    return self.ufDB.profile.altPowerBarHeight or 3
end

-- The full health band: what the frame allots between the name bar and the
-- power bar. Single source of truth -- the frame height, the health bar's
-- drawn rect, the alt bar's anchor, the power bar's offset and the chord
-- insets are all derived from this one number, so they cannot drift.
function BF:GetOUFPlayerHealthBandHeight()
    local pf = self.ufDB.profile.player or {}
    return (pf.healthBarHeight or 22) + self:GetAltPowerBarReservedHeight()
end

-- What the health bar actually DRAWS: the band minus whatever the alt bar is
-- occupying right now. In form that is the user's configured height; out of
-- form it is the whole band. Floored at 1 so an alt height configured taller
-- than the health bar cannot invert the rect.
function BF:GetOUFPlayerHealthDrawnHeight()
    return math.max(1, self:GetOUFPlayerHealthBandHeight()
        - self:GetAltPowerBarEffectiveHeight())
end

-- ============================================================
-- HANDLE SNAP
-- ============================================================
function BF:_SnapOUFAltPowerBarHandle()
    local mb = self.oufAltPowerBar
    if not mb or not mb._handle then return end
    local handle = mb._handle
    handle:ClearAllPoints()
    handle:SetPoint("BOTTOMLEFT", mb, "TOPLEFT", 0, 2)
    if self.db and self.db.global and self.db.global.tinyHandle then
        handle:SetWidth(5)
        handle:SetHeight(5)
    else
        local w = mb:GetWidth()
        if not w or w <= 0 then w = 80 end
        handle:SetWidth(w)
        handle:SetHeight(14)
    end
end

-- ============================================================
-- SLOT BORDER HAND-OFF (v90.10)
-- The attached bar's rounded ring is a SLOT in the player frame's
-- per-bar border pass (_ApplyOUFPerBarRoundBorders) rather than a kit
-- on this bar, and that pass resolves the slot from
-- IsAltPowerBarActive plus the bar's attach state. Anything that flips
-- either has to re-run the pass, or the slot keeps the ring it had
-- before the flip — a stale ring that, because the slot rect anchors
-- to this bar, would follow it to its detached screen position.
--
-- Coalesced onto the next frame rather than run inline, for two
-- reasons. ApplyOUFPlayerLayout lays this bar out BEFORE the power bar,
-- so an inline pass would compute every slot against power geometry
-- that has not been re-anchored yet and then be redone by the layout's
-- own border pass — two full passes per layout, the first one wrong.
-- And a form swap can fire several of these in one frame. Deferring
-- collapses them to exactly one pass, always after whatever layout is
-- in flight has finished. Nothing here is protected, so it is
-- combat-safe.
-- ============================================================
local altSlotRefreshQueued = false
local function RefreshAltSlotBorder()
    if altSlotRefreshQueued then return end
    if not BF.oufPlayer then return end
    if not BF:IsOUFRounded() then return end
    local p = BF.ufDB and BF.ufDB.profile
    if not p or p.oufRoundedSeparators ~= true then return end
    if (p.oufSeparatorStyle or "rings") == "lines" then return end
    altSlotRefreshQueued = true
    C_Timer.After(0, function()
        altSlotRefreshQueued = false
        local pf = BF.oufPlayer
        if pf and BF._ApplyOUFFrameBorder then BF:_ApplyOUFFrameBorder(pf) end
    end)
end

-- ============================================================
-- BORDER
-- ============================================================
function BF:_ApplyOUFAltPowerBarBorder()
    local mb = self.oufAltPowerBar
    if not mb or not mb._border then return end
    local p = self.ufDB.profile
    local bbf = mb._border

    -- Rounded border mode (v59):
    --   Attached — the bar sits INSIDE the player frame's composite
    --   ring (interior separators are gone in rounded, matching the
    --   raid look), so no box and no own ring; its fill/bg subscribe to
    --   the composite mask in ApplyOUFAltPowerBarLayout.
    --   Detached — standalone ring+mask kit (same Frame* art). Level +2
    --   matches the square border level stamped below.
    -- v90: both rounded kit paths below honor powerBorderEnabled — the
    -- SAME key that gates the square box — so the Global Styles Enable
    -- Border toggle (which writes it) hides the rounded borders too.
    local roundedBorderOff = BF:IsOUFRounded() and p.powerBorderEnabled ~= true
    if p.altPowerBarDetached then
        if roundedBorderOff then
            local kit = mb._bfRoundKit
            if kit then kit.ring:Hide(); kit.mask:Hide() end
            bbf:Hide()
            return
        end
        if BF:ApplyUFBarRoundBorder(mb,
            { mb:GetStatusBarTexture(), mb._bg }, mb:GetFrameLevel() + 2) then
            bbf:Hide()
            -- v90.10: detaching does not go through the player frame's
            -- border pass on its own, and the "alt" slot's rect is
            -- anchored to THIS bar — so without a refresh the slot's
            -- ring would travel to the detached bar's new position and
            -- draw a second outline around it.
            RefreshAltSlotBorder()
            return
        end
    else
        -- Per-bar borders (v65, oufRoundedSeparators): the attached bar
        -- gets a kit like every other bar slot.
        -- v90.10: that kit is now built by _ApplyOUFPerBarRoundBorders
        -- on an ext rect, exactly like the name/health/power slots,
        -- instead of on this bar frame — see the "alt" slot there.
        -- Building it here made this the only bar without the chord
        -- extension, the clip's flat cut at the icon side, or the ext
        -- rect's shared-edge overlap, which is why it looked unlike the
        -- power bar at the same height. All this branch does now is
        -- retire the bar's own kit and hand the pass off to the frame
        -- border, which owns every per-bar ring.
        if BF:IsOUFRounded() and not roundedBorderOff
            and p.oufRoundedSeparators == true
            and (p.oufSeparatorStyle or "rings") ~= "lines" then
            local ownKit = mb._bfRoundKit
            if ownKit then ownKit.ring:Hide(); ownKit.mask:Hide() end
            bbf:Hide()
            RefreshAltSlotBorder()
            return
        end
        local kit = mb._bfRoundKit
        if kit then kit.ring:Hide(); kit.mask:Hide() end
        if BF:IsOUFRounded() then
            -- Keep the "lines" separator style in sync with alt-bar
            -- attach/visibility transitions (druid form swaps): the
            -- alt top line only exists while the bar is attached and
            -- shown (the applier self-hides otherwise).
            if self.oufPlayer and self._ApplyOUFSeparatorLines then
                self:_ApplyOUFSeparatorLines(self.oufPlayer)
            end
            bbf:Hide()
            return
        end
    end

    local show = p.powerBorderEnabled == true
    if not show then
        bbf:Hide()
        return
    end

    BF:RefreshPixelSize()

    bbf:SetFrameLevel(mb:GetFrameLevel() + 2)
    local thick = BF:PixelsToUI(p.powerBorderThickness or 1)
    -- Compensate for the frame's own scale so borders don't shrink
    -- below 1 physical pixel on scaled-down frames.
    local fScale = mb:GetEffectiveScale() / UIParent:GetEffectiveScale()
    if fScale > 0 and fScale < 1 then
        thick = thick / fScale
    end
    -- Enforce a minimum of 1 physical pixel.
    local minThick = BF:PixelsToUI(1)
    if fScale > 0 and fScale < 1 then minThick = minThick / fScale end
    if thick < minThick then thick = minThick end
    local bc    = p.powerBorderColor or { r=0, g=0, b=0, a=1 }
    local r, g, b, a = bc.r or 0, bc.g or 0, bc.b or 0, bc.a or 1

    -- Border always follows the alt power bar itself (mb), whether
    -- attached or detached. The bar's own anchors determine position.
    bbf:ClearAllPoints()
    bbf:SetAllPoints(mb)

    bbf.top:SetColorTexture(r, g, b, a)
    bbf.top:ClearAllPoints()
    bbf.top:SetPoint("TOPLEFT",  bbf, "TOPLEFT",  0, 0)
    bbf.top:SetPoint("TOPRIGHT", bbf, "TOPRIGHT", 0, 0)
    bbf.top:SetHeight(thick)

    bbf.bottom:SetColorTexture(r, g, b, a)
    bbf.bottom:ClearAllPoints()
    bbf.bottom:SetPoint("BOTTOMLEFT",  bbf, "BOTTOMLEFT",  0, 0)
    bbf.bottom:SetPoint("BOTTOMRIGHT", bbf, "BOTTOMRIGHT", 0, 0)
    bbf.bottom:SetHeight(thick)

    bbf.left:SetColorTexture(r, g, b, a)
    bbf.left:ClearAllPoints()
    bbf.left:SetPoint("TOPLEFT",    bbf, "TOPLEFT",    0, 0)
    bbf.left:SetPoint("BOTTOMLEFT", bbf, "BOTTOMLEFT", 0, 0)
    bbf.left:SetWidth(thick)

    bbf.right:SetColorTexture(r, g, b, a)
    bbf.right:ClearAllPoints()
    bbf.right:SetPoint("TOPRIGHT",    bbf, "TOPRIGHT",    0, 0)
    bbf.right:SetPoint("BOTTOMRIGHT", bbf, "BOTTOMRIGHT", 0, 0)
    bbf.right:SetWidth(thick)

    bbf:Show()

    -- Edge deduplication is handled by _ApplyOUFFrameBorder on the player
    -- frame: it suppresses the health bar's bottom edge and the power bar's
    -- top edge when the alt bar border is visible.  The alt bar keeps all 4
    -- of its own edges so there are no gaps.
end

-- ============================================================
-- TEXT STYLING — SHARED BY BOTH MODES
--
-- This used to live inline at the tail of ApplyOUFAltPowerBarLayout, which
-- the ATTACHED branch returns from ~80 lines earlier. Two consequences, both
-- owner-reported:
--
--   1. Every text option on the Alt Power Bar tab did nothing while the bar
--      was attached -- Font Size and all six Percent/Value anchor+offset
--      controls. They wrote the profile correctly and the layout pass ran;
--      it just never reached the code that reads them. The texts kept the
--      GameFontNormalSmall face and the build-time anchors from
--      BuildOUFAltPowerBar.
--   2. Detaching applied that styling for the first time and re-attaching
--      did not undo it, so a detach/re-attach round trip visibly changed the
--      text size and position. The bar reuses ONE widget pair for both modes
--      (unlike the power bar, which has separate attached and detached
--      FontStrings and restyles each on every pass), so whatever the last
--      branch wrote simply persisted.
--
-- Calling this from both branches fixes both: the options apply in the mode
-- users actually run the bar in, and the two modes stop disagreeing because
-- they no longer run different code.
--
-- SetJustifyH is applied from the chosen point, mirroring the shared
-- unit-frame text pass — without it, moving Percent from RIGHT to LEFT left
-- the justification stuck at its build-time value and the text drifted off
-- its own anchor.
-- ============================================================
local ALT_TEXT_JUSTIFY = {
    LEFT        = "LEFT",
    CENTER      = "CENTER",
    RIGHT       = "RIGHT",
    TOPLEFT     = "LEFT",
    TOP         = "CENTER",
    TOPRIGHT    = "RIGHT",
    BOTTOMLEFT  = "LEFT",
    BOTTOM      = "CENTER",
    BOTTOMRIGHT = "RIGHT",
}

function BF:_ApplyOUFAltPowerBarText()
    local mb = self.oufAltPowerBar
    if not mb then return end
    local p = self.ufDB.profile
    local fontSize = p.altPowerFontSize or 7

    local function apply(fs, fontKey, pos, defPoint, defX)
        if not fs then return end
        fs:SetFont(BF:GetOUFFont(fontKey, GameFontNormalSmall:GetFont()), fontSize, "")
        local pt = (pos and pos.point) or defPoint
        fs:ClearAllPoints()
        fs:SetPoint(pt, mb, pt, (pos and pos.x) or defX, (pos and pos.y) or 0)
        fs:SetJustifyH(ALT_TEXT_JUSTIFY[pt] or "LEFT")
    end

    apply(mb._pctText, "oufAltPowerPctFont", p.altPowerPctPos, "RIGHT", -3)
    apply(mb._valText, "oufAltPowerValFont", p.altPowerValPos, "LEFT",   3)
end

-- ============================================================
-- LAYOUT
-- ============================================================
function BF:ApplyOUFAltPowerBarLayout()
    local mb = self.oufAltPowerBar
    if not mb then return end
    local p = self.ufDB.profile

    local detached = p.altPowerBarDetached
    local playerFrame = self.oufPlayer

    if not detached then
        -- Attached mode: position on player frame between health and power.
        -- The bar acts as a spacer: when the druid mana status is inactive,
        -- UpdateOUFAltPowerBar collapses height to 0 instead of hiding,
        -- so the power bar (anchored to our BOTTOM) slides up naturally.
        mb:SetParent(playerFrame or UIParent)
        mb:SetFrameStrata("MEDIUM")
        mb:SetFrameLevel((playerFrame and playerFrame:GetFrameLevel() or 5) + 3)
        if mb._handle then mb._handle:Hide() end

        -- Icon cutout mask: when attached to the player, subscribe the alt
        -- power bar's textures to the player's mask so the bar gets the
        -- same icon-shaped cutout as the health/power bars above/below it.
        -- Also subscribes the four border edges so they don't bleed past
        -- the icon's curve either.
        local mask = playerFrame and playerFrame._oufIconCutoutMask
        if mask and not mb._iconCutoutAttached then
            local fillTex = mb:GetStatusBarTexture()
            if fillTex then fillTex:AddMaskTexture(mask) end
            if mb._bg then mb._bg:AddMaskTexture(mask) end
            local b = mb._border
            if b then
                if b.top    then b.top:AddMaskTexture(mask)    end
                if b.bottom then b.bottom:AddMaskTexture(mask) end
                if b.left   then b.left:AddMaskTexture(mask)   end
                if b.right  then b.right:AddMaskTexture(mask)  end
            end
            mb._iconCutoutAttached = mask
        end

        -- v90.8: the v59 subscription to the player's composite
        -- rounded mask is REMOVED — that sliced mask is retired from
        -- rendering (permanently hidden), and its attachment was
        -- silently costing one of the engine's THREE mask slots per
        -- texture, which pushed the fill over the limit when the
        -- edge-strip pair attached (live error: "maximum number of
        -- mask textures (3)"; fill = cutout + dead composite mask +
        -- strips). The attached alt bar sits INTERIOR to the block
        -- (between health and power), so it never reaches the block's
        -- corner radius in composite mode; when the power bar is
        -- hidden/detached and the alt bar becomes the block's bottom
        -- edge, its own per-bar kit handles the rounding in per-bar
        -- mode, and in composite mode the ring band covers its flush
        -- bottom edge. If old sessions left the dead mask attached,
        -- detach cleanup below still removes it via
        -- mb._roundMaskAttached.

        if playerFrame then
            local pf = p.player or {}
            local nameH   = pf.nameBarHeight   or 13
            -- v91: the BAND (configured health + reserved strip), so the
            -- bar's bottom edge lands exactly where the power bar begins.
            local healthH = BF:GetOUFPlayerHealthBandHeight()
            local manaH   = p.altPowerBarHeight or 3
            local barW    = pf.frameWidth      or 156
            local inL = playerFrame._iconBarInsetLeft_alt  or 0
            local inR = playerFrame._iconBarInsetRight_alt or 0
            -- Anchor only to the non-icon side with offset 0 + SetSize.
            -- See ApplyOUFPlayerLayout for rationale.
            mb:ClearAllPoints()
            -- v91: anchored by its BOTTOM to the bottom of the health band,
            -- so it grows UPWARD into the strip the health bar gives up
            -- (ApplyOUFPlayerLayout sizes health to healthH - altH). Its
            -- bottom edge is therefore pinned at -(nameH + healthH) whatever
            -- its height, which is what keeps the power band below it from
            -- moving on a form change -- and what makes the whole transition
            -- legal in combat, since none of these frames are protected.
            --
            -- It used to anchor by its TOP at that same offset and act as a
            -- SPACER: the power bar hung off its BOTTOM, so the bar's height
            -- pushed the power bar down and the frame had to grow to match.
            -- That is the coupling this change removes.
            local aAnchor = BF:GetOUFBarAnchorSide(playerFrame, inL)
            local bottomAnchor = (aAnchor == "TOPRIGHT") and "BOTTOMRIGHT" or "BOTTOMLEFT"
            mb:SetPoint(bottomAnchor, playerFrame, aAnchor, 0, -nameH - healthH)
            mb:SetSize(BF:PixelRound(barW - inL - inR), manaH)
            mb:Show()  -- height is driven by Update: altH in form, epsilon out of it
        end
        -- Attached mode gets the same text pass as detached mode. Before this
        -- the branch returned here and the tab's Font Size / Percent / Value
        -- controls were unreachable in the mode the bar normally runs in.
        self:_ApplyOUFAltPowerBarText()
        self:_ApplyOUFAltPowerBarBorder()
        self:UpdateOUFAltPowerBar()
        return
    end

    -- Detached mode
    -- Remove the icon cutout mask if it was previously attached, so the
    -- detached bar isn't clipped by a cutout positioned over the player
    -- frame (which is now elsewhere on screen).
    if mb._iconCutoutAttached then
        local mask = mb._iconCutoutAttached
        local fillTex = mb:GetStatusBarTexture()
        if fillTex then fillTex:RemoveMaskTexture(mask) end
        if mb._bg then mb._bg:RemoveMaskTexture(mask) end
        local b = mb._border
        if b then
            if b.top    then b.top:RemoveMaskTexture(mask)    end
            if b.bottom then b.bottom:RemoveMaskTexture(mask) end
            if b.left   then b.left:RemoveMaskTexture(mask)   end
            if b.right  then b.right:RemoveMaskTexture(mask)  end
        end
        mb._iconCutoutAttached = nil
    end
    -- Per-bar kit ring cutout (v65): remove on detach for the same
    -- reason — the cutout mask is positioned over the player frame.
    do
        local kit = mb._bfRoundKit
        if kit and kit.ring._bfCutoutAttached then
            kit.ring:RemoveMaskTexture(kit.ring._bfCutoutAttached)
            kit.ring._bfCutoutAttached = nil
        end
    end
    -- Remove the player's composite rounded mask too — a detached bar
    -- must not be clipped by a mask positioned over the player frame.
    -- (The detached bar's OWN ring+mask kit is applied by
    -- _ApplyOUFAltPowerBarBorder below.)
    if mb._roundMaskAttached then
        local rmask = mb._roundMaskAttached
        local fillTex = mb:GetStatusBarTexture()
        if fillTex then fillTex:RemoveMaskTexture(rmask) end
        if mb._bg then mb._bg:RemoveMaskTexture(rmask) end
        mb._roundMaskAttached = nil
    end

    local locked = self.db.global.locked
    if locked == nil then locked = true end

    local manaH = p.altPowerBarHeight or 3
    local pf    = p.player or {}
    local barW  = p.oufAltPowerBarWidth or pf.frameWidth or 156

    mb:SetHeight(manaH)
    mb:SetWidth(barW)

    -- Re-parent to UIParent
    local wasAttached = (mb:GetParent() ~= UIParent)
    if wasAttached then
        local cx, cy = mb:GetCenter()
        if (not cx or not cy) and playerFrame and playerFrame.Power then
            cx, cy = playerFrame.Power:GetCenter()
        end
        local ux, uy = UIParent:GetCenter()
        if cx and cy and ux and uy then
            local existX, existY = BF:GetUFAnchor("playerAltPowerBar")
            if not existX then
                -- Nudge downward to avoid overlapping the player frame
                BF:SetUFAnchor("playerAltPowerBar", cx - ux, (cy - uy) - 30)
            end
        end
        mb:SetParent(UIParent)
        mb:SetFrameStrata("MEDIUM")
        mb:SetFrameLevel(50)
    end

    local ancX, ancY = BF:GetUFAnchor("playerAltPowerBar")
    mb:ClearAllPoints()
    mb:SetPoint("CENTER", UIParent, "CENTER", ancX or -400, ancY or -350)

    -- Text font sizes and positions — one implementation, shared with the
    -- attached branch above.
    self:_ApplyOUFAltPowerBarText()

    mb._handle:SetShown(not locked)
    if not locked then self:_SnapOUFAltPowerBarHandle() end

    self:_ApplyOUFAltPowerBarBorder()
    -- Settings may have changed attached/detached or heights — force the
    -- next collapse pass to run in full rather than hitting the
    -- steady-state _altCollapsed early-out with stale assumptions.
    mb._altCollapsed = nil
    self:UpdateOUFAltPowerBar()
end

-- ============================================================
-- UPDATE
-- ============================================================
function BF:UpdateOUFAltPowerBar()
    local mb = self.oufAltPowerBar
    if not mb then return end
    local p = self.ufDB.profile
    local attached = not p.altPowerBarDetached

    -- When disabled, collapse to epsilon (attached spacer) or hide (detached)
    if not p.showAltPowerBar then
        -- PERF: steady-state collapse is a no-op. The flag is cleared by the
        -- active path below and by ApplyOUFAltPowerBarLayout (so any settings
        -- change forces one full collapse pass with fresh profile state).
        if mb._altCollapsed then return end
        mb._altCollapsed = true
        local wasActive = mb._altBorderActive
        if attached then
            mb:SetHeight(0.001)
            mb:SetAlpha(0)
            if mb._pctText then mb._pctText:Hide() end
            if mb._valText then mb._valText:Hide() end
            if mb._border then mb._border:Hide() end
        else
            mb:Hide()
        end
        if mb._handle then mb._handle:Hide() end
        -- Re-run frame border deduplication if the alt border just disappeared
        if wasActive and self.oufPlayer then
            mb._altBorderActive = false
            -- Restore power-top edge (Rule 2 now handles health-bottom suppression).
            local fb = self.oufPlayer._frameBorder
            if fb and fb.power and fb.power._wantShown and fb.power._cachedColor then
                local cc = fb.power._cachedColor
                fb.power.top:SetColorTexture(cc.r, cc.g, cc.b, cc.a)
            end
        end
        if wasActive then
            RefreshAltSlotBorder()
            -- v91: the health bar reclaims the strip. Unprotected, so this is
            -- safe on the combat path that brought us here.
            if self.ApplyOUFPlayerBarGeometry then
                self._altEdgeGeomRan = true
                self:ApplyOUFPlayerBarGeometry()
            end
        end
        return
    end

    local dmStatus = self.statuses and self.statuses.druidMana
    -- Check if the alt power bar should be active.
    -- For druids: active when in a shapeshift form (primary power != mana)
    -- AND the current spec is toggled on in altPowerBarDruidSpecs.
    local altActive = false
    local _, playerClass = UnitClass("player")
    if playerClass == "DRUID" and UnitPowerType("player") ~= 0 then
        local specIdx = GetSpecialization()
        -- PERF: file-local DRUID_SPEC_KEYS (defined above) — the inline table
        -- literal here allocated 20-40 tables/sec while in form.
        local specKey = specIdx and DRUID_SPEC_KEYS[specIdx]
        local druidSpecs = p.altPowerBarDruidSpecs
        if specKey and druidSpecs and druidSpecs[specKey] then
            altActive = true
        end
    end
    if not altActive then
        -- PERF: steady-state collapse is a no-op (non-druids, druids out of
        -- form). See the matching guard in the disabled branch above.
        if mb._altCollapsed then return end
        mb._altCollapsed = true
        local wasActive = mb._altBorderActive
        if attached then
            -- Collapse to epsilon height; power bar slides up via anchor chain
            mb:SetHeight(0.001)
            mb:SetAlpha(0)
            if mb._pctText then mb._pctText:Hide() end
            if mb._valText then mb._valText:Hide() end
            if mb._border then mb._border:Hide() end
        else
            mb:Hide()
            if mb._handle then mb._handle:Hide() end
        end
        -- Re-run frame border deduplication if the alt border just disappeared
        if wasActive and self.oufPlayer then
            mb._altBorderActive = false
            -- Restore power-top edge (Rule 2 now handles health-bottom suppression).
            local fb = self.oufPlayer._frameBorder
            if fb and fb.power and fb.power._wantShown and fb.power._cachedColor then
                local cc = fb.power._cachedColor
                fb.power.top:SetColorTexture(cc.r, cc.g, cc.b, cc.a)
            end
        end
        if wasActive then
            RefreshAltSlotBorder()
            -- v91: see the matching call above -- health takes the strip back.
            if self.ApplyOUFPlayerBarGeometry then
                self._altEdgeGeomRan = true
                self:ApplyOUFPlayerBarGeometry()
            end
        end
        return
    end

    -- Active: expand to configured height
    mb._altCollapsed = nil
    local wasInactive = not mb._altBorderActive
    if attached and wasInactive then
        -- Transition from inactive to active: expand bar, show border.
        -- The border geometry was already computed by ApplyOUFAltPowerBarLayout;
        -- we just need to show it and suppress the power-top deduplication edge.
        local altH = p.altPowerBarHeight or 3
        mb:SetHeight(altH)
        mb:SetAlpha(1)
        -- Rounded mode has no attached-bar box (composite ring owns the
        -- look), so only the square path re-shows the border here.
        if mb._border and p.powerBorderEnabled and not BF:IsOUFRounded() then
            mb._border:Show()
        end
        mb._altBorderActive = true
        -- Suppress power-top edge (alt bar's bottom edge now handles that line).
        if self.oufPlayer and self.oufPlayer._frameBorder then
            local fb = self.oufPlayer._frameBorder
            if fb.power and fb.power._wantShown then
                fb.power.top:SetColorTexture(0, 0, 0, 0)
            end
        end
        RefreshAltSlotBorder()
        -- v91: the health bar gives the strip up to us. Unprotected.
        if self.ApplyOUFPlayerBarGeometry then
            self._altEdgeGeomRan = true
            self:ApplyOUFPlayerBarGeometry()
        end
    end

    -- Read mana directly (power type 0) instead of going through
    -- the DruidMana status, which is healer-only.
    -- Use raw values (like oUF_DetachedPowerBar) to avoid taint from
    -- arithmetic on secret number values returned by UnitPower.
    local manaMax = UnitPowerMax("player", 0)
    local manaCur = UnitPower("player", 0)
    if not manaMax or manaMax == 0 then
        mb:SetMinMaxValues(0, 1)
        mb:SetValue(0)
    else
        mb:SetMinMaxValues(0, manaMax)
        mb:SetValue(manaCur)
    end

    local mc = BF.PowerTypeColors and BF.PowerTypeColors.MANA
    if mc then
        mb:SetStatusBarColor(mc.r, mc.g, mc.b)
    else
        mb:SetStatusBarColor(0.00, 0.44, 1.00)
    end
    mb:SetAlpha(0.9)

    local S = CurveConstants and CurveConstants.ScaleTo100

    -- Percent text
    if mb._pctText then
        if p.altPowerShowPct ~= false then
            local pctFmt = (p.altPowerShowPctSymbol ~= false) and "%d%%" or "%d"
            mb._pctText:SetText(format(pctFmt, UnitPowerPercent("player", 0, false, S)))
            mb._pctText:Show()
        else
            mb._pctText:Hide()
        end
    end

    -- Value text
    if mb._valText then
        if p.altPowerShowVal == true then
            mb._valText:SetText(AbbreviateNumbers(UnitPower("player", 0)))
            mb._valText:Show()
        else
            mb._valText:Hide()
        end
    end

    mb:Show()
end
