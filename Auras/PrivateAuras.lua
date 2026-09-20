-- ============================================================
-- BuzzardFrames: PrivateAuras.lua
-- Private aura icon indicator following Grid2's exact pattern.
--
-- Grid2 reference:
--   modules/IndicatorPrivateAuras.lua (Icon_Create/Layout/Update/Disable/UpdateDB)
--
-- The icon indicator reads opaque "override" fields written onto
-- unit frames by the customization module:
--   frame.SF_PrivateAuraIndexMap            -- slot -> auraIndex
--   frame.SF_PrivateAuraIconHidden          -- bool
--   frame.SF_PrivateAuraBorderScaleOverride -- number
-- All three are nil when the customization killswitch is off.
--
-- Tooltip suppression (disableTip) is a standard raid/party setting
-- read directly from rpDB.profile.tooltips.suppressPrivateAuraTooltip
-- in Layout, not part of the customization override pipeline.
-- ============================================================

local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")
if not BF then
    error("BuzzardFrames: PrivateAuras.lua loaded before Core.lua!")
    return
end

local AddPrivateAuraAnchor    = C_UnitAuras.AddPrivateAuraAnchor
local RemovePrivateAuraAnchor = C_UnitAuras.RemovePrivateAuraAnchor
local wipe                    = wipe
local pairs                   = pairs
local next                    = next
local InCombatLockdown        = InCombatLockdown

-- Fix for 12.0.5 private-auras bug, when a container is removed/added, private-aura icons are ignoring frame-levels
-- and displayed behind the unit frame, the workaround: use a higher strata for private-aura containers.
local strataFix = { BACKGROUND = 'LOW', LOW = 'MEDIUM', MEDIUM = 'HIGH', HIGH = 'DIALOG' }

-- ============================================================
-- COMBAT QUEUE (Grid2 PARITY: QueueUpdate pattern)
-- ============================================================
local combatQueue = {}

-- ============================================================
-- DEBUG INSTRUMENTATION
-- ============================================================
local function pd(fmt, ...)
    if not BF._debugPrivateAuras then return end
    local payload = string.format(fmt, ...):gsub("|", "||")
    print("|cff33ff99BF PA:|r " .. payload)
end

local function fid(frame)
    local name = frame:GetName() or "?"
    local short = name:sub(-7)
    return string.format("%s[%s]", tostring(frame.unit or "nil"), short)
end

-- ============================================================
-- SHARED ICON-PATH ANCHOR DESCRIPTOR
-- One shared descriptor mutated per-call (Grid2 pattern).
-- ============================================================
local BF_PrivateAuraAnchor = {
    iconInfo = {
        iconAnchor = {
            offsetX       = 0,
            offsetY       = 0,
            point         = 'CENTER',
            relativePoint = 'CENTER',
        },
    },
}

-- ============================================================
-- ANCHOR CLEAR HELPER
-- ============================================================
local function ClearFrameAuraAnchors(frame)
    local auraHandles = frame.SF_PrivateAuraHandles
    if not auraHandles then return end
    if #auraHandles > 0 then
        pd("ClearIconAnchors %s removing %d handles", fid(frame), #auraHandles)
    end
    for i = 1, #auraHandles do
        if auraHandles[i] then
            RemovePrivateAuraAnchor(auraHandles[i])
        end
    end
    return wipe(auraHandles)
end

-- ============================================================
-- ShouldDisablePrivateAuras (pure predicate)
-- ============================================================
local function ShouldDisablePrivateAuras(frame)
    local parentHeader = frame:GetParent()
    -- Pets don't have private auras.
    if parentHeader and parentHeader.isPetFrame then return true end
    if parentHeader and parentHeader.isCustomFrame and not parentHeader.moduleShowPrivateAuras then
        return true
    end

    -- Grid2 pattern: read from pre-resolved AuraCache (populated by
    -- UpdateAuraSizeCache on every profile/context change) rather than
    -- re-resolving the profile on every Update call.
    -- CFG-aware lookup: GetAuraCacheForFrame returns the per-CFG cache
    -- for custom frame group frames so they can have their own
    -- showPrivateAuras setting; falls through to BF.AuraCache otherwise.
    local ac = BF:GetAuraCacheForFrame(frame)
    if ac and ac.showPrivateAuras == false then return true end

    return false
end

-- ============================================================
-- SetPrivateAuraFirstRegistrationDone
-- ============================================================
function BF:SetPrivateAuraFirstRegistrationDone()
    -- intentional no-op: anchor registration happens naturally via
    -- UpdateIndicators -> indicator:Update as OnAttributeChanged fires
    -- for each frame.
end

-- ============================================================
-- DoAddPrivateAuraAnchors (icon path anchors-only)
-- ============================================================
local function DoAddPrivateAuraAnchors(f, unit)
    if not f or f.SF_PrivateAuraUnit == unit then
        if f then pd("DoAdd SKIP (unit unchanged) %s", fid(f)) end
        return
    end
    pd("DoAdd ENTER %s  old=%s new=%s",
        fid(f), tostring(f.SF_PrivateAuraUnit), tostring(unit))

    local auraHandles = ClearFrameAuraAnchors(f)
    if not auraHandles then
        f.SF_PrivateAuraHandles = {}
        auraHandles = f.SF_PrivateAuraHandles
    end

    local auraFrames = f.SF_PrivateAuraFrames
    if not auraFrames then
        pd("DoAdd BAIL (no containers) %s", fid(f))
        return
    end

    local indexMap = f.SF_PrivateAuraIndexMap
    local auraAnchor  = BF_PrivateAuraAnchor
    local iconAnchor  = auraAnchor.iconInfo.iconAnchor
    auraAnchor.isContainer = false
    auraAnchor.unitToken   = unit

    local numContainers = #auraFrames
    pd("DoAdd register %d icon slots %s", numContainers, fid(f))
    for slot = 1, numContainers do
        local container = auraFrames[slot]
        if not container then break end
        auraAnchor.parent     = container
        auraAnchor.auraIndex  = (indexMap and indexMap[slot]) or slot
        iconAnchor.relativeTo = container
        auraHandles[slot] = AddPrivateAuraAnchor(auraAnchor)
        pd("  slot=%d auraIndex=%d handle=%s",
            slot, auraAnchor.auraIndex, tostring(auraHandles[slot]))
    end
    auraAnchor.parent     = nil
    iconAnchor.relativeTo = nil

    f.SF_PrivateAuraUnit = unit
end


-- ############################################################
-- INDICATOR: privateAuraIcons
-- Grid2 parity: IndicatorPrivateAuras.lua
-- ############################################################
local IconIndicator = BF.indicatorPrototype:new("privateAuraIcons")

-- ── Icon_Create (Grid2 Icon_Create via Acquire) ─────────────
-- Grid2 pattern: Acquire creates the frame in Create and stores it
-- at parent[self.name] so GetFrame returns it and the generic Layout
-- loop (which gates on GetFrame) can run.
function IconIndicator:Create(parent)
    local f = parent[self.name]
    if not f then
        f = CreateFrame("Frame", nil, parent)
        f:Hide()
        parent[self.name] = f
        parent.SF_PrivateAuraWrapper = f
    end
    f.SF_PrivateAuraHandles = f.SF_PrivateAuraHandles or {}
    parent.SF_PrivateAuraHandles = parent.SF_PrivateAuraHandles or {}
end

-- ── Icon_Layout (Grid2 Icon_Layout) ──────────────────────────
-- Full geometry pass: creates/positions wrapper + per-slot containers,
-- sets descriptor fields, nils the unit tracker so Update re-registers.
function IconIndicator:Layout(parent)
    if not parent then return end
    if InCombatLockdown() then
        combatQueue[parent] = true
        return
    end

    if ShouldDisablePrivateAuras(parent) then
        self:Disable(parent)
        return
    end

    -- Grid2 pattern (Icon_UpdateDB): read geometry from pre-resolved AuraCache
    -- rather than re-resolving the profile on every Layout call. AuraCache is
    -- populated by UpdateAuraSizeCache (runs on every profile/context change).
    -- This ensures all frames always use the same geometry regardless of when
    -- their Layout runs, eliminating stale-context bugs where a frame that
    -- missed a RefreshAllPrivateAuraIcons sweep keeps old size/position.
    -- CFG-aware: GetAuraCacheForFrame returns the per-CFG _auraCache for
    -- custom frame group frames so they honour their own private aura
    -- settings; falls through to BF.AuraCache for main raid/party frames.
    local ac = BF:GetAuraCacheForFrame(parent)
    local maxIcons    = ac.privateAuraMax        or 3
    local iconSize    = ac.privateAuraSize       or 14
    local anchorPoint = ac.privateAuraAnchor     or "TOPRIGHT"
    local showDuration = ac.privateAuraShowDur   ~= false
    local showSwipe    = ac.privateAuraShowSwipe ~= false
    local disableTip   = ac.suppressPrivateAuraTooltip

    local f = parent
    -- Grid2 line 94: nil the unit tracker so DoAddPrivateAuraAnchors
    -- re-registers anchors after layout.
    f.SF_PrivateAuraUnit = nil

    local auraAnchor = BF_PrivateAuraAnchor
    if not auraAnchor.iconInfo then
        auraAnchor.iconInfo = { iconAnchor = { offsetX=0, offsetY=0, point='CENTER', relativePoint='CENTER' } }
    end

    -- Read opaque override fields from customization module (nil when killswitch off).
    local iconHidden   = f.SF_PrivateAuraIconHidden
    local borderScale  = f.SF_PrivateAuraBorderScaleOverride

    auraAnchor.iconInfo.borderScale = borderScale
    auraAnchor.showCountdownFrame   = (not iconHidden) and showSwipe
    auraAnchor.showCountdownNumbers = showDuration

    -- Calculate offsets from pre-resolved AuraCache values.
    local nudgeX = anchorPoint:find("LEFT")   and  1 or anchorPoint:find("RIGHT")  and -1 or 0
    local nudgeY = anchorPoint:find("TOP")    and -1 or anchorPoint:find("BOTTOM") and  1 or 0
    local userOffX = ac.privateAuraOffsetX or 0
    local userOffY = ac.privateAuraOffsetY or 0
    local offsetX  = nudgeX + userOffX
    local offsetY  = nudgeY + userOffY

    -- Growth direction: pre-resolved by UpdateAuraSizeCache.
    local growDirection = ac.privateAuraGrowDir or "LEFT"

    -- Grid2 line 85-87: scale wrapper, use 32 as work size.
    local wrapper = f.SF_PrivateAuraWrapper
    local wrapperWasNew = false
    if not wrapper then
        wrapper = CreateFrame('frame', nil, f)
        f.SF_PrivateAuraWrapper = wrapper
        f[self.name] = wrapper
        wrapperWasNew = true
    end
    wrapper:SetScale(borderScale and 1 or iconSize/32)
    local iconSizeWork = borderScale and iconSize or 32
    local iconSpacing = ac.privateAuraIconSpacing or 1
    local sizeFull = iconSizeWork + iconSpacing

    -- Grid2 line 89-93: wrapper position + frame level.
    wrapper:ClearAllPoints()
    local wrapperRel = f
    if ac.aurasAbovePowerBar and f.powerBar and f.powerBar:IsShown() and f.healthBar
        and (anchorPoint == "BOTTOM" or anchorPoint == "BOTTOMLEFT" or anchorPoint == "BOTTOMRIGHT") then
        wrapperRel = f.healthBar.clipFrame or f.healthBar
    end
    wrapper:SetPoint(anchorPoint, wrapperRel, anchorPoint, offsetX, offsetY)
    -- Grid2 parity: SetFrameLevel in Layout, not in Update.
    wrapper:SetFrameLevel(f:GetFrameLevel() + 30)
    wrapper:SetFrameStrata(strataFix[f:GetFrameStrata()] or 'DIALOG')
    pd("Layout wrapper %s  new=%s  parentLvl=%d  wrapperLvl=%d",
        fid(f), tostring(wrapperWasNew),
        f:GetFrameLevel(), wrapper:GetFrameLevel())

    -- Grid2 line 94: nil unit tracker so Update re-registers.
    f.SF_PrivateAuraUnit = nil

    -- Grid2 line 96-97: set iconWidth/iconHeight on the descriptor.
    auraAnchor.iconInfo.iconWidth  = iconHidden and 0.001 or iconSizeWork
    auraAnchor.iconInfo.iconHeight = iconHidden and 0.001 or iconSizeWork

    -- Grid2 horMult / verMult derivation.
    local horMult, verMult = 0, 0
    if growDirection == "RIGHT" then horMult = 1
    elseif growDirection == "LEFT" then horMult = -1
    elseif growDirection == "DOWN" then verMult = -1
    elseif growDirection == "UP" then verMult = 1
    end

    -- Grid2 disableTip path.
    local frameSize = disableTip and 0.001 or iconSizeWork
    local adjustX   = disableTip and (iconSizeWork * horMult / 2) or 0
    local adjustY   = disableTip and (iconSizeWork * verMult / 2) or 0
    local slotOffX  = adjustX
    local slotOffY  = adjustY
    local sumX = sizeFull * horMult
    local sumY = sizeFull * verMult

    -- Read visibleIndices from the opaque field.
    local visibleIndices = f.SF_PrivateAuraIndexMap
    if not visibleIndices then
        visibleIndices = {}
        for i = 1, maxIcons do visibleIndices[i] = i end
    end

    -- Wrapper size (BF-specific: exact bounding box).
    local wrapperW, wrapperH
    if horMult ~= 0 then
        wrapperW = iconSizeWork * maxIcons + iconSpacing * (maxIcons - 1)
        wrapperH = iconSizeWork
    elseif verMult ~= 0 then
        wrapperW = iconSizeWork
        wrapperH = iconSizeWork * maxIcons + iconSpacing * (maxIcons - 1)
    else
        wrapperW = iconSizeWork
        wrapperH = iconSizeWork
    end
    wrapper:SetSize(wrapperW, wrapperH)

    -- Cardinal anchor for containers.
    local cardPoint
    if     growDirection == "RIGHT" then cardPoint = "LEFT"
    elseif growDirection == "LEFT"  then cardPoint = "RIGHT"
    elseif growDirection == "DOWN"  then cardPoint = "TOP"
    elseif growDirection == "UP"    then cardPoint = "BOTTOM"
    else                                 cardPoint = "LEFT"
    end

    -- Container loop (Grid2 lines 105-121).
    -- Reuse existing containers; create only if needed. The strataFix
    -- applied to the wrapper (line 260) handles the Blizzard frame-level
    -- bug — no need to destroy and recreate containers.
    ClearFrameAuraAnchors(f)
    local auraFrames = f.SF_PrivateAuraFrames
    if not auraFrames then
        f.SF_PrivateAuraFrames = {}
        auraFrames = f.SF_PrivateAuraFrames
    end

    local numVisible = #visibleIndices
    for slot = 1, numVisible do
        local container = auraFrames[slot] or CreateFrame('frame', nil, wrapper)
        container:ClearAllPoints()
        container:SetPoint(cardPoint, wrapper, cardPoint, slotOffX, slotOffY)
        container:SetSize(frameSize, frameSize)
        container:Show()
        slotOffX = slotOffX + sumX
        slotOffY = slotOffY + sumY
        auraFrames[slot] = container
    end
    for slot = numVisible + 1, #auraFrames do
        auraFrames[slot]:Hide()
    end

    wrapper:Show()
end

-- ── Icon_Update (Grid2 Icon_Update) ──────────────────────────
-- Anchors-only path. Layout must have run at least once.
function IconIndicator:Update(parent, unit)
    if not parent or not unit then return end
    if InCombatLockdown() then
        combatQueue[parent] = true
        return
    end
    if ShouldDisablePrivateAuras(parent) then
        self:Disable(parent)
        return
    end
    -- If containers don't exist yet, run Layout first (first unit assignment).
    if not parent.SF_PrivateAuraFrames then
        self:Layout(parent)
    end
    if unit ~= parent.SF_PrivateAuraUnit then
        DoAddPrivateAuraAnchors(parent, unit)
    end
end

-- ── Icon_Disable (Grid2 Icon_Disable) ────────────────────────
function IconIndicator:Disable(parent)
    if not parent then return end
    ClearFrameAuraAnchors(parent)
    local auraFrames = parent.SF_PrivateAuraFrames
    if auraFrames then
        for i = 1, #auraFrames do
            local c = auraFrames[i]
            if c then
                c:Hide()
                c:ClearAllPoints()
                c:SetParent(nil)
            end
        end
        parent.SF_PrivateAuraFrames = nil
    end
    local wrapper = parent.SF_PrivateAuraWrapper
    if wrapper then
        wrapper:Hide()
        wrapper:ClearAllPoints()
        wrapper:SetParent(nil)
        parent.SF_PrivateAuraWrapper = nil
        parent[self.name] = nil
    end
    parent.SF_PrivateAuraHandles = nil
    parent.SF_PrivateAuraUnit    = nil
end

function IconIndicator:GetFrame(parent)
    return parent[self.name]
end

-- Register the icon indicator.
BF:RegisterIndicator(IconIndicator)


-- ############################################################
-- PUBLIC API (icon indicator only)
-- ############################################################

function BF:DisablePrivateAuraIcons(frame)
    if not frame then return end
    IconIndicator:Disable(frame)
end

function BF:UpdatePrivateAuraAnchor(frame)
    if not frame or not frame.unit then return end
    if InCombatLockdown() then
        combatQueue[frame] = true
        return
    end
    IconIndicator:Layout(frame)
    IconIndicator:Update(frame, frame.unit)
end

-- Anchors-only (no layout), for external callers (Encounters.lua etc.)
function BF:UpdatePrivateAuraAnchors(frame, unit)
    if not frame or not unit then return end
    if unit ~= frame.SF_PrivateAuraUnit then
        DoAddPrivateAuraAnchors(frame, unit)
    end
end

function BF:RegisterPrivateAuraIconAnchorsOnly(frame)
    if not frame or not frame.unit then return end
    if InCombatLockdown() then
        combatQueue[frame] = true
        return
    end
    IconIndicator:Update(frame, frame.unit)
end

-- Keep LayoutPrivateAuraFrames as a public entry point for
-- Encounters.lua which calls it directly.
function BF:LayoutPrivateAuraFrames(frame)
    IconIndicator:Layout(frame)
end

-- Compatibility alias for external callers. The previous version
-- called LayoutFrameIndicators(frame) which iterated every registered
-- indicator (buffs, debuffs, big-def, important, crowd-control,
-- missing raid buff, etc.) — none of which depend on private aura
-- geometry. The scoped version lives in Auras/Auras.lua as
-- BF:RefreshPrivateAurasOnly and also handles the one legitimate
-- cross-effect (extraDebuffYOffset moving debuff positions when
-- separatePrivateAurasInRaid + BOTTOMLEFT is enabled).
-- See Docs/REFRESH_SCOPING_PLAN.md.
function BF:RefreshAllPrivateAuraIcons()
    if self.RefreshPrivateAurasOnly then
        self:RefreshPrivateAurasOnly()
    end
end


-- ############################################################
-- POST-COMBAT FLUSH (icon indicator)
-- ############################################################
do
    local f = CreateFrame("Frame")
    f:RegisterEvent("PLAYER_REGEN_ENABLED")
    f:SetScript("OnEvent", function()
        if not next(combatQueue) then return end
        for frame in pairs(combatQueue) do
            if frame and frame.unit and BF.activeFrames and BF.activeFrames[frame] then
                IconIndicator:Layout(frame)
                IconIndicator:Update(frame, frame.unit)
            end
        end
        wipe(combatQueue)
    end)
end
