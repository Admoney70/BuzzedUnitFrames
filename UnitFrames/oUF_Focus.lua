-- ============================================================
-- BuzzardFrames: oUF_Focus.lua
-- Spawns the oUF-based bluzzard focus frame and wires it into
-- the existing BF profile / option system.
-- Requires oUF_Shared.lua to be loaded first.
-- ============================================================
local BF  = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")
local oUF = BF.oUF  -- set by oUF_Shared.lua which is loaded first

-- ── Spawn ─────────────────────────────────────────────────────────────────────

-- v86 (event refactor stage 3): deferred-build listener owner. One owner
-- per feature; the subscription is taken only if the build has to wait for
-- oUF's PLAYER_LOGIN factory queue.
local buildEvents = BF:EventOwner("oufFocusBuild")

function BF:BuildOUFFocusFrame()
    if self.oufFocus then return end
    if not self._oufReady then
        -- v86 (event refactor stage 3): was a private CreateFrame per call.
        -- Every call while _oufReady is false built ANOTHER listener, so a
        -- second build attempt before PLAYER_LOGIN left two frames both
        -- waiting to fire. SubOnce unsubscribes itself on the first fire, and
        -- the IsSubscribed guard makes re-entry a no-op instead of a leak.
        if not buildEvents:IsSubscribed("PLAYER_LOGIN") then
            buildEvents:SubOnce("PLAYER_LOGIN", function() BF:BuildOUFFocusFrame() end)
        end
        return
    end

    oUF:SetActiveStyle("BuzzardBluzzard")

    local f = oUF:Spawn("focus", "BuzzardFrames_oUFFocus")
    -- Grid2 pattern: register all mouse buttons so right-click menu works.
    f:RegisterForClicks("AnyUp")
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    BF:_BuildDragHandle(f, "focus", "Focus")

    -- ── Dragon overlay ────────────────────────────────────────────────────────
    BF:_BuildOUFDragonOverlay(f, "focus", { "PLAYER_FOCUS_CHANGED" })

    self.oufFocus = f
    self:ApplyOUFFocusLayout()
    C_Timer.After(0, function()
        if f.UpdateAllElements then f:UpdateAllElements("Manual") end
        if f.UpdateTags        then f:UpdateTags() end
    end)
end

-- ── Layout ────────────────────────────────────────────────────────────────────

function BF:ApplyOUFFocusLayout()
    self:_ApplyOUFRightFrameLayout(
        "focus", self.oufFocus, 1340, 530, "showFocusFrame", "focus",
        function(f, p, pf)
            BF:_LayoutOUFDragonOverlay(f)
            BF:_ApplyOUFFocusCastbarLayout(f, p, pf)
        end
    )
end

-- ── Cast bar layout helper ───────────────────────────────────────────────────
function BF:_ApplyOUFFocusCastbarLayout(f, p, pf)
    BF:_ApplyOUFCastbarLayout(f, p, pf)
end

-- ── Drag handle snap (detached cast bar) ─────────────────────────────────────
-- _SnapOUFCastbarHandle is defined in oUF_Target.lua and already operates on
-- any frame generically (it takes f, not a hardcoded unit), so it also serves
-- the focus cast bar without modification.
