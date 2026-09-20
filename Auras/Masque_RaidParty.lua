-- ============================================================
-- BuzzardFrames: Auras/Masque_RaidParty.lua
-- Optional Masque (button skinning) support for raid/party
-- frame aura icons. Soft dependency: does nothing if Masque
-- is not installed.
--
-- STATUS: DISABLED — Masque applies its own sizing/scaling
-- designed for 36px action buttons, which conflicts with BF's
-- 12-14px raid frame icons. Icons become way too small or too
-- big. Needs investigation into how to pass correct size info
-- to Masque's AddButton, or how to re-assert SetSize after
-- Masque skins the button.
--
-- The SetIconBorderColor wrapper in AuraConfig.lua is in place
-- and ready — once the sizing issue is resolved, uncomment the
-- code below.
-- ============================================================
do return end -- DISABLED: sizing conflict with small raid frame icons. See CLAUDE.md.
local BF  = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")
local MSQ = LibStub("Masque", true)
if not MSQ then return end

-- ============================================================
-- GROUP REGISTRY
-- One Masque group per aura icon type.
-- ============================================================
local groups = {}

local GROUP_NAMES = {
    buffs           = "Raid Buffs",
    debuffs         = "Raid Debuffs",
    bigDef          = "Big Defensive",
    important       = "Important",
    crowdControl    = "Crowd Control",
    missingRaidBuff = "Missing Raid Buff",
}

local function GetOrCreateGroup(iconType)
    if not groups[iconType] then
        local name = GROUP_NAMES[iconType] or iconType
        groups[iconType] = MSQ:Group("Buzzard Frames", name)
    end
    return groups[iconType]
end

-- ============================================================
-- BUTTON DATA
-- Masque expects a table describing which sub-regions to skin.
-- Raid/party aura icons (from CreateAuraIcon) have:
--   icon.Icon     = Texture (ARTWORK)
--   icon.cooldown = Cooldown frame
--   icon.count    = FontString (via countFrame)
-- ============================================================
local function GetButtonData(icon)
    return {
        Icon     = icon.Icon,
        Cooldown = icon.cooldown,
        Count    = icon.count,
        Border   = false,   -- no debuff type border texture
        Normal   = false,   -- no normal texture; Masque creates one
    }
end

-- ============================================================
-- REGISTER ICON WITH MASQUE
-- Called for each icon after CreateAuraIcon. Adds it to the
-- appropriate Masque group and marks it as registered.
-- ============================================================
local function RegisterIcon(icon, iconType)
    if not icon or icon._masqueRegistered then return end
    local group = GetOrCreateGroup(iconType)
    group:AddButton(icon, GetButtonData(icon))
    icon._masqueRegistered = true
end

-- ============================================================
-- BORDER COLOR OVERRIDE
-- Replace the default SetIconBorderColor (which calls
-- SetBackdropBorderColor) with one that routes through
-- Masque's __MSQ_Normal texture when the icon is registered.
-- ============================================================
local origSetIconBorderColor = BF.SetIconBorderColor

local function MasqueSetIconBorderColor(icon, r, g, b, a)
    if icon._masqueRegistered then
        -- Masque creates a Normal texture on skinned buttons.
        -- Color it directly via SetVertexColor.
        local normal = icon.__MSQ_Normal
        if normal then
            normal:SetVertexColor(r, g, b, a)
            return
        end
    end
    -- Fallback: icon not registered with Masque, use backdrop border.
    origSetIconBorderColor(icon, r, g, b, a)
end

-- Override the global wrapper. All files that upvalued
-- BF.SetIconBorderColor at load time got the original function;
-- ScanAndDisplay.lua upvalues it, so we also need to patch the
-- local reference it holds. We do this by replacing the BF table
-- entry AND hooking CreateAuraSlots to register icons.
BF.SetIconBorderColor = MasqueSetIconBorderColor

-- ScanAndDisplay.lua upvalued SetIconBorderColor at load time.
-- That local can't be patched from here. However, ScanAndDisplay
-- loaded BEFORE this file (per .toc order), so we need to ensure
-- the upvalue points to our override. The simplest approach: this
-- file must be loaded AFTER ScanAndDisplay in the .toc so that
-- BF.SetIconBorderColor is already set when ScanAndDisplay upvalues
-- it. But ScanAndDisplay loads before us and already grabbed the
-- original. We solve this by making SetIconBorderColor in
-- AuraConfig.lua do an indirect call through BF.SetIconBorderColor
-- instead of being a direct local.

-- ============================================================
-- HOOK: CreateAuraSlots
-- Register every icon created for a raid/party frame with the
-- appropriate Masque group.
-- ============================================================
if BF.CreateAuraSlots then
    hooksecurefunc(BF, "CreateAuraSlots", function(self, frame)
        if not frame then return end
        if frame.buffFrames then
            for i = 1, #frame.buffFrames do
                RegisterIcon(frame.buffFrames[i], "buffs")
            end
        end
        if frame.debuffFrames then
            for i = 1, #frame.debuffFrames do
                RegisterIcon(frame.debuffFrames[i], "debuffs")
            end
        end
        if frame.bigDefIcons then
            for i = 1, #frame.bigDefIcons do
                RegisterIcon(frame.bigDefIcons[i], "bigDef")
            end
        end
        if frame.importantIcons then
            for i = 1, #frame.importantIcons do
                RegisterIcon(frame.importantIcons[i], "important")
            end
        end
        if frame.crowdControlIcon then
            RegisterIcon(frame.crowdControlIcon, "crowdControl")
        end
        if frame.missingRaidBuffIcon then
            RegisterIcon(frame.missingRaidBuffIcon, "missingRaidBuff")
        end
    end)
end

-- ============================================================
-- HOOK: Container icon creation (CustomAuras.lua)
-- Custom buff container icons are created dynamically in
-- ensureContainerIconPool. Hook the pool creation to register
-- new container icons with Masque.
-- ============================================================
-- Container icons are created inside CustomAuras.lua via a local
-- function. We can't hook it directly, but we can scan for new
-- unregistered icons in the container pools after each
-- UpdateCustomBuffContainers call.
if BF.RenderContainerGroupWithAuras then
    hooksecurefunc(BF, "UpdateStandardAuras", function(self, frame)
        if not frame or not frame.SF_CustomContainerIcons then return end
        for _, pool in pairs(frame.SF_CustomContainerIcons) do
            for _, icon in ipairs(pool) do
                if icon and not icon._masqueRegistered then
                    RegisterIcon(icon, "buffs")
                end
            end
        end
    end)
end
