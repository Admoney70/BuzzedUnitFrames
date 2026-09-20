-- ============================================================
-- BuzzardFrames: oUF_TargetOfTarget.lua
-- Spawns the oUF-based bluzzard target-of-target frame and wires
-- it into the existing BF profile / option system.
-- Requires oUF_Shared.lua to be loaded first.
-- ============================================================
local BF  = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")
local oUF = BF.oUF  -- set by oUF_Shared.lua which is loaded first

-- ── Spawn ─────────────────────────────────────────────────────────────────────

-- v86 (event refactor stage 3): deferred-build listener owner. One owner
-- per feature; the subscription is taken only if the build has to wait for
-- oUF's PLAYER_LOGIN factory queue.
local buildEvents = BF:EventOwner("oufTargetOfTargetBuild")

function BF:BuildOUFTargetOfTargetFrame()
    if self.oufTargetOfTarget then return end
    if not self._oufReady then
        -- v86 (event refactor stage 3): was a private CreateFrame per call.
        -- Every call while _oufReady is false built ANOTHER listener, so a
        -- second build attempt before PLAYER_LOGIN left two frames both
        -- waiting to fire. SubOnce unsubscribes itself on the first fire, and
        -- the IsSubscribed guard makes re-entry a no-op instead of a leak.
        if not buildEvents:IsSubscribed("PLAYER_LOGIN") then
            buildEvents:SubOnce("PLAYER_LOGIN", function() BF:BuildOUFTargetOfTargetFrame() end)
        end
        return
    end

    local p = self.ufDB.profile

    oUF:SetActiveStyle("BuzzardBluzzard")

    local f = oUF:Spawn("targettarget", "BuzzardFrames_oUFTargetOfTarget")
    -- Grid2 pattern: register all mouse buttons so right-click menu works.
    f:RegisterForClicks("AnyUp")
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    -- ── Drag handle ───────────────────────────────────────────────────────────
    BF:_BuildDragHandle(f, "targettarget", "Target of Target")

    -- ── Dragon overlay (elite / rare-elite / worldboss) ───────────────────────
    BF:_BuildOUFDragonOverlay(f, "targettarget", { "PLAYER_TARGET_CHANGED" })

    self.oufTargetOfTarget = f
    self:ApplyOUFTargetOfTargetLayout()
    -- Force an initial update so health/power text and bar colors render
    -- immediately without waiting for the first UNIT_HEALTH/UNIT_POWER event.
    C_Timer.After(0, function()
        if f.UpdateAllElements then f:UpdateAllElements("Manual") end
        if f.UpdateTags        then f:UpdateTags() end
    end)
end

-- ── Layout ────────────────────────────────────────────────────────────────────

function BF:ApplyOUFTargetOfTargetLayout()
    self:_ApplyOUFRightFrameLayout(
        "targettarget", self.oufTargetOfTarget, 1500, 420, "showTargetOfTargetFrame", "targettarget",
        function(f, p, pf)
            BF:_LayoutOUFDragonOverlay(f)
        end
    )
end

-- ── Dragon texture update (uses shared _UpdateOUFDragonOverlay) ───────────────
function BF:_UpdateOUFTargetOfTargetDragon()
    if self.oufTargetOfTarget then self:_UpdateOUFDragonOverlay(self.oufTargetOfTarget) end
end
