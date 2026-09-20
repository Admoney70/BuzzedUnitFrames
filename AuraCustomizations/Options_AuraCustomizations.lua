-- ============================================================
-- BuzzardFrames: Options_CustomAuras.lua
-- Builds and returns the "Custom Auras" nav-tab args table.
-- Called from Options.lua: BF:BuildCustomAurasOptions(deps)
-- ============================================================
local BF = _G["BuzzardFrames"]

-- ── Anchor point value table (shared by all position selects) ────────────
local ANCHOR_VALUES = {
    TOPLEFT    = "Top Left",    TOP    = "Top",    TOPRIGHT    = "Top Right",
    LEFT       = "Left",        CENTER = "Center", RIGHT       = "Right",
    BOTTOMLEFT = "Bottom Left", BOTTOM = "Bottom", BOTTOMRIGHT = "Bottom Right",
}

local GROW_VALUES = {
    LEFT  = "Left",
    RIGHT = "Right",
    UP    = "Up",
    DOWN  = "Down",
}

-- ── Healer specs ─────────────────────────────────────────────────────────
-- classColor: WoW class color hex (RRGGBB, no alpha prefix) for the spec name label
local HEALER_SPECS = {
    { id = 256,  name = "Discipline Priest",   tabName = "Discipline Priest",    classColor = "c2c2c2", tabPad = "   " },
    { id = 257,  name = "Holy Priest",         tabName = "Holy Priest",          classColor = "c2c2c2", tabPad = "       " },
    { id = 65,   name = "Holy Paladin",        tabName = "Holy Paladin",         classColor = "f48cba", tabPad = "      " },
    { id = 270,  name = "Mistweaver Monk",     tabName = "Mistweaver Monk",      classColor = "00ff98", tabPad = "    " },
    { id = 1473, name = "Augmentation Evoker", tabName = "Augmentation Evoker",  classColor = "33937f" },
    { id = 1468, name = "Preservation Evoker", tabName = "Preservation Evoker",  classColor = "33937f" },
    { id = 105,  name = "Restoration Druid",   tabName = "Resto Druid",          classColor = "ff7c0a" },
    { id = 264,  name = "Restoration Shaman",  tabName = "Resto Shaman",         classColor = "0070dd" },
}

-- Expose spec order for ShowDummyContainerAuras fallback
BF.HEALER_SPEC_ORDER = HEALER_SPECS

-- ── Spell list and untracked defaults: read from BF.SPEC_SPELLS (defined in CustomAuras.lua)
local SPEC_SPELLS = BF.SPEC_SPELLS

-- DEFAULT_UNTRACKED: derived from BF.SPEC_SPELLS entries with untracked=true
local DEFAULT_UNTRACKED = {}
for specId, spells in pairs(SPEC_SPELLS) do
    for _, s in ipairs(spells) do
        if s.untracked then
            if not DEFAULT_UNTRACKED[specId] then DEFAULT_UNTRACKED[specId] = {} end
            DEFAULT_UNTRACKED[specId][s.id] = true
        end
    end
end

-- ── Per-spec args tables (module-level so closures always share one ref) ─
-- specTabArgs[specId]  ->  tree args for each spec tab (one entry per spell)
-- containerMgmtArgs    ->  global Container Management tab
local specTabArgs       = {}
local containerMgmtArgs = {}   -- single global table, not per-spec
local rebuildContainerMgmtArgs  -- forward declaration so buildContainerMgmtOptions can reference it

-- ── Helpers ──────────────────────────────────────────────────────────────

-- Any container at globalIndex (no spec filter — used by global mgmt tab)
local function getContainer(globalIndex)
    return BF:GetCustomBuffContainers()[globalIndex]
end

local function getSelectedSpells(c)
    if not c.selectedSpells then c.selectedSpells = {} end
    return c.selectedSpells
end

-- Container dropdown values for spell assignment.
-- Index 0 = "*Default*" (spell stays in regular buffs, unassigned).
-- Index 1..N = assign to that container.
local function buildContainerDropdownValues()
    local vals = { [0] = "|cffaaaaaa*Default*|r", [-1] = "|cffff6666Hide Icon|r" }
    local all = BF:GetCustomBuffContainers()
    for gi, c in ipairs(all) do
        local anchorLabel = ANCHOR_VALUES[c.anchorPoint or ""] or (c.anchorPoint or "No Anchor")
        vals[gi] = (c.name or tostring(gi)) .. " (" .. anchorLabel .. ")"
    end
    return vals
end

-- Returns the dropdown value for a spell:
--   -1 = Untracked, 0 = Default, N = container index
local function getAssignedContainerForSpell(sid, specId)
    local p = BF.acDB and BF.acDB.profile
    local assign = p and p.spellAssign and p.spellAssign[specId] and p.spellAssign[specId][sid]
    if assign == "untracked" then return -1 end
    if assign == "default"   then return 0  end
    if assign then
        -- "c:N" format
        local n = tonumber(assign:match("^c:(%d+)$"))
        if n then return n end
    end
    -- Not set by user: DEFAULT_UNTRACKED spells show as Untracked by default
    local defaultUntracked = DEFAULT_UNTRACKED[specId]
    if defaultUntracked and defaultUntracked[sid] then return -1 end
    return 0
end

-- Assigns spell sid to a container, marks it untracked, or sets to default.
local function assignSpellToContainer(sid, newGI, specId)
    local p = BF.acDB and BF.acDB.profile
    if not p then return end
    if not p.spellAssign then p.spellAssign = {} end
    if not p.spellAssign[specId] then p.spellAssign[specId] = {} end
    if newGI == -1 then
        p.spellAssign[specId][sid] = "untracked"
    elseif newGI == 0 then
        p.spellAssign[specId][sid] = "default"
    else
        p.spellAssign[specId][sid] = "c:" .. newGI
    end
    -- Sync selectedSpells on containers
    local all = BF:GetCustomBuffContainers()
    for gi, c in ipairs(all) do
        if c.selectedSpells then c.selectedSpells[sid] = nil end
    end
    if newGI > 0 and all[newGI] then
        getSelectedSpells(all[newGI])[sid] = true
    end
end

-- Per-container expanded state (transient, session-only)
local containerManageExpanded = {}

-- Shared editing group type (transient, session-only)
-- Used when separateGroupConfig is enabled to select which group type's
-- settings are being edited in the Container Management UI.
-- Shared across all containers so the selection persists when navigating.
-- Defaults to the current group type (raid key if in raid, "party" if in party).
local containerEditingGroupType = nil  -- nil = use current group type as default

-- Resolve the default editing group type.
-- Under the flat model this is the currently-editing flat
-- (BF._modifyingFlat). Falls back to flat_party if that's not
-- set or not present. If no flats exist at all (shouldn't
-- happen), returns "flat_party" as a dead-but-stable default.
local function getDefaultGroupType()
    local fl = BF.rpDB and BF.rpDB.profile and BF.rpDB.profile.layouts
               and BF.rpDB.profile.layouts.flatLayouts or {}
    local mf = BF._modifyingFlat
    if mf and fl[mf] then return mf end
    if fl.flat_party then return "flat_party" end
    -- Fall back to any existing flat
    for id in pairs(fl) do return id end
    return "flat_party"
end

local function getEditingGroupType()
    return containerEditingGroupType or getDefaultGroupType()
end

-- ── Group type dropdown helpers (shared by container & per-spell UI) ─────
-- Under the flat model: one entry per flat in flatLayouts,
-- plus one per enabled custom frame group.
local function buildGroupTypeValues()
    local vals = {}
    local fl = BF.rpDB and BF.rpDB.profile and BF.rpDB.profile.layouts
               and BF.rpDB.profile.layouts.flatLayouts or {}
    for id, flat in pairs(fl) do
        local typeTag = (flat.type == "party") and "Party" or "Raid"
        vals[id] = (flat.name or id) .. " (" .. typeTag .. ")"
    end
    -- Add enabled custom frame groups
    local cfGroups = BF:GetCustomFrameGroups()
    for i, group in ipairs(cfGroups) do
        if group.enabled ~= false then
            vals["cfGroup_" .. i] = "Custom Frame Group: " .. (group.name or ("Group " .. i))
        end
    end
    return vals
end
-- Stable display order: seeded flats first (flat_party,
-- flat_raid20/30/40), then user flats alphabetical, then CF groups.
local function buildGroupTypeSorting()
    local order = {}
    local fl = BF.rpDB and BF.rpDB.profile and BF.rpDB.profile.layouts
               and BF.rpDB.profile.layouts.flatLayouts or {}
    local seeded = { "flat_party", "flat_raid20", "flat_raid30", "flat_raid40" }
    local seen   = {}
    for _, id in ipairs(seeded) do
        if fl[id] then
            order[#order + 1] = id
            seen[id]          = true
        end
    end
    local extras = {}
    for id in pairs(fl) do
        if not seen[id] then extras[#extras + 1] = id end
    end
    table.sort(extras)
    for _, id in ipairs(extras) do order[#order + 1] = id end
    -- Custom frame groups after all flats
    local cfGroups = BF:GetCustomFrameGroups()
    for i, group in ipairs(cfGroups) do
        if group.enabled ~= false then
            order[#order + 1] = "cfGroup_" .. i
        end
    end
    return order
end

-- ── Build one container's management options (global, no spec filter) ───────
local function buildContainerMgmtOptions(globalIndex, NotifyChangeSafe)

    -- Resolve the effective settings source for this container.
    -- When separateGroupConfig is on and an editing group type is selected,
    -- returns the groupSettings sub-table (creating it if needed).
    -- Otherwise returns the container itself.
    local function getEffectiveSource(c)
        if c.separateGroupConfig then
            local key = getEditingGroupType()
            if not c.groupSettings then c.groupSettings = {} end
            if not c.groupSettings[key] then c.groupSettings[key] = {} end
            return c.groupSettings[key]
        end
        return c
    end

    -- Read a field from the effective source with fallback to container top-level.
    -- Used by hidden functions to check toggle states through the group settings.
    local function getField(fieldName)
        local c = getContainer(globalIndex)
        if not c then return nil end
        local s = getEffectiveSource(c)
        local val = s[fieldName]
        if val == nil and s ~= c then val = c[fieldName] end
        return val
    end

    local function get(info)
        local c = getContainer(globalIndex)
        if not c then return nil end
        local s = getEffectiveSource(c)
        local val = s[info[#info]]
        if val == nil and s ~= c then val = c[info[#info]] end
        return val
    end
    local function set(info, val)
        if InCombatLockdown() then return end
        local c = getContainer(globalIndex)
        if not c then return end
        local s = getEffectiveSource(c)
        s[info[#info]] = val
        BF:RefreshAllCustomContainers()
    end
    local function containerName()
        local c = getContainer(globalIndex)
        return c and c.name or tostring(globalIndex)
    end
    local function isManageExpanded()
        return containerManageExpanded[globalIndex] == true
    end
    -- Returns true when the container has separateGroupConfig on
    -- AND the selected group type has showForGroupType == false,
    -- meaning all non-global settings should be hidden.
    local function isGroupTypeHidden()
        local c = getContainer(globalIndex)
        if not c then return false end
        if not c.separateGroupConfig then return false end
        local key = getEditingGroupType()
        local gs = c.groupSettings and c.groupSettings[key]
        return gs and gs.showForGroupType == false
    end
    local args = {
        -- Refresh preview frames when entering this container tab so
        -- container icons update to show the correct spells/positions.
        _containerTabTracker = {
            type = "description", order = -1, width = "full",
            name = function()
                -- Mirror the top-level Custom Auras tracker
                -- (AuraCustomizations.lua:2942). Required because users
                -- can navigate directly into a container sub-tab from
                -- another root section (e.g. Custom Frame Groups → Tooltips),
                -- which leaves _currentSection stale and causes
                -- ShouldShowPreviewAuras to reject the section.
                if BF._currentSection ~= "customAuras" then
                    BF._currentSection = "customAuras"
                end
                if BF:GetPreviewContainerIndex() ~= globalIndex then
                    BF:SetContainerPreview(globalIndex)
                    if not InCombatLockdown() then
                        C_Timer.After(0, function()
                            if BF:IsPreviewingContainerMgmt() then
                                BF:ShowContainerPreviewOnAllFrames()
                            end
                        end)
                    end
                end
                return ""
            end,
        },
        -- ── Assigned spells (built as a single inline group below) ─────────

        -- ── Per-group-type configuration ──────────────────────────────────
        separateGroupConfig = {
            type = "toggle", name = "|cff87ceebEnable per-Layout configuration for this Container|r", order = 2.5, width = "full",
            desc = "Enabling this option will allow you to have different settings for each Layout (e.g. Party vs. Raid) or Custom Frame Group.",
            get = function()
                local c = getContainer(globalIndex)
                return c and c.separateGroupConfig or false
            end,
            set = function(_, val)
                if InCombatLockdown() then return end
                local c = getContainer(globalIndex)
                if not c then return end
                c.separateGroupConfig = val
                if val and not c.groupSettings then
                    c.groupSettings = {}
                end
                -- No need to initialize containerEditingGroupType here;
                -- getEditingGroupType() defaults to the current group type.
                BF:InvalidateClaimedSpellCache()
                BF:RefreshAllCustomContainers()
                NotifyChangeSafe()
            end,
            disabled = InCombatLockdown,
        },
        showInRegularBuffs = {
            type = "toggle", name = "Show assigned spells in default buff container", order = 2.75, width = "double",
            desc = "When enabled, spells assigned to this container will appear in the regular buff row for this group type instead of being hidden entirely.",
            hidden = function()
                local c = getContainer(globalIndex)
                if not c or not c.separateGroupConfig then return true end
                local key = getEditingGroupType()
                local gs = c.groupSettings and c.groupSettings[key]
                -- Only show this toggle when showForGroupType is off
                return not gs or gs.showForGroupType ~= false
            end,
            get = function()
                local c = getContainer(globalIndex)
                if not c or not c.separateGroupConfig then return false end
                local key = getEditingGroupType()
                local gs = c.groupSettings and c.groupSettings[key]
                return gs and gs.showInRegularBuffs == true
            end,
            set = function(_, val)
                if InCombatLockdown() then return end
                local c = getContainer(globalIndex)
                if not c then return end
                if not c.groupSettings then c.groupSettings = {} end
                local key = getEditingGroupType()
                if not c.groupSettings[key] then c.groupSettings[key] = {} end
                c.groupSettings[key].showInRegularBuffs = val
                BF:InvalidateClaimedSpellCache()
                BF:RefreshAllCustomContainers()
                NotifyChangeSafe()
            end,
            disabled = InCombatLockdown,
        },
        editingGroupType = {
            type = "select", name = "Layout/Custom Frame Group", order = 2.6, width = "normal",
            desc = "Select which Layout or Custom Frame Group to configure settings for.",
            hidden = function()
                local c = getContainer(globalIndex)
                return not c or not c.separateGroupConfig
            end,
            values = buildGroupTypeValues,
            sorting = buildGroupTypeSorting,
            get = function()
                return getEditingGroupType()
            end,
            set = function(_, val)
                containerEditingGroupType = val
                NotifyChangeSafe()
            end,
            disabled = InCombatLockdown,
        },
        showForGroupType = {
            type = "toggle", name = "Show this container for this Layout/Custom Frame Group", order = 2.7, width = "double",
            desc = "When disabled, this container will not appear on frames of the selected Layout or Custom Frame Group.",
            hidden = function()
                local c = getContainer(globalIndex)
                return not c or not c.separateGroupConfig
            end,
            get = function()
                local c = getContainer(globalIndex)
                if not c or not c.separateGroupConfig then return true end
                local key = getEditingGroupType()
                local gs = c.groupSettings and c.groupSettings[key]
                return not gs or gs.showForGroupType ~= false
            end,
            set = function(_, val)
                if InCombatLockdown() then return end
                local c = getContainer(globalIndex)
                if not c then return end
                if not c.groupSettings then c.groupSettings = {} end
                local key = getEditingGroupType()
                if not c.groupSettings[key] then c.groupSettings[key] = {} end
                c.groupSettings[key].showForGroupType = val
                -- Default showInRegularBuffs to true when hiding the container
                if not val and c.groupSettings[key].showInRegularBuffs == nil then
                    c.groupSettings[key].showInRegularBuffs = true
                end
                BF:InvalidateClaimedSpellCache()
                BF:RefreshAllCustomContainers()
                NotifyChangeSafe()
            end,
            disabled = InCombatLockdown,
        },
        -- ── Show toggles (only shown when separateGroupConfig is off) ──
        showGroup = {
            type = "group", name = "Show Container", inline = true, order = 4,
            hidden = function()
                local c = getContainer(globalIndex)
                return c and c.separateGroupConfig
            end,
            args = {
                showOnParty = {
                    type = "toggle", name = "Show on Party Frames", order = 1,
                    desc = "Show this container's icons on party frames.",
                    get = function()
                        local c = getContainer(globalIndex)
                        return not c or c.showOnParty ~= false
                    end,
                    set = function(_, val)
                        if InCombatLockdown() then return end
                        local c = getContainer(globalIndex)
                        if not c then return end
                        c.showOnParty = val
                        BF:RefreshAllCustomContainers()
                    end,
                    disabled = InCombatLockdown,
                },
                showOnRaid = {
                    type = "toggle", name = "Show on Raid Frames", order = 2,
                    desc = "Show this container's icons on raid frames.",
                    get = function()
                        local c = getContainer(globalIndex)
                        return not c or c.showOnRaid ~= false
                    end,
                    set = function(_, val)
                        if InCombatLockdown() then return end
                        local c = getContainer(globalIndex)
                        if not c then return end
                        c.showOnRaid = val
                        BF:RefreshAllCustomContainers()
                    end,
                    disabled = InCombatLockdown,
                },
                showOnCustomFrames = {
                    type = "toggle", name = "Show on Custom Frame Groups", order = 3,
                    desc = "Show this container's icons on custom frame group frames.",
                    get = function()
                        local c = getContainer(globalIndex)
                        return not c or c.showOnCustomFrames ~= false
                    end,
                    set = function(_, val)
                        if InCombatLockdown() then return end
                        local c = getContainer(globalIndex)
                        if not c then return end
                        c.showOnCustomFrames = val
                        BF:RefreshAllCustomContainers()
                    end,
                    disabled = InCombatLockdown,
                },
            },
        },

        manageContainerHeader = { type = "header", name = "Manage Container", order = 99 },
        manageContainer = {
            type = "execute",
            name = function()
                return isManageExpanded() and "[-] Manage Container" or "[+] Manage Container"
            end,
            order = 100, width = "normal",
            func = function()
                containerManageExpanded[globalIndex] = not isManageExpanded()
                NotifyChangeSafe()
            end,
            disabled = InCombatLockdown,
        },
        manageContainerSpacer = {
            type = "description", name = "", order = 100.5, width = "full",
            hidden = function() return not isManageExpanded() end,
        },
        containerName = {
            type = "input", name = "Rename Container",
            order = 101, width = "double",
            hidden = function() return not isManageExpanded() end,
            get = get,
            set = function(_, val)
                if InCombatLockdown() then return end
                local c = getContainer(globalIndex)
                if not c then return end
                c.name = val ~= "" and val or tostring(globalIndex)
                c.autoNamed = (val == "" or val == tostring(globalIndex)) or nil
                NotifyChangeSafe()
            end,
            disabled = InCombatLockdown,
        },
        removeContainer = {
            type = "execute", name = "Remove Container",
            order = 102, width = "normal",
            hidden = function() return not isManageExpanded() end,
            confirm = function()
                local c = getContainer(globalIndex)
                if not c or not c.selectedSpells then
                    return "Remove this custom buff container?"
                end
                -- Build a list of assigned spells grouped by spec
                -- spellId -> spell name lookup across all specs
                local spellNames = {}
                for _, spec in ipairs(HEALER_SPECS) do
                    for _, spell in ipairs(SPEC_SPELLS[spec.id] or {}) do
                        spellNames[spell.id] = spell.name
                    end
                end
                -- Collect assigned spells per spec name
                local bySpec = {}
                local specNameById = {}
                for _, spec in ipairs(HEALER_SPECS) do
                    specNameById[spec.id] = spec.name
                end
                local p = BF.acDB and BF.acDB.profile
                for sid, on in pairs(c.selectedSpells) do
                    if on then
                        -- Find which spec(s) own this spell
                        for _, spec in ipairs(HEALER_SPECS) do
                            local assign = p and p.spellAssign
                                and p.spellAssign[spec.id]
                                and p.spellAssign[spec.id][sid]
                            if assign and assign:match("^c:%d+$") then
                                local n = tonumber(assign:match("^c:(%d+)$"))
                                if n == globalIndex then
                                    local sname = spellNames[sid] or tostring(sid)
                                    local specName = spec.name
                                    if not bySpec[specName] then bySpec[specName] = {} end
                                    table.insert(bySpec[specName], sname)
                                end
                            end
                        end
                    end
                end
                -- If nothing is actually assigned, allow with simple prompt
                local hasAny = next(bySpec) ~= nil
                if not hasAny then
                    return "Remove this custom buff container?"
                end
                -- Build the blocking message
                local lines = { "Cannot remove: spells are assigned to this container.\n" }
                for specName, spells in pairs(bySpec) do
                    table.insert(lines, specName .. ": " .. table.concat(spells, ", "))
                end
                table.sort(lines, function(a, b)
                    -- keep the header line first
                    if a:sub(1,6) == "Cannot" then return true end
                    if b:sub(1,6) == "Cannot" then return false end
                    return a < b
                end)
                return table.concat(lines, "\n")
            end,
            func = function()
                if InCombatLockdown() then return end
                -- Block deletion if any spells are still assigned
                local c = getContainer(globalIndex)
                if c and c.selectedSpells then
                    for _, on in pairs(c.selectedSpells) do
                        if on then return end
                    end
                end
                BF:RemoveCustomBuffContainer(globalIndex)
                BF:RefreshAllCustomContainers()
                rebuildContainerMgmtArgs(NotifyChangeSafe)
                local remaining = #BF:GetCustomBuffContainers()
                if remaining > 0 then
                    local navTo = math.min(globalIndex, remaining)
                    local ACD = LibStub("AceConfigDialog-3.0")
                    ACD:SelectGroup("BuzzardFrames", "customAuras", "tabContainerMgmt", "container_" .. navTo)
                end
            end,
            disabled = InCombatLockdown,
        },
        -- ── Position ──────────────────────────────────────────────────────
        positionGroup  = {
            type = "group", name = "Position", order = 6, inline = true,
            hidden = isGroupTypeHidden,
            args = {
                anchorPoint = { type = "select", name = "Anchor Point", order = 1, values = ANCHOR_VALUES, disabled = InCombatLockdown, get = get, set = set },
                offsetX     = { type = "range",  name = "X Offset",     order = 2, min = -60, max = 60, step = 1, disabled = InCombatLockdown, get = get, set = set },
                offsetY     = { type = "range",  name = "Y Offset",     order = 3, min = -60, max = 60, step = 1, disabled = InCombatLockdown, get = get, set = set },
            },
        },
        growDirection = { type = "select", name = "Grow Direction", order = 7, desc = "Direction icons expand when more than one row is needed.", values = GROW_VALUES,
            hidden = isGroupTypeHidden, disabled = InCombatLockdown, get = get, set = set },
        -- ── Appearance ────────────────────────────────────────────────────
        appearanceHeader = { type = "header", name = "Buff Size & Spacing", order = 10, hidden = isGroupTypeHidden },
        containerUsesBuffSettings = {
            type = "toggle", name = "|cFF87CEEB" .. "Override Buff Size & Spacing" .. "|r",
            desc = "When enabled, this container uses its own Icon Size, Max Icons, Icons Per Row, and Spacing instead of inheriting from the active Buffs settings.",
            order = 10.5, width = "full",
            hidden = isGroupTypeHidden,
            disabled = InCombatLockdown,
            get = function(info)
                local c = getContainer(globalIndex)
                if not c then return false end
                local s = getEffectiveSource(c)
                local val = s.containerUsesBuffSettings
                if val == nil and s ~= c then val = c.containerUsesBuffSettings end
                return val == false
            end,
            set = function(_, val)
                if InCombatLockdown() then return end
                local c = getContainer(globalIndex)
                if not c then return end
                local s = getEffectiveSource(c)
                s.containerUsesBuffSettings = not val
                BF:RefreshAllCustomContainers()
            end,
        },
        buffSize    = { type = "range", name = "Icon Size",     order = 11, min = 2,  max = 50, step = 1,
            hidden   = function() if isGroupTypeHidden() then return true end; return getField("containerUsesBuffSettings") ~= false end,
            disabled = InCombatLockdown,
            get = get, set = set },
        maxBuffs    = { type = "range", name = "Max Icons",     order = 12, min = 1,  max = 8,  step = 1,
            hidden   = function() if isGroupTypeHidden() then return true end; return getField("containerUsesBuffSettings") ~= false end,
            disabled = InCombatLockdown,
            get = get, set = set },
        buffsPerRow = { type = "range", name = "Icons Per Row", order = 13, min = 1,  max = 8,  step = 1,
            hidden   = function() if isGroupTypeHidden() then return true end; return getField("containerUsesBuffSettings") ~= false end,
            disabled = InCombatLockdown,
            get = get, set = set },
        spacingGroup = {
            type = "group", name = "Spacing", order = 14, inline = true,
            hidden = function() if isGroupTypeHidden() then return true end; return getField("containerUsesBuffSettings") ~= false end,
            args = {
                spacing    = { type = "range", name = "Icon Spacing", order = 1, desc = "Gap between icons within a row.", min = 0, max = 10, step = 1,
                    disabled = InCombatLockdown, get = get, set = set },
                rowSpacing = { type = "range", name = "Row Spacing",  order = 2, desc = "Gap between rows.",              min = 0, max = 10, step = 1,
                    disabled = InCombatLockdown, get = get, set = set },
            },
        },
    }

    -- Build the "Assigned Spells" inline group with per-spec entries
    -- separated by headers. Each spec gets a description for its name +
    -- a description for its spell list. A header separator appears between
    -- specs (but not before the first one).
    local assignedArgs = {
        noSpells = {
            type = "description", order = 0, width = "full",
            name = "|cffaaaaaa(No spells assigned to this container)|r",
            hidden = function()
                local p = BF.acDB and BF.acDB.profile
                if not p or not p.spellAssign then return false end
                for _, spec in ipairs(HEALER_SPECS) do
                    local assigns = p.spellAssign[spec.id]
                    if assigns then
                        for _, spell in ipairs(SPEC_SPELLS[spec.id] or {}) do
                            local val = assigns[spell.id]
                            if val then
                                local n = tonumber(type(val) == "string" and val:match("^c:(%d+)$"))
                                if n == globalIndex then return true end
                            end
                        end
                    end
                end
                return false
            end,
        },
    }
    for si, spec in ipairs(HEALER_SPECS) do
        local specId = spec.id
        local specName = spec.name
        local specColor = spec.classColor or "ffffff"
        local baseOrder = si * 10
        local function specHasSpells()
            local p = BF.acDB and BF.acDB.profile
            local assigns = p and p.spellAssign and p.spellAssign[specId]
            if not assigns then return false end
            for _, spell in ipairs(SPEC_SPELLS[specId] or {}) do
                local val = assigns[spell.id]
                if val then
                    local n = tonumber(type(val) == "string" and val:match("^c:(%d+)$"))
                    if n == globalIndex then return true end
                end
            end
            return false
        end
        -- Separator between specs (hidden if this is the first visible spec)
        assignedArgs["sep_" .. specId] = {
            type = "header", name = "", order = baseOrder - 1,
            hidden = function()
                if not specHasSpells() then return true end
                -- Hide if no earlier spec has spells (i.e. this is the first visible one)
                local p = BF.acDB and BF.acDB.profile
                for ei = 1, si - 1 do
                    local eSpecId = HEALER_SPECS[ei].id
                    local assigns = p and p.spellAssign and p.spellAssign[eSpecId]
                    if assigns then
                        for _, spell in ipairs(SPEC_SPELLS[eSpecId] or {}) do
                            local val = assigns[spell.id]
                            if val then
                                local n = tonumber(type(val) == "string" and val:match("^c:(%d+)$"))
                                if n == globalIndex then return false end
                            end
                        end
                    end
                end
                return true
            end,
        }
        -- Spec name label (clickable: navigates to the spec tab)
        assignedArgs["specLabel_" .. specId] = {
            type = "execute", order = baseOrder, width = "normal",
            hidden = function() return not specHasSpells() end,
            name = function()
                local data = BF.specByID and BF.specByID[specId]
                local icon = data and data.icon
                if icon then icon = icon:gsub("\\", "/") end
                local prefix = icon and ("|T" .. icon .. ":14:14:0:0|t ") or ""
                return prefix .. "|cff" .. specColor .. specName .. "|r"
            end,
            desc = function() return "Go to " .. specName .. " settings" end,
            func = function()
                local ACD = LibStub("AceConfigDialog-3.0")
                ACD:SelectGroup("BuzzardFrames", "customAuras", "tabHealerBuffs", "tabSpec_" .. specId)
            end,
        }
        -- Divider between spec button and spell buttons
        assignedArgs["divider_" .. specId] = {
            type = "description", order = baseOrder + 0.005, width = 0.1, fontSize = "large",
            hidden = function() return not specHasSpells() end,
            name = "  |cff888888|||r  ",
        }
        -- Spell buttons (clickable: one per spell in the spell list, hidden when
        -- that spell isn't assigned to this container). Pre-created at build
        -- time with stable keys so the AceConfig args table never has to be
        -- rebuilt when assignments change -- only the per-widget hidden()
        -- callback has to re-evaluate, matching how the rest of this UI works.
        for spi, spell in ipairs(SPEC_SPELLS[specId] or {}) do
            local sid = spell.id
            local spellIndex = spi
            local spellName = spell.name
            assignedArgs["spellBtn_" .. specId .. "_" .. spi] = {
                type = "execute", order = baseOrder + spi * 0.01, width = "normal",
                hidden = function()
                    if not specHasSpells() then return true end
                    local p = BF.acDB and BF.acDB.profile
                    local assigns = p and p.spellAssign and p.spellAssign[specId]
                    if not assigns then return true end
                    local val = assigns[sid]
                    if not val then return true end
                    local n = tonumber(type(val) == "string" and val:match("^c:(%d+)$"))
                    return n ~= globalIndex
                end,
                name = function()
                    local tex = spell.icon or C_Spell.GetSpellTexture(sid)
                    return tex and ("|T" .. tex .. ":14:14:0:0|t |cffffffff" .. spellName .. "|r") or ("|cffffffff" .. spellName .. "|r")
                end,
                desc = function() return "Go to " .. spellName .. " settings" end,
                func = function()
                    local ACD = LibStub("AceConfigDialog-3.0")
                    ACD:SelectGroup("BuzzardFrames", "customAuras", "tabHealerBuffs", "tabSpec_" .. specId, "spell_" .. spellIndex)
                end,
            }
        end
    end
    args.assignedSpells = {
        type = "group", inline = true, order = 0, name = "Assigned Spells",
        args = assignedArgs,
    }

    return {
        type  = "group",
        name  = containerName,
        order = globalIndex,
        args  = args,
    }
end

-- ── Rebuild the global Container Management args table ────────────────────
rebuildContainerMgmtArgs = function(NotifyChangeSafe)
    -- Clear stale container_N keys
    for k in pairs(containerMgmtArgs) do
        if k:match("^container_%d+$") then containerMgmtArgs[k] = nil end
    end

    -- When entering Container Management, set container preview mode and show
    -- container icons directly on all preview frames.
    containerMgmtArgs._clearSpellTracker = containerMgmtArgs._clearSpellTracker or {
        type = "description", order = -1, width = "full",
        name = function()
            local changed = false
            if BF:IsPreviewingSpell() then
                BF:ClearAuraPreview()
                changed = true
            end
            if not BF:IsPreviewingContainerMgmt() then
                BF:SetContainerPreview()
                changed = true
            end
            if changed and not InCombatLockdown() then
                C_Timer.After(0, function()
                    if BF:IsPreviewingContainerMgmt() then
                        BF:ShowContainerPreviewOnAllFrames()
                    end
                end)
            end
            return ""
        end,
    }

    containerMgmtArgs.addContainer = containerMgmtArgs.addContainer or {
        type = "execute", name = "Add Container", order = 0.5, width = "normal",
        func = function()
            if InCombatLockdown() then return end
            local _, newIndex = BF:CreateCustomBuffContainer()
            -- Eagerly rebuild so container_N exists in args before GroupExists check
            rebuildContainerMgmtArgs(NotifyChangeSafe)
            local ACD = LibStub("AceConfigDialog-3.0")
            ACD:SelectGroup("BuzzardFrames", "customAuras", "tabContainerMgmt", "container_" .. newIndex)
        end,
        disabled = InCombatLockdown,
    }

    containerMgmtArgs.noContainersNote = containerMgmtArgs.noContainersNote or {
        type = "description", order = 1, width = "full",
        name = "No containers yet. Click \"Add Container\" to create one.",
        hidden = function()
            return #BF:GetCustomBuffContainers() > 0
        end,
    }

    local all = BF:GetCustomBuffContainers()
    for gi = 1, #all do
        containerMgmtArgs["container_" .. gi] = buildContainerMgmtOptions(gi, NotifyChangeSafe)
    end
end

-- ── Build the args table for one spec tab ────────────────────────────────
-- All spells are always shown; no Add/Remove workflow needed.
local function rebuildSpecTabArgs(specId, NotifyChangeSafe)
    if not specTabArgs[specId] then specTabArgs[specId] = {} end
    local tArgs = specTabArgs[specId]

    -- Wipe stale spell entries
    for k in pairs(tArgs) do
        if k:match("^spell_%d+$") then tArgs[k] = nil end
    end
    -- Remove the old Add Spell group if present from a previous load
    tArgs.addSpellGroup = nil
    -- Wipe the buff filter group so it gets rebuilt fresh
    tArgs.buffFilterGroup = nil

    -- Per-spell cooldown text editing group type (shared across all spells in this spec tab).
    -- Reuses the module-level containerEditingGroupType so the layout selection
    -- is consistent across the entire options panel.

    -- Debounced refresh for per-spell cooldown text changes (color/threshold
    -- slider drags). Mirrors the container DebouncedCCRefresh pattern exactly.
    local _spellCTRefreshTimer = nil
    local function DebouncedSpellCTRefresh()
        if _spellCTRefreshTimer then _spellCTRefreshTimer:Cancel() end
        _spellCTRefreshTimer = C_Timer.NewTimer(0.05, function()
            _spellCTRefreshTimer = nil
            if BF.InvalidateContainerSettingsCache then BF.InvalidateContainerSettingsCache() end
            if BF.InvalidateContainerIconCaches    then BF.InvalidateContainerIconCaches()    end
            -- Same path as global threshold changes (Options_AuraText.lua):
            -- RebuildExpiringColorCurves + RefreshAllAuras. RefreshAllAuras
            -- calls Layout on every frame (re-stamps curve objects) then
            -- UpdateStandardAuras (re-runs all indicators).
            BF:RebuildExpiringColorCurves()
            BF:RefreshAllAuras()
            if BF.RefreshPreviewDummyContainers and not InCombatLockdown() then
                BF:RefreshPreviewDummyContainers()
            end
        end)
    end

    local spells = SPEC_SPELLS[specId] or {}
    for si, spell in ipairs(spells) do
        local sid = spell.id

        local function getSpecColors()
            local p = BF.acDB.profile
            if not p.specSpellColors then p.specSpellColors = {} end
            if not p.specSpellColors[specId] then p.specSpellColors[specId] = {} end
            return p.specSpellColors[specId]
        end

        tArgs["spell_" .. si] = {
            type  = "group",
            name  = (function()
                local tex = spell.icon or C_Spell.GetSpellTexture(sid)
                return tex and ("|T"..tex..":16:16:0:0|t "..spell.name) or spell.name
            end)(),
            desc  = "",
            order = 10 + si,
            childGroups = "tab",
            args  = {
                -- Spell preview tracker: fires when this spell's page is displayed
                _spellTracker = {
                    type = "description", order = 0, width = "full",
                    name = function()
                        local changed = (BF:GetPreviewSpellID() ~= sid or BF:GetPreviewSpecID() ~= specId)
                        if changed then
                            BF:SetSpellPreview(sid, specId)
                            if not InCombatLockdown() then
                                C_Timer.After(0, function()
                                    if BF:IsPreviewingSpell() and BF:GetPreviewSpellID() == sid then
                                        BF:ShowSpellPreviewOnAllFrames()
                                    end
                                end)
                            end
                        end
                        return ""
                    end,
                },
                -- ── Icon subtab ──────────────────────────────────────────
                iconTab = {
                    type = "group", name = "Icon", order = 1,
                    args = {
                -- Container assignment
                containerHeader = { type = "header", name = "Container", order = 1 },
                container = {
                    type     = "select",
                    name     = "Assign to Container",
                    desc     = "Select a container to track this spell in, or leave as *Default* to show it with regular buffs.",
                    order    = 2,
                    width    = "normal",
                    values   = buildContainerDropdownValues,
                    get      = function() return getAssignedContainerForSpell(sid, specId) end,
                    set      = function(_, newGI)
                        if InCombatLockdown() then return end
                        assignSpellToContainer(sid, newGI, specId)
                        BF:RefreshAllCustomContainersWithRebuild()
                        NotifyChangeSafe()
                    end,
                    disabled = InCombatLockdown,
                },
                containerGoto = {
                    type     = "execute",
                    name     = function()
                        local gi = getAssignedContainerForSpell(sid, specId)
                        if gi and gi > 0 then
                            local c = BF:GetCustomBuffContainers()[gi]
                            local cname = (c and c.name) or tostring(gi)
                            local anchorLabel = c and (ANCHOR_VALUES[c.anchorPoint or ""] or (c.anchorPoint or "No Anchor")) or ""
                            return "|cffffffff" .. cname .. " (" .. anchorLabel .. ") Settings|r"
                        end
                        return ""
                    end,
                    desc     = function()
                        local gi = getAssignedContainerForSpell(sid, specId)
                        if gi and gi > 0 then
                            local c = BF:GetCustomBuffContainers()[gi]
                            local cname = (c and c.name) or tostring(gi)
                            return "Go to " .. cname .. " settings"
                        end
                        return ""
                    end,
                    order    = 2.5,
                    width    = "normal",
                    hidden   = function()
                        local gi = getAssignedContainerForSpell(sid, specId)
                        return not (gi and gi > 0)
                    end,
                    func     = function()
                        local gi = getAssignedContainerForSpell(sid, specId)
                        if not (gi and gi > 0) then return end
                        local ACD = LibStub("AceConfigDialog-3.0")
                        ACD:SelectGroup("BuzzardFrames", "customAuras", "tabContainerMgmt", "container_" .. gi)
                    end,
                },
                addNewContainer = {
                    type     = "execute",
                    name     = "|cffffffffAdd to New Container|r",
                    desc     = "Create a new container and assign this spell to it.",
                    order    = 2.6,
                    width    = "normal",
                    hidden   = function()
                        local gi = getAssignedContainerForSpell(sid, specId)
                        return gi and gi > 0
                    end,
                    func     = function()
                        if InCombatLockdown() then return end
                        local _, newIndex = BF:CreateCustomBuffContainer()
                        assignSpellToContainer(sid, newIndex, specId)
                        rebuildContainerMgmtArgs(NotifyChangeSafe)
                        BF:RefreshAllCustomContainersWithRebuild()
                        local ACD = LibStub("AceConfigDialog-3.0")
                        ACD:SelectGroup("BuzzardFrames", "customAuras", "tabContainerMgmt", "container_" .. newIndex)
                        NotifyChangeSafe()
                    end,
                    disabled = InCombatLockdown,
                },
                -- Icon Type dropdown (replaces old solidIconEnabled + borderColorEnabled toggles)
                iconTypeHeader = { type = "header", name = "Buff Icon", order = 20 },
                iconType = {
                    type     = "select",
                    name     = "Icon Type",
                    desc     = "Icon: normal spell texture. Square: solid color square with no border. Bordered Square: solid color square with a border.",
                    order    = 21,
                    width    = "normal",
                    values   = { Icon = "Icon", Square = "Square", BorderedSquare = "Bordered Square" },
                    sorting  = { "Icon", "Square", "BorderedSquare" },
                    get      = function()
                        local p = BF.acDB.profile
                        local it = p.specSpellIconType and p.specSpellIconType[specId] and p.specSpellIconType[specId][sid]
                        return it or "Icon"
                    end,
                    set      = function(_, val)
                        if InCombatLockdown() then return end
                        local p = BF.acDB.profile
                        -- Store icon type
                        if not p.specSpellIconType then p.specSpellIconType = {} end
                        if not p.specSpellIconType[specId] then p.specSpellIconType[specId] = {} end
                        if val == "Icon" then
                            p.specSpellIconType[specId][sid] = nil
                        else
                            p.specSpellIconType[specId][sid] = val
                        end
                        -- Solid icon state
                        if not p.specSpellSolidIcons then p.specSpellSolidIcons = {} end
                        if not p.specSpellSolidIcons[specId] then p.specSpellSolidIcons[specId] = {} end
                        if val == "Icon" then
                            if p.specSpellSolidIcons[specId][sid] then
                                p.specSpellSolidIcons[specId][sid].enabled = false
                            end
                        else
                            if not p.specSpellSolidIcons[specId][sid] then
                                p.specSpellSolidIcons[specId][sid] = { r=0.0, g=0.7, b=1.0, a=1.0 }
                            else
                                p.specSpellSolidIcons[specId][sid].enabled = nil
                            end
                        end
                        BF:RefreshAllCustomContainersWithRebuild()
                        if BF.RefreshPreviewDummyAuras then BF:RefreshPreviewDummyAuras() end
                        NotifyChangeSafe()
                    end,
                    disabled = InCombatLockdown,
                },
                colorGroup = {
                    type   = "group",
                    name   = "Icon Color",
                    order  = 22,
                    inline = true,
                    hidden = function()
                        local p = BF.acDB.profile
                        local it = p.specSpellIconType and p.specSpellIconType[specId] and p.specSpellIconType[specId][sid]
                        return not it  -- hidden unless Square or BorderedSquare
                    end,
                    args = {
                        solidIconColor = {
                            type     = "color",
                            name     = "Icon Color",
                            order    = 1,
                            hasAlpha = true,
                            get      = function()
                                local p = BF.acDB.profile
                                local c = p.specSpellSolidIcons and p.specSpellSolidIcons[specId] and p.specSpellSolidIcons[specId][sid]
                                c = c or { r=0.0, g=0.7, b=1.0, a=1.0 }
                                return c.r, c.g, c.b, c.a or 1.0
                            end,
                            set      = function(_, r, g, b, a)
                                if InCombatLockdown() then return end
                                local p = BF.acDB.profile
                                if not p.specSpellSolidIcons then p.specSpellSolidIcons = {} end
                                if not p.specSpellSolidIcons[specId] then p.specSpellSolidIcons[specId] = {} end
                                if not p.specSpellSolidIcons[specId][sid] then p.specSpellSolidIcons[specId][sid] = {} end
                                p.specSpellSolidIcons[specId][sid].r = r
                                p.specSpellSolidIcons[specId][sid].g = g
                                p.specSpellSolidIcons[specId][sid].b = b
                                p.specSpellSolidIcons[specId][sid].a = a
                                -- Invalidate cached curve (Icon Color is the above-threshold color)
                                if BF._solidIconColorCurveCache then BF._solidIconColorCurveCache[sid] = nil end
                                BF:RefreshAllCustomContainersWithRebuild()
                                if BF.RefreshPreviewDummyAuras then BF:RefreshPreviewDummyAuras() end
                            end,
                            disabled = InCombatLockdown,
                        },
                        iconColorThresholdEnabled = {
                            type     = "toggle",
                            name     = "Change Color based on Remaining Time",
                            desc     = "When enabled, the icon color changes as the aura's remaining duration drops below the configured thresholds.",
                            order    = 2,
                            width    = "full",
                            get      = function()
                                local p = BF.acDB.profile
                                local entry = p.specSpellSolidIcons and p.specSpellSolidIcons[specId] and p.specSpellSolidIcons[specId][sid]
                                return entry and entry.thresholdEnabled
                            end,
                            set      = function(_, val)
                                if InCombatLockdown() then return end
                                local p = BF.acDB.profile
                                if not p.specSpellSolidIcons then p.specSpellSolidIcons = {} end
                                if not p.specSpellSolidIcons[specId] then p.specSpellSolidIcons[specId] = {} end
                                if not p.specSpellSolidIcons[specId][sid] then p.specSpellSolidIcons[specId][sid] = { r=0.0, g=0.7, b=1.0, a=1.0 } end
                                p.specSpellSolidIcons[specId][sid].thresholdEnabled = val or nil
                                -- Invalidate cached curve
                                if BF._solidIconColorCurveCache then BF._solidIconColorCurveCache[sid] = nil end
                                BF:RefreshAllCustomContainersWithRebuild()
                                if BF.RefreshPreviewDummyAuras then BF:RefreshPreviewDummyAuras() end
                                NotifyChangeSafe()
                            end,
                            disabled = InCombatLockdown,
                        },
                        thresholdColor = {
                            type     = "color",
                            name     = "Threshold Color",
                            order    = 3,
                            hasAlpha = true,
                            width    = "normal",
                            hidden   = function()
                                local p = BF.acDB.profile
                                local entry = p.specSpellSolidIcons and p.specSpellSolidIcons[specId] and p.specSpellSolidIcons[specId][sid]
                                return not (entry and entry.thresholdEnabled)
                            end,
                            get      = function()
                                local p = BF.acDB.profile
                                local entry = p.specSpellSolidIcons and p.specSpellSolidIcons[specId] and p.specSpellSolidIcons[specId][sid]
                                local r = entry and entry.thresholdR or 1.0
                                local g = entry and entry.thresholdG or 0.5
                                local b = entry and entry.thresholdB or 0.0
                                local a = entry and entry.thresholdA or 1.0
                                return r, g, b, a
                            end,
                            set      = function(_, r, g, b, a)
                                if InCombatLockdown() then return end
                                local p = BF.acDB.profile
                                local entry = p.specSpellSolidIcons[specId][sid]
                                entry.thresholdR = r
                                entry.thresholdG = g
                                entry.thresholdB = b
                                entry.thresholdA = a
                                if BF._solidIconColorCurveCache then BF._solidIconColorCurveCache[sid] = nil end
                                BF:RefreshAllCustomContainersWithRebuild()
                                if BF.RefreshPreviewDummyAuras then BF:RefreshPreviewDummyAuras() end
                            end,
                            disabled = InCombatLockdown,
                        },
                        thresholdSecs = {
                            type     = "range",
                            name     = "Threshold (seconds)",
                            desc     = "When the aura's remaining duration drops below this value, the icon switches to the Threshold Color.",
                            order    = 4,
                            min      = 1,
                            max      = 59,
                            step     = 1,
                            width    = "normal",
                            hidden   = function()
                                local p = BF.acDB.profile
                                local entry = p.specSpellSolidIcons and p.specSpellSolidIcons[specId] and p.specSpellSolidIcons[specId][sid]
                                return not (entry and entry.thresholdEnabled)
                            end,
                            get      = function()
                                local p = BF.acDB.profile
                                local entry = p.specSpellSolidIcons and p.specSpellSolidIcons[specId] and p.specSpellSolidIcons[specId][sid]
                                return entry and entry.thresholdSecs or 8
                            end,
                            set      = function(_, val)
                                if InCombatLockdown() then return end
                                local p = BF.acDB.profile
                                local entry = p.specSpellSolidIcons[specId][sid]
                                entry.thresholdSecs = val
                                -- Clamp secondary threshold so it never exceeds primary
                                if entry.secondarySecs and entry.secondarySecs >= val then
                                    entry.secondarySecs = val - 1
                                    if entry.secondarySecs < 1 then entry.secondarySecs = 1 end
                                end
                                if BF._solidIconColorCurveCache then BF._solidIconColorCurveCache[sid] = nil end
                                BF:RefreshAllCustomContainersWithRebuild()
                                if BF.RefreshPreviewDummyAuras then BF:RefreshPreviewDummyAuras() end
                            end,
                            disabled = InCombatLockdown,
                        },
                        secondaryEnabled = {
                            type     = "toggle",
                            name     = "Enable Secondary Threshold",
                            order    = 5,
                            width    = "full",
                            hidden   = function()
                                local p = BF.acDB.profile
                                local entry = p.specSpellSolidIcons and p.specSpellSolidIcons[specId] and p.specSpellSolidIcons[specId][sid]
                                return not (entry and entry.thresholdEnabled)
                            end,
                            get      = function()
                                local p = BF.acDB.profile
                                local entry = p.specSpellSolidIcons and p.specSpellSolidIcons[specId] and p.specSpellSolidIcons[specId][sid]
                                return entry and entry.secondaryEnabled
                            end,
                            set      = function(_, val)
                                if InCombatLockdown() then return end
                                local p = BF.acDB.profile
                                p.specSpellSolidIcons[specId][sid].secondaryEnabled = val or nil
                                if BF._solidIconColorCurveCache then BF._solidIconColorCurveCache[sid] = nil end
                                BF:RefreshAllCustomContainersWithRebuild()
                                if BF.RefreshPreviewDummyAuras then BF:RefreshPreviewDummyAuras() end
                                NotifyChangeSafe()
                            end,
                            disabled = InCombatLockdown,
                        },
                        secondaryColor = {
                            type     = "color",
                            name     = "Secondary Threshold Color",
                            order    = 6,
                            hasAlpha = true,
                            width    = "normal",
                            hidden   = function()
                                local p = BF.acDB.profile
                                local entry = p.specSpellSolidIcons and p.specSpellSolidIcons[specId] and p.specSpellSolidIcons[specId][sid]
                                return not (entry and entry.thresholdEnabled and entry.secondaryEnabled)
                            end,
                            get      = function()
                                local p = BF.acDB.profile
                                local entry = p.specSpellSolidIcons and p.specSpellSolidIcons[specId] and p.specSpellSolidIcons[specId][sid]
                                local r = entry and entry.secondaryR or 1.0
                                local g = entry and entry.secondaryG or 0.0
                                local b = entry and entry.secondaryB or 0.0
                                local a = entry and entry.secondaryA or 1.0
                                return r, g, b, a
                            end,
                            set      = function(_, r, g, b, a)
                                if InCombatLockdown() then return end
                                local p = BF.acDB.profile
                                local entry = p.specSpellSolidIcons[specId][sid]
                                entry.secondaryR = r
                                entry.secondaryG = g
                                entry.secondaryB = b
                                entry.secondaryA = a
                                if BF._solidIconColorCurveCache then BF._solidIconColorCurveCache[sid] = nil end
                                BF:RefreshAllCustomContainersWithRebuild()
                                if BF.RefreshPreviewDummyAuras then BF:RefreshPreviewDummyAuras() end
                            end,
                            disabled = InCombatLockdown,
                        },
                        secondarySecs = {
                            type     = "range",
                            name     = "Secondary Threshold (seconds)",
                            desc     = "When the aura's remaining duration drops below this value, the icon switches to the Secondary Threshold Color.",
                            order    = 7,
                            min      = 1,
                            max      = 58,
                            step     = 1,
                            width    = "normal",
                            hidden   = function()
                                local p = BF.acDB.profile
                                local entry = p.specSpellSolidIcons and p.specSpellSolidIcons[specId] and p.specSpellSolidIcons[specId][sid]
                                return not (entry and entry.thresholdEnabled and entry.secondaryEnabled)
                            end,
                            get      = function()
                                local p = BF.acDB.profile
                                local entry = p.specSpellSolidIcons and p.specSpellSolidIcons[specId] and p.specSpellSolidIcons[specId][sid]
                                local val = entry and entry.secondarySecs or 4
                                local primary = entry and entry.thresholdSecs or 8
                                if val >= primary then val = primary - 1 end
                                if val < 1 then val = 1 end
                                return val
                            end,
                            set      = function(_, val)
                                if InCombatLockdown() then return end
                                local p = BF.acDB.profile
                                local entry = p.specSpellSolidIcons[specId][sid]
                                local primary = entry.thresholdSecs or 8
                                if val >= primary then val = primary - 1 end
                                if val < 1 then val = 1 end
                                entry.secondarySecs = val
                                if BF._solidIconColorCurveCache then BF._solidIconColorCurveCache[sid] = nil end
                                BF:RefreshAllCustomContainersWithRebuild()
                                if BF.RefreshPreviewDummyAuras then BF:RefreshPreviewDummyAuras() end
                            end,
                            disabled = InCombatLockdown,
                        },
                    },
                },
                -- Border group (visible for Icon and Bordered Square, hidden for Square)
                borderGroup = {
                    type   = "group",
                    name   = "Border",
                    order  = 23,
                    inline = true,
                    hidden = function()
                        local p = BF.acDB.profile
                        local it = p.specSpellIconType and p.specSpellIconType[specId] and p.specSpellIconType[specId][sid]
                        return it == "Square"
                    end,
                    args = {
                        adjustBorderColor = {
                            type     = "toggle",
                            name     = "Adjust Border Color",
                            desc     = "Override the default border color for this spell's aura icon. Threshold timer colors will take priority when active.",
                            order    = 1,
                            width    = "normal",
                            get      = function()
                                local p = BF.acDB.profile
                                local entry = p.specSpellBorderColors and p.specSpellBorderColors[specId] and p.specSpellBorderColors[specId][sid]
                                return entry ~= nil and entry.enabled ~= false
                            end,
                            set      = function(_, val)
                                if InCombatLockdown() then return end
                                local p = BF.acDB.profile
                                if not p.specSpellBorderColors then p.specSpellBorderColors = {} end
                                if not p.specSpellBorderColors[specId] then p.specSpellBorderColors[specId] = {} end
                                if val then
                                    if not p.specSpellBorderColors[specId][sid] then
                                        p.specSpellBorderColors[specId][sid] = { r=1.0, g=1.0, b=1.0, a=1.0 }
                                    else
                                        p.specSpellBorderColors[specId][sid].enabled = nil
                                    end
                                else
                                    if p.specSpellBorderColors[specId][sid] then
                                        p.specSpellBorderColors[specId][sid].enabled = false
                                    end
                                end
                                BF:RefreshAllCustomContainersWithRebuild()
                                if BF.RefreshPreviewDummyAuras then BF:RefreshPreviewDummyAuras() end
                                NotifyChangeSafe()
                            end,
                            disabled = InCombatLockdown,
                        },
                        borderColor = {
                            type     = "color",
                            name     = "Border Color",
                            order    = 2,
                            hasAlpha = true,
                            hidden   = function()
                                local p = BF.acDB.profile
                                local entry = p.specSpellBorderColors and p.specSpellBorderColors[specId] and p.specSpellBorderColors[specId][sid]
                                return not entry or entry.enabled == false
                            end,
                            get      = function()
                                local p = BF.acDB.profile
                                local c = p.specSpellBorderColors and p.specSpellBorderColors[specId] and p.specSpellBorderColors[specId][sid]
                                c = c or { r=1.0, g=1.0, b=1.0, a=1.0 }
                                return c.r, c.g, c.b, c.a or 1.0
                            end,
                            set      = function(_, r, g, b, a)
                                if InCombatLockdown() then return end
                                local p = BF.acDB.profile
                                if not p.specSpellBorderColors then p.specSpellBorderColors = {} end
                                if not p.specSpellBorderColors[specId] then p.specSpellBorderColors[specId] = {} end
                                if not p.specSpellBorderColors[specId][sid] then p.specSpellBorderColors[specId][sid] = {} end
                                p.specSpellBorderColors[specId][sid].r = r
                                p.specSpellBorderColors[specId][sid].g = g
                                p.specSpellBorderColors[specId][sid].b = b
                                p.specSpellBorderColors[specId][sid].a = a
                                BF:RefreshAllCustomContainersWithRebuild()
                                if BF.RefreshPreviewDummyAuras then BF:RefreshPreviewDummyAuras() end
                            end,
                            disabled = InCombatLockdown,
                        },
                    },
                },
                -- Custom ordering
                orderingGroup = {
                    type = "group", name = "Custom Ordering", order = 10, inline = true,
                    args = {
                        orderingEnabled = {
                            type     = "toggle",
                            name     = "Pin to Slot Position",
                            desc     = "When enabled, this spell always appears at the chosen slot position in its container. Empty slots are left blank if the spell is not active.",
                            order    = 1,
                            width    = "normal",
                            get      = function()
                                local p = BF.acDB.profile
                                local entry = p.specSpellOrdering and p.specSpellOrdering[specId] and p.specSpellOrdering[specId][sid]
                                if not entry then return false end
                                if type(entry) == "number" then return true end  -- legacy format
                                return entry.enabled ~= false
                            end,
                            set      = function(_, val)
                                if InCombatLockdown() then return end
                                local p = BF.acDB.profile
                                if not p.specSpellOrdering then p.specSpellOrdering = {} end
                                if not p.specSpellOrdering[specId] then p.specSpellOrdering[specId] = {} end
                                local existing = p.specSpellOrdering[specId][sid]
                                if val then
                                    if not existing then
                                        p.specSpellOrdering[specId][sid] = { slot = 1 }
                                    elseif type(existing) == "table" then
                                        existing.enabled = nil  -- re-enable, keep slot
                                    end
                                    -- legacy number format: already enabled, no change needed
                                else
                                    if existing then
                                        if type(existing) == "number" then
                                            -- migrate legacy to table format so we can disable
                                            p.specSpellOrdering[specId][sid] = { slot = existing, enabled = false }
                                        else
                                            existing.enabled = false
                                        end
                                    end
                                end
                                BF:RefreshAllCustomContainersWithRebuild()
                                NotifyChangeSafe()
                            end,
                            disabled = InCombatLockdown,
                        },
                        orderingSlot = {
                            type     = "select",
                            name     = "Slot Position",
                            desc     = "The slot number this spell is pinned to.",
                            order    = 2,
                            width    = "normal",
                            hidden   = function()
                                local p = BF.acDB.profile
                                local entry = p.specSpellOrdering and p.specSpellOrdering[specId] and p.specSpellOrdering[specId][sid]
                                if not entry then return true end
                                if type(entry) == "number" then return false end
                                return entry.enabled == false
                            end,
                            values   = { [1]="1", [2]="2", [3]="3", [4]="4", [5]="5", [6]="6", [7]="7", [8]="8" },
                            get      = function()
                                local p = BF.acDB.profile
                                local entry = p.specSpellOrdering and p.specSpellOrdering[specId] and p.specSpellOrdering[specId][sid]
                                if not entry then return 1 end
                                if type(entry) == "number" then return entry end
                                return entry.slot or 1
                            end,
                            set      = function(_, val)
                                if InCombatLockdown() then return end
                                local p = BF.acDB.profile
                                if not p.specSpellOrdering then p.specSpellOrdering = {} end
                                if not p.specSpellOrdering[specId] then p.specSpellOrdering[specId] = {} end
                                local existing = p.specSpellOrdering[specId][sid]
                                if type(existing) == "number" then
                                    -- migrate legacy to table format
                                    p.specSpellOrdering[specId][sid] = { slot = val }
                                elseif type(existing) == "table" then
                                    existing.slot = val
                                else
                                    p.specSpellOrdering[specId][sid] = { slot = val }
                                end
                                BF:RefreshAllCustomContainersWithRebuild()
                                NotifyChangeSafe()
                            end,
                            disabled = InCombatLockdown,
                        },
                    },
                },
                    }, -- end iconTab.args
                }, -- end iconTab
                -- ── Cooldown Text subtab ────────────────────────────────────
                cdtTab = {
                    type = "group", name = "Cooldown Text", order = 1.5,
                    hidden = function() return getAssignedContainerForSpell(sid, specId) == -1 end,
                    args = {
                -- ── Per-Layout configuration ─────────────────────────────────
                cdtSeparateGroupConfig = {
                    type = "toggle", name = "|cff87ceebEnable per-Layout configuration for this section|r", order = 0.1, width = "full",
                    desc = "Enabling this option will allow you to have different settings for each Layout (e.g. Party vs. Raid) or Custom Frame Group.",
                    get = function()
                        local p = BF.acDB.profile
                        local ct = p.specSpellCooldownText and p.specSpellCooldownText[specId]
                        local entry = ct and ct[sid]
                        return entry and entry.separateGroupConfig or false
                    end,
                    set = function(_, val)
                        if InCombatLockdown() then return end
                        local p = BF.acDB.profile
                        if not p.specSpellCooldownText then p.specSpellCooldownText = {} end
                        if not p.specSpellCooldownText[specId] then p.specSpellCooldownText[specId] = {} end
                        if not p.specSpellCooldownText[specId][sid] then p.specSpellCooldownText[specId][sid] = {} end
                        p.specSpellCooldownText[specId][sid].separateGroupConfig = val
                        if val and not p.specSpellCooldownText[specId][sid].groupSettings then
                            p.specSpellCooldownText[specId][sid].groupSettings = {}
                        end
                        if BF.InvalidateContainerSettingsCache then BF.InvalidateContainerSettingsCache() end
                        BF:RefreshAllCustomContainersWithRebuild()
                        NotifyChangeSafe()
                    end,
                    disabled = InCombatLockdown,
                },
                cdtEditingGroupType = {
                    type = "select", name = "Layout/Custom Frame Group", order = 0.2, width = "normal",
                    desc = "Select which Layout or Custom Frame Group to configure settings for.",
                    hidden = function()
                        local p = BF.acDB.profile
                        local ct = p.specSpellCooldownText and p.specSpellCooldownText[specId]
                        local entry = ct and ct[sid]
                        return not entry or not entry.separateGroupConfig
                    end,
                    values = buildGroupTypeValues,
                    sorting = buildGroupTypeSorting,
                    get = function()
                        return getEditingGroupType()
                    end,
                    set = function(_, val)
                        containerEditingGroupType = val
                        NotifyChangeSafe()
                    end,
                    disabled = InCombatLockdown,
                },
                cdtEnabled = {
                    type = "toggle", name = "|cFF87CEEBOverride Aura Cooldown Text Settings|r",
                    desc = "When enabled, this spell uses its own duration text, scale, swipe, and spark settings instead of inheriting from the Aura Cooldown Text tab.",
                    order = 1, width = "full",
                    disabled = InCombatLockdown,
                    get = function()
                        local p = BF.acDB.profile
                        local ct = p.specSpellCooldownText and p.specSpellCooldownText[specId]
                        local entry = ct and ct[sid]
                        if not entry then return false end
                        -- Per-layout: check groupSettings[key].enabled
                        if entry.separateGroupConfig then
                            local gk = getEditingGroupType()
                            local gs = entry.groupSettings and entry.groupSettings[gk]
                            if gs then
                                return gs.enabled ~= false
                            end
                            -- No gs entry yet → not enabled for this layout
                            return false
                        end
                        return entry.enabled ~= false
                    end,
                    set = function(_, val)
                        if InCombatLockdown() then return end
                        local p = BF.acDB.profile
                        if not p.specSpellCooldownText then p.specSpellCooldownText = {} end
                        if not p.specSpellCooldownText[specId] then p.specSpellCooldownText[specId] = {} end
                        local isNew = not p.specSpellCooldownText[specId][sid]
                        if isNew then
                            p.specSpellCooldownText[specId][sid] = {}
                        end
                        local entry = p.specSpellCooldownText[specId][sid]
                        if entry.separateGroupConfig then
                            -- Per-layout: write to groupSettings[key].enabled
                            if not entry.groupSettings then entry.groupSettings = {} end
                            local gk = getEditingGroupType()
                            if val then
                                if not entry.groupSettings[gk] then
                                    entry.groupSettings[gk] = {}
                                else
                                    entry.groupSettings[gk].enabled = nil
                                end
                            else
                                if not entry.groupSettings[gk] then
                                    entry.groupSettings[gk] = { enabled = false }
                                else
                                    entry.groupSettings[gk].enabled = false
                                end
                            end
                        else
                            if val then
                                entry.enabled = nil
                            else
                                entry.enabled = false
                            end
                        end
                        -- Populate baseline values on first enable so UI toggles
                        -- match the inherited runtime behavior.
                        if val and isNew then
                            local ac = BF.AuraCache
                            if ac then
                                local target = entry
                                if entry.separateGroupConfig then
                                    local gk = getEditingGroupType()
                                    target = entry.groupSettings and entry.groupSettings[gk] or entry
                                end
                                if target.showDuration == nil then target.showDuration = ac.showBuffDuration ~= false end
                                if target.autoScale == nil then target.autoScale = ac.buffAutoScale == true end
                                if target.timerScale == nil then target.timerScale = ac.buffTimerScale or 1.0 end
                                if target.fontSize == nil then target.fontSize = ac.buffFontSize or 11 end
                                if target.disableSwipe == nil then target.disableSwipe = ac.disableBuffSwipe or false end
                                if target.disableSpark == nil then target.disableSpark = ac.disableBuffSpark or false end
                                if target.reverseSwipe == nil then target.reverseSwipe = ac.reverseBuffSwipe == true end
                                if target.colorAuraBorder == nil then target.colorAuraBorder = ac.buffColorAuraBorder == true end
                            end
                        end
                        BF:RebuildExpiringColorCurves()
                        if BF.InvalidateContainerSettingsCache then BF.InvalidateContainerSettingsCache() end
                        BF:RefreshAllCustomContainersWithRebuild()
                        NotifyChangeSafe()
                    end,
                },
                cdtSettingsGroup = {
                    type = "group", name = "", inline = true, order = 2,
                    hidden = function()
                        local p = BF.acDB.profile
                        local ct = p.specSpellCooldownText and p.specSpellCooldownText[specId]
                        local entry = ct and ct[sid]
                        if not entry then return true end
                        if entry.separateGroupConfig then
                            local gk = getEditingGroupType()
                            local gs = entry.groupSettings and entry.groupSettings[gk]
                            return not gs or gs.enabled == false
                        end
                        return entry.enabled == false
                    end,
                    args = (function()
                        -- Resolve the effective source for this spell's cooldown text.
                        -- When separateGroupConfig is on, returns the groupSettings sub-table.
                        local function getCdtEntry()
                            local p = BF.acDB.profile
                            local ct = p.specSpellCooldownText and p.specSpellCooldownText[specId]
                            return ct and ct[sid]
                        end
                        local function ensureCdtEntry()
                            local p = BF.acDB.profile
                            if not p.specSpellCooldownText then p.specSpellCooldownText = {} end
                            if not p.specSpellCooldownText[specId] then p.specSpellCooldownText[specId] = {} end
                            if not p.specSpellCooldownText[specId][sid] then p.specSpellCooldownText[specId][sid] = {} end
                            return p.specSpellCooldownText[specId][sid]
                        end
                        local function getCdtEffective()
                            local entry = getCdtEntry()
                            if not entry then return nil, nil end
                            if entry.separateGroupConfig then
                                local key = getEditingGroupType()
                                if not entry.groupSettings then entry.groupSettings = {} end
                                if not entry.groupSettings[key] then entry.groupSettings[key] = {} end
                                return entry.groupSettings[key], entry
                            end
                            return entry, entry
                        end
                        local function getCdtField(fieldName)
                            local s, entry = getCdtEffective()
                            if not s then return nil end
                            local val = s[fieldName]
                            if val == nil and s ~= entry then val = entry[fieldName] end
                            return val
                        end
                        local function cdtGet(info)
                            local s, entry = getCdtEffective()
                            if not s then return nil end
                            local val = s[info[#info]]
                            if val == nil and s ~= entry then val = entry[info[#info]] end
                            return val
                        end
                        local function cdtSet(info, val)
                            if InCombatLockdown() then return end
                            local entry = ensureCdtEntry()
                            local s
                            if entry.separateGroupConfig then
                                local key = getEditingGroupType()
                                if not entry.groupSettings then entry.groupSettings = {} end
                                if not entry.groupSettings[key] then entry.groupSettings[key] = {} end
                                s = entry.groupSettings[key]
                            else
                                s = entry
                            end
                            s[info[#info]] = val
                            if BF.InvalidateContainerSettingsCache then BF.InvalidateContainerSettingsCache() end
                            BF:RefreshAllCustomContainersWithRebuild()
                        end
                        return {
                            durationTextHeader = {
                                type = "header", name = "Duration Text", order = 1,
                            },
                            showDuration = {
                                type = "toggle", name = "Show Duration Numbers", order = 1.5,
                                disabled = InCombatLockdown,
                                get = cdtGet, set = cdtSet,
                            },
                            hideDurationAbove1Min = {
                                type = "toggle", name = "Hide Duration Text Above 1 Minute", order = 4.5, width = "full",
                                desc = "When enabled, the duration text is hidden when the remaining time is above 59 seconds.",
                                hidden = function() return getCdtField("showDuration") == false end,
                                disabled = InCombatLockdown,
                                get = cdtGet,
                                set = function(info, val)
                                    if InCombatLockdown() then return end
                                    local entry = ensureCdtEntry()
                                    local s
                                    if entry.separateGroupConfig then
                                        local key = getEditingGroupType()
                                        if not entry.groupSettings then entry.groupSettings = {} end
                                        if not entry.groupSettings[key] then entry.groupSettings[key] = {} end
                                        s = entry.groupSettings[key]
                                    else
                                        s = entry
                                    end
                                    s.hideDurationAbove1Min = val
                                    BF:RebuildExpiringColorCurves()
                                    if BF.InvalidateContainerSettingsCache then BF.InvalidateContainerSettingsCache() end
                                    BF:RefreshAllCustomContainersWithRebuild()
                                end,
                            },
                            autoScale = {
                                type = "toggle", name = "Auto Scale Duration Text", order = 2,
                                desc = "When enabled, duration text size scales proportionally with the aura icon size. Use the scale slider to fine-tune. When disabled, a fixed font size is used instead.",
                                hidden = function() return getCdtField("showDuration") == false end,
                                disabled = InCombatLockdown,
                                get = cdtGet, set = cdtSet,
                            },
                            timerScale = {
                                type = "range", name = "Duration Text Scale", order = 3,
                                min = 0.1, max = 3.0, step = 0.1,
                                hidden = function() return getCdtField("showDuration") == false or getCdtField("autoScale") ~= true end,
                                disabled = InCombatLockdown,
                                get = function()
                                    local s, entry = getCdtEffective()
                                    if not s then return 1.0 end
                                    local val = s.timerScale
                                    if val == nil and s ~= entry then val = entry.timerScale end
                                    return val or (BF.AuraCache and BF.AuraCache.buffTimerScale) or 1.0
                                end,
                                set = cdtSet,
                            },
                            fontSize = {
                                type = "range", name = "Font Size", order = 3,
                                min = 6, max = 24, step = 1,
                                hidden = function() return getCdtField("showDuration") == false or getCdtField("autoScale") == true end,
                                disabled = InCombatLockdown,
                                get = function()
                                    local s, entry = getCdtEffective()
                                    if not s then return 11 end
                                    local val = s.fontSize
                                    if val == nil and s ~= entry then val = entry.fontSize end
                                    return val or 11
                                end,
                                set = cdtSet,
                            },
                            durationFontGroup = {
                                type = "group", name = "Font", inline = true, order = 4,
                                hidden = function() return getCdtField("showDuration") == false end,
                                args = {
                                    durationFont = {
                                        type = "select", name = "Font", order = 1,
                                        disabled = InCombatLockdown,
                                        values = function()
                                            local LSM = LibStub("LibSharedMedia-3.0", true)
                                            local vals = { DEFAULT = "Game Default" }
                                            if LSM then for n, p in pairs(LSM:HashTable("font")) do vals[p] = n end end
                                            return vals
                                        end,
                                        get = function(info)
                                            local val = cdtGet(info)
                                            return val or "Interface\\AddOns\\BuzzardFrames\\Media\\Fonts\\RobotoCondensed-Bold.ttf"
                                        end,
                                        set = cdtSet,
                                    },
                                    durationBorder = {
                                        type = "select", name = "Font Border", order = 2,
                                        disabled = InCombatLockdown,
                                        values = {
                                            [""] = "None", ["OUTLINE"] = "Outline", ["THICKOUTLINE"] = "Thick Outline",
                                            ["MONOCHROME"] = "Monochrome", ["OUTLINE, MONOCHROME"] = "Outline + Monochrome",
                                            ["THICKOUTLINE, MONOCHROME"] = "Thick Outline + Monochrome",
                                        },
                                        get = function(info)
                                            local val = cdtGet(info)
                                            return val or ""
                                        end,
                                        set = cdtSet,
                                    },
                                },
                            },
                            colorGroup = {
                                type = "group", name = "Duration Numbers Color", inline = true, order = 5,
                                hidden = function() return getCdtField("showDuration") == false end,
                                args = {
                                    fontColor = {
                                        type = "color", name = "Duration Text Color", order = 1, hasAlpha = true,
                                        desc = "Color of the duration timer text. When Threshold Color is enabled, this is the color used above the threshold.",
                                        disabled = InCombatLockdown,
                                        get = function()
                                            local s, entry = getCdtEffective()
                                            if not s then return 1, 1, 1, 1 end
                                            local col = s.fontColor or (s ~= entry and entry.fontColor) or { r = 1, g = 1, b = 1 }
                                            return col.r, col.g, col.b, 1
                                        end,
                                        set = function(_, r, g, b)
                                            if InCombatLockdown() then return end
                                            local entry = ensureCdtEntry()
                                            local s
                                            if entry.separateGroupConfig then
                                                local key = getEditingGroupType()
                                                if not entry.groupSettings then entry.groupSettings = {} end
                                                if not entry.groupSettings[key] then entry.groupSettings[key] = {} end
                                                s = entry.groupSettings[key]
                                            else
                                                s = entry
                                            end
                                            s.fontColor = { r = r, g = g, b = b }
                                            DebouncedSpellCTRefresh()
                                        end,
                                    },
                                    colorAuraBorder = {
                                        type = "toggle", name = "Also Color Aura Borders", order = 2,
                                        desc = "When enabled, the icon border uses the Font Color. If Threshold Color is also enabled, the border uses the threshold colors below the threshold and the Font Color above it.",
                                        hidden = function()
                                            local p = BF.acDB.profile
                                            local it = p.specSpellIconType and p.specSpellIconType[specId] and p.specSpellIconType[specId][sid]
                                            return it == "Square"
                                        end,
                                        disabled = InCombatLockdown,
                                        get = cdtGet,
                                        set = function(info, val)
                                            if InCombatLockdown() then return end
                                            local entry = ensureCdtEntry()
                                            local s
                                            if entry.separateGroupConfig then
                                                local key = getEditingGroupType()
                                                if not entry.groupSettings then entry.groupSettings = {} end
                                                if not entry.groupSettings[key] then entry.groupSettings[key] = {} end
                                                s = entry.groupSettings[key]
                                            else
                                                s = entry
                                            end
                                            s.colorAuraBorder = val
                                            BF:RebuildExpiringColorCurves()
                                            if BF.InvalidateContainerSettingsCache then BF.InvalidateContainerSettingsCache() end
                                            BF:RefreshAllCustomContainersWithRebuild()
                                        end,
                                    },
                                    thresholdColorEnabled = {
                                        type = "toggle", name = "Change Color based on Remaining Time", order = 3,
                                        width = "full",
                                        disabled = InCombatLockdown,
                                        get = cdtGet,
                                        set = function(info, val)
                                            if InCombatLockdown() then return end
                                            local entry = ensureCdtEntry()
                                            local s
                                            if entry.separateGroupConfig then
                                                local key = getEditingGroupType()
                                                if not entry.groupSettings then entry.groupSettings = {} end
                                                if not entry.groupSettings[key] then entry.groupSettings[key] = {} end
                                                s = entry.groupSettings[key]
                                            else
                                                s = entry
                                            end
                                            s.thresholdColorEnabled = val
                                            BF:RebuildExpiringColorCurves()
                                            if BF.InvalidateContainerSettingsCache then BF.InvalidateContainerSettingsCache() end
                                            BF:RefreshAllCustomContainersWithRebuild()
                                        end,
                                    },
                                    thresholdColor = {
                                        type = "color", name = "Threshold Color", order = 4, hasAlpha = true,
                                        hidden = function() return not getCdtField("thresholdColorEnabled") end,
                                        disabled = InCombatLockdown,
                                        get = function()
                                            local s, entry = getCdtEffective()
                                            local dc = BF.DEFAULT_THRESHOLD_COLOR
                                            if not s then return dc.r, dc.g, dc.b, dc.a end
                                            local col = s.thresholdColor or (s ~= entry and entry.thresholdColor) or dc
                                            return col.r, col.g, col.b, col.a or 1
                                        end,
                                        set = function(_, r, g, b, a)
                                            if InCombatLockdown() then return end
                                            local entry = ensureCdtEntry()
                                            local s
                                            if entry.separateGroupConfig then
                                                local key = getEditingGroupType()
                                                if not entry.groupSettings then entry.groupSettings = {} end
                                                if not entry.groupSettings[key] then entry.groupSettings[key] = {} end
                                                s = entry.groupSettings[key]
                                            else
                                                s = entry
                                            end
                                            s.thresholdColor = { r = r, g = g, b = b, a = a }
                                            DebouncedSpellCTRefresh()
                                        end,
                                    },
                                    thresholdColorThreshold = {
                                        type = "range", name = "Threshold (seconds)", order = 5,
                                        min = 1, max = 59, step = 1,
                                        hidden = function() return not getCdtField("thresholdColorEnabled") end,
                                        disabled = InCombatLockdown,
                                        get = function()
                                            local s, entry = getCdtEffective()
                                            if not s then return 8 end
                                            local val = s.thresholdColorThreshold
                                            if val == nil and s ~= entry then val = entry.thresholdColorThreshold end
                                            return val or 8
                                        end,
                                        set = function(_, val)
                                            if InCombatLockdown() then return end
                                            local entry = ensureCdtEntry()
                                            local s
                                            if entry.separateGroupConfig then
                                                local key = getEditingGroupType()
                                                if not entry.groupSettings then entry.groupSettings = {} end
                                                if not entry.groupSettings[key] then entry.groupSettings[key] = {} end
                                                s = entry.groupSettings[key]
                                            else
                                                s = entry
                                            end
                                            s.thresholdColorThreshold = val
                                            -- Clamp secondary threshold so it stays below primary
                                            local t2 = s.threshold2ColorThreshold
                                            if t2 and t2 >= val then
                                                s.threshold2ColorThreshold = math.max(1, val - 1)
                                            end
                                            DebouncedSpellCTRefresh()
                                        end,
                                    },
                                    threshold2ColorEnabled = {
                                        type = "toggle", name = "Enable Secondary Threshold", order = 6,
                                        width = "full",
                                        hidden = function() return not getCdtField("thresholdColorEnabled") end,
                                        disabled = InCombatLockdown,
                                        get = cdtGet,
                                        set = function(info, val)
                                            if InCombatLockdown() then return end
                                            local entry = ensureCdtEntry()
                                            local s
                                            if entry.separateGroupConfig then
                                                local key = getEditingGroupType()
                                                if not entry.groupSettings then entry.groupSettings = {} end
                                                if not entry.groupSettings[key] then entry.groupSettings[key] = {} end
                                                s = entry.groupSettings[key]
                                            else
                                                s = entry
                                            end
                                            s.threshold2ColorEnabled = val
                                            BF:RebuildExpiringColorCurves()
                                            if BF.InvalidateContainerSettingsCache then BF.InvalidateContainerSettingsCache() end
                                            BF:RefreshAllCustomContainersWithRebuild()
                                        end,
                                    },
                                    threshold2Color = {
                                        type = "color", name = "Secondary Threshold Color", order = 7, hasAlpha = true,
                                        hidden = function() return not getCdtField("thresholdColorEnabled") or not getCdtField("threshold2ColorEnabled") end,
                                        disabled = InCombatLockdown,
                                        get = function()
                                            local s, entry = getCdtEffective()
                                            local dc = BF.DEFAULT_THRESHOLD2_COLOR
                                            if not s then return dc.r, dc.g, dc.b, dc.a end
                                            local col = s.threshold2Color or (s ~= entry and entry.threshold2Color) or dc
                                            return col.r, col.g, col.b, col.a or 1
                                        end,
                                        set = function(_, r, g, b, a)
                                            if InCombatLockdown() then return end
                                            local entry = ensureCdtEntry()
                                            local s
                                            if entry.separateGroupConfig then
                                                local key = getEditingGroupType()
                                                if not entry.groupSettings then entry.groupSettings = {} end
                                                if not entry.groupSettings[key] then entry.groupSettings[key] = {} end
                                                s = entry.groupSettings[key]
                                            else
                                                s = entry
                                            end
                                            s.threshold2Color = { r = r, g = g, b = b, a = a }
                                            DebouncedSpellCTRefresh()
                                        end,
                                    },
                                    threshold2ColorThreshold = {
                                        type = "range", name = "Secondary Threshold (seconds)", order = 8,
                                        min = 1, max = 58, step = 1,
                                        hidden = function() return not getCdtField("thresholdColorEnabled") or not getCdtField("threshold2ColorEnabled") end,
                                        disabled = InCombatLockdown,
                                        get = function()
                                            local s, entry = getCdtEffective()
                                            if not s then return 4 end
                                            local t2 = s.threshold2ColorThreshold or (s ~= entry and entry.threshold2ColorThreshold) or 4
                                            local t1 = s.thresholdColorThreshold or (s ~= entry and entry.thresholdColorThreshold) or 8
                                            local limit = math.max(1, t1 - 1)
                                            return math.min(t2, limit)
                                        end,
                                        set = function(info, val)
                                            if InCombatLockdown() then return end
                                            local entry = ensureCdtEntry()
                                            local s
                                            if entry.separateGroupConfig then
                                                local key = getEditingGroupType()
                                                if not entry.groupSettings then entry.groupSettings = {} end
                                                if not entry.groupSettings[key] then entry.groupSettings[key] = {} end
                                                s = entry.groupSettings[key]
                                            else
                                                s = entry
                                            end
                                            local t1 = s.thresholdColorThreshold or (s ~= entry and entry.thresholdColorThreshold) or 8
                                            local limit = math.max(1, t1 - 1)
                                            s.threshold2ColorThreshold = math.min(val, limit)
                                            DebouncedSpellCTRefresh()
                                        end,
                                    },
                                },
                            },
                            swipeGroup = {
                                type = "group", name = "Cooldown Swipe", inline = true, order = 1,
                                args = {
                                    disableSwipe = { type = "toggle", name = "Disable Cooldown Swipe",  order = 1,
                                        disabled = InCombatLockdown, get = cdtGet, set = cdtSet },
                                    reverseSwipe = { type = "toggle", name = "Reverse Swipe Direction", order = 2,
                                        hidden = function() return getCdtField("disableSwipe") == true end,
                                        disabled = InCombatLockdown, get = cdtGet, set = cdtSet },
                                    disableSpark = { type = "toggle", name = "Disable Cooldown Spark",  order = 3,
                                        disabled = InCombatLockdown, get = cdtGet, set = cdtSet },
                                },
                            },
                        }
                    end)(),
                },
                    }, -- end cdtTab.args
                }, -- end cdtTab
                -- ── Effects subtab ──────────────────────────────────────
                effectsTab = {
                    type = "group", name = "Frame Effects", order = 3,
                    args = {
                -- Health bar color override
                colorHeader = { type = "header", name = "Buff Health Bar Color", order = 50 },
                colorEnabled = {
                    type     = "toggle",
                    name     = "Change Health Color",
                    desc     = "Tint this unit's health bar when they have this spell active.",
                    order    = 51,
                    width    = "normal",
                    get      = function()
                        local entry = getSpecColors()[sid]
                        return entry ~= nil and entry.enabled ~= false
                    end,
                    set      = function(_, val)
                        if InCombatLockdown() then return end
                        local sc = getSpecColors()
                        if val then
                            if not sc[sid] then
                                sc[sid] = { r=0.0, g=1.0, b=0.5 }
                            else
                                sc[sid].enabled = nil  -- re-enable, keep existing color
                            end
                        else
                            if sc[sid] then
                                sc[sid].enabled = false  -- disable, preserve color data
                            end
                        end
                        BF:InvalidateSpellColorCache()
                        BF:RefreshAllCustomContainersWithRebuild()
                        NotifyChangeSafe()
                    end,
                    disabled = InCombatLockdown,
                },
                color = {
                    type     = "color",
                    name     = "Color",
                    order    = 52,
                    hasAlpha = true,
                    hidden   = function()
                        local entry = getSpecColors()[sid]
                        return not entry or entry.enabled == false
                    end,
                    get      = function()
                        local c = getSpecColors()[sid] or { r=0.0, g=1.0, b=0.5, a=1 }
                        return c.r, c.g, c.b, c.a or 1
                    end,
                    set      = function(_, r, g, b, a)
                        if InCombatLockdown() then return end
                        local sc = getSpecColors()
                        if not sc[sid] then sc[sid] = {} end
                        sc[sid].r, sc[sid].g, sc[sid].b, sc[sid].a = r, g, b, a
                        if BF.activeFrames then
                            for frame in pairs(BF.activeFrames) do
                                if frame.buffColorOverlay then frame.buffColorOverlay:Hide() end
                            end
                        end
                        BF:InvalidateSpellColorCache()
                        BF:RefreshAllCustomContainersWithRebuild()
                    end,
                    disabled = InCombatLockdown,
                },
                colorDurationMap = {
                    type = "toggle", name = "Map Height to Remaining Duration", order = 52.7,
                    desc = "When enabled, the overlay height decreases as the buff's remaining duration decreases.",
                    hidden = function()
                        local entry = getSpecColors()[sid]
                        return not entry or entry.enabled == false
                    end,
                    get = function()
                        local c = getSpecColors()[sid]
                        return c and c.durationMap or false
                    end,
                    set = function(_, val)
                        if InCombatLockdown() then return end
                        local sc = getSpecColors()
                        if not sc[sid] then sc[sid] = {} end
                        sc[sid].durationMap = val or nil
                        BF:InvalidateSpellColorCache()
                        BF:RefreshAllCustomContainersWithRebuild()
                    end,
                    disabled = InCombatLockdown,
                },
                -- Buff Border
                buffBorderHeader = { type = "header", name = "Buff Frame Border", order = 60 },
                buffBorderEnabled = {
                    type     = "toggle",
                    name     = "Show Border When Active",
                    desc     = "Show a colored border around the unit frame when this buff is active.",
                    order    = 61,
                    width    = "normal",
                    get      = function()
                        local p = BF.acDB.profile
                        local entry = p.specSpellBorders and p.specSpellBorders[specId] and p.specSpellBorders[specId][sid]
                        return entry ~= nil and entry.enabled ~= false
                    end,
                    set      = function(_, val)
                        if InCombatLockdown() then return end
                        local p = BF.acDB.profile
                        if not p.specSpellBorders then p.specSpellBorders = {} end
                        if not p.specSpellBorders[specId] then p.specSpellBorders[specId] = {} end
                        if val then
                            if not p.specSpellBorders[specId][sid] then
                                p.specSpellBorders[specId][sid] = { color = { r=0, g=1, b=0 }, priority = false }
                            else
                                p.specSpellBorders[specId][sid].enabled = nil
                            end
                        else
                            if p.specSpellBorders[specId][sid] then
                                p.specSpellBorders[specId][sid].enabled = false
                            end
                        end
                        BF:RefreshAllCustomContainersWithRebuild()
                        NotifyChangeSafe()
                    end,
                    disabled = InCombatLockdown,
                },
                buffBorderColor = {
                    type = "color", name = "Border Color", order = 62, hasAlpha = true,
                    hidden = function() local p = BF.acDB.profile; local e = p.specSpellBorders and p.specSpellBorders[specId] and p.specSpellBorders[specId][sid]; return not e or e.enabled == false end,
                    get = function()
                        local p = BF.acDB.profile
                        local s = p.specSpellBorders and p.specSpellBorders[specId] and p.specSpellBorders[specId][sid]
                        local c = s and s.color or { r=0, g=1, b=0, a=1 }
                        return c.r, c.g, c.b, c.a or 1
                    end,
                    set = function(_, r, g, b, a)
                        if InCombatLockdown() then return end
                        local p = BF.acDB.profile
                        local s = p.specSpellBorders and p.specSpellBorders[specId] and p.specSpellBorders[specId][sid]
                        if s then s.color = { r=r, g=g, b=b, a=a } end
                        BF:RefreshAllCustomContainersWithRebuild()
                    end,
                    disabled = InCombatLockdown,
                },
                buffBorderThickness = {
                    type = "range", name = "Border Thickness", order = 62.5,
                    desc = "Thickness of the buff border in pixels. Applies only to this spell's border.",
                    min = 1, max = 5, step = 1,
                    hidden = function() local p = BF.acDB.profile; local e = p.specSpellBorders and p.specSpellBorders[specId] and p.specSpellBorders[specId][sid]; return not e or e.enabled == false end,
                    get = function()
                        local p = BF.acDB.profile
                        local s = p.specSpellBorders and p.specSpellBorders[specId] and p.specSpellBorders[specId][sid]
                        return (s and s.thickness) or (BF.db and BF.db.profile and BF.db.profile.buffBorderWidth) or 2
                    end,
                    set = function(_, val)
                        if InCombatLockdown() then return end
                        local p = BF.acDB.profile
                        local s = p.specSpellBorders and p.specSpellBorders[specId] and p.specSpellBorders[specId][sid]
                        if s then s.thickness = val end
                        BF:RefreshAllCustomContainersWithRebuild()
                        if BF.RefreshPreviewLayout      then BF:RefreshPreviewLayout()      end
                        if BF.RefreshPreviewDummyAuras  then BF:RefreshPreviewDummyAuras()  end
                    end,
                    disabled = InCombatLockdown,
                },
                buffBorderPriority = {
                    type = "toggle", name = "Prioritise Over Debuff Border", order = 63,
                    desc = "When both buff and debuff borders would show, this buff border takes priority and hides the debuff border.",
                    hidden = function() local p = BF.acDB.profile; local e = p.specSpellBorders and p.specSpellBorders[specId] and p.specSpellBorders[specId][sid]; return not e or e.enabled == false end,
                    get = function()
                        local p = BF.acDB.profile
                        local s = p.specSpellBorders and p.specSpellBorders[specId] and p.specSpellBorders[specId][sid]
                        return s and s.priority
                    end,
                    set = function(_, val)
                        if InCombatLockdown() then return end
                        local p = BF.acDB.profile
                        local s = p.specSpellBorders and p.specSpellBorders[specId] and p.specSpellBorders[specId][sid]
                        if s then s.priority = val end
                        BF:RefreshAllCustomContainersWithRebuild()
                    end,
                    disabled = InCombatLockdown,
                },
                -- Buff Overlay
                buffOverlayHeader = { type = "header", name = "Buff Overlay", order = 70 },
                buffOverlayEnabled = {
                    type     = "toggle",
                    name     = "Show Overlay When Active",
                    desc     = "Show a colored gradient overlay on the health bar when this buff is active.",
                    order    = 71,
                    width    = "normal",
                    get      = function()
                        local p = BF.acDB.profile
                        local entry = p.specSpellOverlays and p.specSpellOverlays[specId] and p.specSpellOverlays[specId][sid]
                        return entry ~= nil and entry.enabled ~= false
                    end,
                    set      = function(_, val)
                        if InCombatLockdown() then return end
                        local p = BF.acDB.profile
                        if not p.specSpellOverlays then p.specSpellOverlays = {} end
                        if not p.specSpellOverlays[specId] then p.specSpellOverlays[specId] = {} end
                        if val then
                            if not p.specSpellOverlays[specId][sid] then
                                p.specSpellOverlays[specId][sid] = { color = { r=0, g=1, b=0 }, alpha = 0.5, height = 0.7, fillOnly = false, priority = false }
                            else
                                p.specSpellOverlays[specId][sid].enabled = nil
                            end
                        else
                            if p.specSpellOverlays[specId][sid] then
                                p.specSpellOverlays[specId][sid].enabled = false
                            end
                        end
                        BF:RefreshAllCustomContainersWithRebuild()
                        NotifyChangeSafe()
                    end,
                    disabled = InCombatLockdown,
                },
                buffOverlayColor = {
                    type = "color", name = "Overlay Color", order = 72, hasAlpha = false,
                    hidden = function() local p = BF.acDB.profile; local e = p.specSpellOverlays and p.specSpellOverlays[specId] and p.specSpellOverlays[specId][sid]; return not e or e.enabled == false end,
                    get = function()
                        local p = BF.acDB.profile
                        local s = p.specSpellOverlays and p.specSpellOverlays[specId] and p.specSpellOverlays[specId][sid]
                        local c = s and s.color or { r=0, g=1, b=0 }
                        return c.r, c.g, c.b
                    end,
                    set = function(_, r, g, b)
                        if InCombatLockdown() then return end
                        local p = BF.acDB.profile
                        local s = p.specSpellOverlays and p.specSpellOverlays[specId] and p.specSpellOverlays[specId][sid]
                        if s then s.color = { r=r, g=g, b=b } end
                        BF:RefreshAllCustomContainersWithRebuild()
                    end,
                    disabled = InCombatLockdown,
                },
                buffOverlayAlpha = {
                    type = "range", name = "Overlay Opacity", order = 73, min = 0.1, max = 1.0, step = 0.05,
                    hidden = function() local p = BF.acDB.profile; local e = p.specSpellOverlays and p.specSpellOverlays[specId] and p.specSpellOverlays[specId][sid]; return not e or e.enabled == false end,
                    get = function()
                        local p = BF.acDB.profile
                        local s = p.specSpellOverlays and p.specSpellOverlays[specId] and p.specSpellOverlays[specId][sid]
                        return s and s.alpha or 0.5
                    end,
                    set = function(_, val)
                        if InCombatLockdown() then return end
                        local p = BF.acDB.profile
                        local s = p.specSpellOverlays and p.specSpellOverlays[specId] and p.specSpellOverlays[specId][sid]
                        if s then s.alpha = val end
                        BF:RefreshAllCustomContainersWithRebuild()
                    end,
                    disabled = InCombatLockdown,
                },
                buffOverlayDurationMap = {
                    type = "toggle", name = "Map Height to Remaining Duration", order = 73.5,
                    desc = "When enabled, the overlay height scales with the remaining buff duration as a percentage of total duration. Overlay Height is unused while this is active.",
                    hidden = function()
                        if spell.secretDetection then return true end
                        local p = BF.acDB.profile; local e = p.specSpellOverlays and p.specSpellOverlays[specId] and p.specSpellOverlays[specId][sid]; return not e or e.enabled == false
                    end,
                    get = function()
                        local p = BF.acDB.profile
                        local s = p.specSpellOverlays and p.specSpellOverlays[specId] and p.specSpellOverlays[specId][sid]
                        return s and s.durationMap or false
                    end,
                    set = function(_, val)
                        if InCombatLockdown() then return end
                        local p = BF.acDB.profile
                        local s = p.specSpellOverlays and p.specSpellOverlays[specId] and p.specSpellOverlays[specId][sid]
                        if s then s.durationMap = val end
                        BF:RefreshAllCustomContainersWithRebuild()
                    end,
                    disabled = InCombatLockdown,
                },
                buffOverlayHeight = {
                    type = "range", name = "Overlay Height", order = 74, min = 0.1, max = 1.0, step = 0.05, isPercent = true,
                    hidden = function()
                        local p = BF.acDB.profile
                        local s = p.specSpellOverlays and p.specSpellOverlays[specId] and p.specSpellOverlays[specId][sid]
                        if not s or s.enabled == false then return true end
                        -- secretDetection spells can't use durationMap; always show height slider
                        if spell.secretDetection then return false end
                        return s.durationMap
                    end,
                    get = function()
                        local p = BF.acDB.profile
                        local s = p.specSpellOverlays and p.specSpellOverlays[specId] and p.specSpellOverlays[specId][sid]
                        return s and s.height or 0.7
                    end,
                    set = function(_, val)
                        if InCombatLockdown() then return end
                        local p = BF.acDB.profile
                        local s = p.specSpellOverlays and p.specSpellOverlays[specId] and p.specSpellOverlays[specId][sid]
                        if s then s.height = val end
                        BF:RefreshAllCustomContainersWithRebuild()
                    end,
                    disabled = InCombatLockdown,
                },
                buffOverlayFillOnly = {
                    type = "toggle", name = "Health Fill Only", order = 75,
                    desc = "Overlay covers only the filled portion of the health bar instead of the full width.",
                    hidden = function() local p = BF.acDB.profile; local e = p.specSpellOverlays and p.specSpellOverlays[specId] and p.specSpellOverlays[specId][sid]; return not e or e.enabled == false end,
                    get = function()
                        local p = BF.acDB.profile
                        local s = p.specSpellOverlays and p.specSpellOverlays[specId] and p.specSpellOverlays[specId][sid]
                        return s and s.fillOnly
                    end,
                    set = function(_, val)
                        if InCombatLockdown() then return end
                        local p = BF.acDB.profile
                        local s = p.specSpellOverlays and p.specSpellOverlays[specId] and p.specSpellOverlays[specId][sid]
                        if s then s.fillOnly = val end
                        BF:RefreshAllCustomContainersWithRebuild()
                    end,
                    disabled = InCombatLockdown,
                },
                buffOverlayPriority = {
                    type = "toggle", name = "Prioritise Over Debuff Overlay", order = 76,
                    desc = "When both buff and debuff overlays would show, this buff overlay takes priority and hides the debuff overlay.",
                    hidden = function() local p = BF.acDB.profile; local e = p.specSpellOverlays and p.specSpellOverlays[specId] and p.specSpellOverlays[specId][sid]; return not e or e.enabled == false end,
                    get = function()
                        local p = BF.acDB.profile
                        local s = p.specSpellOverlays and p.specSpellOverlays[specId] and p.specSpellOverlays[specId][sid]
                        return s and s.priority
                    end,
                    set = function(_, val)
                        if InCombatLockdown() then return end
                        local p = BF.acDB.profile
                        local s = p.specSpellOverlays and p.specSpellOverlays[specId] and p.specSpellOverlays[specId][sid]
                        if s then s.priority = val end
                        BF:RefreshAllCustomContainersWithRebuild()
                    end,
                    disabled = InCombatLockdown,
                },
                    }, -- end effectsTab.args
                }, -- end effectsTab
                -- ── Icon Effects subtab ─────────────────────────────────
                -- Per-icon effects (e.g. glow border). Originally named
                -- "Expiration Effects" — the glow can now be configured
                -- to show always or only below a threshold.
                -- All entries live under one per-spec/per-spell sub-table:
                --   acDB.profile.specSpellExpirationGlow[specId][spellId]
                -- so future Icon Effects can extend the same row without
                -- adding new top-level lookup tables.
                expirationEffectsTab = {
                    type = "group", name = "Icon Effects", order = 1.2,
                    hidden = function() return getAssignedContainerForSpell(sid, specId) == -1 end,
                    args = {
                        -- ── Glow Border section ─────────────────────
                        expGlowHeader = { type = "header", name = "Glow Border", order = 10 },
                        expGlowEnabled = {
                            type  = "toggle",
                            name  = "Show Glow",
                            desc  = "Show a glow effect on the buff icon.",
                            order = 11,
                            width = "normal",
                            get = function()
                                local p = BF.acDB.profile
                                local e = p.specSpellExpirationGlow and p.specSpellExpirationGlow[specId] and p.specSpellExpirationGlow[specId][sid]
                                return e ~= nil and e.enabled ~= false
                            end,
                            set = function(_, val)
                                if InCombatLockdown() then return end
                                local p = BF.acDB.profile
                                if not p.specSpellExpirationGlow then p.specSpellExpirationGlow = {} end
                                if not p.specSpellExpirationGlow[specId] then p.specSpellExpirationGlow[specId] = {} end
                                local entry = p.specSpellExpirationGlow[specId][sid]
                                if val then
                                    if not entry then
                                        p.specSpellExpirationGlow[specId][sid] = {
                                            color     = { r = 1, g = 0.2, b = 0.2, a = 1 },
                                            threshold = 3,
                                            glowType  = "pixel",
                                            showMode  = "threshold",
                                        }
                                    else
                                        entry.enabled = nil
                                    end
                                else
                                    if entry then entry.enabled = false end
                                end
                                if BF.ExpirationGlow_Sync then BF:ExpirationGlow_Sync() end
                                BF:RefreshAllCustomContainersWithRebuild()
                                NotifyChangeSafe()
                            end,
                            disabled = InCombatLockdown,
                        },
                        expGlowColor = {
                            type     = "color",
                            name     = "Glow Color",
                            order    = 13,
                            width    = "normal",
                            hasAlpha = true,
                            hidden = function()
                                local p = BF.acDB.profile
                                local e = p.specSpellExpirationGlow and p.specSpellExpirationGlow[specId] and p.specSpellExpirationGlow[specId][sid]
                                return not e or e.enabled == false
                            end,
                            get = function()
                                local p = BF.acDB.profile
                                local e = p.specSpellExpirationGlow and p.specSpellExpirationGlow[specId] and p.specSpellExpirationGlow[specId][sid]
                                local c = e and e.color or { r = 1, g = 0.2, b = 0.2, a = 1 }
                                return c.r, c.g, c.b, c.a or 1
                            end,
                            set = function(_, r, g, b, a)
                                if InCombatLockdown() then return end
                                local p = BF.acDB.profile
                                local e = p.specSpellExpirationGlow and p.specSpellExpirationGlow[specId] and p.specSpellExpirationGlow[specId][sid]
                                if e then
                                    e.color = { r = r, g = g, b = b, a = a }
                                    -- Bump generation so live icons re-resolve cached color on next poll tick.
                                    BF._expirationGlowConfigGen = (BF._expirationGlowConfigGen or 0) + 1
                                end
                            end,
                            disabled = InCombatLockdown,
                        },
                        expGlowType = {
                            type  = "select",
                            name  = "Glow Type",
                            desc  = "Select the glow effect style.",
                            order = 14,
                            width = "normal",
                            values = {
                                button   = "Button Glow",
                                pixel    = "Pixel Glow",
                                autocast = "Autocast Glow",
                                proc     = "Proc Glow",
                                border   = "Change Border Color",
                            },
                            sorting = { "button", "pixel", "autocast", "proc", "border" },
                            hidden = function()
                                local p = BF.acDB.profile
                                local e = p.specSpellExpirationGlow and p.specSpellExpirationGlow[specId] and p.specSpellExpirationGlow[specId][sid]
                                return not e or e.enabled == false
                            end,
                            get = function()
                                local p = BF.acDB.profile
                                local e = p.specSpellExpirationGlow and p.specSpellExpirationGlow[specId] and p.specSpellExpirationGlow[specId][sid]
                                return (e and e.glowType) or "pixel"
                            end,
                            set = function(_, val)
                                if InCombatLockdown() then return end
                                local p = BF.acDB.profile
                                local e = p.specSpellExpirationGlow and p.specSpellExpirationGlow[specId] and p.specSpellExpirationGlow[specId][sid]
                                if e then
                                    e.glowType = val
                                    BF._expirationGlowConfigGen = (BF._expirationGlowConfigGen or 0) + 1
                                end
                            end,
                            disabled = InCombatLockdown,
                        },
                        expGlowShowMode = {
                            type  = "select",
                            name  = "When to Show",
                            desc  = "Choose whether the glow shows always, or only when the buff's remaining duration drops below a threshold.",
                            order = 12,
                            width = "normal",
                            values = {
                                always    = "Always",
                                threshold = "Duration Below Threshold",
                            },
                            sorting = { "always", "threshold" },
                            hidden = function()
                                local p = BF.acDB.profile
                                local e = p.specSpellExpirationGlow and p.specSpellExpirationGlow[specId] and p.specSpellExpirationGlow[specId][sid]
                                return not e or e.enabled == false
                            end,
                            get = function()
                                local p = BF.acDB.profile
                                local e = p.specSpellExpirationGlow and p.specSpellExpirationGlow[specId] and p.specSpellExpirationGlow[specId][sid]
                                return (e and e.showMode) or "threshold"
                            end,
                            set = function(_, val)
                                if InCombatLockdown() then return end
                                local p = BF.acDB.profile
                                local e = p.specSpellExpirationGlow and p.specSpellExpirationGlow[specId] and p.specSpellExpirationGlow[specId][sid]
                                if e then
                                    e.showMode = val
                                    BF._expirationGlowConfigGen = (BF._expirationGlowConfigGen or 0) + 1
                                end
                            end,
                            disabled = InCombatLockdown,
                        },
                        expGlowThreshold = {
                            type  = "range",
                            name  = "Threshold (seconds)",
                            desc  = "When the buff's remaining duration drops below this many seconds, the glow appears.",
                            order = 15,
                            width = "normal",
                            min   = 1,
                            max   = 30,
                            step  = 1,
                            hidden = function()
                                local p = BF.acDB.profile
                                local e = p.specSpellExpirationGlow and p.specSpellExpirationGlow[specId] and p.specSpellExpirationGlow[specId][sid]
                                if not e or e.enabled == false then return true end
                                return ((e.showMode) or "threshold") == "always"
                            end,
                            get = function()
                                local p = BF.acDB.profile
                                local e = p.specSpellExpirationGlow and p.specSpellExpirationGlow[specId] and p.specSpellExpirationGlow[specId][sid]
                                return e and e.threshold or 3
                            end,
                            set = function(_, val)
                                if InCombatLockdown() then return end
                                local p = BF.acDB.profile
                                local e = p.specSpellExpirationGlow and p.specSpellExpirationGlow[specId] and p.specSpellExpirationGlow[specId][sid]
                                if e then
                                    e.threshold = val
                                    BF._expirationGlowConfigGen = (BF._expirationGlowConfigGen or 0) + 1
                                end
                            end,
                            disabled = InCombatLockdown,
                        },
                    },
                }, -- end expirationEffectsTab
            },
        }

        -- Hide every Icon-tab widget below the "Assign to Container"
        -- dropdown when the spell is assigned to Hide Icon (-1). Anything
        -- about the icon's appearance / ordering / overrides is irrelevant
        -- if there's no icon to begin with. Container assignment widgets
        -- sit at order <= 2.6; the Custom Ordering inline group is order
        -- 10; appearance widgets live at order >= 20.
        local iconArgs = tArgs["spell_" .. si].args.iconTab.args
        for _, w in pairs(iconArgs) do
            if type(w) == "table" and (w.order or 0) >= 10 then
                local prevHidden = w.hidden
                if type(prevHidden) == "function" then
                    w.hidden = function(info)
                        if getAssignedContainerForSpell(sid, specId) == -1 then return true end
                        return prevHidden(info)
                    end
                elseif prevHidden == true then
                    -- already permanently hidden; leave as-is
                else
                    w.hidden = function()
                        return getAssignedContainerForSpell(sid, specId) == -1
                    end
                end
            end
        end
    end

    -- ── "Buffs" tree entry ─────────────────────────────────────────────────
    -- Triggered when any visible aura is showing in the regular buff container.
    -- Provides the same customization options as individual spells (health bar
    -- color, solid icon color, custom border color) but applied as a blanket
    -- override for any/all visible buffs.
    do
        local BUFFS_KEY = "_anyBuff"  -- sentinel key in saved vars (not a real spell ID)

        local function getBuffsHealthColor()
            local p = BF.acDB.profile
            if not p.specSpellColors then p.specSpellColors = {} end
            if not p.specSpellColors[specId] then p.specSpellColors[specId] = {} end
            return p.specSpellColors[specId]
        end

        tArgs.buffsGroup = {
            type  = "group",
            name  = "|cffffffff Buffs|r",
            desc  = "Settings that apply when any buff is visible in the regular buff container.",
            order = 9997,  -- just above Buff Filter (9998)
            args  = {
                -- Clear spell preview when navigating to non-spell groups
                _clearSpellTracker = {
                    type = "description", order = -1, width = "full",
                    name = function()
                        if BF:IsPreviewingSpell() then
                            BF:ClearAuraPreview()
                            if not InCombatLockdown() then NotifyChangeSafe() end
                        end
                        return ""
                    end,
                },
                buffsDesc = {
                    type = "description", order = 0, width = "full",
                    name = "These settings trigger when any aura is visible in the regular buff container on a unit frame. They act as a blanket override — health bar color applies to the whole frame, while solid icon and border color apply to every visible buff icon.",
                },
                -- Health bar color override
                colorHeader = { type = "header", name = "Health Bar Color", order = 30 },
                colorEnabled = {
                    type     = "toggle",
                    name     = "Change Health Color When Buffs Visible",
                    desc     = "Tint this unit's health bar when they have any buff showing in the buff container.",
                    order    = 31,
                    get      = function()
                        local entry = getBuffsHealthColor()[BUFFS_KEY]
                        return entry ~= nil and entry.enabled ~= false
                    end,
                    set      = function(_, val)
                        if InCombatLockdown() then return end
                        local sc = getBuffsHealthColor()
                        if val then
                            if not sc[BUFFS_KEY] then
                                sc[BUFFS_KEY] = { r=0.0, g=1.0, b=0.5 }
                            else
                                sc[BUFFS_KEY].enabled = nil
                            end
                        else
                            if sc[BUFFS_KEY] then
                                sc[BUFFS_KEY].enabled = false
                            end
                        end
                        BF:InvalidateSpellColorCache()
                        BF:RefreshAllCustomContainersWithRebuild()
                        NotifyChangeSafe()
                    end,
                    disabled = InCombatLockdown,
                },
                color = {
                    type     = "color",
                    name     = "Color",
                    order    = 32,
                    hasAlpha = true,
                    hidden   = function() local e = getBuffsHealthColor()[BUFFS_KEY]; return not e or e.enabled == false end,
                    get      = function()
                        local c = getBuffsHealthColor()[BUFFS_KEY] or { r=0.0, g=1.0, b=0.5, a=1 }
                        return c.r, c.g, c.b, c.a or 1
                    end,
                    set      = function(_, r, g, b, a)
                        if InCombatLockdown() then return end
                        local sc = getBuffsHealthColor()
                        if not sc[BUFFS_KEY] then sc[BUFFS_KEY] = {} end
                        sc[BUFFS_KEY].r, sc[BUFFS_KEY].g, sc[BUFFS_KEY].b, sc[BUFFS_KEY].a = r, g, b, a
                        if BF.activeFrames then
                            for frame in pairs(BF.activeFrames) do
                                if frame.buffColorOverlay then frame.buffColorOverlay:Hide() end
                            end
                        end
                        BF:InvalidateSpellColorCache()
                        BF:RefreshAllCustomContainersWithRebuild()
                    end,
                    disabled = InCombatLockdown,
                },
                -- Replace all buff icons with solid color
                solidIconHeader = { type = "header", name = "Replace All Buff Icons with Solid Color", order = 10 },
                solidIconEnabled = {
                    type     = "toggle",
                    name     = "Replace Icons with Solid Color",
                    desc     = "Replace all visible buff icon textures with a solid color square when any buff is showing.",
                    order    = 11,
                    get      = function()
                        local p = BF.acDB.profile
                        local entry = p.specBuffsSolidIcon and p.specBuffsSolidIcon[specId]
                        return entry ~= nil and entry.enabled ~= false
                    end,
                    set      = function(_, val)
                        if InCombatLockdown() then return end
                        local p = BF.acDB.profile
                        if not p.specBuffsSolidIcon then p.specBuffsSolidIcon = {} end
                        if val then
                            if not p.specBuffsSolidIcon[specId] then
                                p.specBuffsSolidIcon[specId] = { r=0.0, g=0.7, b=1.0, a=1.0 }
                            else
                                p.specBuffsSolidIcon[specId].enabled = nil
                            end
                        else
                            if p.specBuffsSolidIcon[specId] then
                                p.specBuffsSolidIcon[specId].enabled = false
                            end
                        end
                        BF:RefreshAllCustomContainersWithRebuild()
                        if BF.RefreshPreviewDummyAuras then BF:RefreshPreviewDummyAuras() end
                        NotifyChangeSafe()
                    end,
                    disabled = InCombatLockdown,
                },
                solidIconColor = {
                    type     = "color",
                    name     = "Solid Color",
                    order    = 12,
                    hasAlpha = true,
                    hidden   = function()
                        local p = BF.acDB.profile
                        local entry = p.specBuffsSolidIcon and p.specBuffsSolidIcon[specId]
                        return not entry or entry.enabled == false
                    end,
                    get      = function()
                        local p = BF.acDB.profile
                        local c = p.specBuffsSolidIcon and p.specBuffsSolidIcon[specId]
                        c = c or { r=0.0, g=0.7, b=1.0, a=1.0 }
                        return c.r, c.g, c.b, c.a or 1.0
                    end,
                    set      = function(_, r, g, b, a)
                        if InCombatLockdown() then return end
                        local p = BF.acDB.profile
                        if not p.specBuffsSolidIcon then p.specBuffsSolidIcon = {} end
                        if not p.specBuffsSolidIcon[specId] then p.specBuffsSolidIcon[specId] = {} end
                        p.specBuffsSolidIcon[specId].r = r
                        p.specBuffsSolidIcon[specId].g = g
                        p.specBuffsSolidIcon[specId].b = b
                        p.specBuffsSolidIcon[specId].a = a
                        BF:RefreshAllCustomContainersWithRebuild()
                        if BF.RefreshPreviewDummyAuras then BF:RefreshPreviewDummyAuras() end
                    end,
                    disabled = InCombatLockdown,
                },
                -- Custom icon border color for all buff icons
                borderColorHeader = { type = "header", name = "Buff Icons Border Color", order = 20 },
                borderColorEnabled = {
                    type     = "toggle",
                    name     = "Custom Icon Border Color",
                    desc     = "Set a custom border color for all visible buff icons when any buff is showing.",
                    order    = 21,
                    get      = function()
                        local p = BF.acDB.profile
                        local entry = p.specBuffsBorderColor and p.specBuffsBorderColor[specId]
                        return entry ~= nil and entry.enabled ~= false
                    end,
                    set      = function(_, val)
                        if InCombatLockdown() then return end
                        local p = BF.acDB.profile
                        if not p.specBuffsBorderColor then p.specBuffsBorderColor = {} end
                        if val then
                            if not p.specBuffsBorderColor[specId] then
                                p.specBuffsBorderColor[specId] = { r=1.0, g=1.0, b=1.0, a=1.0 }
                            else
                                p.specBuffsBorderColor[specId].enabled = nil
                            end
                        else
                            if p.specBuffsBorderColor[specId] then
                                p.specBuffsBorderColor[specId].enabled = false
                            end
                        end
                        BF:RefreshAllCustomContainersWithRebuild()
                        if BF.RefreshPreviewDummyAuras then BF:RefreshPreviewDummyAuras() end
                        NotifyChangeSafe()
                    end,
                    disabled = InCombatLockdown,
                },
                borderColor = {
                    type     = "color",
                    name     = "Icon Border Color",
                    order    = 22,
                    hasAlpha = true,
                    hidden   = function()
                        local p = BF.acDB.profile
                        local entry = p.specBuffsBorderColor and p.specBuffsBorderColor[specId]
                        return not entry or entry.enabled == false
                    end,
                    get      = function()
                        local p = BF.acDB.profile
                        local c = p.specBuffsBorderColor and p.specBuffsBorderColor[specId]
                        c = c or { r=1.0, g=1.0, b=1.0, a=1.0 }
                        return c.r, c.g, c.b, c.a or 1.0
                    end,
                    set      = function(_, r, g, b, a)
                        if InCombatLockdown() then return end
                        local p = BF.acDB.profile
                        if not p.specBuffsBorderColor then p.specBuffsBorderColor = {} end
                        if not p.specBuffsBorderColor[specId] then p.specBuffsBorderColor[specId] = {} end
                        p.specBuffsBorderColor[specId].r = r
                        p.specBuffsBorderColor[specId].g = g
                        p.specBuffsBorderColor[specId].b = b
                        p.specBuffsBorderColor[specId].a = a
                        BF:RefreshAllCustomContainersWithRebuild()
                        if BF.RefreshPreviewDummyAuras then BF:RefreshPreviewDummyAuras() end
                    end,
                    disabled = InCombatLockdown,
                },
                -- Buff Border (frame-wide)
                buffsBorderHeader = { type = "header", name = "Buff Frame Border", order = 40 },
                buffsBorderEnabled = {
                    type = "toggle", name = "Show Border When Any Buff Visible", order = 41,
                    desc = "Show a colored border around the unit frame when any buff is showing in the buff container.",
                    get = function()
                        local p = BF.acDB.profile
                        local entry = p.specBuffsBorder and p.specBuffsBorder[specId]
                        return entry ~= nil and entry.enabled ~= false
                    end,
                    set = function(_, val)
                        if InCombatLockdown() then return end
                        local p = BF.acDB.profile
                        if not p.specBuffsBorder then p.specBuffsBorder = {} end
                        if val then
                            if not p.specBuffsBorder[specId] then
                                p.specBuffsBorder[specId] = { color = { r=0, g=1, b=0 }, priority = false }
                            else
                                p.specBuffsBorder[specId].enabled = nil
                            end
                        else
                            if p.specBuffsBorder[specId] then
                                p.specBuffsBorder[specId].enabled = false
                            end
                        end
                        BF:RefreshAllCustomContainersWithRebuild()
                        NotifyChangeSafe()
                    end,
                    disabled = InCombatLockdown,
                },
                buffsBorderColor = {
                    type = "color", name = "Border Color", order = 42, hasAlpha = true,
                    hidden = function() local e = BF.acDB.profile.specBuffsBorder and BF.acDB.profile.specBuffsBorder[specId]; return not e or e.enabled == false end,
                    get = function()
                        local s = BF.acDB.profile.specBuffsBorder and BF.acDB.profile.specBuffsBorder[specId]
                        local c = s and s.color or { r=0, g=1, b=0, a=1 }
                        return c.r, c.g, c.b, c.a or 1
                    end,
                    set = function(_, r, g, b, a)
                        if InCombatLockdown() then return end
                        local s = BF.acDB.profile.specBuffsBorder and BF.acDB.profile.specBuffsBorder[specId]
                        if s then s.color = { r=r, g=g, b=b, a=a } end
                        BF:RefreshAllCustomContainersWithRebuild()
                    end,
                    disabled = InCombatLockdown,
                },
                buffsBorderThickness = {
                    type = "range", name = "Border Thickness", order = 42.5,
                    desc = "Thickness of the buff border in pixels. Applies when any buff is visible.",
                    min = 1, max = 5, step = 1,
                    hidden = function() local e = BF.acDB.profile.specBuffsBorder and BF.acDB.profile.specBuffsBorder[specId]; return not e or e.enabled == false end,
                    get = function()
                        local s = BF.acDB.profile.specBuffsBorder and BF.acDB.profile.specBuffsBorder[specId]
                        return (s and s.thickness) or (BF.db and BF.db.profile and BF.db.profile.buffBorderWidth) or 2
                    end,
                    set = function(_, val)
                        if InCombatLockdown() then return end
                        local s = BF.acDB.profile.specBuffsBorder and BF.acDB.profile.specBuffsBorder[specId]
                        if s then s.thickness = val end
                        BF:RefreshAllCustomContainersWithRebuild()
                        if BF.RefreshPreviewLayout      then BF:RefreshPreviewLayout()      end
                        if BF.RefreshPreviewDummyAuras  then BF:RefreshPreviewDummyAuras()  end
                    end,
                    disabled = InCombatLockdown,
                },
                buffsBorderPriority = {
                    type = "toggle", name = "Prioritise Over Debuff Border", order = 43,
                    hidden = function() local e = BF.acDB.profile.specBuffsBorder and BF.acDB.profile.specBuffsBorder[specId]; return not e or e.enabled == false end,
                    get = function()
                        local s = BF.acDB.profile.specBuffsBorder and BF.acDB.profile.specBuffsBorder[specId]
                        return s and s.priority
                    end,
                    set = function(_, val)
                        if InCombatLockdown() then return end
                        local s = BF.acDB.profile.specBuffsBorder and BF.acDB.profile.specBuffsBorder[specId]
                        if s then s.priority = val end
                        BF:RefreshAllCustomContainersWithRebuild()
                    end,
                    disabled = InCombatLockdown,
                },
                -- Buff Overlay (health bar gradient)
                buffsOverlayHeader = { type = "header", name = "Buff Overlay", order = 50 },
                buffsOverlayEnabled = {
                    type = "toggle", name = "Show Overlay When Any Buff Visible", order = 51,
                    desc = "Show a colored gradient overlay on the health bar when any buff is showing.",
                    get = function()
                        local p = BF.acDB.profile
                        local entry = p.specBuffsOverlay and p.specBuffsOverlay[specId]
                        return entry ~= nil and entry.enabled ~= false
                    end,
                    set = function(_, val)
                        if InCombatLockdown() then return end
                        local p = BF.acDB.profile
                        if not p.specBuffsOverlay then p.specBuffsOverlay = {} end
                        if val then
                            if not p.specBuffsOverlay[specId] then
                                p.specBuffsOverlay[specId] = { color = { r=0, g=1, b=0 }, alpha = 0.5, height = 0.7, fillOnly = false, priority = false }
                            else
                                p.specBuffsOverlay[specId].enabled = nil
                            end
                        else
                            if p.specBuffsOverlay[specId] then
                                p.specBuffsOverlay[specId].enabled = false
                            end
                        end
                        BF:RefreshAllCustomContainersWithRebuild()
                        NotifyChangeSafe()
                    end,
                    disabled = InCombatLockdown,
                },
                buffsOverlayColor = {
                    type = "color", name = "Overlay Color", order = 52, hasAlpha = false,
                    hidden = function() local e = BF.acDB.profile.specBuffsOverlay and BF.acDB.profile.specBuffsOverlay[specId]; return not e or e.enabled == false end,
                    get = function()
                        local s = BF.acDB.profile.specBuffsOverlay and BF.acDB.profile.specBuffsOverlay[specId]
                        local c = s and s.color or { r=0, g=1, b=0 }
                        return c.r, c.g, c.b
                    end,
                    set = function(_, r, g, b)
                        if InCombatLockdown() then return end
                        local s = BF.acDB.profile.specBuffsOverlay and BF.acDB.profile.specBuffsOverlay[specId]
                        if s then s.color = { r=r, g=g, b=b } end
                        BF:RefreshAllCustomContainersWithRebuild()
                    end,
                    disabled = InCombatLockdown,
                },
                buffsOverlayAlpha = {
                    type = "range", name = "Overlay Opacity", order = 53, min = 0.1, max = 1.0, step = 0.05,
                    hidden = function() local e = BF.acDB.profile.specBuffsOverlay and BF.acDB.profile.specBuffsOverlay[specId]; return not e or e.enabled == false end,
                    get = function()
                        local s = BF.acDB.profile.specBuffsOverlay and BF.acDB.profile.specBuffsOverlay[specId]
                        return s and s.alpha or 0.5
                    end,
                    set = function(_, val)
                        if InCombatLockdown() then return end
                        local s = BF.acDB.profile.specBuffsOverlay and BF.acDB.profile.specBuffsOverlay[specId]
                        if s then s.alpha = val end
                        BF:RefreshAllCustomContainersWithRebuild()
                    end,
                    disabled = InCombatLockdown,
                },
                buffsOverlayDurationMap = {
                    type = "toggle", name = "Map Height to Remaining Duration", order = 53.5,
                    desc = "When enabled, the overlay height scales with the remaining buff duration as a percentage of total duration. Overlay Height is unused while this is active.",
                    hidden = function() local e = BF.acDB.profile.specBuffsOverlay and BF.acDB.profile.specBuffsOverlay[specId]; return not e or e.enabled == false end,
                    get = function()
                        local s = BF.acDB.profile.specBuffsOverlay and BF.acDB.profile.specBuffsOverlay[specId]
                        return s and s.durationMap or false
                    end,
                    set = function(_, val)
                        if InCombatLockdown() then return end
                        local s = BF.acDB.profile.specBuffsOverlay and BF.acDB.profile.specBuffsOverlay[specId]
                        if s then s.durationMap = val end
                        BF:RefreshAllCustomContainersWithRebuild()
                    end,
                    disabled = InCombatLockdown,
                },
                buffsOverlayHeight = {
                    type = "range", name = "Overlay Height", order = 54, min = 0.1, max = 1.0, step = 0.05, isPercent = true,
                    hidden = function()
                        local s = BF.acDB.profile.specBuffsOverlay and BF.acDB.profile.specBuffsOverlay[specId]
                        if not s or s.enabled == false then return true end
                        return s.durationMap
                    end,
                    get = function()
                        local s = BF.acDB.profile.specBuffsOverlay and BF.acDB.profile.specBuffsOverlay[specId]
                        return s and s.height or 0.7
                    end,
                    set = function(_, val)
                        if InCombatLockdown() then return end
                        local s = BF.acDB.profile.specBuffsOverlay and BF.acDB.profile.specBuffsOverlay[specId]
                        if s then s.height = val end
                        BF:RefreshAllCustomContainersWithRebuild()
                    end,
                    disabled = InCombatLockdown,
                },
                buffsOverlayFillOnly = {
                    type = "toggle", name = "Health Fill Only", order = 55,
                    hidden = function() local e = BF.acDB.profile.specBuffsOverlay and BF.acDB.profile.specBuffsOverlay[specId]; return not e or e.enabled == false end,
                    get = function()
                        local s = BF.acDB.profile.specBuffsOverlay and BF.acDB.profile.specBuffsOverlay[specId]
                        return s and s.fillOnly
                    end,
                    set = function(_, val)
                        if InCombatLockdown() then return end
                        local s = BF.acDB.profile.specBuffsOverlay and BF.acDB.profile.specBuffsOverlay[specId]
                        if s then s.fillOnly = val end
                        BF:RefreshAllCustomContainersWithRebuild()
                    end,
                    disabled = InCombatLockdown,
                },
                buffsOverlayPriority = {
                    type = "toggle", name = "Prioritise Over Debuff Overlay", order = 56,
                    hidden = function() local e = BF.acDB.profile.specBuffsOverlay and BF.acDB.profile.specBuffsOverlay[specId]; return not e or e.enabled == false end,
                    get = function()
                        local s = BF.acDB.profile.specBuffsOverlay and BF.acDB.profile.specBuffsOverlay[specId]
                        return s and s.priority
                    end,
                    set = function(_, val)
                        if InCombatLockdown() then return end
                        local s = BF.acDB.profile.specBuffsOverlay and BF.acDB.profile.specBuffsOverlay[specId]
                        if s then s.priority = val end
                        BF:RefreshAllCustomContainersWithRebuild()
                    end,
                    disabled = InCombatLockdown,
                },
            },
        }
    end

    -- ── Buff Filter tree entry ─────────────────────────────────────────────
    -- Appears as a sibling of the spell entries in the tree sidebar.
    -- Overrides the global Misc > Special Options > Healer Spec Filter Mode.
    tArgs.buffFilterGroup = {
        type   = "group",
        name   = "|cffffffff Buff Filter|r",
        order  = 9998,
        hidden = function() return not (BF.db and BF.db.profile.enableExperimentalOptions) end,
        args   = {
            -- Clear spell preview when navigating to non-spell groups
            _clearSpellTracker = {
                type = "description", order = -1, width = "full",
                name = function()
                    if BF:IsPreviewingSpell() then
                        BF:ClearAuraPreview()
                        if not InCombatLockdown() then NotifyChangeSafe() end
                    end
                    return ""
                end,
            },
            desc = {
                type  = "description",
                name  = "The defaults have been set per spec to ensure the correct buffs are shown. Not recommended to change this unless you have a specific reason.",
                order = 1,
                width = "full",
            },
            healerBuffFilter = {
                type   = "select",
                name   = "Filter Mode",
                order  = 2,
                width  = "normal",
                values = {
                    whitelist           = "Helpful | Player (Whitelist)",
                    helpful_player      = "Helpful | Player",
                    player_raid         = "Helpful | Player | Raid",
                    player_raid_combat  = "Helpful | Player | Raid_In_Combat",
                    helpful_raid        = "Helpful | Raid",
                    helpful_raid_combat = "Helpful | Raid_In_Combat",
                },
                get = function()
                    local p = BF.acDB and BF.acDB.profile
                    return (p and p.specBuffFilter and p.specBuffFilter[specId])
                        or "whitelist"
                end,
                set = function(_, val)
                    local p = BF.acDB and BF.acDB.profile
                    if not p then return end
                    if not p.specBuffFilter then p.specBuffFilter = {} end
                    p.specBuffFilter[specId] = val
                    BF:RefreshAllCustomContainersWithRebuild()
                    NotifyChangeSafe()
                end,
            },
            clearOverride = {
                type  = "execute",
                name  = "Clear Override",
                desc  = "Remove the per-spec override and restore the default Filter Mode for this spec.",
                order = 3,
                width = "normal",
                hidden = function()
                    local p = BF.acDB and BF.acDB.profile
                    local cur = p and p.specBuffFilter and p.specBuffFilter[specId]
                    if cur == nil then return true end
                    local def = BF.auraCustomizationDefaults
                        and BF.auraCustomizationDefaults.profile
                        and BF.auraCustomizationDefaults.profile.specBuffFilter
                        and BF.auraCustomizationDefaults.profile.specBuffFilter[specId]
                    -- Hide when the current value already matches the per-spec
                    -- default (nothing to clear) or there's no per-spec default
                    -- and the current value was inherited from the defaults table.
                    return cur == def
                end,
                func = function()
                    local p = BF.acDB and BF.acDB.profile
                    if p and p.specBuffFilter then
                        p.specBuffFilter[specId] = nil
                    end
                    BF:RefreshAllCustomContainersWithRebuild()
                    NotifyChangeSafe()
                end,
            },
        },
    }
end


-- ── Swiftmendable tab args (only for spec 105 — Restoration Druid) ─────────
local function buildSwiftmendableArgs(NotifyChangeSafe)
    local function get(info)
        return BF.acDB.profile[info[#info]]
    end
    local function set(info, val)
        BF.acDB.profile[info[#info]] = val
        BF:RefreshAllCustomContainersWithRebuild()
        NotifyChangeSafe()
    end
    local function setColor(info, r, g, b)
        if InCombatLockdown() then return end
        local key = info[#info]
        if not BF.acDB.profile[key] then BF.acDB.profile[key] = {} end
        BF.acDB.profile[key].r, BF.acDB.profile[key].g, BF.acDB.profile[key].b = r, g, b
        if BF.activeFrames then
            for frame in pairs(BF.activeFrames) do
                frame._bf_swiftmendable = nil  -- force re-evaluate
            end
        end
        BF:RefreshAllCustomContainersWithRebuild()
    end

    return {
        -- Clear spell preview when navigating to non-spell groups
        _clearSpellTracker = {
            type = "description", order = -1, width = "full",
            name = function()
                if BF:IsPreviewingSpell() then
                    BF:ClearAuraPreview()
                    if not InCombatLockdown() then NotifyChangeSafe() end
                end
                return ""
            end,
        },
        desc = {
            type = "description", order = 0, width = "full",
            name = "Highlight raid frames when any Restoration Druid HoT (Rejuvenation, Regrowth, Wild Growth, or Germination) is present on the unit.",
        },
        headerName = { type = "header", name = "Player Name", order = 10 },
        swiftmendRecolorName = {
            type = "toggle", name = "Recolor Player Name",
            desc = "Recolors the player name text when the unit is Swiftmendable.",
            order = 11, width = "full",
            disabled = InCombatLockdown,
            get = get, set = set,
        },
        swiftmendNameColor = {
            type = "color", name = "Name Color", order = 12, hasAlpha = false,
            hidden = function() return not BF.acDB.profile.swiftmendRecolorName end,
            disabled = InCombatLockdown,
            get = function()
                local c = BF.acDB.profile.swiftmendNameColor or { r=0.4, g=0.85, b=1.0 }
                return c.r, c.g, c.b
            end,
            set = setColor,
        },
        headerHealth = { type = "header", name = "Health Text", order = 20 },
        swiftmendRecolorHealthText = {
            type = "toggle", name = "Recolor Health Text",
            desc = "Recolors the health text when the unit is Swiftmendable.",
            order = 21, width = "full",
            disabled = InCombatLockdown,
            get = get, set = set,
        },
        swiftmendHealthTextColor = {
            type = "color", name = "Health Text Color", order = 22, hasAlpha = false,
            hidden = function() return not BF.acDB.profile.swiftmendRecolorHealthText end,
            disabled = InCombatLockdown,
            get = function()
                local c = BF.acDB.profile.swiftmendHealthTextColor or { r=0.4, g=0.85, b=1.0 }
                return c.r, c.g, c.b
            end,
            set = setColor,
        },
    }
end

-- ── BuildCustomAurasOptions ───────────────────────────────────────────────
function BF:BuildCustomAurasOptions(deps)
    local NotifyChangeSafe = deps.NotifyChangeSafe or function()
        LibStub("AceConfigRegistry-3.0"):NotifyChange("BuzzardFrames")
    end

    -- Expose the file-local rebuilders on BF so BF:OnProfileChanged can
    -- call them when the AuraCustomizations profile switches. The args
    -- tables (containerMgmtArgs, specTabArgs) are module-level and built
    -- once here; without these rebuilds, a profile switch leaves the UI
    -- showing the previous profile's containers / spec entries.
    function BF:RebuildContainerMgmtArgs(notify)
        rebuildContainerMgmtArgs(notify or NotifyChangeSafe)
    end
    function BF:RebuildAllSpecTabArgs(notify)
        for _, spec in ipairs(HEALER_SPECS) do
            rebuildSpecTabArgs(spec.id, notify or NotifyChangeSafe)
        end
    end

    -- Initialise per-spec args tables (once; stable references)
    for _, spec in ipairs(HEALER_SPECS) do
        if not specTabArgs[spec.id] then
            specTabArgs[spec.id] = {}
        end
        rebuildSpecTabArgs(spec.id, NotifyChangeSafe)
    end

    -- Build global Container Management args
    rebuildContainerMgmtArgs(NotifyChangeSafe)

    -- ── Top-level tabs ────────────────────────────────────────────────────
    local tabContainerMgmt = {
        type        = "group",
        name        = "Container Management",
        order       = 2,
        childGroups = "tab",
        args        = containerMgmtArgs,
    }

    local topArgs = {
        _sectionTracker = {
            type = "description", order = 0, width = "full",
            name = function()
                if BF._currentSection ~= "customAuras" then
                    BF._currentSection = "customAuras"
                    -- Clear all preview state when entering the Custom Auras
                    -- tab. Subtab trackers will re-set the appropriate mode.
                    BF:ClearAuraPreview()
                    if not InCombatLockdown() then NotifyChangeSafe() end
                end
                return ""
            end,
        },
        _guide = {
            type = "description", order = 0.5, width = "full", fontSize = "medium",
            name = "|cff11ace9Aura Customizations|r lets you control where specific healer and Augmentation Evoker buff icons appear on your raid and party frames.\n\n" ..
                "By default, all tracked buffs appear together in the standard Buffs container (configured in Raid/Party Frames -> Auras). Aura Customizations lets you pull individual spells out of that container and position them independently.",
        },
        _guideHowHeader = {
            type = "description", order = 0.6, width = "full", fontSize = "large",
            name = "\n|cffddddddHow it works:|r\n",
        },
        _guideHowBody = {
            type = "description", order = 0.7, width = "full", fontSize = "medium",
            name = "1. Go to |cff76CC4BContainer Management|r and click |cff76CC4BAdd Container|r. Set the container's anchor point and position - for example, anchor it to the |cff76CC4BTop|r of the frame.\n\n" ..
                "2. Go to the spec tab in |cff76CC4BHealer/Aug Buff Customizations|r (e.g. Resto Shaman) and find the spell you want to move (e.g. Riptide). Use the |cff76CC4BAssign to Container|r dropdown to assign it to the container you just created.\n\n" ..
                "3. That spell's icon will now appear at the container's position instead of in the regular buff row.",
        },
        _guideElseHeader = {
            type = "description", order = 0.8, width = "full", fontSize = "large",
            name = "\n|cffddddddWhat else you can do:|r\n",
        },
        _guideElseBody = {
            type = "description", order = 0.9, width = "full", fontSize = "medium",
            name = "- Assign multiple spells to the same container - they will use the grow direction specified in the container settings.\n\n" ..
                "- Change the health bar color, add a frame border or overlay, or replace the icon with a solid color when a specific spell is active - configure these per-spell in the spec tabs.\n\n" ..
                "- Use |cff76CC4BEnable per-Layout configuration for this Container|r to set a different Container position for different Layouts.\n\n" ..
                "- Use |cff76CC4BAura Filtering|r to control which long-term buffs and debuffs (raid buffs, Sated, Deserter) are shown outside of combat.",
        },
        tabContainerMgmt = tabContainerMgmt,
    }

    -- Inject the Swiftmendable tree entry into the Restoration Druid (spec 105) tab
    specTabArgs[105]["swiftmendable"] = {
        type  = "group",
        name  = "|cff00ff96Swiftmendable|r",
        order = 999,
        args  = buildSwiftmendableArgs(NotifyChangeSafe),
    }

    -- Inject the Soul of the Forest tree entry into Restoration Druid (spec 105) tab
    specTabArgs[105]["soulOfTheForest"] = {
        type  = "group",
        name  = "|cff00ff96Soul of the Forest|r",
        order = 1000,
        args  = {
            _clearSpellTracker = {
                type = "description", order = -1, width = "full",
                name = function()
                    if BF:IsPreviewingSpell() then
                        BF:ClearAuraPreview()
                        if not InCombatLockdown() then NotifyChangeSafe() end
                    end
                    return ""
                end,
            },
            desc = {
                type = "description", order = 0, width = "full",
                name = "When Soul of the Forest is talented, casting Swiftmend empowers the next Rejuvenation, Regrowth, or Germination. With Power of the Archdruid, 2 additional allies also receive the empowered spell.\n\nThis feature adds a glow to empowered buff icons so you can see which HoTs were empowered at a glance.",
            },
            sotfGlowRejuv = {
                type = "toggle",
                name = "Glow Empowered Rejuvenation/Germination",
                desc = "Apply a glow effect to Rejuvenation and Germination icons that were empowered by Soul of the Forest.",
                order = 1,
                width = "full",
                disabled = InCombatLockdown,
                get = function() return BF.acDB.profile.sotfGlowRejuv or false end,
                set = function(_, val)
                    if InCombatLockdown() then return end
                    BF.acDB.profile.sotfGlowRejuv = val
                    BF.acDB.profile.sotfGlowEnabled = (val or BF.acDB.profile.sotfGlowRegrowth) or false
                    if BF.SotF_Sync then BF.SotF_Sync() end
                    BF:RefreshAllCustomContainersWithRebuild()
                    NotifyChangeSafe()
                end,
            },
            sotfRejuvColor = {
                type = "color",
                name = "Rejuvenation Glow Color",
                order = 1.1,
                hasAlpha = true,
                hidden = function() return not BF.acDB.profile.sotfGlowRejuv end,
                disabled = InCombatLockdown,
                get = function()
                    local c = BF.acDB.profile.sotfRejuvColor or { r = 0.95, g = 0.75, b = 0.3, a = 1 }
                    return c.r, c.g, c.b, c.a or 1
                end,
                set = function(_, r, g, b, a)
                    if InCombatLockdown() then return end
                    BF.acDB.profile.sotfRejuvColor = { r = r, g = g, b = b, a = a }
                    BF:RefreshAllCustomContainersWithRebuild()
                    NotifyChangeSafe()
                end,
            },
            sotfGerminationColor = {
                type = "color",
                name = "Germination Glow Color",
                order = 1.2,
                hasAlpha = true,
                hidden = function() return not BF.acDB.profile.sotfGlowRejuv end,
                disabled = InCombatLockdown,
                get = function()
                    local c = BF.acDB.profile.sotfGerminationColor or { r = 0.95, g = 0.75, b = 0.3, a = 1 }
                    return c.r, c.g, c.b, c.a or 1
                end,
                set = function(_, r, g, b, a)
                    if InCombatLockdown() then return end
                    BF.acDB.profile.sotfGerminationColor = { r = r, g = g, b = b, a = a }
                    BF:RefreshAllCustomContainersWithRebuild()
                    NotifyChangeSafe()
                end,
            },
            sotfGlowRegrowth = {
                type = "toggle",
                name = "Glow Empowered Regrowth",
                desc = "Apply a glow effect to Regrowth icons that were empowered by Soul of the Forest.",
                order = 1.5,
                width = "full",
                disabled = InCombatLockdown,
                get = function() return BF.acDB.profile.sotfGlowRegrowth or false end,
                set = function(_, val)
                    if InCombatLockdown() then return end
                    BF.acDB.profile.sotfGlowRegrowth = val
                    BF.acDB.profile.sotfGlowEnabled = (BF.acDB.profile.sotfGlowRejuv or val) or false
                    if BF.SotF_Sync then BF.SotF_Sync() end
                    BF:RefreshAllCustomContainersWithRebuild()
                    NotifyChangeSafe()
                end,
            },
            sotfRegrowthColor = {
                type = "color",
                name = "Regrowth Glow Color",
                order = 1.6,
                hasAlpha = true,
                hidden = function() return not BF.acDB.profile.sotfGlowRegrowth end,
                disabled = InCombatLockdown,
                get = function()
                    local c = BF.acDB.profile.sotfRegrowthColor or { r = 0.95, g = 0.75, b = 0.3, a = 1 }
                    return c.r, c.g, c.b, c.a or 1
                end,
                set = function(_, r, g, b, a)
                    if InCombatLockdown() then return end
                    BF.acDB.profile.sotfRegrowthColor = { r = r, g = g, b = b, a = a }
                    BF:RefreshAllCustomContainersWithRebuild()
                    NotifyChangeSafe()
                end,
            },
            convokeNote = {
                type = "description", order = 2, width = "full",
                name = "\n|cffaaaaaa" ..
                    "Note: During Convoke the Spirits, it is not possible to accurately track " ..
                    "whether the buffs it applied were empowered by Soul of the Forest, because " ..
                    "Convoke does not fire individual spellcast events. By default, all Rejuvenations " ..
                    "and Regrowths applied during Convoke will not glow.|r",
            },
            sotfConvokeAsEmpowered = {
                type = "toggle",
                name = "Treat Convoke Rejuvs/Regrowths as Empowered if SoTF was active when cast",
                desc = "When Soul of the Forest is active and Convoke the Spirits is channeled, treat all Rejuvenations and Regrowths applied by Convoke as empowered (up to the 3-target cap with Power of the Archdruid). This may result in some non-empowered buffs incorrectly glowing.",
                order = 3,
                width = "full",
                disabled = function() return InCombatLockdown() or not BF.acDB.profile.sotfGlowEnabled end,  -- sotfGlowEnabled is derived from sotfGlowRejuv || sotfGlowRegrowth
                get = function() return BF.acDB.profile.sotfConvokeAsEmpowered or false end,
                set = function(_, val)
                    if InCombatLockdown() then return end
                    BF.acDB.profile.sotfConvokeAsEmpowered = val
                    NotifyChangeSafe()
                end,
            },
            sotfGlowTypeHeader = {
                type = "header",
                name = "Soul of the Forest Glow Type",
                order = 4,
            },
            sotfGlowType = {
                type = "select",
                name = "Glow Type",
                desc = "Select the glow effect style for empowered buffs.",
                order = 4.1,
                values = {
                    button   = "Button Glow",
                    pixel    = "Pixel Glow",
                    autocast = "Autocast Glow",
                    proc     = "Proc Glow",
                    border   = "Change Border Color",
                },
                sorting = { "button", "pixel", "autocast", "proc", "border" },
                disabled = function() return InCombatLockdown() or not BF.acDB.profile.sotfGlowEnabled end,
                get = function() return BF.acDB.profile.sotfGlowType or "button" end,
                set = function(_, val)
                    if InCombatLockdown() then return end
                    BF.acDB.profile.sotfGlowType = val
                    BF:RefreshAllCustomContainersWithRebuild()
                    NotifyChangeSafe()
                end,
            },
        },
    }

    -- ── Healer/Aug Buff Customizations parent group ───────────────────
    local healerBuffArgs = {}
    for si, spec in ipairs(HEALER_SPECS) do
        local specId   = spec.id
        local tabLabel = spec.tabName or spec.name
        healerBuffArgs["tabSpec_" .. specId] = {
            type        = "group",
            name        = function()
                local sd    = BF.specByID and BF.specByID[specId]
                local icon  = sd and sd.icon or ""
                local color = spec.classColor or "ffffff"
                local label = "|cff" .. color .. tabLabel .. "|r"
                local pad   = spec.tabPad or ""
                if icon ~= "" then
                    return pad .. "|T" .. icon .. ":16:16:0:0|t " .. label .. pad
                else
                    return pad .. label .. pad
                end
            end,
            order       = 10 + si,
            childGroups = "tree",
            args        = specTabArgs[specId],
        }
    end
    topArgs.tabHealerBuffs = {
        type        = "group",
        name        = "Healer/Aug Buff Customizations",
        order       = 3,
        childGroups = "tab",
        args        = healerBuffArgs,
    }

    -- ── Aura Filtering tab ───────────────────────────────────────────────────
    topArgs.tabAuraFiltering = {
        type        = "group",
        name        = "Aura Filtering",
        order       = 99,
        args        = {
            -- Clear spell preview when navigating to non-spell tabs
            _clearSpellTracker = {
                type = "description", order = -1, width = "full",
                name = function()
                    if BF:IsPreviewingSpell() then
                        BF:ClearAuraPreview()
                        if not InCombatLockdown() then NotifyChangeSafe() end
                    end
                    return ""
                end,
            },
            headerOutOfCombatBuffs = {
                type  = "header",
                name  = "Show long-term buffs (out of combat)",
                order = 1,
            },
            showRaidBuffs = {
                type     = "toggle",
                name     = "Raid Buffs",
                desc     = "Show raid buffs (Mark of the Wild, Arcane Intellect, Battle Shout, Power Word: Fortitude, Blessing of the Bronze, etc.) on raid/party frames when out of combat.",
                order    = 2,
                disabled = InCombatLockdown,
                get      = function() return BF.acDB.profile.showRaidBuffs end,
                set      = function(_, val)
                    BF.acDB.profile.showRaidBuffs = val
                    BF:RefreshAllCustomContainersWithRebuild()
                end,
            },
            headerOutOfCombat = {
                type  = "header",
                name  = "Show long-term debuffs (out of combat)",
                order = 10,
            },
            showSatedDebuffs = {
                type     = "toggle",
                name     = "Sated / Exhaustion",
                desc     = "Show Sated, Exhaustion, Temporal Displacement, and similar bloodlust debuffs on raid/party frames when out of combat.",
                order    = 11,
                disabled = InCombatLockdown,
                get      = function() return BF.acDB.profile.showSatedDebuffs end,
                set      = function(_, val)
                    BF.acDB.profile.showSatedDebuffs = val
                    BF:RefreshAllCustomContainersWithRebuild()
                end,
            },
            showDeserterDebuffs = {
                type     = "toggle",
                name     = "Deserter",
                desc     = "Show BG Deserter and Dungeon Deserter debuffs on raid/party frames when out of combat.",
                order    = 12,
                disabled = InCombatLockdown,
                get      = function() return BF.acDB.profile.showDeserterDebuffs end,
                set      = function(_, val)
                    BF.acDB.profile.showDeserterDebuffs = val
                    BF:RefreshAllCustomContainersWithRebuild()
                end,
            },
            showSkyridingDebuffs = {
                type     = "toggle",
                name     = "Skyriding Ride Along",
                desc     = "Show Skyriding Ride Along (Available, Active, Inactive) debuffs on raid/party frames when out of combat.",
                order    = 13,
                disabled = InCombatLockdown,
                get      = function() return BF.acDB.profile.showSkyridingDebuffs end,
                set      = function(_, val)
                    BF.acDB.profile.showSkyridingDebuffs = val
                    BF:RefreshAllCustomContainersWithRebuild()
                end,
            },
            -- ── Advanced Filter Modes (experimental) ──────────────────────
            advFilterSpacer = { type = "description", name = "", order = 20, hidden = function() return not (BF.db and BF.db.profile.enableExperimentalOptions) end },
            advFilterHeader = { type = "header", name = "Advanced Filter Modes", order = 20.1, hidden = function() return not (BF.db and BF.db.profile.enableExperimentalOptions) end },
            advFilterNote = {
                type = "description", order = 20.2, width = "full",
                hidden = function() return not (BF.db and BF.db.profile.enableExperimentalOptions) end,
                name = "|cffbbbbbbFilter Mode for Healer specs and Augmentation is set per-spec in the Buff Filter settings for each spec.|r",
            },
            nonHealerBuffFilter = {
                type = "select", name = "Non-Healer Spec Filter Mode", order = 22,
                width = "normal",
                hidden = function() return not (BF.db and BF.db.profile.enableExperimentalOptions) end,
                desc = "Helpful | Player | Raid_In_Combat: May show some additional relevant buffs.",
                values = {
                    helpful_player      = "Helpful | Player",
                    player_raid         = "Helpful | Player | Raid",
                    player_raid_combat  = "Helpful | Player | Raid_In_Combat",
                    helpful_raid        = "Helpful | Raid",
                    helpful_raid_combat = "Helpful | Raid_In_Combat",
                },
                get = function() return BF.acDB.profile.nonHealerBuffFilter end,
                set = function(_, val)
                    if InCombatLockdown() then return end
                    BF.acDB.profile.nonHealerBuffFilter = val
                    BF:RefreshAllAuras()
                    if BF.RefreshPreviewDummyAuras then BF:RefreshPreviewDummyAuras() end
                end,
            },
            -- debuffFilter REMOVED — replaced by debuffShowMode in the Debuffs
            -- section of Options_Auras.lua (auras.debuffs sub-category).
        },
    }

    -- ── Private Aura Customizations tab ─────────────────────────────────────
    do
        -- Raid definitions: which encounter IDs belong to each raid
        local RAID_ENCOUNTER_IDS = {
            dreamrift    = { 3306 },
            voidspire    = { 3176, 3177, 3178, 3179, 3180, 3181 },
            queldanas     = { 3182, 3183 },
        }
        local RAID_ORDER = { "dungeons", "dreamrift", "voidspire", "queldanas" }
        local RAID_LABELS = {
            dungeons  = "Dungeons",
            dreamrift = "The Dreamrift",
            voidspire = "The Voidspire",
            queldanas  = "March on Quel'Danas",
        }

        -- Session-only selected raid (defaults to first)
        local selectedRaid = "dreamrift"

        -- Build a lookup: encID -> raid key
        local encIDToRaid = {}
        for raidKey, ids in pairs(RAID_ENCOUNTER_IDS) do
            for _, id in ipairs(ids) do
                encIDToRaid[id] = raidKey
            end
        end

        -- Build a lookup: encID -> display order within its raid
        local encIDToRaidOrder = {}
        for _, ids in pairs(RAID_ENCOUNTER_IDS) do
            for orderIdx, id in ipairs(ids) do
                encIDToRaidOrder[id] = orderIdx
            end
        end

        local encArgs = {}

        -- ── Master killswitch ───────────────────────────────────────────
        -- When OFF (default), the entire PrivateAuraCustomizations module is
        -- inert: every entry point bails immediately, no frames are created,
        -- no SF_* fields are written. Toggling OFF after being on tears down
        -- everything customizations ever wrote and rebuilds icons clean.
        encArgs.enablePrivateAuraCustomizations = {
            type  = "toggle",
            name  = "Enable Private Aura Customizations",
            desc  = "Master switch for all per-encounter, per-dungeon, and global private aura customization features (overlay, frame border, hide indices, dispel overlay, tooltip suppression, border scale).\n\nWhen disabled, regular private aura icons render normally with no customizations applied.",
            order = 0,
            width = "full",
            disabled = InCombatLockdown,
            get   = function()
                local p = BF.acDB and BF.acDB.profile
                return p and p.enablePrivateAuraCustomizations == true
            end,
            set   = function(_, val)
                if BF.SetPrivateAuraCustomizationsEnabled then
                    BF:SetPrivateAuraCustomizationsEnabled(val)
                end
                LibStub("AceConfigRegistry-3.0"):NotifyChange("BuzzardFrames")
            end,
        }

        -- All other options in this tab are disabled when the killswitch is off.
        local function paCustomizationsDisabled()
            if InCombatLockdown() then return true end
            local p = BF.acDB and BF.acDB.profile
            return not (p and p.enablePrivateAuraCustomizations)
        end

        -- All other options in this tab are HIDDEN when the killswitch is off.
        -- Distinct from paCustomizationsDisabled: this one ignores combat state
        -- (combat should disable interaction, not hide widgets).
        local function paCustomizationsHidden()
            local p = BF.acDB and BF.acDB.profile
            return not (p and p.enablePrivateAuraCustomizations)
        end

        -- ── Dungeon global settings (shown when selectedRaid == "dungeons") ──────
        local function getDungeonProfile()
            local p = BF.acDB and BF.acDB.profile
            if not p then return nil end
            if not p.dungeonPASettings then p.dungeonPASettings = {} end
            return p.dungeonPASettings
        end

        encArgs.dungeonSettings = {
            type   = "group",
            name   = "Dungeons",
            order  = 50,
            inline = true,
            hidden = function() return paCustomizationsHidden() or selectedRaid ~= "dungeons" end,
            disabled = InCombatLockdown,
            args   = {
                showBorder = {
                    type  = "toggle",
                    name  = "Show Border",
                    desc  = "Show the private aura frame border in all dungeons.",
                    order = 1,
                    get   = function()
                        local dp = getDungeonProfile()
                        return dp and dp.showBorder == true
                    end,
                    set   = function(_, val)
                        local dp = getDungeonProfile()
                        if dp then dp.showBorder = val end
                        if BF.RefreshEncounterOverrides then BF:RefreshEncounterOverrides() end
                    end,
                },
                hideFirstSlotBorder = {
                    type   = "toggle",
                    name   = "Hide First Slot Border",
                    desc   = "Skip the border for the first private aura slot in dungeons.",
                    order  = 2,
                    hidden = function()
                        local dp = getDungeonProfile()
                        return not (dp and dp.showBorder)
                    end,
                    get    = function()
                        local dp = getDungeonProfile()
                        return dp and dp.hideFirstSlotBorder == true
                    end,
                    set    = function(_, val)
                        local dp = getDungeonProfile()
                        if dp then dp.hideFirstSlotBorder = val end
                        if BF.RefreshEncounterOverrides then BF:RefreshEncounterOverrides() end
                    end,
                },
                drawOrder = {
                    type   = "select",
                    name   = "Border Draw Order",
                    desc   = "When multiple private aura slots are active simultaneously, which slot's border renders on top.",
                    order  = 3,
                    hidden = function()
                        local dp = getDungeonProfile()
                        return not (dp and dp.showBorder)
                    end,
                    values = { first = "First Slot on Top", last = "Last Slot on Top" },
                    get    = function()
                        local dp = getDungeonProfile()
                        return (dp and dp.drawOrder) or "first"
                    end,
                    set    = function(_, val)
                        local dp = getDungeonProfile()
                        if dp then dp.drawOrder = val end
                        if BF.RefreshEncounterOverrides then BF:RefreshEncounterOverrides() end
                    end,
                },
                showOverlayBreak = { type = "description", name = "", order = 9.5, width = "full" },
                showOverlay = {
                    type  = "toggle",
                    name  = "Show Text Overlay",
                    desc  = "This option can improve the stack count visibility on private auras.",
                    order = 10,
                    get   = function()
                        local dp = getDungeonProfile()
                        return dp and dp.showOverlay == true
                    end,
                    set   = function(_, val)
                        local dp = getDungeonProfile()
                        if dp then dp.showOverlay = val end
                        if BF.RefreshEncounterOverrides then BF:RefreshEncounterOverrides() end
                    end,
                },
                hideIcon = {
                    type   = "toggle",
                    name   = "Hide Icon Texture",
                    desc   = "Hide the private aura icon texture in all dungeons, keeping only the border and countdown.",
                    order  = 11,
                    hidden = function() return true end,
                    get    = function()
                        local dp = getDungeonProfile()
                        return dp and dp.hideIcon == true
                    end,
                    set    = function(_, val)
                        local dp = getDungeonProfile()
                        if dp then dp.hideIcon = val end
                        if BF.RefreshEncounterIconOverrides then BF:RefreshEncounterIconOverrides() end
                    end,
                },
                hideAuraIndicesHeader = { type = "header", name = "Hide Private Aura Indices", order = 12 },
                hideAuraIndex1 = {
                    type = "toggle", name = "Hide Index 1", order = 13,
                    desc = "Do not register a private aura anchor for index 1. Remaining indices shift down to fill the gap.",
                    get = function() local dp = getDungeonProfile(); return dp and dp.hiddenAuraIndices and dp.hiddenAuraIndices[1] or false end,
                    set = function(_, val)
                        local dp = getDungeonProfile(); if not dp then return end
                        if not dp.hiddenAuraIndices then dp.hiddenAuraIndices = {} end
                        dp.hiddenAuraIndices[1] = val or nil
                        if BF.RefreshEncounterIconOverrides then BF:RefreshEncounterIconOverrides() end
                    end,
                },
                hideAuraIndex2 = {
                    type = "toggle", name = "Hide Index 2", order = 14,
                    desc = "Do not register a private aura anchor for index 2. Remaining indices shift down to fill the gap.",
                    get = function() local dp = getDungeonProfile(); return dp and dp.hiddenAuraIndices and dp.hiddenAuraIndices[2] or false end,
                    set = function(_, val)
                        local dp = getDungeonProfile(); if not dp then return end
                        if not dp.hiddenAuraIndices then dp.hiddenAuraIndices = {} end
                        dp.hiddenAuraIndices[2] = val or nil
                        if BF.RefreshEncounterIconOverrides then BF:RefreshEncounterIconOverrides() end
                    end,
                },
                hideAuraIndex3 = {
                    type = "toggle", name = "Hide Index 3", order = 15,
                    desc = "Do not register a private aura anchor for index 3. Remaining indices shift down to fill the gap.",
                    get = function() local dp = getDungeonProfile(); return dp and dp.hiddenAuraIndices and dp.hiddenAuraIndices[3] or false end,
                    set = function(_, val)
                        local dp = getDungeonProfile(); if not dp then return end
                        if not dp.hiddenAuraIndices then dp.hiddenAuraIndices = {} end
                        dp.hiddenAuraIndices[3] = val or nil
                        if BF.RefreshEncounterIconOverrides then BF:RefreshEncounterIconOverrides() end
                    end,
                },
            },
        }

        -- ── Global PA Override (applies everywhere, highest priority) ────
        local function getGlobalPA()
            local p = BF.acDB and BF.acDB.profile
            if not p then return nil end
            if not p.globalPASettings then p.globalPASettings = {} end
            return p.globalPASettings
        end
        local function cleanGlobalPA()
            local p = BF.acDB and BF.acDB.profile
            if p and p.globalPASettings and not next(p.globalPASettings) then
                p.globalPASettings = nil
            end
        end

        -- Clear spell preview when navigating to Private Aura Customizations
        encArgs._clearSpellTracker = {
            type = "description", order = -3, width = "full",
            hidden = paCustomizationsHidden,
            name = function()
                if BF:IsPreviewingSpell() then
                    BF:ClearAuraPreview()
                    if not InCombatLockdown() then NotifyChangeSafe() end
                end
                return ""
            end,
        }

        encArgs.enableGlobalRaidOverrides = {
            type  = "toggle",
            name  = "Enable Global Raid Overrides",
            desc  = "When enabled, ONLY the settings below apply to private auras in raid instances. Per-encounter settings are ignored. Dungeon settings are not affected.",
            order = -2.5,
            width = "full",
            disabled = InCombatLockdown,
            hidden = function() return paCustomizationsHidden() or selectedRaid == "dungeons" end,
            get   = function()
                local p = BF.acDB and BF.acDB.profile
                return p and p.enableGlobalPAOverrides == true
            end,
            set   = function(_, val)
                local p = BF.acDB and BF.acDB.profile
                if not p then return end
                p.enableGlobalPAOverrides = val or nil
                -- Only refresh if the toggle has functional effect. When the
                -- master switch flips but globalPASettings is empty (no actual
                -- override values set), the resolved override state is identical
                -- before and after the toggle, so any refresh would just churn
                -- anchor registrations for no reason. The refresh paths re-
                -- register every frame's PA anchors, which can race with
                -- Blizzard's PrivateAurasUI dispatch and corrupt rendering state.
                local gp = p.globalPASettings
                local hasContent = gp and next(gp) ~= nil
                if hasContent then
                    if BF.RefreshEncounterOverrides then BF:RefreshEncounterOverrides() end
                    if BF.RefreshEncounterIconOverrides then BF:RefreshEncounterIconOverrides() end
                end
                LibStub("AceConfigRegistry-3.0"):NotifyChange("BuzzardFrames")
            end,
        }

        encArgs.globalOverrideGroup = {
            type   = "group",
            name   = "Global Raid Override",
            order  = -2,
            inline = true,
            disabled = InCombatLockdown,
            hidden = function()
                if paCustomizationsHidden() then return true end
                if selectedRaid == "dungeons" then return true end
                local p = BF.acDB and BF.acDB.profile
                return not (p and p.enableGlobalPAOverrides)
            end,
            args   = {
                desc = {
                    type = "description", order = 0, width = "full",
                    name = "These settings apply to all raid instances and override per-encounter settings. Dungeon settings are not affected.",
                    hidden = function() local p = BF.acDB and BF.acDB.profile; return not (p and p.enableGlobalPAOverrides) end,
                },
                showBorder = {
                    type  = "toggle",
                    name  = "Show Border",
                    desc  = "Show the private aura frame border in all raid instances.",
                    order = 1,
                    hidden = function() local p = BF.acDB and BF.acDB.profile; return not (p and p.enableGlobalPAOverrides) end,
                    get   = function() local gp = getGlobalPA(); return gp and gp.showBorder == true end,
                    set   = function(_, val)
                        local gp = getGlobalPA(); if gp then gp.showBorder = val or nil end
                        cleanGlobalPA()
                        if BF.RefreshEncounterOverrides then BF:RefreshEncounterOverrides() end
                    end,
                },
                hideFirstSlotBorder = {
                    type   = "toggle",
                    name   = "Hide First Slot Border",
                    desc   = "Skip the border for the first private aura slot.",
                    order  = 2,
                    hidden = function() local p = BF.acDB and BF.acDB.profile; if not (p and p.enableGlobalPAOverrides) then return true end; local gp = getGlobalPA(); return not (gp and gp.showBorder) end,
                    get    = function() local gp = getGlobalPA(); return gp and gp.hideFirstSlotBorder == true end,
                    set    = function(_, val)
                        local gp = getGlobalPA(); if gp then gp.hideFirstSlotBorder = val or nil end
                        cleanGlobalPA()
                        if BF.RefreshEncounterOverrides then BF:RefreshEncounterOverrides() end
                    end,
                },
                drawOrder = {
                    type   = "select",
                    name   = "Border Draw Order",
                    desc   = "Which slot's border renders on top when multiple are active.",
                    order  = 3,
                    hidden = function() local p = BF.acDB and BF.acDB.profile; if not (p and p.enableGlobalPAOverrides) then return true end; local gp = getGlobalPA(); return not (gp and gp.showBorder) end,
                    values = { first = "First Slot on Top", last = "Last Slot on Top" },
                    get    = function() local gp = getGlobalPA(); return (gp and gp.drawOrder) or "first" end,
                    set    = function(_, val)
                        local gp = getGlobalPA(); if gp then gp.drawOrder = val end
                        if BF.RefreshEncounterOverrides then BF:RefreshEncounterOverrides() end
                    end,
                },
                showOverlayBreak = { type = "description", name = "", order = 9.5, width = "full",
                    hidden = function() local p = BF.acDB and BF.acDB.profile; return not (p and p.enableGlobalPAOverrides) end },
                showOverlay = {
                    type  = "toggle",
                    name  = "Show Text Overlay",
                    desc  = "Show the text overlay in all raid instances.",
                    order = 10,
                    hidden = function() local p = BF.acDB and BF.acDB.profile; return not (p and p.enableGlobalPAOverrides) end,
                    get   = function() local gp = getGlobalPA(); return gp and gp.showOverlay == true end,
                    set   = function(_, val)
                        local gp = getGlobalPA(); if gp then gp.showOverlay = val or nil end
                        cleanGlobalPA()
                        if BF.RefreshEncounterOverrides then BF:RefreshEncounterOverrides() end
                    end,
                },
                hideIcon = {
                    type   = "toggle",
                    name   = "Hide Icon Texture",
                    desc   = "Hide the private aura icon texture in all raid instances.",
                    order  = 11,
                    hidden = function() return true end, -- kept hidden for now
                    get    = function() local gp = getGlobalPA(); return gp and gp.hideIcon == true end,
                    set    = function(_, val)
                        local gp = getGlobalPA(); if gp then gp.hideIcon = val or nil end
                        cleanGlobalPA()
                        if BF.RefreshEncounterIconOverrides then BF:RefreshEncounterIconOverrides() end
                    end,
                },
                hideAuraIndicesHeader = { type = "header", name = "Hide Private Aura Indices", order = 12,
                    hidden = function() local p = BF.acDB and BF.acDB.profile; return not (p and p.enableGlobalPAOverrides) end },
                hideAuraIndex1 = {
                    type = "toggle", name = "Hide Index 1", order = 13,
                    desc = "Do not register a private aura anchor for index 1.",
                    hidden = function() local p = BF.acDB and BF.acDB.profile; return not (p and p.enableGlobalPAOverrides) end,
                    get = function() local gp = getGlobalPA(); return gp and gp.hiddenAuraIndices and gp.hiddenAuraIndices[1] or false end,
                    set = function(_, val)
                        local gp = getGlobalPA(); if not gp then return end
                        if not gp.hiddenAuraIndices then gp.hiddenAuraIndices = {} end
                        gp.hiddenAuraIndices[1] = val or nil
                        if not next(gp.hiddenAuraIndices) then gp.hiddenAuraIndices = nil end
                        cleanGlobalPA()
                        if BF.RefreshEncounterIconOverrides then BF:RefreshEncounterIconOverrides() end
                    end,
                },
                hideAuraIndex2 = {
                    type = "toggle", name = "Hide Index 2", order = 14,
                    desc = "Do not register a private aura anchor for index 2.",
                    hidden = function() local p = BF.acDB and BF.acDB.profile; return not (p and p.enableGlobalPAOverrides) end,
                    get = function() local gp = getGlobalPA(); return gp and gp.hiddenAuraIndices and gp.hiddenAuraIndices[2] or false end,
                    set = function(_, val)
                        local gp = getGlobalPA(); if not gp then return end
                        if not gp.hiddenAuraIndices then gp.hiddenAuraIndices = {} end
                        gp.hiddenAuraIndices[2] = val or nil
                        if not next(gp.hiddenAuraIndices) then gp.hiddenAuraIndices = nil end
                        cleanGlobalPA()
                        if BF.RefreshEncounterIconOverrides then BF:RefreshEncounterIconOverrides() end
                    end,
                },
                hideAuraIndex3 = {
                    type = "toggle", name = "Hide Index 3", order = 15,
                    desc = "Do not register a private aura anchor for index 3.",
                    hidden = function() local p = BF.acDB and BF.acDB.profile; return not (p and p.enableGlobalPAOverrides) end,
                    get = function() local gp = getGlobalPA(); return gp and gp.hiddenAuraIndices and gp.hiddenAuraIndices[3] or false end,
                    set = function(_, val)
                        local gp = getGlobalPA(); if not gp then return end
                        if not gp.hiddenAuraIndices then gp.hiddenAuraIndices = {} end
                        gp.hiddenAuraIndices[3] = val or nil
                        if not next(gp.hiddenAuraIndices) then gp.hiddenAuraIndices = nil end
                        cleanGlobalPA()
                        if BF.RefreshEncounterIconOverrides then BF:RefreshEncounterIconOverrides() end
                    end,
                },
            },
        }
        encArgs.globalSpacer = {
            type = "description", name = "", order = -1, width = "full",
            hidden = paCustomizationsHidden,
        }

        -- ── Instance selector dropdown ────────────────────────────────────
        encArgs.raidSelect = {
            type   = "select",
            name   = "Instance",
            order  = 0,
            width  = "normal",
            hidden = paCustomizationsHidden,
            values = (function()
                local v = {}
                for _, k in ipairs(RAID_ORDER) do v[k] = RAID_LABELS[k] end
                return v
            end)(),
            sorting = RAID_ORDER,
            get    = function() return selectedRaid end,
            set    = function(_, val)
                selectedRaid = val
                NotifyChangeSafe()
            end,
        }

        -- Build a set of encounter IDs that have subzone names mapped.
        -- Encounters without subzone mapping are hidden (coming soon).
        local hasSubzone = {}
        if BF.SUBZONE_NAME_TO_ENCOUNTER then
            for _, encID in pairs(BF.SUBZONE_NAME_TO_ENCOUNTER) do
                hasSubzone[encID] = true
            end
        end

        -- ── "Coming soon" note for encounters without subzone data ────────
        encArgs.comingSoonNote = {
            type  = "description",
            name  = "|cffaaaaaaAdditional boss customizations are coming soon as subzone data is collected.|r",
            order = 9999,
            width = "full",
            hidden = function()
                if paCustomizationsHidden() then return true end
                -- Only show when viewing a raid that has hidden bosses
                if selectedRaid == "dungeons" then return true end
                local raidIDs = RAID_ENCOUNTER_IDS[selectedRaid]
                if not raidIDs then return true end
                for _, id in ipairs(raidIDs) do
                    if not hasSubzone[id] then return false end
                end
                return true  -- all bosses have subzone data, hide the note
            end,
        }

        -- ── Per-encounter entries ─────────────────────────────────────────
        local encounters = BF.Encounters or {}
        for i, encounter in ipairs(encounters) do
            local encID   = encounter.id
            local encName = encounter.name
            local raidKey = encIDToRaid[encID]

            local function getEncProfile()
                local p = BF.acDB and BF.acDB.profile
                if not p then return nil end
                if not p.encounterPASettings then p.encounterPASettings = {} end
                if not p.encounterPASettings[encID] then p.encounterPASettings[encID] = {} end
                return p.encounterPASettings[encID]
            end

            local bossOrder = encIDToRaidOrder[encID] or i

            -- Note for encounters sharing a subzone: add a description at the top.
            local sharedSubzoneNote = nil
            if encID == 3178 then
                sharedSubzoneNote = "These two bosses share the same subzone (The Voidspire) and therefore share the same private aura settings. Changes here apply to both encounters."
            end

            encArgs["enc_" .. encID] = {
                type   = "group",
                name   = encName,
                order  = 100 + (bossOrder * 10),
                inline = true,
                hidden = function() return paCustomizationsHidden() or selectedRaid ~= raidKey or not hasSubzone[encID] end,
                disabled = InCombatLockdown,
                args   = {
                    sharedSubzoneDesc = {
                        type = "description",
                        name = sharedSubzoneNote or "",
                        order = 0,
                        width = "full",
                        hidden = function() return not sharedSubzoneNote end,
                    },
                    showBorder = {
                        type  = "toggle",
                        name  = "Show Border",
                        desc  = "Show the private aura frame border during this encounter.",
                        order = 1,
                        get   = function()
                            local ep = getEncProfile()
                            return ep and ep.showBorder == true
                        end,
                        set   = function(_, val)
                            local ep = getEncProfile()
                            if ep then ep.showBorder = val end
                            if BF.RefreshEncounterOverrides then BF:RefreshEncounterOverrides() end
                        end,
                    },
                    hideFirstSlotBorder = {
                        type   = "toggle",
                        name   = "Hide First Slot Border",
                        desc   = "Skip the border for the first private aura slot. The border only appears when a second or later aura is active simultaneously.",
                        order  = 2,
                        hidden = function()
                            local ep = getEncProfile()
                            return not (ep and ep.showBorder)
                        end,
                        get    = function()
                            local ep = getEncProfile()
                            return ep and ep.hideFirstSlotBorder == true
                        end,
                        set    = function(_, val)
                            local ep = getEncProfile()
                            if ep then ep.hideFirstSlotBorder = val end
                            if BF.RefreshEncounterOverrides then BF:RefreshEncounterOverrides() end
                        end,
                    },
                    drawOrder = {
                        type   = "select",
                        name   = "Border Draw Order",
                        desc   = "When multiple private aura slots are active simultaneously, which slot's border renders on top.",
                        order  = 3,
                        hidden = function()
                            local ep = getEncProfile()
                            return not (ep and ep.showBorder)
                        end,
                        values = { first = "First Slot on Top", last = "Last Slot on Top" },
                        get    = function()
                            local ep = getEncProfile()
                            return (ep and ep.drawOrder) or "first"
                        end,
                        set    = function(_, val)
                            local ep = getEncProfile()
                            if ep then ep.drawOrder = val end
                            if BF.RefreshEncounterOverrides then BF:RefreshEncounterOverrides() end
                        end,
                    },
                    showOverlayBreak = { type = "description", name = "", order = 9.5, width = "full" },
                    showOverlay = {
                        type  = "toggle",
                        name  = "Show Text Overlay",
                        desc  = "This option can improve the stack count visibility on private auras.",
                        order = 10,
                        get   = function()
                            local ep = getEncProfile()
                            return ep and ep.showOverlay == true
                        end,
                        set   = function(_, val)
                            local ep = getEncProfile()
                            if ep then ep.showOverlay = val end
                            if BF.RefreshEncounterOverrides then BF:RefreshEncounterOverrides() end
                        end,
                    },
                    hideIcon = {
                        type   = "toggle",
                        name   = "Hide Icon Texture",
                        desc   = "Hide the private aura icon texture during this encounter, keeping only the border and countdown.",
                        order  = 11,
                        hidden = function() return true end,
                        get    = function()
                            local ep = getEncProfile()
                            return ep and ep.hideIcon == true
                        end,
                        set    = function(_, val)
                            local ep = getEncProfile()
                            if ep then ep.hideIcon = val end
                            if BF.RefreshEncounterIconOverrides then BF:RefreshEncounterIconOverrides() end
                        end,
                    },
                    hideAuraIndicesHeader = { type = "header", name = "Hide Private Aura Indices", order = 12 },
                    hideAuraIndex1 = {
                        type = "toggle", name = "Hide Index 1", order = 13,
                        desc = "Do not register a private aura anchor for index 1. Remaining indices shift down to fill the gap.",
                        get = function() local ep = getEncProfile(); return ep and ep.hiddenAuraIndices and ep.hiddenAuraIndices[1] or false end,
                        set = function(_, val)
                            local ep = getEncProfile(); if not ep then return end
                            if not ep.hiddenAuraIndices then ep.hiddenAuraIndices = {} end
                            ep.hiddenAuraIndices[1] = val or nil
                            if BF.RefreshEncounterIconOverrides then BF:RefreshEncounterIconOverrides() end
                        end,
                    },
                    hideAuraIndex2 = {
                        type = "toggle", name = "Hide Index 2", order = 14,
                        desc = "Do not register a private aura anchor for index 2. Remaining indices shift down to fill the gap.",
                        get = function() local ep = getEncProfile(); return ep and ep.hiddenAuraIndices and ep.hiddenAuraIndices[2] or false end,
                        set = function(_, val)
                            local ep = getEncProfile(); if not ep then return end
                            if not ep.hiddenAuraIndices then ep.hiddenAuraIndices = {} end
                            ep.hiddenAuraIndices[2] = val or nil
                            if BF.RefreshEncounterIconOverrides then BF:RefreshEncounterIconOverrides() end
                        end,
                    },
                    hideAuraIndex3 = {
                        type = "toggle", name = "Hide Index 3", order = 15,
                        desc = "Do not register a private aura anchor for index 3. Remaining indices shift down to fill the gap.",
                        get = function() local ep = getEncProfile(); return ep and ep.hiddenAuraIndices and ep.hiddenAuraIndices[3] or false end,
                        set = function(_, val)
                            local ep = getEncProfile(); if not ep then return end
                            if not ep.hiddenAuraIndices then ep.hiddenAuraIndices = {} end
                            ep.hiddenAuraIndices[3] = val or nil
                            if BF.RefreshEncounterIconOverrides then BF:RefreshEncounterIconOverrides() end
                        end,
                    },
                },
            }
        end

        -- ── Frame Border subtab ──────────────────────────────────
        -- Widgets relocated from Preview → Special Options →
        -- "Private Aura Frame Border". Storage relocated from self.db.profile
        -- / per-flat to self.acDB.profile in the §18.2 storage-namespace
        -- migration — these widgets live in the Aura Customizations section
        -- so storage belongs in acDB per the naming convention.
        --
        --   privateAuraBorderAutoScale       → BF.acDB.profile.privateAuraBorderAutoScale
        --   privateAuraBorderWidthRatio      → BF.acDB.profile.privateAuraBorderWidthRatio
        --   privateAuraBorderFrameLevel      → BF.acDB.profile.privateAuraBorderFrameLevel
        --   privateAuraFrameBorderScaleRaid  → BF.acDB.profile.privateAuraFrameBorderScaleRaid  (was per-flat, now global)
        --   privateAuraFrameBorderScaleParty → BF.acDB.profile.privateAuraFrameBorderScaleParty (was per-flat, now global)
        --
        -- Experimental gating removed from individual widgets: the
        -- parent "Private Aura Customizations" tab is already gated
        -- on enableExperimentalOptions, so everything inside it
        -- inherits that gate.
        -- Helper: refresh all active frames by re-running UpdatePrivateAuraAnchor,
        -- which re-reads the raid/party keys via isRaid per-frame. Used by every
        -- setter below so the raid variant doesn't apply to party frames and
        -- vice versa.
        local function refreshAllFramesForBorder()
            -- No combat guard: Group B (frame border) is fully separated
            -- from Group A (icons / overlay / dispel) and is combat-tolerant.
            -- AddPrivateAuraAnchor / RemovePrivateAuraAnchor calls inside
            -- DoAddBorderAnchors / ClearFrameBorderAnchors are pcall-wrapped,
            -- so if they turn out to still be combat-restricted the border
            -- simply won't re-render until combat ends — icons, overlay, and
            -- dispel are never touched here.
            if not BF.activeFrames then return end
            for frame in pairs(BF.activeFrames) do
                if frame and frame.unit then
                    BF:UpdatePrivateAuraFrameBorder(frame)
                end
            end
        end

        -- Build an inline group of border settings scoped to one group type
        -- (raid or party). Both groups are identical in structure; only the
        -- storage key suffix and the group label differ.
        --
        -- Storage keys are <base><Suffix> where Suffix is "Raid" or "Party":
        --   privateAuraBorderAutoScale<Suffix>
        --   privateAuraBorderWidthRatio<Suffix>
        --   privateAuraFrameBorderScale<Suffix>   (pre-existing keys, reused)
        --   privateAuraBorderFrameLevel<Suffix>
        local function buildBorderGroup(suffix, label, groupOrder)
            local autoScaleKey  = "privateAuraBorderAutoScale"  .. suffix
            local widthRatioKey = "privateAuraBorderWidthRatio" .. suffix
            local scaleKey      = "privateAuraFrameBorderScale" .. suffix
            local frameLevelKey = "privateAuraBorderFrameLevel" .. suffix

            return {
                type = "group", name = label, order = groupOrder, inline = true,
                args = {
                    autoScale = {
                        type = "toggle", name = "Auto Scale Border", order = 1,
                        desc = "Automatically calculate the border width ratio from the frame dimensions. Disable to set the ratio manually.",
                        get = function() return BF.acDB.profile[autoScaleKey] ~= false end,
                        set = function(_, val)
                            BF.acDB.profile[autoScaleKey] = val
                            refreshAllFramesForBorder()
                        end,
                    },
                    widthRatio = {
                        type = "range", name = "Frame Border Width Ratio", order = 2,
                        hidden = function() return BF.acDB.profile[autoScaleKey] ~= false end,
                        desc = "Adjusts the icon width ratio passed to the border anchor. Reducing this makes the border ring narrower (taller relative to width). Re-registers all anchors on change.",
                        min = 0.1, max = 10.0, step = 0.05,
                        get = function() return BF.acDB.profile[widthRatioKey] or 2.6 end,
                        set = function(_, val)
                            BF.acDB.profile[widthRatioKey] = val
                            refreshAllFramesForBorder()
                        end,
                    },
                    scale = {
                        type = "range", name = "Border Scale", order = 3,
                        desc = "Multiplier on top of the auto-calculated border scale. Leave at 1.0 to use the automatic scaling.",
                        min = 0.1, max = 1.5, step = 0.01,
                        get = function() return BF.acDB.profile[scaleKey] or 1.0 end,
                        set = function(_, val)
                            BF.acDB.profile[scaleKey] = val
                            refreshAllFramesForBorder()
                        end,
                    },
                    frameLevel = {
                        type = "range", name = "Frame Border Level Offset", order = 4,
                        desc = "Frame level offset of the border container. Default is F+14. Lower to move it below aura icons (F+23), higher to move it above. Re-applies immediately.",
                        min = 0, max = 20, step = 1,
                        get = function() return BF.acDB.profile[frameLevelKey] or 14 end,
                        set = function(_, val)
                            BF.acDB.profile[frameLevelKey] = val
                            -- Cannot use direct SetFrameLevel here because raid
                            -- frames need the raid value and party frames need
                            -- the party value. UpdatePrivateAuraAnchor -> 
                            -- LayoutPrivateAuraFrameBorderContainer re-reads
                            -- the right key per-frame via isRaid.
                            refreshAllFramesForBorder()
                        end,
                    },
                },
            }
        end

        local frameBorderArgs = {
            frameBorderDesc = {
                type = "description", order = 1, width = "full",
                name = "Registers a separate private aura anchor sized to cover the entire unit frame. The Blizzard border will appear around the frame when a private aura is present on that unit. Each group type (Raid / Party) has its own independent settings.",
            },
            raidGroup  = buildBorderGroup("Raid",  "Raid",  10),
            partyGroup = buildBorderGroup("Party", "Party", 20),
        }

        topArgs.tabPrivateAuraCustomizations = {
            type        = "group",
            name        = "Private Aura Customizations",
            order       = 100,
            -- TEMPORARILY HIDDEN: section completely hidden while debugging a
            -- frame-level rendering bug. Original gate was on enableExperimentalOptions.
            -- To restore, change `return true` back to:
            --   return not (BF.db and BF.db.profile.enableExperimentalOptions)
            hidden      = function() return true end,
            childGroups = "tab",
            args        = {
                overridesTab = {
                    type  = "group",
                    name  = "Overrides",
                    order = 1,
                    args  = encArgs,
                },
                frameBorderTab = {
                    type  = "group",
                    name  = "Frame Border",
                    order = 2,
                    hidden = paCustomizationsHidden,
                    args  = frameBorderArgs,
                },
            },
        }
    end

    return {
        type        = "group",
        name        = "Aura Customizations",
        order       = 4,
        childGroups = "tree",
        args        = topArgs,
    }
end
