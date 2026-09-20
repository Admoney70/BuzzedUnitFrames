--[[
BuzzardFrames: Auras/AuraTooltip.lua

Aura-icon tooltip wiring. Defines:

  BF.indicatorPrototype:EnableFrameTooltips(icon, enabled, combatAllowed, position)
      Per-icon tooltip toggle. Installs OnEnter/OnLeave scripts and the
      mouse-propagation flags needed for aura-tooltip-over-unit-tooltip
      precedence. Method on the indicator prototype so every indicator
      can call self:EnableFrameTooltips(...) on its own icons (mirrors
      Grid2's Grid2.indicatorPrototype:EnableFrameTooltips at
      modules/IndicatorTooltip.lua:64).

v67: BF:DispatchTooltipSettings was removed from this file (12.1-only) —
see the note where it used to live, below EnableFrameTooltips.

Source: SetIconTooltip body extracted from Auras/AuraConfig.lua:231-281.
The SafeSetPropagateMouseMotion/Clicks wrappers from the old code are
NOT preserved here — Grid2's analogous EnableFrameTooltips calls bare
SetPropagateMouseMotion/Clicks unconditionally from the exact same
secure-header initialConfigFunction call path BuzzardFrames uses (verified:
Grid2/modules/IndicatorTooltip.lua:68-69 + Grid2/GridFrame.lua:134
calls frame:CreateIndicators from GridFrame_Init which itself runs from
the initialConfigFunction callback). The "SetPropagateMouseMotion is
protected" claim in the old SafeSet* comment block does not match
observed Grid2 behavior in live raids.
]]

local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

local InCombatLockdown = InCombatLockdown
local GetCursorPosition = GetCursorPosition
local GameTooltip = GameTooltip
local UIParent = UIParent
-- NOTE: Do NOT upvalue GameTooltip_SetDefaultAnchor here. Third-party
-- tooltip addons SecureHook the global after addon load; upvaluing the
-- global captures the pre-hook function and bypasses their repositioning.
-- Same rationale as Indicators/Tooltip.lua:13-17.

-- ============================================================
-- OnEnter / OnLeave script closures
--
-- Defined ONCE as file-locals so every EnableFrameTooltips call installs
-- the same function identity. WoW's SetScript de-duplication relies on
-- function-identity comparison; using the same closure across all
-- icons avoids per-icon script-table churn that would happen if we
-- created a fresh closure per call.
-- ============================================================

local function IconOnEnter(self)
    if InCombatLockdown() and not self.SF_TooltipCombatAllowed then return end
    local parent = self:GetParent()
    local unit = parent and parent.unit  -- always current, never stale
    local id = self.auraInstanceID
    if not (unit and id) then return end
    -- Flag the parent so its own OnEnter knows not to show the unit tooltip
    parent.SF_AuraTooltipActive = true
    local pos = self.SF_TooltipPosition
    if pos == "icon" then
        GameTooltip:SetOwner(self, "ANCHOR_NONE")
        local cx, cy = GetCursorPosition()
        local scale = GameTooltip:GetEffectiveScale()
        GameTooltip:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", cx / scale + 12, cy / scale - 12)
    elseif pos == "iconTR" then
        GameTooltip:SetOwner(self, "ANCHOR_CURSOR_RIGHT")
    elseif pos == "frame" then
        GameTooltip:SetOwner(parent, "ANCHOR_BOTTOM")
    else
        GameTooltip_SetDefaultAnchor(GameTooltip, UIParent)
    end
    GameTooltip:SetUnitAuraByAuraInstanceID(unit, id)
    GameTooltip:Show()
end

local function IconOnLeave(self)
    local parent = self:GetParent()
    if parent then parent.SF_AuraTooltipActive = nil end
    GameTooltip:Hide()
end

-- ============================================================
-- BF.indicatorPrototype:EnableFrameTooltips(icon, enabled, combatAllowed, position)
--
-- Method on the indicator prototype. Mirrors Grid2's
-- Grid2.indicatorPrototype:EnableFrameTooltips at
-- modules/IndicatorTooltip.lua:64.
--
-- enabled=true:
--   - Enable mouse, disable click capture
--   - Stop motion propagation to parent (so unit tooltip doesn't fire
--     over the aura tooltip), keep click propagation (so click-casting
--     works normally)
--   - Stamp combat-allowed flag + position-mode on the icon for the
--     OnEnter closure to read
--   - Install OnEnter/OnLeave scripts
--
-- enabled=false:
--   - Disable mouse, clear propagation flags
--   - Clear stamped fields
--   - Remove OnEnter/OnLeave scripts
-- ============================================================
function BF.indicatorPrototype:EnableFrameTooltips(icon, enabled, combatAllowed, position)
    local inCombat = InCombatLockdown()
    if enabled then
        icon:EnableMouse(true)
        icon:SetMouseClickEnabled(false)
        -- SetPropagateMouseMotion/Clicks are #nocombat-restricted (added in
        -- 11.0). Calling them during combat fires ADDON_ACTION_BLOCKED. Skip
        -- in combat; the next out-of-combat refresh (options panel touch,
        -- PLAYER_REGEN_ENABLED-driven refresh) re-runs this function and
        -- applies the flags then.
        if not inCombat then
            icon:SetPropagateMouseMotion(false)
            icon:SetPropagateMouseClicks(true)
        end
        icon.SF_TooltipCombatAllowed = combatAllowed
        icon.SF_TooltipPosition = position or "default"
        icon:SetScript("OnEnter", IconOnEnter)
        icon:SetScript("OnLeave", IconOnLeave)
    else
        icon:EnableMouse(false)
        if not inCombat then
            icon:SetPropagateMouseMotion(false)
            icon:SetPropagateMouseClicks(false)
        end
        icon.SF_TooltipCombatAllowed = nil
        icon.SF_TooltipPosition = nil
        icon:SetScript("OnEnter", nil)
        icon:SetScript("OnLeave", nil)
    end
end

-- ============================================================
-- v67: BF:DispatchTooltipSettings removed (12.1-only).
--
-- It fanned out to UpdateFrameSettings on buffsAndContainers, debuffIcons,
-- bigDefIcons and crowdControlIcons. On 12.1 every one of those four
-- methods had already collapsed to an empty body — container buttons bake
-- their tooltip bindings at creation, so there is no icon pool left to
-- re-walk — which made the whole dispatcher a per-frame no-op inside six
-- scoped-refresh loops in Auras.lua. All four methods and all six call
-- sites went with it.
--
-- EnableFrameTooltips above is UNAFFECTED and still live: it is called
-- directly at button-creation time, not through this dispatcher.
-- ============================================================
