-- ============================================================
-- BuzzardFrames: SetupModePetFrames.lua
-- Setup mode test frames for pet frames in raid/party module.
--
-- Follows the SetupModeCustomFrames.lua pattern: a detached
-- insecure header positioned at the flat's petFrameAnchorX/Y,
-- draggable independently from the main raid/party test header.
--
-- Count rule:
--   party-typed flat: 5 pet frames (flat row).
--   raid-typed flat: 10 pet frames (flat row).
--
-- Only shown when the modifying flat has showPetFrames == true.
-- Reads petFrameWidth, petFrameHeight, petFrameSpacing,
-- petGrowDirection from the modifying flat.
-- ============================================================
local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

local SETUP_FRAME_ALPHA   = 0.8
local SETUP_CONTENT_ALPHA = 0.625
local PET_POOL_SIZE       = 40  -- max frames in the pool (raid: 8 cols × 5 = 40)

-- Persistent test header; Show/Hide controls visibility across toggles.
local _petTestHeader = nil  -- { header, frames }

-- ============================================================
-- CREATE ONE PET TEST FRAME
-- ============================================================
local function CreatePetTestFrame(parent, index)
    local frame = CreateFrame("Button", "BFPetTestFrame_" .. index, parent, "BackdropTemplate")
    frame:SetSize(65, 30)

    -- Background
    local bg = BF.Texture(frame, nil, "BACKGROUND")
    bg:SetAllPoints(frame)
    local bgR, bgG, bgB, bgA = BF.GetSetupFrameColors()
    bg:SetColorTexture(bgR, bgG, bgB, bgA)
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
-- CREATE / GET THE PET TEST HEADER
-- ============================================================
local function GetOrCreatePetTestHeader()
    if _petTestHeader then return _petTestHeader end

    -- Header frame (insecure, HIGH strata to overlay real frames)
    local header = CreateFrame("Frame", "BFPetTestHeader", UIParent)
    header:SetSize(1, 1)
    header:SetFrameStrata("HIGH")
    header:SetMovable(true)
    header:SetClampedToScreen(true)
    header:EnableMouse(false)
    header:Hide()

    -- Frame pool
    local frames = {}
    for i = 1, PET_POOL_SIZE do
        frames[i] = CreatePetTestFrame(header, i)
    end

    -- Label overlay
    local labelOverlay = CreateFrame("Frame", nil, header)
    labelOverlay:SetAllPoints(header)
    labelOverlay:SetFrameStrata("HIGH")
    labelOverlay:SetFrameLevel(200)
    local groupLabel = labelOverlay:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    groupLabel:SetText("Pet Frames")
    groupLabel:SetTextColor(1, 1, 1, 0.9)
    header._label = groupLabel

    -- ── Drag: find the real pet header and sync it in lockstep ─────────
    local function FindRealPetHeader()
        if not BF.groupsUsed then return nil end
        for _, h in ipairs(BF.groupsUsed) do
            if h.isPetFrame then return h end
        end
        return nil
    end

    -- Grow-derived anchor corner for the current modifying flat. The test
    -- header is a 1x1 point so its edge reads are identical regardless of
    -- corner, but the stored/applied anchor NAME must match the real pet
    -- header's grow-derived corner so the block pins correctly on re-pin.
    local function CurrentPetAnchor()
        local flat = BF:GetModifyingProfile()
        local dir  = (flat and flat.petGrowDirection) or "DOWN"
        -- Normalize the secondary against the current primary axis so a stale
        -- cross-axis value can never change the derived corner; this keeps the
        -- preview's pinned corner identical to the live pet header
        -- (BF:GetPetSecondaryGrowDirection / GetNormalizedPetSecondary).
        local sec  = BF:GetPetSecondaryGrowDirection(flat)
        return BF:DeriveGroupAnchor(dir, sec)
    end

    local function SyncRealHeader()
        if InCombatLockdown() then return end
        local real = FindRealPetHeader()
        if not real then return end
        -- Anchor from the grow-derived corner so the real header pins to the
        -- matching corner (mirrors RefreshPetHeaders setting cfgLayoutAnchor).
        local anchor = CurrentPetAnchor()
        local ax = header:GetLeft()
        local ay = header:GetTop()
        if not ax or not ay then return end
        local ux, uy = UIParent:GetCenter()
        if not ux or not uy then return end
        -- Convert to CENTER-relative.
        local cx = ax - ux
        local cy = ay - uy
        local us = UIParent:GetEffectiveScale()
        -- The real pet header is parented to its pet anchor frame, so move the
        -- ANCHOR FRAME (not the header) — SetPoint-ing the header to UIParent
        -- would un-parent it. The header follows because it's pinned to the
        -- anchor frame's corner.
        local af = BF.GetOrCreatePetAnchorFrame and BF:GetOrCreatePetAnchorFrame(BF._modifyingFlat)
        if af then
            local afs = af:GetEffectiveScale()
            af:ClearAllPoints()
            af:SetPoint(anchor, UIParent, "CENTER", cx * us / afs, cy * us / afs)
        else
            local rs = real:GetEffectiveScale()
            real:ClearAllPoints()
            real:SetPoint(anchor, UIParent, "CENTER", cx * us / rs, cy * us / rs)
        end
        if real._handle and real._handle.SnapToParent then
            real._handle.SnapToParent()
        end
    end

    local function SavePosition()
        local flat = BF:GetModifyingProfile()
        if not flat then return end
        -- Anchor from the grow-derived corner so the stored anchor matches
        -- the real pet header's cfgLayoutAnchor.
        local anchor = CurrentPetAnchor()
        local ax = header:GetLeft()
        local ay = header:GetTop()
        local ux, uy = UIParent:GetCenter()
        if not (ax and ay and ux and uy) then return end
        -- Store CENTER-relative UI coords, matching the real pet header,
        -- the detached-position system, and the X/Y Position sliders.
        local cx = math.floor(ax - ux + 0.5)
        local cy = math.floor(ay - uy + 0.5)

        -- Detached header position store (read by RestoreDetachedHeaderPosition).
        if BF._modifyingFlat then
            local p = BF.cfgDB and BF.cfgDB.profile
            if p then
                if not p.customFrameGroupPositions then
                    p.customFrameGroupPositions = {}
                end
                p.customFrameGroupPositions["petFrame_" .. BF._modifyingFlat] = {
                    anchor, cx, cy,
                }
            end
        end

        -- Keep the X/Y Position sliders accurate. Anchor is TOPLEFT, so the
        -- CENTER-relative cx/cy map directly onto petFrameAnchorX/Y, which the
        -- options sliders and real-header initial placement read as
        -- CENTER-relative offsets.
        flat.petFrameAnchorX = cx
        flat.petFrameAnchorY = cy
        -- v53 Phase 2.2: position-level dirt only. The real pet header is
        -- re-placed by the drag handler itself; exit just re-applies the
        -- saved position and rebuilds nothing.
        BF:MarkSetupDirty("pets", BF.SETUP_DIRTY_POS)
    end

    -- Make all cells draggable — moves the header
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
            SavePosition()
            local real = FindRealPetHeader()
            if real and BF.RestoreDetachedHeaderPosition then
                BF:RestoreDetachedHeaderPosition(real)
            end
            -- Refresh the options panel so the X/Y Position sliders update.
            BF:RefreshPanel("petPosition")
        end)
    end

    _petTestHeader = {
        header = header,
        frames = frames,
    }
    return _petTestHeader
end

-- ============================================================
-- RESTORE POSITION from petFrameAnchorX/Y on the modifying flat
-- ============================================================
local function RestorePetTestPosition(header, pinAnchor)
    local flat = BF:GetModifyingProfile()
    if not flat then return false end

    -- IDENTICAL to the CFG preview's RestoreTestHeaderPosition: trust the
    -- STORED corner. The stored { anchor, cx, cy } is written by the real pet
    -- header path (RecomputePetHeaderAnchor / SaveDetachedHeaderPosition), where
    -- cx,cy is the anchor-corner of the FULL-GRID pet anchor frame. The real
    -- cell #1's <anchor> corner sits exactly at that point (the secure header is
    -- pinned to the anchor frame's <anchor> corner at 0,0). Pinning the 1x1
    -- preview header by the SAME stored <anchor> places cell #1 (anchored at
    -- offset 0,0 by ReconfigurePetTestFrames using DeriveGroupAnchor, which
    -- equals the stored anchor) at the identical point — for every direction.
    -- Do NOT re-derive a corner here: CFG uses pos[1] verbatim, and the cell
    -- loop derives the same value from the same flat, so they agree.
    if BF._modifyingFlat then
        local posKey = "petFrame_" .. BF._modifyingFlat
        local p = BF.cfgDB and BF.cfgDB.profile
        local positions = p and p.customFrameGroupPositions
        if positions and positions[posKey] then
            local pos = positions[posKey]
            local anchor, cx, cy = pos[1], pos[2], pos[3]
            local us = UIParent:GetEffectiveScale()
            local s  = header:GetEffectiveScale()
            header:ClearAllPoints()
            header:SetPoint(anchor, UIParent, "CENTER", cx * us / s, cy * us / s)
            return true
        end
    end

    -- Fallback (no saved position yet): seed EXACTLY like the real pet header's
    -- no-saved-position path in BFLayout PlaceHeaders (the isPetFrame else-branch
    -- at ~1790): pin the header's CENTER to (petFrameAnchorX, petFrameAnchorY),
    -- default 0,-300. The real header does NOT use the grow-derived corner here;
    -- it centers the block on that point and then re-saves the anchor-frame
    -- corner. Centering the 1x1 preview header the same way overlays the real
    -- block in this transient state. (Pinning by the grow-derived corner instead
    -- offset the preview by half the block for every direction — the old bug.)
    --
    -- pinAnchor: the caller's grow-derived corner, once the header has been
    -- sized to the full grid (see ReconfigurePetTestFrames). Pinning a sized
    -- header by CENTER would put the block's middle where the old 1x1
    -- header's corner sat and move the default placement by half a block;
    -- pinning the same corner with the same numbers keeps it exactly where
    -- it is today. Callers that do not know the corner yet pass nothing and
    -- get the historic CENTER pin -- ReconfigurePetTestFrames re-pins right
    -- after them anyway.
    local ax = flat.petFrameAnchorX or 0
    local ay = flat.petFrameAnchorY or -300
    local us = UIParent:GetEffectiveScale()
    local s  = header:GetEffectiveScale()
    header:ClearAllPoints()
    header:SetPoint(pinAnchor or "CENTER", UIParent, "CENTER", ax * us / s, ay * us / s)
    return true
end

-- ============================================================
-- APPLY VISUALS to a pet test frame (border only — matches
-- SetupModeCustomFrames pattern)
-- ============================================================
local function ApplyVisualsToFrame(frame)
    if frame.unitBorder then
        local b = frame.unitBorder
        if b.top and b.bottom and b.left and b.right then
            local _, _, _, _, bR, bG, bB, bA = BF.GetSetupFrameColors()
            local thickness = 1
            b.top:ClearAllPoints()
            b.top:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
            b.top:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
            b.top:SetHeight(thickness)
            b.top:SetColorTexture(bR, bG, bB, bA)
            b.top:Show()
            b.bottom:ClearAllPoints()
            b.bottom:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
            b.bottom:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
            b.bottom:SetHeight(thickness)
            b.bottom:SetColorTexture(bR, bG, bB, bA)
            b.bottom:Show()
            b.left:ClearAllPoints()
            b.left:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
            b.left:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
            b.left:SetWidth(thickness)
            b.left:SetColorTexture(bR, bG, bB, bA)
            b.left:Show()
            b.right:ClearAllPoints()
            b.right:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
            b.right:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
            b.right:SetWidth(thickness)
            b.right:SetColorTexture(bR, bG, bB, bA)
            b.right:Show()
        end
    end
end

-- ============================================================
-- RECONFIGURE: size, position, show/hide pet test frames
-- ============================================================
local function ReconfigurePetTestFrames(entry, flat)
    local header = entry.header
    local frames = entry.frames

    local isParty    = flat.type == "party"
    local frameWidth  = BF:PixelRound(flat.petFrameWidth  or (isParty and 100 or 65))
    local frameHeight = BF:PixelRound(flat.petFrameHeight or (isParty and 50  or 30))
    local spacing     = BF:PixelSnap(flat.petFrameSpacing or 0)
    local growDir     = flat.petGrowDirection or "DOWN"
    -- Normalize the secondary against the current primary axis so a stale
    -- cross-axis value can never change the derived corner; keeps the preview
    -- matching the live pet header (BF:GetPetSecondaryGrowDirection).
    local secDir      = BF:GetPetSecondaryGrowDirection(flat)
    -- Grid dims from the flat's pet settings (party-clamped to 1 col of 5),
    -- matching the real pet header. Preview shows the configured grid, capped
    -- to the test-frame pool (PET_POOL_SIZE).
    local maxCols, upc = BF:GetPetGridDims(flat)
    local frameCount = math.min(maxCols * upc, PET_POOL_SIZE)
    local isHoriz     = (growDir == "RIGHT" or growDir == "LEFT")
    -- Anchor corner the block grows FROM, matching the live pet header
    -- (DeriveGroupAnchor). The preview cells are placed relative to this
    -- corner with directional signs so the preview matches the real frames
    -- for every grow direction (e.g. UP keeps cell #1 at the bottom).
    local petGA = BF:DeriveGroupAnchor(growDir, secDir)
    -- Offset multipliers derived PURELY from the anchor corner, exactly like
    -- the custom-frame setup preview (SetupModeCustomFrames). Frames grow AWAY
    -- from the anchor corner into the block; the corner alone determines the
    -- direction, so there is no separate grow-direction sign (that double-
    -- applied direction and sent UP/LEFT the wrong way).
    local xMult = petGA:find("LEFT") and 1 or -1
    local yMult = petGA:find("TOP")  and -1 or 1

    -- Apply scale the same way the live pet header does: start at 1.0 and
    -- only apply a scale when the flat's enableFrameScale/frameScale pair
    -- is set. scaleIndicators=true scales the header (indicators included);
    -- scaleIndicators=false bakes the scale into frame dimensions instead.
    local headerScale = 1.0
    if flat.enableFrameScale and flat.frameScale then
        if flat.scaleIndicators ~= false then
            headerScale = flat.frameScale
        else
            frameWidth  = BF:PixelRound(frameWidth  * flat.frameScale)
            frameHeight = BF:PixelRound(frameHeight * flat.frameScale)
        end
    end
    header:SetScale(headerScale)

    -- Keep the BLOCK static across a grow-direction change. The stored position
    -- is the petGA corner of the block. When the direction changes, petGA flips
    -- to a different corner (e.g. UP=BOTTOMLEFT -> DOWN=TOPLEFT), so to keep the
    -- bounding box in the same screen region we must move the stored point from
    -- the OLD corner to the NEW corner by the block's extent. RecomputePetHeaderAnchor
    -- does this for the real frames by reading the full-grid anchor frame, but it
    -- only runs when the modifying flat is ACTIVE. For a non-active layout (no
    -- live anchor frame) we recompute here from the block's known dimensions so
    -- the preview block stays put too.
    if BF._modifyingFlat then
        local posKey = "petFrame_" .. BF._modifyingFlat
        local p = BF.cfgDB and BF.cfgDB.profile
        local positions = p and p.customFrameGroupPositions
        local pos = positions and positions[posKey]
        if pos then
            local storedAnchor, scx, scy = pos[1], pos[2], pos[3]
            if storedAnchor ~= petGA then
                -- Block bounding box (full configured grid), in UI coords.
                local gw, gh
                if isHoriz then
                    gw = upc     * (frameWidth  + spacing) - spacing
                    gh = maxCols * (frameHeight + spacing) - spacing
                else
                    gw = maxCols * (frameWidth  + spacing) - spacing
                    gh = upc     * (frameHeight + spacing) - spacing
                end
                gw = gw * headerScale
                gh = gh * headerScale
                -- Convert the OLD stored corner to the block's TOPLEFT, then to
                -- the NEW corner, so the bounding box stays fixed on screen.
                -- X: LEFT corners are at block left; RIGHT corners at left+gw.
                local oldLeftX = storedAnchor:find("LEFT") and scx or (scx - gw)
                local oldTopY  = storedAnchor:find("TOP")  and scy or (scy + gh)
                local newcx = petGA:find("LEFT") and oldLeftX or (oldLeftX + gw)
                local newcy = petGA:find("TOP")  and oldTopY  or (oldTopY - gh)
                positions[posKey] = { petGA, math.floor(newcx + 0.5), math.floor(newcy + 0.5) }
            end
        end
    end

    -- Clamp parity with the real block, exactly as the custom-frame preview
    -- does it. The real pet anchor frame is sized to the full configured grid
    -- and SetClampedToScreen(true); this header is clamped too, so while it
    -- stayed 1x1 the preview could be dragged past the screen edge while the
    -- real block stopped there, and SyncRealHeader's SetPoint was clamped back
    -- -- the two desynced. BF:GetPetGridExtent is the same arithmetic the
    -- anchor frame is sized from; it returns UIParent units and the scale it
    -- used, and this header carries that scale itself.
    --
    -- Sizing moves nothing: every cell is pinned to the header's petGA corner
    -- and so is the position, and SetSize leaves that corner in place.
    local gw, gh, gscale = BF:GetPetGridExtent(flat)
    if gw and gscale and gscale > 0 then
        header:SetSize(math.max(gw / gscale, 1), math.max(gh / gscale, 1))
    end

    -- Re-pin the header from the (now corner-consistent) saved position so the
    -- grow-direction change takes effect, mirroring the CFG preview.
    RestorePetTestPosition(header, petGA)

    for i, frame in ipairs(frames) do
        if i > frameCount then
            frame:Hide()
        else
            frame:SetSize(frameWidth, frameHeight)
            frame:ClearAllPoints()
            local idx = i - 1
            -- row/col split, identical to the custom-frame preview: for both
            -- axes the within-column/row index is idx % upc and the column/row
            -- index is floor(idx / upc).
            local row, col
            if isHoriz then
                col = idx % upc            -- position along X (primary)
                row = math.floor(idx / upc)
            else
                row = idx % upc            -- position along Y (primary)
                col = math.floor(idx / upc)
            end
            -- Offsets keyed only off the anchor corner (xMult/yMult), so frames
            -- grow away from the corner correctly for ALL directions.
            local dx = xMult * col * (frameWidth  + spacing)
            local dy = yMult * row * (frameHeight + spacing)
            frame:SetPoint(petGA, header, petGA, dx, dy)
            frame:SetAlpha(SETUP_FRAME_ALPHA)
            ApplyVisualsToFrame(frame)
            frame:Show()
        end
    end

    -- Position the label to span the visible block. cell #1 sits at the
    -- petGA corner and the block grows via xMult/yMult, so for UP cell #1 is
    -- at the BOTTOM and for LEFT it's at the RIGHT. Anchoring the label
    -- TOPLEFT->first / BOTTOMRIGHT->last (as before) produced an INVERTED
    -- (negative-size) rect for UP/LEFT, so the FontString never rendered.
    -- Anchor each label edge to the geometrically-correct extreme cell instead.
    if header._label then
        local first = frames[1]
        local last  = frames[frameCount]
        if first and last and first:IsShown() and last:IsShown() then
            -- Identify the geometrically top-left-most and bottom-right-most
            -- cells (which of first/last they are depends on grow direction),
            -- then anchor the label TOPLEFT->topLeftCell, BOTTOMRIGHT->bottomRightCell
            -- so the rect is always positive-size and the label renders.
            -- topLeftCell: leftmost AND topmost. xMult>0 => first is left;
            -- yMult<0 => first is top. The two extreme cells are first & last.
            local leftIsFirst = (xMult > 0)
            local topIsFirst  = (yMult < 0)
            -- The top-left corner comes from the cell that is both left and top.
            -- first/last are diagonal opposites, so:
            --   if first is left and first is top  -> topLeft=first, bottomRight=last
            --   if first is left and last  is top  -> mixed (block is 1-D); pick edges per-axis
            header._label:ClearAllPoints()
            local leftCell  = leftIsFirst and first or last
            local rightCell = leftIsFirst and last  or first
            local topCell   = topIsFirst  and first or last
            local botCell   = topIsFirst  and last  or first
            header._label:SetPoint("LEFT",   leftCell,  "LEFT",   0, 0)
            header._label:SetPoint("RIGHT",  rightCell, "RIGHT",  0, 0)
            header._label:SetPoint("TOP",    topCell,   "TOP",    0, 0)
            header._label:SetPoint("BOTTOM", botCell,   "BOTTOM", 0, 0)
            header._label:Show()
        end
    end
end

-- ============================================================
-- PUBLIC: Show pet test frames
-- Called from ToggleSetupMode / UpdateSetupFrames when entering
-- setup mode, if the modifying flat has showPetFrames == true.
-- ============================================================
function BF:ShowPetTestFrames()
    local flat = self:GetModifyingProfile()
    if not flat or not flat.showPetFrames then
        self:HidePetTestFrames()
        return
    end

    local entry = GetOrCreatePetTestHeader()
    RestorePetTestPosition(entry.header)
    ReconfigurePetTestFrames(entry, flat)

    -- Update label with flat name
    if entry.header._label then
        local flatName = (flat.name or "Layout")
        entry.header._label:SetText(flatName .. ": Pet Frames")
    end

    entry.header:Show()
end

-- ============================================================
-- PUBLIC: Hide pet test frames
-- ============================================================
function BF:HidePetTestFrames()
    if _petTestHeader then
        _petTestHeader.header:Hide()
    end
end

-- ============================================================
-- PUBLIC: Update pet test frames (reconfigure while visible)
-- Called when pet frame settings change while setup mode is active.
-- ============================================================
function BF:UpdatePetTestFrames()
    if not BF._IsSetupModeActive() then return end
    local flat = self:GetModifyingProfile()
    if not flat or not flat.showPetFrames then
        self:HidePetTestFrames()
        return
    end
    if not _petTestHeader then return end
    ReconfigurePetTestFrames(_petTestHeader, flat)
end
