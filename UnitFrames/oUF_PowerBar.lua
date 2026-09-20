-- ============================================================
-- BuzzardFrames: oUF_PowerBar.lua
-- Single owner of ALL player power bar state.
--
-- Two modes:
--   ATTACHED: f.Power is shown on the player frame, text is
--             driven by the Power PostUpdate in oUF_Shared.lua.
--             This file positions f.Power and applies fb.power.
--   DETACHED: f.Power is hidden, the standalone oufDetachedPowerBar
--             is shown on UIParent with its own text/color/border.
--
-- RULES:
--   1. This file NEVER calls ApplyOUFPlayerLayout.
--   2. This file NEVER touches alt power bar or resource bar.
--   3. ApplyOUFPlayerLayout calls ApplyOUFPowerBarLayout.
--   4. Options setters call the bar's layout, then player layout.
-- ============================================================
local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

-- Border-code revision marker (read by /bfborders — see oUF_Shared.lua).
BF._bfBorderRevPowerBar = "v90"

local format = string.format
local UnitPower = UnitPower
local UnitPowerMax = UnitPowerMax
local UnitPowerType = UnitPowerType
local UnitExists = UnitExists

-- ============================================================
-- QUERIES
-- ============================================================
function BF:IsPowerBarDetached()
    return self.GetUFDetachState and self:GetUFDetachState("playerPowerBar") or false
end

function BF:GetPowerBarEffectiveHeight()
    -- Always returns the configured height. Detach is alpha-only --
    -- the player frame keeps its full layout (power slot reserved)
    -- regardless of detach state; the detached pb on UIParent is a
    -- separate widget that doesn't affect the player frame's size.
    local pf = self.ufDB.profile.player or {}
    return pf.powerBarHeight or 10
end

-- ============================================================
-- BUILD
-- ============================================================
function BF:BuildOUFPowerBar()
    if self.oufDetachedPowerBar then return end

    local f = self.oufPlayer or UIParent
    local pb = BF.StatusBar("BuzzardFrames_oUFDetachedPowerBar", f)
    pb:SetFrameLevel(f:GetFrameLevel() + 4)
    pb:SetFrameStrata("MEDIUM")
    pb:EnableMouse(false)
    pb:SetMovable(true)
    pb:SetClampedToScreen(true)
    pb:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    pb:SetStatusBarColor(0.00, 0.44, 1.00)
    pb:Hide()

    local bg = BF.Texture(pb, nil, "BACKGROUND", nil, -1)
    bg:SetAllPoints(pb)
    -- Seeded from the profile rather than a literal, for the same reason as
    -- the attached bar's _powerBg in oUF_Shared: ApplyOUFPowerBarLayout is
    -- reached through ApplyOUFPlayerLayout, which RunSecure defers in combat.
    bg:SetColorTexture(BF:_GetOUFPowerBgColor())
    pb._bg = bg

    local border = CreateFrame("Frame", nil, pb)
    border:SetAllPoints(pb)
    border:SetFrameLevel(pb:GetFrameLevel() + 3)
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
    pb._border = border

    local textFrame = CreateFrame("Frame", nil, pb)
    textFrame:SetAllPoints(pb)
    textFrame:SetFrameLevel(pb:GetFrameLevel() + 5)
    textFrame:EnableMouse(false)

    local pctText = textFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pctText:SetTextColor(1, 1, 1, 1)
    pctText:SetPoint("RIGHT", pb, "RIGHT", -3, 0)
    pctText:SetJustifyH("RIGHT")
    pb._pctText = pctText

    local valText = textFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    valText:SetTextColor(1, 1, 1, 1)
    valText:SetPoint("LEFT", pb, "LEFT", 3, 0)
    valText:SetJustifyH("LEFT")
    pb._valText = valText

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
    lbl:SetText("Power Bar")
    lbl:SetTextColor(1, 1, 1)
    handle:SetScript("OnDragStart", function() pb:StartMoving() end)
    handle:SetScript("OnDragStop", function()
        pb:StopMovingOrSizing()
        local x, y   = pb:GetCenter()
        local ux, uy = UIParent:GetCenter()
        BF:SetUFAnchor("playerPowerBar", x - ux, y - uy)
        BF:_SnapOUFPowerBarHandle()
    end)
    handle:Hide()
    pb._handle = handle

    self.oufDetachedPowerBar = pb

    -- Apply the user's saved Power Bar Opacity (Unit Frames -> Global ->
    -- Colors -> Power Bars) to the detached bar + its border. Mirrors the
    -- attached-bar setup in oUF_Shared.lua so the setting survives a /reload.
    do
        local op = BF.ufDB and BF.ufDB.profile and BF.ufDB.profile.oufPowerBarOpacity
        if op ~= nil then
            pb:SetAlpha(op)
            if pb._border then pb._border:SetAlpha(op) end
        end
    end

    local ev = CreateFrame("Frame")
    ev:SetScript("OnEvent", function(_, event, unit)
        -- v86 PERF: PLAYER_SPECIALIZATION_CHANGED carries a unit and fires
        -- once per GROUP MEMBER as the client resolves their specs, so on a
        -- raid join this ran ~20 times for other people's specs. Only the
        -- player's own spec can change the player's power bar.
        if event == "PLAYER_SPECIALIZATION_CHANGED" and unit and unit ~= "player" then
            return
        end
        -- PERF: value ticks take the slim path (min/max/value/text only).
        -- Color tracks the power TYPE, which changes on UNIT_DISPLAYPOWER,
        -- not per tick; texture/alpha/text-visibility are profile-only and
        -- live in ApplyOUFPowerBarLayout.
        if event == "UNIT_POWER_FREQUENT" or event == "UNIT_MAXPOWER" then
            BF:TickOUFPowerBar()
        else
            BF:UpdateOUFPowerBar()
        end
    end)
    ev:RegisterEvent("PLAYER_ENTERING_WORLD")
    ev:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
    -- The three power events are (un)registered by ApplyOUFPowerBarLayout
    -- based on detach state — an attached-configuration player should not
    -- pay a 10-20x/sec handler that exists only to Hide() a hidden widget.
    -- Registered here as the pre-first-layout default.
    ev:RegisterUnitEvent("UNIT_POWER_FREQUENT", "player")
    ev:RegisterUnitEvent("UNIT_DISPLAYPOWER",   "player")
    ev:RegisterUnitEvent("UNIT_MAXPOWER",       "player")
    pb._eventFrame = ev
end

-- ============================================================
-- HANDLE SNAP
-- ============================================================
function BF:_SnapOUFPowerBarHandle()
    local pb = self.oufDetachedPowerBar
    if not pb or not pb._handle then return end
    local handle = pb._handle
    handle:ClearAllPoints()
    handle:SetPoint("BOTTOMLEFT", pb, "TOPLEFT", 0, 2)
    if self.db and self.db.global and self.db.global.tinyHandle then
        handle:SetWidth(5)
        handle:SetHeight(5)
    else
        local w = pb:GetWidth()
        if not w or w <= 0 then w = 80 end
        handle:SetWidth(w)
        handle:SetHeight(14)
    end
end

-- ============================================================
-- LAYOUT: called by ApplyOUFPlayerLayout, never by itself
-- ============================================================
function BF:ApplyOUFPowerBarLayout()
    local f = self.oufPlayer
    local pb = self.oufDetachedPowerBar
    local p = self.ufDB.profile
    local pf = p.player or {}
    local detached = self:IsPowerBarDetached()

    -- The detached bar owns a separate background texture from the attached
    -- f.Power's _powerBg (which _ApplyOUFPowerBgColor handles below), and it
    -- lives on UIParent so no other layout path reaches it. Colored here
    -- unconditionally so the two stay in step whichever one is visible.
    if pb and pb._bg then
        pb._bg:SetColorTexture(self:_GetOUFPowerBgColor())
    end

    -- ── ATTACHED BAR LAYOUT (always runs) ────────────────────────────────
    -- Detach is alpha-only too: the attached f.Power is always positioned
    -- at its layout slot, but when detached its alpha drops to 0 so the
    -- player frame's overall layout (frame height, chord insets, etc.)
    -- stays consistent regardless of detach state. The detached pb (on
    -- UIParent, separate widget) handles actual rendering when detached.
    if f and f.Power then
        local nameH   = pf.nameBarHeight   or 13
        -- v91: the health BAND (configured + the alt bar's reserved strip),
        -- so the power bar's top offset is invariant across a form change.
        local healthH = BF:GetOUFPlayerHealthBandHeight()
        local powerH  = pf.powerBarHeight  or 10
        local barW    = pf.frameWidth      or 156
        local inL = f._iconBarInsetLeft_power  or 0
        local inR = f._iconBarInsetRight_power or 0

        -- Anchor only to the non-icon side with offset 0 and use SetSize.
        -- See ApplyOUFPlayerLayout for the rationale (preserves offset-0
        -- inheritance to avoid 1px health-fill spill with circular icon).
        -- v91: ALWAYS anchored to the frame at a fixed offset, never to the
        -- alt power bar. The alt bar used to sit between health and power as
        -- a SPACER, so its height moved the power bar and the frame had to
        -- grow by that height to keep the bar inside its border -- a resize
        -- that is PROTECTED and therefore impossible mid-combat. The alt bar
        -- now takes its strip out of the health bar instead, which leaves
        -- this offset constant across a form change.
        f.Power:ClearAllPoints()
        -- v90.4: anchor side by ICON side (see GetOUFBarAnchorSide) so
        -- the power bar's far edge lands on the same snapped pixel as
        -- the health bar's.
        local anchorRight = BF:GetOUFBarAnchorSide(f, inL) == "TOPRIGHT"
        if anchorRight then
            f.Power:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, -nameH - healthH)
        else
            f.Power:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -nameH - healthH)
        end
        f.Power:SetSize(BF:PixelRound(barW - inL - inR), powerH)
        -- f.Power alpha is set below by _ApplyOUFPowerElementState
        -- (handles showPowerBar + detached + EnableElement/DisableElement
        -- all together for both player and non-player frames).

        -- Color
        if f.__unit then
            local r, g, b = BF:_GetOUFPowerColor(f.__unit, "player")
            f.Power:SetStatusBarColor(r, g, b)
        end

        -- Texture
        local pTex = (p.oufUseCustomPowerBarTexture and BF:ResolveBarTexture(p.oufPowerBarTexture)) or "Interface\\Buttons\\WHITE8X8"
        f.Power:SetStatusBarTexture(pTex)

        -- Background color
        BF:_ApplyOUFPowerBgColor(f)

        -- Font
        local pFontSz = pf.powerFontSize or 7
        local pFont = BF:GetOUFFont(nil, GameFontNormalSmall:GetFont())
        if f.PowerPctText then f.PowerPctText:SetFont(pFont, pFontSz, "") end
        if f.PowerValText then f.PowerValText:SetFont(pFont, pFontSz, "") end

        -- Text widgets. When detached, the pb has its own text widgets
        -- so suppress the attached ones to avoid duplicates. The Power
        -- PostUpdate's powerDetached check applies the same suppression
        -- on subsequent power events.
        local textShown = (pf.showPowerText ~= false) and not detached
        if f.PowerPctText then
            f.PowerPctText:SetShown(textShown and pf.showPowerPct ~= false)
        end
        if f.PowerValText then
            f.PowerValText:SetShown(textShown and pf.showPowerVal ~= false)
        end
    end

    -- Frame border. _ApplyPlayerPowerBorder(detached) hides the border
    -- when detached (no border around an invisible/alpha-0 bar).
    self:_ApplyPlayerPowerBorder(detached)

    -- Element + alpha gating (EnableElement/DisableElement, f.Power
    -- alpha, fb.power alpha). Runs AFTER _ApplyPlayerPowerBorder so
    -- the alpha 0 wins over any Show() that border layout may have done.
    -- The helper internally handles the player-detached case (alpha 0
    -- on attached f.Power when detached).
    if f then BF:_ApplyOUFPowerElementState(f, "player") end

    -- ── DETACHED BAR (pb on UIParent) ─────────────────────────────────────
    -- Hide the detached widget when not detached; otherwise fall through
    -- to size/position/show it.
    if not detached then
        if pb then
            pb:Hide()
            if pb._handle then pb._handle:Hide() end
            -- PERF: stop the 10-20x/sec power ticks entirely while attached —
            -- the handler existed only to Hide() an already-hidden widget.
            -- PLAYER_ENTERING_WORLD / PLAYER_SPECIALIZATION_CHANGED stay
            -- registered (rare; full update early-outs on the detach gate).
            local ev = pb._eventFrame
            if ev then
                ev:UnregisterEvent("UNIT_POWER_FREQUENT")
                ev:UnregisterEvent("UNIT_DISPLAYPOWER")
                ev:UnregisterEvent("UNIT_MAXPOWER")
            end
        end
        return
    end

    if not pb then return end

    -- Detached: (re)arm the power events (idempotent; mirrors the
    -- unregister in the attached branch above).
    do
        local ev = pb._eventFrame
        if ev then
            ev:RegisterUnitEvent("UNIT_POWER_FREQUENT", "player")
            ev:RegisterUnitEvent("UNIT_DISPLAYPOWER",   "player")
            ev:RegisterUnitEvent("UNIT_MAXPOWER",       "player")
        end
    end

    local locked = self.db.global.locked
    if locked == nil then locked = true end
    local h    = p.oufPowerBarHeight or pf.powerBarHeight or 10
    local barW = p.oufPowerBarWidth or pf.frameWidth or 156

    pb:SetHeight(h)
    pb:SetWidth(barW)

    local fontSize = pf.powerFontSize or 7
    local pFont = BF:GetOUFFont(nil, GameFontNormalSmall:GetFont())
    if pb._pctText then pb._pctText:SetFont(pFont, fontSize, "") end
    if pb._valText then pb._valText:SetFont(pFont, fontSize, "") end

    -- v92: apply the Power Percent / Power Value POSITION settings to the
    -- detached bar's own FontStrings. They were anchored once at Build
    -- (RIGHT -3 / LEFT +3) and powerPctPos/powerValPos only ever reached
    -- the ATTACHED texts (_ApplyOUFBarTextPositions anchors
    -- frame.Power*Text to f.Power) — the position/X/Y controls were inert
    -- while detached (owner-reported). Same shape as the alt power bar's
    -- _ApplyOUFAltPowerBarText apply(). No icon-chord compensation: the
    -- detached bar is a standalone rectangle, so the raw slider values are
    -- the whole offset.
    local function anchorText(fs, pos, defPoint, defX)
        if not fs then return end
        local pt = (pos and pos.point) or defPoint
        fs:ClearAllPoints()
        fs:SetPoint(pt, pb, pt, (pos and pos.x) or defX, (pos and pos.y) or 0)
        fs:SetJustifyH((pt:find("LEFT") and "LEFT")
            or (pt:find("RIGHT") and "RIGHT") or "CENTER")
    end
    anchorText(pb._pctText, pf.powerPctPos, "RIGHT", -3)
    anchorText(pb._valText, pf.powerValPos, "LEFT",   3)

    -- PERF: profile-only style, moved out of the per-tick update path.
    -- Texture (was an LSM resolve + SetStatusBarTexture per power tick):
    pb:SetStatusBarTexture((p.oufUseCustomPowerBarTexture
        and BF:ResolveBarTexture(p.oufPowerBarTexture))
        or "Interface\\Buttons\\WHITE8X8")
    -- Text visibility + percent format, baked for TickOUFPowerBar:
    local textOn = pf.showPowerText ~= false
    pb._showPct = (textOn and pf.showPowerPct ~= false) and true or false
    pb._showVal = (textOn and pf.showPowerVal ~= false) and true or false
    pb._pctFmt  = (pf.showPowerPctSymbol ~= false) and "%d%%" or "%d"
    if pb._pctText then pb._pctText:SetShown(pb._showPct) end
    if pb._valText then pb._valText:SetShown(pb._showVal) end

    if pb:GetParent() ~= UIParent then
        local cx, cy = pb:GetCenter()
        if not cx or not cy then
            if f and f.Power then cx, cy = f.Power:GetCenter() end
        end
        local ux, uy = UIParent:GetCenter()
        if cx and cy and ux and uy then
            local existX = BF:GetUFAnchor("playerPowerBar")
            if not existX then
                BF:SetUFAnchor("playerPowerBar", cx - ux, cy - uy)
            end
        end
        pb:SetParent(UIParent)
        pb:SetFrameStrata("MEDIUM")
        pb:SetFrameLevel(10)
    end

    local ancX, ancY = BF:GetUFAnchor("playerPowerBar")
    pb:ClearAllPoints()
    pb:SetPoint("CENTER", UIParent, "CENTER", ancX or -400, ancY or -340)

    pb._handle:SetShown(not locked)
    if not locked then self:_SnapOUFPowerBarHandle() end

    self:_ApplyDetachedPowerBorder()
    -- showPowerBar alpha-only for the detached bar too.
    pb:SetAlpha(pf.showPowerBar == false and 0 or 1)
    pb:Show()
    self:UpdateOUFPowerBar()
end

-- ============================================================
-- FRAME BORDER: fb.power on the player frame
-- ============================================================
function BF:_ApplyPlayerPowerBorder(detached)
    local f = self.oufPlayer
    if not f then return end
    local fb = f._frameBorder
    if not fb or not fb.power then return end
    local p = self.ufDB.profile

    -- Rounded border mode (v59): the attached power bar is enclosed by
    -- the player frame's composite ring (_ApplyOUFRoundedFrameBorder in
    -- oUF_Shared.lua, which also lifts the ring bottom when the bar is
    -- hidden/detached) — the square box never shows.
    if BF:IsOUFRounded() then
        fb.power._wantShown = false
        fb.power:Hide()
        return
    end

    if detached then
        fb.power._wantShown = false
        fb.power:Hide()
        return
    end

    local pf = p.player or {}
    local show = p.powerBorderEnabled == true
    fb.power._wantShown = show
    if not show then
        fb.power:Hide()
        return
    end

    local nameH   = pf.nameBarHeight   or 13
    -- v91: the health BAND -- see the note in ApplyOUFPowerBarLayout.
    local healthH = BF:GetOUFPlayerHealthBandHeight()
    local powerH  = pf.powerBarHeight  or 10
    local barW    = pf.frameWidth      or 156

    BF:RefreshPixelSize()
    local thick = BF:PixelsToUI(p.powerBorderThickness or 1)
    local fScale = f:GetEffectiveScale() / UIParent:GetEffectiveScale()
    if fScale > 0 and fScale < 1 then thick = thick / fScale end
    local minThick = BF:PixelsToUI(1)
    if fScale > 0 and fScale < 1 then minThick = minThick / fScale end
    if thick < minThick then thick = minThick end

    local bc = p.powerBorderColor or { r=0, g=0, b=0, a=1 }
    local r, g, b, a = bc.r or 0, bc.g or 0, bc.b or 0, bc.a or 1
    fb.power._cachedColor = { r=r, g=g, b=b, a=a }

    local altBar = self.oufAltPowerBar
    local altAttached = altBar and altBar:GetParent() == f
        and p.showAltPowerBar and not p.altPowerBarDetached

    local inL = f._iconBarInsetLeft_power  or 0
    local inR = f._iconBarInsetRight_power or 0

    -- Anchor only to the non-icon side with offset 0 + SetSize.
    -- See ApplyOUFPlayerLayout for rationale.
    fb.power:ClearAllPoints()
    -- v90.4: anchor side by ICON side (see GetOUFBarAnchorSide).
    local fbAnchorRight = BF:GetOUFBarAnchorSide(f, inL) == "TOPRIGHT"
    if altAttached then
        if fbAnchorRight then
            fb.power:SetPoint("TOPRIGHT", altBar, "BOTTOMRIGHT", 0, 0)
        else
            fb.power:SetPoint("TOPLEFT",  altBar, "BOTTOMLEFT",  0, 0)
        end
    else
        if fbAnchorRight then
            fb.power:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, -(nameH + healthH))
        else
            fb.power:SetPoint("TOPLEFT",  f, "TOPLEFT",  0, -(nameH + healthH))
        end
    end
    fb.power:SetSize(BF:PixelRound(barW - inL - inR), powerH)

    fb.power:SetFrameLevel(f:GetFrameLevel() + 7)
    fb.power:Show()

    fb.power.top:SetColorTexture(r, g, b, a)
    fb.power.top:ClearAllPoints()
    fb.power.top:SetPoint("TOPLEFT",  fb.power, "TOPLEFT",  0, 0)
    fb.power.top:SetPoint("TOPRIGHT", fb.power, "TOPRIGHT", 0, 0)
    fb.power.top:SetHeight(thick)

    fb.power.bottom:SetColorTexture(r, g, b, a)
    fb.power.bottom:ClearAllPoints()
    fb.power.bottom:SetPoint("BOTTOMLEFT",  fb.power, "BOTTOMLEFT",  0, 0)
    fb.power.bottom:SetPoint("BOTTOMRIGHT", fb.power, "BOTTOMRIGHT", 0, 0)
    fb.power.bottom:SetHeight(thick)

    fb.power.left:SetColorTexture(r, g, b, a)
    fb.power.left:ClearAllPoints()
    fb.power.left:SetPoint("TOPLEFT",    fb.power, "TOPLEFT",    0, 0)
    fb.power.left:SetPoint("BOTTOMLEFT", fb.power, "BOTTOMLEFT", 0, 0)
    fb.power.left:SetWidth(thick)

    fb.power.right:SetColorTexture(r, g, b, a)
    fb.power.right:ClearAllPoints()
    fb.power.right:SetPoint("TOPRIGHT",    fb.power, "TOPRIGHT",    0, 0)
    fb.power.right:SetPoint("BOTTOMRIGHT", fb.power, "BOTTOMRIGHT", 0, 0)
    fb.power.right:SetWidth(thick)

    -- showPowerBar alpha-only: fade the whole border frame to 0 when off.
    fb.power:SetAlpha(pf.showPowerBar == false and 0 or 1)
end

-- ============================================================
-- DETACHED BAR BORDER
-- ============================================================
function BF:_ApplyDetachedPowerBorder()
    local pb = self.oufDetachedPowerBar
    if not pb or not pb._border then return end
    local p = self.ufDB.profile
    local bbf = pb._border

    -- Rounded border mode (v59): the detached bar gets its own
    -- standalone ring+mask kit (same Frame* art as the composite ring,
    -- frameBorderColor tint) in place of the 4-edge box. Level +3
    -- matches the square border frame created in BuildOUFPowerBar.
    -- v90: the kit honors powerBorderEnabled — the SAME key that gates
    -- the square box below — so the Global Styles Enable Border toggle
    -- (which writes it) hides the rounded border too.
    if BF:IsOUFRounded() and p.powerBorderEnabled ~= true then
        local kit = pb._bfRoundKit
        if kit then kit.ring:Hide(); kit.mask:Hide() end
        bbf:Hide()
        return
    end
    if BF:ApplyUFBarRoundBorder(pb,
        { pb:GetStatusBarTexture(), pb._bg }, pb:GetFrameLevel() + 3) then
        bbf:Hide()
        return
    end

    if p.powerBorderEnabled ~= true then
        bbf:Hide()
        return
    end

    bbf:SetFrameLevel(pb:GetFrameLevel() + 5)
    -- Match the attached-bar border math (_ApplyPlayerPowerBorder):
    -- convert profile pixel thickness to UI units, then compensate for
    -- the bar's effective scale so the border stays at a clean physical
    -- pixel count regardless of UI scale. Without this the detached
    -- border draws fatter/blurrier than the attached version.
    BF:RefreshPixelSize()
    local thick = BF:PixelsToUI(p.powerBorderThickness or 1)
    local pbScale = pb:GetEffectiveScale() / UIParent:GetEffectiveScale()
    if pbScale > 0 and pbScale < 1 then thick = thick / pbScale end
    local minThick = BF:PixelsToUI(1)
    if pbScale > 0 and pbScale < 1 then minThick = minThick / pbScale end
    if thick < minThick then thick = minThick end
    local bc    = p.powerBorderColor or { r=0, g=0, b=0, a=1 }
    local r, g, b, a = bc.r or 0, bc.g or 0, bc.b or 0, bc.a or 1

    bbf.top:SetColorTexture(r, g, b, a)
    bbf.top:ClearAllPoints()
    bbf.top:SetPoint("TOPLEFT",  pb, "TOPLEFT",  0, 0)
    bbf.top:SetPoint("TOPRIGHT", pb, "TOPRIGHT", 0, 0)
    bbf.top:SetHeight(thick)

    bbf.bottom:SetColorTexture(r, g, b, a)
    bbf.bottom:ClearAllPoints()
    bbf.bottom:SetPoint("BOTTOMLEFT",  pb, "BOTTOMLEFT",  0, 0)
    bbf.bottom:SetPoint("BOTTOMRIGHT", pb, "BOTTOMRIGHT", 0, 0)
    bbf.bottom:SetHeight(thick)

    bbf.left:SetColorTexture(r, g, b, a)
    bbf.left:ClearAllPoints()
    bbf.left:SetPoint("TOPLEFT",    pb, "TOPLEFT",    0, 0)
    bbf.left:SetPoint("BOTTOMLEFT", pb, "BOTTOMLEFT", 0, 0)
    bbf.left:SetWidth(thick)

    bbf.right:SetColorTexture(r, g, b, a)
    bbf.right:ClearAllPoints()
    bbf.right:SetPoint("TOPRIGHT",    pb, "TOPRIGHT",    0, 0)
    bbf.right:SetPoint("BOTTOMRIGHT", pb, "BOTTOMRIGHT", 0, 0)
    bbf.right:SetWidth(thick)

    bbf:Show()
end

-- ============================================================
-- UPDATE: only the detached bar
--
-- PERF (split update): the old single function re-resolved the LSM bar
-- texture, re-set the color, re-read profile tables, and re-decided text
-- visibility on EVERY UNIT_POWER_FREQUENT tick (10-20x/sec). Now:
--   TickOUFPowerBar   — value ticks: min/max/value + text values only,
--                       using fields baked by ApplyOUFPowerBarLayout
--                       (_showPct/_showVal/_pctFmt).
--   UpdateOUFPowerBar — full update (PEW, spec change, UNIT_DISPLAYPOWER,
--                       layout tail, _RefreshAllOUFPowerColors): detach
--                       gate + power-type color, then falls through to a
--                       tick. Texture/alpha/text-visibility are profile-
--                       only and live in ApplyOUFPowerBarLayout.
-- ============================================================
function BF:TickOUFPowerBar()
    local pb = self.oufDetachedPowerBar
    if not pb then return end

    local unit = "player"
    local powerType = UnitPowerType(unit)
    local cur = UnitPower(unit, powerType)
    local max = UnitPowerMax(unit, powerType)

    if not max or max == 0 then
        pb:SetMinMaxValues(0, 1)
        pb:SetValue(0)
    else
        pb:SetMinMaxValues(0, max)
        pb:SetValue(cur)
    end

    local S = CurveConstants and CurveConstants.ScaleTo100
    if pb._showPct and pb._pctText then
        pb._pctText:SetText(format(pb._pctFmt or "%d%%", UnitPowerPercent(unit, powerType, false, S)))
    end
    if pb._showVal and pb._valText then
        pb._valText:SetText(AbbreviateNumbers(cur))
    end
end

function BF:UpdateOUFPowerBar()
    local pb = self.oufDetachedPowerBar
    if not pb then return end

    if not self:IsPowerBarDetached() then
        pb:Hide()
        if pb._handle then pb._handle:Hide() end
        return
    end

    local unit = "player"
    if not UnitExists(unit) then pb:Hide(); return end

    -- Color tracks the power type (UNIT_DISPLAYPOWER lands here).
    local r, g, b = self:_GetOUFPowerColor(unit, "player")
    pb:SetStatusBarColor(r, g, b)

    -- Re-bake the text visibility/format + showPowerBar alpha from the
    -- profile. This FULL update runs on rare events (PEW, spec change,
    -- UNIT_DISPLAYPOWER) and on the options update() path (updatePlayer in
    -- Options_oUF_Other.lua) — the Pct/Val/Symbol toggles call update()
    -- WITHOUT a relayout, so baking these only in ApplyOUFPowerBarLayout
    -- left those setters inert (owner-reported). The per-tick path
    -- (TickOUFPowerBar) still only reads the baked fields.
    local pf = self.ufDB.profile.player or {}
    local textOn = pf.showPowerText ~= false
    pb._showPct = (textOn and pf.showPowerPct ~= false) and true or false
    pb._showVal = (textOn and pf.showPowerVal ~= false) and true or false
    pb._pctFmt  = (pf.showPowerPctSymbol ~= false) and "%d%%" or "%d"
    if pb._pctText then pb._pctText:SetShown(pb._showPct) end
    if pb._valText then pb._valText:SetShown(pb._showVal) end
    pb:SetAlpha(pf.showPowerBar == false and 0 or 1)
    pb:Show()

    self:TickOUFPowerBar()
end

-- Backward compat aliases
BF.BuildOUFDetachedPowerBar = BF.BuildOUFPowerBar
BF.ApplyOUFDetachedPowerBarLayout = BF.ApplyOUFPowerBarLayout
BF.UpdateOUFDetachedPowerBar = BF.UpdateOUFPowerBar
BF._SnapOUFDetachedPowerBarHandle = BF._SnapOUFPowerBarHandle
