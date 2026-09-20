-- ============================================================
-- BuzzardFrames: Core_ProfileAutoSwitch.lua
-- Auto-switch AceDB profiles based on the player's current spec
-- or assigned role. Called on spec change and role change events.
-- Extracted from Core.lua in the Core split refactor.
-- ============================================================
local BF = _G["BuzzardFrames"]

-- ============================================================
-- PROFILE AUTO-SWITCH
-- Follows Grid2's ReloadProfile() pattern: check if the current
-- spec/role maps to a different AceDB profile name and call
-- db:SetProfile() to switch the entire configuration.
-- Called on spec change and role change events.
-- ============================================================
function BF:ApplyProfileAutoSwitch(silent)
    local p = self.db.profile
    if not BF.db.global.enableProfileAutoSwitch then return end

    local mode = BF.db.global.profileAutoSwitchMode or "spec"
    local targetProfile

    if mode == "spec" then
        local specIndex = GetSpecialization and GetSpecialization()
        local specID = specIndex and GetSpecializationInfo and select(1, GetSpecializationInfo(specIndex))
        if specID then
            local specIDStr = tostring(specID)
            targetProfile = BF.db.global.specProfileAssignment and BF.db.global.specProfileAssignment[specIDStr]
        end
    elseif mode == "role" then
        local role = UnitGroupRolesAssigned and UnitGroupRolesAssigned("player") or "NONE"
        if role == "NONE" or role == "" then
            -- Outside a group, infer role from spec
            if self.playerSpecRole then
                role = self.playerSpecRole
            end
        end
        targetProfile = BF.db.global.roleProfileAssignment and BF.db.global.roleProfileAssignment[role]
    end

    -- Only switch if we have a valid target that differs from current.
    -- Check rpDB (the primary settings DB), not self.db (the parent DB
    -- whose profile is fixed and never switched).
    if not targetProfile or targetProfile == "" then return end
    if targetProfile == self.rpDB:GetCurrentProfile() then return end

    -- Verify the target profile actually exists in rpDB
    local profiles = self.rpDB:GetProfiles()
    local found = false
    for _, name in ipairs(profiles) do
        if name == targetProfile then found = true; break end
    end
    if not found then return end

    if not silent then
        print("|cffd3ff7dBuzzardFrames:|r Auto-switching to profile: " .. targetProfile)
    end

    -- Switch all module databases. The parent DB (self.db) is never
    -- switched — its profile is fixed and only holds db.global state.
    -- Auto-switch targets the five module DBs which hold actual settings.
    for _, db in ipairs({ self.rpDB, self.acDB, self.cfgDB, self.ufDB, self.icDB }) do
        db:SetProfile(targetProfile)
    end
end

