-- ============================================================
-- BuzzardFrames: SetupMode.lua
-- Setup mode test/preview frames for positioning.
--
-- Setup mode is governed by a SINGLE global bool
-- `BF.db.global.setupModeActive`. Frame count, frame type (party/raid),
-- and rendering rules all derive from the currently-editing flat
-- (self._modifyingFlat) resolved via BF:GetModifyingProfile().
--
-- Count rule:
--   party-typed flat: always 5 test frames.
--   raid-typed flat:  (# of visible groups) * 5, where "visible" is
--                     BF:GetGroupVisibilityRule -- flat.showGroup normally,
--                     or the current instance's capacity when the flat has
--                     Auto Hide Groups by Instance Size on.
--
-- Real frames stay visible underneath. Test frames overlay at HIGH
-- strata with SETUP_FRAME_ALPHA so the user sees through them to the
-- real frames when the layouts align.
--
-- Drag behavior: test anchor drag saves to _modifyingFlat.anchorX/Y.
-- When ActiveMatchesModifying() the real anchor moves in lockstep so
-- edits to the currently-rendering flat are visible on the real frames
-- live.
--
-- Legacy tier-specific globals (partyTestMode / raid20TestMode /
-- raid30TestMode / raid40TestMode) are no longer read at runtime but
-- are preserved in SavedVariables for rollback. See
-- Docs/SETUP_MODE_MIGRATION.md for the planned cleanup pass.
-- ============================================================
local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

local SETUP_FRAME_ALPHA = 0.8
local SETUP_CONTENT_ALPHA = 0.9

-- Returns the number of test frames setup mode should render for `flat`.
-- Party flats: always 5. Raid flats: count of enabled groups * 5.
local function SetupFrameCount(flat)
    if not flat then return 40 end
    if flat.type == "party" then return 5 end
    -- Same rule the real frames use, so the test frames show the group set
    -- that would actually render. Under Auto Hide Groups by Instance Size
    -- that is the CURRENT instance's capacity -- eight groups out in the
    -- world, four while standing in a 20-man raid.
    local cap, sg = BF:GetGroupVisibilityRule(flat)
    if cap >= 8 and type(sg) ~= "table" then return 40 end
    local n = 0
    for i = 1, 8 do
        if i <= cap and not (sg and sg[i] == false) then n = n + 1 end
    end
    if n == 0 then return 40 end
    return n * 5
end
BF._SetupFrameCount = SetupFrameCount

-- Returns true when setup mode is on.
local function IsSetupModeActive()
    return BF.db and BF.db.global and BF.db.global.setupModeActive == true
end
BF._IsSetupModeActive = IsSetupModeActive

-- ============================================================
-- v53 PHASE 2.2 — SETUP-MODE EXIT DIRTINESS
--
-- Leaving setup mode used to run a full profile re-apply unconditionally:
-- BF:UpdateFrameLayout() -> BF:ReloadLayout(true) -> LoadLayout (every
-- header Reset() + rebuilt, UpdateAuraSizeCache over every scope, and a
-- frame:Layout() sweep over every child of every header -- twice, because
-- BF:ResizeAllFrames() immediately re-ran the same sweep) plus
-- BF:GroupTypeChanged(). That is a whole-raid rebuild paid on every exit,
-- including an exit from a session that changed nothing.
-- (v53 Phase 3 removed the duplicate ResizeAllFrames sweep; see the exit
-- path in BF:ToggleSetupMode for the redundancy proof.)
--
-- What that rebuild is actually FOR: while setup mode is open BF skips
-- real-frame work whenever the flat being EDITED is not the flat being
-- RENDERED -- see BF:RefreshAll (Core_Refresh.lua), BF:ResizeAllFrames
-- (BFLayout.lua) and the ~20 setters in Options/Options_Frames.lua, all of
-- which gate on BF:ActiveMatchesModifying(). Those skipped edits are the
-- only ones the real frames have not already seen live, so the rebuild is
-- needed exactly when at least one of them happened. Core_ProfileAPI.lua
-- records that from inside ActiveMatchesModifying itself, so no individual
-- setter has to be taught about setup mode.
--
-- Levels are monotonic per scope:
--   0 NONE  nothing was skipped -> exit restores anchors/labels only.
--   1 POS   a saved position moved -> re-place that scope, no rebuild.
--   2 FULL  a setting was written while real-frame work was skipped ->
--           the pre-2.2 full path, unchanged.
--
-- Scopes: "raid" (main raid/party layout), "pets", or a CFG group index.
-- ============================================================
local SETUP_DIRTY_NONE = 0
local SETUP_DIRTY_POS  = 1
local SETUP_DIRTY_FULL = 2
BF.SETUP_DIRTY_POS  = SETUP_DIRTY_POS
BF.SETUP_DIRTY_FULL = SETUP_DIRTY_FULL

-- Clears every scope back to NONE. Called at the END of the setup-mode
-- enter path, after that path's own calls have run: several of them consult
-- ActiveMatchesModifying and would otherwise dirty the session at birth.
function BF:ResetSetupDirty()
    self._setupDirtyRaid = SETUP_DIRTY_NONE
    self._setupDirtyPets = SETUP_DIRTY_NONE
    local cfg = self._setupDirtyCFG
    if cfg then wipe(cfg) else self._setupDirtyCFG = {} end
end

-- Raise `scope` to at least `level` (default FULL). Levels never fall.
-- Inert while setup mode is off, which is what lets BF:ToggleSetupMode's
-- exit branch snapshot the levels the moment it clears setupModeActive and
-- be certain nothing it calls afterwards can add to them.
function BF:MarkSetupDirty(scope, level)
    local g = BF.db and BF.db.global
    if not (g and g.setupModeActive) then return end
    level = level or SETUP_DIRTY_FULL
    if scope == "pets" then
        if (self._setupDirtyPets or SETUP_DIRTY_NONE) < level then
            self._setupDirtyPets = level
        end
    elseif type(scope) == "number" then
        local cfg = self._setupDirtyCFG
        if not cfg then cfg = {}; self._setupDirtyCFG = cfg end
        if (cfg[scope] or SETUP_DIRTY_NONE) < level then cfg[scope] = level end
    else
        if (self._setupDirtyRaid or SETUP_DIRTY_NONE) < level then
            self._setupDirtyRaid = level
        end
    end
end

-- Computes the visual grid position for a frame at the given index.
-- Returns (col, row) as simple 0-based indices. The caller applies
-- directional multipliers (from the groupAnchor-derived xMult/yMult)
-- to handle grow direction and secondary direction flipping.
-- visibleGroupIndices: ordered list of enabled group numbers (GROUP mode),
--   or nil for ROLE/party modes where simple index math applies.
-- groupSize: units per group (5 for GROUP mode), ignored when visibleGroupIndices is nil.
local function ComputeGridPosition(adjustedIndex, unitsPerColumn, isHorizGrow, maxCols, maxRows, visibleGroupIndices, groupSize)
    local row, col
    if visibleGroupIndices then
        -- GROUP mode: remap via visible group list
        local groupIndex = math.floor(adjustedIndex / groupSize) + 1
        local unitInGroup = adjustedIndex % groupSize
        local visibleCol = 0
        for vi, g in ipairs(visibleGroupIndices) do
            if g == groupIndex then visibleCol = vi - 1; break end
        end
        if isHorizGrow then
            row = visibleCol
            col = unitInGroup
        else
            row = unitInGroup
            col = visibleCol
        end
    else
        if isHorizGrow then
            col = adjustedIndex % unitsPerColumn
            row = math.floor(adjustedIndex / unitsPerColumn)
        else
            row = adjustedIndex % unitsPerColumn
            col = math.floor(adjustedIndex / unitsPerColumn)
        end
    end
    return col, row
end

-- Computes the visual bounding box extent of a grid layout.
-- Returns totalW, totalH, visCols, visRows.
local function ComputeGridExtent(numFrames, unitsPerColumn, isHorizGrow, layoutW, layoutH, spacingH, spacingV, visibleGroupCount)
    local visCols, visRows
    if visibleGroupCount then
        -- GROUP mode: column count comes from visible groups
        visCols = visibleGroupCount
        visRows = unitsPerColumn
    else
        visCols = math.ceil(numFrames / unitsPerColumn)
        visRows = math.min(numFrames, unitsPerColumn)
    end
    if isHorizGrow then
        visCols, visRows = visRows, visCols
    end
    local totalW = visCols * layoutW + math.max(0, visCols - 1) * spacingH
    local totalH = visRows * layoutH + math.max(0, visRows - 1) * spacingV
    return totalW, totalH, visCols, visRows
end

-- Returns bg (r,g,b,a) and border (r,g,b,a) derived from the user's
-- setupFrameColor profile setting. Background is the base color at 35%
-- alpha; border is a brighter tint at 80% alpha.
local function GetSetupFrameColors()
    local p = BF.db and BF.db.profile
    local c = p and BF.db.global.setupFrameColor or { r = 0.15, g = 0.35, b = 0.7 }
    -- Border: push each channel towards white by ~40%
    local br = math.min(1, c.r + (1 - c.r) * 0.4)
    local bg = math.min(1, c.g + (1 - c.g) * 0.4)
    local bb = math.min(1, c.b + (1 - c.b) * 0.4)
    return c.r, c.g, c.b, 0.6,  br, bg, bb, 0.8
end
-- Expose for SetupModeCustomFrames.lua
BF.GetSetupFrameColors = GetSetupFrameColors
-- Snap a requested header scale so that (frameWidth * snappedScale) and
-- (frameHeight * snappedScale) both land on whole screen pixels.
-- This prevents sub-pixel gaps between adjacent frames when spacing = 0,
-- regardless of UIParent scale or the user's chosen frame scale value.
-- v93: thin wrapper over the shared BF:SnapScaleForSize (PixelPerfect.lua),
-- which pixel-rounds the dimensions itself on the device-pixel grid. Setup
-- frames therefore snap byte-identically to the real headers, which is the
-- whole point of this function existing separately.
local function SnapHeaderScale(requestedScale, frameWidth, frameHeight)
    return BF:SnapScaleForSize(requestedScale, frameWidth, frameHeight)
end

-- ============================================================
-- EXIT SETUP MODE
-- Cleanly exits setup mode without saving or applying anything.
-- Safe to call at any time, including during group type changes.
-- Does not call ResizeAllFrames, UpdateAnchorPosition, or any
-- function that would touch real frame geometry.
-- ============================================================
function BF:ExitSetupMode()
    if not IsSetupModeActive() then return end

    BF.db.global.setupModeActive = false

    -- Hide test headers and cancel dummy aura timers.
    if self.testHeader then
        if self.testHeader.resizeHandle then self.testHeader.resizeHandle:Hide() end
        if self.testHeader.frames then
            local limit = self.testHeader.activeCount or #self.testHeader.frames
            for i = 1, limit do
                local tf = self.testHeader.frames[i]
                if tf and tf.SF_DummyRestartTimer then
                    tf.SF_DummyRestartTimer:Cancel()
                    tf.SF_DummyRestartTimer = nil
                end
            end
        end
        self.testHeader:Hide()
    end
    if self.partyTestHeader then
        if self.partyTestHeader.resizeHandle then self.partyTestHeader.resizeHandle:Hide() end
        if self.partyTestHeader.frames then
            for _, tf in ipairs(self.partyTestHeader.frames) do
                if tf and tf.SF_DummyRestartTimer then
                    tf.SF_DummyRestartTimer:Cancel()
                    tf.SF_DummyRestartTimer = nil
                end
            end
        end
        self.partyTestHeader:Hide()
    end

    -- Hide test anchor handle.
    if self.testAnchorFrame then
        self.testAnchorFrame:EnableMouse(false)
        self.testAnchorFrame.handle:Hide()
    end

    -- Clear test status icon flags.
    if self.ClearTestStatusFlags then self:ClearTestStatusFlags() end

    -- Hide setup grid.
    if self.UpdateSetupGrid then self:UpdateSetupGrid() end

    -- Hide UF test frames.
    if self.HideUFTestFrames then self:HideUFTestFrames() end

    -- Hide custom frame group test frames.
    if self.HideCustomFrameTestFrames then self:HideCustomFrameTestFrames() end

    -- Hide pet test frames.
    if self.HidePetTestFrames then self:HidePetTestFrames() end

    -- Restore real frame handle visibility now that setup mode is off.
    if self.RefreshHandleVisibility then self:RefreshHandleVisibility() end
end
-- ============================================================
-- FRAME CREATION
-- ============================================================

-- ============================================================
-- ANCHOR & LOCK
-- ============================================================

-- SnapAnchor lives in PixelPerfect.lua as BF:SnapAnchor(v).
-- Call it as BF:SnapAnchor(offset) wherever a CENTER offset must be snapped
-- so the anchor's TOPLEFT lands on an exact screen pixel.
-- ============================================================
-- POSITIONING GRID
-- A full-screen grid of evenly-spaced lines drawn over UIParent
-- to help with frame alignment during setup mode.
-- Shown when setup mode is active AND db.global.showSetupGrid ~= false.
-- ============================================================
function BF:CreateSetupGrid()
    if self._setupGrid then return end

    -- Root frame covers the entire UIParent virtual canvas.
    -- BACKGROUND strata keeps it behind all frames.
    local root = CreateFrame("Frame", "BuzzardFramesSetupGrid", UIParent)
    root:SetAllPoints(UIParent)
    root:SetFrameStrata("BACKGROUND")
    root:SetFrameLevel(1)
    root:EnableMouse(false)
    root:Hide()

    -- We draw lines as 1-pixel-tall / 1-pixel-wide textures.
    -- Lines are stored so we can regenerate them if UIParent resizes.
    root._lines = {}

    local GRID_STEP   = 50     -- virtual units between lines
    local LINE_ALPHA  = 0.25
    local LINE_COLOR  = { 0.6, 0.6, 0.6 }  -- gray grid
    local CTR_COLOR   = { 0.9, 0.7, 0.2 }  -- gold center crosshair
    local CTR_ALPHA   = 0.55

    local function MakeTex(r, g, b, a)
        local t = BF.Texture(root, nil, "BACKGROUND", nil, 2)
        t:SetColorTexture(r, g, b, a)
        return t
    end

    local function BuildLines()
        -- Clear old lines
        for _, t in ipairs(root._lines) do t:Hide() end
        root._lines = {}

        local W = UIParent:GetWidth()
        local H = UIParent:GetHeight()
        local cx = W / 2
        local cy = H / 2

        -- Center vertical (gold)
        do
            local t = MakeTex(CTR_COLOR[1], CTR_COLOR[2], CTR_COLOR[3], CTR_ALPHA)
            t:SetPoint("TOPLEFT",    root, "BOTTOMLEFT", cx - 0.5, H)
            t:SetPoint("BOTTOMRIGHT",root, "BOTTOMLEFT", cx + 0.5, 0)
            table.insert(root._lines, t)
        end
        -- Vertical lines stepping outward from center
        local x = GRID_STEP
        while true do
            local drew = false
            for _, dx in ipairs({ cx - x, cx + x }) do
                if dx > 0 and dx < W then
                    local t = MakeTex(LINE_COLOR[1], LINE_COLOR[2], LINE_COLOR[3], LINE_ALPHA)
                    t:SetPoint("TOPLEFT",    root, "BOTTOMLEFT", dx - 0.5, H)
                    t:SetPoint("BOTTOMRIGHT",root, "BOTTOMLEFT", dx + 0.5, 0)
                    table.insert(root._lines, t)
                    drew = true
                end
            end
            if not drew then break end
            x = x + GRID_STEP
        end

        -- Center horizontal (gold)
        do
            local t = MakeTex(CTR_COLOR[1], CTR_COLOR[2], CTR_COLOR[3], CTR_ALPHA)
            t:SetPoint("TOPLEFT",   root, "BOTTOMLEFT", 0,  cy + 0.5)
            t:SetPoint("BOTTOMRIGHT",root, "BOTTOMLEFT", W,  cy - 0.5)
            table.insert(root._lines, t)
        end
        -- Horizontal lines stepping outward from center
        local y = GRID_STEP
        while true do
            local drew = false
            for _, dy in ipairs({ cy - y, cy + y }) do
                if dy > 0 and dy < H then
                    local t = MakeTex(LINE_COLOR[1], LINE_COLOR[2], LINE_COLOR[3], LINE_ALPHA)
                    t:SetPoint("TOPLEFT",   root, "BOTTOMLEFT", 0,  dy + 0.5)
                    t:SetPoint("BOTTOMRIGHT",root, "BOTTOMLEFT", W,  dy - 0.5)
                    table.insert(root._lines, t)
                    drew = true
                end
            end
            if not drew then break end
            y = y + GRID_STEP
        end
    end

    BuildLines()

    -- Rebuild if the window is resized (e.g. resolution change)
    root:HookScript("OnSizeChanged", function() BuildLines() end)

    self._setupGrid = root
end

function BF:UpdateSetupGrid()
    if not self._setupGrid then self:CreateSetupGrid() end
    if IsSetupModeActive() and BF.db.global.showSetupGrid then
        self._setupGrid:Show()
    else
        self._setupGrid:Hide()
    end
end

function BF:CreateAnchor()
    if self.anchorFrame then return end
    local p = self.db.profile

    local anchor = CreateFrame("Frame", "BuzzardFramesAnchor", UIParent)
    anchor:SetSize(1, 1)  -- Small point anchor
    anchor:SetFrameStrata("MEDIUM")
    
    -- Set initial position from saved layout data, using the same
    -- party-vs-raid logic as UpdateAnchorPosition.
    local _initX, _initY
    if self:ShouldUsePartyAnchor() then
        local pp = self:GetActivePartyProfile()
        _initX = pp.anchorX or -200
        _initY = pp.anchorY or 100
    else
        local rp = self:GetRaidProfile()
        _initX = rp.anchorX or -200
        _initY = rp.anchorY or 100
    end
    local _initAnchor = BF:GetLayoutAnchor()
    anchor:SetPoint(_initAnchor, UIParent, "CENTER", BF:SnapAnchor(_initX), BF:SnapAnchor(_initY))
    anchor:SetMovable(true)
    anchor:SetClampedToScreen(true)
    anchor:EnableMouse(false)

    -- Drag handle - parented to UIParent (NOT the anchor) so SetClampedToScreen
    -- on the anchor does not include the handle's 18 px height in the clamping
    -- rect.  When the handle was a child of the anchor, the clamper would push
    -- the anchor down by ~18 px every time it approached the top of the screen,
    -- causing the saved position to drift on each setup-mode open.
    local handle = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    handle:SetSize(200, 16)
    handle:SetFrameStrata("MEDIUM")
    handle:SetFrameLevel(100)
    handle:SetBackdrop({
        bgFile="Interface\\Buttons\\White8x8",
        edgeFile="Interface\\Buttons\\White8x8",
        edgeSize=1,
    })
    handle:SetBackdropColor(0.1, 0.3, 0.6, 0.8)
    handle:SetBackdropBorderColor(0.2, 0.5, 0.9, 1)
    handle:EnableMouse(true)
    handle:SetMovable(true)
    handle:RegisterForDrag("LeftButton")

    -- Pin the handle above the anchor.  Called whenever the anchor moves so
    -- the handle tracks it without an OnUpdate running every game frame.
    -- (OnUpdate with ClearAllPoints+SetPoint at 60-165 Hz was the primary
    -- source of idle CPU usage.)
    local function SnapHandleToAnchor()
        handle:ClearAllPoints()
        handle:SetPoint("BOTTOMLEFT", anchor, "TOPLEFT", 0, 2)
    end
    -- Expose on anchor so UpdateAnchorPosition can call it after repositioning.
    anchor.SnapHandle = SnapHandleToAnchor

    -- Only run OnUpdate while actively dragging — zero cost at rest.
    -- SnapHandleToAnchor is called explicitly everywhere the anchor moves
    -- (UpdateAnchorPosition, OnDragStop, OnShow) so no polling is needed.
    local function AnchorOnUpdate()
        SnapHandleToAnchor()
    end
    handle:HookScript("OnShow", SnapHandleToAnchor)

    handle:SetScript("OnDragStart", function()
        anchor:StartMoving()
        anchor:SetScript("OnUpdate", AnchorOnUpdate)
    end)
    handle:SetScript("OnDragStop", function()
        anchor:StopMovingOrSizing()
        anchor:SetScript("OnUpdate", nil)
        SnapHandleToAnchor()
        -- Save the layoutAnchor corner position relative to UIParent CENTER.
        -- Grid2 equivalent: SavePosition uses the anchor corner (LEFT/RIGHT/
        -- TOP/BOTTOM) to decide which edge coordinates to persist.
        local la = BF:GetLayoutAnchor()
        local ux, uy = UIParent:GetCenter()
        local ax = la:find("LEFT")  and anchor:GetLeft()  or la:find("RIGHT")  and anchor:GetRight()  or anchor:GetCenter()
        local ay = la:find("TOP")   and anchor:GetTop()   or la:find("BOTTOM") and anchor:GetBottom() or select(2, anchor:GetCenter())
        local nx = BF:SnapAnchor(ax - ux)
        local ny = BF:SnapAnchor(ay - uy)
        -- Round to integers so saved values match the slider step of 1.
        nx = math.floor(nx + 0.5)
        ny = math.floor(ny + 0.5)
        anchor:ClearAllPoints()
        anchor:SetPoint(la, UIParent, "CENTER", nx, ny)
        -- Save to the profile the user is actually editing in setup mode,
        -- not the currently active context (which may differ when e.g.
        -- editing the raid layout while solo in the open world).
        local modProfile = self:GetModifyingProfile()
        modProfile.anchorX = nx
        modProfile.anchorY = ny
        -- Notify the options panel so the position sliders reflect the drag.
        BF:RefreshPanel("layoutPosition")
    end)

    local label = handle:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("CENTER")
    label:SetText("BuzzardFrames")
    label:SetTextColor(1, 1, 1)
    handle:Hide()
    anchor.handle = handle

    self.anchorFrame = anchor

    -- ── Test anchor (setup mode only) ──────────────────────────────────────
    -- Starts at the same position as the real anchor and moves independently
    -- during setup mode.  Its drag saves to anchorX/Y on the modifying
    -- profile.  When the real anchor is repositioned outside setup mode, the
    -- test anchor is snapped to match (see UpdateAnchorPosition).
    local testAnchor = CreateFrame("Frame", "BuzzardFramesTestAnchor", UIParent)
    testAnchor:SetSize(1, 1)
    testAnchor:SetFrameStrata("MEDIUM")
    testAnchor:SetPoint(_initAnchor, UIParent, "CENTER", BF:SnapAnchor(_initX), BF:SnapAnchor(_initY))
    testAnchor:SetMovable(true)
    testAnchor:SetClampedToScreen(true)
    testAnchor:EnableMouse(false)

    local testHandle = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    testHandle:SetSize(200, 16)
    testHandle:SetFrameStrata("MEDIUM")
    testHandle:SetFrameLevel(101)
    testHandle:SetBackdrop({
        bgFile = "Interface\\Buttons\\White8x8",
        edgeFile = "Interface\\Buttons\\White8x8",
        edgeSize = 1,
    })
    testHandle:SetBackdropColor(0.1, 0.5, 0.2, 0.8)
    testHandle:SetBackdropBorderColor(0.2, 0.9, 0.4, 1)
    testHandle:EnableMouse(true)
    testHandle:SetMovable(true)
    testHandle:RegisterForDrag("LeftButton")

    local function SnapTestHandleToAnchor()
        testHandle:ClearAllPoints()
        testHandle:SetPoint("BOTTOMLEFT", testAnchor, "TOPLEFT", 0, 2)
    end
    testAnchor.SnapHandle = SnapTestHandleToAnchor

    testHandle:HookScript("OnShow", SnapTestHandleToAnchor)

    local _dragging = false

    -- OnUpdate only runs during an active drag — zero cost at rest.
    -- SnapTestHandleToAnchor is called explicitly on show, drag-stop, and
    -- whenever UpdateAnchorPosition repositions the test anchor.
    local function TestAnchorOnUpdate()
        SnapTestHandleToAnchor()
        if self.anchorFrame and self:ActiveMatchesModifying() then
            local la = BF:GetModifyingLayoutAnchor()
            local ux2, uy2 = UIParent:GetCenter()
            local ax = la:find("LEFT") and testAnchor:GetLeft() or la:find("RIGHT") and testAnchor:GetRight() or testAnchor:GetCenter()
            local ay = la:find("TOP") and testAnchor:GetTop() or la:find("BOTTOM") and testAnchor:GetBottom() or select(2, testAnchor:GetCenter())
            if ax and ay then
                self.anchorFrame:ClearAllPoints()
                self.anchorFrame:SetPoint(la, UIParent, "CENTER", BF:SnapAnchor(ax - ux2), BF:SnapAnchor(ay - uy2))
            end
        end
    end

    testHandle:SetScript("OnDragStart", function()
        _dragging = true
        testAnchor:StartMoving()
        testAnchor:SetScript("OnUpdate", TestAnchorOnUpdate)
    end)
    testHandle:SetScript("OnDragStop", function()
        _dragging = false
        testAnchor:StopMovingOrSizing()
        testAnchor:SetScript("OnUpdate", nil)
        SnapTestHandleToAnchor()
        local la = BF:GetModifyingLayoutAnchor()
        local ux, uy = UIParent:GetCenter()
        local ax = la:find("LEFT") and testAnchor:GetLeft() or la:find("RIGHT") and testAnchor:GetRight() or testAnchor:GetCenter()
        local ay = la:find("TOP") and testAnchor:GetTop() or la:find("BOTTOM") and testAnchor:GetBottom() or select(2, testAnchor:GetCenter())
        local nx, ny = BF:SnapAnchor(ax - ux), BF:SnapAnchor(ay - uy)
        -- Round to integers so saved values match the slider step of 1.
        nx = math.floor(nx + 0.5)
        ny = math.floor(ny + 0.5)
        testAnchor:ClearAllPoints()
        testAnchor:SetPoint(la, UIParent, "CENTER", nx, ny)

        -- Save position to anchorX/Y immediately so the position is never
        -- lost regardless of how setup mode is exited.
        local modProfile = self:GetModifyingProfile()
        if modProfile then
            modProfile.anchorX = nx
            modProfile.anchorY = ny
        end
        -- v53 Phase 2.2: position-level dirt for the main layout. The real
        -- anchor is already moved in lockstep above when the edited flat is
        -- the live one; exit only re-chains the headers against it.
        BF:MarkSetupDirty("raid", SETUP_DIRTY_POS)

        -- Also move the real anchor frame when editing the currently-active
        -- layout+group (they represent the same frames on screen).
        if self:ActiveMatchesModifying() then
            if self.anchorFrame then
                self.anchorFrame:ClearAllPoints()
                self.anchorFrame:SetPoint(la, UIParent, "CENTER", nx, ny)
                if self.anchorFrame.SnapHandle then self.anchorFrame.SnapHandle() end
            end
        end
        -- Notify the options panel so the position sliders reflect the drag.
        BF:RefreshPanel("layoutPosition")
    end)

    local testLabel = testHandle:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    testLabel:SetPoint("CENTER")
    testLabel:SetText("BuzzardFrames [Setup]")
    testLabel:SetTextColor(1, 1, 1)
    testHandle:Hide()
    testAnchor.handle = testHandle

    self.testAnchorFrame = testAnchor

    -- Apply tiny handle mode immediately if it was saved on from a previous session
    if self.db and self.db.profile and self.db.global.tinyHandle then
        self:ApplyTinyHandle()
    end
end
-- ============================================================
-- TEST MODE - Show dummy raid frames for positioning
-- ============================================================


-- POOL SIZE: always build 40 frames so switching tiers never needs a rebuild --
-- only the visible count (testHeader.activeCount) changes between calls.      --
local TEST_FRAME_POOL_SIZE = 40

function BF:CreateTestHeader(profile)
    if self.testHeader then return self.testHeader end

    local p = self.db.profile
    -- Initial dimensions come from the modifying flat. `profile` is passed
    -- by UpdateTestFrames. _ReconfigureTestFrames will overwrite these on
    -- every call, so the initial values just need to be non-nil.
    local raidProfile = profile or self:GetModifyingProfile() or self:GetRaidProfile()
    
    -- Create an INSECURE frame container for test units.
    -- HIGH strata sits above the real frames (MEDIUM) so test frames cover
    -- them visually without ever calling Hide() on secure frame children.
    local header = CreateFrame("Frame", "BuzzardFramesTestHeader", self.testAnchorFrame)
    header:SetPoint("TOPLEFT", self.testAnchorFrame, "TOPLEFT", 0, 0)
    header:SetSize(1, 1)
    header:SetFrameStrata("HIGH")
    
    -- Always build the full pool of 40 frames up-front.
    -- UpdateTestFrames will show/hide the correct subset and reposition them,
    -- so switching tiers (20/30/40) never destroys or recreates frames.
    local numFrames = TEST_FRAME_POOL_SIZE

    -- Create dummy frames
    local frames = {}
    -- Initial frame dimensions come from the modifying flat. Will be
    -- overwritten by _ReconfigureTestFrames on every update call.
    local frameWidth = BF:PixelRound(raidProfile.frameWidth or 70)
    local frameHeight = BF:PixelRound(raidProfile.frameHeight or 40)
    
    for i = 1, numFrames do
        local frame = CreateFrame("Button", "BuzzardFramesTestFrame"..i, header, "BackdropTemplate")
        frame:SetSize(frameWidth, frameHeight)
        frame:RegisterForDrag("LeftButton")
        frame:SetScript("OnDragStart", function()
            if self.testAnchorFrame then
                self.testAnchorFrame:StartMoving()
                self.testAnchorFrame:SetScript("OnUpdate", function()
                    if self.testAnchorFrame.SnapHandle then self.testAnchorFrame.SnapHandle() end
                    -- Move real anchor in real-time when editing the active layout
                    if self.anchorFrame and self:ActiveMatchesModifying() then
                        local la = BF:GetModifyingLayoutAnchor()
                        local ux, uy = UIParent:GetCenter()
                        local ax = la:find("LEFT") and self.testAnchorFrame:GetLeft() or la:find("RIGHT") and self.testAnchorFrame:GetRight() or self.testAnchorFrame:GetCenter()
                        local ay = la:find("TOP") and self.testAnchorFrame:GetTop() or la:find("BOTTOM") and self.testAnchorFrame:GetBottom() or select(2, self.testAnchorFrame:GetCenter())
                        if ax and ay then
                            self.anchorFrame:ClearAllPoints()
                            self.anchorFrame:SetPoint(la, UIParent, "CENTER", BF:SnapAnchor(ax - ux), BF:SnapAnchor(ay - uy))
                        end
                    end
                end)
            end
        end)
        frame:SetScript("OnDragStop", function()
            if self.testAnchorFrame then
                self.testAnchorFrame:StopMovingOrSizing()
                self.testAnchorFrame:SetScript("OnUpdate", nil)
                local la = BF:GetModifyingLayoutAnchor()
                local ux, uy = UIParent:GetCenter()
                local ax = la:find("LEFT") and self.testAnchorFrame:GetLeft() or la:find("RIGHT") and self.testAnchorFrame:GetRight() or self.testAnchorFrame:GetCenter()
                local ay = la:find("TOP") and self.testAnchorFrame:GetTop() or la:find("BOTTOM") and self.testAnchorFrame:GetBottom() or select(2, self.testAnchorFrame:GetCenter())
                if ax and ux then
                    local nx, ny = BF:SnapAnchor(ax - ux), BF:SnapAnchor(ay - uy)
                    nx = math.floor(nx + 0.5)
                    ny = math.floor(ny + 0.5)
                    self.testAnchorFrame:ClearAllPoints()
                    self.testAnchorFrame:SetPoint(la, UIParent, "CENTER", nx, ny)
                    if self.testAnchorFrame.SnapHandle then self.testAnchorFrame.SnapHandle() end
                    local prof = self:GetModifyingProfile()
                    if prof then
                        prof.anchorX = nx
                        prof.anchorY = ny
                    end
                    -- v53 Phase 2.2: position-level dirt for the main layout. The real
                    -- anchor is already moved in lockstep above when the edited flat is
                    -- the live one; exit only re-chains the headers against it.
                    BF:MarkSetupDirty("raid", SETUP_DIRTY_POS)
                    if self:ActiveMatchesModifying() then
                        if self.anchorFrame then
                            self.anchorFrame:ClearAllPoints()
                            self.anchorFrame:SetPoint(la, UIParent, "CENTER", nx, ny)
                            if self.anchorFrame.SnapHandle then self.anchorFrame.SnapHandle() end
                        end
                    end
                    BF:RefreshPanel("layoutPosition")
                end
            end
        end)
        
        -- Initial position at origin; _ReconfigureTestFrames will place
        -- all frames correctly on the first UpdateTestFrames call.
        frame:SetPoint("TOPLEFT", header, "TOPLEFT", 0, 0)
        
        -- Background
        local bg = BF.Texture(frame, nil, "BACKGROUND")
        bg:SetAllPoints(frame)
        local bgR, bgG, bgB, bgA = GetSetupFrameColors()
        bg:SetColorTexture(bgR, bgG, bgB, bgA)
        bg:SetAlpha(SETUP_CONTENT_ALPHA)
        frame.bg = bg

        -- Unit border (texture-based, matches real frames)
        -- Created hidden; _ApplyProfileVisualsToTestFrame shows/hides
        -- and anchors them based on the enableBorder profile setting.
        local border = CreateFrame("Frame", nil, frame)
        border:SetAllPoints(frame)
        border:SetFrameLevel(frame:GetFrameLevel() + 10)
        border:EnableMouse(false)
        local function TEdge(parent)
            local t = BF.Texture(parent, nil, "OVERLAY")
            t:SetColorTexture(0, 0, 0, 0)
            t:Hide()
            return t
        end
        border.top    = TEdge(border)
        border.bottom = TEdge(border)
        border.left   = TEdge(border)
        border.right  = TEdge(border)
        frame.unitBorder = border

        frames[i] = frame
    end
    
    header.frames = frames
    -- activeCount tracks how many frames are currently shown (changes per tier switch)
    header.activeCount = numFrames

    -- Flexible-width placeholder: a single large box shown instead of the 40
    -- individual test frames when scaleRaidToFit is ON and we're editing a
    -- raid flat. Sized to match the full 40-man raid's bounding rectangle,
    -- with centered text explaining the mode.
    -- Reuses the same drag handlers as the regular test frames so the user
    -- can still reposition the anchor by dragging.
    do
        local flex = CreateFrame("Button", "BuzzardFramesTestFlexBox", header, "BackdropTemplate")
        flex:SetPoint("TOPLEFT", header, "TOPLEFT", 0, 0)
        flex:RegisterForDrag("LeftButton")
        flex:SetScript("OnDragStart", function()
            if self.testAnchorFrame then
                self.testAnchorFrame:StartMoving()
                self.testAnchorFrame:SetScript("OnUpdate", function()
                    if self.testAnchorFrame.SnapHandle then self.testAnchorFrame.SnapHandle() end
                    if self.anchorFrame and self:ActiveMatchesModifying() then
                        local la = BF:GetModifyingLayoutAnchor()
                        local ux, uy = UIParent:GetCenter()
                        local ax = la:find("LEFT") and self.testAnchorFrame:GetLeft() or la:find("RIGHT") and self.testAnchorFrame:GetRight() or self.testAnchorFrame:GetCenter()
                        local ay = la:find("TOP") and self.testAnchorFrame:GetTop() or la:find("BOTTOM") and self.testAnchorFrame:GetBottom() or select(2, self.testAnchorFrame:GetCenter())
                        if ax and ay then
                            self.anchorFrame:ClearAllPoints()
                            self.anchorFrame:SetPoint(la, UIParent, "CENTER", BF:SnapAnchor(ax - ux), BF:SnapAnchor(ay - uy))
                        end
                    end
                end)
            end
        end)
        flex:SetScript("OnDragStop", function()
            if self.testAnchorFrame then
                self.testAnchorFrame:StopMovingOrSizing()
                self.testAnchorFrame:SetScript("OnUpdate", nil)
                local la = BF:GetModifyingLayoutAnchor()
                local ux, uy = UIParent:GetCenter()
                local ax = la:find("LEFT") and self.testAnchorFrame:GetLeft() or la:find("RIGHT") and self.testAnchorFrame:GetRight() or self.testAnchorFrame:GetCenter()
                local ay = la:find("TOP") and self.testAnchorFrame:GetTop() or la:find("BOTTOM") and self.testAnchorFrame:GetBottom() or select(2, self.testAnchorFrame:GetCenter())
                if ax and ux then
                    local nx, ny = BF:SnapAnchor(ax - ux), BF:SnapAnchor(ay - uy)
                    nx = math.floor(nx + 0.5)
                    ny = math.floor(ny + 0.5)
                    self.testAnchorFrame:ClearAllPoints()
                    self.testAnchorFrame:SetPoint(la, UIParent, "CENTER", nx, ny)
                    if self.testAnchorFrame.SnapHandle then self.testAnchorFrame.SnapHandle() end
                    local prof = self:GetModifyingProfile()
                    if prof then
                        prof.anchorX = nx
                        prof.anchorY = ny
                    end
                    -- v53 Phase 2.2: position-level dirt for the main layout. The real
                    -- anchor is already moved in lockstep above when the edited flat is
                    -- the live one; exit only re-chains the headers against it.
                    BF:MarkSetupDirty("raid", SETUP_DIRTY_POS)
                    if self:ActiveMatchesModifying() then
                        if self.anchorFrame then
                            self.anchorFrame:ClearAllPoints()
                            self.anchorFrame:SetPoint(la, UIParent, "CENTER", nx, ny)
                            if self.anchorFrame.SnapHandle then self.anchorFrame.SnapHandle() end
                        end
                    end
                    BF:RefreshPanel("layoutPosition")
                end
            end
        end)

        local bg = BF.Texture(flex, nil, "BACKGROUND")
        bg:SetAllPoints(flex)
        local bgR, bgG, bgB, bgA = GetSetupFrameColors()
        bg:SetColorTexture(bgR, bgG, bgB, bgA)
        bg:SetAlpha(SETUP_CONTENT_ALPHA)
        flex.bg = bg

        -- Border edges (solid color, same style as regular test frames)
        local function Edge(parent)
            local t = BF.Texture(parent, nil, "OVERLAY")
            local _, _, _, _, bR, bG, bB, bA = GetSetupFrameColors()
            t:SetColorTexture(bR, bG, bB, bA)
            return t
        end
        local thickness = 2
        local top = Edge(flex)
        top:SetPoint("TOPLEFT", flex, "TOPLEFT", 0, 0)
        top:SetPoint("TOPRIGHT", flex, "TOPRIGHT", 0, 0)
        top:SetHeight(thickness)
        local bot = Edge(flex)
        bot:SetPoint("BOTTOMLEFT", flex, "BOTTOMLEFT", 0, 0)
        bot:SetPoint("BOTTOMRIGHT", flex, "BOTTOMRIGHT", 0, 0)
        bot:SetHeight(thickness)
        local lft = Edge(flex)
        lft:SetPoint("TOPLEFT", flex, "TOPLEFT", 0, 0)
        lft:SetPoint("BOTTOMLEFT", flex, "BOTTOMLEFT", 0, 0)
        lft:SetWidth(thickness)
        local rgt = Edge(flex)
        rgt:SetPoint("TOPRIGHT", flex, "TOPRIGHT", 0, 0)
        rgt:SetPoint("BOTTOMRIGHT", flex, "BOTTOMRIGHT", 0, 0)
        rgt:SetWidth(thickness)

        local flexLabel = flex:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        flexLabel:SetPoint("CENTER", flex, "CENTER", 0, 0)
        flexLabel:SetText("Raid Frames: Flexible Width Mode")
        flexLabel:SetTextColor(1, 1, 1, 0.95)
        flex._label = flexLabel

        flex:Hide()
        header.flexBox = flex
    end

    -- Label overlay (same style as UF test frame labels).
    -- Parented to a high-level overlay frame so it renders above the cells.
    local labelOverlay = CreateFrame("Frame", nil, header)
    labelOverlay:SetAllPoints(header)
    labelOverlay:SetFrameStrata("HIGH")
    labelOverlay:SetFrameLevel(200)
    local label = labelOverlay:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetText("Raid Frames")
    label:SetTextColor(1, 1, 1, 0.9)
    header._label = label

    self.testHeader = header
    return header
end

function BF:CreatePartyTestHeader(profile)
    if self.partyTestHeader then return self.partyTestHeader end

    local p = self.db.profile

    -- Create an INSECURE frame container for test party frames.
    -- HIGH strata covers real frames without hiding them.
    local header = CreateFrame("Frame", "BuzzardFramesPartyTestHeader", self.testAnchorFrame)
    header:SetPoint("TOPLEFT", self.testAnchorFrame, "TOPLEFT", 0, 0)
    header:SetSize(1, 1)
    header:SetFrameStrata("HIGH")
    -- Create 5 dummy frames (player + party1-4)
    local frames = {}
    -- Initial dimensions come from the modifying flat. `profile` is passed
    -- by UpdatePartyTestFrames. _ReconfigureTestFrames / UpdatePartyTestFrames
    -- overwrite these on every call, so the initial values just need to be non-nil.
    local pp = profile or BF:GetModifyingProfile() or BF:GetActivePartyProfile()
    local spacing = BF:PixelSnap(pp.frameSpacing or 0)
    local frameWidth = BF:PixelRound(pp.frameWidth or 100)
    local frameHeight = BF:PixelRound(pp.frameHeight or 68)
    -- Party growDirection moved to rpDB.profile.sorting.growDirection (or
    -- flat.sorting.growDirection when per-layout toggle is ON).
    local sp = BF:GetSectionProfile("sorting", pp)
    local growDir = (sp and sp.growDirection) or "RIGHT"
    
    local PARTY_NAMES = { "Aelorian", "Bryndis", "Caelan", "Draven", "Elyssia" }
    local PARTY_ROLES = { "HEALER", "TANK", "DAMAGER", "DAMAGER", "HEALER" }

    for i = 1, 5 do
        local frame = CreateFrame("Button", "BuzzardFramesPartyTestFrame"..i, header, "BackdropTemplate")
        frame:SetSize(frameWidth, frameHeight)
        frame:RegisterForDrag("LeftButton")
        frame:SetScript("OnDragStart", function()
            if self.testAnchorFrame then
                self.testAnchorFrame:StartMoving()
                self.testAnchorFrame:SetScript("OnUpdate", function()
                    if self.testAnchorFrame.SnapHandle then self.testAnchorFrame.SnapHandle() end
                    if self.anchorFrame and self:ActiveMatchesModifying() then
                        local la = BF:GetModifyingLayoutAnchor()
                        local ux, uy = UIParent:GetCenter()
                        local ax = la:find("LEFT") and self.testAnchorFrame:GetLeft() or la:find("RIGHT") and self.testAnchorFrame:GetRight() or self.testAnchorFrame:GetCenter()
                        local ay = la:find("TOP") and self.testAnchorFrame:GetTop() or la:find("BOTTOM") and self.testAnchorFrame:GetBottom() or select(2, self.testAnchorFrame:GetCenter())
                        if ax and ay then
                            self.anchorFrame:ClearAllPoints()
                            self.anchorFrame:SetPoint(la, UIParent, "CENTER", BF:SnapAnchor(ax - ux), BF:SnapAnchor(ay - uy))
                        end
                    end
                end)
            end
        end)
        frame:SetScript("OnDragStop", function()
            if self.testAnchorFrame then
                self.testAnchorFrame:StopMovingOrSizing()
                self.testAnchorFrame:SetScript("OnUpdate", nil)
                local la = BF:GetModifyingLayoutAnchor()
                local ux, uy = UIParent:GetCenter()
                local ax = la:find("LEFT") and self.testAnchorFrame:GetLeft() or la:find("RIGHT") and self.testAnchorFrame:GetRight() or self.testAnchorFrame:GetCenter()
                local ay = la:find("TOP") and self.testAnchorFrame:GetTop() or la:find("BOTTOM") and self.testAnchorFrame:GetBottom() or select(2, self.testAnchorFrame:GetCenter())
                if ax and ux then
                    local nx, ny = BF:SnapAnchor(ax - ux), BF:SnapAnchor(ay - uy)
                    nx = math.floor(nx + 0.5)
                    ny = math.floor(ny + 0.5)
                    self.testAnchorFrame:ClearAllPoints()
                    self.testAnchorFrame:SetPoint(la, UIParent, "CENTER", nx, ny)
                    if self.testAnchorFrame.SnapHandle then self.testAnchorFrame.SnapHandle() end
                    local prof = self:GetModifyingProfile()
                    if prof then
                        prof.anchorX = nx
                        prof.anchorY = ny
                    end
                    -- v53 Phase 2.2: position-level dirt for the main layout. The real
                    -- anchor is already moved in lockstep above when the edited flat is
                    -- the live one; exit only re-chains the headers against it.
                    BF:MarkSetupDirty("raid", SETUP_DIRTY_POS)
                    if self:ActiveMatchesModifying() then
                        if self.anchorFrame then
                            self.anchorFrame:ClearAllPoints()
                            self.anchorFrame:SetPoint(la, UIParent, "CENTER", nx, ny)
                            if self.anchorFrame.SnapHandle then self.anchorFrame.SnapHandle() end
                        end
                    end
                    BF:RefreshPanel("layoutPosition")
                end
            end
        end)

        -- Position based on grow direction (GROW_DIRECTION.md section 7)
        -- Party is always a single row/column (5 frames, no wrapping)
        if growDir == "RIGHT" or growDir == "LEFT" then
            frame:SetPoint("TOPLEFT", header, "TOPLEFT", (i - 1) * (frameWidth + spacing), 0)
        else
            frame:SetPoint("TOPLEFT", header, "TOPLEFT", 0, -(i - 1) * (frameHeight + spacing))
        end
        
        -- Background
        local bg = BF.Texture(frame, nil, "BACKGROUND")
        bg:SetAllPoints(frame)
        local bgR2, bgG2, bgB2, bgA2 = GetSetupFrameColors()
        bg:SetColorTexture(bgR2, bgG2, bgB2, bgA2)
        bg:SetAlpha(SETUP_CONTENT_ALPHA)
        frame.bg = bg

        -- Unit border (texture-based, matches real frames)
        -- Created hidden; _ApplyProfileVisualsToTestFrame shows/hides
        -- and anchors them based on the enableBorder profile setting.
        local border = CreateFrame("Frame", nil, frame)
        border:SetAllPoints(frame)
        border:SetFrameLevel(frame:GetFrameLevel() + 10)
        border:EnableMouse(false)
        local function TEdge2(parent)
            local t = BF.Texture(parent, nil, "OVERLAY")
            t:SetColorTexture(0, 0, 0, 0)
            t:Hide()
            return t
        end
        border.top    = TEdge2(border)
        border.bottom = TEdge2(border)
        border.left   = TEdge2(border)
        border.right  = TEdge2(border)
        frame.unitBorder = border

        table.insert(frames, frame)
    end
    
    header.frames = frames

    -- Label overlay (same style as UF test frame labels)
    local labelOverlay = CreateFrame("Frame", nil, header)
    labelOverlay:SetAllPoints(header)
    labelOverlay:SetFrameStrata("HIGH")
    labelOverlay:SetFrameLevel(200)
    local label = labelOverlay:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetText("Party Frames")
    label:SetTextColor(1, 1, 1, 0.9)
    header._label = label

    self.partyTestHeader = header
    return header
end
-- BF:UpdateFrameSpacing lives in BFLayout.lua. An older pre-Grid2-refactor copy
-- used to be defined here; it iterated the obsolete mainHeader/groupHeaders
-- structure, ignored _contextIsRaid, and had no debounce / PlaceHeaders /
-- ResizeAllFrames follow-up. The BFLayout.lua definition overrode it at load
-- order (toc loads SetupMode.lua at line 71, BFLayout.lua at line 81), so this
-- copy was dead. Removed to avoid drift.

-- BF:ResizeAllFrames lives in BFLayout.lua. An older pre-Grid2-refactor copy
-- used to be defined here; it iterated the obsolete mainHeader/groupHeaders
-- structure and lacked custom-frame / pet-frame handling. The BFLayout.lua
-- definition overrode it at load order (toc loads SetupMode.lua at line 71,
-- BFLayout.lua at line 81), so this copy was dead. Removed to avoid drift.

-- Returns the diagonally opposite corner anchor.
local function OppositeCorner(anchor)
    local lr = anchor:find("LEFT") and "RIGHT" or "LEFT"
    local tb = anchor:find("TOP")  and "BOTTOM" or "TOP"
    return tb .. lr
end

-- (Re-)draws the three diagonal grip lines on the resize handle so they
-- radiate from the corner that matches the handle's current position.
-- Called on first creation and whenever the grow direction changes.
function BF:_UpdateResizeHandleGrip(header, handle)
    handle = handle or header.resizeHandle
    if not handle then return end
    -- Determine which corner the handle sits at (opposite of groupAnchor).
    local ga = header._groupAnchor or "TOPLEFT"
    local corner = OppositeCorner(ga)

    -- Hide and recycle old lines.
    if handle._gripLines then
        for _, ln in ipairs(handle._gripLines) do ln:Hide() end
    end
    handle._gripLines = {}

    -- Sign multipliers: lines radiate inward from `corner`.
    -- For BOTTOMRIGHT: start offset goes left (-), end offset goes up (+).
    -- For BOTTOMLEFT:  start offset goes right (+), end offset goes up (+).
    -- etc.
    local sx = corner:find("RIGHT") and -1 or 1   -- along bottom/top edge
    local sy = corner:find("BOTTOM") and 1 or -1   -- along left/right edge

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
    addGripLine(4)   -- short  (nearest corner)
    addGripLine(8)   -- medium
    addGripLine(13)  -- long   (nearest far edges)

    handle._handleCorner = corner
end

-- Creates a resize handle at the opposite corner of the bounding box from the groupAnchor.
-- Dragging it updates the width/height profile settings and rebuilds test frames live.
function BF:CreateTestResizeHandle(header, isParty)
    -- Handle already exists — just re-anchor and show.
    if header.resizeHandle then
        self:_UpdateResizeHandleGrip(header)
        self:_AnchorResizeHandle(header)
        header.resizeHandle:Show()
        return
    end

    -- First creation: child of the header so it inherits scale.
    local handle = CreateFrame("Frame", nil, header)
    handle:SetFrameStrata(header:GetFrameStrata())
    -- +20, NOT +1. The test frames are Buttons parented to this same header with
    -- no explicit SetFrameLevel, so they default to header level + 1 — exactly
    -- what +1 gives the handle. Same strata, same level, and _AnchorResizeHandle
    -- deliberately places the handle INSIDE the bounding box on top of the last
    -- cell, so the two tie on mouse hit-testing and the Button (mouse-enabled by
    -- default, with RegisterForDrag) can swallow the click. The handle still
    -- LOOKS on top because its grip lines are OVERLAY layer while the cell
    -- background is BACKGROUND — draw order and hit order diverge, which is why
    -- the symptom is "visible but acts like it doesn't exist".
    -- 20 clears both the cells (+1) and their borders (+10 relative to the cell),
    -- matching the gap convention used everywhere else in this addon.
    --
    -- ABSOLUTE level 120, not header-relative: header-relative (+20 ≈ level 22)
    -- left the handle BELOW other mouse-enabled setup-mode overlays in the
    -- same HIGH strata — UF test frames sit at level 100
    -- (SetupMode_UnitFrames.lua) and CFG drag handles at 110
    -- (SetupModeCustomFrames.lua:120). A user whose player/target/castbar
    -- setup boxes overlap the raid grid's corner had the click swallowed by
    -- them: handle visible, unresponsive — while users without the overlap
    -- were fine. 120 clears every mouse-enabled setup overlay.
    handle:SetFrameLevel(math.max(120, header:GetFrameLevel() + 20))
    handle:SetSize(16, 16)
    handle:EnableMouse(true)
    handle._gripLines = {}

    self:_UpdateResizeHandleGrip(header, handle)

    handle:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" then return end
        self.isDragging = true

        local scale = UIParent:GetEffectiveScale()

        -- Snapshot cursor position and current frame dimensions at drag start.
        -- Each OnUpdate computes how far the cursor moved from the start point
        -- and adds that delta (converted to profile units) to the start dimensions.
        -- This avoids needing any coordinate-space origin from the header frame.
        local startCX, startCY = GetCursorPosition()

        local startW, startH, spacingH, spacingV, frameScale, numCols, numRows
        -- Read from the currently-modifying flat. Handler runs at drag-start,
        -- not at creation time, so resolution happens now.
        if isParty then
            local pp = BF:GetModifyingProfile() or BF:GetActivePartyProfile()
            startW     = pp.frameWidth   or 100
            startH     = pp.frameHeight  or 68
            spacingH   = pp.frameSpacing or 0
            spacingV   = pp.frameSpacing or 0
            frameScale = pp.frameScale   or 1.0
            -- Party growDirection moved to rpDB.profile.sorting.growDirection.
            local _partySP = BF:GetSectionProfile("sorting", pp)
            local growDir = (_partySP and _partySP.growDirection) or "RIGHT"
            if growDir == "RIGHT" or growDir == "LEFT" then
                numCols = 5 ; numRows = 1
            else
                numCols = 1 ; numRows = 5
            end
        else
            local rp = BF:GetModifyingProfile() or BF:GetRaidProfile()
            local bp = BF.rpDB.profile.layouts
            -- Sorting settings now in rpDB.profile.sorting.* (or flat.sorting.*
            -- when per-layout toggle is ON).
            local _raidSP = BF:GetSectionProfile("sorting", rp)
            startW     = rp.frameWidth    or 70
            startH     = rp.frameHeight   or 40
            spacingH   = rp.frameSpacingH or 0
            spacingV   = rp.frameSpacingV or 0
            frameScale = (rp.enableFrameScale and rp.frameScale) or 1.0
            local upc  = (_raidSP and _raidSP.sortingMode == "GROUP") and 5 or (_raidSP and _raidSP.unitsPerColumn or 5)
            local raidDir = (_raidSP and _raidSP.raidGrowDirection) or "DOWN"
            -- Flexible-Width Mode: the flex box represents a full 40-man raid's
            -- bounding rect (8 cols x 5 rows for vertical grow, 5 x 8 for
            -- horizontal). Drag math must use those dimensions so a pixel of
            -- cursor movement changes frameWidth/frameHeight by 1/8th or 1/5th.
            if BF.testHeader and BF.testHeader.flexBox and BF.testHeader.flexBox:IsShown() then
                if raidDir == "RIGHT" or raidDir == "LEFT" then
                    numCols = 5 ; numRows = 8
                else
                    numCols = 8 ; numRows = 5
                end
            else
                local activeCount = (BF.testHeader and BF.testHeader.activeCount)
                    or (BF.testHeader and BF.testHeader.frames and #BF.testHeader.frames)
                    or 20
                if raidDir == "RIGHT" or raidDir == "LEFT" then
                    numRows = upc
                    numCols = math.ceil(activeCount / upc)
                else
                    numCols = math.ceil(activeCount / upc)
                    numRows = upc
                end
            end
        end

        -- Drag direction depends on which corner the handle is at.
        -- BOTTOMRIGHT: drag right=wider, drag down=taller (default).
        -- BOTTOMLEFT:  drag left=wider,  drag down=taller.
        -- TOPRIGHT:    drag right=wider, drag up=taller.
        -- TOPLEFT:     drag left=wider,  drag up=taller.
        local corner = self._handleCorner or "BOTTOMRIGHT"
        local dxSign = corner:find("RIGHT") and 1 or -1
        local dySign = corner:find("BOTTOM") and 1 or -1

        self:SetScript("OnUpdate", function(self)
            local cx, cy = GetCursorPosition()
            local dW = dxSign * (cx - startCX) / scale / frameScale
            local dH = dySign * (startCY - cy) / scale / frameScale

            local newW = math.max(20, math.floor(startW + dW / numCols))
            local newH = math.max(10, math.floor(startH + dH / numRows))

            if isParty then
                local _pp = BF:GetModifyingProfile() or BF:GetActivePartyProfile()
                if newW ~= _pp.frameWidth or newH ~= _pp.frameHeight then
                    _pp.frameWidth  = newW
                    _pp.frameHeight = newH
                    BF:UpdatePartyTestFrames()
                end
            else
                local rp = BF:GetModifyingProfile() or BF:GetRaidProfile()
                if newW ~= rp.frameWidth or newH ~= rp.frameHeight then
                    rp.frameWidth  = newW
                    rp.frameHeight = newH
                    -- Lightweight per-tick update: resize/reposition test frames
                    -- for live visual feedback.  Real frames are not touched during
                    -- the drag — ResizeAllFrames on MouseUp commits final dimensions.
                    BF:ResizeTestFramesInPlace()
                end
            end
        end)
    end)

    handle:SetScript("OnMouseUp", function(self, button)
        self:SetScript("OnUpdate", nil)
        self.isDragging = false
        -- Resize dimensions were already written per-tick in OnUpdate.
        -- No anchor saving here — drag-stop handles that independently.
        BF:InvalidateRaidProfileCache()
        if BF.ResizeAllFrames then BF:ResizeAllFrames() end
        if BF.UpdateTestFrames then BF:UpdateTestFrames() end
        if BF.UpdatePartyTestFrames then BF:UpdatePartyTestFrames() end
        BF:RefreshPanel("layoutSize")
    end)

    header.resizeHandle = handle
    self:_AnchorResizeHandle(header)
    handle:Show()
end

-- Positions the resize handle at the bottom-right of the bounding box.
-- Called on creation and after every reconfigure (direction change, resize drag, etc.).
function BF:_AnchorResizeHandle(header)
    local handle = header.resizeHandle
    if not handle then return end
    handle:ClearAllPoints()
    if header.flexBox and header.flexBox:IsShown() then
        handle:SetPoint("BOTTOMRIGHT", header.flexBox, "BOTTOMRIGHT", 0, 0)
    else
        local bW = header._boundingW or 0
        local bH = header._boundingH or 0
        -- The header is anchored at its groupAnchor corner. The resize
        -- handle sits INSIDE the bounding box at the opposite corner.
        local ga = header._groupAnchor or "TOPLEFT"
        local corner = handle._handleCorner or OppositeCorner(ga)
        local offX = ga:find("LEFT") and bW or -bW
        local offY = ga:find("TOP")  and -bH or bH
        handle:SetPoint(corner, header, ga, offX, offY)
    end
end

function BF:PositionTestResizeHandle(header, isParty)
    if not header then return end
    local hasFlex = header.flexBox and header.flexBox:IsShown()
    if not hasFlex and (not header.frames or #header.frames == 0) then return end
    self:CreateTestResizeHandle(header, isParty)
end

-- Resize and reposition existing raid test frames in-place without destroying them.
-- Called during a drag operation so the handle stays alive and anchored.
function BF:ResizeTestFramesInPlace()
    if not self.testHeader or not self.testHeader.frames then return end
    -- Resolve profile at call time: the resize handle's OnUpdate fires during
    -- a drag on the modifying flat's frames, so GetModifyingProfile is correct.
    local flat = self:GetModifyingProfile()
    self:_ReconfigureTestFrames(flat, self.testHeader.activeCount or #self.testHeader.frames)
    self:_AnchorResizeHandle(self.testHeader)
    C_Timer.After(0, function()
        if BF.UpdateGroupLabels then BF:UpdateGroupLabels() end
    end)
end

-- Clears all test status icon flags and re-evaluates the affected icons/text
-- on every real active frame. Called whenever setup mode is disabled so that
-- test state never bleeds through to live frames.
function BF:ClearTestStatusFlags()
    -- v53 Phase 2.2: the four test-status toggles live in db.global and are
    -- only ever set from Options/Options_Icons.lua's debug switches, so in a
    -- normal session all four are already false and the sweep below is four
    -- indicator updates per active frame (160 calls in a 40-man raid) that
    -- cannot change anything -- Indicators/StatusIcons.lua only honors these
    -- flags on preview frames, never on the real ones.
    local g = BF.db.global
    if not (g.testPhased or g.testSummonPending
            or g.testResurrectPending or g.testVehicleIcon) then
        return
    end
    local p = self.db.profile
    BF.db.global.testPhased           = false
    BF.db.global.testSummonPending    = false
    BF.db.global.testResurrectPending = false
    BF.db.global.testVehicleIcon      = false
    for frame in pairs(self.activeFrames or {}) do
        if frame and frame.unit then
            self:UpdatePhased(frame)
            self:UpdateSummonPending(frame)
            self:UpdateResurrectPending(frame)
            self:UpdateVehicle(frame)
        end
    end
end

-- ToggleSetupMode(enabled, silent)
-- Single entry point for entering/exiting setup mode. Replaces the old
-- pair of ToggleTestMode (raid) + TogglePartyTestMode (party); frame type
-- is resolved from the currently-modifying flat inside UpdateSetupFrames.
-- `silent` suppresses the chat message and the UpdateAnchorPosition +
-- rebuild/re-place tail used by the profile-switch teardown path.
-- (v53 Phase 3: that tail no longer contains a ResizeAllFrames call.)
function BF:ToggleSetupMode(enabled, silent)
    self:InvalidateRaidProfileCache()
    if enabled then
        -- Modifying Layout reset rule: when entering Setup Mode while the
        -- options panel is NOT open, the last close of either panel left
        -- both closed, so _modifyingFlat should revert to the currently-
        -- active flat. If the panel IS open, the user has an active edit
        -- session and we preserve their selection.
        if not self:IsOptionsShown() then
            local fl = self.rpDB.profile.layouts.flatLayouts or {}
            local activeID = self:ResolveActiveFlat(self:GetActiveSlot())
            if activeID and activeID ~= "none" and fl[activeID] then
                self._modifyingFlat = activeID
            else
                self._modifyingFlat = fl.flat_party and "flat_party" or nil
            end
        end

        BF.db.global.setupModeActive = true

        -- Build/update test frames (handles both party and raid flats).
        -- UpdateAnchorPosition will position the test anchor from anchorX/Y.
        self:UpdateSetupFrames()

        self:UpdateAnchorPosition()
        self.preLockState = self.db.global.locked

        -- Hide the real frame handle; the test anchor handle is exposed
        -- in its place.
        if self.anchorFrame and self.anchorFrame.handle then
            self.anchorFrame.handle:Hide()
        end
        if self.testAnchorFrame then
            self.testAnchorFrame:EnableMouse(true)
            self.testAnchorFrame.handle:Hide()
        end

        if not silent then
            -- Resolve via GetModifyingProfile so first-toggle-after-login (when
            -- _modifyingFlat is still unset) reports the real flat name and
            -- frame count, matching what's actually being rendered. Falls back
            -- to the true active profile when _modifyingFlat is nil or stale.
            local flat = self:GetModifyingProfile()
            local name = (flat and flat.name) or "\226\128\148"
            local count = SetupFrameCount(flat)
            print("BuzzardFrames: Setup Mode enabled (" .. name .. ", " .. count .. " frames)")
        end

        self:UpdateSetupGrid()
        if self.UpdateGroupLabels       then self:UpdateGroupLabels()       end
        if self.ShowUFTestFrames        then self:ShowUFTestFrames()        end
        if self.ShowCustomFrameTestFrames then self:ShowCustomFrameTestFrames() end
        if self.ShowPetTestFrames         then self:ShowPetTestFrames()         end

        self:RefreshHandleVisibility()

        -- v53 Phase 2.2: arm exit dirtiness tracking. Runs LAST so the
        -- enter path's own ActiveMatchesModifying consumers (UpdateSetupFrames,
        -- UpdateAnchorPosition) don't count as user changes. A SILENT enter is
        -- a re-entry from a teardown/rebuild pair (UnitFrames/Options_UFLayouts.lua
        -- toggles setup mode off and straight back on when the UF layout
        -- changes) -- resetting there would drop dirtiness the session had
        -- already accumulated, so silent re-entries keep the running levels.
        if not silent then self:ResetSetupDirty() end
    else
        BF.db.global.setupModeActive = false

        -- v53 Phase 2.2: snapshot BEFORE anything below can add to it.
        -- setupModeActive is already false, so MarkSetupDirty is inert from
        -- here on and this snapshot cannot drift under us.
        local dirtyRaid = self._setupDirtyRaid or SETUP_DIRTY_NONE
        local dirtyPets = self._setupDirtyPets or SETUP_DIRTY_NONE
        local dirtyCFG  = self._setupDirtyCFG

        if self.testAnchorFrame then
            self.testAnchorFrame:EnableMouse(false)
            self.testAnchorFrame.handle:Hide()
        end

        local function hideHeader(h)
            if not h then return end
            if h.resizeHandle then h.resizeHandle:Hide() end
            if h.frames then
                local limit = h.activeCount or #h.frames
                for i = 1, limit do
                    local tf = h.frames[i]
                    if tf and tf.SF_DummyRestartTimer then
                        tf.SF_DummyRestartTimer:Cancel()
                        tf.SF_DummyRestartTimer = nil
                    end
                end
            end
            h:Hide()
        end
        hideHeader(self.testHeader)
        hideHeader(self.partyTestHeader)

        if not silent then
            self:UpdateAnchorPosition()
            self.preLockState = nil
            -- v53 Phase 2.2: the rebuild below is the pre-2.2 exit path and
            -- still runs whenever the session skipped real-frame work
            -- (dirtyRaid == FULL). When it skipped none, the real frames
            -- already carry every edit the session made -- every option setter
            -- that reached them did so live -- so rebuilding them reproduces
            -- the state they are already in, at the cost of a full-raid
            -- header rebuild plus a frame:Layout() sweep.
            --
            -- v53 Phase 3: the trailing self:ResizeAllFrames() that used to
            -- sit under UpdateFrameLayout() is GONE. It was a second, fully
            -- redundant frame:Layout() sweep over every child of every header:
            --   * UpdateFrameLayout() -> ReloadLayout(true) sets _forceReload,
            --     and LoadLayout brings up every header in groupsUsed through
            --     AddHeader -> FixHeaderAttributes -> UpdateFramesSizeForHeader,
            --     whose _forceReload branch unconditionally writes
            --     header.frameWidth/frameHeight + SetScale and dispatches
            --     frame:Layout() for every child (BFLayout.lua). CFG and pet
            --     headers get a second explicit UpdateFramesSizeForHeader after
            --     their cf*/pet* fields are stamped, so their sizing is final
            --     too.
            --   * ResizeAllFrames recomputed exactly the same numbers:
            --     BF:_ResolveHeaderSizeAndScale (which UpdateFramesSizeForHeader
            --     calls) is the verbatim extraction of ResizeAllFrames' math,
            --     scaleRaidToFit / GetFitFrameWidth included, for all three
            --     header classes. Nothing between the two calls can move them.
            --   * LoadLayout deliberately does NOT call ResizeAllFrames itself
            --     (see the "(Removed) self:ResizeAllFrames()" note in
            --     BFLayout.lua): a per-child Layout dispatch after the header
            --     has been shown wipes the private-aura anchors that
            --     OnAttributeChanged -> UpdateIndicators just registered, via
            --     IconIndicator:Layout -> ClearFrameAuraAnchors. Running it
            --     here reintroduced exactly that hazard on every FULL exit.
            -- Login and every profile apply already rebuild with
            -- ReloadLayout(true) alone; the FULL exit now does the same thing.
            -- PTR-VERIFY: frame dimensions, scale and scaleRaidToFit widths
            -- after a FULL exit must be identical to a /reload with the same
            -- profile. A CFG or pet header that comes back mis-sized (or a
            -- raid that ignores Scale Raid To Fit) points here.
            if dirtyRaid >= SETUP_DIRTY_FULL then
                if self.UpdateFrameLayout then self:UpdateFrameLayout() end
                -- UpdateFrameLayout() -> ReloadLayout(true) rebuilds the real
                -- header unconditionally; it has no notion of the party/raid
                -- enable toggles. If the context we're returning to is globally
                -- disabled, that rebuild leaves the real header shown again.
                -- GroupTypeChanged() re-runs the same contextDisabled check
                -- used everywhere else (GROUP_ROSTER_UPDATE, login) and hides
                -- it back down when appropriate; when the context IS enabled
                -- this is a cheap no-op via the flat/context skip-check.
                if self.GroupTypeChanged then self:GroupTypeChanged() end
            elseif not InCombatLockdown() then
                -- No rebuild happened, so there is nothing for
                -- GroupTypeChanged() to undo and it is deliberately skipped.
                -- Re-place only the scopes a saved position could have moved.
                if dirtyRaid >= SETUP_DIRTY_POS then
                    -- Main layout: headers hang off anchorFrame, which
                    -- UpdateAnchorPosition above has just re-placed from the
                    -- ACTIVE flat. PlaceHeaders re-chains them and UpdateSize
                    -- re-fits the anchor's bounding box; neither rebuilds a
                    -- header or touches a child frame.
                    if self.PlaceHeaders then self:PlaceHeaders() end
                    if self.UpdateSize   then self:UpdateSize()   end
                end
                if self.groupsUsed and self.RestoreDetachedHeaderPosition
                   and (dirtyCFG or dirtyPets >= SETUP_DIRTY_POS) then
                    for _, header in ipairs(self.groupsUsed) do
                        if header.isCustomFrame then
                            local gi = header.customGroupIndex
                            if gi and dirtyCFG and dirtyCFG[gi] then
                                self:RestoreDetachedHeaderPosition(header)
                            end
                        elseif header.isPetFrame and dirtyPets >= SETUP_DIRTY_POS then
                            self:RestoreDetachedHeaderPosition(header)
                        end
                    end
                end
            end
            print("BuzzardFrames: Setup Mode disabled")
        end

        self:UpdateSetupGrid()
        if self.UpdateGroupLabels       then self:UpdateGroupLabels()       end
        self:ClearTestStatusFlags()
        if self.HideUFTestFrames        then self:HideUFTestFrames()        end
        if self.HideCustomFrameTestFrames then self:HideCustomFrameTestFrames() end
        if self.HidePetTestFrames         then self:HidePetTestFrames()         end

        self:RefreshHandleVisibility()
    end

    -- Refresh the options panel's Setup Mode button label so it stays in
    -- sync regardless of how setup mode was toggled (minimap, slash cmd, etc.).
    self:RefreshPanelChrome("setupButton")
end

-- UpdateSetupFrames: dispatches to the raid or party test header based
-- on the currently-modifying flat's type. Safe to call whenever:
--   * setup mode is entered
--   * a showGroup toggle changes (count may change)
--   * the Modifying Layout dropdown picks a different flat
--   * a sizing/spacing/orientation setting changes on the modifying flat
-- When setup mode is off, hides both headers and returns.
function BF:UpdateSetupFrames()
    if not IsSetupModeActive() then
        if self.testHeader then
            if self.testHeader.resizeHandle then self.testHeader.resizeHandle:Hide() end
            self.testHeader:Hide()
        end
        if self.partyTestHeader then
            if self.partyTestHeader.resizeHandle then self.partyTestHeader.resizeHandle:Hide() end
            self.partyTestHeader:Hide()
        end
        if self.HidePetTestFrames then self:HidePetTestFrames() end
        return
    end

    local flat = self:GetModifyingProfile()
    local isParty = flat and flat.type == "party"
    local g = self.db.global

    if isParty then
        -- Party flat: hide raid test header if it was up, show party.
        if self.testHeader and self.testHeader:IsShown() then
            if self.testHeader.resizeHandle then self.testHeader.resizeHandle:Hide() end
            self.testHeader:Hide()
        end
        if g.partyFramesEnabled == false then
            -- Party frames are globally disabled: don't preview them in
            -- Setup Mode either.
            if self.partyTestHeader and self.partyTestHeader:IsShown() then
                if self.partyTestHeader.resizeHandle then self.partyTestHeader.resizeHandle:Hide() end
                self.partyTestHeader:Hide()
            end
        else
            self:UpdatePartyTestFrames()
        end
    else
        -- Raid flat: hide party test header if it was up, show raid.
        if self.partyTestHeader and self.partyTestHeader:IsShown() then
            if self.partyTestHeader.resizeHandle then self.partyTestHeader.resizeHandle:Hide() end
            self.partyTestHeader:Hide()
        end
        if g.raidFramesEnabled == false then
            -- Raid frames are globally disabled: don't preview them in
            -- Setup Mode either.
            if self.testHeader and self.testHeader:IsShown() then
                if self.testHeader.resizeHandle then self.testHeader.resizeHandle:Hide() end
                self.testHeader:Hide()
            end
        else
            self:UpdateTestFrames()
        end
    end

    -- Show/hide pet test frames based on the modifying flat's showPetFrames.
    if self.ShowPetTestFrames then self:ShowPetTestFrames() end
end

function BF:UpdateTestFrames()
    -- POOLING APPROACH: a single pool of TEST_FRAME_POOL_SIZE (40) frames
    -- lives across the entire session; count changes only flip show/hide
    -- on the pool. A full destroy+rebuild is only triggered when the pool
    -- does not yet exist.
    --
    -- Active count is derived from the currently-modifying flat's showGroup
    -- (party flats are dispatched away from here by UpdateSetupFrames).
    if not IsSetupModeActive() then
        if self.testHeader then
            if self.testHeader.resizeHandle then
                self.testHeader.resizeHandle:Hide()
            end
            self.testHeader:Hide()
        end
        return
    end

    local flat = self:GetModifyingProfile()
    if not flat or flat.type ~= "raid" then
        -- Party flat (or no flat) -- nothing for the raid header to do.
        if self.testHeader then
            if self.testHeader.resizeHandle then self.testHeader.resizeHandle:Hide() end
            self.testHeader:Hide()
        end
        return
    end

    local activeCount = SetupFrameCount(flat)

    -- Create the pool the first time, seeding dimensions from the modifying flat.
    if not self.testHeader then
        self:CreateTestHeader(flat)
    end

    -- Reconfigure: resize, reposition, and show/hide frames for the new count.
    self:_ReconfigureTestFrames(flat, activeCount)

    -- Show the header and refresh the resize handle (deferred so that the
    -- new scale/size is committed to the layout engine before we read GetLeft/GetTop).
    self.testHeader:Show()
    self:CreateTestResizeHandle(self.testHeader, false)
    C_Timer.After(0, function()
        if BF.testHeader and BF.testHeader:IsShown() then
            BF:PositionTestResizeHandle(BF.testHeader, false)
        end
    end)

    -- Reposition group labels after the header is visible so GetTop() returns valid values.
    C_Timer.After(0, function()
        if BF.UpdateGroupLabels then BF:UpdateGroupLabels() end
    end)
end

-- ============================================================
-- RECONFIGURE TEST FRAMES - Fast path used by UpdateTestFrames
-- Applies current raid profile settings (size, spacing, layout)
-- and shows/hides frames to match activeCount without any
-- frame creation or destruction.
-- ============================================================
-- Applies border, debuff highlight and overlay settings from the current
-- profile to a test/setup frame. Called after sizing/positioning so that
-- LayoutFrame has already run and healthBar bounds are correct.
function BF:_ApplyProfileVisualsToTestFrame(frame)
    -- Setup mode renders test frames for the currently-modifying flat.
    -- Resolve borders via GetSectionProfile so per-layout overrides on the
    -- modifying flat drive the test-frame visuals. Pre-v29 this read
    -- `self.db.profile` (the core DB), which has no border keys at all,
    -- so every guard was nil and setup-mode border thickness silently
    -- fell back to 1 while the debuff-border/overlay test flags were
    -- dead code.
    local modifying = self:GetModifyingProfile()
    local bp = self:GetSectionProfile("borders", modifying) or {}
    -- v35: debuff border/overlay keys moved from borders → auras.dispelIndicator.
    -- Resolve the auras section once here so the debuff-border and debuff-
    -- overlay test-frame paths below can read from diP.
    -- v60: resolved per aura sub-category, not by resolving the whole
    -- auras table and indexing it. The Buffs and Debuffs per-layout
    -- toggles are independent, so a flat's auras table can carry stale
    -- rawkeys for whichever group is currently OFF.
    local diP = self:GetAurasSubcatProfile("dispelIndicator", modifying) or {}

    -- Update health bar inset to match border thickness (without calling LayoutFrame
    -- which would overwrite the frame size and position set by _ReconfigureTestFrames).
    -- EffectiveBorderPixels: rounded border styles use fixed 2/3px art
    -- thickness. Setup-mode edges stay SQUARE deliberately (they render
    -- in the setup-frame schematic colors, not the real border art).
    local inset = BF:EffectiveBorderPixels(bp)
    if frame.healthBar then
        frame.healthBar:ClearAllPoints()
        frame.healthBar:SetPoint("TOPLEFT",     frame, "TOPLEFT",     inset,  -inset)
        frame.healthBar:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -inset,  inset)
        if frame.nameClip then
            frame.nameClip:ClearAllPoints()
            frame.nameClip:SetAllPoints(frame.healthBar)
        end
    end

    -- Border: match enableBorder, borderColor, borderThickness, borderOpacity
    if frame.unitBorder then
        local b = frame.unitBorder
        if b.top and b.bottom and b.left and b.right then
            if bp.enableBorder ~= false then
                local thickness = math.max(inset, 1)
                local _, _, _, _, bR, bG, bB, bA = GetSetupFrameColors()
                local c = { r=bR, g=bG, b=bB }
                local ba = bA
                -- Anchor edges to frame bounds (mirrors LayoutFrame)
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

    -- Debuff border geometry re-stamp (color cleared; dummy painter owns it)
    if frame.dispelDebuffBorder then
        local dh = frame.dispelDebuffBorder
        local thickness = diP.debuffBorderWidth or 2
        if dh.top and dh.bottom and dh.left and dh.right then
            dh.top:SetPoint("TOPLEFT",     frame, "TOPLEFT",     0, 0)
            dh.top:SetPoint("TOPRIGHT",    frame, "TOPRIGHT",    0, 0)
            dh.top:SetHeight(thickness)
            dh.bottom:SetPoint("BOTTOMLEFT",  frame, "BOTTOMLEFT",  0, 0)
            dh.bottom:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
            dh.bottom:SetHeight(thickness)
            dh.left:SetPoint("TOPLEFT",    frame, "TOPLEFT",    0, 0)
            dh.left:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
            dh.left:SetWidth(thickness)
            dh.right:SetPoint("TOPRIGHT",    frame, "TOPRIGHT",    0, 0)
            dh.right:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
            dh.right:SetWidth(thickness)
            -- testDebuffBorder REMOVED (never exposed in the UI): always
            -- cleared here; the dummy dispel painter shows the border.
            -- SetHighlightBorder also hides the rounded ring if present.
            self:SetHighlightBorder(dh, frame, 0, 0, 0, 0)
        end
    end

    -- testDebuffOverlay REMOVED (never exposed in the UI): always hidden
    -- here; the dummy dispel painter shows the overlay.
    if frame.dispelDebuffOverlay then
        frame.dispelDebuffOverlay:Hide()
    end
end

function BF:_ReconfigureTestFrames(profile, activeCount)
    if not self.testHeader or not self.testHeader.frames then return end

    -- Profile is passed by callers (UpdateTestFrames / ResizeTestFramesInPlace)
    -- and is always the currently-modifying flat. Fall back defensively.
    local raidProfile = profile or self:GetModifyingProfile() or self:GetRaidProfile()
    if not raidProfile then return end
    -- Raw frame dimensions before any pixel rounding. Fed to SnapHeaderScale
    -- so it computes the same snapped scale as ComputeHeaderScale does for
    -- real frames. If we pre-round frameW/frameH and THEN pass them in, the
    -- inputs are already pixel-aligned and the snap becomes a no-op, which
    -- produces a different (smaller) final scale than the real frames get.
    local rawFrameWidth  = raidProfile.frameWidth  or 70
    local rawFrameHeight = raidProfile.frameHeight or 40
    local frameWidth  = BF:PixelRound(rawFrameWidth)
    local frameHeight = BF:PixelRound(rawFrameHeight)
    local frameScale, scaleIndicators
    if raidProfile.enableFrameScale then
        frameScale      = raidProfile.frameScale  or 1.0
        scaleIndicators = raidProfile.scaleIndicators ~= false
    else
        frameScale      = 1.0
        scaleIndicators = true
    end
    local spacingH    = BF:PixelSnap(raidProfile.frameSpacingH or 0)
    local spacingV    = BF:PixelSnap(raidProfile.frameSpacingV or 0)
    local bp          = self.rpDB.profile.layouts
    -- Sorting settings moved to rpDB.profile.sorting.* (or flat.sorting.*
    -- when per-layout toggle is ON). Route via the modifying flat so
    -- per-layout overrides drive the test frame layout.
    local sp          = self:GetSectionProfile("sorting", raidProfile)
    local growDir     = (sp and sp.raidGrowDirection) or "DOWN"
    local secGrowDir = sp and sp.raidSecondaryGrowDirection
    local isHorizGrow = (growDir == "RIGHT" or growDir == "LEFT")
    local unitsPerColumn = (sp and sp.sortingMode == "GROUP") and 5 or (sp and sp.unitsPerColumn or 5)

    local header = self.testHeader
    local frames = header.frames

    -- Derive group anchor from grow direction so the test header pins
    -- to the correct corner of the test anchor frame (mirrors PlaceHeaders).
    local groupAnchor = self:DeriveGroupAnchor(growDir, secGrowDir)
    header:ClearAllPoints()
    header:SetPoint(groupAnchor, self.testAnchorFrame, groupAnchor, 0, 0)
    header._groupAnchor = groupAnchor

    -- Offset multipliers: frames grow away from the groupAnchor corner.
    local xMult = groupAnchor:find("LEFT")  and 1 or -1
    local yMult = groupAnchor:find("TOP")   and -1 or 1

    -- Setup mode intentionally does NOT track live roster size when
    -- scaleRaidToFit is on. The point of setup mode is to preview the full
    -- extent of the layout -- the smallest frame width the feature will
    -- ever produce (when all 8 groups are populated). activeCount stays at
    -- the tier pool count (SetupFrameCount), and GetFitFrameWidth is called
    -- with that same count so the preview width matches a full raid.

    -- ── Flexible-Width Mode fast path ─────────────────────────────────────
    -- When scaleRaidToFit is ON, individual frame widths are computed live
    -- from the roster composition, so previewing per-frame dimensions in
    -- setup mode is meaningless. Show a single bounding-box placeholder
    -- sized to the full 40-man layout extent instead.
    if bp.scaleRaidToFit and header.flexBox then
        -- Hide all per-unit pool frames and ghost frames.
        for _, f in ipairs(frames) do
            if f:IsShown() then f:Hide() end
        end
        -- Hide the header label (the flex box has its own centered label).
        if header._label then header._label:Hide() end

        -- Compute the bounding rectangle of a full 40-man raid at baseWidth.
        -- Vertical grow (DOWN/UP): 8 columns x 5 rows of (baseW x baseH).
        -- Horizontal grow (RIGHT/LEFT): 5 columns x 8 rows (swap axes).
        local baseW = BF:PixelRound(frameWidth)
        local baseH = BF:PixelRound(frameHeight)
        local cols, rows
        if isHorizGrow then
            cols, rows = 5, 8
        else
            cols, rows = 8, 5
        end
        local totalW = cols * baseW + (cols - 1) * spacingH
        local totalH = rows * baseH + (rows - 1) * spacingV

        -- Apply frame scale on the header (matches the normal path behavior).
        local hScale
        if scaleIndicators then
            hScale = SnapHeaderScale(frameScale, baseW, baseH)
        else
            hScale = 1.0
            totalW = BF:PixelRound(totalW * frameScale)
            totalH = BF:PixelRound(totalH * frameScale)
        end
        header:SetScale(hScale)
        header.activeCount = 0  -- no per-unit frames shown
        header.flexBox:ClearAllPoints()
        header.flexBox:SetPoint(groupAnchor, header, groupAnchor, 0, 0)
        header.flexBox:SetSize(totalW, totalH)
        header.flexBox:SetAlpha(SETUP_FRAME_ALPHA)
        header.flexBox:Show()
        return
    end

    -- Normal mode: make sure the flex box is hidden in case we just left
    -- flexible-width mode (e.g. user toggled scaleRaidToFit off).
    if header.flexBox and header.flexBox:IsShown() then
        header.flexBox:Hide()
    end
    if header._label and not header._label:IsShown() then
        header._label:Show()
    end

    -- Apply scale: if scaleIndicators, scale the header; otherwise keep header at 1
    -- and bake scale into frame dimensions so only the frame body scales.
    -- scaleRaidToFit: fit multiplier is applied to header after the normal path.
    local headerScale, layoutW, layoutH
    if scaleIndicators then
        -- v93: SnapHeaderScale now pixel-rounds internally (it must, or the
        -- rounding correction lands twice -- see the note in that function),
        -- so raw or rounded dimensions in produce the same result. Kept raw
        -- here purely so this call still mirrors BFLayout.lua's
        -- ComputeHeaderScale, which also reads ap.frameWidth raw.
        headerScale = SnapHeaderScale(frameScale, rawFrameWidth, rawFrameHeight)
        layoutW = frameWidth
        layoutH = frameHeight
    else
        headerScale = 1.0
        layoutW = BF:PixelRound(rawFrameWidth  * frameScale)
        layoutH = BF:PixelRound(rawFrameHeight * frameScale)
    end
    -- scaleRaidToFit: widen each frame so the actual raid's columns span the
    -- same total horizontal width as a full 40-man layout would.
    -- Height is intentionally left unchanged.
    if bp.scaleRaidToFit then
        layoutW = BF:PixelRound(BF:GetFitFrameWidth(layoutW, spacingH, activeCount))
    end
    header:SetScale(headerScale)

    -- Respect showGroup: build an ordered list of visible group indices so
    -- hidden groups are skipped in the layout.
    -- In GROUP mode: each group gets its own column; hidden groups are removed.
    -- In ROLE mode: hidden groups reduce the total unit count (units in those
    -- groups wouldn't appear on real frames because the header's groupFilter
    -- excludes them).
    local visibleGroupIndices = nil
    local vgCap, sg = BF:GetGroupVisibilityRule(raidProfile)
    local totalGroups = math.ceil(activeCount / 5)  -- always based on raid groups of 5
    if sp and sp.sortingMode == "GROUP" then
        visibleGroupIndices = {}
        for g = 1, totalGroups do
            if g <= vgCap and not (sg and sg[g] == false) then
                visibleGroupIndices[#visibleGroupIndices + 1] = g
            end
        end
    elseif sg or vgCap < 8 then
        -- ROLE mode: count how many groups are enabled and cap activeCount.
        local enabledGroups = 0
        for g = 1, totalGroups do
            if g <= vgCap and not (sg and sg[g] == false) then
                enabledGroups = enabledGroups + 1
            end
        end
        if enabledGroups < totalGroups then
            activeCount = math.min(activeCount, enabledGroups * 5)
        end
    end

    -- Compute bounding box extent via shared helper.
    local visGroupCount = visibleGroupIndices and #visibleGroupIndices or nil
    local bW, bH, gridCols, gridRows = ComputeGridExtent(
        activeCount, unitsPerColumn, isHorizGrow,
        layoutW, layoutH, spacingH, spacingV, visGroupCount)

    -- Position active frames using the shared grid helper.
    for i, frame in ipairs(frames) do
        if i > activeCount then
            frame:Hide()
        else
            -- In GROUP mode, check if this frame's group is visible
            local groupVisible = true
            if visibleGroupIndices then
                local groupIndex = math.ceil(i / unitsPerColumn)
                groupVisible = false
                for _, g in ipairs(visibleGroupIndices) do
                    if g == groupIndex then groupVisible = true; break end
                end
            end

            if not groupVisible then
                frame:Hide()
            else
                frame:SetSize(layoutW, layoutH)
                frame:ClearAllPoints()
                local colX, rowY = ComputeGridPosition(
                    i - 1, unitsPerColumn, isHorizGrow,
                    gridCols, gridRows, visibleGroupIndices, unitsPerColumn)
                frame:SetPoint(groupAnchor, header, groupAnchor,
                    xMult * colX * (layoutW + spacingH),
                    yMult * rowY * (layoutH + spacingV))
                frame:SetAlpha(SETUP_FRAME_ALPHA)
                frame:Show()
            end
        end
    end

    header.activeCount = activeCount
    header._boundingW = bW
    header._boundingH = bH

    -- Size the test anchor frame to match the bounding box (mirrors
    -- UpdateSize for the real anchor).
    if self.testAnchorFrame then
        local sW = math.max(bW * headerScale, 1)
        local sH = math.max(bH * headerScale, 1)
        self.testAnchorFrame:SetSize(sW, sH)
    end

    -- Apply visuals to active frames.
    for i, frame in ipairs(frames) do
        if i <= activeCount and frame:IsShown() then
            self:_ApplyProfileVisualsToTestFrame(frame)
        end
    end

    -- Position the label to cover the full bounding box.
    if header._label then
        if bW > 0 and bH > 0 then
            header._label:ClearAllPoints()
            header._label:SetPoint(groupAnchor, header, groupAnchor, 0, 0)
            header._label:SetSize(bW, bH)
            header._label:Show()
        end
    end
end
-- ============================================================
-- UPDATE PARTY TEST FRAMES - Reposition/resize without recreating
-- Called when party settings (size, spacing, orientation) change
-- while party test mode is active.
-- ============================================================
function BF:UpdatePartyTestFrames()
    if not IsSetupModeActive() then return end
    local flat = self:GetModifyingProfile()
    if not flat or flat.type ~= "party" then return end

    -- If test header doesn't exist yet, create it with the modifying flat's dimensions.
    if not self.partyTestHeader then
        self:CreatePartyTestHeader(flat)
        if not self.partyTestHeader then return end
        -- Fall through to the reposition/show logic below
    end


    local frames = self.partyTestHeader.frames
    if not frames then return end

    -- Read sizing/spacing/orientation from the modifying flat.
    local pp2 = flat
    local spacing     = pp2.frameSpacing or 0
    -- Dims fed to SnapHeaderScale, which pixel-rounds them itself (v93).
    -- Mirrors BFLayout.lua's ComputeHeaderScale for real frames. See
    -- _ReconfigureTestFrames for the full rationale.
    local rawFrameWidth  = pp2.frameWidth  or 100
    local rawFrameHeight = pp2.frameHeight or 68
    local frameWidth  = BF:PixelRound(rawFrameWidth)
    local frameHeight = BF:PixelRound(rawFrameHeight)
    local frameScale  = pp2.frameScale   or 1.0
    -- Party growDirection moved to rpDB.profile.sorting.growDirection (or
    -- flat.sorting.growDirection when per-layout toggle is ON).
    local sp2         = self:GetSectionProfile("sorting", pp2)
    local growDir     = (sp2 and sp2.growDirection) or "RIGHT"
    local header      = self.partyTestHeader

    -- Apply scale: if scaleIndicators, scale the header; otherwise bake into dimensions.
    local scaleIndicators = pp2.scaleIndicators ~= false
    local headerScale, layoutW, layoutH
    if scaleIndicators then
        headerScale = SnapHeaderScale(frameScale, rawFrameWidth, rawFrameHeight)
        layoutW = frameWidth
        layoutH = frameHeight
    else
        headerScale = 1.0
        layoutW = BF:PixelRound(rawFrameWidth  * frameScale)
        layoutH = BF:PixelRound(rawFrameHeight * frameScale)
    end
    header:SetScale(headerScale)

    -- Derive the group anchor from grow direction so the test header
    -- pins to the correct corner of the test anchor frame (mirrors
    -- PlaceHeaders which uses DeriveGroupAnchor for real headers).
    local groupAnchor = self:DeriveGroupAnchor(growDir, nil)
    header:ClearAllPoints()
    header:SetPoint(groupAnchor, self.testAnchorFrame, groupAnchor, 0, 0)
    header._groupAnchor = groupAnchor

    -- Offset multipliers: frames grow away from the groupAnchor corner.
    local xMult = groupAnchor:find("LEFT")  and 1 or -1
    local yMult = groupAnchor:find("TOP")   and -1 or 1
    local anchor = groupAnchor

    local numFrames = #frames
    for i, frame in ipairs(frames) do
        frame:SetSize(layoutW, layoutH)
        frame:ClearAllPoints()
        if growDir == "RIGHT" or growDir == "LEFT" then
            frame:SetPoint(anchor, header, anchor,
                xMult * (i - 1) * (layoutW + spacing), 0)
        else
            frame:SetPoint(anchor, header, anchor,
                0, yMult * (i - 1) * (layoutH + spacing))
        end
        frame:SetAlpha(SETUP_FRAME_ALPHA)
        frame:Show()
        self:_ApplyProfileVisualsToTestFrame(frame)
    end

    -- Store bounding box for resize handle positioning.
    if growDir == "RIGHT" or growDir == "LEFT" then
        header._boundingW = numFrames * layoutW + math.max(0, numFrames - 1) * spacing
        header._boundingH = layoutH
    else
        header._boundingW = layoutW
        header._boundingH = numFrames * layoutH + math.max(0, numFrames - 1) * spacing
    end

    -- Size the test anchor frame to match the bounding box (mirrors
    -- UpdateSize for the real anchor). This makes the groupAnchor corner
    -- meaningful — changing grow direction moves the header to a different
    -- corner of the correctly-sized rectangle.
    if self.testAnchorFrame then
        local sW = math.max(header._boundingW * headerScale, 1)
        local sH = math.max(header._boundingH * headerScale, 1)
        self.testAnchorFrame:SetSize(sW, sH)
    end

    header:Show()

    -- Position the label to cover the full bounding box.
    if header._label then
        header._label:ClearAllPoints()
        header._label:SetPoint(groupAnchor, header, groupAnchor, 0, 0)
        header._label:SetSize(header._boundingW, header._boundingH)
        header._label:Show()
    end

    -- Create (or refresh) the resize handle at the bounding box bottom-right.
    self:CreateTestResizeHandle(header, true)
    C_Timer.After(0, function()
        if BF.partyTestHeader and BF.partyTestHeader:IsShown() then
            BF:PositionTestResizeHandle(BF.partyTestHeader, true)
        end
    end)
end

-- ============================================================
-- UPDATE ANCHOR POSITION - Called when switching between party/raid
-- ============================================================
function BF:UpdateAnchorPosition()
    if not self.anchorFrame then return end

    -- Grid2 parity: queue at priority 8 in combat. anchorFrame is
    -- unprotected (mover frame) so priority 8 is conservative; it matches
    -- the visibility tier. See PEW_GRID2_REFACTOR_PLAN §3.5.
    if self:RunSecure(8, self, "UpdateAnchorPosition") then return end

    local p = self.db.profile

    -- Check if setup mode is active.
    local inSetupMode = BF.db.global.setupModeActive

    -- ── Real anchor ────────────────────────────────────────────────────────────
    -- Always positioned from the ACTIVE profile (the layout+group that is truly
    -- running, ignoring which layout/group the user is currently editing).
    --
    -- When active == modifying we also move the real anchor to stay in sync with
    -- the test anchor (they represent the same frames).  When they differ we must
    -- NOT touch the real anchor — the real frames should stay exactly where they
    -- are, showing the active layout's real saved position.
    local activeProfile = self:GetTrueActiveProfile()
    local anchorX = (activeProfile and activeProfile.anchorX) or -200
    local anchorY = (activeProfile and activeProfile.anchorY) or 100

    local layoutAnchor = self:GetLayoutAnchor()
    if not inSetupMode or self:ActiveMatchesModifying() then
        -- Safe to move: either not in setup mode, or editing the same context as active.
        self.anchorFrame:ClearAllPoints()
        self.anchorFrame:SetPoint(layoutAnchor, UIParent, "CENTER", BF:SnapAnchor(anchorX), BF:SnapAnchor(anchorY))
        if self.anchorFrame.SnapHandle then self.anchorFrame.SnapHandle() end
    end
    -- If inSetupMode and active != modifying: leave the real anchor exactly where
    -- it is — don't touch it at all.

    -- ── Test anchor ────────────────────────────────────────────────────────────
    -- Positioned from the MODIFYING profile.  Outside setup mode it snaps to the
    -- real anchor so the next entry starts from the current real position.
    if self.testAnchorFrame then
        local testX, testY
        local testLA = layoutAnchor  -- default: same as real anchor
        if inSetupMode then
            local modProfile = self:GetModifyingProfile()
            testX = (modProfile and modProfile.anchorX) or -200
            testY = (modProfile and modProfile.anchorY) or 100
            -- Read the modifying profile's layout anchor (may differ from the
            -- active profile's layout anchor when editing a different context).
            -- MUST go through the accessor: it returns "CENTER" when the
            -- party Grow from Center toggle is on (an inline corner read
            -- here left the test anchor corner-pinned at center offsets --
            -- the setup preview sat half a box right+down of the frames).
            testLA = self:GetModifyingLayoutAnchor()
        else
            testX = anchorX
            testY = anchorY
        end
        self.testAnchorFrame:ClearAllPoints()
        self.testAnchorFrame:SetPoint(testLA, UIParent, "CENTER", BF:SnapAnchor(testX), BF:SnapAnchor(testY))
        if self.testAnchorFrame.SnapHandle then self.testAnchorFrame.SnapHandle() end
    end

    -- Apply lock state to the real anchor UI.
    -- The test anchor handle is managed by ToggleSetupMode.
    local locked = self.db.global.locked
    if locked == nil then locked = true end
    if not locked then
        self.anchorFrame:EnableMouse(true)
        self.anchorFrame.handle:Show()
    else
        self.anchorFrame:EnableMouse(false)
        self.anchorFrame.handle:Hide()
    end
end

-- ============================================================
-- UNIT FRAME TEST FRAMES
-- Extracted to UnitFrames/SetupMode_UnitFrames.lua
-- ============================================================

-- ============================================================
-- DEBUG: compare real raid frame positions vs setup test frame positions.
-- Usage: /run BuzzardFrames:DebugSetupVsReal()
-- Requires setup mode to be active with a raid flat being modified,
-- AND the matching real raid header to be visible.
-- Prints screen-space coordinates (GetLeft/GetTop/GetRight/GetBottom
-- multiplied by the frame's effective scale, so the numbers are in
-- physical pixels relative to the UIParent origin).
-- ============================================================
function BF:DebugSetupVsReal()
    if not self:IsDebugOutputEnabled() then return end
    local function pxCoords(frame)
        if not frame then return nil end
        local s = frame:GetEffectiveScale()
        local l, b, w, h = frame:GetLeft(), frame:GetBottom(), frame:GetWidth(), frame:GetHeight()
        if not l then return nil end
        return {
            left   = l * s,
            right  = (l + w) * s,
            top    = (b + h) * s,
            bottom = b * s,
            width  = w * s,
            height = h * s,
            scale  = s,
        }
    end

    local function fmt(tag, c)
        if not c then print("  " .. tag .. ": nil"); return end
        print(string.format("  %-16s L=%.3f  R=%.3f  T=%.3f  B=%.3f  W=%.3f  H=%.3f  scale=%.4f",
            tag, c.left, c.right, c.top, c.bottom, c.width, c.height, c.scale))
    end

    print("|cff00ff00===== BF DebugSetupVsReal =====|r")

    -- Setup frames.
    local setupFrames
    if self.testHeader and self.testHeader:IsShown() then
        setupFrames = self.testHeader.frames
    elseif self.partyTestHeader and self.partyTestHeader:IsShown() then
        setupFrames = self.partyTestHeader.frames
    end
    if not setupFrames then
        print("  No visible setup test header.")
    else
        -- Find first and last visible setup frames.
        local firstS, lastS
        for _, f in ipairs(setupFrames) do
            if f and f:IsShown() then
                firstS = firstS or f
                lastS = f
            end
        end
        print("Setup frames:")
        fmt("first", pxCoords(firstS))
        fmt("last",  pxCoords(lastS))
    end

    -- Real frames. Walk groupsUsed, ignore detached/custom/pet headers,
    -- collect first and last child frame.
    local firstR, lastR
    for _, header in ipairs(self.groupsUsed or {}) do
        if not header.isDetached then
            local i = 1
            while true do
                local child = header:GetAttribute("child" .. i)
                if not child then break end
                if child:IsShown() then
                    firstR = firstR or child
                    lastR = child
                end
                i = i + 1
            end
        end
    end
    print("Real frames:")
    fmt("first", pxCoords(firstR))
    fmt("last",  pxCoords(lastR))

    -- Anchors.
    if self.anchorFrame then
        fmt("anchor (real)", pxCoords(self.anchorFrame))
    end
    if self.testAnchorFrame then
        fmt("anchor (test)", pxCoords(self.testAnchorFrame))
    end
    -- Headers.
    if self.testHeader then
        fmt("test header", pxCoords(self.testHeader))
    end
    for _, h in ipairs(self.groupsUsed or {}) do
        if not h.isDetached then
            fmt("real header", pxCoords(h))
            break
        end
    end
    print("|cff00ff00================================|r")
end


-- Perf plan §L5.1 load-time mark: 107 KB (.toc 99-102).
if BuzzardFrames then BuzzardFrames:LoadMark("chunk:setupMode") end
