-- ============================================================
-- BuzzardFrames: oUF_Pet.lua
-- Spawns the oUF-based bluzzard pet frame and wires it into
-- the existing BF profile / option system.
-- All shared layout logic lives in _ApplyOUFRightFrameLayout (oUF_Shared.lua).
-- Requires oUF_Shared.lua to be loaded first.
-- ============================================================
local BF  = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")
local oUF = BF.oUF  -- set by oUF_Shared.lua

-- ── Spawn ─────────────────────────────────────────────────────────────────────

-- v86 (event refactor stage 3): deferred-build listener owner. One owner
-- per feature; the subscription is taken only if the build has to wait for
-- oUF's PLAYER_LOGIN factory queue.
local buildEvents = BF:EventOwner("oufPetBuild")

function BF:BuildOUFPetFrame()
    if self.oufPet then return end
    if not self._oufReady then
        -- v86 (event refactor stage 3): was a private CreateFrame per call.
        -- Every call while _oufReady is false built ANOTHER listener, so a
        -- second build attempt before PLAYER_LOGIN left two frames both
        -- waiting to fire. SubOnce unsubscribes itself on the first fire, and
        -- the IsSubscribed guard makes re-entry a no-op instead of a leak.
        if not buildEvents:IsSubscribed("PLAYER_LOGIN") then
            buildEvents:SubOnce("PLAYER_LOGIN", function() BF:BuildOUFPetFrame() end)
        end
        return
    end

    oUF:SetActiveStyle("BuzzardBluzzard")

    local f = oUF:Spawn("pet", "BuzzardFrames_oUFPet")
    -- Grid2 pattern: register all mouse buttons so right-click menu works.
    f:RegisterForClicks("AnyUp")
    f:SetParent(UIParent)
    f:SetFrameStrata("MEDIUM")
    f:SetFrameLevel(50)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    -- ── Drag handle ───────────────────────────────────────────────────────────
    BF:_BuildDragHandle(f, "pet", "Pet")

    self.oufPet = f
    self:ApplyOUFPetLayout()

    -- Force an initial update so health/power text and bar colors render
    -- immediately without waiting for the first UNIT_HEALTH/UNIT_POWER event.
    C_Timer.After(0, function()
        if f.UpdateAllElements then f:UpdateAllElements("Manual") end
        if f.UpdateTags        then f:UpdateTags() end
    end)
end

-- ── Layout ────────────────────────────────────────────────────────────────────

function BF:ApplyOUFPetLayout()
    self:_ApplyOUFRightFrameLayout(
        "pet", self.oufPet, 690, 370, "showPetFrame", "pet"
    )
end

-- ── Forwarders for options callbacks ─────────────────────────────────────────

function BF:LayoutBlizzPetFrame()
    if self.oufPet then self:ApplyOUFPetLayout() end
end

function BF:UpdateBlizzPetFrame()
    local f = self.oufPet
    if f then f:UpdateAllElements("Manual") end
end
