-- ============================================================
-- BuzzardFrames: oUF_FocusTarget.lua
-- Spawns the oUF-based bluzzard focus-target frame and wires
-- it into the existing BF profile / option system.
-- Requires oUF_Shared.lua to be loaded first.
-- ============================================================
local BF  = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")
local oUF = BF.oUF  -- set by oUF_Shared.lua which is loaded first

-- ── Spawn ─────────────────────────────────────────────────────────────────────

-- v86 (event refactor stage 3): deferred-build listener owner. One owner
-- per feature; the subscription is taken only if the build has to wait for
-- oUF's PLAYER_LOGIN factory queue.
local buildEvents = BF:EventOwner("oufFocusTargetBuild")

function BF:BuildOUFFocusTargetFrame()
    if self.oufFocusTarget then return end
    if not self._oufReady then
        -- v86 (event refactor stage 3): was a private CreateFrame per call.
        -- Every call while _oufReady is false built ANOTHER listener, so a
        -- second build attempt before PLAYER_LOGIN left two frames both
        -- waiting to fire. SubOnce unsubscribes itself on the first fire, and
        -- the IsSubscribed guard makes re-entry a no-op instead of a leak.
        if not buildEvents:IsSubscribed("PLAYER_LOGIN") then
            buildEvents:SubOnce("PLAYER_LOGIN", function() BF:BuildOUFFocusTargetFrame() end)
        end
        return
    end

    local p = self.ufDB.profile

    oUF:SetActiveStyle("BuzzardBluzzard")

    local f = oUF:Spawn("focustarget", "BuzzardFrames_oUFFocusTarget")
    -- Grid2 pattern: register all mouse buttons so right-click menu works.
    f:RegisterForClicks("AnyUp")
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    -- ── Drag handle ───────────────────────────────────────────────────────────
    BF:_BuildDragHandle(f, "focustarget", "Focus Target")

    -- ── Dragon overlay ────────────────────────────────────────────────────────
    BF:_BuildOUFDragonOverlay(f, "focustarget", { "PLAYER_FOCUS_CHANGED", "PLAYER_TARGET_CHANGED" })

    self.oufFocusTarget = f
    self:ApplyOUFFocusTargetLayout()
    C_Timer.After(0, function()
        if f.UpdateAllElements then f:UpdateAllElements("Manual") end
        if f.UpdateTags        then f:UpdateTags() end
    end)
end

-- ── Layout ────────────────────────────────────────────────────────────────────

function BF:ApplyOUFFocusTargetLayout()
    self:_ApplyOUFRightFrameLayout(
        "focustarget", self.oufFocusTarget, 1450, 530, "showFocusTargetFrame", "focustarget",
        function(f, p, pf)
            BF:_LayoutOUFDragonOverlay(f)
        end
    )
end

-- ── Dragon texture update (uses shared _UpdateOUFDragonOverlay) ───────────────
function BF:_UpdateOUFFocusTargetDragon()
    if self.oufFocusTarget then self:_UpdateOUFDragonOverlay(self.oufFocusTarget) end
end

-- ── Forwarders for options callbacks ─────────────────────────────────────────

function BF:LayoutBlizzFocusTargetFrame()
    if self.oufFocusTarget then self:ApplyOUFFocusTargetLayout() end
end

function BF:UpdateBlizzFocusTargetFrame()
    local f = self.oufFocusTarget
    if f then f:UpdateAllElements("Manual") end
end
