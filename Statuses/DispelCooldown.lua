-- ============================================================
-- BuzzardFrames: Statuses/DispelCooldown.lua
-- Tracks the player's defensive dispel spell cooldown.
-- Used by DebuffHighlight to suppress the debuff border when
-- the player's dispel is on cooldown.
--
-- Spell table covers all class/spec defensive dispels that can
-- target friendly players. Mass Dispel excluded (long CD,
-- situational). Self-only dispels excluded.
-- ============================================================

local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

local GetSpellCooldown = C_Spell and C_Spell.GetSpellCooldown
local GetSpellCooldownDuration = C_Spell and C_Spell.GetSpellCooldownDuration
local IsPlayerSpell    = IsPlayerSpell
local GetSpecialization = GetSpecialization
local GetSpecializationInfo = GetSpecializationInfo
local UnitClass        = UnitClass
local select           = select
local pairs            = pairs

-- ============================================================
-- DISPEL SPELL TABLE
-- Keyed by specID. Each entry is a list of spell IDs to check.
-- The first known spell wins (checked via IsPlayerSpell).
-- ============================================================
local DISPEL_SPELLS_BY_SPEC = {
    -- Priest: Holy (257), Discipline (256)
    [256] = { 527 },        -- Purify (Magic, Disease)
    [257] = { 527 },        -- Purify (Magic, Disease)
    -- Priest: Shadow (258)
    [258] = { 213634 },     -- Purify Disease (Disease only)

    -- Paladin: Holy (65)
    [65]  = { 4987 },       -- Cleanse (Poison, Disease, Magic)
    -- Paladin: Protection (66), Retribution (70)
    [66]  = { 213644 },     -- Cleanse Toxins (Poison, Disease)
    [70]  = { 213644 },     -- Cleanse Toxins (Poison, Disease)

    -- Shaman: Restoration (264), Elemental (262), Enhancement (263)
    [264] = { 51886 },      -- Cleanse Spirit (Curse, Magic)
    [262] = { 51886 },      -- Cleanse Spirit (Curse)
    [263] = { 51886 },      -- Cleanse Spirit (Curse)

    -- Druid: Restoration (105)
    [105] = { 88423 },      -- Nature's Cure (Curse, Poison, Magic)
    -- Druid: Balance (102), Feral (103), Guardian (104)
    [102] = { 2782 },       -- Remove Corruption (Curse, Poison)
    [103] = { 2782 },       -- Remove Corruption (Curse, Poison)
    [104] = { 2782 },       -- Remove Corruption (Curse, Poison)

    -- Monk: Mistweaver (270)
    [270] = { 115450 },     -- Detox (Magic, Poison, Disease)
    -- Monk: Brewmaster (268), Windwalker (269)
    [268] = { 218164 },     -- Detox (Poison, Disease)
    [269] = { 218164 },     -- Detox (Poison, Disease)

    -- Evoker: Preservation (1468)
    [1468] = { 360823 },    -- Naturalize (Magic, Poison)
    -- Evoker: Augmentation (1473), Devastation (1467)
    [1473] = { 374251 },    -- Cauterizing Flame (Bleed, Poison, Curse, Disease)
    [1467] = { 374251 },    -- Cauterizing Flame (Bleed, Poison, Curse, Disease)

    -- Mage: Arcane (62), Fire (63), Frost (64)
    [62]  = { 475 },        -- Remove Curse (Curse)
    [63]  = { 475 },        -- Remove Curse (Curse)
    [64]  = { 475 },        -- Remove Curse (Curse)

    -- Warlock: Affliction (265), Demonology (266), Destruction (267)
    -- Singe Magic (89808) is an Imp pet ability
    [265] = { 89808 },      -- Singe Magic
    [266] = { 89808 },      -- Singe Magic
    [267] = { 89808 },      -- Singe Magic
}

-- Classes with no friendly dispel: DK, DH, Hunter, Rogue, Warrior
-- (no entries needed — they'll return nil from the lookup)

-- ============================================================
-- STATE
-- ============================================================
local _dispelSpellID = nil      -- the player's active dispel spell ID (or nil if none)
local _trackingActive = false   -- true if we're listening for cooldown events

-- ============================================================
-- RESOLVE PLAYER'S DISPEL SPELL
-- Called on login, spec change, and talent change.
-- ============================================================
local function ResolveDispelSpell()
    _dispelSpellID = nil
    local specIndex = GetSpecialization and GetSpecialization()
    if not specIndex then return end
    local specID = GetSpecializationInfo and select(1, GetSpecializationInfo(specIndex))
    if not specID then return end

    local candidates = DISPEL_SPELLS_BY_SPEC[specID]
    if not candidates then return end

    for _, id in pairs(candidates) do
        if IsPlayerSpell and IsPlayerSpell(id) then
            _dispelSpellID = id
            return
        end
    end
end

-- ============================================================
-- COOLDOWN CHECK
--
-- C_Spell.GetSpellCooldown returns secret values for startTime
-- and duration. We CANNOT compare them in Lua. Instead we return
-- a secret boolean (dispelReady) that DebuffHighlight passes
-- directly to texture:SetAlphaFromBoolean(ready, showAlpha, 0)
-- on the border edges. The engine handles the secret branching.
--
-- GetDispelOnCooldownBool() returns a secret boolean that is:
--   true  = dispel is on a real cooldown (not just GCD)
--   false = dispel is ready (off CD, or only GCD is active)
--   nil   = no dispel spell or feature disabled (caller should show border)
-- ============================================================
-- Returns true if dispel is on a real cooldown (not GCD), false if ready,
-- nil if no dispel spell known or cooldown API unavailable.
-- Callers check their own per-feature enable flag before using the result.
local _onCooldown = false       -- true while the dispel is on real cooldown
local _cooldownTimer = nil      -- C_Timer handle for the 8s cooldown window
local DISPEL_COOLDOWN = 8       -- all dispels share an 8-second cooldown

function BF:GetDispelOnCooldownBool()
    if not _dispelSpellID then return nil end
    return _onCooldown
end

-- Returns true if any of the three dispel cooldown gating features are enabled.
-- Reads auras.dispelIndicator via GetAurasSubcatProfile against the ACTIVE flat
-- (raid or party) so per-layout overrides drive the tracking decision. This
-- runs only from UpdateDispelCooldownTracking (login / spec change / talent
-- change / toggle), not in a per-frame hot path, so the active-context
-- resolution cost is fine.
-- v35: dispelBorderOnlyIfReady and dispelOverlayOnlyIfReady were relocated
-- from borders to auras.dispelIndicator alongside dispelIndicatorOnlyIfReady
-- (which v34 relocated). All three now live in the same sub-category so a
-- single section resolution serves everything.
function BF:IsAnyDispelCooldownGatingEnabled()
    local isRaid = self:ResolveActiveIsRaid()
    local activeFlat = isRaid and self:GetRaidProfile() or self:GetActivePartyProfile()
    -- v60: resolved per aura sub-category, not by resolving the whole
    -- auras table and indexing it. The Buffs and Debuffs per-layout
    -- toggles are independent, so a flat's auras table can carry stale
    -- rawkeys for whichever group is currently OFF.
    local diP = self:GetAurasSubcatProfile("dispelIndicator", activeFlat) or {}
    if diP.dispelBorderOnlyIfReady or diP.dispelOverlayOnlyIfReady then return true end
    -- Debuff Health Color Change's own gate (dispelHealthColor visual kind).
    if diP.dispelHealthColorOnlyIfReady then return true end
    return diP.dispelIndicatorOnlyIfReady or false
end

-- Refresh all debuff highlights on active frames.
local function RefreshAllDispelIndicators()
    local dispelStatus = BF.statuses and BF.statuses.dispel
    if dispelStatus and dispelStatus.enabled then
        local activatedFrames = BF.activatedFrames
        if activatedFrames then
            for frame, unit in pairs(activatedFrames) do
                dispelStatus:UpdateIndicators(unit)
            end
        end
    end
end

-- ============================================================
-- EVENT HANDLER: SPELL_UPDATE_COOLDOWN
--
-- 12.1: cooldown NUMBERS (startTime/duration) are secret in combat, but
-- GetSpellCooldown's isActive and isOnGCD are accessible BOOLEANS by
-- design -- the same contract the Buzzard Auras spell-ready watcher runs
-- on. "On a real cooldown" is isActive and not isOnGCD.
--
-- NOT read at the event instant, deliberately. At the moment the press
-- fires this event the struct is not settled: a MISSED dispel (GCD
-- only) was observed in game reporting isActive with isOnGCD still
-- false, which classified it as a real cooldown -- and with no real
-- cooldown running, no end edge ever came, so the fallback held the
-- suppression for the full window. Mid-GCD the flag is reliable (the
-- Buzzard Auras watcher reads it there on every combat event without
-- flicker), so classification waits CLASSIFY_DELAY and then reads once:
-- a landed dispel still suppresses a fifth of a second after the press,
-- a miss never suppresses at all.
-- ============================================================
local CLASSIFY_DELAY = 0.2
local _classifyTimer = nil
local _events = BF:EventOwner("dispelCooldown")

-- The suppression ENDS when the engine says the cooldown ended: a hidden
-- Cooldown widget armed with the dispel's duration OBJECT (no numbers
-- read; SPELL_UPDATE_COOLDOWN does not fire when a cooldown ends), its
-- OnCooldownDone engine-scheduled. Mirrors the Buzzard Auras ticker,
-- PTR caution included: the widget stays alpha-0 and undrawn rather
-- than hidden. The 8s timer stays as a fallback with a little slack --
-- whichever fires first clears the other -- and the engine edge also
-- tracks a cooldown that something shortened.
local _cdTicker = nil
local function EndSuppression()
    if _cooldownTimer then
        _cooldownTimer:Cancel()
        _cooldownTimer = nil
    end
    if not _onCooldown then return end
    _onCooldown = false
    RefreshAllDispelIndicators()
end

local function ArmCooldownDone()
    if not GetSpellCooldownDuration then return end
    local w = _cdTicker
    if not w then
        w = CreateFrame("Cooldown", nil, UIParent, "CooldownFrameTemplate")
        w:SetSize(1, 1)
        w:SetPoint("TOPLEFT")
        w:SetAlpha(0)
        w:SetDrawSwipe(false)
        w:SetDrawEdge(false)
        w:SetDrawBling(false)
        w:SetHideCountdownNumbers(true)
        w:SetScript("OnCooldownDone", EndSuppression)
        _cdTicker = w
    end
    -- true = ignore the GCD contribution; the REAL cooldown's end.
    local dur = GetSpellCooldownDuration(_dispelSpellID, true)
    if dur then w:SetCooldownFromDurationObject(dur) end
end

-- BFEvents normalizes the shape to (owner, event, ...), so the payload
-- (spellID) lands in the third slot exactly as it did on the frame.
local function Classify()
    _classifyTimer = nil
    if _onCooldown then return end
    local cd = GetSpellCooldown and GetSpellCooldown(_dispelSpellID)
    if not (cd and cd.isActive and not cd.isOnGCD) then return end

    -- The dispel is on its REAL cooldown: it landed. Suppress now.
    _onCooldown = true
    RefreshAllDispelIndicators()
    ArmCooldownDone()
    if _cooldownTimer then _cooldownTimer:Cancel() end
    _cooldownTimer = C_Timer.NewTimer(DISPEL_COOLDOWN + 0.5, EndSuppression)
end

local function OnSpellCooldownUpdate(_, _, spellID)
    -- Only care about our dispel spell
    if spellID ~= _dispelSpellID then return end
    if _onCooldown or _classifyTimer then return end
    if not GetSpellCooldown then return end
    local cd = GetSpellCooldown(_dispelSpellID)
    if not (cd and cd.isActive) then return end
    _classifyTimer = C_Timer.NewTimer(CLASSIFY_DELAY, Classify)
end

-- ============================================================
-- START / STOP TRACKING
-- ============================================================
local function StartTracking()
    if _trackingActive then return end
    -- Guarded because _trackingActive and the subscription could in principle
    -- drift; re-subscribing an already-held (owner, event) would error.
    if not _events:IsSubscribed("SPELL_UPDATE_COOLDOWN") then
        _events:Sub("SPELL_UPDATE_COOLDOWN", OnSpellCooldownUpdate, "unitless")
    end
    _trackingActive = true
    _onCooldown = false
end

local function StopTracking()
    if not _trackingActive then return end
    -- The subscription, the fallback timer and the end-edge widget are
    -- one unit of state: dropping the event without clearing them would
    -- leave a scheduled end able to flip _onCooldown after tracking
    -- stopped.
    _events:Unsub("SPELL_UPDATE_COOLDOWN")
    if _cooldownTimer then
        _cooldownTimer:Cancel()
        _cooldownTimer = nil
    end
    if _cdTicker then _cdTicker:Clear() end
    if _classifyTimer then
        _classifyTimer:Cancel()
        _classifyTimer = nil
    end
    _trackingActive = false
    _onCooldown = false
end

-- ============================================================
-- PUBLIC API
-- ============================================================

-- Called on spec change, talent change, and setting toggle.
function BF:UpdateDispelCooldownTracking()
    if not self:IsAnyDispelCooldownGatingEnabled() then
        StopTracking()
        return
    end
    ResolveDispelSpell()
    if _dispelSpellID then
        StartTracking()
    else
        StopTracking()
    end
end

-- UpdateDispelCooldownTracking is called from:
--   • PLAYER_ENTERING_WORLD (after OnPlayerSpecChanged)
--   • PLAYER_SPECIALIZATION_CHANGED (after spec change)
--   • PLAYER_TALENT_UPDATE (after talent change)
-- These calls are added directly in Initialization.lua.
