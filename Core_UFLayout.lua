-- ============================================================
-- BuzzardFrames: Core_UFLayout.lua
-- Unit frame layout system: positioning for player/target/focus/pet/
-- TOT/focusTarget and the player detached power/resource bars.
-- This is independent from the raid/party header layout system
-- (which lives in BFLayout.lua).
-- Extracted from Core.lua in the Core split refactor.
-- ============================================================
local BF = _G["BuzzardFrames"]

-- ============================================================
-- UNIT FRAME LAYOUT SYSTEM
-- Independent layout system for unit frame positioning.
-- Mirrors ApplyRoleSpecLayout but operates on ufLayouts.
-- ============================================================

-- Returns the active ufLayouts[id] table.
function BF:GetActiveUFLayoutProfile()
    local p = self.ufDB.profile
    local id = self._ufActiveLayout or p.activeUFLayout or "default"
    if not p.ufLayouts then return {} end
    if not p.ufLayouts[id] then id = "default" end
    return p.ufLayouts[id] or {}
end

-- Returns the current group type key for UF layout resolution.
-- Uses the same logic as GetTrueActiveTab().
function BF:GetUFGroupType()
    return self:GetTrueActiveTab()
end

-- Returns anchorX, anchorY for a unit frame.
-- If the frame is enabled in ufLayoutFrames, reads from the active
-- UF layout's group-type sub-table. Otherwise reads from the global
-- profile (p[unitKey].anchorX/Y or p.ouf*AnchorX/Y).
function BF:GetUFAnchor(unitKey)
    local p = self.ufDB.profile
    local lf = p.ufLayoutFrames or {}

    if lf[unitKey] then
        -- Per-layout positioning
        local layout = self:GetActiveUFLayoutProfile()
        -- All group types share a single position bucket. The
        -- separateUFByGroupType flag that used to select a per-group-type
        -- bucket here was removed 2026-08-15 (owner decision): it had been
        -- force-nil'd on every login, so this branch was unreachable and
        -- the "party" arm was the only live path.
        local gt = "party"
        local gtTable = layout[gt]
        if gtTable and gtTable[unitKey] then
            return gtTable[unitKey].anchorX, gtTable[unitKey].anchorY
        end
        -- No saved position in this layout/group-type yet: fall through to global
    end

    -- Global fallback
    if unitKey == "playerPowerBar" then
        return p.oufPowerBarAnchorX, p.oufPowerBarAnchorY
    elseif unitKey == "playerResourceBar" then
        return p.oufResourceBarAnchorX, p.oufResourceBarAnchorY
    else
        local uf = p[unitKey]
        if uf then return uf.anchorX, uf.anchorY end
    end
    return nil, nil
end

-- Saves anchorX, anchorY for a unit frame.
-- Writes to the active UF layout if the frame is enabled in ufLayoutFrames,
-- otherwise writes to the global profile.
--
-- When Setup Mode is active, also refreshes the UF test frame positions so
-- the test overlay tracks slider edits in real time. Drag handlers call
-- SetUFAnchor too, but they've already positioned the test anchor via the
-- native StartMoving/StopMovingOrSizing, so the refresh is a visual no-op
-- in that path (same saved position → same test-frame anchor).
function BF:SetUFAnchor(unitKey, x, y)
    local p = self.ufDB.profile
    local lf = p.ufLayoutFrames or {}

    if lf[unitKey] then
        local layout = self:GetActiveUFLayoutProfile()
        -- All group types share a single position bucket. The
        -- separateUFByGroupType flag that used to select a per-group-type
        -- bucket here was removed 2026-08-15 (owner decision): it had been
        -- force-nil'd on every login, so this branch was unreachable and
        -- the "party" arm was the only live path.
        local gt = "party"
        if not layout[gt] then layout[gt] = {} end
        layout[gt][unitKey] = { anchorX = x, anchorY = y }
    else
        -- Global fallback
        if unitKey == "playerPowerBar" then
            p.oufPowerBarAnchorX = x
            p.oufPowerBarAnchorY = y
        elseif unitKey == "playerResourceBar" then
            p.oufResourceBarAnchorX = x
            p.oufResourceBarAnchorY = y
        else
            p[unitKey] = p[unitKey] or {}
            p[unitKey].anchorX = x
            p[unitKey].anchorY = y
        end
    end

    -- Sync test-frame overlay to the new saved position when Setup Mode is on.
    -- ShowUFTestFrames re-reads anchors via GetUFAnchor (and direct profile
    -- reads for bars/castbars/IC), so the test frame for this unit will move
    -- to match. Guarded because ShowUFTestFrames would otherwise make test
    -- frames visible outside Setup Mode.
    if self.db and self.db.global and self.db.global.setupModeActive
       and self.ShowUFTestFrames then
        self:ShowUFTestFrames()
    end
end

-- Returns the detach state for a bar ("playerPowerBar" or "playerResourceBar").
-- When the bar is included in ufLayoutFrames, reads from the UF layout's
-- group-type sub-table. Otherwise reads from the global profile key.
function BF:GetUFDetachState(barKey)
    local p = self.ufDB.profile
    local lf = p.ufLayoutFrames or {}
    local profileKey = (barKey == "playerPowerBar") and "oufPowerBarDetached" or "oufResourceBarDetached"

    if lf[barKey] then
        local layout = self:GetActiveUFLayoutProfile()
        -- All group types share a single position bucket. The
        -- separateUFByGroupType flag that used to select a per-group-type
        -- bucket here was removed 2026-08-15 (owner decision): it had been
        -- force-nil'd on every login, so this branch was unreachable and
        -- the "party" arm was the only live path.
        local gt = "party"
        local gtTable = layout[gt]
        if gtTable and gtTable[barKey] and gtTable[barKey].detached ~= nil then
            return gtTable[barKey].detached
        end
        -- No saved detach state for this group-type: fall through to the
        -- global profile key so the bar stays detached when the user enters
        -- a different group context (e.g. party → raid instance).
    end

    return p[profileKey] == true
end

-- Saves the detach state for a bar.
function BF:SetUFDetachState(barKey, detached)
    local p = self.ufDB.profile
    local lf = p.ufLayoutFrames or {}
    local profileKey = (barKey == "playerPowerBar") and "oufPowerBarDetached" or "oufResourceBarDetached"

    -- Always write to the global key so the rest of the addon can read it
    p[profileKey] = detached

    if lf[barKey] then
        local layout = self:GetActiveUFLayoutProfile()
        -- All group types share a single position bucket. The
        -- separateUFByGroupType flag that used to select a per-group-type
        -- bucket here was removed 2026-08-15 (owner decision): it had been
        -- force-nil'd on every login, so this branch was unreachable and
        -- the "party" arm was the only live path.
        local gt = "party"
        if not layout[gt] then layout[gt] = {} end
        if not layout[gt][barKey] then layout[gt][barKey] = {} end
        layout[gt][barKey].detached = detached
    end
end

-- Re-anchors all unit frames from the current UF layout + group type.
-- Called after layout/group-type changes.
function BF:ApplyAllUFPositions()
    if InCombatLockdown() then return end
    local p = self.db.profile
    -- Layout functions (ApplyOUFResourceBarLayout, ApplyOUFDetachedPowerBarLayout)
    -- call GetUFDetachState directly to read the authoritative detach state,
    -- so no sync to the global profile keys is needed here.
    if self.oufPlayer         then self:ApplyOUFPlayerLayout() end
    if self.oufTarget         then self:ApplyOUFTargetLayout() end
    if self.oufFocus          then self:ApplyOUFFocusLayout() end
    if self.oufPet            then self:ApplyOUFPetLayout() end
    if self.oufTargetOfTarget then self:ApplyOUFTargetOfTargetLayout() end
    if self.oufFocusTarget    then self:ApplyOUFFocusTargetLayout() end
    -- Detached bars read their anchor inside their own layout functions,
    -- which are called by ApplyOUFPlayerLayout.
end

-- Resolve which UF layout should be active based on spec/role.
-- Mirrors ApplyRoleSpecLayout but operates on UF-specific keys.
function BF:ApplyUFRoleSpecLayout(silent)
    local p = self.ufDB.profile

    -- The GLOBAL assignment: what applies when no override does. The raid
    -- side resolves the same way -- instance-type slot first, then the
    -- role and spec overrides on top of it -- and this is the unit-frame
    -- counterpart of that slot.
    --
    -- There used to be an early return here that forced "default" whenever
    -- both override kinds were off, which meant a reader with no overrides
    -- could not keep a layout selected at all: the next role change, spec
    -- change or profile switch reverted it and said so in chat. The
    -- selection had nowhere to live, because the picker wrote the field
    -- this function overwrites. It has ufGlobalLayout now.
    local globalID = p.ufGlobalLayout
    if not (globalID and p.ufLayouts[globalID]) then globalID = "default" end

    local specID    = self.playerSpecID
    local specIDStr = specID and tostring(specID)

    local newID

    -- Spec-specific layout takes priority
    -- An entry with NO assignment is "use the global setting": it is in the
    -- list but declines to override, so it falls through rather than
    -- resolving to the Default layout. That used to read `assignedID =
    -- "default"`, which made "no opinion" and "the layout named Default"
    -- the same answer -- and with a Global assignment underneath, they are
    -- not.
    if p.enableUFSpecLayouts and specIDStr and p.ufSpecLayouts[specIDStr] then
        local assignedID = p.ufSpecLayoutAssignment and p.ufSpecLayoutAssignment[specIDStr]
        if assignedID and p.ufLayouts[assignedID] then
            newID = assignedID
        end
    end

    -- Fall back to role-specific layout.
    --
    -- Gated on ufRoleLayouts, the presence table, and not on the assignment
    -- alone: the assignment table is an AceDB default that always carries
    -- all three roles, so before this it resolved for every role the moment
    -- the switch was on -- there was no such thing as a role WITHOUT an
    -- override. The Layout Assignments tree lists overrides one entry at a
    -- time, so a role the reader has not added has to fall through to the
    -- Global assignment, the same way a spec without an entry always has.
    if not newID and p.enableUFRoleLayouts then
        local role = UnitGroupRolesAssigned and UnitGroupRolesAssigned("player") or "NONE"
        if role == "NONE" or role == "" then
            if self.playerSpecRole then role = self.playerSpecRole end
        end
        if p.ufRoleLayouts and p.ufRoleLayouts[role] then
            local assignedID = p.ufRoleLayoutAssignment and p.ufRoleLayoutAssignment[role]
            if assignedID and p.ufLayouts[assignedID] then
                newID = assignedID
            end
        end
    end

    -- No override matched: the Global assignment.
    if not newID then newID = globalID end

    local changed = (self._ufActiveLayout ~= newID)
    self._ufActiveLayout = newID
    p.activeUFLayout = newID

    if changed and not silent then
        if newID == "default" then
            print("|cffd3ff7dBuzzardFrames:|r UF Layout reverted to Default")
        else
            local layoutName = (p.ufLayouts[newID] and p.ufLayouts[newID].name) or "Default"
            print("|cffd3ff7dBuzzardFrames:|r UF Layout Applied: " .. layoutName)
        end
    end

    -- Always apply positions so that enabling/changing an assignment for the
    -- current spec takes effect immediately without requiring a reload.
    self:ApplyAllUFPositions()
    return newID
end

