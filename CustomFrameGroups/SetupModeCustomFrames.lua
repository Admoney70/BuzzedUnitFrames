-- ============================================================
-- BuzzardFrames: SetupModeCustomFrames.lua
-- Setup mode test frames for custom frame groups.
--
-- Creates insecure test frames per enabled custom frame group
-- when setup mode is active. Each group gets its own draggable
-- header with frames sized/positioned according to the group's
-- cf* layout settings. Positions are saved to the same
-- customFrameGroupPositions key that real detached headers use.
-- ============================================================
local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

local SETUP_FRAME_ALPHA   = 0.8
local SETUP_CONTENT_ALPHA = 0.625
local MAX_TEST_FRAMES     = 40  -- pool size per group
local floor = math.floor

-- CFG-specific purple tint (matches the drag handle color) so custom
-- frame test frames are visually distinct from raid/party (blue).
local CFG_BG_R, CFG_BG_G, CFG_BG_B, CFG_BG_A = 0.3, 0.1, 0.38, 0.7
-- Border: push each channel towards white by ~40% (same formula as GetSetupFrameColors)
local CFG_BR_R = math.min(1, CFG_BG_R + (1 - CFG_BG_R) * 0.4)
local CFG_BR_G = math.min(1, CFG_BG_G + (1 - CFG_BG_G) * 0.4)
local CFG_BR_B = math.min(1, CFG_BG_B + (1 - CFG_BG_B) * 0.4)
local CFG_BR_A = 0.8

local function OppositeCorner(anchor)
    local lr = anchor:find("LEFT") and "RIGHT" or "LEFT"
    local tb = anchor:find("TOP")  and "BOTTOM" or "TOP"
    return tb .. lr
end

-- ============================================================
-- PER-GROUP TEST HEADER POOL
-- _cfTestHeaders[groupIndex] = { header, frames, handle, ... }
-- Persists across setup mode toggles; Show/Hide controls visibility.
-- ============================================================
local _cfTestHeaders = {}

-- ============================================================
-- CREATE ONE TEST FRAME (matches CreateTestHeader pattern)
-- ============================================================
local function CreateTestFrame(parent, index)
    local frame = CreateFrame("Button", "BFCFTestFrame_" .. index, parent, "BackdropTemplate")
    frame:SetSize(70, 40)

    -- Background (CFG purple)
    local bg = BF.Texture(frame, nil, "BACKGROUND")
    bg:SetAllPoints(frame)
    bg:SetColorTexture(CFG_BG_R, CFG_BG_G, CFG_BG_B, CFG_BG_A)
    bg:SetAlpha(SETUP_CONTENT_ALPHA)
    frame.bg = bg

    -- Unit border (texture-based, matches real frames)
    local border = CreateFrame("Frame", nil, frame)
    border:SetAllPoints(frame)
    border:SetFrameLevel(frame:GetFrameLevel() + 10)
    border:EnableMouse(false)
    local function TEdge(p)
        local t = BF.Texture(p, nil, "OVERLAY")
        t:SetColorTexture(0, 0, 0, 0)
        t:Hide()
        return t
    end
    border.top    = TEdge(border)
    border.bottom = TEdge(border)
    border.left   = TEdge(border)
    border.right  = TEdge(border)
    frame.unitBorder = border

    frame:Hide()
    return frame
end

-- ============================================================
-- CREATE / GET A TEST HEADER FOR A CUSTOM FRAME GROUP
-- ============================================================
local function GetOrCreateTestHeader(groupIndex, groupName)
    local existing = _cfTestHeaders[groupIndex]
    if existing then
        -- Update label in case group was renamed
        if existing.handle and existing.handle._label then
            existing.handle._label:SetText("Custom Frame Group: " .. (groupName or ("Group " .. groupIndex)))
        end
        if existing.header and existing.header._label then
            existing.header._label:SetText("Custom Frame Group: " .. (groupName or ("Group " .. groupIndex)))
        end
        return existing
    end

    -- Create the header frame (insecure, HIGH strata to overlay real frames)
    local header = CreateFrame("Frame", "BFCFTestHeader_" .. groupIndex, UIParent)
    header:SetSize(1, 1)
    header:SetFrameStrata("HIGH")
    header:SetMovable(true)
    header:SetClampedToScreen(true)
    header:EnableMouse(false)
    header:Hide()

    -- Create the frame pool
    local frames = {}
    for i = 1, MAX_TEST_FRAMES do
        frames[i] = CreateTestFrame(header, groupIndex * 100 + i)
    end

    -- Label overlay (same style as UF test frame labels)
    local labelOverlay = CreateFrame("Frame", nil, header)
    labelOverlay:SetAllPoints(header)
    labelOverlay:SetFrameStrata("HIGH")
    labelOverlay:SetFrameLevel(200)
    local groupLabel = labelOverlay:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    groupLabel:SetText("Custom Frame Group: " .. (groupName or ("Group " .. groupIndex)))
    groupLabel:SetTextColor(1, 1, 1, 0.9)
    header._label = groupLabel

    -- Create the drag handle (matches SetupDetachedHeader pattern)
    local handle = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    handle:SetSize(200, 16)
    handle:SetFrameStrata("HIGH")
    handle:SetFrameLevel(110)
    handle:SetBackdrop({
        bgFile   = "Interface\\Buttons\\White8x8",
        edgeFile = "Interface\\Buttons\\White8x8",
        edgeSize = 1,
    })
    -- Purple tint to distinguish from main anchor (green) and test anchor (blue)
    handle:SetBackdropColor(0.5, 0.2, 0.6, 0.8)
    handle:SetBackdropBorderColor(0.7, 0.4, 0.9, 1)
    handle:EnableMouse(true)
    handle:SetMovable(true)
    handle:RegisterForDrag("LeftButton")

    local label = handle:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("CENTER")
    label:SetText(groupName or ("Group " .. groupIndex))
    label:SetTextColor(1, 1, 1)
    handle._label = label

    -- Pin handle above header
    local function SnapHandleToHeader()
        handle:ClearAllPoints()
        handle:SetPoint("BOTTOMLEFT", header, "TOPLEFT", 0, 2)
    end
    handle.SnapToParent = SnapHandleToHeader
    handle:HookScript("OnShow", SnapHandleToHeader)

    -- Entry table created early so closures can read entry.groupIndex,
    -- which gets updated by RemoveCustomFrameTestHeader when a group
    -- is deleted and indices shift.  Remaining fields are filled in
    -- at the bottom of this function.
    local entry = { groupIndex = groupIndex }

    -- Find the real detached header for this group index so we can
    -- move it in lockstep with the test header during drag.
    local function FindRealHeader()
        local posKey = "customFrame_" .. entry.groupIndex
        if not BF.groupsUsed then return nil end
        for _, h in ipairs(BF.groupsUsed) do
            if h.headerPosKey == posKey then return h end
        end
        return nil
    end

    local function SyncRealHeader()
        if InCombatLockdown() then return end
        local real = FindRealHeader()
        if not real then return end
        -- Read the group's layout anchor so both test and real headers
        -- anchor from the same corner.
        local groups = BF:GetCustomFrameGroups()
        local grp = groups and groups[entry.groupIndex]
        local anchor = (grp and grp.flat and grp.flat.raidLayoutAnchor) or "TOPLEFT"
        -- Get the anchor corner of the test header in screen coords.
        local ax = anchor:find("LEFT") and header:GetLeft() or header:GetRight()
        local ay = anchor:find("TOP")  and header:GetTop()  or header:GetBottom()
        if not ax or not ay then return end
        local ux, uy = UIParent:GetCenter()
        if not ux or not uy then return end
        -- Convert to CENTER-relative.
        local cx = ax - ux
        local cy = ay - uy
        local us = UIParent:GetEffectiveScale()
        -- The real CFG header is parented to its anchor frame, so move the
        -- ANCHOR FRAME (not the header) — SetPoint-ing the header to UIParent
        -- would un-parent it. The header follows because it's pinned to the
        -- anchor frame's corner.
        local af = BF.GetOrCreateCFGAnchorFrame and BF:GetOrCreateCFGAnchorFrame(entry.groupIndex)
        if af then
            local afs = af:GetEffectiveScale()
            af:ClearAllPoints()
            af:SetPoint(anchor, UIParent, "CENTER", cx * us / afs, cy * us / afs)
        else
            local rs = real:GetEffectiveScale()
            real:ClearAllPoints()
            real:SetPoint(anchor, UIParent, "CENTER", cx * us / rs, cy * us / rs)
        end
        -- Move real handle too
        if real._handle and real._handle.SnapToParent then
            real._handle.SnapToParent()
        end
    end

    -- Drag: move the test header and sync the real header in real time
    handle:SetScript("OnDragStart", function()
        if InCombatLockdown() then return end
        header:StartMoving()
        header:SetScript("OnUpdate", function()
            SnapHandleToHeader()
            SyncRealHeader()
        end)
    end)
    handle:SetScript("OnDragStop", function()
        header:StopMovingOrSizing()
        header:SetScript("OnUpdate", nil)
        SnapHandleToHeader()
        SyncRealHeader()
        -- Save position in CENTER-relative format using cfgLayoutAnchor
        local posKey = "customFrame_" .. entry.groupIndex
        local groups = BF:GetCustomFrameGroups()
        local grp = groups and groups[entry.groupIndex]
        local anchor = (grp and grp.flat and grp.flat.raidLayoutAnchor) or "TOPLEFT"
        local ax = anchor:find("LEFT") and header:GetLeft() or header:GetRight()
        local ay = anchor:find("TOP")  and header:GetTop()  or header:GetBottom()
        local ux, uy = UIParent:GetCenter()
        if ax and ay and ux and uy then
            local cx = math.floor(ax - ux + 0.5)
            local cy = math.floor(ay - uy + 0.5)
            local p = BF.cfgDB.profile
            if not p.customFrameGroupPositions then
                p.customFrameGroupPositions = {}
            end
            p.customFrameGroupPositions[posKey] = { anchor, cx, cy }
        end
        -- v53 Phase 2.2: position-level dirt for THIS group only. The real
        -- header is already re-placed below, so exit re-applies the saved
        -- position for this one group and rebuilds nothing.
        BF:MarkSetupDirty(entry.groupIndex, BF.SETUP_DIRTY_POS)
        -- Also apply saved position to the real header so it snaps pixel-perfect
        local real = FindRealHeader()
        if real then
            BF:RestoreDetachedHeaderPosition(real)
        end
        -- Notify options panel so sliders update
        BF:RefreshPanel("cfgPosition")
    end)

    -- Make cells draggable — moves the header (same pattern as raid/party test frames)
    for _, frame in ipairs(frames) do
        frame:RegisterForDrag("LeftButton")
        frame:SetScript("OnDragStart", function()
            if InCombatLockdown() then return end
            header:StartMoving()
            header:SetScript("OnUpdate", function()
                SyncRealHeader()
            end)
        end)
        frame:SetScript("OnDragStop", function()
            header:StopMovingOrSizing()
            header:SetScript("OnUpdate", nil)
            SyncRealHeader()
            -- Save position in CENTER-relative format using cfgLayoutAnchor
            local posKey = "customFrame_" .. entry.groupIndex
            local groups2 = BF:GetCustomFrameGroups()
            local grp2 = groups2 and groups2[entry.groupIndex]
            local anchor2 = (grp2 and grp2.flat and grp2.flat.raidLayoutAnchor) or "TOPLEFT"
            local ax2 = anchor2:find("LEFT") and header:GetLeft() or header:GetRight()
            local ay2 = anchor2:find("TOP")  and header:GetTop()  or header:GetBottom()
            local ux2, uy2 = UIParent:GetCenter()
            if ax2 and ay2 and ux2 and uy2 then
                local cx2 = math.floor(ax2 - ux2 + 0.5)
                local cy2 = math.floor(ay2 - uy2 + 0.5)
                local p = BF.cfgDB.profile
                if not p.customFrameGroupPositions then
                    p.customFrameGroupPositions = {}
                end
                p.customFrameGroupPositions[posKey] = { anchor2, cx2, cy2 }
            end
            -- v53 Phase 2.2: see the handle drag above.
            BF:MarkSetupDirty(entry.groupIndex, BF.SETUP_DIRTY_POS)
            local real = FindRealHeader()
            if real then
                BF:RestoreDetachedHeaderPosition(real)
            end
            BF:RefreshPanel("cfgPosition")
        end)
    end

    handle:Hide()

    entry.header     = header
    entry.frames     = frames
    entry.handle     = handle
    -- entry.groupIndex already set above (read by closures)
    _cfTestHeaders[groupIndex] = entry
    return entry
end

-- ============================================================
-- RESTORE POSITION FROM customFrameGroupPositions
-- ============================================================
local function RestoreTestHeaderPosition(header, groupIndex)
    local p = BF.cfgDB and BF.cfgDB.profile
    local positions = p and p.customFrameGroupPositions
    if not positions then return false end

    local posKey = "customFrame_" .. groupIndex
    local pos = positions[posKey]
    if not pos then return false end

    -- CENTER-relative format: { anchor, cx, cy }
    local anchor, cx, cy = pos[1], pos[2], pos[3]
    local us = UIParent:GetEffectiveScale()
    local s  = header:GetEffectiveScale()
    local ox = cx * us / s
    local oy = cy * us / s

    header:ClearAllPoints()
    header:SetPoint(anchor, UIParent, "CENTER", ox, oy)
    return true
end

-- ============================================================
-- APPLY VISUALS (border, health bar inset)
-- Mirrors _ApplyProfileVisualsToTestFrame from SetupModeUnlockMode.lua
-- ============================================================
local function ApplyVisualsToTestFrame(frame)
    local p = BF.db.profile
    local inset = p.enableBorder ~= false and (p.borderThickness or 1) or 0

    -- Health bar inset
    if frame.healthBar then
        frame.healthBar:ClearAllPoints()
        frame.healthBar:SetPoint("TOPLEFT",     frame, "TOPLEFT",      inset, -inset)
        frame.healthBar:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT",  -inset,  inset)
    end

    -- Border
    if frame.unitBorder then
        local b = frame.unitBorder
        if b.top and b.bottom and b.left and b.right then
            if p.enableBorder ~= false then
                local thickness = math.max(inset, 1)
                local c = { r = CFG_BR_R, g = CFG_BR_G, b = CFG_BR_B }
                local ba = CFG_BR_A
                b.top:ClearAllPoints()
                b.top:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
                b.top:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
                b.top:SetHeight(thickness)
                b.top:SetColorTexture(c.r, c.g, c.b, ba)
                b.top:Show()
                b.bottom:ClearAllPoints()
                b.bottom:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
                b.bottom:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
                b.bottom:SetHeight(thickness)
                b.bottom:SetColorTexture(c.r, c.g, c.b, ba)
                b.bottom:Show()
                b.left:ClearAllPoints()
                b.left:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
                b.left:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
                b.left:SetWidth(thickness)
                b.left:SetColorTexture(c.r, c.g, c.b, ba)
                b.left:Show()
                b.right:ClearAllPoints()
                b.right:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
                b.right:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
                b.right:SetWidth(thickness)
                b.right:SetColorTexture(c.r, c.g, c.b, ba)
                b.right:Show()
            else
                b.top:Hide()
                b.bottom:Hide()
                b.left:Hide()
                b.right:Hide()
            end
        end
    end
end

-- Forward declaration: ReconfigureTestFrames is defined below but
-- referenced by the resize handle's OnUpdate callback.
local ReconfigureTestFrames

-- ============================================================
-- CFG RESIZE HANDLE
-- Mirrors CreateTestResizeHandle from SetupMode.lua but writes
-- to the CFG group's cfFrameWidth/cfFrameHeight.
-- ============================================================
local function UpdateCFGResizeGrip(header, handle)
    handle = handle or header.resizeHandle
    if not handle then return end
    local ga = header._groupAnchor or "TOPLEFT"
    local corner = OppositeCorner(ga)
    if handle._gripLines then
        for _, ln in ipairs(handle._gripLines) do ln:Hide() end
    end
    handle._gripLines = {}
    local sx = corner:find("RIGHT") and -1 or 1
    local sy = corner:find("BOTTOM") and 1 or -1
    local function addGripLine(offset)
        local ln = handle:CreateLine(nil, "OVERLAY", nil, 4)
        ln:SetThickness(1.5)
        ln:SetColorTexture(1, 1, 1, 0.9)
        ln:SetStartPoint(corner, handle, sx * offset, sy * 1)
        ln:SetEndPoint(  corner, handle, sx * 1,      sy * offset)
        handle._gripLines[#handle._gripLines + 1] = ln
        local sh = handle:CreateLine(nil, "OVERLAY", nil, 3)
        sh:SetThickness(1.5)
        sh:SetColorTexture(0, 0, 0, 0.45)
        sh:SetStartPoint(corner, handle, sx * (offset + 1), sy * 1)
        sh:SetEndPoint(  corner, handle, sx * 1,            sy * (offset + 1))
        handle._gripLines[#handle._gripLines + 1] = sh
    end
    addGripLine(4)
    addGripLine(8)
    addGripLine(13)
    handle._handleCorner = corner
end

local function AnchorCFGResizeHandle(header)
    local handle = header.resizeHandle
    if not handle then return end
    handle:ClearAllPoints()
    local bW = header._boundingW or 0
    local bH = header._boundingH or 0
    local ga = header._groupAnchor or "TOPLEFT"
    local corner = handle._handleCorner or OppositeCorner(ga)
    local offX = ga:find("LEFT") and bW or -bW
    local offY = ga:find("TOP")  and -bH or bH
    handle:SetPoint(corner, header, ga, offX, offY)
end

local function CreateCFGResizeHandle(entry, group)
    local header = entry.header
    if header.resizeHandle then
        UpdateCFGResizeGrip(header)
        AnchorCFGResizeHandle(header)
        header.resizeHandle:Show()
        return
    end

    local handle = CreateFrame("Frame", nil, header)
    handle:SetFrameStrata("HIGH")
    -- +20, NOT +1 — same fix as SetupMode.lua:CreateTestResizeHandle, same cause.
    -- The CFG cells are Buttons parented to this header with no explicit level,
    -- so they default to header level + 1 and tie with the handle, swallowing the
    -- click. Floored at absolute 120 for the same occlusion reason as the raid
    -- handle: UF test frames (level 100) and CFG drag handles (110) are
    -- mouse-enabled in the same strata and can otherwise swallow the click when
    -- they overlap. See SetupMode.lua:CreateTestResizeHandle.
    handle:SetFrameLevel(math.max(120, header:GetFrameLevel() + 20))
    handle:SetSize(16, 16)
    handle:EnableMouse(true)
    handle._gripLines = {}

    UpdateCFGResizeGrip(header, handle)

    handle:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" then return end
        self.isDragging = true

        local scale = UIParent:GetEffectiveScale()
        local startCX, startCY = GetCursorPosition()

        local grp = group
        local flat = grp.flat
        local sorting = flat and flat.sorting
        local startW   = (flat and flat.frameWidth)  or 70
        local startH   = (flat and flat.frameHeight) or 40
        local spacingH = (flat and flat.frameSpacingH) or 0
        local spacingV = (flat and flat.frameSpacingV) or 0
        local cfScale  = (flat and flat.enableFrameScale and flat.frameScale) or 1.0
        local growDir  = (sorting and sorting.raidGrowDirection) or "DOWN"
        local maxCols, upc = BF:GetCFGGridDims(sorting)
        local frameCount = math.min(upc * maxCols, MAX_TEST_FRAMES)
        local isHoriz  = (growDir == "RIGHT" or growDir == "LEFT")
        local numCols, numRows
        if isHoriz then
            numCols = math.ceil(frameCount / upc)
            numRows = math.min(frameCount, upc)
        else
            numRows = math.min(frameCount, upc)
            numCols = math.ceil(frameCount / upc)
        end

        local corner = self._handleCorner or "BOTTOMRIGHT"
        local dxSign = corner:find("RIGHT") and 1 or -1
        local dySign = corner:find("BOTTOM") and 1 or -1

        self:SetScript("OnUpdate", function(self)
            local cx, cy = GetCursorPosition()
            local dW = dxSign * (cx - startCX) / scale / cfScale
            local dH = dySign * (startCY - cy) / scale / cfScale

            local newW = math.max(20, floor(startW + dW / numCols))
            local newH = math.max(10, floor(startH + dH / numRows))

            if flat and (newW ~= flat.frameWidth or newH ~= flat.frameHeight) then
                flat.frameWidth  = newW
                flat.frameHeight = newH
                ReconfigureTestFrames(entry, grp)
            end
        end)
    end)

    handle:SetScript("OnMouseUp", function(self, button)
        self:SetScript("OnUpdate", nil)
        self.isDragging = false
        -- Commit: refresh real headers and notify options panel
        if BF.RefreshCustomFrameHeaders then BF:RefreshCustomFrameHeaders() end
        BF:RefreshPanel("cfgSize")
    end)

    header.resizeHandle = handle
    AnchorCFGResizeHandle(header)
    handle:Show()
end

-- ============================================================
-- RECONFIGURE: size, position, show/hide frames for a group
-- ============================================================
ReconfigureTestFrames = function(entry, group)
    local header = entry.header
    local frames = entry.frames

    local flat = group.flat
    local sorting = flat and flat.sorting
    -- When useActiveLayoutSize is ON, read size/spacing from the
    -- active RP flat instead of the CFG flat (mirrors BFLayout.lua).
    local sizeFlat = flat
    if group.useActiveLayoutSize then
        local isRaid = BF:ResolveActiveIsRaid()
        local activeFlat = isRaid and BF:GetRaidProfile() or BF:GetActivePartyProfile()
        if activeFlat then sizeFlat = activeFlat end
    end
    local frameWidth  = BF:PixelRound((sizeFlat and sizeFlat.frameWidth)  or 70)
    local frameHeight = BF:PixelRound((sizeFlat and sizeFlat.frameHeight) or 40)
    local spacingH    = BF:PixelSnap((sizeFlat and sizeFlat.frameSpacingH) or 0)
    local spacingV    = BF:PixelSnap((sizeFlat and sizeFlat.frameSpacingV) or 0)
    local growDir     = (sorting and sorting.raidGrowDirection) or "DOWN"
    local secGrowDir  = sorting and sorting.raidSecondaryGrowDirection
    local maxCols, upc = BF:GetCFGGridDims(sorting)
    -- Derive frame count from units per column × max columns (replaces cfSetupFrameCount).
    local frameCount  = math.min(upc * maxCols, MAX_TEST_FRAMES)

    -- Apply scale
    local headerScale = 1.0
    if flat and flat.enableFrameScale and flat.frameScale then
        if flat.scaleIndicators ~= false then
            headerScale = flat.frameScale
        else
            frameWidth  = BF:PixelRound(frameWidth  * flat.frameScale)
            frameHeight = BF:PixelRound(frameHeight * flat.frameScale)
        end
    end
    header:SetScale(headerScale)

    -- Derive group anchor from grow directions (matches _DoRefreshCustomFrameHeaders).
    local groupAnchor = (flat and flat.raidLayoutAnchor) or "TOPLEFT"
    -- Offset multipliers: frames grow away from the anchor corner.
    local xMult = groupAnchor:find("LEFT")  and 1 or -1
    local yMult = groupAnchor:find("TOP")   and -1 or 1
    local isHoriz = (growDir == "RIGHT" or growDir == "LEFT")

    -- Clamp parity with the real block. The real CFG anchor frame is sized to
    -- the full configured grid and SetClampedToScreen(true); this header is
    -- clamped too, so while it stayed 1x1 the preview could be dragged to the
    -- screen edge and past it while the real block -- clamped on a rect the
    -- size of the whole grid -- stopped, and SyncRealHeader's SetPoint was
    -- silently clamped back. Same rect, same clamp, no desync. The grid math
    -- is BF:GetCFGGridExtent so there is one copy of it; it returns UIParent
    -- units and the scale it used, and this header carries that scale itself.
    --
    -- Sizing moves nothing: every cell is pinned to the header's groupAnchor
    -- corner, and both the saved position and SyncRealHeader read that same
    -- corner -- SetSize leaves it where it is.
    local gw, gh, gscale = BF:GetCFGGridExtent(entry.groupIndex)
    if gw and gscale and gscale > 0 then
        header:SetSize(math.max(gw / gscale, 1), math.max(gh / gscale, 1))
    end

    -- Re-anchor the header from saved position so layout anchor changes
    -- take effect (mirrors raid _ReconfigureTestFrames).
    local restored = RestoreTestHeaderPosition(header, entry.groupIndex)
    if not restored then
        header:ClearAllPoints()
        -- Pinned by groupAnchor, not CENTER: with the header sized to the
        -- grid above, a CENTER pin would put the block's middle where the
        -- 1x1 header's corner used to be and shift the default placement by
        -- half a block. Same numbers, same corner, same result on screen.
        header:SetPoint(groupAnchor, UIParent, "CENTER", 200, 100 - (entry.groupIndex - 1) * 60)
    end
    header._groupAnchor = groupAnchor

    -- Compute grid dimensions for bounding box (matches raid UpdateSize
    -- pattern: gridCols = horizontal extent, gridRows = vertical extent).
    local gridCols, gridRows
    if isHoriz then
        -- Horizontal grow: upc frames in a row, maxCols rows deep.
        gridCols = math.min(frameCount, upc)
        gridRows = math.ceil(frameCount / upc)
    else
        -- Vertical grow: upc frames in a column, maxCols columns wide.
        gridRows = math.min(frameCount, upc)
        gridCols = math.ceil(frameCount / upc)
    end

    for i, frame in ipairs(frames) do
        if i > frameCount then
            frame:Hide()
        else
            frame:SetSize(frameWidth, frameHeight)
            frame:ClearAllPoints()

            local idx = i - 1
            local row, col
            if isHoriz then
                -- Horizontal: primary axis is columns
                col = idx % upc
                row = math.floor(idx / upc)
            else
                -- Vertical (DOWN / UP): primary axis is rows
                row = idx % upc
                col = math.floor(idx / upc)
            end
            -- Position relative to the header's anchor corner.
            -- xMult/yMult ensure frames grow in the correct direction.
            local xOff = xMult * col * (frameWidth + spacingH)
            local yOff = yMult * row * (frameHeight + spacingV)
            frame:SetPoint(groupAnchor, header, groupAnchor, xOff, yOff)

            frame:SetAlpha(SETUP_FRAME_ALPHA)
            ApplyVisualsToTestFrame(frame)
            frame:Show()
        end
    end

    -- Compute bounding box (matches raid _ReconfigureTestFrames pattern).
    local bW = gridCols * frameWidth  + math.max(0, gridCols - 1) * spacingH
    local bH = gridRows * frameHeight + math.max(0, gridRows - 1) * spacingV
    header._boundingW = bW
    header._boundingH = bH

    -- Position the label to cover the full bounding box (matches raid pattern:
    -- anchor at groupAnchor with explicit size instead of two-point anchoring).
    if header._label then
        if bW > 0 and bH > 0 then
            header._label:ClearAllPoints()
            header._label:SetPoint(groupAnchor, header, groupAnchor, 0, 0)
            header._label:SetSize(bW, bH)
            header._label:Show()
        end
    end

    -- Create / reposition the resize handle at the opposite corner of the
    -- bounding box (matches raid CreateTestResizeHandle pattern).
    CreateCFGResizeHandle(entry, group)
end

-- ============================================================
-- PUBLIC: Show test frames for all enabled custom frame groups
-- Called from ToggleTestMode / TogglePartyTestMode when entering
-- setup mode.
-- ============================================================
function BF:ShowCustomFrameTestFrames()
    local groups = self:GetCustomFrameGroups()
    if not groups or #groups == 0 then return end

    for i, group in ipairs(groups) do
        if group.enabled ~= false then
            local entry = GetOrCreateTestHeader(i, group.name)

            -- Restore saved position (same position as real detached header)
            if not RestoreTestHeaderPosition(entry.header, i) then
                -- No saved position: default to center-ish
                entry.header:ClearAllPoints()
                entry.header:SetPoint("CENTER", UIParent, "CENTER", 200, 100 - (i - 1) * 60)
            end

            ReconfigureTestFrames(entry, group)
            entry.header:Show()
            -- Handle hidden; test frames are directly draggable
            entry.handle:Hide()
        else
            -- Disabled group: hide if showing
            local entry = _cfTestHeaders[i]
            if entry then
                entry.header:Hide()
                entry.handle:Hide()
            end
        end
    end

    -- Hide any orphaned test headers (group was removed or disabled)
    for gi, entry in pairs(_cfTestHeaders) do
        local grp = groups[gi]
        if not grp or grp.enabled == false then
            entry.header:Hide()
            entry.handle:Hide()
        end
    end
end

-- ============================================================
-- PUBLIC: Hide all custom frame group test frames
-- Called from ExitSetupMode / ToggleTestMode(false) /
-- TogglePartyTestMode(false).
-- ============================================================
function BF:HideCustomFrameTestFrames()
    for _, entry in pairs(_cfTestHeaders) do
        entry.header:Hide()
        entry.handle:Hide()
    end
end

-- ============================================================
-- PUBLIC: Update test frames (reconfigure without hide/show toggle)
-- Called when custom frame group settings change while setup mode
-- is active.
-- ============================================================
function BF:UpdateCustomFrameTestFrames()
    if not (BF.db and BF.db.global and BF.db.global.setupModeActive) then return end
    -- Delegate to ShowCustomFrameTestFrames which handles creation of
    -- new test headers, reconfiguration of existing ones, and cleanup
    -- of orphaned headers from deleted groups.
    self:ShowCustomFrameTestFrames()
end

-- ============================================================
-- PUBLIC: Restore the saved position of a setup mode test header
-- for a given group index. Called from the position sliders in
-- Options_CustomFrames.lua after updating the saved position.
-- ============================================================
function BF:RestoreCustomFrameTestHeaderPosition(groupIndex)
    local entry = _cfTestHeaders[groupIndex]
    if entry and entry.header then
        RestoreTestHeaderPosition(entry.header, groupIndex)
    end
end

-- ============================================================
-- PUBLIC: Remove a test header entry after a group is deleted.
-- Hides and destroys the entry at removedIndex, shifts all
-- higher entries down by one so _cfTestHeaders stays in sync
-- with the groups array after table.remove(groups, index).
-- Called from the delete handler in Options_CustomFrames.lua
-- BEFORE table.remove and ReloadCustomFrames.
-- ============================================================
function BF:RemoveCustomFrameTestHeader(removedIndex)
    -- Hide the entry being removed
    local removed = _cfTestHeaders[removedIndex]
    if removed then
        removed.header:Hide()
        removed.handle:Hide()
    end

    -- Find the highest occupied index
    local maxIdx = 0
    for gi in pairs(_cfTestHeaders) do
        if gi > maxIdx then maxIdx = gi end
    end

    -- Shift entries above removedIndex down by one
    for gi = removedIndex, maxIdx do
        _cfTestHeaders[gi] = _cfTestHeaders[gi + 1]
        -- Update the stored groupIndex on shifted entries
        if _cfTestHeaders[gi] then
            _cfTestHeaders[gi].groupIndex = gi
        end
    end
    -- The last slot is now a duplicate — already moved to maxIdx-1
    _cfTestHeaders[maxIdx] = nil
end
