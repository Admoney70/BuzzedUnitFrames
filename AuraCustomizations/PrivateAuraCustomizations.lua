-- ============================================================================
-- PrivateAuraCustomizations.lua
-- ============================================================================
-- All non-essential private aura behaviour lives here. The regular icon path
-- (PrivateAuras.lua) does NOT call into this file and does NOT depend on any
-- function defined here. Communication is purely via opaque "override" fields
-- that this file writes onto unit frames; the icon path reads them as
-- "if present, use; otherwise default."
--
-- KILLSWITCH:
--   acDB.profile.enablePrivateAuraCustomizations
--   Off by default. When off, every public entry point in this file returns
--   immediately. When toggled OFF, the setter wipes all SF_* fields this
--   module ever wrote and tears down all frames it ever created on every
--   active unit frame, then forces an icon-path rebuild so icons return to
--   pristine, customization-free behaviour.
--
-- OPAQUE OVERRIDE FIELDS (written here, read by PrivateAuras.lua icon path):
--   f.SF_PrivateAuraIndexMap            -- slot -> auraIndex (hidden indices)
--   f.SF_PrivateAuraIconHidden          -- bool, suppresses icon (size 0.001)
--   f.SF_PrivateAuraBorderScaleOverride -- number, fed to AddPrivateAuraAnchor
--
-- OWNED FRAMES & STATE (touched only by this file):
--   SF_PrivateAuraOverlayFrames, SF_PrivateAuraOverlayHandles
--   SF_PrivateAuraFrameBorderContainer, SF_PrivateAuraFrameBorderSubContainers,
--   SF_PrivateAuraFrameBorderHandles, SF_PrivateAuraBorderUnit,
--   SF_PrivateAuraBorderIconW, SF_PrivateAuraBorderScale,
--   SF_PrivateAuraBorderMaxSlots
--   SF_EncounterIconOverride, SF_EncounterBorderOverride
--
-- PUBLIC ENTRY POINTS (called from Auras.lua's per-frame loop):
--   BF:ApplyPrivateAuraOverrideFields(frame)
--     Writes the four opaque override fields based on resolved override state.
--     Called BEFORE BF:UpdatePrivateAuraAnchor in Auras.lua so the icon path
--     sees fresh override values on its layout pass.
--   BF:UpdatePrivateAuraOverlay(frame)         -- text overlay layout + anchors
--   BF:UpdatePrivateAuraFrameBorder(frame)     -- frame border layout + anchors
--   BF:RegisterPrivateAuraOverlayAnchorsOnly(frame)   -- unit-change hot path
--
-- KILLSWITCH SETTER:
--   BF:SetPrivateAuraCustomizationsEnabled(enabled)
-- ============================================================================

local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")
if not BF then
    error("BuzzardFrames: PrivateAuraCustomizations.lua loaded before Core.lua!")
    return
end

local AddPrivateAuraAnchor    = C_UnitAuras.AddPrivateAuraAnchor
local RemovePrivateAuraAnchor = C_UnitAuras.RemovePrivateAuraAnchor
local wipe                    = wipe

-- ----------------------------------------------------------------------------
-- Killswitch query
-- ----------------------------------------------------------------------------
-- TEMPORARILY HARDCODED to false while debugging a frame-level rendering bug.
-- Original implementation read the saved variable. To restore, change to:
--   return BF.acDB and BF.acDB.profile and BF.acDB.profile.enablePrivateAuraCustomizations == true
local function customizationsEnabled()
    return false
end

-- ============================================================================
-- ANCHOR DESCRIPTORS
-- One shared descriptor per anchor type, mutated per-call in the registration
-- loops. Matches Grid2's pattern (single shared descriptor, mutate-per-call).
-- ============================================================================

-- Descriptor for the icon-less text overlay (cooldown timer + stack count).
local BF_PrivateAuraOverlayAnchor = {
    iconInfo = {
        iconWidth  = 0.001,
        iconHeight = 0.001,
        iconAnchor = {
            offsetX      = 0,
            offsetY      = 0,
            point        = 'CENTER',
            relativePoint = 'CENTER',
        },
    },
    showCountdownFrame   = false,
    showCountdownNumbers = false,
}

-- Descriptor for the frame-border ring. iconWidth/Height & borderScale are
-- mutated per-frame from the values stashed on the frame by the layout pass.
local BF_PrivateAuraFrameBorderAnchor = {
    iconInfo = {
        iconWidth  = 0.001,
        iconHeight = 0.001,
        iconAnchor = {
            offsetX       = 0,
            offsetY       = 0,
            point         = 'CENTER',
            relativePoint = 'CENTER',
        },
    },
    showCountdownFrame   = false,
    showCountdownNumbers = false,
}

-- ============================================================================
-- OVERRIDE RESOLUTION HELPERS
-- ============================================================================

-- Returns the active override profile for private aura display, or nil.
-- Priority: globalPASettings > encounter > dungeon.
-- Used to resolve hideIcon, showOverlay, hiddenAuraIndices, hideFirstAuraSlot.
-- NOTE: We check activeEncounterID without requiring IsEncounterInProgress() so
-- that subzone-based overrides (applied before the pull) take effect immediately
-- on anchor registration, not only once combat starts.
local function GetActiveInstanceOverride()
    local p = BF and BF.db and BF.db.profile
    local acp = BF.acDB and BF.acDB.profile
    if not p or not acp then return nil end
    -- Global raid override takes highest priority in raid instances.
    if acp.enableGlobalPAOverrides then
        local instanceType = select(2, IsInInstance())
        if instanceType == "raid" then
            return acp.globalPASettings or {}
        end
    end
    -- Encounter override.
    local encID = p.activeEncounterID
    if encID then
        local ep = acp.encounterPASettings and acp.encounterPASettings[encID]
        if ep then return ep end
    end
    -- Dungeon fallback.
    local instanceType = select(2, IsInInstance())
    if instanceType == "party" then
        return acp.dungeonPASettings
    end
    return nil
end
-- Expose for Encounters.lua and any other caller that needs it.
BF.GetActivePrivateAuraOverride = GetActiveInstanceOverride

-- Resolve hidden aura indices from all override sources.
-- Returns a table like {[1]=true, [3]=true} or nil if nothing hidden.
local function ResolveHiddenIndices(frame)
    local encIconOverride = frame and frame.SF_EncounterIconOverride
    local instanceOverride = encIconOverride or GetActiveInstanceOverride()
    local hiddenIndices = (instanceOverride and instanceOverride.hiddenAuraIndices)
    if not hiddenIndices then
        local hideFirst = (instanceOverride and instanceOverride.hideFirstAuraSlot)
        if hideFirst then hiddenIndices = { [1] = true } end
    end
    return hiddenIndices
end

-- ============================================================================
-- ApplyPrivateAuraOverrideFields
--
-- Computes the four opaque override fields from the resolved override state
-- and writes them onto `frame`. The icon path reads these as "if present,
-- use; otherwise default." When the killswitch is OFF, all four fields are
-- forced nil so the icon path falls through to pristine, customization-free
-- behaviour.
-- ============================================================================
function BF:ApplyPrivateAuraOverrideFields(frame)
    if not frame then return end

    if not customizationsEnabled() then
        -- Killswitch off: nothing to apply, and ensure no stale overrides
        -- linger from a previous on-state.
        frame.SF_PrivateAuraIndexMap            = nil
        frame.SF_PrivateAuraIconHidden          = nil
        frame.SF_PrivateAuraBorderScaleOverride = nil
        return
    end

    local encIconOverride = frame.SF_EncounterIconOverride
    local instanceOverride = encIconOverride or GetActiveInstanceOverride()

    -- Resolve isRaid context once for the three rpDB reads below.
    local isRaid       = IsInRaid()
    local raidProfile  = BF:GetRaidProfile()
    local pp           = BF:GetActivePartyProfile()
    local activeFlat   = isRaid and raidProfile or pp
    local aurasP       = BF:GetSectionProfile("auras", activeFlat) or {}
    local paP          = aurasP.privateAuras or {}
    local maxIcons     = paP.maxPrivateAuras or 3

    -- 1. Hidden indices -> SF_PrivateAuraIndexMap.
    --    indexMap[slot] = auraIndex. With index 1 hidden and maxIcons=3:
    --    indexMap = {2, 3, 4} -> slot 1 gets auraIndex 2, slot 2 gets 3, etc.
    --    Nil when no indices hidden -- icon path falls through to identity.
    local hiddenIndices = ResolveHiddenIndices(frame)
    if hiddenIndices then
        local visibleIndices = {}
        local idx = 1
        while #visibleIndices < maxIcons do
            if not hiddenIndices[idx] then
                visibleIndices[#visibleIndices + 1] = idx
            end
            idx = idx + 1
            if idx > maxIcons + 20 then break end
        end
        frame.SF_PrivateAuraIndexMap = visibleIndices
    else
        frame.SF_PrivateAuraIndexMap = nil
    end

    -- 2. iconHidden -> SF_PrivateAuraIconHidden.
    frame.SF_PrivateAuraIconHidden = (instanceOverride and instanceOverride.hideIcon) and true or nil

    -- 3. borderScale -> SF_PrivateAuraBorderScaleOverride.
    --    Read from rpDB.profile.privateAuraBorderScale; only set when ~= 1.0.
    local rpScale = BF.rpDB and BF.rpDB.profile and BF.rpDB.profile.privateAuraBorderScale
    if rpScale and rpScale ~= 1.0 then
        frame.SF_PrivateAuraBorderScaleOverride = rpScale
    else
        frame.SF_PrivateAuraBorderScaleOverride = nil
    end
end

-- ============================================================================
-- ANCHOR CLEAR HELPERS
-- Module-private. Stale handle IDs from a previous session are harmless
-- no-ops when removed, so no guards are needed (Grid2 pattern).
-- ============================================================================

local function ClearFrameOverlayAnchors(frame)
    local handles = frame.SF_PrivateAuraOverlayHandles
    if not handles then return end
    for i = 1, #handles do
        if handles[i] then
            RemovePrivateAuraAnchor(handles[i])
        end
    end
    return wipe(handles)
end

local function ClearFrameBorderAnchors(frame)
    local handles = frame.SF_PrivateAuraFrameBorderHandles
    if not handles then return end
    for i = 1, #handles do
        if handles[i] then
            RemovePrivateAuraAnchor(handles[i])
            handles[i] = nil
        end
    end
end

-- ============================================================================
-- TEXT OVERLAY (icon-less, timer/stack only)
--
-- A second set of containers at the same anchor as the icon, registered with
-- icon size 0.001 so Blizzard renders no icon texture but DOES render the
-- cooldown timer and stack count. The overlay containers track the same aura
-- slots as the icon containers so timers/stacks always match the icon.
-- ============================================================================

-- Build / position the overlay container frames. Does NOT register anchors
-- (that happens in DoAddOverlayAnchors below).
local function LayoutOverlayFrames(frame)
    if not frame then return end
    if InCombatLockdown() then return end

    local isRaid       = IsInRaid()
    local raidProfile  = BF:GetRaidProfile()
    local pp           = BF:GetActivePartyProfile()
    local activeFlat   = isRaid and raidProfile or pp
    local aurasP       = BF:GetSectionProfile("auras", activeFlat) or {}
    local paP          = aurasP.privateAuras or {}

    -- Overlay is controlled exclusively by per-encounter / per-dungeon
    -- override (acDB). When showOverlay is false, tear everything down.
    local instanceOverride = GetActiveInstanceOverride()
    local showOverlay = instanceOverride and instanceOverride.showOverlay == true

    if not showOverlay then
        ClearFrameOverlayAnchors(frame)
        local existing = frame.SF_PrivateAuraOverlayFrames
        if existing then
            for i = 1, #existing do
                local c = existing[i]
                if c then
                    c:Hide()
                    c:ClearAllPoints()
                    c:SetParent(nil)
                end
            end
            frame.SF_PrivateAuraOverlayFrames = nil
        end
        frame.SF_PrivateAuraOverlayHandles = nil
        return
    end

    local maxIcons = paP.maxPrivateAuras or 3
    local iconSize = paP.privateAuraSize or (isRaid and 12 or 14)

    -- Overlay mirrors the icon anchor / grow direction. Per-layout overlay-
    -- specific offset/scale keys were removed in an earlier refactor.
    local ovAnchor  = paP.privateAuraAnchorPoint or "TOPRIGHT"
    local ovOffX    = paP.privateAuraOffsetX or 0
    local ovOffY    = paP.privateAuraOffsetY or 0
    local ovGrowDir = paP.privateAuraGrowDirection or ""
    if not ovGrowDir or ovGrowDir == "" then
        if     ovAnchor:find("LEFT")   then ovGrowDir = "RIGHT"
        elseif ovAnchor == "TOP"       then ovGrowDir = "DOWN"
        elseif ovAnchor == "BOTTOM"    then ovGrowDir = "UP"
        else                                ovGrowDir = "LEFT" end
    end

    -- Same 30px / scaleFactor trick as the icon path.
    local scaleFactor    = (iconSize / 30)
    local iconSizeScaled = 30
    local nudgeX = ovAnchor:find("LEFT") and 1 or ovAnchor:find("RIGHT") and -1 or 0
    local nudgeY = ovAnchor:find("TOP")  and -1 or ovAnchor:find("BOTTOM") and 1 or 0
    local sumX = (ovGrowDir == "RIGHT" and iconSizeScaled or ovGrowDir == "LEFT" and -iconSizeScaled or 0)
    local sumY = (ovGrowDir == "UP"    and iconSizeScaled or ovGrowDir == "DOWN" and -iconSizeScaled or 0)

    -- Overlay containers sit above icon containers (+28).
    local overlayLevel = frame:GetFrameLevel() + 28

    local overlayFrames = frame.SF_PrivateAuraOverlayFrames
    if not overlayFrames then
        frame.SF_PrivateAuraOverlayFrames = {}
        overlayFrames = frame.SF_PrivateAuraOverlayFrames
    end

    -- Build maxIcons VISIBLE slots, iterating past maxIcons to collect enough
    -- when early indices are hidden. Mirrors the icon-path index map exactly.
    local hiddenIndices = ResolveHiddenIndices(frame)
    local numVisible = 0
    local idx = 1
    while numVisible < maxIcons do
        if not (hiddenIndices and hiddenIndices[idx]) then
            numVisible = numVisible + 1
            local c = overlayFrames[numVisible] or CreateFrame("Frame", nil, frame)
            c:ClearAllPoints()
            local ovPosX = nudgeX + ovOffX + (numVisible - 1) * sumX
            local ovPosY = nudgeY + ovOffY + (numVisible - 1) * sumY
            if BF.AuraCache and BF.AuraCache.aurasAbovePowerBar
                and frame.powerBar and frame.powerBar:IsShown() and frame.healthBar
                and (ovAnchor == "BOTTOM" or ovAnchor == "BOTTOMLEFT" or ovAnchor == "BOTTOMRIGHT") then
                local anchorFrame = frame.healthBar.clipFrame or frame.healthBar
                c:SetPoint(ovAnchor, anchorFrame, ovAnchor, ovPosX, ovPosY)
            else
                c:SetPoint(ovAnchor, frame, ovAnchor, ovPosX, ovPosY)
            end
            c:SetScale(scaleFactor)
            c:SetSize(iconSizeScaled, iconSizeScaled)
            c:SetFrameStrata(frame:GetFrameStrata())
            c:SetFrameLevel(overlayLevel)
            c:Show()
            overlayFrames[numVisible] = c
        end
        idx = idx + 1
        if idx > maxIcons + 20 then break end
    end

    -- Hide / clear excess overlay frames from a previous larger maxIcons.
    for i = numVisible + 1, #overlayFrames do
        overlayFrames[i] = nil
    end
end

-- Register overlay anchors against the current overlay frames.
-- Mutates the shared BF_PrivateAuraOverlayAnchor descriptor per-iteration.
local function DoAddOverlayAnchors(frame, unit)
    local overlayFrames = frame.SF_PrivateAuraOverlayFrames
    if not overlayFrames or #overlayFrames == 0 then return end

    local overlayHandles = ClearFrameOverlayAnchors(frame)
    if not overlayHandles then
        frame.SF_PrivateAuraOverlayHandles = {}
        overlayHandles = frame.SF_PrivateAuraOverlayHandles
    end

    -- Use the same index map the icon path uses, so overlay auraIndex
    -- matches the icon auraIndex for each slot.
    local indexMap = frame.SF_PrivateAuraIndexMap

    local ovAnchor    = BF_PrivateAuraOverlayAnchor
    local ovIcon      = ovAnchor.iconInfo.iconAnchor
    ovAnchor.isContainer = false
    ovAnchor.unitToken   = unit
    local maxOverlay = #overlayFrames
    for i = 1, maxOverlay do
        local c = overlayFrames[i]
        ovAnchor.parent     = c
        ovAnchor.auraIndex  = (indexMap and indexMap[i]) or i
        ovIcon.relativeTo   = c
        overlayHandles[i] = AddPrivateAuraAnchor(ovAnchor)
    end
    -- Don't leave a strong reference to the last container in the shared descriptor.
    ovAnchor.parent   = nil
    ovIcon.relativeTo = nil
end

-- Public entry point: layout + register overlay anchors.
function BF:UpdatePrivateAuraOverlay(frame)
    if not customizationsEnabled() then return end
    if not frame or not frame.unit then return end
    if InCombatLockdown() then return end
    LayoutOverlayFrames(frame)
    DoAddOverlayAnchors(frame, frame.unit)
end

-- Public entry point: re-register overlay anchors only (no layout).
-- Used on unit-change hot path. Layout has already run for current settings.
function BF:RegisterPrivateAuraOverlayAnchorsOnly(frame)
    if not customizationsEnabled() then return end
    if not frame or not frame.unit then return end
    if InCombatLockdown() then return end
    DoAddOverlayAnchors(frame, frame.unit)
end

-- ============================================================================
-- FRAME BORDER (Group B)
--
-- A separate set of containers covering the entire unit frame, with the
-- Blizzard private-aura widget scaled up to render its border ring around
-- the whole frame. Independent of icons / overlay / dispel.
-- ============================================================================

-- Build / position the border container + per-slot sub-containers.
local function LayoutBorderContainer(frame)
    if not frame then return end

    local isRaid      = IsInRaid()
    local raidProfile = BF:GetRaidProfile()
    local pp          = BF:GetActivePartyProfile()
    local activeFlat  = isRaid and raidProfile or pp
    local aurasP      = BF:GetSectionProfile("auras", activeFlat) or {}
    local paP         = aurasP.privateAuras or {}

    -- Priority order for showBorder:
    -- 1. Global raid PA override (raid instances only, when enabled)
    -- 2. Per-encounter override (set on ZONE_CHANGED)
    -- 3. Dungeon global profile (when in a non-raid instance)
    -- 4. Default: no border
    local p_border          = BF.acDB and BF.acDB.profile
    local globalEnabled     = p_border and p_border.enableGlobalPAOverrides
    local instanceTypeBorder = select(2, IsInInstance())
    local globalApplies     = globalEnabled and (instanceTypeBorder == "raid")
    local gp                = globalApplies and p_border.globalPASettings
    local encOverride       = frame.SF_EncounterBorderOverride
    local showBorder
    if globalApplies then
        showBorder = gp and gp.showBorder == true
    elseif encOverride and encOverride.showBorder ~= nil then
        showBorder = encOverride.showBorder == true
    else
        local inDungeon = (instanceTypeBorder == "party")
        if inDungeon then
            local dp = p_border and p_border.dungeonPASettings
            showBorder = dp ~= nil and dp.showBorder == true
        else
            showBorder = false
        end
    end

    if not showBorder then
        -- Tear down every leftover frame and state field. Nothing related to
        -- the border feature should persist when it is disabled.
        ClearFrameBorderAnchors(frame)
        local subContainers = frame.SF_PrivateAuraFrameBorderSubContainers
        if subContainers then
            for i = 1, #subContainers do
                local sub = subContainers[i]
                if sub then
                    sub:Hide()
                    sub:ClearAllPoints()
                    sub:SetParent(nil)
                end
            end
            frame.SF_PrivateAuraFrameBorderSubContainers = nil
        end
        local borderContainer = frame.SF_PrivateAuraFrameBorderContainer
        if borderContainer then
            borderContainer:Hide()
            borderContainer:ClearAllPoints()
            borderContainer:SetParent(nil)
            frame.SF_PrivateAuraFrameBorderContainer = nil
        end
        frame.SF_PrivateAuraFrameBorderHandles = nil
        frame.SF_PrivateAuraBorderUnit         = nil
        frame.SF_PrivateAuraBorderIconW        = nil
        frame.SF_PrivateAuraBorderScale        = nil
        frame.SF_PrivateAuraBorderMaxSlots     = nil
        return
    end

    local fw = frame:GetWidth()
    local fh = frame:GetHeight()
    if not fw or not fh or fw <= 0 or fh <= 0 then return end

    local container = frame.SF_PrivateAuraFrameBorderContainer
    if not container then
        container = CreateFrame("Frame", nil, frame)
        container:EnableMouse(false)
        container:SetMouseClickEnabled(false)
        local cover = container:CreateTexture(nil, "OVERLAY", nil, 7)
        cover:SetAllPoints(container)
        container.SF_CoverTexture = cover
        frame.SF_PrivateAuraFrameBorderContainer = container
    end

    container:ClearAllPoints()
    container:SetPoint("CENTER", frame, "CENTER", 0, 0)
    container:SetSize(0.001, 0.001)
    container:SetScale(1)
    container:SetAlpha(1)

    -- Container frame level. Default F+14: above target highlight (F+13),
    -- below text (F+16). Per raid/party override available via acDB.
    local borderLevel
    if BF.acDB then
        borderLevel = isRaid and BF.acDB.profile.privateAuraBorderFrameLevelRaid
                             or BF.acDB.profile.privateAuraBorderFrameLevelParty
    end
    borderLevel = borderLevel or 14
    container:SetFrameStrata(frame:GetFrameStrata())
    container:SetFrameLevel(frame:GetFrameLevel() + borderLevel)

    local cover = container.SF_CoverTexture
    if cover then cover:Hide() end

    -- Auto-scale: derive widthRatio and borderScale from the frame's aspect
    -- ratio using linear formulas fitted to two known-good configurations:
    --   93x50  -> widthRatio=5.35, borderScale=0.67
    --   102x80 -> widthRatio=2.25, borderScale=1.05
    local autoScaleKey  = isRaid and "privateAuraBorderAutoScaleRaid"  or "privateAuraBorderAutoScaleParty"
    local widthRatioKey = isRaid and "privateAuraBorderWidthRatioRaid" or "privateAuraBorderWidthRatioParty"
    local autoScale     = not (BF.acDB and BF.acDB.profile[autoScaleKey] == false)
    local aspect        = fw / fh
    local widthRatio, autoBorderScale
    if autoScale then
        widthRatio      = math.max(0.1,  5.2991 * aspect - 4.5064)
        autoBorderScale = math.max(0.01, -0.6496 * aspect + 1.8782)
    else
        widthRatio      = (BF.acDB and BF.acDB.profile[widthRatioKey]) or 2.6
        autoBorderScale = 1.0
    end
    local userScale
    if BF.acDB then
        userScale = isRaid and BF.acDB.profile.privateAuraFrameBorderScaleRaid
                           or BF.acDB.profile.privateAuraFrameBorderScaleParty
    end
    userScale = userScale or 1.0
    local iconW  = fw * widthRatio / 10
    local bScale = 2 * 10 * autoBorderScale * userScale

    -- One sub-container per private aura slot. Each slot needs its own parent
    -- frame so Blizzard creates a separate widget per slot. All sub-containers
    -- are positioned identically (covering the frame); whichever slot is
    -- active draws its border ring.
    local maxSlots = paP.maxPrivateAuras or 3
    local subContainers = frame.SF_PrivateAuraFrameBorderSubContainers
    if not subContainers then
        subContainers = {}
        frame.SF_PrivateAuraFrameBorderSubContainers = subContainers
    end

    -- Draw order priority mirrors the showBorder block above.
    local drawOrder
    if globalApplies then
        drawOrder = (gp and gp.drawOrder) or "first"
    elseif encOverride and encOverride.drawOrder then
        drawOrder = encOverride.drawOrder
    else
        local dp = (instanceTypeBorder == "party") and BF.acDB and BF.acDB.profile and
                   (BF.acDB.profile.dungeonPASettings or {})
        drawOrder = (dp and dp.drawOrder) or "first"
    end
    local baseLevel = container:GetFrameLevel()
    for i = 1, maxSlots do
        local sub = subContainers[i]
        if not sub then
            sub = CreateFrame("Frame", nil, container)
            sub:EnableMouse(false)
            sub:SetMouseClickEnabled(false)
            subContainers[i] = sub
        end
        sub:ClearAllPoints()
        sub:SetAllPoints(container)
        sub:SetSize(0.001, 0.001)
        sub:SetFrameStrata(container:GetFrameStrata())
        local slotLevel
        if drawOrder == "last" then
            slotLevel = baseLevel + (i - 1)
        else  -- "first"
            slotLevel = baseLevel + (maxSlots - i)
        end
        sub:SetFrameLevel(slotLevel)
        sub:Show()
    end
    -- Hide and clear extra sub-containers if maxSlots shrank.
    for i = maxSlots + 1, #subContainers do
        subContainers[i]:Hide()
        subContainers[i] = nil
    end

    -- Stash per-frame border geometry for DoAddBorderAnchors.
    frame.SF_PrivateAuraBorderIconW    = math.max(iconW, 0.001)
    frame.SF_PrivateAuraBorderScale    = bScale
    frame.SF_PrivateAuraBorderMaxSlots = maxSlots

    container:Show()
    -- Border has its own unit tracker so DoAddBorderAnchors re-registers.
    frame.SF_PrivateAuraBorderUnit = nil
end

-- Register border anchors against the current sub-containers.
-- Mutates the shared BF_PrivateAuraFrameBorderAnchor descriptor per-iteration.
local function DoAddBorderAnchors(f, unit)
    if not f or f.SF_PrivateAuraBorderUnit == unit then return end
    local borderContainer = f.SF_PrivateAuraFrameBorderContainer
    if not borderContainer or not borderContainer:IsShown() then return end
    local subContainers = f.SF_PrivateAuraFrameBorderSubContainers
    local maxSlots      = f.SF_PrivateAuraBorderMaxSlots
    if not subContainers or not maxSlots or maxSlots == 0 then return end
    ClearFrameBorderAnchors(f)
    if not f.SF_PrivateAuraFrameBorderHandles then
        f.SF_PrivateAuraFrameBorderHandles = {}
    end
    local handles = f.SF_PrivateAuraFrameBorderHandles

    -- Resolve border-specific hidden slots. hiddenAuraIndices only affects
    -- icons; the border has its own hideFirstSlotBorder toggle.
    local encOverride = f.SF_EncounterBorderOverride
    local borderHiddenSlots = nil
    local hideFirst = false
    if encOverride and encOverride.hideFirstSlotBorder ~= nil then
        hideFirst = encOverride.hideFirstSlotBorder
    end
    if not hideFirst then
        local instanceOverride = GetActiveInstanceOverride()
        hideFirst = instanceOverride and instanceOverride.hideFirstSlotBorder
    end
    if not hideFirst then
        local instanceType = select(2, IsInInstance())
        local inDungeon = (instanceType == "party")
        local dp = inDungeon and BF.acDB and BF.acDB.profile and
                   (BF.acDB.profile.dungeonPASettings or {})
        hideFirst = dp and dp.hideFirstSlotBorder
    end
    if hideFirst then borderHiddenSlots = { [1] = true } end

    local bAnchor = BF_PrivateAuraFrameBorderAnchor
    local bInfo   = bAnchor.iconInfo
    local bIcon   = bInfo.iconAnchor
    bAnchor.isContainer = false
    bAnchor.unitToken   = unit
    bInfo.iconWidth     = f.SF_PrivateAuraBorderIconW or 0.001
    bInfo.iconHeight    = 0.001
    bInfo.borderScale   = f.SF_PrivateAuraBorderScale

    for i = 1, maxSlots do
        local sub = subContainers[i]
        if sub and not (borderHiddenSlots and borderHiddenSlots[i]) then
            bAnchor.parent    = sub
            bAnchor.auraIndex = i
            bIcon.relativeTo  = sub
            handles[i] = AddPrivateAuraAnchor(bAnchor)
        end
    end
    bAnchor.parent   = nil
    bIcon.relativeTo = nil
    f.SF_PrivateAuraBorderUnit = unit
end

-- Public entry point: layout border container + sub-containers + register
-- anchors. Combat-tolerant: AddPrivateAuraAnchor / RemovePrivateAuraAnchor
-- inside the helpers are pcall-wrapped via the shared descriptor's silent
-- failure path -- if combat-restricted, the border simply doesn't re-render.
function BF:UpdatePrivateAuraFrameBorder(frame)
    if not customizationsEnabled() then return end
    if not frame or not frame.unit then return end
    LayoutBorderContainer(frame)
    DoAddBorderAnchors(frame, frame.unit)
end

function BF:RefreshAllPrivateAuraFrameBorders()
    if not customizationsEnabled() then return end
    if not self.activeFrames then return end
    for frame in pairs(self.activeFrames) do
        if frame and frame.unit then
            self:UpdatePrivateAuraFrameBorder(frame)
        end
    end
end

-- Public entry point: re-register border anchors only (no layout). Used on
-- unit-change hot path. Layout has already run for current settings; the
-- existing border container/sub-containers are reused as-is and only the
-- anchors need to rebind to the new unit.
function BF:RegisterPrivateAuraBorderAnchorsOnly(frame)
    if not customizationsEnabled() then return end
    if not frame or not frame.unit then return end
    if frame.unit ~= frame.SF_PrivateAuraBorderUnit then
        DoAddBorderAnchors(frame, frame.unit)
    end
end

-- ============================================================================
-- KILLSWITCH TEAR-DOWN
--
-- Wipes every SF_* field this module ever wrote and destroys every frame this
-- module ever created on a single unit frame. Called from the killswitch
-- setter on the OFF transition.
-- ============================================================================

local function tearDownAllCustomizationState(frame)
    if not frame then return end

    -- Override fields read by the icon path
    frame.SF_PrivateAuraIndexMap            = nil
    frame.SF_PrivateAuraIconHidden          = nil
    frame.SF_PrivateAuraBorderScaleOverride = nil

    -- Overlay state
    local overlayHandles = frame.SF_PrivateAuraOverlayHandles
    if overlayHandles then
        for i = 1, #overlayHandles do
            if overlayHandles[i] then
                pcall(RemovePrivateAuraAnchor, overlayHandles[i])
            end
        end
    end
    frame.SF_PrivateAuraOverlayHandles = nil
    local overlayFrames = frame.SF_PrivateAuraOverlayFrames
    if overlayFrames then
        for i = 1, #overlayFrames do
            local c = overlayFrames[i]
            if c then
                c:Hide()
                c:ClearAllPoints()
                c:SetParent(nil)
            end
        end
    end
    frame.SF_PrivateAuraOverlayFrames = nil

    -- Frame border state
    local borderHandles = frame.SF_PrivateAuraFrameBorderHandles
    if borderHandles then
        for i = 1, #borderHandles do
            if borderHandles[i] then
                pcall(RemovePrivateAuraAnchor, borderHandles[i])
            end
        end
    end
    frame.SF_PrivateAuraFrameBorderHandles = nil
    local subContainers = frame.SF_PrivateAuraFrameBorderSubContainers
    if subContainers then
        for i = 1, #subContainers do
            local sub = subContainers[i]
            if sub then
                sub:Hide()
                sub:ClearAllPoints()
                sub:SetParent(nil)
            end
        end
    end
    frame.SF_PrivateAuraFrameBorderSubContainers = nil
    local borderContainer = frame.SF_PrivateAuraFrameBorderContainer
    if borderContainer then
        borderContainer:Hide()
        borderContainer:ClearAllPoints()
        borderContainer:SetParent(nil)
    end
    frame.SF_PrivateAuraFrameBorderContainer = nil
    frame.SF_PrivateAuraBorderUnit       = nil
    frame.SF_PrivateAuraBorderIconW      = nil
    frame.SF_PrivateAuraBorderScale      = nil
    frame.SF_PrivateAuraBorderMaxSlots   = nil

    -- NOTE: Blizzard dispel overlay state (SF_PrivateAuraDispelOverlay*) is
    -- NOT touched here. The dispel overlay is a regular feature owned by
    -- PrivateAuras.lua, gated by its own `dispelIndicatorOverlayMode`
    -- setting, and unrelated to the customizations killswitch.

    -- Encounter override caches
    frame.SF_EncounterIconOverride   = nil
    frame.SF_EncounterBorderOverride = nil
end

-- Tear down the icon wrapper / containers so the icon path rebuilds fresh on
-- the next layout pass. Delegates to DisablePrivateAuraIndicators which is
-- the single centralized PA cleanup path (removes anchors, destroys
-- containers, nils all tracking fields).
local function tearDownIconPathState(frame)
    if not frame then return end
    if BF.DisablePrivateAuraIcons then BF:DisablePrivateAuraIcons(frame) end
end

-- ============================================================================
-- KILLSWITCH SETTER
-- ============================================================================
function BF:SetPrivateAuraCustomizationsEnabled(enabled)
    if not BF.acDB or not BF.acDB.profile then return end
    BF.acDB.profile.enablePrivateAuraCustomizations = enabled and true or nil

    if InCombatLockdown() then return end
    if not BF.activeFrames then return end

    if not enabled then
        -- OFF: wipe all customization state, tear down icon path so it
        -- rebuilds clean (without override fields), then run the icon path.
        for frame in pairs(BF.activeFrames) do
            tearDownAllCustomizationState(frame)
            tearDownIconPathState(frame)
            if BF.UpdatePrivateAuraAnchor then BF:UpdatePrivateAuraAnchor(frame) end
        end
    else
        -- ON: tear down icon path so it rebuilds with override fields applied,
        -- write the override fields, run icon + customization paths.
        for frame in pairs(BF.activeFrames) do
            tearDownIconPathState(frame)
            if BF.ApplyPrivateAuraOverrideFields then BF:ApplyPrivateAuraOverrideFields(frame) end
            if BF.UpdatePrivateAuraAnchor       then BF:UpdatePrivateAuraAnchor(frame)        end
            if BF.UpdatePrivateAuraOverlay      then BF:UpdatePrivateAuraOverlay(frame)       end
            if BF.UpdatePrivateAuraFrameBorder  then BF:UpdatePrivateAuraFrameBorder(frame)   end
            -- NOTE: Dispel overlay (UpdatePrivateAuraDispelOverlay) is NOT
            -- driven by the killswitch -- it's a regular feature owned by
            -- PrivateAuras.lua and gated by its own dispelIndicatorOverlayMode
            -- setting. Toggling the killswitch does not affect it.
        end
    end
end

-- ============================================================================
-- POST-COMBAT FLUSH (customization side)
--
-- If a unit changed during combat, the customization unit trackers may be
-- stale. On PLAYER_REGEN_ENABLED, sweep every active frame and re-register
-- any whose unit no longer matches the unit the anchors were last registered
-- against. The icon path has its own equivalent flush in PrivateAuras.lua.
-- ============================================================================
do
    local f = CreateFrame("Frame")
    f:RegisterEvent("PLAYER_REGEN_ENABLED")
    f:SetScript("OnEvent", function()
        if not customizationsEnabled() then return end
        if not BF.activeFrames then return end
        for frame in pairs(BF.activeFrames) do
            if frame.unit then
                -- Overlay re-registers when SF_PrivateAuraUnit drifts
                -- (overlay anchors share the icon-path unit tracker).
                if frame.unit ~= frame.SF_PrivateAuraUnit then
                    BF:UpdatePrivateAuraOverlay(frame)
                end
                -- Border has its own unit tracker.
                if frame.unit ~= frame.SF_PrivateAuraBorderUnit then
                    BF:UpdatePrivateAuraFrameBorder(frame)
                end
                -- NOTE: Dispel overlay flush is handled in PrivateAuras.lua,
                -- not here. It's not a customization.
            end
        end
    end)
end
