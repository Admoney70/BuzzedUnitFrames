-- ============================================================
-- BuzzardFrames: BlizzardFrames.lua
-- Hides Blizzard's default compact raid/party frames so they
-- don't interfere with BF.
--
-- Ported verbatim from Grid2's GridBlizFramesHide.lua pattern:
--  • Fully unregister all events on hidden frames (no retention).
--  • Hook CompactUnitFrame_UpdateUnitEvents so events stay
--    unregistered across roster changes (Blizzard re-registers on
--    every roster update).
--  • One-way: hiding is permanent until /reload. Toggling Hide off
--    in the UI prompts a UI reload (handled by Options.lua).
--  • The party and raid hides are gated on partyFramesEnabled /
--    raidFramesEnabled: with our own frames off we replace nothing,
--    so Blizzard's are left alone. See HideBlizzardFrames below.
--
-- Deviations from Grid2:
--  • CompactRaidFrameManager (the left-side raid tools panel with
--    ready check, role poll, etc.) has its own independent toggle
--    (`hideBlizzardRaidManager` db.global flag, default false).
--    Runs whether or not the raid frames themselves are hidden.
--  • Unit-frame hiding (target, focus, player, pet) lives in the
--    Unit Frames section, not here. This file only handles
--    raid and party.
-- ============================================================
local BF = _G["BuzzardFrames"]

local pcall            = pcall
local InCombatLockdown = InCombatLockdown

-- Shared hidden parent for reparented frames.
local hiddenFrame = CreateFrame("Frame")
hiddenFrame:Hide()

-- Rehide callback for frames that try to Show() themselves after
-- being hidden (e.g. PartyFrame on roster changes).
local function rehide(self)
    if not InCombatLockdown() then self:Hide() end
end

local function unregister(f)
    if f then f:UnregisterAllEvents() end
end

-- Core hide helper: reparent to hidden frame, unregister all events,
-- hook OnShow to re-hide, and strip events from common nested bars.
local function hideFrame(frame)
    if not frame then return end
    if UnregisterUnitWatch then pcall(UnregisterUnitWatch, frame) end
    frame:Hide()
    frame:UnregisterAllEvents()
    frame:SetParent(hiddenFrame)
    frame:HookScript("OnShow", rehide)
    unregister(frame.healthbar)
    unregister(frame.manabar)
    unregister(frame.powerBarAlt)
    unregister(frame.spellbar)
end

-- Per-mode whitelists of units whose CompactUnitFrame events we want
-- to strip. Populated at file load. Arena units and nameplate units
-- ("nameplateN") are intentionally NOT in either set.
--
-- This guard is critical: CompactUnitFrame_UpdateUnitEvents is called
-- for every CompactUnitFrame, which in modern WoW includes nameplate
-- unit frames. Without the guard, the hook would strip events from
-- nameplates and they would stop updating.
--
-- Split by mode so a raid-only hide doesn't strip events off the
-- CompactPartyFrame and vice versa. player/pet are only stripped when
-- BOTH raid and party hides are active; a lone raid or party hide
-- shouldn't touch the player frame's compact representation.
local raid_units, party_units = {}, {}
do
    for i = 1, MAX_PARTY_MEMBERS do
        party_units["party"..i]    = true
        party_units["partypet"..i] = true
    end
    for i = 1, MAX_RAID_MEMBERS do
        raid_units["raid"..i]    = true
        raid_units["raidpet"..i] = true
    end
end

-- Mode flags. Set by HideRaidFrames() / HidePartyFrames() before
-- InstallUnitEventsHook() is called; the hook closure reads them live
-- so enabling party-hide after raid-hide (or vice versa in a future
-- code path) just flips the corresponding flag on without re-hooking.
local hideRaidActive  = false
local hidePartyActive = false

-- Called for every compact unit frame on every UpdateUnitEvents.
-- When Blizzard re-registers events on a roster change, this strips
-- them back off. This is the critical piece BF was missing.
--
-- Gated by per-mode whitelists so we only touch the compact frames
-- that belong to the currently-active hide mode(s), never nameplates
-- or any other CompactUnitFrame consumer.
local function UnregisterUnitEvents(frame)
    local unit = frame.unit
    if not unit then return end
    if hideRaidActive and raid_units[unit] then
        pcall(frame.UnregisterAllEvents, frame)
        return
    end
    if hidePartyActive and party_units[unit] then
        pcall(frame.UnregisterAllEvents, frame)
        return
    end
    -- player/pet: only strip when BOTH modes are active, matching the
    -- "combined hide" semantics Grid2 uses with its single grouped_units
    -- table.
    if hideRaidActive and hidePartyActive and (unit == "player" or unit == "pet") then
        pcall(frame.UnregisterAllEvents, frame)
    end
end

-- hooksecurefunc cannot be uninstalled, so guard against double-install
-- if both HideRaidFrames and HidePartyFrames run in the same session.
local unitEventsHookInstalled = false
local function InstallUnitEventsHook()
    if unitEventsHookInstalled then return end
    unitEventsHookInstalled = true
    hooksecurefunc("CompactUnitFrame_UpdateUnitEvents", UnregisterUnitEvents)
end

-- Party frames: hide both the non-compact PartyFrame (used when
-- "Use Raid-Style Party Frames" is off) and CompactPartyFrame
-- (used when raid-style is on), plus every pooled member frame.
local function HidePartyFrames()
    if not PartyFrame then return end
    hidePartyActive = true
    -- Install the UpdateUnitEvents hook so CompactPartyFrame events
    -- stay stripped across roster updates. Same mechanism as raid.
    InstallUnitEventsHook()
    hideFrame(PartyFrame)
    if PartyFrame.PartyMemberFramePool then
        for frame in PartyFrame.PartyMemberFramePool:EnumerateActive() do
            hideFrame(frame)
            hideFrame(frame.HealthBar)
            hideFrame(frame.ManaBar)
        end
        PartyFrame.PartyMemberFramePool:ReleaseAll()
    end
    hideFrame(CompactPartyFrame)
    -- Used by CompactPartyFrame internally; killing it on UIParent
    -- prevents the compact party frame from re-arming itself.
    UIParent:UnregisterEvent("GROUP_ROSTER_UPDATE")
end

-- Raid frames: hide the container and install the UpdateUnitEvents
-- hook + re-show guards. Does NOT touch CompactRaidFrameManager
-- (the tools panel) — that's handled independently by
-- HideRaidManager() below.
local function HideRaidFrames()
    if not CompactRaidFrameContainer then return end
    hideRaidActive = true
    local function HideOne(frame)
        pcall(function()
            frame:SetAlpha(0)
            if not InCombatLockdown() then
                frame:SetScale(0.001)
                frame:Hide()
            end
            frame:UnregisterAllEvents()
        end)
    end
    local function HideContainer()
        HideOne(CompactRaidFrameContainer)
        -- v98 (owner report 2026-09-06): the ping mirror (PingMirror.lua)
        -- reads its raid/party pins off Blizzard's compact frames, and the
        -- container's own GROUP_ROSTER_UPDATE handler (TryUpdate ->
        -- LayoutFrames -> CompactUnitFrame_SetUnit) is the ONLY thing that
        -- assigns units to those receivers. With every event stripped the
        -- receivers froze at the roster of the last layout, so anyone who
        -- joined after login had no receiver and never got a pin -- the pin
        -- worked on the player (present at that layout) and again after a
        -- /reload (fresh layout). Keep exactly these two events: the
        -- container stays alpha-0 / scaled / hidden, the per-unit-frame
        -- events are still stripped by the UpdateUnitEvents hook above, and
        -- Blizzard's other two (UNIT_PET, LFG_UPDATE) stay off -- pets are
        -- not pinged on our frames and LFG state does not move the roster.
        -- The handler runs in Blizzard's own secure context, so it also lays
        -- out mid-combat. Idempotent: this runs again from the
        -- UpdateShown / OnShow hooks below.
        pcall(CompactRaidFrameContainer.RegisterEvent, CompactRaidFrameContainer, "GROUP_ROSTER_UPDATE")
        pcall(CompactRaidFrameContainer.RegisterEvent, CompactRaidFrameContainer, "PLAYER_ENTERING_WORLD")
    end
    -- UpdateUnitEvents fires on roster updates and re-registers every
    -- event on a compact unit frame; our hook strips them again.
    InstallUnitEventsHook()
    -- CompactRaidFrameManager_UpdateShown can also show the container;
    -- the OnShow hook covers any path that bypasses it.
    hooksecurefunc("CompactRaidFrameManager_UpdateShown", HideContainer)
    CompactRaidFrameContainer:HookScript("OnShow", HideContainer)
    HideContainer()
end

-- Raid tools panel (CompactRaidFrameManager): the left-side panel
-- with ready check, role poll, etc. Hidden independently of the
-- raid frames container via the hideBlizzardRaidManager toggle.
local function HideRaidManager()
    if not CompactRaidFrameManager then return end
    local function HideOne()
        pcall(function()
            CompactRaidFrameManager:SetAlpha(0)
            if not InCombatLockdown() then
                CompactRaidFrameManager:SetScale(0.001)
                CompactRaidFrameManager:Hide()
            end
            CompactRaidFrameManager:UnregisterAllEvents()
        end)
    end
    hooksecurefunc("CompactRaidFrameManager_UpdateShown", HideOne)
    CompactRaidFrameManager:HookScript("OnShow", HideOne)
    HideOne()
end

-- Public entry point. Per-feature idempotent: each hide routine
-- installs OnShow/hooksecurefunc hooks that cannot be uninstalled,
-- so each feature has its own one-shot guard. This lets the options
-- UI toggle any single hide ON mid-session (e.g. enabling Hide Party
-- while Hide Raid is already active) without the previous feature's
-- activation short-circuiting the new one.
--
-- Turning a hide OFF requires a UI reload (handled by the option
-- setter via BUZZARDFRAMES_RELOAD); the guards here only exist to
-- prevent double-installing hooks, not to undo hiding.
function BF:HideBlizzardFrames()
    if InCombatLockdown() then return end
    local g = self.db.global
    -- Each hide is gated on the frames it exists to make room for: with
    -- our party or raid frames switched off we are not replacing
    -- anything, so hiding Blizzard's would leave the player with no
    -- frames at all. The stored hideBlizzard* value is left alone -- it
    -- is remembered and simply not applied -- and `~= false` is the read,
    -- since an absent enable key means ON.
    --
    -- The raid tools panel (ready check, role poll) is deliberately NOT
    -- gated: it is a separate piece of UI that the raid frames do not
    -- replace, so its toggle stands on its own.
    if g.hideBlizzardRaid and g.raidFramesEnabled ~= false
        and not self._raidHidden then
        self._raidHidden = true
        HideRaidFrames()
    end
    if g.hideBlizzardRaidManager and not self._raidManagerHidden then
        self._raidManagerHidden = true
        HideRaidManager()
    end
    if g.hideBlizzardParty and g.partyFramesEnabled ~= false
        and not self._partyHidden then
        self._partyHidden = true
        HidePartyFrames()
    end
end
