-- ============================================================
-- BuzzardFrames: Auras/SoulOfTheForest.lua
--
-- Detects Soul of the Forest-empowered Rejuvenation, Regrowth,
-- and Germination applications and marks their auraInstanceIDs
-- so BuffIcons indicator can apply a glow to the corresponding icons.
--
-- Detection logic:
--   1. Cache whether the player has Soul of the Forest (158478)
--      and Power of the Archdruid (392302) via IsPlayerSpell().
--   2. UNIT_SPELLCAST_SUCCEEDED on "player" for Swiftmend (18562)
--      opens the window (_sotfActive = true).
--   3. The FIRST Rejuv/Regrowth SPELLCAST after Swiftmend is the
--      empowered cast (_sotfCastConsumed = true). Its resulting
--      addedAuras (including Archdruid extras) are marked, up to
--      a hard cap of 3 (1 direct + 2 Archdruid).
--   4. The SECOND Rejuv/Regrowth SPELLCAST definitively closes the
--      window — no more marks until the next Swiftmend.
--   5. Safety timeout (15s) closes the window if no cast happens.
--
-- Empowered marks are cleared when:
--   a) The auraInstanceID appears in removedAuraInstanceIDs (aura
--      expired, was dispelled, or WoW reassigned the ID).
--   b) The player casts a non-empowered Rejuv/Regrowth on a unit
--      that has an empowered mark (detected via UNIT_SPELLCAST_SENT
--      target tracking + UNIT_AURA addedAuras/updatedAuraInstanceIDs).
--   c) The buff icon is hidden by BuffIcons indicator (aura expired).
-- Removal cleanup (a) is essential because WoW can reuse
-- auraInstanceIDs on the same unit, which would cause false glows.
--
-- Novel implementation — no Grid2 equivalent exists for this feature.
-- ============================================================

local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")
local LCG = LibStub("LibCustomGlow-1.0", true)
local issecretvalue = issecretvalue or function(v) return false end

-- Spell IDs
local SWIFTMEND_ID          = 18562
local REJUVENATION_ID       = 774
local REGROWTH_ID           = 8936
local GERMINATION_ID        = 155777
local SOUL_OF_THE_FOREST_ID = 158478
local POWER_OF_ARCHDRUID_ID = 392302
local RAMPANT_GROWTH_ID     = 404521
local CONVOKE_ID            = 391528
local LIFEBLOOM_ID          = 33763

-- Spells whose auras can be empowered (fast lookup for addedAuras)
local EMPOWERABLE = {
    [REJUVENATION_ID] = true,
    [REGROWTH_ID]     = true,
    [GERMINATION_ID]  = true,
}

-- Exposed (read-only by convention) for CustomAuras.lua's per-container
-- "has SotF-relevant spell" flag. Consumers use this as a set:
-- BF._SotF_EMPOWERABLE_IDS[spellId] is true iff the spell is empowerable.
BF._SotF_EMPOWERABLE_IDS = EMPOWERABLE

-- Spells the player directly casts that consume the SotF buff.
-- Germination is applied by casting Rejuvenation, not cast directly.
local CASTABLE_EMPOWERABLE = {
    [REJUVENATION_ID] = true,
    [REGROWTH_ID]     = true,
}

-- ============================================================
-- STATE
-- ============================================================
local _sotfTalented    = false   -- player has Soul of the Forest
local _archdTalented   = false   -- player has Power of the Archdruid
local _rampantTalented = false   -- player has Rampant Growth
local _sotfActive    = false   -- Swiftmend was cast, waiting for the empowered cast
local _sotfCastConsumed = false -- the empowered Rejuv/Regrowth was cast, marking auras
local _sotfCastSpellId = nil   -- spellID of the empowered cast (for Rampant Growth detection)
-- Hard cap on distinct UNITS hit per empowered cast.
-- Power of the Archdruid always picks 3 different targets.
-- A single unit can receive multiple empowered auras (e.g. Rejuv refresh
-- + Germination add) but only counts once toward the cap.
local _sotfMaxCount  = 1       -- 1 without Archdruid, 3 with
local _sotfUnitsHit  = {}      -- unit -> true for units already counted
local _sotfUnitsHitCount = 0   -- count of entries in _sotfUnitsHit
local _sotfTimer     = nil     -- safety timeout handle
local _convokeActive = false   -- true while Convoke the Spirits is channeling

-- Tracks the target unit AND spellId of the non-empowered cast.
-- Only the UNIT_AURA for this specific unit will clear empowered marks.
local _nonEmpoweredTargetUnit = nil   -- unit token (e.g. "party2")
local _nonEmpoweredCastSpellId = nil  -- spellId that was cast
local _nonEmpoweredClearTimer = nil

-- Last UNIT_SPELLCAST_SENT target name + spellId, used to resolve
-- the target unit when UNIT_SPELLCAST_SUCCEEDED fires.
local _lastSentTargetName = nil
local _lastSentSpellId = nil

-- "unit:auraInstanceID" -> "unit:spellId" key for empowered auras currently active.
-- auraInstanceIDs are only unique per-unit, not globally, so the key must
-- include the unit token to avoid collisions.
local _empoweredIDs = {}

-- Reverse map: "unit:spellId" -> "unit:auraInstanceID" for empowered auras.
local _empoweredByUnitSpell = {}

-- Fast-path flag: true when _empoweredIDs has at least one entry.
-- Avoids next() call on every ApplySotFGlow invocation.
local _hasEmpowered = false

-- Gate flag for display-path callers. When false, BuffIcons /
-- UpdateCustomBuffContainers / SetupNewIcon skip the ApplySotFGlow call
-- entirely. Set true in Enable(), false in Disable().
-- Non-Druids / idle Druids / Druids without the talent pay zero per-icon
-- cost for SotF when this flag is false.
BF._sotfGlowActive = false

-- Rampant Growth: track which unit has the player's Lifebloom.
-- Updated in UNIT_AURA from addedAuras / removedAuraInstanceIDs.
local _lifeblooomUnit = nil        -- unit token, e.g. "party2"
local _lifeblooomInstanceID = nil  -- auraInstanceID of the active Lifebloom

-- ============================================================
-- PUBLIC API
-- ============================================================

-- Check if a given aura on a given unit is empowered.
-- Called from BuffIcons indicator which has the unit available.
function BF.IsEmpoweredSotFAura(unit, auraInstanceID)
    if not unit or not auraInstanceID then return false end
    return _empoweredIDs[unit .. ":" .. auraInstanceID] ~= nil
end

-- Stop whatever glow type is currently active on an icon.
local function StopSotFGlow(icon)
    if not icon._sotfGlow then return end
    local glowType = icon._sotfGlowType or "button"
    if glowType == "border" then
        icon._sotfBorderActive = nil
        -- Restore original border color
        local orig = icon._sotfOrigBorderColor
        if orig then
            BF.SetIconBorderColor(icon, orig[1], orig[2], orig[3], orig[4])
        else
            BF.SetIconBorderColor(icon, 0, 0, 0, 0.8)
        end
        icon._sotfOrigBorderColor = nil
    elseif LCG then
        if glowType == "pixel" then
            LCG.PixelGlow_Stop(icon, "sotf")
        elseif glowType == "autocast" then
            LCG.AutoCastGlow_Stop(icon, "sotf")
        elseif glowType == "proc" then
            LCG.ProcGlow_Stop(icon, "sotf")
        else
            LCG.ButtonGlow_Stop(icon)
        end
    end
    icon._sotfGlow = false
    icon._sotfGlowType = nil
    icon._sotfGlowColor = nil
end

-- Start the configured glow type on an icon.
local function StartSotFGlow(icon, glowColor, glowType)
    if glowType == "border" then
        -- Save current border color so we can restore it on stop
        if not icon._sotfOrigBorderColor and BF.SetIconBorderColor then
            local r, g, b, a = icon:GetBackdropBorderColor()
            if r then icon._sotfOrigBorderColor = { r, g, b, a } end
        end
        if BF.SetIconBorderColor then
            BF.SetIconBorderColor(icon, glowColor[1], glowColor[2], glowColor[3], glowColor[4] or 1)
        end
        icon._sotfBorderActive = true
        icon._sotfGlow = true
        icon._sotfGlowType = glowType
        icon._sotfGlowColor = glowColor
        return
    end
    if not LCG then return end
    local w, h = icon:GetSize()
    if not w or not h or w <= 0 or h <= 0 then return end
    local ok
    if glowType == "pixel" then
        -- PixelGlow_Start(r, color, N, frequency, length, th, xOffset, yOffset, border, key, frameLevel)
        -- Pixel-snapped params keyed on the icon's current size via
        -- BF.GetPixelGlowParamsForSize — math runs once per distinct
        -- size per session, every subsequent glow start is O(1).
        local N, lenArg, thArg
        if BF.GetPixelGlowParamsForSize then
            N, lenArg, thArg = BF.GetPixelGlowParamsForSize(icon.cachedSize or w)
        else
            N, lenArg, thArg = 8, 6, 1
        end
        ok = pcall(LCG.PixelGlow_Start, icon, glowColor, N, 0.4, lenArg, thArg, 0, 0, false, "sotf")
    elseif glowType == "autocast" then
        -- AutoCastGlow_Start(r, color, N, frequency, scale, xOffset, yOffset, key, frameLevel)
        ok = pcall(LCG.AutoCastGlow_Start, icon, glowColor, nil, 0.25, nil, nil, nil, "sotf")
    elseif glowType == "proc" then
        ok = pcall(LCG.ProcGlow_Start, icon, { color = glowColor, key = "sotf", duration = 0.8 })
    else
        -- ButtonGlow_Start(r, color, frequency, frameLevel)
        ok = pcall(LCG.ButtonGlow_Start, icon, glowColor, 0.25, nil)
    end
    if ok then
        icon._sotfGlow = true
        icon._sotfGlowType = glowType
        icon._sotfGlowColor = glowColor
    end
end

-- Called from BuffIcons and UpdateCustomBuffContainers on every
-- buff icon. Must be as cheap as possible on the common path.
function BF.ApplySotFGlow(icon, auraInstanceID)
    if not _hasEmpowered then
        if icon._sotfGlow then StopSotFGlow(icon) end
        return
    end

    -- ApplySotFGlow needs the unit to build the composite key.
    -- The unit is stored on the icon by BuffIcons as icon._sotfUnit.
    local iidKey = icon._sotfUnit and auraInstanceID and (icon._sotfUnit .. ":" .. auraInstanceID)
    if iidKey and _empoweredIDs[iidKey] ~= nil then
        -- Check per-spell glow settings and resolve color
        local unitSpellKey = _empoweredIDs[iidKey]
        local keySid = unitSpellKey and tonumber(unitSpellKey:match(":(%d+)$"))
        local p = BF.acDB and BF.acDB.profile
        local glowAllowed = false
        local glowColor = nil
        if p and keySid then
            if keySid == REGROWTH_ID then
                glowAllowed = p.sotfGlowRegrowth
                local c = p.sotfRegrowthColor
                if c then glowColor = { c.r, c.g, c.b, c.a or 1 } end
            elseif keySid == GERMINATION_ID then
                glowAllowed = p.sotfGlowRejuv
                local c = p.sotfGerminationColor
                if c then glowColor = { c.r, c.g, c.b, c.a or 1 } end
            else
                -- Rejuvenation (774)
                glowAllowed = p.sotfGlowRejuv
                local c = p.sotfRejuvColor
                if c then glowColor = { c.r, c.g, c.b, c.a or 1 } end
            end
        end
        if not glowAllowed then
            if icon._sotfGlow then StopSotFGlow(icon) end
            return
        end
        -- Determine glow type
        local glowType = p and p.sotfGlowType or "button"
        -- Check if glow needs restart (color, type, or opacity changed)
        local needsRestart = false
        if not icon._sotfGlow then
            needsRestart = true
        elseif icon._sotfGlowType ~= glowType then
            needsRestart = true
        elseif icon._sotfGlowColor and glowColor then
            local oc = icon._sotfGlowColor
            if oc[1] ~= glowColor[1] or oc[2] ~= glowColor[2] or oc[3] ~= glowColor[3] or oc[4] ~= glowColor[4] then
                needsRestart = true
            end
        elseif icon._sotfGlowColor ~= glowColor then
            needsRestart = true
        end
        if needsRestart then
            if icon._sotfGlow then StopSotFGlow(icon) end
            StartSotFGlow(icon, glowColor, glowType)
        end
    else
        if icon._sotfGlow then StopSotFGlow(icon) end
    end
end

-- ============================================================
-- TALENT CACHING
-- ============================================================
local function RefreshTalentCache()
    if BF.playerSpecID ~= 105 then
        _sotfTalented    = false
        _archdTalented   = false
        _rampantTalented = false
        return
    end
    _sotfTalented    = IsPlayerSpell(SOUL_OF_THE_FOREST_ID) or false
    _archdTalented   = IsPlayerSpell(POWER_OF_ARCHDRUID_ID) or false
    _rampantTalented = IsPlayerSpell(RAMPANT_GROWTH_ID) or false
end
BF._SotF_RefreshTalentCache = RefreshTalentCache

-- ============================================================
-- Helper: close the SotF window entirely
-- ============================================================
local function CloseSotFWindow()
    _sotfActive        = false
    _sotfCastConsumed  = false
    _sotfCastSpellId   = nil
    table.wipe(_sotfUnitsHit)
    _sotfUnitsHitCount = 0
    if _sotfTimer then _sotfTimer:Cancel(); _sotfTimer = nil end
end

-- Clear an empowered mark by its "unit:spellId" key.
-- The reverse map stores "unit:auraInstanceID" composite keys.
local function ClearEmpoweredByKey(unitSpellKey)
    local iidKey = _empoweredByUnitSpell[unitSpellKey]
    if iidKey and _empoweredIDs[iidKey] then
        _empoweredIDs[iidKey] = nil
        _empoweredByUnitSpell[unitSpellKey] = nil
        _hasEmpowered = next(_empoweredIDs) ~= nil
    end
end

-- ============================================================
-- UNIT_SPELLCAST_SENT / UNIT_SPELLCAST_SUCCEEDED
-- ============================================================
local _spellcastFrame = CreateFrame("Frame")
_spellcastFrame:Hide()

-- Forward declaration; filled after OnSpellcastSucceeded is defined.
local OnSpellcastEvent

-- Resolve a target name to a unit token by scanning roster units.
local function ResolveUnitFromName(name)
    if not name then return nil end
    if issecretvalue(name) then return nil end
    -- UNIT_SPELLCAST_SENT provides "Name-Realm" but UnitName returns
    -- just "Name" for same-realm players. Strip the realm suffix.
    local shortName = name:match("^([^%-]+)") or name
    -- Must return the roster unit token (e.g. "raid5") not "player",
    -- because UNIT_AURA fires with the roster token. In a raid the
    -- player is one of the raidN units; in a party "player" is correct
    -- since party units don't include the player.
    local n = GetNumGroupMembers()
    if n > 0 then
        if IsInRaid() then
            for i = 1, n do
                local u = "raid" .. i
                if UnitName(u) == shortName then return u end
            end
        else
            -- In a party, check party members first, then fall through
            -- to "player" below (party units don't include the player).
            for i = 1, n - 1 do
                local u = "party" .. i
                if UnitName(u) == shortName then return u end
            end
        end
    end
    if UnitName("player") == shortName then return "player" end
    return nil
end

local function OnSpellcastSucceeded(_, event, unit, _, spellID)
    if unit ~= "player" then return end

    if spellID == SWIFTMEND_ID then
        if not _sotfTalented then return end
        local p = BF.acDB and BF.acDB.profile
        if not p or not p.sotfGlowEnabled then return end

        _sotfActive        = true
        _sotfCastConsumed  = false
        _sotfMaxCount      = _archdTalented and 3 or 1
        table.wipe(_sotfUnitsHit)
        _sotfUnitsHitCount = 0
        _nonEmpoweredCastSpellId = nil
        _nonEmpoweredTargetUnit = nil

        if _sotfTimer then _sotfTimer:Cancel() end
        _sotfTimer = C_Timer.NewTimer(15, function()
            CloseSotFWindow()
        end)

    elseif CASTABLE_EMPOWERABLE[spellID] then
        if _sotfActive and not _sotfCastConsumed and not _convokeActive then
            -- FIRST Rejuv/Regrowth after Swiftmend: empowered cast.
            _sotfCastConsumed = true
            -- Track spell ID so Rampant Growth logic knows whether
            -- the empowered cast was Regrowth.
            _sotfCastSpellId = spellID
            _nonEmpoweredCastSpellId = nil
            _nonEmpoweredTargetUnit = nil
            -- Replace the 15s safety timer with a short marking window.
            -- All empowered aura events arrive within 1-2 frames of the cast.
            -- 0.5s is generous enough for server lag while preventing
            -- stale _sotfCastConsumed from marking random Rejuv refreshes.
            if _sotfTimer then _sotfTimer:Cancel() end
            _sotfTimer = C_Timer.NewTimer(0.5, function()
                CloseSotFWindow()
            end)
        elseif _sotfCastConsumed then
            -- SECOND Rejuv/Regrowth: close the marking window.
            CloseSotFWindow()
            if _hasEmpowered and _lastSentSpellId == spellID then
                _nonEmpoweredCastSpellId = spellID
                _nonEmpoweredTargetUnit = ResolveUnitFromName(_lastSentTargetName)
                if _nonEmpoweredClearTimer then _nonEmpoweredClearTimer:Cancel() end
                _nonEmpoweredClearTimer = C_Timer.After(0, function()
                    _nonEmpoweredCastSpellId = nil
                    _nonEmpoweredTargetUnit = nil
                    _nonEmpoweredClearTimer = nil
                end)
            end
        elseif not _sotfActive and _hasEmpowered then
            -- No SotF window open, but empowered auras exist.
            if _lastSentSpellId == spellID then
                _nonEmpoweredCastSpellId = spellID
                _nonEmpoweredTargetUnit = ResolveUnitFromName(_lastSentTargetName)
                if _nonEmpoweredClearTimer then _nonEmpoweredClearTimer:Cancel() end
                _nonEmpoweredClearTimer = C_Timer.After(0, function()
                    _nonEmpoweredCastSpellId = nil
                    _nonEmpoweredTargetUnit = nil
                    _nonEmpoweredClearTimer = nil
                end)
            end
        end
    end
end

-- Fill in the forward-declared OnSpellcastEvent.
OnSpellcastEvent = function(_, event, unit, ...)
    if unit ~= "player" then return end
    if event == "UNIT_SPELLCAST_SENT" then
        local targetName, _, spellID = ...
        if CASTABLE_EMPOWERABLE[spellID] then
            _lastSentTargetName = targetName
            _lastSentSpellId = spellID
        end
        return
    elseif event == "UNIT_SPELLCAST_CHANNEL_START" then
        local _, spellID = ...
        if spellID == CONVOKE_ID then
            local p = BF.acDB and BF.acDB.profile
            if p and p.sotfConvokeAsEmpowered and _sotfActive and not _sotfCastConsumed then
                -- User opted in: treat all Convoke Rejuv/Regrowth as empowered.
                -- Open the marking window as if the player cast Rejuv/Regrowth.
                _convokeActive = true
                _sotfCastConsumed = true
            else
                -- Default: Convoke can cast Swiftmend (granting SotF) and then
                -- consume it with Rejuv/Regrowth, all without individual SPELLCAST
                -- events. We can't track which applications are empowered, so close
                -- any open SotF window and suppress marking for the channel duration.
                _convokeActive = true
                if _sotfActive or _sotfCastConsumed then
                    CloseSotFWindow()
                end
            end
        end
        return
    elseif event == "UNIT_SPELLCAST_CHANNEL_STOP" then
        local _, spellID = ...
        if spellID == CONVOKE_ID then
            _convokeActive = false
            -- When Convoke ends with the opt-in marking mode, close the window
            -- so no further manual casts are incorrectly marked.
            if _sotfCastConsumed then
                CloseSotFWindow()
            end
        end
        return
    end
    -- UNIT_SPELLCAST_SUCCEEDED: args after unit are (castGUID, spellID)
    local castGUID, spellID = ...
    OnSpellcastSucceeded(nil, event, unit, castGUID, spellID)
end

-- ============================================================
-- UNIT_AURA LISTENER
-- ============================================================
local SotFAuraListener = {}

function SotFAuraListener:UNIT_AURA(event, unit, updateInfo)
    if not updateInfo then return end

    -- ── Lifebloom tracking (for Rampant Growth) ─────────────────
    if _rampantTalented then
        if updateInfo.addedAuras then
            for i = 1, #updateInfo.addedAuras do
                local aura = updateInfo.addedAuras[i]
                local sid = aura.spellId
                if sid and not issecretvalue(sid) and sid == LIFEBLOOM_ID then
                    local iid = aura.auraInstanceID
                    if iid and not issecretvalue(iid) then
                        _lifeblooomUnit = unit
                        _lifeblooomInstanceID = iid
                    end
                    break
                end
            end
        end
        if updateInfo.removedAuraInstanceIDs and _lifeblooomInstanceID and _lifeblooomUnit == unit then
            for i = 1, #updateInfo.removedAuraInstanceIDs do
                local rid = updateInfo.removedAuraInstanceIDs[i]
                if issecretvalue(rid) then break end
                if rid == _lifeblooomInstanceID then
                    _lifeblooomUnit = nil
                    _lifeblooomInstanceID = nil
                    break
                end
            end
        end
    end

    -- ── Empowered aura removal cleanup ─────────────────────
    -- Must also stop glows immediately because BuffIcons may have
    -- already run (before this handler) and applied the glow based on
    -- the now-stale _empoweredIDs entry.
    if _hasEmpowered and updateInfo.removedAuraInstanceIDs then
        local removed = updateInfo.removedAuraInstanceIDs
        for i = 1, #removed do
            local rid = removed[i]
            if issecretvalue(rid) then break end
            local ridKey = unit .. ":" .. rid
            if _empoweredIDs[ridKey] then
                local unitSpellKey = _empoweredIDs[ridKey]
                _empoweredIDs[ridKey] = nil
                if unitSpellKey and _empoweredByUnitSpell[unitSpellKey] == ridKey then
                    _empoweredByUnitSpell[unitSpellKey] = nil
                end
                _hasEmpowered = next(_empoweredIDs) ~= nil
                -- Immediately stop glows on all frames for this unit
                -- that were displaying the removed auraInstanceID.
                -- Iterate both regular buff slots and custom container
                -- icon pools — container icons use the same _sotfGlow /
                -- _sotfUnit / auraInstanceID conventions as regular buffs.
                --
                -- Gated by the cached skip flags so non-Druids and Druids
                -- whose HoTs all live in containers pay zero cost for the
                -- branch they don't need:
                --   * BF._sotfSkipRegularBuffs true  → no empowerable aura
                --     can ever be in buffFrames, so skip that walk.
                --   * _anyContainerHasSotFSpell false → no container holds
                --     an empowerable spell, so skip the pool walk.
                local sweepBuffs      = not BF._sotfSkipRegularBuffs
                local sweepContainers = BF._anyContainerHasSotFSpell
                if sweepBuffs or sweepContainers then
                    local bucket = BF.frames_of_unit and rawget(BF.frames_of_unit, unit)
                    if bucket then
                        for frame in next, bucket do
                            if sweepBuffs and frame.buffFrames then
                                for idx = 1, #frame.buffFrames do
                                    local icon = frame.buffFrames[idx]
                                    if icon and icon._sotfGlow and icon._sotfUnit == unit
                                        and icon.auraInstanceID == rid then
                                        StopSotFGlow(icon)
                                    end
                                end
                            end
                            if sweepContainers then
                                local pools = frame.SF_CustomContainerIcons
                                if pools then
                                    for _, pool in pairs(pools) do
                                        for idx = 1, #pool do
                                            local icon = pool[idx]
                                            if icon and icon._sotfGlow and icon._sotfUnit == unit
                                                and icon.auraInstanceID == rid then
                                                StopSotFGlow(icon)
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- ── Non-empowered overwrite detection ──────────────────────
    -- Also check the Lifebloom target when Rampant Growth is talented
    -- and the cast is Regrowth, because Rampant Growth bounces a
    -- regular Regrowth onto the Lifebloom target.
    local isOverwriteTarget = _nonEmpoweredTargetUnit == unit
    if not isOverwriteTarget and _rampantTalented
        and _nonEmpoweredCastSpellId == REGROWTH_ID
        and _lifeblooomUnit == unit then
        isOverwriteTarget = true
    end
    if _nonEmpoweredCastSpellId and isOverwriteTarget and _hasEmpowered then
        local castSid = _nonEmpoweredCastSpellId

        -- addedAuras: non-empowered cast replaced an empowered aura
        -- with a new auraInstanceID on the same unit+spell.
        if updateInfo.addedAuras then
            local added = updateInfo.addedAuras
            for i = 1, #added do
                local aura = added[i]
                local sid = aura.spellId
                if sid and not issecretvalue(sid) and EMPOWERABLE[sid] then
                    ClearEmpoweredByKey(unit .. ":" .. sid)
                end
            end
        end

        -- updatedAuraInstanceIDs: non-empowered cast refreshed an
        -- empowered aura (same auraInstanceID). Only check the specific
        -- spells this cast could have overwritten.
        if updateInfo.updatedAuraInstanceIDs then
            local updated = updateInfo.updatedAuraInstanceIDs

            -- Which spells could this cast overwrite?
            -- Rejuv (774) → Rejuv (774) or Germination (155777)
            -- Regrowth (8936) → Regrowth (8936)
            local spellsToCheck = { castSid }
            if castSid == REJUVENATION_ID then
                spellsToCheck[2] = GERMINATION_ID
            end

            for _, sid in ipairs(spellsToCheck) do
                local unitSpellKey = unit .. ":" .. sid
                local empIID = _empoweredByUnitSpell[unitSpellKey]
                if empIID and _empoweredIDs[empIID] then
                    -- empIID is "unit:auraInstanceID", extract the raw ID
                    local rawIID = tonumber(empIID:match(":(%d+)$"))
                    if rawIID then
                        -- Verify this specific ID is in the updated set
                        for i = 1, #updated do
                            local uid = updated[i]
                            if issecretvalue(uid) then break end
                            if uid == rawIID then
                                ClearEmpoweredByKey(unitSpellKey)
                                break
                            end
                        end
                    end
                end
            end
        end
    end

    -- ── Empowered marking ──────────────────────────────────────
    -- Runs after the empowered cast was detected and before the
    -- window is closed by the next cast.
    --
    -- Invariants enforced (per user spec):
    --   * SotF empowers AT MOST ONE aura per unit per cast.
    --     Rule: a single cast produces exactly one aura event on a
    --     unit (either one add OR one refresh, never both). Additional
    --     empowerable auras that appear in updatedAuraInstanceIDs
    --     during the same UNIT_AURA event are unrelated noise (HoT
    --     ticks, pandemic recalc, etc.) and must not be marked.
    --   * Per-cast unit cap: _sotfMaxCount distinct units
    --     (1 without Archdruid, 3 with). Rampant Growth bounce to the
    --     Lifebloom target is free (doesn't count toward the cap).
    --   * Applying a new empowerment to a unit NEVER clears any
    --     existing empowerment on that unit — regardless of spell
    --     class. Each empowered cast produces one empowerment; it
    --     doesn't remove others.
    --
    -- Winner selection (when multiple candidates appear):
    --   * Spell-ID compatibility filter: Rejuv cast → Rejuv/Germination
    --     only; Regrowth cast → Regrowth only.
    --   * If any candidate has a secret expirationTime → prefer Rejuv
    --     (only two possible empowerable spells in a Rejuv cast event,
    --     and one is always Rejuv in any ambiguous case).
    --   * Else → longest remaining duration wins (the aura WoW
    --     refreshed has been reset to full duration by the time
    --     UNIT_AURA fires; the non-refreshed one still shows its
    --     prior depleted remaining).
    --   * On exact duration tie → Rejuv > Germination.
    --
    -- If the winner is already correctly empowered (e.g. empowered
    -- Rejuv refreshed in place by a second empowered cast, same aIID)
    -- → no write, just count the unit. Otherwise mark the winner.
    -- Prior empowerments on this unit are never cleared here.
    if _sotfCastConsumed then
        local unitAlreadyCounted = _sotfUnitsHit[unit]

        -- Rampant Growth: an empowered Regrowth also applies to the
        -- Lifebloom target. That bounce should be marked but not count
        -- toward the unit cap. We detect it by comparing against the
        -- tracked Lifebloom unit (_lifeblooomUnit), updated above.
        -- Must check regardless of cap state — the bounce UNIT_AURA can
        -- arrive before other Archdruid targets, and counting it would
        -- steal a cap slot from a real Archdruid target.
        local isRampantBounce = false
        if _rampantTalented and _sotfCastSpellId == REGROWTH_ID
            and not unitAlreadyCounted and _lifeblooomUnit == unit then
            isRampantBounce = true
        end

        -- Gate checks. Skip marking if the per-unit or per-cast cap
        -- would be violated.
        local skipMarking = false
        if unitAlreadyCounted and not isRampantBounce then
            -- Per-unit cap: this unit already received its one empowered
            -- aura from this cast (in a previous UNIT_AURA event).
            skipMarking = true
        elseif not unitAlreadyCounted and _sotfUnitsHitCount >= _sotfMaxCount
            and not isRampantBounce then
            -- Per-cast cap reached; new units can't be added.
            skipMarking = true
        end

        if not skipMarking then
            -- Compatibility filter for the cast spell.
            local function isCompatibleSpell(sid)
                if _sotfCastSpellId == REJUVENATION_ID then
                    return sid == REJUVENATION_ID or sid == GERMINATION_ID
                elseif _sotfCastSpellId == REGROWTH_ID then
                    return sid == REGROWTH_ID
                end
                return false
            end

            -- Collect candidates. Each candidate:
            --   iidKey       = "unit:auraInstanceID"
            --   unitSpellKey = "unit:spellId"
            --   sid          = spellId
            --   remaining    = seconds remaining, or nil if secret
            local candidates = {}
            local anySecretExp = false

            -- addedAuras: fresh applications produced by the cast.
            if updateInfo.addedAuras then
                local added = updateInfo.addedAuras
                for i = 1, #added do
                    local aura = added[i]
                    if aura then
                        local sid = aura.spellId
                        local iid = aura.auraInstanceID
                        if sid and not issecretvalue(sid) and EMPOWERABLE[sid]
                            and isCompatibleSpell(sid)
                            and iid and not issecretvalue(iid) then
                            local exp = aura.expirationTime
                            local remaining
                            if exp == nil or issecretvalue(exp) then
                                anySecretExp = true
                                remaining = nil
                            else
                                remaining = exp - GetTime()
                            end
                            candidates[#candidates + 1] = {
                                iidKey       = unit .. ":" .. iid,
                                unitSpellKey = unit .. ":" .. sid,
                                sid          = sid,
                                remaining    = remaining,
                            }
                        end
                    end
                end
            end

            -- updatedAuraInstanceIDs: refreshes of existing auras.
            -- Dedup against addedAuras candidates by iidKey (one aura
            -- can in theory appear in both lists; ignore the duplicate).
            if updateInfo.updatedAuraInstanceIDs then
                local GetAuraData = C_UnitAuras.GetAuraDataByAuraInstanceID
                local updated = updateInfo.updatedAuraInstanceIDs
                for i = 1, #updated do
                    local id = updated[i]
                    if issecretvalue(id) then break end
                    local idKey = unit .. ":" .. id
                    local dup = false
                    for j = 1, #candidates do
                        if candidates[j].iidKey == idKey then
                            dup = true
                            break
                        end
                    end
                    if not dup then
                        local auraData = GetAuraData(unit, id)
                        if auraData then
                            local sid = auraData.spellId
                            if sid and not issecretvalue(sid) and EMPOWERABLE[sid]
                                and isCompatibleSpell(sid) then
                                local exp = auraData.expirationTime
                                local remaining
                                if exp == nil or issecretvalue(exp) then
                                    anySecretExp = true
                                    remaining = nil
                                else
                                    remaining = exp - GetTime()
                                end
                                candidates[#candidates + 1] = {
                                    iidKey       = idKey,
                                    unitSpellKey = unit .. ":" .. sid,
                                    sid          = sid,
                                    remaining    = remaining,
                                }
                            end
                        end
                    end
                end
            end

            if #candidates > 0 then
                -- Pick the winner.
                local winner
                if anySecretExp then
                    -- Any secret expirationTime → skip duration comparison,
                    -- prefer Rejuvenation.
                    for i = 1, #candidates do
                        if candidates[i].sid == REJUVENATION_ID then
                            winner = candidates[i]
                            break
                        end
                    end
                    if not winner then winner = candidates[1] end
                else
                    -- Longest remaining wins (refreshed aura has been
                    -- reset to full duration). On exact tie, Rejuv wins
                    -- over Germination.
                    winner = candidates[1]
                    for i = 2, #candidates do
                        local c = candidates[i]
                        if c.remaining > winner.remaining then
                            winner = c
                        elseif c.remaining == winner.remaining
                            and c.sid == REJUVENATION_ID
                            and winner.sid == GERMINATION_ID then
                            winner = c
                        end
                    end
                end

                -- If the winner is already correctly empowered, no
                -- write is needed — just count the unit. Otherwise
                -- mark it. Prior empowerments on this unit are NOT
                -- cleared (per user spec).
                if _empoweredIDs[winner.iidKey] ~= winner.unitSpellKey then
                    _empoweredIDs[winner.iidKey] = winner.unitSpellKey
                    _empoweredByUnitSpell[winner.unitSpellKey] = winner.iidKey
                    _hasEmpowered = true
                end

                if not unitAlreadyCounted and not isRampantBounce then
                    _sotfUnitsHit[unit] = true
                    _sotfUnitsHitCount = _sotfUnitsHitCount + 1
                end
            end
        end

        -- Once the cap is reached, close the marking window immediately.
        -- Without this, _sotfCastConsumed stays true until the 2nd
        -- cast or 15s timeout, and any Rejuv refresh on an uncounted
        -- unit during that period would be falsely marked.
        -- Exception: if Rampant Growth could still send a bounce to the
        -- Lifebloom target, keep the window open for that.
        if _sotfUnitsHitCount >= _sotfMaxCount then
            local rampantPending = _rampantTalented
                and _sotfCastSpellId == REGROWTH_ID
                and _lifeblooomUnit
                and not _sotfUnitsHit[_lifeblooomUnit]
            if not rampantPending then
                _sotfCastConsumed = false
                _sotfCastSpellId = nil
            end
        end
    end
end

-- ============================================================
-- ENABLE / DISABLE
-- ============================================================
local _enabled = false

local function Enable()
    if _enabled then return end
    _enabled = true
    _spellcastFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
    _spellcastFrame:RegisterEvent("UNIT_SPELLCAST_SENT")
    _spellcastFrame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_START")
    _spellcastFrame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_STOP")
    _spellcastFrame:SetScript("OnEvent", OnSpellcastEvent)
    BF.RegisterRosterUnitEvent(SotFAuraListener, "UNIT_AURA", "UNIT_AURA")
    -- Open the gate so display paths start calling ApplySotFGlow.
    BF._sotfGlowActive = true
end

-- Walks every active frame's buff slots and container icon pools and
-- stops any SotF glow currently running. Called from Disable() so the
-- gate can be closed without leaving orphan glows on screen.
-- Gated the same way as the UNIT_AURA removal sweep — if the per-path
-- skip flag was set while glows were running, we can't have started any
-- glow on that path, so skip the walk.
local function StopAllActiveGlows()
    if not BF.activeFrames then return end
    local sweepBuffs      = not BF._sotfSkipRegularBuffs
    local sweepContainers = BF._anyContainerHasSotFSpell
    if not (sweepBuffs or sweepContainers) then return end
    for frame in pairs(BF.activeFrames) do
        if sweepBuffs and frame.buffFrames then
            for i = 1, #frame.buffFrames do
                local icon = frame.buffFrames[i]
                if icon and icon._sotfGlow then StopSotFGlow(icon) end
            end
        end
        if sweepContainers then
            local pools = frame.SF_CustomContainerIcons
            if pools then
                for _, pool in pairs(pools) do
                    for i = 1, #pool do
                        local icon = pool[i]
                        if icon and icon._sotfGlow then StopSotFGlow(icon) end
                    end
                end
            end
        end
    end
end

local function Disable()
    if not _enabled then return end
    _enabled = false
    -- Close the gate before sweeping: prevents a concurrent display pass
    -- from starting a new glow between the sweep and the wipe.
    BF._sotfGlowActive = false
    StopAllActiveGlows()
    _spellcastFrame:UnregisterAllEvents()
    _spellcastFrame:SetScript("OnEvent", nil)
    BF.UnregisterRosterUnitEvent(SotFAuraListener, "UNIT_AURA")
    CloseSotFWindow()
    _convokeActive = false
    table.wipe(_empoweredIDs)
    table.wipe(_empoweredByUnitSpell)
    _hasEmpowered = false
    _nonEmpoweredCastSpellId = nil
    _nonEmpoweredTargetUnit = nil
    _lifeblooomUnit = nil
    _lifeblooomInstanceID = nil
    if _nonEmpoweredClearTimer then _nonEmpoweredClearTimer:Cancel(); _nonEmpoweredClearTimer = nil end
end

function BF.SotF_Sync()
    RefreshTalentCache()
    local p = BF.acDB and BF.acDB.profile
    local shouldEnable = (BF.playerSpecID == 105)
        and _sotfTalented
        and p and p.sotfGlowEnabled
    if shouldEnable then
        Enable()
    else
        Disable()
    end
end

-- ============================================================
-- HOOKS
-- ============================================================
do
    local origSpecChanged = BF.OnPlayerSpecChanged
    if origSpecChanged then
        BF.OnPlayerSpecChanged = function(self, ...)
            origSpecChanged(self, ...)
            BF.SotF_Sync()
        end
    end
end

do
    local origTalentUpdate = BF.PLAYER_TALENT_UPDATE
    if origTalentUpdate then
        BF.PLAYER_TALENT_UPDATE = function(self, ...)
            origTalentUpdate(self, ...)
            BF.SotF_Sync()
        end
    end
end
