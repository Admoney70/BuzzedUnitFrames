-- ============================================================
-- BuzzardFrames: oUF_Target.lua
-- Spawns the oUF-based bluzzard target frame and wires it into
-- the existing BF profile / option system.
-- Requires oUF_Shared.lua to be loaded first.
-- ============================================================
local BF  = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")
local oUF = BF.oUF  -- set by oUF_Shared.lua which is loaded first

-- ── Spawn ─────────────────────────────────────────────────────────────────────

-- v86 (event refactor stage 3): deferred-build listener owner. One owner
-- per feature; the subscription is taken only if the build has to wait for
-- oUF's PLAYER_LOGIN factory queue.
local buildEvents = BF:EventOwner("oufTargetBuild")

function BF:BuildOUFTargetFrame()
    if self.oufTarget then return end
    if not self._oufReady then
        -- v86 (event refactor stage 3): was a private CreateFrame per call.
        -- Every call while _oufReady is false built ANOTHER listener, so a
        -- second build attempt before PLAYER_LOGIN left two frames both
        -- waiting to fire. SubOnce unsubscribes itself on the first fire, and
        -- the IsSubscribed guard makes re-entry a no-op instead of a leak.
        if not buildEvents:IsSubscribed("PLAYER_LOGIN") then
            buildEvents:SubOnce("PLAYER_LOGIN", function() BF:BuildOUFTargetFrame() end)
        end
        return
    end

    local p = self.ufDB.profile

    oUF:SetActiveStyle("BuzzardBluzzard")

    local f = oUF:Spawn("target", "BuzzardFrames_oUFTarget")
    -- Grid2 pattern: register all mouse buttons so right-click menu works.
    f:RegisterForClicks("AnyUp")
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    -- ── Drag handle ───────────────────────────────────────────────────────────
    BF:_BuildDragHandle(f, "target", "Target")

    -- ── Dragon overlay (elite / rare-elite / worldboss) ───────────────────────
    BF:_BuildOUFDragonOverlay(f, "target", { "PLAYER_TARGET_CHANGED" })

    self.oufTarget = f
    self:ApplyOUFTargetLayout()
    -- Force an initial update so health/power text and bar colors render
    -- immediately without waiting for the first UNIT_HEALTH/UNIT_POWER event.
    C_Timer.After(0, function()
        if f.UpdateAllElements then f:UpdateAllElements("Manual") end
        if f.UpdateTags        then f:UpdateTags() end
    end)
end

-- ── Layout ────────────────────────────────────────────────────────────────────

function BF:ApplyOUFTargetLayout()
    self:_ApplyOUFRightFrameLayout(
        "target", self.oufTarget, 1315, 420, "showTargetFrame", "target",
        function(f, p, pf)
            BF:_LayoutOUFDragonOverlay(f)
            -- ── Cast bar layout ──────────────────────────────────────────
            BF:_ApplyOUFTargetCastbarLayout(f, p, pf)
        end
    )
end

-- ── Cast bar layout helper ───────────────────────────────────────────────────
function BF:_ApplyOUFTargetCastbarLayout(f, p, pf)
    BF:_ApplyOUFCastbarLayout(f, p, pf)
end

-- ── Drag handle snap (detached cast bar) ─────────────────────────────────────
function BF:_SnapOUFCastbarHandle(f)
    if not (f and f.Castbar and f.Castbar._handle) then return end
    local handle = f.Castbar._handle
    handle:ClearAllPoints()
    handle:SetPoint("BOTTOMLEFT", f.Castbar, "TOPLEFT", 0, 2)
    handle:SetWidth(f.Castbar:GetWidth())
    handle:SetHeight(14)
end

-- ── Dragon texture update (uses shared _UpdateOUFDragonOverlay) ───────────────
-- Legacy wrapper kept for any external callers.
function BF:_UpdateOUFDragon()
    if self.oufTarget then self:_UpdateOUFDragonOverlay(self.oufTarget) end
end
