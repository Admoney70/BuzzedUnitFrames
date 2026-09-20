-- ============================================================
-- BuzzardFrames: Core_ProfileLifecycle.lua
-- Runtime profile-change entry points:
--   OnRPProfileChanged  — Raid/Party Frames profile switch
--   OnACProfileChanged  — Aura Customizations profile switch
--   OnCFGProfileChanged — Custom Frame Groups profile switch
--   OnUFProfileChanged  — Unit Frames profile switch
--   OnICProfileChanged  — Incoming Casts profile switch
--   OnUFProfileShutdown — snapshots reload-sensitive UF keys
--     before the profile pointer is reassigned.
--   ApplyRoleSpecLayout — resolves and applies the correct
--     raid/party layout for the player's current spec/role.
--     Called on login, spec change, and profile change.
-- Extracted from Core.lua in the Core split refactor.
-- ============================================================
local BF = _G["BuzzardFrames"]

-- Keys in ufDB.profile that require a UI reload when their value changes.
-- These are the settings whose option setters call promptReload().
local UF_RELOAD_KEYS = {
    "ptfEnabled",
    "hideBlizzardPlayerFrame",
    "hideBlizzardTargetFrame",
    "hideBlizzardFocusFrame",
    "hideBlizzardPetFrame",
    "hideBlizzardTargetOfTargetFrame",
    "hideBlizzardBossFrames",
    "showPlayerFrame",
    "showTargetFrame",
    "showFocusFrame",
    "showPetFrame",
    "showBossFrames",
    "showTargetOfTargetFrame",
    "showFocusTargetFrame",
}

-- Snapshot the reload-sensitive UF keys from the CURRENT (about-to-be-
-- replaced) profile. Called by AceDB's OnProfileShutdown callback on
-- ufDB, which fires BEFORE the profile pointer is reassigned. The
-- snapshot is consumed by OnProfileChanged to detect whether any
-- reload-requiring settings changed.
function BF:OnUFProfileShutdown()
    local ufp = self.ufDB and self.ufDB.profile
    if not ufp then return end
    local snap = {}
    for _, key in ipairs(UF_RELOAD_KEYS) do
        snap[key] = ufp[key]
    end
    self._ufReloadSnapshot = snap
end

-- ============================================================
-- SHARED HELPERS
-- ============================================================

-- Notify the options panel to re-read values (Core_OptionsBridge.lua).
local function NotifyOptions(self)
    if self.RefreshPanel then self:RefreshPanel("profile") end
end

-- BuzzardFrames profiles are global, not character-specific. AceDB's
-- SetProfile only updates profileKeys[currentCharKey], which creates
-- per-character divergence if the user switches profiles on one toon
-- and then logs into another. SyncProfileKeysGlobal fixes this by
-- updating every entry in db.sv.profileKeys to the current profile
-- name after any profile switch. The next character to log in will
-- find their profileKey already pointing at the correct profile.
local function SyncProfileKeysGlobal(db)
    if not db or not db.sv or not db.sv.profileKeys then return end
    local current = db:GetCurrentProfile()
    for charKey in pairs(db.sv.profileKeys) do
        db.sv.profileKeys[charKey] = current
    end
end

-- Safety-net lazy migration for the parent DB. Under v18 each module
-- has its own AceDB and the parent's profile is no longer switched from
-- the UI. This check exists for edge cases (programmatic SetProfile on
-- the parent, imported legacy SVs, future features).
local function LazyMigrateParent(self)
    local p = self.db.profile
    if (p.dbVersion or 0) < 18 then
        self:MigrateUnitFramesProfile()
        self:MigrateAuraCustomizationsProfile()
        self:MigrateCustomFrameGroupsProfile()
        self:MigrateGlobalSettings()
        self:MigrateRaidPartyFramesProfile()
        self:MigrateIncomingCastsProfile()
        p.dbVersion = 18
    end
end

-- ============================================================
-- PER-MODULE PROFILE-CHANGE HANDLERS
-- ============================================================
-- Each module DB fires its own OnProfileChanged / OnProfileCopied /
-- OnProfileReset. These handlers do only the refresh work that the
-- specific module requires, rather than the full RefreshAll pipeline.

-- ── Raid/Party Frames ───────────────────────────────────────────────
function BF:OnRPProfileChanged()
    SyncProfileKeysGlobal(self.rpDB)
    LazyMigrateParent(self)
    -- Flat layouts are stored sparsely; re-seed missing flats and wire
    -- __index metatable templates on the incoming profile so any read
    -- of an un-customized key (e.g. frame.showGroup[i]) resolves to
    -- the default instead of nil. See Core_FlatDefaults.lua.
    self:RehydrateFlats()
    -- Scrub stale slot→flatID assignments on the incoming profile so
    -- the options panel and the runtime resolver agree on which flat
    -- each slot points to. Same call as in RegisterDB (Core_DB.lua) but
    -- targets the profile we just switched to. Must run AFTER
    -- RehydrateFlats so the seeded defaults (flat_party / flat_raid40)
    -- exist on this profile; must run BEFORE InvalidateRaidProfileCache
    -- + RefreshAll below so the first post-switch render reads the
    -- already-scrubbed assignments.
    self:ScrubInvalidSlotAssignments()
    self:InvalidateRaidProfileCache()
    -- Per-layout flats are entirely different objects after a profile
    -- switch; conservatively invalidate every flat so UpdateAuraSizeCache
    -- rebuilds.
    if self.InvalidateAllFlatAuraCaches then self:InvalidateAllFlatAuraCaches() end
    if self.RefreshProfileCache then self:RefreshProfileCache() end
    self:RefreshAll()
    -- v96: icons.showPingIndicator is per-profile, and the mirror caches a
    -- resolved pin list -- re-resolve it so the incoming profile's setting
    -- takes effect without waiting for a roster event.
    if self.RebuildPingMirror then self:RebuildPingMirror() end
    NotifyOptions(self)
end

-- ── Aura Customizations ─────────────────────────────────────────────
function BF:OnACProfileChanged()
    SyncProfileKeysGlobal(self.acDB)
    LazyMigrateParent(self)
    -- Fires for OnProfileChanged / OnProfileCopied / OnProfileReset. A copied
    -- or reset acDB profile is never seen by the dbVersion-gated dispatcher in
    -- RegisterDB (that stamp lives on the MAIN db), and OnProfileReset clears
    -- both the sentinel and customBuffContainers -- leaving the profile with no
    -- Single Buff entries and, on 12.1, no way to configure any curated spell.
    -- Sentinel-guarded per profile, so this is a no-op in the normal case.
    if self.EnsureAurasMigratedForProfile then self:EnsureAurasMigratedForProfile() end
    if self.RefreshAllAuras then self:RefreshAllAuras() end
    if self.RefreshAllCustomContainersWithRebuild then
        self:RefreshAllCustomContainersWithRebuild()
    end
    if self.Bounce_Sync then self:Bounce_Sync() end
    -- The panel re-derives its container list and per-spec pages on
    -- refresh, so a page refresh is the whole rebuild.
    NotifyOptions(self)
end

-- ── Custom Frame Groups ─────────────────────────────────────────────
function BF:OnCFGProfileChanged()
    SyncProfileKeysGlobal(self.cfgDB)
    LazyMigrateParent(self)
    self:RehydrateCFGFlats()
    self:InvalidateRaidProfileCache()
    -- CFG flats are entirely different objects after a profile switch;
    -- conservatively invalidate every flat so UpdateAuraSizeCache rebuilds.
    if self.InvalidateAllFlatAuraCaches then self:InvalidateAllFlatAuraCaches() end
    self:RefreshAll()
    NotifyOptions(self)
end

-- ── Unit Frames ─────────────────────────────────────────────────────
function BF:OnUFProfileChanged()
    SyncProfileKeysGlobal(self.ufDB)
    LazyMigrateParent(self)
    -- Restore UF layout from the new profile
    local ufp = self.ufDB.profile
    local savedUFID = ufp.activeUFLayout or "default"
    if not ufp.ufLayouts or not ufp.ufLayouts[savedUFID] then savedUFID = "default" end
    self._ufActiveLayout = savedUFID
    -- Re-resolve UF layout after profile switch
    if self.ApplyUFRoleSpecLayout then self:ApplyUFRoleSpecLayout(true) end
    if self.ApplyAllUFPositions then self:ApplyAllUFPositions() end
    -- Relayout all active oUF frames
    if self.oufPlayer        then self:ApplyOUFPlayerLayout()        end
    if self.oufTarget        then self:ApplyOUFTargetLayout()        end
    if self.oufFocus          then self:ApplyOUFFocusLayout()         end
    if self.oufPet            then self:ApplyOUFPetLayout()           end
    if self.oufTargetOfTarget then self:ApplyOUFTargetOfTargetLayout() end
    if self.oufFocusTarget   then self:ApplyOUFFocusTargetLayout()   end
    if self.oufBoss           then self:ApplyOUFBossFrameLayout()     end
    if self.RefreshOUFFonts   then self:RefreshOUFFonts()             end
    -- v96: the UF-side ping gates (ptfEnabled / oufShowPingIndicator /
    -- showXFrame) all live in this profile, and the relayout calls above only
    -- fire for frames that EXIST -- ApplyOUFPingIndicators would be skipped
    -- entirely on a profile with the unit frames off. Ask the shared mirror
    -- to re-resolve directly.
    if self.RebuildPingMirror then self:RebuildPingMirror()           end
    -- Aura button styling (borders, cooldown/duration, stack text) lives
    -- on ALREADY-CREATED pooled buttons; PostCreateButton fires once per
    -- button at spawn and never again, and the layout pass above only
    -- re-stamps when the icon SIZE changed. Without this walk a profile
    -- switch/copy/reset left every visible aura wearing the previous
    -- profile's aura styling while the options panel reported the new
    -- values -- until some unrelated aura edit happened to trigger a walk.
    if self.RestyleOUFAuraButtons then self:RestyleOUFAuraButtons() end
    -- Check whether any reload-sensitive keys changed
    --
    -- v94: during a profile IMPORT this handler runs TWICE -- once from
    -- db:SetProfile (against the still-empty profile, where the comparison is
    -- outgoing-profile vs DEFAULTS and therefore meaningless: it is why an
    -- import that changed a reload-sensitive key never prompted) and once from
    -- the post-merge resync in Options_Profiles.lua. Neither pass prompts or
    -- consumes the snapshot: the import path always shows its own reload popup
    -- when it finishes, and clears the snapshot itself.
    local snap = (not self._importPendingMerge) and self._ufReloadSnapshot or nil
    if snap then
        self._ufReloadSnapshot = nil
        for _, key in ipairs(UF_RELOAD_KEYS) do
            if snap[key] ~= ufp[key] then
                C_Timer.After(0, function()
                    StaticPopup_Show("BUZZARDFRAMES_RELOAD_UI")
                end)
                break
            end
        end
    end
    NotifyOptions(self)
end

-- ── Incoming Casts ──────────────────────────────────────────────────
function BF:OnICProfileChanged()
    SyncProfileKeysGlobal(self.icDB)
    LazyMigrateParent(self)
    if self.IncomingCasts then
        self.IncomingCasts:OnSettingChanged()
        self.IncomingCasts:Refresh()
    end
    NotifyOptions(self)
end

-- Invalidate caches and refresh so the next render re-walks the
-- override precedence chain with the current spec/role.
-- Called on login, spec change, and profile change.
--
-- Phase 2: role/spec changes no longer pick a whole layout; they
-- shift which flat gets resolved per-slot via BF:ResolveActiveFlat.
-- This function just nudges the render path to re-resolve.
--
-- Signature preserved for API compatibility:
--   silent    - accepted but unused (no announce messages in Phase 2)
--   noRefresh - if true, skip the RefreshAll call (caller will refresh)
--
-- PLAYER_ROLES_ASSIGNED fires on every group member's role/spec change
-- (not just the local player's), and its deferred handler calls this
-- function. Under Phase 2 only the LOCAL player's spec/role affects
-- which flat resolves for us, so a remote player's spec change doesn't
-- require a rebuild. Skip the RefreshAll when the resolved flat is
-- unchanged from the last applied state (tracked by ApplyProfile via
-- _lastAppliedFlat / _lastAppliedContextIsRaid). This mirrors the
-- skip check in _GroupTypeChangedExecute and addresses the same
-- class of spurious nuclear rebuilds.
function BF:ApplyRoleSpecLayout(silent, noRefresh)
    self:InvalidateRaidProfileCache()
    if noRefresh or not self.RefreshAll then return end

    -- Compute what the resolved flat + context WOULD be after this
    -- re-resolution, and compare against what ApplyProfile last wrote.
    -- If nothing actually changed, skip RefreshAll entirely.
    local newFlat   = self:ResolveActiveFlat(self:GetActiveSlot())
    local newIsRaid
    if self.GetTrueActiveTab then
        local gt = self:GetTrueActiveTab()
        newIsRaid = (gt ~= "party")
    else
        newIsRaid = self._contextIsRaid
    end
    local lastFlat   = self._lastAppliedFlat
    local lastIsRaid = self._lastAppliedContextIsRaid
    if lastFlat ~= nil
       and lastFlat == newFlat
       and lastIsRaid == newIsRaid then
        -- Resolved flat is unchanged -- the render path would produce
        -- the same output. Skip the nuclear RefreshAll; downstream
        -- indicators will pick up any role-icon changes through the
        -- role status's UpdateAllUnits sweep (fired from the
        -- PLAYER_ROLES_ASSIGNED handler alongside this call).
        return
    end

    self:RefreshAll()
end
