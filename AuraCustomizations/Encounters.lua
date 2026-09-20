-- ============================================================
-- BuzzardFrames: Encounters.lua
-- Encounter definitions and private aura border suppression.
--
-- SUBZONE-BASED APPROACH (Blizzard 12.1+):
-- AddPrivateAuraAnchor / RemovePrivateAuraAnchor are combat-restricted.
-- Anchor registration happens on ZONE_CHANGED / ZONE_CHANGED_INDOORS when
-- the player walks into a boss subzone before the pull.
-- ENCOUNTER_END clears overrides and re-registers anchors after the fight.
-- PLAYER_REGEN_ENABLED flushes any deferred anchor work after combat.
-- ============================================================
local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

-- ============================================================
-- ENCOUNTER LIST
-- { id = encounterID, name = "Display Name" }
-- The per-encounter Private Aura Customization UI is built in
-- Options/Options_CustomAuras.lua (encounter tabs section).
-- ============================================================
BF.Encounters = {
    { id = 3306, name = "Chimaerus the Undreamt God" },
    { id = 3176, name = "Imperator Averzian" },
    { id = 3177, name = "Vorasius" },
    { id = 3178, name = "Vaelgor & Ezzorak, Lightblinded Vanguard" },
    { id = 3179, name = "Fallen-King Salhadaar" },
    { id = 3180, name = "Lightblinded Vanguard" },
    { id = 3181, name = "Crown of the Cosmos" },
    { id = 3182, name = "Belo'ren, Child of Al'ar" },
    { id = 3183, name = "Midnight Falls" },
}

-- ============================================================
-- SUBZONE NAME → ENCOUNTER MAP
-- GetSubZoneText() → encounterID
-- More reliable than map area IDs, which can be shared across
-- multiple rooms. Add rows as you collect subzone names.
-- ============================================================
local SUBZONE_NAME_TO_ENCOUNTER = {
    ["Den of the Undreamt"] = 3306,  -- Chimaerus the Undreamt God
    ["The Approach"]       = 3176,  -- Imperator Averzian
    ["Behemoth's Rise"]     = 3177,  -- Vorasius
    ["The Voidspire"]       = 3178,  -- Vaelgor & Ezzorak + Lightblinded Vanguard (shared subzone, shared settings)
    ["The Riftlabs"]       = 3179,  -- Fallen-King Salhadaar
    -- ["???"]               = 3181,  -- Crown of the Cosmos
    -- ["???"]               = 3182,  -- Belo'ren, Child of Al'ar
    -- ["???"]               = 3183,  -- Midnight Falls
}

BF.SUBZONE_NAME_TO_ENCOUNTER = SUBZONE_NAME_TO_ENCOUNTER

-- ============================================================
-- ENCOUNTER EVENT HANDLER
-- ============================================================
do
    local f = CreateFrame("Frame")
    f:RegisterEvent("ENCOUNTER_END")
    f:RegisterEvent("PLAYER_ENTERING_WORLD")
    f:RegisterEvent("PLAYER_REGEN_ENABLED")
    f:RegisterEvent("ZONE_CHANGED")
    f:RegisterEvent("ZONE_CHANGED_INDOORS")

    -- Killswitch query: when off, every function in this file is a no-op.
    -- Customizations are the ONLY thing this file produces -- there is no
    -- icon-path interaction here at all.
    --
    -- TEMPORARILY HARDCODED to false while debugging a frame-level rendering
    -- bug. To restore: change to
    --   return BF.acDB and BF.acDB.profile and BF.acDB.profile.enablePrivateAuraCustomizations == true
    local function customizationsEnabled()
        return false
    end

    -- Track whether we have deferred anchor work to flush after combat.
    local pendingAnchorApply = nil  -- encounterID or false (clear)

    -- ----------------------------------------------------------------
    -- setSoftOverrides: sets per-frame Lua table flags only.
    -- Safe to call in combat — no anchor API calls.
    -- ----------------------------------------------------------------
    local function setSoftOverrides(encID)
        if not customizationsEnabled() then return end
        local p = BF and BF.db and BF.db.profile
    local acp = BF.acDB and BF.acDB.profile
        if not p or not BF.activeFrames then return end

        local encProfile = encID and acp.encounterPASettings and acp.encounterPASettings[encID]

        for frame in pairs(BF.activeFrames) do
            if frame and frame.unit then
                if encProfile then
                    frame.SF_EncounterBorderOverride = {
                        showBorder          = encProfile.showBorder,
                        hideFirstSlotBorder = encProfile.hideFirstSlotBorder,
                        drawOrder           = encProfile.drawOrder,
                    }
                    frame.SF_EncounterIconOverride = {
                        hideIcon            = encProfile.hideIcon,
                        hiddenAuraIndices   = encProfile.hiddenAuraIndices,
                        -- Legacy compat
                        hideFirstAuraSlot   = encProfile.hideFirstAuraSlot,
                    }
                else
                    frame.SF_EncounterBorderOverride = nil
                    frame.SF_EncounterIconOverride   = nil
                end
            end
        end
    end

    -- ----------------------------------------------------------------
    -- applyAnchors: re-registers private aura anchors on all frames.
    -- MUST be called out of combat (AddPrivateAuraAnchor / RemovePrivateAuraAnchor
    -- are combat-restricted in 12.1+).
    -- ----------------------------------------------------------------
    local function applyAnchors(encID)
        if not customizationsEnabled() then return end
        if InCombatLockdown() then
            pendingAnchorApply = encID or false
            return
        end
        pendingAnchorApply = nil

        local p = BF and BF.db and BF.db.profile
    local acp = BF.acDB and BF.acDB.profile
        if not p or not BF.activeFrames then return end

        for frame in pairs(BF.activeFrames) do
            if frame and frame.unit then
                frame.SF_PrivateAuraUnit       = nil
                frame.SF_PrivateAuraBorderUnit = nil
                -- TEMPORARILY DISABLED: customization-side calls commented out
                -- while debugging a frame-level rendering bug. Icon path still runs.
                --
                -- Apply override fields BEFORE the icon path so the icon
                -- layout sees the fresh encounter override. Without this,
                -- the icon path would read stale SF_PrivateAuraIndexMap.
                -- if BF.ApplyPrivateAuraOverrideFields then
                --     BF:ApplyPrivateAuraOverrideFields(frame)
                -- end
                if BF.UpdatePrivateAuraAnchor then
                    BF:UpdatePrivateAuraAnchor(frame)
                end
                -- Customization entry points (each gates internally on the
                -- killswitch and reads from frame.SF_EncounterIconOverride /
                -- SF_EncounterBorderOverride).
                -- if BF.UpdatePrivateAuraOverlay then
                --     BF:UpdatePrivateAuraOverlay(frame)
                -- end
                -- if BF.UpdatePrivateAuraFrameBorder then
                --     BF:UpdatePrivateAuraFrameBorder(frame)
                -- end
                -- NOTE: Blizzard dispel overlay rebind is handled inside
                -- BF:UpdatePrivateAuraAnchor above. It is NOT a customization.
            end
        end
    end

    -- ----------------------------------------------------------------
    -- Full apply: soft overrides + anchors. Used by subzone trigger
    -- and post-combat flush.
    -- ----------------------------------------------------------------
    local function applyEncounterOverrides(encID)
        setSoftOverrides(encID)
        applyAnchors(encID)
    end

    -- ----------------------------------------------------------------
    -- Subzone check: resolve current subzone to an encounter ID.
    -- Returns the encounter ID if in a boss room, nil otherwise.
    -- Uses GetSubZoneText() as the primary key — subzone names are
    -- unique per boss room and don't suffer from shared area IDs.
    -- ----------------------------------------------------------------
    local function getSubzoneEncounterID()
        local subzoneName = GetSubZoneText()
        if subzoneName and subzoneName ~= "" then
            local encID = SUBZONE_NAME_TO_ENCOUNTER[subzoneName]
            if BF._debugEncounters then
                print("|cff33ff99BF Encounter:|r subzone='" .. tostring(subzoneName) .. "' -> encID=" .. tostring(encID))
            end
            return encID
        end
        return nil
    end

    -- Track the last subzone encounter ID so we don't re-apply on every
    -- ZONE_CHANGED event when the player stays in the same subzone.
    local lastSubzoneEncID = nil

    -- ----------------------------------------------------------------
    -- Exposed API for options panel (same as before)
    -- ----------------------------------------------------------------
    function BF:RefreshEncounterIconOverrides()
        if not customizationsEnabled() then return end
        -- DO NOT invalidate flat aura caches here. The encounter-override
        -- settings UI is currently disabled and not visible in the options
        -- panel; nothing user-facing writes to encounterPASettings /
        -- dungeonPASettings / globalPASettings while the feature is off.
        -- Encounter transitions are runtime-only state — previews never
        -- need to react to them, and live frames pick up changes through
        -- the existing ApplyPrivateAuraOverrideFields / LayoutPrivateAura-
        -- Frames calls below. When this feature is reactivated, decide
        -- carefully whether full-flat invalidation is actually needed
        -- (probably not — only live PA frame fields, not flat geometry).
        if self.UpdateAuraSizeCache then self:UpdateAuraSizeCache() end
        local p = self.db and self.db.profile
    local acp = self.acDB and self.acDB.profile
        if not self.activeFrames then return end
        local encID = p and p.activeEncounterID
        local encProfile = encID
                       and acp.encounterPASettings
                       and acp.encounterPASettings[encID]
        for frame in pairs(self.activeFrames) do
            if frame and frame.unit then
                if encProfile then
                    frame.SF_EncounterIconOverride = {
                        hideIcon            = encProfile.hideIcon,
                        hiddenAuraIndices   = encProfile.hiddenAuraIndices,
                        hideFirstAuraSlot   = encProfile.hideFirstAuraSlot,
                    }
                else
                    frame.SF_EncounterIconOverride = nil
                end
                frame.SF_PrivateAuraUnit      = nil
                -- TEMPORARILY DISABLED: customization-side calls commented out
                -- while debugging a frame-level rendering bug.
                -- Re-apply override fields so the icon path's next layout
                -- pass sees the freshly written SF_EncounterIconOverride.
                -- if BF.ApplyPrivateAuraOverrideFields then
                --     BF:ApplyPrivateAuraOverrideFields(frame)
                -- end
                if BF.LayoutPrivateAuraFrames then BF:LayoutPrivateAuraFrames(frame) end
                -- Anchor calls: defer if in combat.
                if not InCombatLockdown() then
                    if BF.UpdatePrivateAuraAnchors then BF:UpdatePrivateAuraAnchors(frame, frame.unit) end
                    -- Toggling Hide Index N perturbs Blizzard's private-aura
                    -- dispatch state. Even though hiddenAuraIndices is
                    -- icon-only conceptually, the icon re-registration
                    -- causes overlay/border existing registrations to stop
                    -- firing until they are re-registered. Rebuild the
                    -- customization sides here so they stay in sync.
                    -- if BF.UpdatePrivateAuraOverlay then
                    --     BF:UpdatePrivateAuraOverlay(frame)
                    -- end
                    -- if BF.UpdatePrivateAuraFrameBorder then
                    --     BF:UpdatePrivateAuraFrameBorder(frame)
                    -- end
                else
                    pendingAnchorApply = encID or false
                end
            end
        end
    end

    function BF:RefreshEncounterOverrides()
        if not customizationsEnabled() then return end
        -- DO NOT invalidate flat aura caches here. See the equivalent
        -- comment in RefreshEncounterIconOverrides above — same rationale.
        -- Encounter UI is disabled; runtime encounter transitions are not
        -- a flat-cache concern.
        if self.UpdateAuraSizeCache then self:UpdateAuraSizeCache() end
        local p = self.db and self.db.profile
    local acp = self.acDB and self.acDB.profile
        local encID = p and p.activeEncounterID
        if encID then
            applyEncounterOverrides(encID)
        else
            if not self.activeFrames then return end
            for frame in pairs(self.activeFrames) do
                if frame and frame.unit then
                    frame.SF_PrivateAuraUnit       = nil
                    frame.SF_PrivateAuraBorderUnit = nil
                    if not InCombatLockdown() then
                        -- TEMPORARILY DISABLED: customization-side calls commented out.
                        -- Re-apply override fields BEFORE the icon path.
                        -- if BF.ApplyPrivateAuraOverrideFields then
                        --     BF:ApplyPrivateAuraOverrideFields(frame)
                        -- end
                        self:UpdatePrivateAuraAnchor(frame)
                        -- Customization entry points: rebuild alongside the
                        -- icon path when any PA-related setting changes.
                        -- if BF.UpdatePrivateAuraOverlay then
                        --     BF:UpdatePrivateAuraOverlay(frame)
                        -- end
                        -- if BF.UpdatePrivateAuraFrameBorder then
                        --     BF:UpdatePrivateAuraFrameBorder(frame)
                        -- end
                        -- NOTE: Blizzard dispel overlay rebind is handled
                        -- inside UpdatePrivateAuraAnchor above. Not a customization.
                    else
                        pendingAnchorApply = false
                    end
                end
            end
        end
    end

    -- ----------------------------------------------------------------
    -- Event dispatcher
    -- ----------------------------------------------------------------
    f:SetScript("OnEvent", function(_, event)
        -- Killswitch: when off, this entire event handler is a no-op.
        -- All work below is purely customization-driven.
        if not customizationsEnabled() then return end
        if event == "ZONE_CHANGED" or event == "ZONE_CHANGED_INDOORS" then
            -- Player walked into a different subzone inside a raid.
            -- Apply encounter overrides + re-register anchors NOW (out of combat).
            if BF._debugEncounters then
                print("|cff33ff99BF Encounter:|r event=" .. event .. " subzone='" .. tostring(GetSubZoneText()) .. "'")
            end
            local subzoneEncID = getSubzoneEncounterID()
            if subzoneEncID ~= lastSubzoneEncID then
                lastSubzoneEncID = subzoneEncID
                local p = BF and BF.db and BF.db.profile
    local acp = BF.acDB and BF.acDB.profile
                if p then p.activeEncounterID = subzoneEncID end
                if BF._debugEncounters then
                    local hasProfile = p and acp.encounterPASettings and acp.encounterPASettings[subzoneEncID]
                    print("|cff33ff99BF Encounter:|r applying overrides for encID=" .. tostring(subzoneEncID) .. " hasProfile=" .. tostring(hasProfile ~= nil))
                end
                -- DO NOT invalidate flat aura caches on encounter
                -- transitions. The encounter-override UI is disabled and
                -- the only inputs that would change here (encounterPASettings)
                -- can't be edited without that UI. Runtime encounter
                -- transitions are a live-frame concern, not a flat-cache
                -- concern — UpdateAuraSizeCache below still runs for any
                -- non-encounter-related rebuild needs, and the existing
                -- applyEncounterOverrides handles the per-frame state.
                if BF.UpdateAuraSizeCache then BF:UpdateAuraSizeCache() end
                applyEncounterOverrides(subzoneEncID)
            end

        elseif event == "ENCOUNTER_END" then
            -- Clear the encounter ID and re-apply anchors (or defer if somehow
            -- still in combat lockdown, e.g. overlapping encounters).
            local p = BF and BF.db and BF.db.profile
    local acp = BF.acDB and BF.acDB.profile
            if p then p.activeEncounterID = nil end
            setSoftOverrides(nil)
            if not InCombatLockdown() then
                applyAnchors(nil)
            else
                pendingAnchorApply = false
            end

        elseif event == "PLAYER_REGEN_ENABLED" then
            -- Leaving combat: flush any deferred anchor work.
            -- activeEncounterID is subzone-driven; leave it as-is so overrides
            -- stay active if the player is still in the boss room after a wipe.
            if pendingAnchorApply ~= nil then
                local encID = pendingAnchorApply
                if encID == false then encID = nil end
                pendingAnchorApply = nil
                applyEncounterOverrides(encID)
            end

        elseif event == "PLAYER_ENTERING_WORLD" then
            lastSubzoneEncID = nil  -- reset subzone tracking on zone-in
            C_Timer.After(0.5, function()
                local p = BF and BF.db and BF.db.profile
    local acp = BF.acDB and BF.acDB.profile
                if p then p.activeEncounterID = nil end
                -- Check if we're already in a boss subzone on login/reload.
                local subzoneEncID = getSubzoneEncounterID()
                lastSubzoneEncID = subzoneEncID
                if p then p.activeEncounterID = subzoneEncID end
                applyEncounterOverrides(subzoneEncID)
            end)
        end
    end)
end
