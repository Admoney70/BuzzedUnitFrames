-- ============================================================
-- BuzzardFrames: UnitFrames/SetupMode_UnitFrames.lua
-- Setup-mode test/preview frames for unit frame positioning.
-- Extracted from SetupMode.lua to keep the UnitFrames module
-- self-contained. All profile reads use BF.ufDB.profile
-- (the UnitFrames namespace).
-- ============================================================
local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

-- ============================================================
-- UNIT FRAME TEST FRAMES  (setup-mode positioning frames)
-- Semi-transparent frames shown for each enabled unit frame
-- when setup mode is active. Dragging saves position to the active
-- UF layout's group-type sub-table via SetUFAnchor.
-- ============================================================

-- Map unit keys to their enable profile keys.
local UF_ENABLE_KEYS = {
    player             = "showPlayerFrame",
    target             = "showTargetFrame",
    focus              = "showFocusFrame",
    pet                = "showPetFrame",
    targettarget       = "showTargetOfTargetFrame",
    focustarget        = "showFocusTargetFrame",
    playerPowerBar     = "showPlayerFrame",
    playerResourceBar  = "showPlayerFrame",
    playerAltPowerBar = "showPlayerFrame",
    targetCastbar      = "showTargetFrame",
    focusCastbar       = "showFocusFrame",
    icPlayerFrame      = "incomingCastsEnabled",  -- checked via UF_ENABLE_RESOLVE below
    boss               = "showBossFrames",
}

-- Map unit keys to BF field names for the real oUF frames.
local UF_REAL_FRAMES = {
    player             = "oufPlayer",
    target             = "oufTarget",
    focus              = "oufFocus",
    pet                = "oufPet",
    targettarget       = "oufTargetOfTarget",
    focustarget        = "oufFocusTarget",
    playerPowerBar     = "oufDetachedPowerBar",
    playerResourceBar  = "oufResourceBar",
    playerAltPowerBar = "oufAltPowerBar",
    -- targetCastbar/focusCastbar/icPlayerFrame use special handling below
    boss               = "oufBoss",
}

local UF_TEST_FRAME_DEFS = {
    player             = { label = "Player",            anchorStyle = "topleft" },
    target             = { label = "Target",            anchorStyle = "topleft" },
    focus              = { label = "Focus",             anchorStyle = "topleft" },
    pet                = { label = "Pet",               anchorStyle = "topleft" },
    targettarget       = { label = "Target of Target",  anchorStyle = "topleft" },
    focustarget        = { label = "Focus Target",      anchorStyle = "topleft" },
    playerPowerBar     = { label = "Power Bar",         anchorStyle = "center" },
    playerResourceBar  = { label = "Resource Bar",      anchorStyle = "center" },
    playerAltPowerBar = { label = "Alt Power Bar",        anchorStyle = "center" },
    targetCastbar      = { label = "Target Cast Bar",   anchorStyle = "topleft" },
    focusCastbar       = { label = "Focus Cast Bar",    anchorStyle = "topleft" },
    -- Incoming Casts: the saved coords are UIParent-CENTER relative (that
    -- is how the mover anchor and its drag handler store them), but the
    -- real cast bars are laid out with m = { point = "TOPLEFT" } against a
    -- 1x1 anchor, i.e. the chain's TOP-LEFT sits on the anchor point and
    -- grows right/down -- and the Unlock-mode drag handle likewise sits
    -- above the anchor's TOPLEFT. Centring the overlay on that point put
    -- it half its width to the LEFT of where casts actually appear, so the
    -- handle and the Setup Mode box disagreed. frameOrigin keeps the
    -- coordinate space ("center") while anchoring the overlay by its
    -- top-left, matching reality.
    icPlayerFrame      = { label = "Incoming Casts",    anchorStyle = "center",
                           frameOrigin = function()
                               local IC = BF.IncomingCasts
                               return (IC and IC.GetPlayerStackOrigin)
                                      and IC:GetPlayerStackOrigin() or "TOPLEFT"
                           end },
    boss               = { label = "Boss Frames",       anchorStyle = "topleft" },
}

-- ── Raid-style twins ────────────────────────────────────────────────────────
-- When a unit's twin is active (UnitFrames/Twins.lua) its oUF frame is
-- driver-hidden and the raid-style twin occupies that spot instead, so the
-- overlay has to describe the twin -- otherwise setup mode draws a box for a
-- frame that is not on screen. Only these four keys have twins; the bars and
-- cast bars keep their own boxes.
local TWIN_UF_KEY = {
    player = "player",
    target = "target",
    focus  = "focus",
    boss   = "boss",
}

-- Twin width/height in on-screen UI units, or nil when no twin is active.
local function ActiveTwinSize(unitKey)
    local ufKey = TWIN_UF_KEY[unitKey]
    if not ufKey then return nil end
    if not (BF.IsTwinActive and BF:IsTwinActive(ufKey)) then return nil end
    if not BF.GetTwinFrameSize then return nil end
    return BF:GetTwinFrameSize(ufKey)
end

-- Returns the visual size of a unit frame for the test frame.
local function GetUFTestFrameSize(unitKey)
    local p = BF.ufDB.profile
    if unitKey == "playerPowerBar" then
        local pf = p.player or {}
        return p.oufPowerBarWidth or pf.frameWidth or 156,
               p.oufPowerBarHeight or pf.powerBarHeight or 10
    elseif unitKey == "playerResourceBar" then
        local pf = p.player or {}
        return p.oufResourceBarWidth or pf.frameWidth or 156,
               p.oufResourceBarHeight or 14
    elseif unitKey == "playerAltPowerBar" then
        local pf = p.player or {}
        return p.oufAltPowerBarWidth or pf.frameWidth or 156,
               p.altPowerBarHeight or 3
    elseif unitKey == "targetCastbar" then
        local pf = p.target or {}
        return p.targetCastBarWidth or pf.frameWidth or 156,
               p.targetCastBarHeight or 14
    elseif unitKey == "focusCastbar" then
        local pf = p.focus or {}
        return p.focusCastBarWidth or pf.frameWidth or 156,
               p.focusCastBarHeight or 14
    elseif unitKey == "icPlayerFrame" then
        local ic = (BF.icDB and BF.icDB.profile) or {}
        -- icPlayerFrame is the DETACHED display, so its geometry comes from
        -- the incomingCastsPlayer* keys -- matching the spacing, grow
        -- direction and anchor reads further down this same branch.
        --
        -- Before the per-display split the two displays shared one set of
        -- keys, so these three read the unprefixed names and were still
        -- correct. Afterwards they silently sized the overlay from the PARTY
        -- display's bar, so editing the detached bar width or height did not
        -- resize it at all. Fallbacks match Defaults_IncomingCasts (12 / 20);
        -- they previously read 14 / 24, which matched nothing.
        local isCB = (ic.incomingCastsPlayerDisplayType or "castbar") == "castbar"
        local fw = isCB and (ic.incomingCastsPlayerBarWidth  or 80)
                        or  (ic.incomingCastsPlayerIconSize  or 20)
        local fh = isCB and (ic.incomingCastsPlayerBarHeight or 12)
                        or  (ic.incomingCastsPlayerIconSize  or 20)
        -- Icon reserve must match what IC:ApplyCastBarStyle actually
        -- anchors, or the Setup Mode overlay misrepresents the real
        -- footprint. Was hardcoded fh + 1 (icon always on, 1px gap).
        local totalW = fw
        if isCB then
            local IC = BF.IncomingCasts
            if IC and IC.GetCastBarIconMetrics then
                -- "player" = the detached display, same as above.
                local _, reserve = IC:GetCastBarIconMetrics(fh, "player")
                totalW = totalW + reserve
            else
                totalW = totalW + fh + 1
            end
        end
        local sp = ic.incomingCastsPlayerSpacing or 2
        local growDir = ic.incomingCastsPlayerGrowDirection or "DOWN"
        local count = 3
        if growDir == "LEFT" or growDir == "RIGHT" then
            return totalW * count + sp * (count - 1), fh
        else
            return totalW, fh * count + sp * (count - 1)
        end
    elseif unitKey == "boss" then
        local pf = p.boss or {}
        local growDir = p.bossGrowDirection or "DOWN"
        -- One source for the slot pitch (oUF_BossFrames.lua GetBossSlotSpan):
        -- the oUF frame plus its aura rows / cast bar, or the twin plus the
        -- reserve of the neighbor it grows into, whichever is larger.
        local bScale = pf.frameScale or 1.0
        local twinW, twinH, twinS = ActiveTwinSize("boss")
        local slotH = BF:GetBossSlotSpan(p, pf, false, twinH, bScale, twinS)
        local slotW = BF:GetBossSlotSpan(p, pf, true,  twinW, bScale, twinS)
        local gap = p.bossFrameSpacing or 4
        if growDir == "LEFT" or growDir == "RIGHT" then
            return slotW * 5 + gap * 4, slotH
        else
            return slotW, slotH * 5 + gap * 4
        end
    else
        -- Twin active: the oUF frame is hidden, so measure the twin instead.
        -- Returned in on-screen units; ShowUFTestFrames drops the frame scale
        -- to 1 for these so the box lands at the twin's real size.
        local tw, th = ActiveTwinSize(unitKey)
        if tw and th then return tw, th end
        local pf = p[unitKey] or p.player or {}
        local w = pf.frameWidth or 156
        local nameH   = pf.nameBarHeight   or 13
        -- v91: the player's health band carries the alt power bar's reserved
        -- strip, so the test frame has to use the same number the real frame
        -- does or the setup-mode ghost sits short of it. Other units are
        -- unaffected -- the helper reserves nothing for them.
        local healthH = (unitKey == "player" and BF.GetOUFPlayerHealthBandHeight)
            and BF:GetOUFPlayerHealthBandHeight()
            or (pf.healthBarHeight or 22)
        local powerH  = pf.powerBarHeight  or 10
        return w, nameH + healthH + powerH
    end
end

-- Returns the default anchor position for a unit frame test frame
-- when no position is saved in the layout.
local function GetUFTestFrameDefaultAnchor(unitKey)
    local p = BF.ufDB.profile
    if unitKey == "playerPowerBar" then
        return p.oufPowerBarAnchorX or -400, p.oufPowerBarAnchorY or -340
    elseif unitKey == "playerResourceBar" then
        return p.oufResourceBarAnchorX or 2, p.oufResourceBarAnchorY or -100
    elseif unitKey == "playerAltPowerBar" then
        local ancX, ancY = BF:GetUFAnchor("playerAltPowerBar")
        return ancX or -400, ancY or -320
    elseif unitKey == "targetCastbar" then
        return p.targetCastBarAnchorX or 0, p.targetCastBarAnchorY or 0
    elseif unitKey == "focusCastbar" then
        return p.focusCastBarAnchorX or 0, p.focusCastBarAnchorY or 0
    elseif unitKey == "icPlayerFrame" then
        local ic = (BF.icDB and BF.icDB.profile) or {}
        return ic.incomingCastsPlayerAnchorX or 0, ic.incomingCastsPlayerAnchorY or -200
    else
        local pf = p[unitKey] or {}
        local defaults = {
            player       = { 660,  420 },
            target       = { 1315, 420 },
            focus        = { 1340, 530 },
            pet          = { 690,  370 },
            targettarget = { 1500, 420 },
            focustarget  = { 1450, 530 },
            boss         = { 1475, 500 },
        }
        local d = defaults[unitKey] or { 600, 400 }
        return pf.anchorX or d[1], pf.anchorY or d[2]
    end
end

-- Detached-only unit keys: test frame only shown when the bar is detached.
local UF_DETACH_CHECK = {
    playerPowerBar     = function(p) return BF:GetUFDetachState("playerPowerBar") end,
    playerResourceBar  = function(p) return BF:GetUFDetachState("playerResourceBar") end,
    playerAltPowerBar = function(p) return p.altPowerBarDetached end,
    targetCastbar      = function(p) return p.targetCastBarDetached == true end,
    focusCastbar       = function(p) return p.focusCastBarDetached == true end,
    icPlayerFrame      = function(p)
        local ic = BF.icDB and BF.icDB.profile
        return ic and ic.incomingCastsShowOnPlayerFrame
    end,
}

-- Unit keys that use center-based anchoring (don't apply frame scale).
local UF_CENTER_KEYS = {
    playerPowerBar = true, playerResourceBar = true, playerAltPowerBar = true,
    targetCastbar = true, focusCastbar = true, icPlayerFrame = true,
}

function BF:CreateUFTestFrames()
    if self._ufTestFrames then return end
    self._ufTestFrames = {}

    for unitKey, def in pairs(UF_TEST_FRAME_DEFS) do
        local anchor = CreateFrame("Frame", nil, UIParent)
        anchor:SetSize(1, 1)
        anchor:SetFrameStrata("HIGH")
        anchor:SetFrameLevel(99)
        anchor:SetMovable(true)
        anchor:SetClampedToScreen(true)
        anchor:EnableMouse(false)

        local tf = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
        tf:SetFrameStrata("HIGH")
        tf:SetFrameLevel(100)
        tf:SetBackdrop({
            bgFile   = "Interface\\Buttons\\White8x8",
            edgeFile = "Interface\\Buttons\\White8x8",
            edgeSize = 1,
        })
        local ufBgR, ufBgG, ufBgB, ufBgA, ufBrR, ufBrG, ufBrB, ufBrA = BF.GetSetupFrameColors()
        tf:SetBackdropColor(ufBgR, ufBgG, ufBgB, ufBgA)
        tf:SetBackdropBorderColor(ufBrR, ufBrG, ufBrB, ufBrA)
        tf:EnableMouse(true)
        tf:SetMovable(false)
        tf:RegisterForDrag("LeftButton")
        tf:Hide()

        local label = tf:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetPoint("CENTER")
        label:SetText(def.label)
        label:SetTextColor(1, 1, 1, 0.9)
        tf._label = label
        tf._unitKey = unitKey
        tf._anchorStyle = def.anchorStyle
        -- Optional: which of the overlay's own corners sits on the anchor
        -- point. Defaults to matching anchorStyle. See the icPlayerFrame
        -- entry in UF_TEST_FRAME_DEFS for why they can differ.
        tf._frameOrigin = def.frameOrigin
        tf._anchor = anchor

        -- Helper to get the real frame for syncing during drag
        local function GetRealFrame(uk)
            if uk == "targetCastbar" then
                local f = BF.oufTarget
                return f and f.Castbar
            elseif uk == "focusCastbar" then
                local f = BF.oufFocus
                return f and f.Castbar
            elseif uk == "icPlayerFrame" then
                return BF.IncomingCasts and BF.IncomingCasts._playerAnchor
            elseif uk == "boss" then
                return BF.oufBoss and BF.oufBoss[1]
            else
                local key = UF_REAL_FRAMES[uk]
                return key and BF[key]
            end
        end

        tf:SetScript("OnDragStart", function(self)
            anchor:StartMoving()
            anchor:SetScript("OnUpdate", function()
                if InCombatLockdown() then return end
                local uk = self._unitKey
                if self._anchorStyle == "center" then
                    local cx, cy = anchor:GetCenter()
                    local ux, uy = UIParent:GetCenter()
                    if cx and ux then
                        if uk == "icPlayerFrame" then
                            local icAnc = BF.IncomingCasts and BF.IncomingCasts._playerAnchor
                            if icAnc then
                                icAnc:ClearAllPoints()
                                icAnc:SetPoint("CENTER", UIParent, "CENTER", cx - ux, cy - uy)
                            end
                        else
                            local real = (uk == "playerPowerBar" and BF.oufDetachedPowerBar)
                                      or (uk == "playerResourceBar" and BF.oufResourceBar)
                                      or (uk == "playerAltPowerBar" and BF.oufAltPowerBar)
                            if real then
                                real:ClearAllPoints()
                                real:SetPoint("CENTER", UIParent, "CENTER", cx - ux, cy - uy)
                            end
                        end
                    end
                else
                    local real = GetRealFrame(uk)
                    if real and real._anchor then
                        local al = anchor:GetLeft()
                        local at = anchor:GetTop()
                        if al and at then
                            real._anchor:ClearAllPoints()
                            real._anchor:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", al, at)
                            if real._anchor.SnapHandle then real._anchor.SnapHandle() end
                        end
                    elseif uk == "targetCastbar" or uk == "focusCastbar" then
                        -- Castbars use TOPLEFT directly, not via _anchor
                        if real then
                            local al = anchor:GetLeft()
                            local at = anchor:GetTop()
                            if al and at then
                                real:ClearAllPoints()
                                real:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", al, at)
                            end
                        end
                    end
                end
            end)
        end)
        tf:SetScript("OnDragStop", function(self)
            anchor:StopMovingOrSizing()
            anchor:SetScript("OnUpdate", nil)
            local uk = self._unitKey
            if self._anchorStyle == "center" then
                local cx, cy = anchor:GetCenter()
                local ux, uy = UIParent:GetCenter()
                if cx and cy and ux and uy then
                    local nx, ny = math.floor(cx - ux + 0.5), math.floor(cy - uy + 0.5)
                    if uk == "icPlayerFrame" then
                        local ic = BF.icDB and BF.icDB.profile
                        if ic then
                            ic.incomingCastsPlayerAnchorX = nx
                            ic.incomingCastsPlayerAnchorY = ny
                        end
                        local icAnc = BF.IncomingCasts and BF.IncomingCasts._playerAnchor
                        if icAnc then
                            icAnc:ClearAllPoints()
                            icAnc:SetPoint("CENTER", UIParent, "CENTER", nx, ny)
                        end
                    else
                        BF:SetUFAnchor(uk, nx, ny)
                        local real = (uk == "playerPowerBar" and BF.oufDetachedPowerBar)
                                  or (uk == "playerResourceBar" and BF.oufResourceBar)
                                  or (uk == "playerAltPowerBar" and BF.oufAltPowerBar)
                        if real then
                            real:ClearAllPoints()
                            real:SetPoint("CENTER", UIParent, "CENTER", nx, ny)
                        end
                    end
                end
            else
                local al = anchor:GetLeft()
                local at = anchor:GetTop()
                if al and at then
                    local nx, ny = math.floor(al + 0.5), math.floor(at + 0.5)
                    if uk == "targetCastbar" then
                        local p = BF.ufDB and BF.ufDB.profile
                        if p then
                            p.targetCastBarAnchorX = nx
                            p.targetCastBarAnchorY = ny
                            p.targetCastBarAnchorSaved = true
                        end
                        local f = BF.oufTarget
                        if f and f.Castbar then
                            f.Castbar:ClearAllPoints()
                            f.Castbar:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", nx, ny)
                        end
                    elseif uk == "focusCastbar" then
                        local p = BF.ufDB and BF.ufDB.profile
                        if p then
                            p.focusCastBarAnchorX = nx
                            p.focusCastBarAnchorY = ny
                            p.focusCastBarAnchorSaved = true
                        end
                        local f = BF.oufFocus
                        if f and f.Castbar then
                            f.Castbar:ClearAllPoints()
                            f.Castbar:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", nx, ny)
                        end
                    else
                        BF:SetUFAnchor(uk, nx, ny)
                        if uk == "boss" then
                            -- Boss frames: a full layout apply, so the
                            -- column (boss2..5 stack off boss1) and the
                            -- twins follow the new anchor together.
                            BF:ApplyOUFBossFrameLayout()
                        else
                            local real = GetRealFrame(uk)
                            if real and real._anchor then
                                real._anchor:ClearAllPoints()
                                real._anchor:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", nx, ny)
                                real:ClearAllPoints()
                                real:SetPoint("TOPLEFT", real._anchor, "TOPLEFT", 0, 0)
                                if real._anchor.SnapHandle then real._anchor.SnapHandle() end
                            end
                        end
                    end
                end
            end
            BF:RefreshPanel("ufPosition")
        end)

        self._ufTestFrames[unitKey] = tf
    end
end

function BF:ShowUFTestFrames()
    if not self._ufTestFrames then self:CreateUFTestFrames() end
    local p = self.ufDB.profile

    for unitKey, tf in pairs(self._ufTestFrames) do
        local enableKey = UF_ENABLE_KEYS[unitKey]
        local isEnabled
        if unitKey == "icPlayerFrame" then
            local ic = BF.icDB and BF.icDB.profile
            isEnabled = ic and ic.incomingCastsEnabled
        else
            isEnabled = enableKey and p[enableKey]
        end
        -- Check detach requirement for bars/castbars/IC
        local detachCheck = UF_DETACH_CHECK[unitKey]
        if isEnabled and detachCheck then
            if not detachCheck(p) then
                isEnabled = false
            end
        end
        if isEnabled then
            local w, h = GetUFTestFrameSize(unitKey)
            local twinActive = ActiveTwinSize(unitKey) and true or false
            local scale = 1.0
            if not UF_CENTER_KEYS[unitKey] then
                local pf = p[unitKey] or {}
                scale = pf.frameScale or 1.0
            end
            -- Single-box twins are already measured on screen by
            -- GetUFTestFrameSize, so the oUF frame's scale must not be applied
            -- on top. Boss keeps its scale: that box's interior is laid out in
            -- the oUF boss frames' pre-scale space.
            if twinActive and unitKey ~= "boss" then scale = 1.0 end
            tf:SetSize(w, h)
            tf:SetScale(scale)

            -- Never draw an unlabeled box for a frame the twin has replaced:
            -- the oUF frame behind it is driver-hidden.
            local def = UF_TEST_FRAME_DEFS[unitKey]
            local baseLabel = (def and def.label) or unitKey
            local boxLabel = twinActive and (baseLabel .. " (raid style)") or baseLabel
            tf._label:SetText(boxLabel)

            -- Boss frames: show individual sub-frame outlines
            if unitKey == "boss" then
                if not tf._bossSubFrames then
                    tf._bossSubFrames = {}
                    for i = 1, 5 do
                        local sub = CreateFrame("Frame", nil, tf, "BackdropTemplate")
                        sub:SetBackdrop({
                            bgFile   = "Interface\\Buttons\\White8x8",
                            edgeFile = "Interface\\Buttons\\White8x8",
                            edgeSize = 1,
                        })
                        local sbR, sbG, sbB, sbA, sbrR, sbrG, sbrB, sbrA = BF.GetSetupFrameColors()
                        sub:SetBackdropColor(sbR, sbG, sbB, sbA * 0.7)
                        sub:SetBackdropBorderColor(sbrR, sbrG, sbrB, sbrA * 0.875)
                        sub:EnableMouse(false)
                        local lbl = sub:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                        lbl:SetPoint("CENTER")
                        lbl:SetText("Boss " .. i)
                        lbl:SetTextColor(1, 1, 1, 0.7)
                        sub._label = lbl
                        tf._bossSubFrames[i] = sub
                    end
                end
                tf:SetBackdropColor(0, 0, 0, 0)
                local _, _, _, _, boR, boG, boB, boA = BF.GetSetupFrameColors()
                tf:SetBackdropBorderColor(boR, boG, boB, boA * 0.625)
                tf._label:SetText(boxLabel)
                tf._label:ClearAllPoints()
                tf._label:SetPoint("BOTTOM", tf, "TOP", 0, 2)
                local pf = p.boss or {}
                local bossGrowDir = p.bossGrowDirection or "DOWN"
                local bScale = pf.frameScale or 1.0
                local twinW, twinH, twinS = ActiveTwinSize("boss")
                -- Same slot arithmetic as ApplyOUFBossFrameLayout, from the
                -- same function (GetBossSlotSpan).
                local slotH = BF:GetBossSlotSpan(p, pf, false, twinH, bScale, twinS)
                local gap = p.bossFrameSpacing or 4
                local slotW = BF:GetBossSlotSpan(p, pf, true,  twinW, bScale, twinS)
                for i = 1, 5 do
                    local sub = tf._bossSubFrames[i]
                    sub:ClearAllPoints()
                    if bossGrowDir == "UP" then
                        local yOff = (i - 1) * (slotH + gap)
                        sub:SetPoint("BOTTOMLEFT", tf, "BOTTOMLEFT", 0, yOff)
                        sub:SetSize(slotW, slotH)
                    elseif bossGrowDir == "LEFT" then
                        local xOff = (i - 1) * (slotW + gap)
                        sub:SetPoint("TOPRIGHT", tf, "TOPRIGHT", -xOff, 0)
                        sub:SetSize(slotW, slotH)
                    elseif bossGrowDir == "RIGHT" then
                        local xOff = (i - 1) * (slotW + gap)
                        sub:SetPoint("TOPLEFT", tf, "TOPLEFT", xOff, 0)
                        sub:SetSize(slotW, slotH)
                    else -- DOWN (default)
                        local yOff = (i - 1) * (slotH + gap)
                        sub:SetPoint("TOPLEFT", tf, "TOPLEFT", 0, -yOff)
                        sub:SetSize(slotW, slotH)
                    end
                    sub:Show()
                end
            else
                if tf._bossSubFrames then
                    for i = 1, 5 do tf._bossSubFrames[i]:Hide() end
                end
            end

            -- Read anchor from the UF layout system
            local ancX, ancY
            if unitKey == "icPlayerFrame" then
                local ic = (BF.icDB and BF.icDB.profile) or {}
                ancX = ic.incomingCastsPlayerAnchorX or 0
                ancY = ic.incomingCastsPlayerAnchorY or -200
            elseif unitKey == "targetCastbar" then
                ancX = p.targetCastBarAnchorX or 0
                ancY = p.targetCastBarAnchorY or 0
            elseif unitKey == "focusCastbar" then
                ancX = p.focusCastBarAnchorX or 0
                ancY = p.focusCastBarAnchorY or 0
            else
                ancX, ancY = BF:GetUFAnchor(unitKey)
                if not ancX then
                    ancX, ancY = GetUFTestFrameDefaultAnchor(unitKey)
                end
            end

            local anc = tf._anchor
            if anc then
                anc:ClearAllPoints()
                if tf._anchorStyle == "center" then
                    anc:SetPoint("CENTER", UIParent, "CENTER", ancX or 0, ancY or 0)
                else
                    anc:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", ancX or 600, ancY or 400)
                end
                -- frameOrigin, when set, overrides which corner of the
                -- overlay lands on the anchor point without changing the
                -- coordinate space above.
                local origin = tf._frameOrigin
                if type(origin) == "function" then origin = origin() end
                origin = origin
                    or ((tf._anchorStyle == "center") and "CENTER" or "TOPLEFT")
                tf:ClearAllPoints()
                if unitKey == "boss" then
                    -- The saved anchor is boss1's TOPLEFT for every grow
                    -- direction (oUF_BossFrames.lua), and boss1 is the
                    -- column's FIXED end: the bottom frame for Up, the
                    -- right-hand one for Left. The box extends away from
                    -- it. Offsets are in the overlay's own (scaled) space,
                    -- so a single frame's height / width places the far
                    -- corner exactly on boss1's far edge.
                    local bpf = p.boss or {}
                    local dir = p.bossGrowDirection or "DOWN"
                    if dir == "UP" then
                        local fh = (bpf.nameBarHeight or 12) + (bpf.healthBarHeight or 22)
                                 + (bpf.powerBarHeight or 12)
                        tf:SetPoint("BOTTOMLEFT", anc, "TOPLEFT", 0, -fh)
                    elseif dir == "LEFT" then
                        tf:SetPoint("TOPRIGHT", anc, "TOPLEFT", bpf.frameWidth or 150, 0)
                    else
                        tf:SetPoint("TOPLEFT", anc, "TOPLEFT", 0, 0)
                    end
                else
                    tf:SetPoint(origin, anc, origin, 0, 0)
                end
            else
                local origin = tf._frameOrigin
                if type(origin) == "function" then origin = origin() end
                origin = origin
                    or ((tf._anchorStyle == "center") and "CENTER" or "TOPLEFT")
                tf:ClearAllPoints()
                if tf._anchorStyle == "center" then
                    tf:SetPoint(origin, UIParent, "CENTER", ancX or 0, ancY or 0)
                else
                    tf:SetPoint(origin, UIParent, "BOTTOMLEFT", ancX or 600, ancY or 400)
                end
            end
            tf:Show()
        else
            tf:Hide()
        end
    end
end

function BF:HideUFTestFrames()
    if not self._ufTestFrames then return end
    for _, tf in pairs(self._ufTestFrames) do
        tf:Hide()
    end
end
