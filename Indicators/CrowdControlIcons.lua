--[[
BuzzardFrames: Indicators/CrowdControlIcons.lua
Crowd Control icon indicator — renders HARMFUL|CROWD_CONTROL icons.

Grid2 pattern: indicator bound to the crowdcontrol status. Calls
CrowdControl:GetIcons(unit) at display time for lazy fetch.

Standalone — no cross-status dependencies.

Extracted from the "CROWD CONTROL" section of ScanAndDisplay.lua.
First icon slot is pre-allocated by ApplyAuraGeometry (AuraConfig.lua)
as frame.crowdControlIcon. Additional slots created lazily here.
]]

local BF  = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")
local LCG = LibStub("LibCustomGlow-1.0", true)

local ipairs           = ipairs
local issecretvalue    = issecretvalue  or function() return false end
local canaccessvalue   = canaccessvalue or function() return true  end
local UnitIsVisible    = UnitIsVisible

local SetIconBorderColor    = BF.SetIconBorderColor
local CreateAuraIcon        = BF.CreateAuraIcon
local GetBackdropTable      = BF.GetBackdropTable
local SetFrameBackdrop      = BF.SetFrameBackdrop
local PixelPerfectSize      = BF.PixelPerfectSize

local _ccStatus = BF.statuses.crowdcontrol

local CrowdControlIcons = BF.indicatorPrototype:new("crowdControlIcons")

function CrowdControlIcons:CanCreate() return true end
function CrowdControlIcons:Create() end
function CrowdControlIcons:GetFrame(parent) return parent.crowdControlIcons or parent.crowdControlIcon end

-- Grid2 pattern: stamp cooldown config + color curve targets onto icon
-- frames at Layout time. CC uses a single icon (or small pool); stamp
-- them all.
function CrowdControlIcons:Layout(parent)
    local icons = parent.crowdControlIcons
    if not icons and parent.crowdControlIcon then
        icons = { parent.crowdControlIcon }
    end
    if not icons then return end
    local ac = BF:GetAuraCacheForFrame(parent)
    for i = 1, #icons do
        local icon = icons[i]
        -- Clear cached index so Update repositions with the new offset table.
        icon.SF_LastIndex = nil
        if icon.cooldown then
            local cd = icon.cooldown
            cd:SetDrawSwipe(not ac.disableCrowdControlSwipe)
            cd:SetDrawEdge(not ac.disableCrowdControlSpark)
            cd:SetReverse(ac.reverseCrowdControlSwipe or false)
            cd:SetHideCountdownNumbers(not ac.showCrowdControlDuration)
            -- Grid2 pattern: re-fetch if not yet available
            if ac.showCrowdControlDuration and not cd.timerText then
                cd.timerText = cd:GetCountdownFontString()
            end
            local tt = cd.timerText
            if tt then
                local fontPath = ac.crowdControlDurationFont or "Interface\\AddOns\\BuzzardFrames\\Media\\Fonts\\RobotoCondensed-Bold.ttf"
                local autoScale = ac.crowdControlAutoScale
                local fontSize = autoScale and 11 or (ac.crowdControlFontSize or 11)
                local fontBorder = ac.crowdControlDurationBorder or "OUTLINE"
                local timerScale = autoScale and ((ac._roundedCrowdControlSize or 24) / 12 * (ac.crowdControlTimerScale or 1.0)) or 1.0
                cd._bf_font   = fontPath
                cd._bf_size   = fontSize
                cd._bf_border = fontBorder
                cd._bf_scale  = timerScale
                tt:SetFont(fontPath, fontSize, fontBorder)
                tt:SetScale(timerScale)
                tt:ClearAllPoints()
                tt:SetPoint("CENTER", cd, "CENTER", 0, 0)
                local fc = ac.crowdControlFontColor
                if fc then
                    cd._bf_textR = fc.r or 1
                    cd._bf_textG = fc.g or 1
                    cd._bf_textB = fc.b or 1
                    cd._bf_textA = fc.a or 1
                    tt:SetTextColor(fc.r or 1, fc.g or 1, fc.b or 1, fc.a or 1)
                else
                    cd._bf_textR = 1
                    cd._bf_textG = 1
                    cd._bf_textB = 1
                    cd._bf_textA = 1
                    tt:SetTextColor(1, 1, 1, 1)
                end
            end
            -- Color curve config (Grid2 pattern: stamp on icon)
            -- CC: border is owned by dispel color glow, never by curve
            icon.colorCurveObject = ac.expiringCurveCrowdControl
            icon.colorCurveText = tt
            icon.colorCurveBorder = nil
        end
    end
end

-- ============================================================
-- HideAll
-- ============================================================
function CrowdControlIcons:HideAll(frame)
    if frame.crowdControlIcons then
        for _, icon in ipairs(frame.crowdControlIcons) do
            if LCG and icon._hasGlow then LCG.ButtonGlow_Stop(icon); icon._hasGlow = false end
            icon:Hide()
        end
    elseif frame.crowdControlIcon then
        if LCG and frame.crowdControlIcon._hasGlow then LCG.ButtonGlow_Stop(frame.crowdControlIcon); frame.crowdControlIcon._hasGlow = false end
        frame.crowdControlIcon:Hide()
    end
end

-- ============================================================
-- Update
-- ============================================================
function CrowdControlIcons:Update(frame, unit)
    if not frame.crowdControlIcon then return end

    -- Skip preview/dummy frames — DummyAuras.lua handles their rendering.
    if frame._isPreviewFrame then return end

    local ac = BF:GetAuraCacheForFrame(frame)

    -- Gate: feature disabled or custom frame module override
    if not ac.showCrowdControl then
        self:HideAll(frame)
        return
    end
    local parentHeader = frame._bf_parentHeader or frame:GetParent()
    local cfgShowCrowdCtrl = parentHeader and parentHeader.isCustomFrame and parentHeader.moduleShowCrowdControl
    if cfgShowCrowdCtrl == false then
        self:HideAll(frame)
        return
    end

    -- Fetch CC data (Grid2 lazy fetch)
    -- Grid2 pattern: visibility gate lives in GetIcons, not here.
    if not _ccStatus or not _ccStatus.GetIcons then
        self:HideAll(frame)
        return
    end
    local ccCount, srcTex, srcStk, srcExp, srcDur, srcIID = _ccStatus:GetIcons(unit)

    if not ccCount or ccCount == 0 then
        self:HideAll(frame)
        return
    end

    -- Read cached settings
    local maxIcons        = ac.crowdControlMaxIcons or 1
    local ccSize          = ac._roundedCrowdControlSize or 24
    local anchorPos       = ac.crowdControlAnchor
    local level           = frame.crowdControlIcon:GetFrameLevel()

    -- Ensure we have enough icon slots
    if not frame.crowdControlIcons then
        frame.crowdControlIcons = { frame.crowdControlIcon }
    end
    for i = #frame.crowdControlIcons + 1, maxIcons do
        local newIcon = CreateAuraIcon(frame, level)
        if newIcon.Icon then newIcon.Icon:SetDrawLayer("OVERLAY", 1) end
        frame.crowdControlIcons[i] = newIcon
    end

    local ap           = (anchorPos ~= "") and anchorPos or "CENTER"
    local offX         = ac.crowdControlOffsetX or 0
    local offY         = ac.crowdControlOffsetY or 0
    local ccOffsets    = ac._crowdControlOffsets or BF.OffsetCache.crowdControl

    for slot = 1, maxIcons do
        local icon = frame.crowdControlIcons[slot]
        if not icon then break end
        local foundIcon       = slot <= ccCount and srcTex[slot] or nil
        local foundExp        = srcExp[slot]
        local foundDur        = srcDur[slot]
        local foundInstanceID = srcIID[slot]

        if foundIcon and (issecretvalue(foundDur) or foundDur > 0) then
            icon:SetSize(ccSize, ccSize)
            icon.Icon:SetTexture(foundIcon)
            icon.Icon:Show()
            icon.auraInstanceID = foundInstanceID
            SetIconBorderColor(icon, 0, 0, 0, 0.8)

            -- Stack count (Grid2 parallel array pattern: pre-resolved at fetch time)
            if ac.showStackText ~= false then
                local apps = srcStk[slot]
                icon.count:SetText(apps or "")
                if ac.stackAutoScale then
                    icon.count:SetScale(ccSize / 12 * (ac.stackTimerScale or 1.0))
                end
                if not icon.count:IsShown() then icon.count:Show() end
            else
                if icon.count:IsShown() then icon.count:Hide() end
            end

            if icon.cooldown and foundInstanceID then
                BF.UpdateIconCooldown(icon, unit, foundExp, foundDur, foundInstanceID)
            end

            -- Position: pre-computed offset table (DebuffIcons pattern)
            local slotOff = ccOffsets[slot]
            local slotOffX = slotOff.x + offX
            local slotOffY = slotOff.y + offY
            icon:ClearAllPoints()
            if ac.aurasAbovePowerBar and frame.powerBar and frame.powerBar:IsShown() and frame.healthBar
                and (ap == "BOTTOM" or ap == "BOTTOMLEFT" or ap == "BOTTOMRIGHT") then
                local anchorFrame = frame.healthBar.clipFrame or frame.healthBar
                icon:SetPoint(ap, anchorFrame, ap, slotOffX, slotOffY)
            else
                icon:SetPoint(ap, frame, ap, slotOffX, slotOffY)
            end
            icon:Show()

            -- Glow / colored border
            if LCG and ac.crowdControlShowGlow then
                local iconW, iconH = icon:GetSize()
                if not issecretvalue(iconW) and not issecretvalue(iconH)
                        and iconW and iconH and iconW > 0 and iconH > 0 then
                    pcall(LCG.ButtonGlow_Start, icon, nil, nil, nil)
                    if foundInstanceID and SF_DispelCurve
                            and C_UnitAuras.GetAuraDispelTypeColor
                            and icon._ButtonGlow then
                        local dc = C_UnitAuras.GetAuraDispelTypeColor(
                            unit, foundInstanceID, SF_DispelCurve)
                        if dc then
                            local bf = icon._ButtonGlow
                            for _, texKey in ipairs({"spark","innerGlow","innerGlowOver","outerGlow","outerGlowOver","ants"}) do
                                if bf[texKey] then
                                    bf[texKey]:SetDesaturated(1)
                                    bf[texKey]:SetVertexColor(dc:GetRGBA())
                                end
                            end
                        end
                    end
                end
                icon._hasGlow = true
                SetIconBorderColor(icon, 0, 0, 0, 0.8)
            else
                if LCG and icon._hasGlow then LCG.ButtonGlow_Stop(icon); icon._hasGlow = false end
                local borderBackdrop = GetBackdropTable(BF:PixelsToUI(2))
                SetFrameBackdrop(icon, borderBackdrop)
                if foundInstanceID and SF_DispelCurve and C_UnitAuras.GetAuraDispelTypeColor then
                    local dc = C_UnitAuras.GetAuraDispelTypeColor(unit, foundInstanceID, SF_DispelCurve)
                    if dc then
                        SetIconBorderColor(icon, dc:GetRGBA())
                    else
                        SetIconBorderColor(icon, 0.8, 0, 0, 1)
                    end
                else
                    SetIconBorderColor(icon, 0.8, 0, 0, 1)
                end
            end
        else
            if LCG and icon._hasGlow then LCG.ButtonGlow_Stop(icon); icon._hasGlow = false end
            icon:Hide()
        end
    end

    -- Hide extra slots beyond current maxIcons
    if frame.crowdControlIcons then
        for i = maxIcons + 1, #frame.crowdControlIcons do
            local icon = frame.crowdControlIcons[i]
            if icon then
                if LCG and icon._hasGlow then LCG.ButtonGlow_Stop(icon); icon._hasGlow = false end
                icon:Hide()
            end
        end
    end
end

BF:RegisterIndicator(CrowdControlIcons)
CrowdControlIcons:EnableDeferredUpdates()
