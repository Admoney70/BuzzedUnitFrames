-- ============================================================
-- BuzzardFrames: oUF_Masque.lua
-- Optional Masque (button skinning) support for oUF aura icons.
-- Loaded after oUF_Shared.lua. Soft dependency: does nothing if
-- Masque is not installed.
--
-- STATUS: DISABLED — same sizing conflict as Masque_RaidParty.lua.
-- See CLAUDE.md Future Work section.
-- ============================================================
do return end -- DISABLED: sizing conflict with Masque. See CLAUDE.md.
local BF  = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")
local MSQ = LibStub("Masque", true)
if not MSQ then return end

-- ============================================================
-- GROUP REGISTRY
-- One Masque group per (frame-type, aura-type) pair.
-- Groups are created lazily on first use and cached here.
-- ============================================================
local groups = {}

-- Map unit tokens to human-readable group names.
local function GetGroupKey(unit, auraType)
    local base
    if unit == "player"       then base = "Player"
    elseif unit == "target"   then base = "Target"
    elseif unit == "focus"    then base = "Focus"
    elseif unit:match("^boss") then base = "Boss"
    else                           base = unit
    end
    return base .. " " .. auraType
end

local function GetOrCreateGroup(unit, auraType)
    local key = GetGroupKey(unit, auraType)
    if not groups[key] then
        groups[key] = MSQ:Group("Buzzard Frames", key)
    end
    return groups[key]
end

-- ============================================================
-- BUTTON DATA
-- Masque needs a table describing which sub-regions to skin.
-- oUF aura buttons have: Icon, Cooldown, Count, Overlay, Stealable.
-- ============================================================
local function GetButtonData(button)
    return {
        Icon     = button.Icon,
        Cooldown = button.Cooldown,
        Count    = button.Count,
        Border   = button.Overlay,  -- debuff type border
        Normal   = false,           -- no normal texture
    }
end

-- ============================================================
-- HOOK: wrap the existing PostCreateButton on Buffs/Debuffs
-- elements to register each new button with Masque.
-- ============================================================
local function WrapPostCreateButton(element, unit, auraType)
    local group = GetOrCreateGroup(unit, auraType)
    local origCB = element.PostCreateButton

    element.PostCreateButton = function(el, button)
        -- Run the original callback first (font, cooldown settings).
        if origCB then origCB(el, button) end
        -- Register with Masque.
        group:AddButton(button, GetButtonData(button))
    end

    -- Also register any buttons that were already created before
    -- this hook ran (e.g. if oUF pre-created buttons during Spawn).
    for i = 1, (element.createdButtons or 0) do
        local btn = element[i]
        if btn and not btn._masqueRegistered then
            group:AddButton(btn, GetButtonData(btn))
            btn._masqueRegistered = true
        end
    end
end

-- ============================================================
-- INIT: hook the style function so every spawned frame gets
-- Masque integration on its aura elements.
-- ============================================================
local origStyle = BF._bluzzardStyle
if not origStyle then return end

local function MasqueStyle(self, unit)
    -- The original style has already run (we hook AFTER it via
    -- hooksecurefunc on the spawn path). Wrap the callbacks.
    if self.Buffs  then WrapPostCreateButton(self.Buffs,  unit, "Buffs")  end
    if self.Debuffs then WrapPostCreateButton(self.Debuffs, unit, "Debuffs") end
end

-- Hook oUF's Spawn so MasqueStyle runs after BluzzardStyle for each frame.
-- oUF:Spawn calls the registered style function, then returns the frame.
-- We hook the frame's Buffs/Debuffs after the style has set them up.
local oUF = BF.oUF
if oUF and oUF.Spawn then
    hooksecurefunc(oUF, "Spawn", function(_, unitOrHeader, ...)
        -- oUF:Spawn returns the frame, but hooksecurefunc doesn't give
        -- us the return value. Instead, we defer to the next frame so
        -- the frame is fully initialized.
        C_Timer.After(0, function()
            -- Find the frame that was just spawned for this unit.
            -- oUF stores spawned frames; iterate BF's known frame refs.
            local frames = {}
            if BF.oufPlayer then frames[#frames+1] = {BF.oufPlayer, "player"} end
            if BF.oufTarget then frames[#frames+1] = {BF.oufTarget, "target"} end
            if BF.oufFocus  then frames[#frames+1] = {BF.oufFocus,  "focus"}  end
            if BF.oufBoss then
                for i = 1, 5 do
                    if BF.oufBoss[i] then
                        frames[#frames+1] = {BF.oufBoss[i], "boss"..i}
                    end
                end
            end
            if BF.oufPet        then frames[#frames+1] = {BF.oufPet,        "pet"}        end
            if BF.oufToT        then frames[#frames+1] = {BF.oufToT,        "targettarget"} end
            if BF.oufFocusTarget then frames[#frames+1] = {BF.oufFocusTarget,"focustarget"} end

            for _, pair in ipairs(frames) do
                local f, u = pair[1], pair[2]
                if f and not f._masqueHooked then
                    MasqueStyle(f, u)
                    f._masqueHooked = true
                end
            end
        end)
    end)
end
