-- ============================================================
-- BuzzardFrames: UnlockMode.lua
-- Handle visibility for unlocked frame dragging.
-- Single source of truth: RefreshHandleVisibility determines
-- whether handles are shown or hidden based on lock state and
-- setup mode state.
-- ============================================================
local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

-- ============================================================
-- HELPER: Is setup mode currently active?
-- Reads the single setupModeActive flag. Replaces the old four-flag OR.
-- ============================================================
function BF:IsSetupModeActive()
    return self.db and self.db.global and self.db.global.setupModeActive == true
end

-- ============================================================
-- ApplyTinyHandle
-- Apply or remove tiny-handle mode on all draggable handles.
-- Tiny = 5x5 px, no label text. Normal = original sizes with label.
-- ============================================================
function BF:ApplyTinyHandle()
    local tiny = self.db and self.db.profile and self.db.global.tinyHandle

    local function resize(handle, normalW, normalH, labelText)
        if not handle then return end
        if tiny then
            handle:SetSize(5, 5)
            handle:SetHitRectInsets(-10, -10, -10, 0)
            if handle.SetBackdropColor then
                handle:SetBackdropColor(0.1, 0.3, 0.6, 0.2)
                handle:SetBackdropBorderColor(0.2, 0.5, 0.9, 0.2)
            end
            for i = 1, select("#", handle:GetRegions()) do
                local region = select(i, handle:GetRegions())
                if region and region.GetObjectType and region:GetObjectType() == "FontString" then
                    region:Hide()
                end
            end
        else
            handle:SetSize(normalW, normalH)
            handle:SetHitRectInsets(0, 0, 0, 0)
            if handle.SetBackdropColor then
                handle:SetBackdropColor(0.1, 0.3, 0.6, 0.8)
                handle:SetBackdropBorderColor(0.2, 0.5, 0.9, 1)
            end
            for i = 1, select("#", handle:GetRegions()) do
                local region = select(i, handle:GetRegions())
                if region and region.GetObjectType and region:GetObjectType() == "FontString" then
                    region:Show()
                    if labelText then region:SetText(labelText) end
                end
            end
        end
    end

    -- Real anchor handle
    if self.anchorFrame and self.anchorFrame.handle then
        resize(self.anchorFrame.handle, 200, 16, "BuzzardFrames")
    end
    -- Test anchor handle: never apply tiny mode — setup mode handles should
    -- always remain full-size for easy visibility and dragging.
    if not tiny and self.testAnchorFrame and self.testAnchorFrame.handle then
        resize(self.testAnchorFrame.handle, 200, 16, "BuzzardFrames [Setup]")
    end
    -- Unit frame handles (oUF frames)
    local function resizeUF(f)
        if f and f._handle then resize(f._handle, 200, 16, nil) end
    end
    resizeUF(self.oufPlayer)
    resizeUF(self.oufTarget)
    resizeUF(self.oufFocus)
    resizeUF(self.oufPet)
    resizeUF(self.oufTargetOfTarget)
    resizeUF(self.oufFocusTarget)
    if self.oufBoss then resizeUF(self.oufBoss[1]) end
    -- Cast bar and resource bar handles
    local function resizeCastbar(f)
        if f and f.Castbar and f.Castbar._handle then
            resize(f.Castbar._handle, 200, 16, nil)
        end
    end
    resizeCastbar(self.oufTarget)
    resizeCastbar(self.oufFocus)
    if self.oufResourceBar and self.oufResourceBar._handle then
        resize(self.oufResourceBar._handle, 200, 16, nil)
    end
    if self.oufDetachedPowerBar and self.oufDetachedPowerBar._handle then
        resize(self.oufDetachedPowerBar._handle, 200, 16, nil)
    end
    if self.oufAltPowerBar and self.oufAltPowerBar._handle then
        resize(self.oufAltPowerBar._handle, 200, 16, nil)
    end

    -- Incoming casts player anchor handle
    if self.IncomingCasts and self.IncomingCasts._playerAnchor then
        local icAnchor = self.IncomingCasts._playerAnchor
        if icAnchor._handle then
            resize(icAnchor._handle, 200, 14, "Incoming Casts")
            if not tiny and icAnchor._handle:IsShown() and icAnchor.SnapHandle then
                icAnchor.SnapHandle()
            end
        end
    end

    -- Custom frame group detached header handles
    if self.groupsUsed then
        for _, header in ipairs(self.groupsUsed) do
            if header.isDetached and header._handle then
                if self.ApplyTinyHandleToDetachedHeader then
                    self:ApplyTinyHandleToDetachedHeader(header)
                end
            end
        end
    end
end

-- ============================================================
-- RefreshHandleVisibility
-- Single source of truth for handle visibility. Reads current
-- lock state and setup mode state. Never changes lock state.
-- ============================================================
function BF:RefreshHandleVisibility()
    local p  = self.db.profile
    local up = self.ufDB.profile  -- UF keys (oufResourceBarDetached, oufPowerBarDetached, altPowerBarDetached, *CastBar*) live here
    local locked = self.db.global.locked
    if locked == nil then locked = true end
    local inSetupMode = self:IsSetupModeActive()

    -- If setup mode is active OR frames are locked, hide all handles.
    local shouldHide = locked or inSetupMode

    -- Raid/party anchor handle
    if self.anchorFrame then
        if shouldHide then
            self.anchorFrame:EnableMouse(false)
            self.anchorFrame.handle:Hide()
        else
            self.anchorFrame:EnableMouse(true)
            self.anchorFrame.handle:Show()
        end
    end

    -- oUF unit frame handles
    local function setUFHandle(f)
        if not f or not f._handle then return end
        if shouldHide then
            f:SetMovable(false)
            f._handle:Hide()
        else
            f:SetMovable(true)
            f._handle:Show()
            if f._anchor and f._anchor.SnapHandle then
                f._anchor.SnapHandle()
            end
        end
    end
    setUFHandle(self.oufPlayer)
    setUFHandle(self.oufTarget)
    setUFHandle(self.oufFocus)
    setUFHandle(self.oufPet)
    setUFHandle(self.oufTargetOfTarget)
    setUFHandle(self.oufFocusTarget)
    if self.oufBoss then setUFHandle(self.oufBoss[1]) end

    -- Castbar handles (only shown when detached and unlocked)
    local function updateCastbarHandle(f, unitKey)
        if not (f and f.Castbar and f.Castbar._handle) then return end
        local detached = up[unitKey .. "CastBarDetached"] == true
        local cbShown  = up[unitKey .. "ShowCastBar"] ~= false
        if cbShown and detached and not shouldHide then
            f.Castbar._handle:Show()
            self:_SnapOUFCastbarHandle(f)
        else
            f.Castbar._handle:Hide()
        end
    end
    updateCastbarHandle(self.oufTarget, "target")
    updateCastbarHandle(self.oufFocus,  "focus")

    -- Resource bar handle (only shown when detached and unlocked)
    local rb = self.oufResourceBar
    if rb and rb._handle then
        local detached = (up.oufResourceBarDetached == true) or (not self.oufPlayer)
        local enabled  = up.oufResourceBarEnabled == true
        if enabled and detached and not shouldHide then
            rb._handle:Show()
            self:_SnapOUFResourceBarHandle()
        else
            rb._handle:Hide()
        end
    end

    -- Detached power bar handle
    local dpb = self.oufDetachedPowerBar
    if dpb and dpb._handle then
        if up.oufPowerBarDetached == true and not shouldHide then
            dpb._handle:Show()
            self:_SnapOUFDetachedPowerBarHandle()
        else
            dpb._handle:Hide()
        end
    end

    -- Detached alt power bar handle
    local dmb = self.oufAltPowerBar
    if dmb and dmb._handle then
        if up.altPowerBarDetached == true and not shouldHide then
            dmb._handle:Show()
            self:_SnapOUFAltPowerBarHandle()
        else
            dmb._handle:Hide()
        end
    end

    -- Incoming casts player mover handle
    if self.IncomingCasts then
        -- icDB, NOT p.modules.incomingCasts. The keys moved into the
        -- IncomingCasts namespace in dbVersion 16; this was the last reader
        -- left on the pre-migration path, so the condition was always false
        -- and the mover handle never appeared in Unlock mode.
        local ic = self.icDB and self.icDB.profile
        if ic and ic.incomingCastsEnabled and ic.incomingCastsShowOnPlayerFrame and not shouldHide then
            self.IncomingCasts:ShowPlayerMover()
        else
            self.IncomingCasts:HidePlayerMover()
        end
    end

    -- Custom frame group detached header handles
    if self.groupsUsed then
        for _, header in ipairs(self.groupsUsed) do
            if header.isDetached and header._handle then
                if shouldHide then
                    header._handle:Hide()
                else
                    header._handle:Show()
                    if header._handle.SnapToParent then header._handle.SnapToParent() end
                end
            end
        end
    end

    -- Re-apply tiny handle appearance after showing handles
    if not shouldHide and BF.db.global.tinyHandle then
        self:ApplyTinyHandle()
    end
end

-- ============================================================
-- SetLocked
-- Changes the lock state and refreshes handle visibility.
-- ============================================================
function BF:SetLocked(locked)
    self.db.global.locked = locked
    self:RefreshHandleVisibility()
end
