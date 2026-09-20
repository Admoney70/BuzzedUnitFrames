-- ============================================================
-- BuzzardFrames: PrivateAuraDispelOverlay.lua
-- Blizzard-native dispel overlay using isContainer=true private
-- aura anchors. Grid2 parity: IndicatorPrivateAurasDispel.lua.
--
-- Separated from PrivateAuras.lua (icon indicator) for clarity.
-- This file MUST load after PrivateAuras.lua (icon indicator
-- registers first) because the cross-indicator public API at the
-- bottom looks up the icon indicator by name.
-- ============================================================

local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")
if not BF then
    error("BuzzardFrames: PrivateAuraDispelOverlay.lua loaded before Core.lua!")
    return
end

local AddPrivateAuraAnchor    = C_UnitAuras.AddPrivateAuraAnchor
local RemovePrivateAuraAnchor = C_UnitAuras.RemovePrivateAuraAnchor
-- GetAuraDataByIndex removed: container visibility now uses Dispel status cache
local C_Timer_After           = C_Timer.After
local wipe                    = wipe
local pairs                   = pairs
local next                    = next
local pcall                   = pcall
local IsInRaid                = IsInRaid

-- Grid2 parity: no combat queue needed. The overlay frame is a
-- plain Frame (not SecureUnitButtonTemplate), so SetAttribute and
-- AddPrivateAuraAnchor work in combat. Grid2's Overlay_Update /
-- Overlay_Layout have no InCombatLockdown guards.

-- 12.0.5+ supports isContainer in AddPrivateAuraAnchor args.
local CLIENT_VERSION = select(4, GetBuildInfo())
local IS_CONTAINER_SUPPORTED = CLIENT_VERSION >= 120005

-- ============================================================
-- DEBUG INSTRUMENTATION
-- ============================================================
local function pd(fmt, ...)
    if not BF._debugPrivateAuras then return end
    local payload = string.format(fmt, ...):gsub("|", "||")
    print("|cff33ff99BF PA Dispel:|r " .. payload)
end

-- ############################################################
-- INDICATOR: privateAuraDispelOverlay
-- Grid2 parity: IndicatorPrivateAurasDispel.lua (current)
-- ############################################################
local DispelIndicator = BF.indicatorPrototype:new("privateAuraDispelOverlay")

-- Cached settings (Grid2 parity: populated by UpdateSettings,
-- read by Layout/Update/UpdateVisibility).
-- v60: _opacity removed — overlay alpha is per-frame now (FrameOverlayOpacity),
-- so a Custom Frame Group's own Overlay Opacity setting applies to its frames.
DispelIndicator._privateAurasOnly = false
DispelIndicator._settingsInitialized = false

-- Dispel overlay gate: frame-type restrictions only (pets have no private
-- auras). Deliberately does NOT consult showPrivateAuras in any form, because
-- the Blizzard dispel overlay is an independent feature from private aura
-- icons — users can enable one without the other.
--
-- v60 BUGFIX: this used to additionally return true for
-- `isCustomFrame and not parentHeader.moduleShowPrivateAuras`, which
-- contradicted the paragraph above: moduleShowPrivateAuras is derived straight
-- from auras.privateAuras.showPrivateAuras (BFLayout.lua), i.e. it IS the
-- private-aura-ICONS setting. Consequences:
--   • On 12.1, where the icon feature is inert and its subtab is hidden, the
--     overlay depended on a setting with no UI.
--   • Pre-12.1, turning a custom frame group's private aura ICONS off also
--     silently killed its dispel overlay.
-- The overlay's own controls live on the Dispellable Debuffs subtab
-- (dispelIndicatorOverlayMode / blizzardDispelShowOverlay), which is where
-- enabling and disabling it belongs.
local function ShouldDisableDispelOverlay(frame)
    local parentHeader = frame:GetParent()
    if parentHeader and parentHeader.isPetFrame then return true end
    return false
end

-- Grid2 parity (Overlay_RemoveFrameAnchor): remove anchor + nil tracking.
-- Matches Grid2's cleanup of bliz_hide state for the unit.
local bliz_hide = {}

local function ClearDispelOverlayAnchor(f)
    if not f then return end
    if f.auraHandle then
        pcall(RemovePrivateAuraAnchor, f.auraHandle)
        bliz_hide[f.auraUnit] = nil
        f.auraHandle = nil
        f.auraUnit   = nil
    end
end

-- ── Frame-scoped settings resolution (v60) ───────────────────
-- The overlay's settings live in the dispelIndicator aura sub-category, and
-- used to be resolved ONCE from the active raid/party flat
-- (GetRaidProfile/GetActivePartyProfile) for every frame. That meant a Custom
-- Frame Group's own Dispellable Debuffs settings never reached its overlay --
-- the group could not enable, disable, recolor or fade it independently, even
-- though the CFG options page exposes exactly those controls.
--
-- Layout and Update are both per-frame, so they now resolve per frame:
-- GetAurasSubcatProfileForFrame honors the frame's CFG flat + that group's
-- per-CFG override flag, the per-Layout flat for RP frames, and the preview
-- flat for preview frames. Cost is a couple of table lookups on a path that
-- runs per layout pass / unit change, never per UNIT_AURA.
local EMPTY_DI = {}
local function FrameDispelProfile(frame)
    return BF:GetAurasSubcatProfileForFrame("dispelIndicator", frame) or EMPTY_DI
end
local function FrameOverlayOpacity(frame)
    return FrameDispelProfile(frame).blizzardDispelOverlayOpacity or 1
end

-- ── Private-auras-only visibility (Grid2: hideNormalDispells) ──
-- Active when Custom mode + showBlizzardPrivateAuraDispel is on.
-- Hides the Blizzard overlay whenever a non-private dispellable
-- debuff is present so BF's own custom highlight handles it.
-- Re-shows the overlay (one-frame delay to avoid visual glitch)
-- when all normal dispellable debuffs clear.
local frames_of_unit = BF.frames_of_unit

local function DispelOverlay_UpdateVisibility(self, event, unit)
    if not unit then return end
    -- Defensive: if the mode changed but the handler wasn't yet
    -- unregistered (timing edge on profile/context switch), bail
    -- out so we don't hide the overlay in blizzard mode.
    if not self._privateAurasOnly then return end
    -- Explicit mode check: never hide the overlay when blizzard native
    -- mode is active. The showBlizzardPrivateAuraDispel toggle is only
    -- hidden in the UI when blizzard mode is enabled — its saved value
    -- can still be true, so _privateAurasOnly alone is not sufficient.
    -- v60: resolved per aura sub-category (the Buffs/Debuffs per-Layout
    -- toggles are independent, so a flat's auras table can carry stale rawkeys
    -- for whichever group is OFF), and via BF:ResolveActiveIsRaid() so this
    -- handler and :Layout can never disagree about which flat to read.
    local activeFlat = BF:ResolveActiveIsRaid() and BF:GetRaidProfile()
                       or BF:GetActivePartyProfile()
    local diP        = BF:GetAurasSubcatProfile("dispelIndicator", activeFlat) or {}
    if diP.dispelIndicatorOverlayMode == "blizzard" then return end
    local dispelStatus = BF.statuses and BF.statuses.dispel
    local hide = dispelStatus and dispelStatus:GetColor(unit, self._containerDispelMode) ~= nil or false
    if hide ~= bliz_hide[unit] then
        local name = self.name
        if hide then
            local bucket = rawget(frames_of_unit, unit)
            if bucket then
                for frame in next, bucket do
                    local f = frame[name]
                    if f then f:SetAlpha(0) end
                end
            end
        else
            C_Timer_After(0, function()
                if bliz_hide[unit] then return end
                local bucket = rawget(frames_of_unit, unit)
                if bucket then
                    for frame in next, bucket do
                        local f = frame[name]
                        -- v60: opacity is per-frame, not one cached value.
                        if f then f:SetAlpha(FrameOverlayOpacity(frame)) end
                    end
                end
            end)
        end
        bliz_hide[unit] = hide
    end
end

-- ── Shared anchor descriptor (Grid2 parity: one table, mutated per call) ─
local dispelAnchorTemplate = {
    auraIndex            = 1,
    isContainer          = true,
    showCountdownFrame   = false,  -- pre-12.1 field name
    showCooldownFrame    = false,  -- 12.1 rename; both passed (each client ignores the unknown key)
    showCountdownNumbers = false,
}

-- ── Overlay_Create (Grid2 Overlay_Create) ────────────────────
-- Grid2 pattern: create the container frame once here via Acquire.
-- The frame is stored at parent[self.name] (standard indicator convention)
-- and reused across Layout/Update calls — never destroyed.
function DispelIndicator:Create(parent)
    local f = parent[self.name]
    if not f then
        f = CreateFrame("Frame", nil, parent)
        f:EnableMouse(false)
        if f.SetMouseClickEnabled then f:SetMouseClickEnabled(false) end
        -- Above frame border and text elements (name/health text at +16),
        -- matching the custom dispel dot (+23). Re-stamped in Layout —
        -- SetParent resets frame levels.
        f:SetFrameLevel(parent:GetFrameLevel() + 23)
        f:Hide()
        parent[self.name] = f
    end
    f.auraHandle = nil
    f.auraUnit   = nil
end

-- ── Overlay_Layout (Grid2 Overlay_Layout) ────────────────────
-- Reconfigures the existing container frame. Does NOT destroy/recreate.
-- Grid2 removes the anchor in Layout so Update re-registers it.
function DispelIndicator:Layout(parent)
    if not parent then return end
    if not IS_CONTAINER_SUPPORTED then return end

    -- v60: per-frame (see FrameDispelProfile) so a Custom Frame Group's own
    -- Dispellable Debuffs settings drive its overlay.
    local diP = FrameDispelProfile(parent)

    local mode = diP.dispelIndicatorOverlayMode
    -- v34: blizzard mode ONLY (custom+showBlizzardPrivateAuraDispel combo
    -- REMOVED — owner decision: one display system or the other).
    local enabled = mode == "blizzard"

    if not enabled or ShouldDisableDispelOverlay(parent) then
        self:Disable(parent)
        return
    end

    local f = parent[self.name]
    if not f then return end

    -- Grid2 parity: remove anchor so Update re-registers.
    ClearDispelOverlayAnchor(f)

    -- Grid2 parity: parent directly to the unit frame, position via
    -- SetAllPoints (no explicit SetSize needed).
    f:SetParent(parent)
    f:ClearAllPoints()
    f:SetAllPoints()
    -- +23: above frame border/highlights and the health-bar stack; the
    -- overlay must render BELOW text and icons (live 12.0 behavior).
    -- 12.0: children follow the host level → +23 < text (+216) ✓.
    -- 12.1: Blizzard_PrivateAurasUI gives the child aura/overlay frames
    -- ABSOLUTE frame levels (125–200 — DispelOverlay hard-coded to 200 in
    -- PrivateAuraAnchorContainerMixin:ReserveAuraFramesForContainer), so
    -- the host level cannot control stacking. That is WHY the whole
    -- text/icon band carries the "+200 native-overlay lift" (+216..+224):
    -- it puts text/icons above 200 while keeping their relative order.
    f:SetFrameLevel(parent:GetFrameLevel() + 23)
    f:SetAlpha(diP.blizzardDispelOverlayOpacity or 1)

    -- Container attributes (Grid2 Overlay_Layout — exact match).
    f:SetAttribute("max-buffs", 0)
    f:SetAttribute("max-debuffs", 0)
    -- Dispel indicator ICONS: honor the show toggle + Max Indicator Icons
    -- setting (previously hardcoded to 1 — the maxIcons setting only ever
    -- drove the preview). 0 = icons off.
    f:SetAttribute("max-dispel-debuffs",
        (diP.blizzardDispelShowIcons ~= false)
            and (diP.dispelIndicatorMaxIcons or 1) or 0)
    f:SetAttribute("ignore-buffs", true)
    f:SetAttribute("ignore-debuffs", true)
    f:SetAttribute("ignore-dispel-debuffs", true)
    -- dispel-indicator-option: BF stores 1 = Dispellable By Me, 2 = All.
    -- 12.1's Blizzard_PrivateAurasUI consumes Enum.RaidDispelDisplayType;
    -- the raw 1/2 fallback stays as a defensive path if the enum is absent.
    -- v67: 12.0.7 branch removed (addon is 12.1-only).
    local optMode = diP.blizzardDispelOverlayMode or 2
    if Enum.RaidDispelDisplayType then
        f:SetAttribute("dispel-indicator-option", optMode == 1
            and Enum.RaidDispelDisplayType.DispellableByMe
            or Enum.RaidDispelDisplayType.DisplayAll)
    else
        f:SetAttribute("dispel-indicator-option", optMode)
    end
    f:SetAttribute("show-dispel-indicator-overlay", true)  -- pre-12.1 attribute; UNREAD on 12.1
    -- 12.1 overlay contract (PTR-confirmed: the boolean above is gone —
    -- without dispel-indicator-overlay-type the overlay renders hidden):
    -- overlay color mode (UseDebuffColor/UseBlack) + pulse animation.
    -- Overlay show toggle: nil overlay-type = hidden (GetDispelOverlayColor
    -- returns nil → all overlay textures alpha 0). NOTE: the overlay's
    -- border edge is part of the same template element as the gradient —
    -- it cannot be toggled separately from the overlay.
    local ovType
    if diP.blizzardDispelShowOverlay ~= false then
        if diP.blizzardDispelOverlayColorMode == "black" then
            ovType = Enum.RaidDispelOverlayType and Enum.RaidDispelOverlayType.UseBlack
        else
            ovType = Enum.RaidDispelOverlayType and Enum.RaidDispelOverlayType.UseDebuffColor
        end
    end
    f:SetAttribute("dispel-indicator-overlay-type", ovType)  -- nil clears on toggle-off
    f:SetAttribute("dispel-indicator-overlay-animation", diP.blizzardDispelOverlayFlash == true)
    f:SetAttribute("always-hide-duration", true)
    f:SetAttribute("set-aura-size-to-icon-size", true)
    f:SetAttribute("suppress-dispel-border-icons", false)
    f:SetAttribute("icon-size", 12)
    f:SetAttribute("power-bar-used-height", 0)
    -- Icon + overlay position: Blizzard's three fixed layout presets
    -- (each bundles the dispel-icon corner WITH the overlay gradient
    -- orientation — no free offsets exist in the secure layout tables).
    local ORG = Enum.RaidAuraOrganizationType
    local orgSetting = diP.blizzardDispelOrgType
    local orgType
    if orgSetting == "bottomLeft" then
        orgType = ORG and ORG.BuffsTopDebuffsBottom or 1
    elseif orgSetting == "topLeft" then
        orgType = ORG and ORG.BuffsRightDebuffsLeft or 2
    else
        orgType = ORG and ORG.Legacy or 0  -- "topRight" (default)
    end
    f:SetAttribute("aura-organization-type", orgType)

    f:Show()
end

-- ── Overlay_Update (Grid2 Overlay_Update) ────────────────────
-- Anchors-only: register/remove the isContainer anchor on unit change.
-- Grid2 parity: NO InCombatLockdown guard. The overlay frame is a
-- plain Frame (not SecureUnitButtonTemplate), so SetAttribute is not
-- restricted. The previous combat guard caused stale anchors when
-- roster shuffles happened mid-combat, showing the overlay on the
-- wrong unit. Grid2's Overlay_Update has no combat guard either —
-- it just pcalls AddPrivateAuraAnchor and accepts the error.
function DispelIndicator:Update(parent, unit)
    if not parent or not unit then return end
    if not IS_CONTAINER_SUPPORTED then return end

    -- Lazy init: UpdateSettings reads profile data to cache
    -- _containerDispelMode and register the UNIT_AURA handler.
    -- The first Update call arrives before RefreshAllAuras (which
    -- runs in a deferred C_Timer.After(0)), so prime settings here.
    if not self._settingsInitialized then
        self:UpdateSettings()
    end

    -- Check gates. v60: per-frame, as in :Layout.
    local diP = FrameDispelProfile(parent)
    local mode = diP.dispelIndicatorOverlayMode
    -- v34: blizzard mode ONLY (custom+showBlizzardPrivateAuraDispel combo
    -- REMOVED — owner decision: one display system or the other).
    local enabled = mode == "blizzard"

    if not enabled or ShouldDisableDispelOverlay(parent) then
        self:Disable(parent)
        return
    end

    local f = parent[self.name]
    if not f then return end

    -- Ensure Layout has run at least once before we add the anchor.
    if not f:IsShown() then
        self:Layout(parent)
        f = parent[self.name]
        if not f or not f:IsShown() then return end
    end

    -- Grid2 parity: only re-register on unit change.
    if f.auraUnit == unit then return end

    -- Switching units: remove old anchor before re-registering.
    ClearDispelOverlayAnchor(f)

    -- Grid2 parity: skip pets. ShouldDisableDispelOverlay already
    -- gates on isPetFrame, but guard the anchor call too.
    local parentHeader = parent:GetParent()
    local anchored = false
    if not (parentHeader and parentHeader.isPetFrame) then
        dispelAnchorTemplate.parent    = f
        dispelAnchorTemplate.unitToken = unit
        f:SetAttribute("group-type", unit:find("party") and 4 or 5)
        f:SetAttribute("update-settings", true)
        local ok, handle = pcall(function() return AddPrivateAuraAnchor(dispelAnchorTemplate) end)
        if ok then
            f.auraHandle = handle
            anchored = true
        else
            pd("Error AddPrivateAuraAnchor (dispel): %s", tostring(handle))
        end
        dispelAnchorTemplate.parent    = nil
        dispelAnchorTemplate.unitToken = nil
    else
        anchored = true  -- pets never anchor; nothing to retry
    end
    -- v64 LOGIN FIX: latch auraUnit only on SUCCESS. A failed
    -- AddPrivateAuraAnchor (early-login timing) used to latch anyway,
    -- and the `f.auraUnit == unit` early-out then suppressed every
    -- retry until a settings change forced a full re-Layout — the
    -- "overlay dead until I touch settings" symptom. Grid2 latches
    -- unconditionally (same latent bug); deviation deliberate.
    if anchored then
        f.auraUnit = unit
    end
end

-- ── Overlay_Disable (Grid2 Overlay_Disable) ──────────────────
function DispelIndicator:Disable(parent)
    if not parent then return end
    local f = parent[self.name]
    if not f then return end
    ClearDispelOverlayAnchor(f)
    f:Hide()
    f:SetParent(nil)
    f:ClearAllPoints()
end

function DispelIndicator:GetFrame(parent)
    return parent[self.name]
end

-- ── UpdateSettings (Grid2 Overlay_UpdateDB) ──────────────────
-- Reads profile settings and caches them on the indicator object.
-- Registers/unregisters the UNIT_AURA handler for the
-- private-auras-only visibility feature.
function DispelIndicator:UpdateSettings()
    -- Indicator-wide settings only. v60: self._opacity is GONE -- overlay
    -- alpha is resolved per frame at Layout time (FrameOverlayOpacity), so a
    -- Custom Frame Group can have its own. What remains here is
    -- _containerDispelMode, consumed solely by the dormant
    -- DispelOverlay_UpdateVisibility handler below, which is genuinely
    -- indicator-wide because it drives a single UNIT_AURA registration.
    -- BF:ResolveActiveIsRaid() rather than a bare IsInRaid(), so
    -- _containerDispelMode below cannot come from the raid flat while :Layout
    -- reads the party flat for the same frames.
    local activeFlat = BF:ResolveActiveIsRaid() and BF:GetRaidProfile()
                       or BF:GetActivePartyProfile()
    local diP        = BF:GetAurasSubcatProfile("dispelIndicator", activeFlat) or {}

    self._settingsInitialized = true

    -- Map the Blizzard container's dispel mode (1=dispellableByMe,
    -- 2=any dispellable) to the Dispel status mode string so the
    -- visibility handler can reuse the existing dispel cache.
    local containerMode = diP.blizzardDispelOverlayMode or 2
    self._containerDispelMode = containerMode == 1 and "dispellable" or "allDispellable"

    -- privateAurasOnly: PERMANENTLY false (v34). It gated the
    -- hide-normal-dispels handler for the custom+showBlizzardPrivateAuraDispel
    -- combo, which was REMOVED (owner decision: the Blizzard private-aura
    -- display is exclusive to blizzard mode). The handler also hard-errored
    -- on 12.1 secret aura reads before it was gated. The machinery is
    -- retained dormant for the post-12.1 cleanup pass.
    self._privateAurasOnly = false

    if self._privateAurasOnly then
        BF.RegisterRosterUnitEvent(self, "UNIT_AURA", DispelOverlay_UpdateVisibility)
    else
        BF.UnregisterRosterUnitEvent(self, "UNIT_AURA")
        -- Clear any hidden states so overlays restore to configured opacity.
        if next(bliz_hide) then
            wipe(bliz_hide)
            if BF.activeFrames then
                for frame in pairs(BF.activeFrames) do
                    local f = frame[self.name]
                    if f and f:IsShown() then
                        f:SetAlpha(FrameOverlayOpacity(frame))
                    end
                end
            end
        end
    end
end

-- Register the dispel overlay indicator.
BF:RegisterIndicator(DispelIndicator)


-- ############################################################
-- PUBLIC API (dispel overlay only)
-- ############################################################

function BF:DisablePrivateAuraDispelOverlay(frame)
    if not frame then return end
    DispelIndicator:Disable(frame)
end

function BF:UpdatePrivateAuraDispelOverlay(frame)
    if not frame or not frame.unit then return end
    DispelIndicator:Layout(frame)
    DispelIndicator:Update(frame, frame.unit)
end

function BF:RegisterPrivateAuraDispelOverlayOnly(frame)
    if not frame or not frame.unit then return end
    DispelIndicator:Update(frame, frame.unit)
end

function BF:RefreshAllPrivateAuraDispelOverlays()
    DispelIndicator:UpdateSettings()
    if not self.activeFrames then return end
    for frame in pairs(self.activeFrames) do
        if frame and frame.unit then
            DispelIndicator:Layout(frame)
            DispelIndicator:Update(frame, frame.unit)
        end
    end
end


-- Grid2 parity: no post-combat flush needed — Layout/Update work in combat.
