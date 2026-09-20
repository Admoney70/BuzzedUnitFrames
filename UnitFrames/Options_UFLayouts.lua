-- ============================================================
-- BuzzardFrames: Options_UFLayouts.lua
-- Builds the "Unit Frame Layouts" nav-tab within the Unit Frames tree.
-- Two sub-tabs: Manage Layouts + Role/Spec Layouts.
-- Called from Options_oUF_Other.lua: BF:BuildUFLayoutsOptions(deps)
-- ============================================================
local BF = _G["BuzzardFrames"]

function BF:BuildUFLayoutsOptions(deps)
    local self             = deps.self
    local NotifyChangeSafe = deps.NotifyChangeSafe

    -- Build UF layouts dropdown values (id -> display name)
    local function ufLayoutValues()
        local p = self.ufDB.profile
        local activeID = self._ufActiveLayout or p.activeUFLayout or "default"
        local t = {}
        if not p.ufLayouts then return { default = "Default" } end
        for id, layout in pairs(p.ufLayouts) do
            if id == activeID then
                t[id] = "|cff76CC4B" .. layout.name .. "|r"
            else
                t[id] = layout.name
            end
        end
        return t
    end

    -- Generate a unique UF layout ID
    local function newUFLayoutID()
        local p = self.ufDB.profile
        if not p.ufLayouts then p.ufLayouts = {} end
        local i = 1
        repeat
            local id = "uflayout_" .. i
            if not p.ufLayouts[id] then return id end
            i = i + 1
        until false
    end

    -- Group type labels and values (mirrors the raid section exactly)
    local GT_LABELS = {
        party  = "Party",
        raid20 = "Raid (20 Man - Mythic)",
        raid30 = "Raid (30 Man - Normal/Heroic)",
        raid40 = "Raid (40 Man - Open World/PvP)",
    }

    local function groupTypeValues()
        local p = self.ufDB.profile
        local activeTab = self:GetTrueActiveTab()
        local function label(key, text)
            if key == activeTab then
                return "|cff76CC4B" .. text .. "|r"
            end
            return text
        end
        local t = { party = label("party", "Party") }
        t.raid40 = label("raid40", GT_LABELS.raid40)
        t.raid30 = label("raid30", GT_LABELS.raid30)
        t.raid20 = label("raid20", GT_LABELS.raid20)
        return t
    end

    -- Apply UF positions after layout or group type change
    local function applyPositions()
        if not InCombatLockdown() and self.ApplyAllUFPositions then
            self:ApplyAllUFPositions()
        end
    end

    -- Refresh UF test frames if setup mode is active
    local function refreshTestFrames()
        if not self.ShowUFTestFrames then return end
        if BF.db.global.setupModeActive then self:ShowUFTestFrames() end
    end

    return {
        type        = "group",
        name        = "Unit Frame Layouts",
        order       = 20,
        childGroups = "tab",
        hidden      = function() return not self.ufDB.profile.ptfEnabled end,
        args        = {
            -- ── Global controls at top (Setup Mode, Layout, Group Type) ───────
            setupModeBtn = {
                type = "execute",
                name = function()
                    return BF.db.global.setupModeActive and "Exit Setup Mode" or "Setup Mode"
                end,
                desc = "Enter or exit Setup Mode. Green positioning frames appear for each checked unit frame.",
                order = -10,
                width = "normal",
                disabled = InCombatLockdown,
                func = function()
                    if BF.db.global.setupModeActive then
                        self:ToggleSetupMode(false)
                    else
                        self:ToggleSetupMode(true)
                    end
                    NotifyChangeSafe()
                end,
            },
            ufLayoutSelect = {
                type   = "select",
                name   = "Layout",
                order  = -7,
                width  = "normal",
                values = ufLayoutValues,
                get    = function()
                    return self._ufActiveLayout or self.ufDB.profile.activeUFLayout or "default"
                end,
                set    = function(_, val)
                    if InCombatLockdown() then return end
                    self._ufActiveLayout = val
                    self.ufDB.profile.activeUFLayout = val
                    applyPositions()
                    -- Refresh UF test frames if setup mode is active
                    if self.ShowUFTestFrames and BF.db.global.setupModeActive then
                        self:ShowUFTestFrames()
                    end
                    NotifyChangeSafe()
                end,
                disabled = InCombatLockdown,
            },
            separateByGroupType = {
                type  = "toggle",
                name  = "Separate Configuration by Group Type",
                desc  = "When enabled, unit frame positions are saved separately for each group type (Party, Raid 20/30/40). When disabled, all group types share a single set of positions.",
                order = -6.5,
                width = "normal",
                -- Hidden pending reimplementation for the new layouts/profile
                -- structure. The underlying profile flag (separateUFByGroupType)
                -- is left untouched so the future implementation can migrate or
                -- reuse existing saved state.
                hidden = function() return true end,
                get   = function() return self.ufDB.profile.separateUFByGroupType == true end,
                set   = function(_, val)
                    self.ufDB.profile.separateUFByGroupType = val
                    applyPositions()
                    NotifyChangeSafe()
                end,
            },
            groupTypeSelect = {
                type     = "select",
                name     = "Modify Group Type",
                order    = -6,
                width    = "normal",
                disabled = InCombatLockdown,
                hidden   = function() return not self.ufDB.profile.separateUFByGroupType end,
                values   = groupTypeValues,
                get = function()
                    local current = self._modifyingGroupType or self:GetActiveTab()
                    if current ~= "party" then
                        local resolved = self:ResolveTier(current)
                        if resolved ~= current then
                            self._modifyingGroupType = resolved
                            return resolved
                        end
                    end
                    return current
                end,
                set = function(_, val)
                    local wasActive = BF.db.global.setupModeActive
                    if wasActive then
                        -- Save current test anchor position
                        if self.testAnchorFrame then
                            local x, y = self.testAnchorFrame:GetCenter()
                            if x and y then
                                local ux, uy = UIParent:GetCenter()
                                local oldModProfile = self:GetModifyingProfile()
                                if oldModProfile then
                                    oldModProfile.anchorX = x - ux
                                    oldModProfile.anchorY = y - uy
                                end
                            end
                        end
                        -- Tear down current setup mode
                        self:ToggleSetupMode(false, true)
                        -- Switch to new group type (shared with raid frames)
                        self._modifyingGroupType = val
                        self:InvalidateRaidProfileCache()
                        -- Rebuild setup mode for the new group type
                        self:ToggleSetupMode(true, true)
                    else
                        -- Not in setup mode: just update the shared group type pointer
                        self._modifyingGroupType = val
                    end
                    -- Refresh UF test frames for the new group type
                    if self.ShowUFTestFrames and BF.db.global.setupModeActive then
                        self:ShowUFTestFrames()
                    end
                    applyPositions()
                    NotifyChangeSafe()
                end,
            },

            -- ── Sub-tab 1: Manage Layouts ─────────────────────────────────────
            manageTab = {
                type  = "group",
                name  = "Manage Layouts",
                order = 1,
                args  = {
                    desc = {
                        type = "description", order = 0, width = "full",
                        name = "Unit Frame Layouts currently control positioning only. All other settings (size, colors, text, etc.) are shared across all layouts.\n\nCheck the frames below that should have per-layout positioning. Unchecked frames use a single global position.",
                    },
                    hdrFrames = { type="header", name="Include in Layout", order=10 },
                    frameDesc = {
                        type = "description", order = 11, width = "full",
                        name = "Checked frames will have their position saved per-layout and per-group-type. Unchecked frames use a single global position.",
                    },
                    ufPlayer = {
                        type = "toggle", name = "Player", order = 12,
                        get = function() return self.ufDB.profile.ufLayoutFrames and self.ufDB.profile.ufLayoutFrames.player end,
                        set = function(_, v) self.ufDB.profile.ufLayoutFrames = self.ufDB.profile.ufLayoutFrames or {}; self.ufDB.profile.ufLayoutFrames.player = v; refreshTestFrames() end,
                    },
                    ufPlayerPowerBar = {
                        type = "toggle", name = "Player Power Bar", order = 13,
                        desc = "Detached power bar position.",
                        get = function() return self.ufDB.profile.ufLayoutFrames and self.ufDB.profile.ufLayoutFrames.playerPowerBar end,
                        set = function(_, v) self.ufDB.profile.ufLayoutFrames = self.ufDB.profile.ufLayoutFrames or {}; self.ufDB.profile.ufLayoutFrames.playerPowerBar = v; refreshTestFrames() end,
                    },
                    ufPlayerResourceBar = {
                        type = "toggle", name = "Player Resource Bar", order = 14,
                        desc = "Detached resource bar position.",
                        get = function() return self.ufDB.profile.ufLayoutFrames and self.ufDB.profile.ufLayoutFrames.playerResourceBar end,
                        set = function(_, v) self.ufDB.profile.ufLayoutFrames = self.ufDB.profile.ufLayoutFrames or {}; self.ufDB.profile.ufLayoutFrames.playerResourceBar = v; refreshTestFrames() end,
                    },
                    ufTarget = {
                        type = "toggle", name = "Target", order = 15,
                        get = function() return self.ufDB.profile.ufLayoutFrames and self.ufDB.profile.ufLayoutFrames.target end,
                        set = function(_, v) self.ufDB.profile.ufLayoutFrames = self.ufDB.profile.ufLayoutFrames or {}; self.ufDB.profile.ufLayoutFrames.target = v; refreshTestFrames() end,
                    },
                    ufFocus = {
                        type = "toggle", name = "Focus", order = 16,
                        get = function() return self.ufDB.profile.ufLayoutFrames and self.ufDB.profile.ufLayoutFrames.focus end,
                        set = function(_, v) self.ufDB.profile.ufLayoutFrames = self.ufDB.profile.ufLayoutFrames or {}; self.ufDB.profile.ufLayoutFrames.focus = v; refreshTestFrames() end,
                    },
                    ufPet = {
                        type = "toggle", name = "Pet", order = 17,
                        get = function() return self.ufDB.profile.ufLayoutFrames and self.ufDB.profile.ufLayoutFrames.pet end,
                        set = function(_, v) self.ufDB.profile.ufLayoutFrames = self.ufDB.profile.ufLayoutFrames or {}; self.ufDB.profile.ufLayoutFrames.pet = v; refreshTestFrames() end,
                    },
                    ufTargetOfTarget = {
                        type = "toggle", name = "Target of Target", order = 18,
                        get = function() return self.ufDB.profile.ufLayoutFrames and self.ufDB.profile.ufLayoutFrames.targettarget end,
                        set = function(_, v) self.ufDB.profile.ufLayoutFrames = self.ufDB.profile.ufLayoutFrames or {}; self.ufDB.profile.ufLayoutFrames.targettarget = v; refreshTestFrames() end,
                    },
                    ufFocusTarget = {
                        type = "toggle", name = "Focus Target", order = 19,
                        get = function() return self.ufDB.profile.ufLayoutFrames and self.ufDB.profile.ufLayoutFrames.focustarget end,
                        set = function(_, v) self.ufDB.profile.ufLayoutFrames = self.ufDB.profile.ufLayoutFrames or {}; self.ufDB.profile.ufLayoutFrames.focustarget = v; refreshTestFrames() end,
                    },
                    ufBoss = {
                        type = "toggle", name = "Boss Frames", order = 20,
                        get = function() return self.ufDB.profile.ufLayoutFrames and self.ufDB.profile.ufLayoutFrames.boss end,
                        set = function(_, v) self.ufDB.profile.ufLayoutFrames = self.ufDB.profile.ufLayoutFrames or {}; self.ufDB.profile.ufLayoutFrames.boss = v; refreshTestFrames() end,
                    },
                },
            },
            -- ── Sub-tab 2: Role/Spec Layouts ──────────────────────────────────
            roleSpecTab = {
                type        = "group",
                name        = "Role/Spec Layouts",
                order       = 2,
                childGroups = "tab",
                args        = {
                    enableUFRoleLayouts = {
                        type  = "toggle",
                        name  = "Enable role-specific layouts",
                        order = -2,
                        width = "full",
                        get   = function() return self.ufDB.profile.enableUFRoleLayouts end,
                        set   = function(_, val)
                            self.ufDB.profile.enableUFRoleLayouts = val
                            if self.ApplyUFRoleSpecLayout then self:ApplyUFRoleSpecLayout() end
                            NotifyChangeSafe()
                        end,
                    },
                    enableUFSpecLayouts = {
                        type  = "toggle",
                        name  = "Enable spec-specific layouts",
                        order = -1,
                        width = "full",
                        get   = function() return self.ufDB.profile.enableUFSpecLayouts end,
                        set   = function(_, val)
                            self.ufDB.profile.enableUFSpecLayouts = val
                            if self.ApplyUFRoleSpecLayout then self:ApplyUFRoleSpecLayout() end
                            NotifyChangeSafe()
                        end,
                    },

                    -- ── Tab: Role Layouts ──────────────────────────────────
                    tabRoleLayouts = {
                        type   = "group",
                        name   = "Role Layouts",
                        order  = 1.5,
                        hidden = function() return not self.ufDB.profile.enableUFRoleLayouts end,
                        args   = {
                            specOverrideNote = {
                                type  = "description",
                                order = 0,
                                width = "full",
                                name  = function()
                                    local p = self.ufDB.profile
                                    if not p.enableUFSpecLayouts then return "" end
                                    local specIndex = GetSpecialization and GetSpecialization()
                                    local specID = specIndex and GetSpecializationInfo and tostring(select(1, GetSpecializationInfo(specIndex)))
                                    if specID and p.ufSpecLayouts[specID] and p.ufSpecLayoutAssignment and p.ufSpecLayoutAssignment[specID] then
                                        return "|cffff9900|TInterface\\DialogFrame\\UI-Dialog-Icon-AlertOther:14:14:0:0|t The current spec has an active spec-specific layout which overrides these settings.|r"
                                    end
                                    return ""
                                end,
                            },
                            roleHealerLayout = {
                                type   = "select",
                                name   = (CreateAtlasMarkup and CreateAtlasMarkup("roleicon-tiny-healer", 16, 16) or "") .. " Healer",
                                order  = 1,
                                width  = "normal",
                                values = ufLayoutValues,
                                get    = function() return self.ufDB.profile.ufRoleLayoutAssignment.HEALER end,
                                set    = function(_, val) self.ufDB.profile.ufRoleLayoutAssignment.HEALER = val; self:ApplyUFRoleSpecLayout() end,
                            },
                            roleTankLayout = {
                                type   = "select",
                                name   = (CreateAtlasMarkup and CreateAtlasMarkup("roleicon-tiny-tank", 16, 16) or "") .. " Tank",
                                order  = 2,
                                width  = "normal",
                                values = ufLayoutValues,
                                get    = function() return self.ufDB.profile.ufRoleLayoutAssignment.TANK end,
                                set    = function(_, val) self.ufDB.profile.ufRoleLayoutAssignment.TANK = val; self:ApplyUFRoleSpecLayout() end,
                            },
                            roleDpsLayout = {
                                type   = "select",
                                name   = (CreateAtlasMarkup and CreateAtlasMarkup("roleicon-tiny-dps", 16, 16) or "") .. " DPS",
                                order  = 3,
                                width  = "normal",
                                values = ufLayoutValues,
                                get    = function() return self.ufDB.profile.ufRoleLayoutAssignment.DAMAGER end,
                                set    = function(_, val) self.ufDB.profile.ufRoleLayoutAssignment.DAMAGER = val; self:ApplyUFRoleSpecLayout() end,
                            },
                        },
                    },

                    -- ── Tab: Create ────────────────────────────────────────
                    tabCreate = {
                        type  = "group",
                        name  = "Create",
                        order = 2,
                        args  = {
                            createCopyFrom = {
                                type   = "select",
                                name   = "Copy Settings From",
                                desc   = "Choose an existing layout to copy positions from. Defaults to Default.",
                                order  = 1,
                                width  = "normal",
                                values = ufLayoutValues,
                                get    = function() return self._ufCreateCopyFrom or self._ufActiveLayout or self.ufDB.profile.activeUFLayout or "default" end,
                                set    = function(_, val)
                                    self._ufCreateCopyFrom = val
                                    NotifyChangeSafe()
                                end,
                            },
                            createLayout = {
                                type  = "input",
                                name  = "Create Layout",
                                desc  = "Type a name and press Enter (or click OK) to create the new layout.",
                                order = 2,
                                width = "double",
                                get   = function() return "" end,
                                set   = function(_, val)
                                    if not val or val:match("^%s*$") then return end
                                    local p = self.ufDB.profile
                                    if not p.ufLayouts then p.ufLayouts = {} end
                                    for _, layout in pairs(p.ufLayouts) do
                                        if layout.name == val then
                                            print("BuzzardFrames: A UF layout named \"" .. val .. "\" already exists.")
                                            return
                                        end
                                    end
                                    local id = newUFLayoutID()
                                    local copyFrom = self._ufCreateCopyFrom or "default"
                                    if p.ufLayouts[copyFrom] then
                                        p.ufLayouts[id] = self:DeepCopy(p.ufLayouts[copyFrom])
                                        p.ufLayouts[id].name = val
                                        print("BuzzardFrames: Created UF layout \"" .. val .. "\" (copied from \"" .. p.ufLayouts[copyFrom].name .. "\")")
                                    else
                                        p.ufLayouts[id] = { name = val, party = {}, raid40 = {}, raid30 = {}, raid20 = {} }
                                        print("BuzzardFrames: Created UF layout \"" .. val .. "\"")
                                    end
                                    self._ufCreateCopyFrom = nil
                                    NotifyChangeSafe()
                                end,
                            },
                        },
                    },

                    -- ── Tab: Edit ──────────────────────────────────────────────
                    tabEdit = {
                        type  = "group",
                        name  = "Edit",
                        order = 3,
                        args  = {
                            renameHeader = { type = "header", name = "Rename Layout", order = 1 },
                            renameLayoutSelect = {
                                type   = "select",
                                name   = "Rename Layout",
                                desc   = "Select a layout to rename.",
                                order  = 2,
                                width  = "normal",
                                hidden = function()
                                    local p = self.ufDB.profile
                                    if not p.ufLayouts then return true end
                                    for id in pairs(p.ufLayouts) do
                                        if id ~= "default" then return false end
                                    end
                                    return true
                                end,
                                values = function()
                                    local p = self.ufDB.profile
                                    local t = {}
                                    for id, layout in pairs(p.ufLayouts or {}) do
                                        if id ~= "default" then t[id] = layout.name end
                                    end
                                    return t
                                end,
                                get = function()
                                    if self._ufRenameLayoutID and self.ufDB.profile.ufLayouts[self._ufRenameLayoutID] then
                                        return self._ufRenameLayoutID
                                    end
                                    return nil
                                end,
                                set = function(_, val)
                                    self._ufRenameLayoutID = val
                                    NotifyChangeSafe()
                                end,
                            },
                            noRenameNote = {
                                type   = "description",
                                name   = "No custom layouts to rename. Create a layout first.",
                                order  = 2.5,
                                hidden = function()
                                    local p = self.ufDB.profile
                                    if not p.ufLayouts then return false end
                                    for id in pairs(p.ufLayouts) do
                                        if id ~= "default" then return true end
                                    end
                                    return false
                                end,
                            },
                            renameLayoutInput = {
                                type   = "input",
                                name   = "New Name",
                                desc   = "Type a new name and press Enter (or click OK) to rename the selected layout.",
                                order  = 3,
                                width  = "double",
                                hidden = function() return not self._ufRenameLayoutID end,
                                get = function()
                                    local p = self.ufDB.profile
                                    local id = self._ufRenameLayoutID
                                    if id and p.ufLayouts and p.ufLayouts[id] then
                                        return p.ufLayouts[id].name
                                    end
                                    return ""
                                end,
                                set = function(_, val)
                                    if not val or val:match("^%s*$") then return end
                                    local p = self.ufDB.profile
                                    local id = self._ufRenameLayoutID
                                    if not id or not p.ufLayouts or not p.ufLayouts[id] then return end
                                    for oid, layout in pairs(p.ufLayouts) do
                                        if oid ~= id and layout.name == val then
                                            print("BuzzardFrames: A UF layout named \"" .. val .. "\" already exists.")
                                            return
                                        end
                                    end
                                    local old_name = p.ufLayouts[id].name
                                    p.ufLayouts[id].name = val
                                    NotifyChangeSafe()
                                    print("BuzzardFrames: Renamed UF layout \"" .. old_name .. "\" to \"" .. val .. "\"")
                                end,
                            },
                        },
                    },

                    -- ── Tab: Remove ────────────────────────────────────────────
                    tabRemove = {
                        type  = "group",
                        name  = "Remove",
                        order = 4,
                        args  = {
                            removeLayout = {
                                type    = "select",
                                name    = "Remove Layout",
                                desc    = "Select a layout to permanently delete it.",
                                order   = 1,
                                width   = "normal",
                                confirm = function(info, val)
                                    local p = BF.ufDB.profile
                                    local name = p.ufLayouts and p.ufLayouts[val] and p.ufLayouts[val].name or val
                                    return "Are you sure you want to delete UF layout \"" .. name .. "\"? This cannot be undone."
                                end,
                                hidden = function()
                                    local p = self.ufDB.profile
                                    if not p.ufLayouts then return true end
                                    for id in pairs(p.ufLayouts) do
                                        if id ~= "default" then return false end
                                    end
                                    return true
                                end,
                                values = function()
                                    local p = self.ufDB.profile
                                    local t = {}
                                    for id, layout in pairs(p.ufLayouts or {}) do
                                        if id ~= "default" then t[id] = layout.name end
                                    end
                                    return t
                                end,
                                get = function() return nil end,
                                set = function(_, val)
                                    local p = self.ufDB.profile
                                    if not p.ufLayouts or not p.ufLayouts[val] then return end
                                    local name = p.ufLayouts[val].name or val
                                    -- Check if in use
                                    local usages = {}
                                    local roles = { HEALER = "Healer", TANK = "Tank", DAMAGER = "DPS" }
                                    if p.ufRoleLayoutAssignment then
                                        for roleKey, roleLabel in pairs(roles) do
                                            if p.ufRoleLayoutAssignment[roleKey] == val then
                                                table.insert(usages, "Role: " .. roleLabel)
                                            end
                                        end
                                    end
                                    if p.ufSpecLayoutAssignment then
                                        for specID, assignedLayout in pairs(p.ufSpecLayoutAssignment) do
                                            if assignedLayout == val and p.ufSpecLayouts and p.ufSpecLayouts[specID] then
                                                local s = BF.specByID[tonumber(specID)]
                                                local specName = s and s.name or ("Spec " .. specID)
                                                table.insert(usages, "Spec: " .. specName)
                                            end
                                        end
                                    end
                                    if #usages > 0 then
                                        local msg = "Cannot delete UF layout \"" .. name .. "\" — it is assigned in " .. #usages .. " place(s):\n"
                                        for _, u in ipairs(usages) do
                                            msg = msg .. "\n• " .. u
                                        end
                                        StaticPopup_Show("BUZZARDFRAMES_LAYOUT_IN_USE", msg)
                                        return
                                    end
                                    p.ufLayouts[val] = nil
                                    -- If the deleted layout was active, revert to default
                                    if self._ufActiveLayout == val then
                                        self._ufActiveLayout = "default"
                                        p.activeUFLayout = "default"
                                        applyPositions()
                                    end
                                    NotifyChangeSafe()
                                    print("BuzzardFrames: Removed UF layout \"" .. name .. "\"")
                                end,
                            },
                            noLayoutsNote = {
                                type   = "description",
                                name   = "No custom layouts to remove. The Default layout cannot be deleted.",
                                order  = 2,
                                hidden = function()
                                    local p = self.ufDB.profile
                                    if not p.ufLayouts then return false end
                                    for id in pairs(p.ufLayouts) do
                                        if id ~= "default" then return true end
                                    end
                                    return false
                                end,
                            },
                        },
                    },

                    -- ── Tab: Spec Layouts ──────────────────────────────────
                    tabSpecLayouts = {
                        type   = "group",
                        name   = "Spec Layouts",
                        order  = 1.6,
                        hidden = function() return not self.ufDB.profile.enableUFSpecLayouts end,
                        args   = {
                            specCreate = {
                                type   = "select",
                                name   = "Add Spec",
                                desc   = "Select a spec to add a layout assignment for it.",
                                order  = 1,
                                width  = "normal",
                                values = function()
                                    local t = {}
                                    for _, s in ipairs(BF.specData) do
                                        local id = tostring(s.id)
                                        if not self.ufDB.profile.ufSpecLayouts[id] then
                                            t[id] = "|T" .. s.icon .. ":14|t " .. s.name
                                        end
                                    end
                                    return t
                                end,
                                sorting = function()
                                    local keys = {}
                                    for _, s in ipairs(BF.specData) do
                                        local id = tostring(s.id)
                                        if not self.ufDB.profile.ufSpecLayouts[id] then
                                            keys[#keys+1] = id
                                        end
                                    end
                                    return keys
                                end,
                                get = function() return nil end,
                                set = function(_, val)
                                    self.ufDB.profile.ufSpecLayouts[val] = true
                                    self:ApplyUFRoleSpecLayout()
                                    NotifyChangeSafe()
                                end,
                            },
                            specRemove = {
                                type   = "select",
                                name   = "Remove Spec",
                                desc   = "Select a spec to remove its layout assignment.",
                                order  = 2,
                                width  = "normal",
                                hidden = function()
                                    for _ in pairs(self.ufDB.profile.ufSpecLayouts) do return false end
                                    return true
                                end,
                                values = function()
                                    local t = {}
                                    for id in pairs(self.ufDB.profile.ufSpecLayouts) do
                                        local s = BF.specByID[tonumber(id)]
                                        if s then t[id] = "|T" .. s.icon .. ":14|t " .. s.name end
                                    end
                                    return t
                                end,
                                sorting = function()
                                    local keys = {}
                                    for _, s in ipairs(BF.specData) do
                                        local id = tostring(s.id)
                                        if self.ufDB.profile.ufSpecLayouts[id] then
                                            keys[#keys+1] = id
                                        end
                                    end
                                    return keys
                                end,
                                get = function() return nil end,
                                set = function(_, val)
                                    self.ufDB.profile.ufSpecLayouts[val] = nil
                                    if self.ufDB.profile.ufSpecLayoutAssignment then
                                        self.ufDB.profile.ufSpecLayoutAssignment[val] = nil
                                    end
                                    self:ApplyUFRoleSpecLayout()
                                    NotifyChangeSafe()
                                end,
                            },
                            assignmentsHeader = {
                                type   = "header",
                                name   = "Layout Assignments",
                                order  = 3,
                                hidden = function()
                                    for _ in pairs(self.ufDB.profile.ufSpecLayouts) do return false end
                                    return true
                                end,
                            },
                            specLayoutsGroup = {
                                type   = "group",
                                name   = "",
                                order  = 4,
                                inline = true,
                                hidden = function()
                                    for _ in pairs(self.ufDB.profile.ufSpecLayouts) do return false end
                                    return true
                                end,
                                args = (function()
                                    local t = {}
                                    for i, s in ipairs(BF.specData) do
                                        local id = tostring(s.id)
                                        local icon = "|T" .. s.icon .. ":14|t "
                                        t["spec_" .. id] = {
                                            type   = "select",
                                            name   = icon .. s.name,
                                            order  = i,
                                            width  = "normal",
                                            hidden = function()
                                                return not self.ufDB.profile.ufSpecLayouts[id]
                                            end,
                                            values = ufLayoutValues,
                                            get    = function()
                                                local p = self.ufDB.profile
                                                if not p.ufSpecLayoutAssignment then p.ufSpecLayoutAssignment = {} end
                                                return p.ufSpecLayoutAssignment[id] or "default"
                                            end,
                                            set    = function(_, val)
                                                local p = self.ufDB.profile
                                                if not p.ufSpecLayoutAssignment then p.ufSpecLayoutAssignment = {} end
                                                p.ufSpecLayoutAssignment[id] = val
                                                self:ApplyUFRoleSpecLayout()
                                            end,
                                        }
                                    end
                                    return t
                                end)(),
                            },
                        },
                    },
                },
            },
        },
    }
end
