--[[
BuzzardFrames: Indicators/ImportantIcons.lua
Important buff icon indicator — renders HELPFUL|IMPORTANT icons.

Grid2 pattern: indicator bound to the important status. Calls
Important:GetIcons(unit, bdInstancesSeen) at display time for
lazy fetch + BigDef deduplication.

Cross-status dependency: needs BigDef's claimed instanceIDs to dedup.
When showBigDef is disabled, no dedup is needed (nil exclusion set).

Extracted from the "IMPORTANT BUFFS" section of ScanAndDisplay.lua.
Icon pool is pre-allocated by ApplyAuraGeometry (AuraConfig.lua).
]]

local BF  = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")
local LCG = LibStub("LibCustomGlow-1.0", true)

local ipairs           = ipairs
local issecretvalue    = issecretvalue  or function() return false end
local canaccessvalue   = canaccessvalue or function() return true  end
local UnitIsVisible    = UnitIsVisible

local SetIconBorderColor   = BF.SetIconBorderColor

local _bigdefStatus = BF.statuses.bigdef
local _impStatus    = BF.statuses.important

local ImportantIcons = BF.indicatorPrototype:new("importantIcons")

function ImportantIcons:CanCreate() return true end
function ImportantIcons:Create() end
function ImportantIcons:GetFrame(parent) return parent.importantIcons end

-- Grid2 pattern: stamp cooldown config + color curve targets onto icon
-- frames at Layout time.
function ImportantIcons:Layout(parent)
    if not parent.importantIcons then return end
    local ac = BF:GetAuraCacheForFrame(parent)
    for i = 1, #parent.importantIcons do
        local icon = parent.importantIcons[i]
        -- Clear cached index so Update repositions with the new offset table.
        icon.SF_LastIndex = nil
        if icon.cooldown then
            local cd = icon.cooldown
            cd:SetDrawSwipe(not ac.disableImportantSwipe)
            cd:SetDrawEdge(not ac.disableImportantSpark)
            cd:SetReverse(ac.reverseImportantSwipe or false)
            cd:SetHideCountdownNumbers(not ac.showImportantDuration)
            -- Grid2 pattern: re-fetch if not yet available
            if ac.showImportantDuration and not cd.timerText then
                cd.timerText = cd:GetCountdownFontString()
            end
            local tt = cd.timerText
            if tt then
                local fontPath = ac.importantDurationFont or "Interface\\AddOns\\BuzzardFrames\\Media\\Fonts\\RobotoCondensed-Bold.ttf"
                local autoScale = ac.importantAutoScale
                local fontSize = autoScale and 11 or (ac.importantFontSize or 11)
                local fontBorder = ac.importantDurationBorder or "OUTLINE"
                local timerScale = autoScale and ((ac._roundedImportantSize or 18) / 12 * (ac.importantTimerScale or 1.0)) or 1.0
                cd._bf_font   = fontPath
                cd._bf_size   = fontSize
                cd._bf_border = fontBorder
                cd._bf_scale  = timerScale
                tt:SetFont(fontPath, fontSize, fontBorder)
                tt:SetScale(timerScale)
                tt:ClearAllPoints()
                tt:SetPoint("CENTER", cd, "CENTER", 0, 0)
                local fc = ac.importantFontColor
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
            icon.colorCurveObject = ac.expiringCurveImportant
            icon.colorCurveText = tt
            icon.colorCurveBorder = (ac.importantColorAuraBorder == true) and true or nil
        end
    end
end

-- ============================================================
-- HideAll
-- ============================================================
function ImportantIcons:HideAll(frame)
    if not frame.importantIcons then return end
    for i = 1, #frame.importantIcons do
        local icon = frame.importantIcons[i]
        if icon:IsShown() then
            if LCG and icon._hasGlow then LCG.ButtonGlow_Stop(icon); icon._hasGlow = false end
            icon:Hide()
        end
        -- Clear change-guard state so repositioning works when icons reappear.
        icon.SF_LastSlot = nil
        icon.SF_LastOffX = nil
        icon.SF_LastOffY = nil
    end
end

-- ============================================================
-- Update
-- ============================================================
function ImportantIcons:Update(frame, unit)
    if not frame.importantIcons then return end

    -- Skip preview/dummy frames — DummyAuras.lua handles their rendering.
    if frame._isPreviewFrame then return end

    local ac = BF:GetAuraCacheForFrame(frame)

    -- Gate: feature disabled or custom frame module override
    if not ac.showImportant then
        self:HideAll(frame)
        return
    end
    local parentHeader = frame._bf_parentHeader or frame:GetParent()
    local cfgShowImportant = parentHeader and parentHeader.isCustomFrame and parentHeader.moduleShowImportant
    if cfgShowImportant == false then
        self:HideAll(frame)
        return
    end

    -- Fetch BigDef exclusion set (only if BigDef is enabled)
    -- Grid2 pattern: visibility gate lives in GetIcons, not here.
    -- Cache in the status makes this free on 2nd+ call per unit per event.
    local bdInstancesSeen = nil
    if ac.showBigDef and _bigdefStatus and _bigdefStatus.GetIcons then
        local _bdCount, _bdTex, _bdStk, _bdExp, _bdDur, _bdIID, seen = _bigdefStatus:GetIcons(unit)
        bdInstancesSeen = seen
    end

    -- Fetch Important data (Grid2 lazy fetch, dedup against BigDef)
    if not _impStatus or not _impStatus.GetIcons then
        self:HideAll(frame)
        return
    end
    local impCount, srcTex, srcStk, srcExp, srcDur, srcIID, impSeen = _impStatus:GetIcons(unit, bdInstancesSeen)

    if not impCount or impCount == 0 then
        self:HideAll(frame)
        return
    end

    -- Read cached settings
    local impSize        = ac._roundedImportantSize or 18
    local anchorPos      = ac.importantAnchor
    local ap           = (anchorPos ~= "") and anchorPos or "CENTER"
    local offX         = ac.importantOffsetX or 0
    local offY         = ac.importantOffsetY or 0
    local impOffsets   = ac._importantOffsets or BF.OffsetCache.important

    -- Grid2 parity: read pre-resolved default border color from AuraCache
    -- (populated once in UpdateAuraSizeCache) instead of calling
    -- GetDefaultBorderColorFor per icon per Update.
    local defBR = ac._defBorder_important_r or 0
    local defBG = ac._defBorder_important_g or 0
    local defBB = ac._defBorder_important_b or 0
    local defBA = ac._defBorder_important_a or 0.8

    local shown = 0
    for idx = 1, impCount do
        local tex = srcTex[idx]
        local dur = srcDur[idx]
        if tex and (issecretvalue(dur) or dur > 0) then
            shown = shown + 1
            local icon = frame.importantIcons[shown]
            if not icon then break end

            local iid = srcIID[idx]

            -- Size (BigDefIcons change-guard pattern: skip SetSize when unchanged)
            if icon.cachedSize ~= impSize then
                icon:SetSize(impSize, impSize)
                icon.cachedSize = impSize
            end
            icon.Icon:SetTexture(tex)
            icon.Icon:Show()
            icon.auraInstanceID = iid
            -- v33: default border is importantFontColor at alpha 0.8 when
            -- importantColorAuraBorder is on, otherwise legacy black.
            SetIconBorderColor(icon, defBR, defBG, defBB, defBA)

            -- Stack count (Grid2 parallel array pattern: pre-resolved at fetch time)
            if ac.showStackText ~= false then
                local apps = srcStk[idx]
                icon.count:SetText(apps or "")
                if ac.stackAutoScale then
                    icon.count:SetScale(impSize / 12 * (ac.stackTimerScale or 1.0))
                end
                if not icon.count:IsShown() then icon.count:Show() end
            else
                if icon.count:IsShown() then icon.count:Hide() end
            end

            if icon.cooldown then
                BF.UpdateIconCooldown(icon, unit, srcExp[idx], dur, iid)
            end

            -- Position: grow direction with per-row wrapping
            -- Position: pre-computed offset table (DebuffIcons pattern)
            local slotOff = impOffsets[shown]
            local slotOffX = slotOff.x + offX
            local slotOffY = slotOff.y + offY
            if icon.SF_LastSlot ~= shown or icon.SF_LastOffX ~= slotOffX or icon.SF_LastOffY ~= slotOffY then
                icon:ClearAllPoints()
                if ac.aurasAbovePowerBar and frame.powerBar and frame.powerBar:IsShown() and frame.healthBar
                    and (ap == "BOTTOM" or ap == "BOTTOMLEFT" or ap == "BOTTOMRIGHT") then
                    local anchorFrame = frame.healthBar.clipFrame or frame.healthBar
                    icon:SetPoint(ap, anchorFrame, ap, slotOffX, slotOffY)
                else
                    icon:SetPoint(ap, frame, ap, slotOffX, slotOffY)
                end
                icon.SF_LastSlot = shown
                icon.SF_LastOffX = slotOffX
                icon.SF_LastOffY = slotOffY
            end
            icon:Show()

            -- Glow
            if LCG then
                if ac.importantShowGlow then
                    local iW, iH = icon:GetSize()
                    if not issecretvalue(iW) and not issecretvalue(iH)
                            and iW and iH and iW > 0 and iH > 0 then
                        pcall(LCG.ButtonGlow_Start, icon, nil, nil, nil)
                    end
                    icon._hasGlow = true
                else
                    if icon._hasGlow then LCG.ButtonGlow_Stop(icon); icon._hasGlow = false end
                end
            end
        end
    end

    -- Hide unused pool slots
    for i = shown + 1, #frame.importantIcons do
        local _icon = frame.importantIcons[i]
        if _icon:IsShown() then
            if LCG and _icon._hasGlow then LCG.ButtonGlow_Stop(_icon); _icon._hasGlow = false end
            _icon:Hide()
        end
        _icon.SF_LastSlot = nil
        _icon.SF_LastOffX = nil
        _icon.SF_LastOffY = nil
    end
end

BF:RegisterIndicator(ImportantIcons)
ImportantIcons:EnableDeferredUpdates()
