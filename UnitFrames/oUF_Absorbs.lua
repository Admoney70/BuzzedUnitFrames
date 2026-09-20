-- ============================================================
-- BuzzardFrames: UnitFrames/oUF_Absorbs.lua
--
-- Absorb, overshield, heal prediction, and heal absorb overlays
-- for oUF unit frames (player, target, focus, boss1-5).
--
-- Visual structure mirrors Indicators/AbsorbBars.lua (raid/party
-- frames) and reads the same profile settings so both frame types
-- look identical.  Event handling is driven by oUF's built-in
-- HealthPrediction element -- the PostUpdate callback applies the
-- raid-frame settings to the oUF widgets.
--
-- NOTE: This is a novel solution.  Grid2 has no oUF absorb
-- element; oUF's built-in HealthPrediction visuals are simpler
-- than BF's raid frame absorbs.  This file bridges the gap.
-- ============================================================

local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

local UnitExists               = UnitExists
local UnitIsDeadOrGhost        = UnitIsDeadOrGhost
local UnitHealthMax            = UnitHealthMax
local UnitGetTotalHealAbsorbs  = UnitGetTotalHealAbsorbs
local UnitGetDetailedHealPrediction = UnitGetDetailedHealPrediction
local UnitCanAttack            = UnitCanAttack
local IsInRaid                 = IsInRaid


-- ============================================================
-- RestoreHealthBarAnchors
-- Reverts the clipFrame to follow the healthContainer in full,
-- so the Health bar spans the full container again after a
-- reduced-max-health state ends. Mirrors the raid-frame helper
-- in Indicators/AbsorbBars.lua. Gated on _oufReducedMaxActive
-- to avoid redundant anchor resets on every PostUpdate call.
-- ============================================================
local function RestoreHealthBarAnchors(frame)
    if not frame._oufReducedMaxActive then return end
    local clip      = frame._oufHealthClipFrame
    local container = frame._oufHealthContainer
    if clip and container then
        clip:ClearAllPoints()
        clip:SetAllPoints(container)
    end
    frame._oufReducedMaxActive = nil
end

-- A second calculator with DamageAbsorbClampMode = 2 (overshield
-- only).  oUF's element provides one calculator (clamp mode 1, which
-- clamps absorb to missing health).  We need a second one for the
-- Overlay overshield style.
local _overshieldCalc = CreateUnitHealPredictionCalculator()
_overshieldCalc:SetDamageAbsorbClampMode(2)

-- ============================================================
-- SetupOUFAbsorbs(frame)
-- Called from BluzzardStyle for player/target/focus/boss frames.
-- Creates all absorb widgets and wires them into oUF's
-- HealthPrediction element.
-- ============================================================
function BF:SetupOUFAbsorbs(frame)
    local Health = frame.Health
    if not Health then return end
    local hBarTex = Health:GetStatusBarTexture()
    if not hBarTex then return end

    -- ---- Absorb clip ------------------------------------------------
    local absorbClip = CreateFrame("Frame", nil, frame)
    absorbClip:SetAllPoints(Health)
    absorbClip:SetClipsChildren(true)
    -- Parented to the UNIT FRAME, not Health: Health sits inside healthClipFrame's
    -- SetClipsChildren render group, which would otherwise bound the absorbs'
    -- z-order below the aura-slot effects. Anchored to Health (clipping unchanged).
    --
    -- LEVELS: the whole absorb stack is FRAME-relative (Health's own level
    -- varies with container/clip nesting per unit type, so Health-relative
    -- levels floated over the border/text on player/target). Raid-frame
    -- ordering (Indicators/AbsorbBars.lua), compressed under the frame
    -- border (+7) and text (+10):
    --   +4 clip / heal-pred / overshield bar   (raid: hBar+6)
    --   +5 missing-health absorb / glow        (raid: hBar+7)
    --   +6 heal-absorb group                   (raid: hBar+10, topmost)
    absorbClip:SetFrameLevel(frame:GetFrameLevel() + 4)
    frame._oufAbsorbClip = absorbClip

    -- ---- Heal prediction --------------------------------------------
    local healPred = BF.StatusBar(nil, absorbClip)
    healPred:EnableMouse(false)
    BF:DisablePixelSnapRegion(healPred)
    healPred:SetPoint("TOPLEFT",    hBarTex, "TOPRIGHT")
    healPred:SetPoint("BOTTOMLEFT", hBarTex, "BOTTOMRIGHT")
    healPred:SetWidth(Health:GetWidth())
    healPred:SetStatusBarTexture("Interface\\RaidFrame\\Raid-Bar-Hp-Fill")
    healPred:SetStatusBarColor(0, 0.7, 0, 0.6)
    healPred:SetMinMaxValues(0, 1)
    healPred:SetValue(0)
    healPred:SetFrameLevel(frame:GetFrameLevel() + 4)
    healPred:Hide()

    -- ---- Damage absorb (missing health gap) -------------------------
    local absorbBar = BF.StatusBar(nil, absorbClip)
    absorbBar:EnableMouse(false)
    BF:DisablePixelSnapRegion(absorbBar)
    absorbBar:SetPoint("TOPLEFT",    hBarTex, "TOPRIGHT")
    absorbBar:SetPoint("BOTTOMLEFT", hBarTex, "BOTTOMRIGHT")
    absorbBar:SetWidth(Health:GetWidth())
    -- +5: orders the missing-health absorb above the overshield/heal-pred (+4)
    -- — raid parity; see the level table on absorbClip above.
    absorbBar:SetFrameLevel(frame:GetFrameLevel() + 5)
    -- Base texture (Blizzard shield overlay, tiled)
    local absorbTex = BF.Texture(absorbBar, nil, "ARTWORK")
    absorbTex:SetTexture(7539076, "REPEAT", "REPEAT")
    absorbTex:SetHorizTile(true)
    absorbTex:SetVertTile(true)
    absorbBar:SetStatusBarTexture(absorbTex)
    absorbBar:SetStatusBarColor(0.941, 0.941, 0.937, 1.0)
    absorbBar:SetMinMaxValues(0, 1)
    absorbBar:SetValue(0)
    absorbBar:Hide()
    -- Background behind fill texture
    local layer, sublayer = absorbTex:GetDrawLayer()
    local absorbBg = BF.Texture(absorbBar, nil)
    absorbBg:SetColorTexture(0, 0, 0, 1)
    absorbBg:SetDrawLayer(layer, sublayer - 1)
    absorbBg:SetAllPoints(absorbTex)
    absorbBar._bg = absorbBg
    -- Overlay texture (Blizzard cross-hatch, tiled)
    local absorbOverlay = BF.Texture(absorbBar, nil)
    absorbOverlay:SetTexture(7539079, "REPEAT", "REPEAT")
    absorbOverlay:SetHorizTile(true)
    absorbOverlay:SetVertTile(true)
    absorbOverlay:SetDrawLayer(layer, sublayer + 1)
    absorbOverlay:SetAllPoints(absorbTex)
    absorbOverlay:Show()
    absorbBar._overlay = absorbOverlay
    -- TotalAbsorbLeftShadow, verbatim from CompactUnitFrame.xml (~:23):
    -- "!raidframe-absorb-edge" (leading ! = vertically tiling strip),
    -- useAtlasSize so the width comes from the art, anchored TOPLEFT +
    -- BOTTOMLEFT to the fill only. Mirrors Indicators/AbsorbBars.lua (~:165).
    local absorbLeftShadow = BF.Texture(absorbBar, nil)
    absorbLeftShadow:SetAtlas("!raidframe-absorb-edge", true)
    absorbLeftShadow:SetDrawLayer(layer, sublayer + 1)
    absorbLeftShadow:SetPoint("TOPLEFT",    absorbTex, "TOPLEFT")
    absorbLeftShadow:SetPoint("BOTTOMLEFT", absorbTex, "BOTTOMLEFT")
    absorbLeftShadow:Hide()
    absorbBar._leftShadow = absorbLeftShadow

    -- ---- Overshield (Overlay style: reverse-fill StatusBar) ---------
    local overshieldBar = BF.StatusBar(nil, absorbClip)
    overshieldBar:EnableMouse(false)
    BF:DisablePixelSnapRegion(overshieldBar)
    overshieldBar:SetAllPoints(Health)
    overshieldBar:SetFrameLevel(frame:GetFrameLevel() + 4)
    local overshieldTex = BF.Texture(overshieldBar, nil, "ARTWORK")
    overshieldTex:SetTexture(7539076, "REPEAT", "REPEAT")
    overshieldTex:SetHorizTile(true)
    overshieldTex:SetVertTile(true)
    overshieldBar:SetStatusBarTexture(overshieldTex)
    overshieldBar:SetStatusBarColor(0.937, 0.941, 0.855, 0.36)
    overshieldBar:SetReverseFill(true)
    overshieldBar:SetMinMaxValues(0, 1)
    overshieldBar:SetValue(0)
    -- Overlay texture
    local overshieldOverlay = BF.Texture(overshieldBar, nil, "ARTWORK", nil, 1)
    overshieldOverlay:SetTexture(7539079, "REPEAT", "REPEAT")
    overshieldOverlay:SetHorizTile(true)
    overshieldOverlay:SetVertTile(true)
    overshieldOverlay:SetBlendMode("BLEND")
    overshieldOverlay:SetAllPoints(overshieldTex)
    overshieldOverlay:Hide()
    overshieldBar._overlay = overshieldOverlay
    overshieldBar:Hide()

    -- ---- Overshield glow (Glow style) -------------------------------
    -- Mirror of Blizzard's overAbsorbGlow (12.1 layout source: atlas
    -- RaidFrame-Shield-Overshield, IgnoreAtlasSize, Clamp, ADD; geometry:
    -- 16 wide, full bar height, left edge 7px inside the bar's right edge
    -- so the feathered glow straddles the edge). Same shape as the raid
    -- frames' overshieldGlow in Indicators/AbsorbBars.lua — keep in sync.
    local overshieldGlow = CreateFrame("Frame", nil, frame)
    overshieldGlow:SetPoint("TOPLEFT", Health, "TOPRIGHT", -7, 0)
    overshieldGlow:SetPoint("BOTTOMLEFT", Health, "BOTTOMRIGHT", -7, 0)
    overshieldGlow:SetWidth(16)
    overshieldGlow:SetFrameLevel(frame:GetFrameLevel() + 5)
    local glowTex = BF.Texture(overshieldGlow, nil, "ARTWORK")
    glowTex:SetAllPoints(overshieldGlow)
    glowTex:SetAtlas("RaidFrame-Shield-Overshield", false)
    glowTex:SetBlendMode("ADD")
    glowTex:SetVertexColor(1, 1, 1, 1)
    overshieldGlow:SetAlpha(0)
    overshieldGlow:Show()

    -- ---- Frame clip for heal absorb ---------------------------------
    -- LEVELS: pinned to the UNIT FRAME's base, not Health's. Health sits
    -- inside container/clip nesting (1-3 levels above the frame depending on
    -- unit), so "Health + 10" floated the heal-absorb group ABOVE the frame
    -- border boxes (frame+7, oUF_Shared ApplyBox) and the text frame
    -- (frame+10) — it painted over both. frame+6 is above the health fill
    -- and the other absorb widgets it overlays, below border and text.
    local frameClip = CreateFrame("Frame", nil, frame)
    frameClip:SetAllPoints(frame)
    frameClip:SetClipsChildren(true)
    frameClip:SetFrameLevel(frame:GetFrameLevel() + 6)
    frame._oufHealAbsorbClip = frameClip

    -- ---- Heal absorb (reverse-fill overlay from health fill edge) ----
    local healAbsorb = BF.StatusBar(nil, frameClip)
    healAbsorb:EnableMouse(false)
    BF:DisablePixelSnapRegion(healAbsorb)
    healAbsorb:SetFrameLevel(frame:GetFrameLevel() + 6)
    local healAbsorbTex = BF.Texture(healAbsorb, nil, "ARTWORK")
    healAbsorbTex:SetTexture("Interface\\Buttons\\WHITE8x8")
    healAbsorb:SetStatusBarTexture(healAbsorbTex)
    healAbsorb:SetStatusBarColor(1, 0, 0, 0.5)
    healAbsorb:SetReverseFill(true)
    healAbsorb:SetMinMaxValues(0, 1)
    healAbsorb:SetValue(0)
    healAbsorb:SetAlpha(0)
    healAbsorb:Show()
    -- Blizzard plus-symbols overlay (7539063)
    local healAbsorbOverlay = BF.Texture(healAbsorb, nil, "ARTWORK", nil, 1)
    healAbsorbOverlay:SetTexture(7539063, "REPEAT", "REPEAT")
    healAbsorbOverlay:SetHorizTile(true)
    healAbsorbOverlay:SetVertTile(true)
    healAbsorbOverlay:SetAllPoints(healAbsorbTex)
    -- v93: alpha 1 -- the picker's alpha owns this now (see AbsorbBars).
    healAbsorbOverlay:SetAlpha(1)
    healAbsorbOverlay:Hide()
    healAbsorb._overlay = healAbsorbOverlay
    -- Blizzard right shadow (898248)
    local healAbsorbShadow = BF.Texture(healAbsorb, nil, "ARTWORK", nil, 2)
    healAbsorbShadow:SetTexture(898248)
    healAbsorbShadow:Hide()
    healAbsorb._shadow = healAbsorbShadow

    -- ---- Heal absorb bar (top-strip alternative style) --------------
    local healAbsorbStrip = BF.StatusBar(nil, frame)
    healAbsorbStrip:EnableMouse(false)
    BF:DisablePixelSnapRegion(healAbsorbStrip)
    -- Same border/text pinning as the overlay group above.
    healAbsorbStrip:SetFrameLevel(frame:GetFrameLevel() + 6)
    healAbsorbStrip:SetPoint("TOPLEFT",  Health, "TOPLEFT",  0, 0)
    healAbsorbStrip:SetPoint("TOPRIGHT", Health, "TOPRIGHT", 0, 0)
    healAbsorbStrip:SetHeight(12)
    local healAbsorbStripTex = BF.Texture(healAbsorbStrip, nil, "ARTWORK")
    healAbsorbStripTex:SetTexture("Interface\\Buttons\\WHITE8x8")
    healAbsorbStrip:SetStatusBarTexture(healAbsorbStripTex)
    healAbsorbStrip:SetStatusBarColor(1, 0, 0, 0.75)
    healAbsorbStrip:SetMinMaxValues(0, 1)
    healAbsorbStrip:SetValue(0)
    healAbsorbStrip:SetAlpha(0)
    healAbsorbStrip:Show()
    -- Blizzard plus-symbols overlay for BarBlizzard style
    local healAbsorbStripOverlay = BF.Texture(healAbsorbStrip, nil, "ARTWORK", nil, 1)
    healAbsorbStripOverlay:SetTexture(7539063, "REPEAT", "REPEAT")
    healAbsorbStripOverlay:SetHorizTile(true)
    healAbsorbStripOverlay:SetVertTile(true)
    healAbsorbStripOverlay:SetAllPoints(healAbsorbStripTex)
    -- v93: alpha 1 -- the picker's alpha owns this now (see AbsorbBars).
    healAbsorbStripOverlay:SetAlpha(1)
    healAbsorbStripOverlay:Hide()
    healAbsorbStrip._overlay = healAbsorbStripOverlay

    -- ---- Reduced max health bar ------------------------------------
    -- Gated on the frame having a healthContainer (player/target/focus).
    -- Mirrors raid-frame AbsorbBars.lua:Create reducedMaxHealthBar creation.
    -- Reverse-fill StatusBar anchored to the healthContainer; the bar fills
    -- from the right edge leftward by (1 - modifiedMaxHealthPct). The
    -- bar's fill texture left edge is then used as the anchor target to
    -- clip the Health bar's clipFrame, cutting the health bar short.
    if frame._oufHealthContainer then
        local reducedMaxBar = BF.StatusBar(nil, frame)
        reducedMaxBar:EnableMouse(false)
        BF:DisablePixelSnapRegion(reducedMaxBar)
        reducedMaxBar:SetAllPoints(frame._oufHealthContainer)
        reducedMaxBar:SetFrameLevel(Health:GetFrameLevel() + 1)
        reducedMaxBar:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
        reducedMaxBar:SetStatusBarColor(0.3, 0.3, 0.3, 0.8)
        reducedMaxBar:SetReverseFill(true)
        reducedMaxBar:SetMinMaxValues(0, 1)
        reducedMaxBar:SetValue(0)
        reducedMaxBar:Show()
        frame._oufReducedMaxBar = reducedMaxBar
    end

    -- ---- Store references on frame ----------------------------------
    frame._oufHealPred        = healPred
    frame._oufAbsorbBar       = absorbBar
    frame._oufOvershieldBar   = overshieldBar
    frame._oufOvershieldGlow  = overshieldGlow
    frame._oufOvershieldGlowTex = glowTex
    frame._oufHealAbsorb      = healAbsorb
    frame._oufHealAbsorbStrip = healAbsorbStrip

    -- ---- Icon cutout mask attachment --------------------------------
    -- All absorb/heal-prediction overlays sit inside the chord-inset
    -- Health region, so they bleed under the icon's curve at the bar's
    -- near corner just like the Health fill does. Attach the unit
    -- frame's mask (set up in BluzzardStyle) to every fill texture and
    -- companion overlay/bg/shadow texture here so they all share the
    -- same icon-shaped cutout.
    local mask = frame._oufIconCutoutMask
    if mask then
        local function attach(tex) if tex then tex:AddMaskTexture(mask) end end
        attach(healPred:GetStatusBarTexture())
        attach(absorbTex)        -- absorbBar fill
        attach(absorbBg)         -- absorbBar background
        attach(absorbOverlay)    -- absorbBar overlay
        attach(absorbLeftShadow) -- absorbBar left shadow (absorb/health seam)
        attach(overshieldTex)    -- overshieldBar fill
        attach(overshieldOverlay)
        attach(glowTex)          -- overshield glow strip (sits at bar edge)
        attach(healAbsorbTex)    -- healAbsorb fill
        attach(healAbsorbOverlay)
        attach(healAbsorbShadow)
        attach(healAbsorbStripTex) -- healAbsorbStrip fill
        attach(healAbsorbStripOverlay)
        if frame._oufReducedMaxBar then
            attach(frame._oufReducedMaxBar:GetStatusBarTexture())
        end
    end

    -- ---- Wire into oUF HealthPrediction -----------------------------
    -- oUF's element handles event registration (UNIT_HEALTH, UNIT_MAXHEALTH,
    -- UNIT_HEAL_PREDICTION, UNIT_ABSORB_AMOUNT_CHANGED, etc.) and calls
    -- Update which populates the values via CreateUnitHealPredictionCalculator.
    -- The PostUpdate callback applies the raid-frame visual settings.
    frame.HealthPrediction = {
        healingAll   = healPred,
        damageAbsorb = absorbBar,
        healAbsorb   = healAbsorb,
        -- DamageAbsorbClampMode 1 = clamp absorb to missing health gap
        damageAbsorbClampMode = 1,

        PostUpdate = function(element, unit)
            BF:_OUFAbsorbPostUpdate(frame, unit, element)
        end,
    }

    -- v98: reduced-max is event-driven like the raid frames (see
    -- _OUFUpdateReducedMax). oUF registers this as a unit event for the
    -- frame's own unit; the element's Update also listens to it, and oUF
    -- fans one event out to both handlers.
    if frame._oufReducedMaxBar then
        frame:RegisterEvent("UNIT_MAX_HEALTH_MODIFIERS_CHANGED", BF._OUFReducedMaxEvent)
    end
end

-- ============================================================
-- _ApplyOUFAbsorbStyle
-- Grid2 pattern: precompute all settings-derived state at
-- init/layout/settings-change time, not per-event.
-- Called from ApplyOUFAbsorbLayout and _RefreshAllOUFAbsorbs.
-- Caches results on the frame as _oufAbsorbCfg_* fields so
-- _OUFAbsorbPostUpdate can skip all profile lookups, texture
-- resolution, and color work.
-- ============================================================
function BF:_ApplyOUFAbsorbStyle(frame)
    if not frame then return end
    local Health = frame.Health
    if not Health then return end

    local isRaid = BF:ResolveActiveIsRaid()
    local activeFlat = isRaid and BF:GetRaidProfile() or BF:GetActivePartyProfile()
    local ab = BF:GetSectionProfile("absorbs", activeFlat)
    local hp = BF:GetSectionProfile("healthPower", activeFlat)
    if not ab then return end

    -- Cache profile references
    frame._oufAbsorbCfg_ab = ab
    frame._oufAbsorbCfg_hp = hp

    -- ---- Heal Prediction style --------------------------------------
    local healPred = frame._oufHealPred
    if healPred then
        frame._oufAbsorbCfg_showHealPred = ab.showHealPrediction and true or false
        if ab.showHealPrediction then
            local c = ab.healPredictionColor
            if c then
                healPred:SetStatusBarColor(c.r, c.g, c.b, c.a or 0.6)
            else
                healPred:SetStatusBarColor(0, 0.7, 0, 0.6)
            end
            local texKey = (ab.useCustomHealPredictionTexture and ab.healPredictionTexture) or "_default"
            if frame._oufHealPredTexKey ~= texKey then
                if texKey ~= "_default" and self.ResolveBarTexture then
                    healPred:SetStatusBarTexture(self:ResolveBarTexture(texKey))
                else
                    healPred:SetStatusBarTexture("Interface\\RaidFrame\\Raid-Bar-Hp-Fill")
                end
                frame._oufHealPredTexKey = texKey
            end
        end
    end

    -- ---- Damage absorb (missing health gap) style -------------------
    local absorbBar = frame._oufAbsorbBar
    if absorbBar then
        local absorbTexKey = (ab.useCustomAbsorbBarTexture and ab.absorbBarTexture) or "_default"
        if frame._oufAbsorbTexKey ~= absorbTexKey then
            local arTex = absorbBar:GetStatusBarTexture()
            if arTex then
                if absorbTexKey ~= "_default" and self.ResolveBarTexture then
                    local path = self:ResolveBarTexture(absorbTexKey)
                    arTex:SetTexture(path)
                    arTex:SetHorizTile(false)
                    arTex:SetVertTile(false)
                    if absorbBar._overlay then absorbBar._overlay:Hide() end
                else
                    arTex:SetTexture(7539076, "REPEAT", "REPEAT")
                    arTex:SetHorizTile(true)
                    arTex:SetVertTile(true)
                    if absorbBar._overlay then absorbBar._overlay:Show() end
                end
            end
            frame._oufAbsorbTexKey = absorbTexKey
        end
        -- Base color
        if ab.useCustomAbsorbColor then
            local bc = ab.absorbBaseColor
            if bc then
                absorbBar:SetStatusBarColor(bc.r, bc.g, bc.b, bc.a or 1)
            else
                absorbBar:SetStatusBarColor(0.941, 0.941, 0.937, 1.0)
            end
        else
            absorbBar:SetStatusBarColor(0.941, 0.941, 0.937, 1.0)
        end
        -- Overlay color
        if absorbBar._overlay and absorbBar._overlay:IsShown() then
            if ab.useCustomAbsorbColor then
                local oc = ab.absorbOverlayColor
                if oc then
                    absorbBar._overlay:SetVertexColor(oc.r, oc.g, oc.b, oc.a or 1)
                else
                    absorbBar._overlay:SetVertexColor(1, 1, 1, 0.66)
                end
            else
                absorbBar._overlay:SetVertexColor(1, 1, 1, 0.66)
            end
        end
        -- Background color
        if absorbBar._bg then
            if hp and hp.useCustomBackgroundColor then
                local bgc = hp.backgroundColor or { r = 0, g = 0, b = 0 }
                absorbBar._bg:SetColorTexture(bgc.r, bgc.g, bgc.b, 1)
            else
                absorbBar._bg:SetColorTexture(0, 0, 0, 1)
            end
        end
    end

    -- ---- Overshield style -------------------------------------------
    local ovStyle          = ab.overshieldStyle or "Overlay"
    local ovAnchor         = ab.overshieldAnchor or "RIGHT"
    local overshieldActive = BF:IsOvershieldActive(ab)
    frame._oufAbsorbCfg_ovStyle          = ovStyle
    frame._oufAbsorbCfg_ovAnchor         = ovAnchor
    frame._oufAbsorbCfg_overshieldActive = overshieldActive

    -- Overlay LEFT mode: absorb bar is redundant
    frame._oufAbsorbCfg_hideAbsorbInOverlayLeft =
        (ovStyle ~= "Glow" and overshieldActive and ovAnchor == "LEFT")

    local overshieldBar  = frame._oufOvershieldBar
    local overshieldGlow = frame._oufOvershieldGlow
    if not overshieldActive then
        if overshieldBar  then overshieldBar:Hide() end
        if overshieldGlow then overshieldGlow:SetAlpha(0) end
    elseif ovStyle == "Glow" then
        if overshieldBar then overshieldBar:Hide() end
        -- Glow geometry — Blizzard overAbsorbGlow parity (see the creation
        -- site): 16 wide, full bar height via top+bottom anchors, straddling
        -- the bar edge 7px in. LEFT mirrors the geometry and flips the art
        -- via the legacy file + texcoord flip (SetTexCoord would override an
        -- atlas's coords; switching back to RIGHT re-establishes them
        -- through SetAtlas). Same logic as Indicators/AbsorbBars.lua.
        if overshieldGlow then
            local t = frame._oufOvershieldGlowTex
            overshieldGlow:ClearAllPoints()
            overshieldGlow:SetWidth(16)
            if ovAnchor == "LEFT" then
                overshieldGlow:SetPoint("TOPRIGHT", Health, "TOPLEFT", 7, 0)
                overshieldGlow:SetPoint("BOTTOMRIGHT", Health, "BOTTOMLEFT", 7, 0)
                if t then
                    t:SetTexture("Interface\\RaidFrame\\Shield-Overshield")
                    t:SetTexCoord(1, 0, 0, 1)
                end
            else
                overshieldGlow:SetPoint("TOPLEFT", Health, "TOPRIGHT", -7, 0)
                overshieldGlow:SetPoint("BOTTOMLEFT", Health, "BOTTOMRIGHT", -7, 0)
                if t then
                    t:SetAtlas("RaidFrame-Shield-Overshield", false)
                end
            end
        end
    else
        -- Overlay style
        if overshieldGlow then overshieldGlow:SetAlpha(0) end
        if overshieldBar then
            overshieldBar:SetReverseFill(ovAnchor == "RIGHT")
            -- Texture
            local ovTexKey = (ab.useCustomOvershieldBarTexture and ab.overshieldBarTexture) or "_default"
            if frame._oufOvershieldTexKey ~= ovTexKey then
                local otTex = overshieldBar:GetStatusBarTexture()
                if otTex then
                    if ovTexKey ~= "_default" and self.ResolveBarTexture then
                        local path = self:ResolveBarTexture(ovTexKey)
                        otTex:SetTexture(path)
                        otTex:SetHorizTile(false)
                        otTex:SetVertTile(false)
                        if overshieldBar._overlay then overshieldBar._overlay:Hide() end
                    else
                        otTex:SetTexture(7539076, "REPEAT", "REPEAT")
                        otTex:SetHorizTile(true)
                        otTex:SetVertTile(true)
                        if overshieldBar._overlay then overshieldBar._overlay:Show() end
                    end
                end
                frame._oufOvershieldTexKey = ovTexKey
            end
            -- Base color
            if ab.useCustomOvershieldColor then
                local obc = ab.overshieldBaseColor
                if obc then
                    overshieldBar:SetStatusBarColor(obc.r, obc.g, obc.b, obc.a or 1)
                else
                    overshieldBar:SetStatusBarColor(0.937, 0.941, 0.855, 0.36)
                end
            else
                overshieldBar:SetStatusBarColor(0.937, 0.941, 0.855, 0.36)
            end
            -- Overlay color
            if overshieldBar._overlay and overshieldBar._overlay:IsShown() then
                if ab.useCustomOvershieldColor then
                    local ooc = ab.overshieldOverlayColor
                    if ooc then
                        overshieldBar._overlay:SetVertexColor(ooc.r, ooc.g, ooc.b, ooc.a or 1)
                    else
                        overshieldBar._overlay:SetVertexColor(1, 1, 1, 0.66)
                    end
                else
                    overshieldBar._overlay:SetVertexColor(1, 1, 1, 0.66)
                end
            end
        end
    end

    -- ---- Heal Absorb style ------------------------------------------
    local healAbsorbBar   = frame._oufHealAbsorb
    local healAbsorbStrip = frame._oufHealAbsorbStrip
    -- Absorb left shadow: independent of the custom-texture toggle.
    frame._oufAbsorbCfg_showShadow = ab.showAbsorbShadow ~= false
    if frame._oufAbsorbBar and frame._oufAbsorbBar._leftShadow then
        local sc = ab.absorbShadowColor
        frame._oufAbsorbBar._leftShadow:SetVertexColor(
            sc and sc.r or 1, sc and sc.g or 1, sc and sc.b or 1, sc and sc.a or 1)
        if not frame._oufAbsorbCfg_showShadow then
            frame._oufAbsorbBar._leftShadow:Hide()
        end
    end

    frame._oufAbsorbCfg_showHealAbsorb = ab.showHealAbsorb and true or false
    frame._oufAbsorbCfg_healAbsorbStyle = ab.healAbsorbStyle or "Overlay"

    if ab.showHealAbsorb then
        local style = frame._oufAbsorbCfg_healAbsorbStyle
        -- v93: custom heal-absorb fill texture (base fill only; the plus
        -- overlay and right shadow keep their own art).
        local haCustomTex = ab.useCustomHealAbsorbTexture
            and self:ResolveBarTexture(ab.healAbsorbTexture or "Solid") or nil
        -- v93: plus-symbol tint (see the twin note in AbsorbBars).
        local hsc = (ab.useCustomHealAbsorbSymbolColor and ab.healAbsorbSymbolColor)
            or { r = 1, g = 1, b = 1, a = 0.2 }
        if style == "Bar" or style == "BarBlizzard" then
            if healAbsorbStrip then
                local barH = math.min(ab.healAbsorbBarHeight or 12, Health:GetHeight() or 40)
                healAbsorbStrip:SetHeight(math.max(barH, 1))
                local tex = healAbsorbStrip:GetStatusBarTexture()
                if style == "BarBlizzard" then
                    if tex then
                        tex:SetTexture(haCustomTex or 7539017)
                        if haCustomTex then
                            tex:SetHorizTile(false)
                            tex:SetVertTile(false)
                        end
                        BF:DisablePixelSnapRegion(tex)
                        tex:SetBlendMode("BLEND")
                    end
                    local c = ab.healAbsorbColor
                    if c then
                        healAbsorbStrip:SetStatusBarColor(c.r, c.g, c.b, c.a or 1)
                    else
                        healAbsorbStrip:SetStatusBarColor(1, 1, 1, 1)
                    end
                    if healAbsorbStrip._overlay then
                        healAbsorbStrip._overlay:SetVertexColor(hsc.r, hsc.g, hsc.b, hsc.a or 0.2)
                        healAbsorbStrip._overlay:Show()
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
                    local c = ab.healAbsorbColor
                    if c then
                        healAbsorbStrip:SetStatusBarColor(c.r, c.g, c.b, c.a or 0.5)
                    else
                        healAbsorbStrip:SetStatusBarColor(1, 0, 0, 0.5)
                    end
                    if healAbsorbStrip._overlay then healAbsorbStrip._overlay:Hide() end
                end
            end
        else
            -- Overlay / OverlayBlizzard
            if healAbsorbBar then
                local tex = healAbsorbBar:GetStatusBarTexture()
                if tex then
                    tex:SetTexture(haCustomTex or 7539017)
                    if haCustomTex then
                        tex:SetHorizTile(false)
                        tex:SetVertTile(false)
                    end
                    BF:DisablePixelSnapRegion(tex)
                    tex:SetBlendMode("BLEND")
                end
                local c = ab.healAbsorbColor
                if style == "OverlayBlizzard" then
                    if c then
                        healAbsorbBar:SetStatusBarColor(c.r, c.g, c.b, c.a or 1)
                    else
                        healAbsorbBar:SetStatusBarColor(1, 1, 1, 1)
                    end
                    if healAbsorbBar._overlay then
                        healAbsorbBar._overlay:SetVertexColor(hsc.r, hsc.g, hsc.b, hsc.a or 0.2)
                        healAbsorbBar._overlay:Show()
                    end
                else
                    if c then
                        healAbsorbBar:SetStatusBarColor(c.r, c.g, c.b, c.a or 1)
                    else
                        healAbsorbBar:SetStatusBarColor(1, 1, 1, 1)
                    end
                    if healAbsorbBar._overlay then healAbsorbBar._overlay:Hide() end
                end
            end
        end
    end

    -- ---- Reduced max health style -----------------------------------
    local reducedMaxBar = frame._oufReducedMaxBar
    frame._oufAbsorbCfg_showReducedMax = ab.showReducedMaxHealth and true or false
    if reducedMaxBar and ab.showReducedMaxHealth then
        if ab.useCustomReducedMaxTexture then
            local path = self:ResolveBarTexture(ab.reducedMaxHealthTexture or "Solid")
            reducedMaxBar:SetStatusBarTexture(path)
            local c = ab.reducedMaxHealthColor
            if c then
                reducedMaxBar:SetStatusBarColor(c.r, c.g, c.b, c.a or 0.8)
            else
                reducedMaxBar:SetStatusBarColor(0.3, 0.3, 0.3, 0.8)
            end
        else
            -- Blizzard parity -- see the matching note in
            -- Indicators/AbsorbBars.lua _UpdateReducedMaxHealth.
            local tex = reducedMaxBar:GetStatusBarTexture()
            if tex then
                tex:SetAtlas("raidframe-MaximumHealthReduction-Overlay", false)
                tex:SetHorizTile(true)
                tex:SetVertTile(true)
            end
            reducedMaxBar:SetStatusBarColor(1, 1, 1, 1)
        end
    end
end

-- ============================================================
-- _OUFUpdateReducedMax
-- Reduced max health (player + friendly target/focus only).
-- v98: split out of _OUFAbsorbPostUpdate. Same evaluation points as the
-- raid frames (Indicators/AbsorbBars.lua _UpdateReducedMaxHealth): unit
-- change, UNIT_MAX_HEALTH_MODIFIERS_CHANGED, and a layout pass -- never a
-- health tick. isDead is passed in so the two callers that already hold
-- it do not read it twice.
-- ============================================================
function BF:_OUFUpdateReducedMax(frame, unit, isDead)
    if not unit or not UnitExists(unit) then return end
    local reducedMaxBar = frame._oufReducedMaxBar
    if reducedMaxBar then
        local ufKey = frame._bf_ufKey or frame.__unit
        local friendlyAllowed = (ufKey == "player")
            or ((ufKey == "target" or ufKey == "focus")
                and not UnitCanAttack("player", unit))

        if not (friendlyAllowed and frame._oufAbsorbCfg_showReducedMax) or isDead then
            reducedMaxBar:Hide()
            frame._oufReducedMaxPct = nil
            RestoreHealthBarAnchors(frame)
        else
            local pct
            if GetUnitTotalModifiedMaxHealthPercent then
                pct = GetUnitTotalModifiedMaxHealthPercent(unit)
            end

            -- v98 (owner report 2026-09-06): after a disconnect/relog the
            -- player frame's whole health rect -- fill AND background --
            -- was gone until a /reload, with the rest of the frame intact.
            -- This clip is the only thing in the addon that can do that.
            -- The raid frames run the same clip through the same API and
            -- were fine on the same login; the differences were that this
            -- path anchored the clip once behind an _oufReducedMaxActive
            -- early-out, and ran on every health tick. Now identical to
            -- the raid path: `not pct` hides and restores, the value goes
            -- to the widget untouched (secret-safe -- no compare, no
            -- clamp), and the anchors are re-asserted on every call.
            if not pct then
                reducedMaxBar:Hide()
                frame._oufReducedMaxPct = nil
                RestoreHealthBarAnchors(frame)
            else
                reducedMaxBar:SetMinMaxValues(0, 1)
                reducedMaxBar:SetValue(pct)
                reducedMaxBar:Show()

                local clip      = frame._oufHealthClipFrame
                local container = frame._oufHealthContainer
                local reducedTex = reducedMaxBar:GetStatusBarTexture()
                if clip and container and reducedTex then
                    clip:ClearAllPoints()
                    clip:SetPoint("TOPLEFT",     container,  "TOPLEFT")
                    clip:SetPoint("BOTTOMLEFT",  container,  "BOTTOMLEFT")
                    clip:SetPoint("TOPRIGHT",    reducedTex, "TOPLEFT")
                    clip:SetPoint("BOTTOMRIGHT", reducedTex, "BOTTOMLEFT")
                    frame._oufReducedMaxActive = true
                end

                frame._oufReducedMaxPct = pct
            end
        end
    end
end

-- Frame event handler (registered per oUF frame in SetupOUFAbsorbs;
-- oUF filters the unit for us, the __unit check is the same belt the
-- element's own Update wears).
function BF._OUFReducedMaxEvent(frame, _, unit)
    if frame.__unit ~= unit then return end
    BF:_OUFUpdateReducedMax(frame, unit, UnitIsDeadOrGhost(unit))
end

-- ============================================================
-- _OUFAbsorbPostUpdate
-- Called by oUF after HealthPrediction:Update.  Per-event
-- dynamic work only — all settings were precomputed by
-- _ApplyOUFAbsorbStyle.
-- ============================================================
function BF:_OUFAbsorbPostUpdate(frame, unit, element)
    local ab = frame._oufAbsorbCfg_ab
    if not ab then return end
    if not unit or not UnitExists(unit) then return end

    local Health  = frame.Health
    local hBarTex = Health and Health:GetStatusBarTexture()
    local isDead  = UnitIsDeadOrGhost(unit)

    -- ---- Heal Prediction --------------------------------------------
    local healPred = frame._oufHealPred
    if healPred then
        if frame._oufAbsorbCfg_showHealPred and not isDead then
            healPred:Show()
        else
            healPred:Hide()
        end
    end

    -- ---- Damage absorb (missing health gap) -------------------------
    local absorbBar = frame._oufAbsorbBar
    if absorbBar then
        if isDead or frame._oufAbsorbCfg_hideAbsorbInOverlayLeft then
            absorbBar:Hide()
        else
            -- oUF already set MinMaxValues and Value via element.values
            absorbBar:Show()
            -- Left shadow: static geometry, alpha-gated on the absorb amount.
            -- Secret on 12.1, so SetAlphaFromBoolean rather than a compare.
            local ls = absorbBar._leftShadow
            if ls and frame._oufAbsorbCfg_showShadow then
                ls:Show()
                ls:SetAlphaFromBoolean(element.values:GetDamageAbsorbs(), 1, 0)
            end
        end
    end

    -- ---- Overshield -------------------------------------------------
    local overshieldActive = frame._oufAbsorbCfg_overshieldActive
    local overshieldBar    = frame._oufOvershieldBar
    local overshieldGlow   = frame._oufOvershieldGlow

    if not overshieldActive or isDead then
        if overshieldBar  then overshieldBar:Hide() end
        if overshieldGlow then overshieldGlow:SetAlpha(0) end
    else
        local _, r2 = element.values:GetDamageAbsorbs()

        if frame._oufAbsorbCfg_ovStyle == "Glow" then
            -- PERF: Glow mode never uses the clamp-mode-2 calculator's
            -- result — only the r2 boolean fetched above — so the second
            -- UnitGetDetailedHealPrediction engine calc per element update
            -- now runs only in Overlay mode (below).
            if overshieldGlow then
                overshieldGlow:SetAlphaFromBoolean(r2, 1, 0)
            end
        else
            if overshieldBar then
                local maxHealth = UnitHealthMax(unit)
                UnitGetDetailedHealPrediction(unit, "player", _overshieldCalc)
                local ovAbsorbed = _overshieldCalc:GetDamageAbsorbs()
                overshieldBar:Show()
                if frame._oufAbsorbCfg_ovAnchor == "LEFT" then
                    overshieldBar:SetAlpha(1)
                else
                    overshieldBar:SetAlphaFromBoolean(r2, 1, 0)
                end
                overshieldBar:SetMinMaxValues(0, maxHealth)
                overshieldBar:SetValue(ovAbsorbed)
            end
        end
    end

    -- ---- Heal Absorb ------------------------------------------------
    local healAbsorbBar   = frame._oufHealAbsorb
    local healAbsorbStrip = frame._oufHealAbsorbStrip

    -- Reset both styles first
    if healAbsorbBar   then healAbsorbBar:SetAlpha(0) end
    if healAbsorbStrip then healAbsorbStrip:SetAlpha(0) end
    if healAbsorbBar and healAbsorbBar._shadow then healAbsorbBar._shadow:Hide() end

    if frame._oufAbsorbCfg_showHealAbsorb and not isDead then
        local maxHealth     = UnitHealthMax(unit)
        local healAbsorbAmt = UnitGetTotalHealAbsorbs(unit)
        if healAbsorbAmt and maxHealth then
            local style = frame._oufAbsorbCfg_healAbsorbStyle

            if style == "Bar" or style == "BarBlizzard" then
                if healAbsorbStrip then
                    healAbsorbStrip:SetMinMaxValues(0, maxHealth)
                    healAbsorbStrip:SetValue(healAbsorbAmt)
                    healAbsorbStrip:SetAlpha(1)
                end
            else
                if healAbsorbBar then
                    -- PERF (lazy anchor guard): the reverse-fill anchors target
                    -- the health fill texture OBJECT and the bar width — stable
                    -- until a layout pass, which clears _bfAnchorTex
                    -- (ApplyOUFAbsorbLayout) so the next event re-stamps with
                    -- settled geometry. The guard also self-heals if the fill
                    -- object is ever replaced (reference compare; object
                    -- handles are never secret values). Steady state: one
                    -- compare instead of ClearAllPoints + 2 SetPoints +
                    -- SetWidth + the shadow's SetAllPoints per element update.
                    local tex = healAbsorbBar:GetStatusBarTexture()
                    if hBarTex and healAbsorbBar._bfAnchorTex ~= hBarTex then
                        healAbsorbBar._bfAnchorTex = hBarTex
                        healAbsorbBar:ClearAllPoints()
                        healAbsorbBar:SetPoint("TOPRIGHT",    hBarTex, "TOPRIGHT")
                        healAbsorbBar:SetPoint("BOTTOMRIGHT", hBarTex, "BOTTOMRIGHT")
                        healAbsorbBar:SetWidth(Health:GetWidth())
                        -- Right shadow tracks the heal-absorb's own fill;
                        -- re-pin it on the same edge for the same reason.
                        if healAbsorbBar._shadow and tex then
                            healAbsorbBar._shadow:ClearAllPoints()
                            healAbsorbBar._shadow:SetAllPoints(tex)
                        end
                    end
                    if healAbsorbBar._shadow then
                        healAbsorbBar._shadow:Show()
                    end
                    healAbsorbBar:SetMinMaxValues(0, maxHealth)
                    healAbsorbBar:SetValue(healAbsorbAmt)
                    healAbsorbBar:SetAlpha(1)
                end
            end
        end
    end

    -- ---- Reduced max health ------------------------------------------
    -- v98: OFF the per-event path (raid parity -- Indicators/AbsorbBars.lua
    -- "_UpdateReducedMaxHealth removed from here"). Re-derived only when
    -- the frame's unit identity may have changed: _bf_ufGen is bumped by
    -- frame.PreUpdate on every UpdateAllElements (target/focus swap,
    -- ForceUpdate, first paint). UNIT_MAX_HEALTH_MODIFIERS_CHANGED has its
    -- own handler (SetupOUFAbsorbs), and a layout pass re-derives it in
    -- ApplyOUFAbsorbLayout. Health ticks cost one field compare here.
    if frame._bf_absorbRmGen ~= frame._bf_ufGen then
        frame._bf_absorbRmGen = frame._bf_ufGen
        self:_OUFUpdateReducedMax(frame, unit, isDead)
    end
end

-- ============================================================
-- ApplyOUFAbsorbLayout
-- Called from _ApplyOUFPlayerLayout / _ApplyOUFRightFrameLayout
-- after bar sizes may have changed.  Re-anchors absorb widgets
-- to the health bar fill texture.
-- ============================================================
function BF:ApplyOUFAbsorbLayout(frame)
    if not frame then return end
    local Health  = frame.Health
    if not Health then return end
    local hBarTex = Health:GetStatusBarTexture()
    if not hBarTex then return end

    local barW = Health:GetWidth()

    if frame._oufHealPred then
        frame._oufHealPred:ClearAllPoints()
        frame._oufHealPred:SetPoint("TOPLEFT",    hBarTex, "TOPRIGHT")
        frame._oufHealPred:SetPoint("BOTTOMLEFT", hBarTex, "BOTTOMRIGHT")
        frame._oufHealPred:SetWidth(barW)
    end

    if frame._oufAbsorbBar then
        frame._oufAbsorbBar:ClearAllPoints()
        frame._oufAbsorbBar:SetPoint("TOPLEFT",    hBarTex, "TOPRIGHT")
        frame._oufAbsorbBar:SetPoint("BOTTOMLEFT", hBarTex, "BOTTOMRIGHT")
        frame._oufAbsorbBar:SetWidth(barW)
    end

    -- Heal-absorb overlay anchors: INVALIDATE here, stamp LAZILY in
    -- _OUFAbsorbPostUpdate. A direct layout-time stamp was tried and reverted
    -- (owner-reported: overlay painted over the frame border and text) —
    -- during a build/resize pass this function can run BEFORE the health
    -- bar's final size lands, so the captured width/edges were stale and
    -- nothing ever corrected them. Clearing the guard here instead makes the
    -- NEXT element update — which always runs after geometry has settled —
    -- re-anchor once with live values, and every event after that is a single
    -- reference compare. Same lazy idiom as the raid frames' _healPredAnchor.
    if frame._oufHealAbsorb then
        frame._oufHealAbsorb._bfAnchorTex = nil
    end

    if frame._oufOvershieldGlow then
        local h = math.floor(Health:GetHeight() * 0.9 + 0.5)
        frame._oufOvershieldGlow:ClearAllPoints()
        frame._oufOvershieldGlow:SetPoint("RIGHT", Health, "RIGHT", 0, 0)
        frame._oufOvershieldGlow:SetSize(3, h)
    end

    if frame._oufAbsorbClip then
        frame._oufAbsorbClip:ClearAllPoints()
        frame._oufAbsorbClip:SetAllPoints(Health)
    end

    -- Reset reduced-max clipping. If we are mid-reduced-max, the clipFrame
    -- currently has explicit TOPRIGHT/BOTTOMRIGHT points anchored to the old
    -- reducedMaxBar fill texture — which is stale now that the layout has
    -- resized/reanchored the healthContainer. Restore the clipFrame to
    -- follow the container, then let the next PostUpdate re-apply the
    -- clipping (pct, color, texture, clipFrame right-edge) from scratch.
    if frame._oufHealthClipFrame and frame._oufHealthContainer then
        frame._oufHealthClipFrame:ClearAllPoints()
        frame._oufHealthClipFrame:SetAllPoints(frame._oufHealthContainer)
    end
    frame._oufReducedMaxActive = nil

    -- Invalidate texture caches so _ApplyOUFAbsorbStyle re-resolves them.
    frame._oufAbsorbTexKey     = nil
    frame._oufOvershieldTexKey = nil
    frame._oufHealPredTexKey   = nil

    -- Precompute all settings-derived absorb state (Grid2 pattern).
    self:_ApplyOUFAbsorbStyle(frame)

    -- v98: reduced-max no longer rides the per-event path, so re-derive it
    -- here (raid parity: RefreshReducedMaxHealth after assignment) -- the
    -- clip was just reset to the container above. Anchors are relative
    -- (container / reduced fill texture), so nothing here captures a
    -- not-yet-settled size.
    local unit = frame.__unit
    if unit and frame._oufReducedMaxBar then
        self:_OUFUpdateReducedMax(frame, unit, UnitIsDeadOrGhost(unit))
    end
end

-- ============================================================
-- _RefreshAllOUFAbsorbs
-- Forces every oUF unit frame's HealthPrediction element to
-- re-run its full Update → PostUpdate cycle, which re-resolves
-- the absorb profile and repaints heal prediction, damage absorb,
-- overshield, heal absorb, and reduced-max-health.
--
-- Called by:
--   - Core_Refresh.lua RefreshAllAbsorbs / RefreshAllHealAbsorbs /
--     RefreshAllHealPrediction (when a shared absorbs setting changes)
--   - Options_Absorbs.lua reduced-max setters
--   - ApplyProfile.lua (on raid↔party context flip, so active-context
--     routing picks up the new flat's absorbs sub-table)
--
-- Mirrors the _RefreshAllOUFPowerColors pattern.
-- ============================================================
function BF:_RefreshAllOUFAbsorbs()
    local frames = {
        self.oufPlayer,
        self.oufTarget,
        self.oufFocus,
        self.oufPet,
        self.oufTargetOfTarget,
        self.oufFocusTarget,
    }
    if self.oufBoss then
        for i = 1, 5 do
            if self.oufBoss[i] then frames[#frames+1] = self.oufBoss[i] end
        end
    end
    for _, f in ipairs(frames) do
        if f then
            -- Reapply settings-derived state before the event-driven update.
            self:_ApplyOUFAbsorbStyle(f)
            if f.HealthPrediction and f.HealthPrediction.ForceUpdate then
                f.HealthPrediction:ForceUpdate()
            end
            -- v98: element ForceUpdate does not bump _bf_ufGen, so the
            -- reduced-max setters need this explicit re-derive.
            if f.__unit and f._oufReducedMaxBar then
                self:_OUFUpdateReducedMax(f, f.__unit, UnitIsDeadOrGhost(f.__unit))
            end
        end
    end
end
