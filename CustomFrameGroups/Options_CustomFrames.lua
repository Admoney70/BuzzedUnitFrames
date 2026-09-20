-- ============================================================
-- BuzzardFrames: Options_CustomFrames.lua
-- Builds and returns the "Custom Frames" nav-tab args table.
-- Called from Options.lua: BF:BuildCustomFramesOptions(deps)
--
-- SECURE HEADER CONSTRAINT:
-- The options UI enforces that nameList is mutually exclusive with
-- roleFilter and groupFilter.  When nameList is enabled, role and
-- group filters are disabled (and vice versa).  This prevents the
-- user from creating filter combinations that would require Grid2's
-- insecure header system.
--
-- roleFilter + groupFilter CAN be combined (strictFiltering=true
-- on the SecureGroupHeaderTemplate handles this natively).
-- ============================================================
local BF = _G["BuzzardFrames"]

local ROLE_VALUES = {
    TANK    = "Tank",
    HEALER  = "Healer",
    DAMAGER = "DPS",
}

-- ── Module-level state ───────────────────────────────────────────────────
local customFrameArgs = {}

-- Selected group index for the Frames tree entry (session-only)
local selectedFramesGroup = 1

-- Saved references for the Groups tree entry (set in BuildCustomFramesOptions)
local savedAddGroupButton = nil
local savedBaseLayoutDropdown = nil

-- Per-group expanded state for collapsible sections (transient, session-only)
local manageExpanded = {}
local layoutSettingsExpanded = {}
local auraSourceExpanded = {}  -- not used as collapsible; just for state tracking
local auraSettingsExpanded = {}

local function getCustomFrames()
    local p = BF.cfgDB and BF.cfgDB.profile
    if not p then return {} end
    if not p.customFrameGroups then p.customFrameGroups = {} end
    return p.customFrameGroups
end

local function getCustomFrame(index)
    return getCustomFrames()[index]
end

-- ── Raid flat helpers ──────────────────────────────────────────────────
-- Return a table of raid flat IDs → names for dropdown values/sorting.
local function getRaidFlatValues()
    local rpl = BF.rpDB and BF.rpDB.profile and BF.rpDB.profile.layouts
    local fl = rpl and rpl.flatLayouts
    if not fl then return {} end
    local t = {}
    for id, flat in pairs(fl) do
        if type(flat) == "table" and flat.type ~= "party" then
            t[id] = flat.name or id
        end
    end
    return t
end

local function getRaidFlatSorting()
    local rpl = BF.rpDB and BF.rpDB.profile and BF.rpDB.profile.layouts
    local fl = rpl and rpl.flatLayouts
    if not fl then return {} end
    local ids = {}
    for id, flat in pairs(fl) do
        if type(flat) == "table" and flat.type ~= "party" then
            ids[#ids + 1] = id
        end
    end
    table.sort(ids, function(a, b)
        local na = fl[a].name or a
        local nb = fl[b].name or b
        return na:lower() < nb:lower()
    end)
    return ids
end

-- Return the first raid flat ID (alphabetically by name) as the default
-- base layout for new CFGs.
local function getDefaultRaidFlatID()
    local sorted = getRaidFlatSorting()
    return sorted[1]
end

-- Return the actual raid flat table for a given flat ID.
local function getRaidFlat(flatID)
    if not flatID then return nil end
    local rpl = BF.rpDB and BF.rpDB.profile and BF.rpDB.profile.layouts
    local fl = rpl and rpl.flatLayouts
    return fl and fl[flatID]
end

-- ── CFG flat ID helpers ───────────────────────────────────────────────
-- Each CFG flat gets a stable unique ID (stored in flat.cfgFlatID) so it
-- can be referenced reliably even after groups are deleted or reordered.
local function newCFGFlatID()
    local groups = getCustomFrames()
    local used = {}
    for _, grp in ipairs(groups) do
        if grp and grp.flat and grp.flat.cfgFlatID then
            used[grp.flat.cfgFlatID] = true
        end
    end
    local i = 1
    while used["cfg_flat_" .. i] do
        i = i + 1
    end
    return "cfg_flat_" .. i
end

-- Ensure all existing CFG flats have a stable ID (migration for
-- groups created before this feature was added).
local function ensureCFGFlatIDs()
    local groups = getCustomFrames()
    for _, grp in ipairs(groups) do
        if grp and grp.flat and not grp.flat.cfgFlatID then
            grp.flat.cfgFlatID = newCFGFlatID()
        end
    end
end

-- ── Source layout helpers (raid flats + existing CFG flats) ───────────
-- Used by the "Initial Source Layout" dropdown so new CFGs can be seeded
-- from either a raid layout or an existing custom frame group layout.
local function getSourceLayoutValues()
    ensureCFGFlatIDs()
    local t = getRaidFlatValues()
    local groups = getCustomFrames()
    for i, grp in ipairs(groups) do
        if grp and grp.flat and grp.flat.cfgFlatID then
            local name = grp.flat.name or grp.name or ("Group " .. i)
            t[grp.flat.cfgFlatID] = "Custom Frame Group: " .. name
        end
    end
    return t
end

local function getSourceLayoutSorting()
    ensureCFGFlatIDs()
    local ids = getRaidFlatSorting()
    -- Append CFG entries after the raid layouts, in tab order
    local groups = getCustomFrames()
    for i, grp in ipairs(groups) do
        if grp and grp.flat and grp.flat.cfgFlatID then
            ids[#ids + 1] = grp.flat.cfgFlatID
        end
    end
    return ids
end

-- Resolve a source layout ID to the actual flat table.
-- Handles both raid flat IDs and cfg_flat_N CFG flat IDs.
local function getSourceFlat(flatID)
    if not flatID then return nil end
    if flatID:match("^cfg_flat_") then
        local groups = getCustomFrames()
        for _, grp in ipairs(groups) do
            if grp and grp.flat and grp.flat.cfgFlatID == flatID then
                return grp.flat
            end
        end
        return nil
    end
    return getRaidFlat(flatID)
end

-- ── Flat layout accessors ───────────────────────────────────────────────
-- Each CFG group stores its layout/aura/sorting settings in group.flat,
-- which has the same structure as raid flats in rpDB. These helpers
-- provide safe access to the flat and its sub-tables.
local function getCFFlat(index)
    local cf = getCustomFrames()[index]
    return cf and cf.flat
end

local function getCFFlatSorting(index)
    local flat = getCFFlat(index)
    return flat and flat.sorting
end

-- ── Lightweight refresh: syncs visual settings to live headers ────────────
-- Used for frame size, spacing, scale, grow direction, borders, modules, icons.
-- RefreshCustomFrameHeaders is already debounced internally (0.05s), and the
-- test frame update is included in its debounced callback.
local function RefreshCustomFrames()
    if InCombatLockdown() then return end
    if BF.RefreshCustomFrameHeaders then
        BF:RefreshCustomFrameHeaders()
    end
    if BF.UpdateCustomFrameTestFrames then
        BF:UpdateCustomFrameTestFrames()
    end
end

-- ── Full layout reload for structural changes ────────────────────────────
-- Used for adding/removing groups, enable/disable, filter changes, visibility.
local function ReloadCustomFrames()
    if InCombatLockdown() then return end
    if BF.ReloadCustomFrameHeadersOnly then
        BF:ReloadCustomFrameHeadersOnly()
    elseif BF.ReloadLayout then
        BF:ReloadLayout(true)
    end
    if BF.UpdateCustomFrameTestFrames then
        BF:UpdateCustomFrameTestFrames()
    end
end

-- ── Build one custom frame group's options tab ───────────────────────────
local function buildCustomFrameGroupOptions(index, NotifyChangeSafe)
    local function get(info)
        local cf = getCustomFrame(index)
        if not cf then return nil end
        return cf[info[#info]]
    end
    local function set(info, val)
        if InCombatLockdown() then return end
        local cf = getCustomFrame(index)
        if not cf then return end
        cf[info[#info]] = val
        RefreshCustomFrames()
    end

    -- Helper: is nameList the active filter mode?
    local function isNameListMode()
        local cf = getCustomFrame(index)
        return cf and cf.nameListEnabled == true
    end

    -- Helper: is role/group filter mode active (i.e. nameList is NOT active)?
    local function isRoleGroupMode()
        local cf = getCustomFrame(index)
        return cf and cf.nameListEnabled ~= true
    end

    local function isManageExpanded()
        return manageExpanded[index] == true
    end

    local function isAuraSettingsExpanded()
        return auraSettingsExpanded[index] == true
    end


    local function isLayoutSettingsExpanded()
        return layoutSettingsExpanded[index] == true
    end


    local args = {
        -- ── Visibility ────────────────────────────────────────────────────
        visibilityGroup = {
            type = "group", name = "Show Custom Frame Group", inline = true, order = 55,
            args = {
                showSolo = {
                    type = "toggle", name = "Show Solo", order = 1, width = 0.7,
                    desc = "Show this custom frame group when solo.",
                    get = function()
                        local cf = getCustomFrame(index)
                        if not cf then return true end
                        return cf.showSolo ~= false
                    end,
                    set = function(_, val)
                        if InCombatLockdown() then return end
                        local cf = getCustomFrame(index)
                        if not cf then return end
                        cf.showSolo = val
                        ReloadCustomFrames()
                    end,
                    disabled = InCombatLockdown,
                },
                showInParty = {
                    type = "toggle", name = "Show in Party", order = 2, width = 0.7,
                    desc = "Show this custom frame group when in a party.",
                    get = function()
                        local cf = getCustomFrame(index)
                        if not cf then return true end
                        return cf.showInParty ~= false
                    end,
                    set = function(_, val)
                        if InCombatLockdown() then return end
                        local cf = getCustomFrame(index)
                        if not cf then return end
                        cf.showInParty = val
                        ReloadCustomFrames()
                    end,
                    disabled = InCombatLockdown,
                },
                showInRaid = {
                    type = "toggle", name = "Show in Raid", order = 3, width = 0.7,
                    desc = "Show this custom frame group when in a raid.",
                    get = function()
                        local cf = getCustomFrame(index)
                        if not cf then return true end
                        return cf.showInRaid ~= false
                    end,
                    set = function(_, val)
                        if InCombatLockdown() then return end
                        local cf = getCustomFrame(index)
                        if not cf then return end
                        cf.showInRaid = val
                        ReloadCustomFrames()
                    end,
                    disabled = InCombatLockdown,
                },
            },
        },

        -- ── Filter Mode Selection ─────────────────────────────────────────
        filterHeader = { type = "header", name = "Unit Filters", order = 10 },
        filterModeDesc = {
            type = "description", order = 10.5, width = "full",
            name = "Choose a filter mode. Role and Group filters can be combined, "
                .. "but Name List filtering is a separate mode and cannot be used "
                .. "with Role or Group filters.",
        },

        filterMode = {
            type = "select", name = "Filter Mode", order = 11, width = "double",
            desc = "Select how this custom frame group filters units.\n\n"
                .. "|cff00ff00Role / Group|r — Filter by assigned role and/or raid group number. "
                .. "These can be combined (a unit must match both).\n\n"
                .. "|cff00ff00Name List|r — Show only specific players by name. "
                .. "Cannot be combined with Role or Group filters.",
            values = {
                rolegroup = "Role / Group Filter",
                namelist  = "Name List Filter",
            },
            sorting = { "rolegroup", "namelist" },
            get = function()
                local cf = getCustomFrame(index)
                if cf and cf.nameListEnabled then return "namelist" end
                return "rolegroup"
            end,
            set = function(_, val)
                if InCombatLockdown() then return end
                local cf = getCustomFrame(index)
                if not cf then return end
                if val == "namelist" then
                    cf.nameListEnabled   = true
                    -- Disable role/group when switching to nameList
                    -- (secure header constraint: mutually exclusive)
                    cf.roleFilterEnabled  = false
                    cf.groupFilterEnabled = false
                else
                    cf.nameListEnabled = false
                end
                ReloadCustomFrames()
                NotifyChangeSafe()
            end,
            disabled = InCombatLockdown,
        },

        -- ── Exclude Self ─────────────────────────────────────────────────
        excludePlayer = {
            type = "toggle", name = "Exclude Self (Party/Solo Only)", order = 12,
            desc = "When enabled, your own character will not appear in this custom frame group when in a party or solo.",
            hidden = isNameListMode,
            get = function()
                local cf = getCustomFrame(index)
                return cf and cf.excludePlayer == true
            end,
            set = function(_, val)
                if InCombatLockdown() then return end
                local cf = getCustomFrame(index)
                if not cf then return end
                cf.excludePlayer = val or nil
                ReloadCustomFrames()
            end,
            disabled = InCombatLockdown,
        },

        -- (filterByNote removed — redundant with filterMode tooltip)

        -- ── Filter By (toggle which filter categories are active) ─────
        filterByGroup = {
            type = "group", name = "Filter By", inline = true, order = 13,
            hidden = isNameListMode,
            args = {
                filterByRole = {
                    type = "toggle", name = "Role", order = 1, width = 0.5,
                    desc = "When enabled, only units matching the selected roles will be shown.",
                    get = function()
                        local cf = getCustomFrame(index)
                        return cf and cf.roleFilterEnabled == true
                    end,
                    set = function(_, val)
                        if InCombatLockdown() then return end
                        local cf = getCustomFrame(index)
                        if not cf then return end
                        cf.roleFilterEnabled = val
                        ReloadCustomFrames()
                    end,
                    disabled = InCombatLockdown,
                },
                filterByClass = {
                    type = "toggle", name = "Class", order = 2, width = 0.5,
                    desc = "When enabled, only units of the selected classes will be shown.",
                    get = function()
                        local cf = getCustomFrame(index)
                        return cf and cf.classFilterEnabled == true
                    end,
                    set = function(_, val)
                        if InCombatLockdown() then return end
                        local cf = getCustomFrame(index)
                        if not cf then return end
                        cf.classFilterEnabled = val
                        if not val and cf.classFilter then
                            table.wipe(cf.classFilter)
                        end
                        ReloadCustomFrames()
                    end,
                    disabled = InCombatLockdown,
                },
                filterByRaidGroup = {
                    type = "toggle", name = "Raid Group", order = 3, width = 0.6,
                    desc = "When enabled, only units in the selected raid groups will be shown.",
                    get = function()
                        local cf = getCustomFrame(index)
                        return cf and cf.groupFilterEnabled == true
                    end,
                    set = function(_, val)
                        if InCombatLockdown() then return end
                        local cf = getCustomFrame(index)
                        if not cf then return end
                        cf.groupFilterEnabled = val
                        ReloadCustomFrames()
                    end,
                    disabled = InCombatLockdown,
                },
            },
        },

        -- ── Filter: Roles (shown when Role toggle is on) ─────────────────
        roleFilterGroup = {
            type = "group", name = "Role Filter", inline = true, order = 20,
            hidden = function()
                if isNameListMode() then return true end
                local cf = getCustomFrame(index)
                return not cf or not cf.roleFilterEnabled
            end,
            args = {
                roleMainTank = {
                    type = "toggle", name = "Main Tank", order = 1, width = 0.6,
                    desc = "Show units assigned as Main Tank (manual raid assignment).",
                    get = function() local cf = getCustomFrame(index); return cf and cf.roleFilter and cf.roleFilter.MAINTANK end,
                    set = function(_, val)
                        if InCombatLockdown() then return end
                        local cf = getCustomFrame(index)
                        if not cf then return end
                        if not cf.roleFilter then cf.roleFilter = {} end
                        cf.roleFilter.MAINTANK = val or nil
                        ReloadCustomFrames()
                    end,
                    disabled = InCombatLockdown,
                },
                roleMainAssist = {
                    type = "toggle", name = "Main Assist", order = 1.7, width = 0.6,
                    desc = "Show units assigned as Main Assist (manual raid assignment).",
                    get = function() local cf = getCustomFrame(index); return cf and cf.roleFilter and cf.roleFilter.MAINASSIST end,
                    set = function(_, val)
                        if InCombatLockdown() then return end
                        local cf = getCustomFrame(index)
                        if not cf then return end
                        if not cf.roleFilter then cf.roleFilter = {} end
                        cf.roleFilter.MAINASSIST = val or nil
                        ReloadCustomFrames()
                    end,
                    disabled = InCombatLockdown,
                },
                roleTank = {
                    type = "toggle", name = "Tank", order = 2, width = 0.5,
                    get = function() local cf = getCustomFrame(index); return cf and cf.roleFilter and cf.roleFilter.TANK end,
                    set = function(_, val)
                        if InCombatLockdown() then return end
                        local cf = getCustomFrame(index)
                        if not cf then return end
                        if not cf.roleFilter then cf.roleFilter = {} end
                        cf.roleFilter.TANK = val or nil
                        ReloadCustomFrames()
                    end,
                    disabled = InCombatLockdown,
                },
                roleHealer = {
                    type = "toggle", name = "Healer", order = 3, width = 0.5,
                    get = function() local cf = getCustomFrame(index); return cf and cf.roleFilter and cf.roleFilter.HEALER end,
                    set = function(_, val)
                        if InCombatLockdown() then return end
                        local cf = getCustomFrame(index)
                        if not cf then return end
                        if not cf.roleFilter then cf.roleFilter = {} end
                        cf.roleFilter.HEALER = val or nil
                        ReloadCustomFrames()
                    end,
                    disabled = InCombatLockdown,
                },
                roleDamager = {
                    type = "toggle", name = "DPS", order = 4, width = 0.5,
                    get = function() local cf = getCustomFrame(index); return cf and cf.roleFilter and cf.roleFilter.DAMAGER end,
                    set = function(_, val)
                        if InCombatLockdown() then return end
                        local cf = getCustomFrame(index)
                        if not cf then return end
                        if not cf.roleFilter then cf.roleFilter = {} end
                        cf.roleFilter.DAMAGER = val or nil
                        ReloadCustomFrames()
                    end,
                    disabled = InCombatLockdown,
                },
            },
        },

        -- ── Filter: Class (shown when Class toggle is on) ────────────────
        classFilterGroup = {
            type = "group", name = "Class Filter", inline = true, order = 25,
            hidden = function()
                if isNameListMode() then return true end
                local cf = getCustomFrame(index)
                return not cf or not cf.classFilterEnabled
            end,
            args = {},
        },

        -- ── Filter: Raid Groups (shown when Raid Group toggle is on) ─────
        groupFilterGroup = {
            type = "group", name = "Group Filter", inline = true, order = 30,
            hidden = function()
                if isNameListMode() then return true end
                local cf = getCustomFrame(index)
                return not cf or not cf.groupFilterEnabled
            end,
            args = {},
        },
    }

    -- Class checkboxes — dynamically filtered to only show classes that
    -- can perform the currently selected roles. Added into classFilterGroup.
    do
        local classArgs = args.classFilterGroup.args
        local classOrder = 1
        for _, cls in ipairs(BF.CLASS_SORT_ORDER_ALPHA) do
            local classToken = cls  -- capture for closures
            classArgs["class_" .. cls] = {
                type = "toggle",
                name = function()
                    -- Use class-coloured name if RAID_CLASS_COLORS is available
                    local display = BF.CLASS_DISPLAY_NAMES[classToken] or classToken
                    local cc = RAID_CLASS_COLORS and RAID_CLASS_COLORS[classToken]
                    if cc then
                        return string.format("|cff%02x%02x%02x%s|r",
                            cc.r * 255, cc.g * 255, cc.b * 255, display)
                    end
                    return display
                end,
                order = classOrder,
                width = 0.6,
                hidden = function()
                    -- If role filter is active AND at least one spec-role
                    -- (Tank/Healer/DPS) is checked, only show classes eligible
                    -- for those roles.  Main Tank / Main Assist are raid
                    -- assignments that any class can hold, so when either is
                    -- selected the full class list is shown.
                    local cf = getCustomFrame(index)
                    if not cf then return true end
                    if cf.roleFilterEnabled and cf.roleFilter then
                        local rf = cf.roleFilter
                        if rf.MAINTANK or rf.MAINASSIST then
                            return false
                        end
                        local anySpecRole = false
                        local eligible = false
                        for _, role in ipairs({"TANK", "HEALER", "DAMAGER"}) do
                            if rf[role] then
                                anySpecRole = true
                                if BF.ROLE_CLASSES[role] and BF.ROLE_CLASSES[role][classToken] then
                                    eligible = true
                                end
                            end
                        end
                        if anySpecRole then
                            return not eligible
                        end
                    end
                    return false
                end,
                get = function()
                    local cf = getCustomFrame(index)
                    return cf and cf.classFilter and cf.classFilter[classToken]
                end,
                set = function(_, val)
                    if InCombatLockdown() then return end
                    local cf = getCustomFrame(index)
                    if not cf then return end
                    if not cf.classFilter then cf.classFilter = {} end
                    cf.classFilter[classToken] = val or nil
                    ReloadCustomFrames()
                end,
                disabled = InCombatLockdown,
            }
            classOrder = classOrder + 0.01
        end
    end

    -- Group 1-8 checkboxes — added into groupFilterGroup.
    do
        local groupArgs = args.groupFilterGroup.args
        for i = 1, 8 do
            groupArgs["group" .. i] = {
                type = "toggle", name = "Group " .. i, order = i, width = 0.5,
                get = function()
                    local cf = getCustomFrame(index)
                    return cf and cf.groupFilter and cf.groupFilter[i]
                end,
                set = function(_, val)
                    if InCombatLockdown() then return end
                    local cf = getCustomFrame(index)
                    if not cf then return end
                    if not cf.groupFilter then cf.groupFilter = {} end
                    cf.groupFilter[i] = val or nil
                    ReloadCustomFrames()
                end,
                disabled = InCombatLockdown,
            }
        end
    end

    -- ── Layout header (only shown in rolegroup mode) ───────────────────
    args.cfgLayoutHeader = {
        type = "header", name = "Custom Frame Group Layout", order = 39,
        hidden = isNameListMode,
    }

    -- ── Sorting / Group By (only shown in rolegroup mode) ─────────────
    args.sortingGroup = {
        type = "group", name = "Sorting", inline = true, order = 40,
        hidden = isNameListMode,
        args = {
            groupBy = {
                type = "select", name = "Group By", order = 1,
                desc = "Pre-sort units into visual sub-groups within this custom frame group.",
                width = 1.2,
                values = {
                    NONE         = "None",
                    GROUP        = "Raid Group",
                    ASSIGNEDROLE = "Role",
                    CLASS        = "Class",
                },
                sorting = { "NONE", "GROUP", "ASSIGNEDROLE", "CLASS" },
                get = function()
                    local cf = getCustomFrame(index)
                    return cf and cf.groupBy or "NONE"
                end,
                set = function(_, val)
                    if InCombatLockdown() then return end
                    local cf = getCustomFrame(index)
                    if not cf then return end
                    cf.groupBy = val ~= "NONE" and val or nil
                    ReloadCustomFrames()
                end,
                disabled = InCombatLockdown,
            },
            sortMethod = {
                type = "select", name = "Sort Method", order = 2,
                desc = "How units are sorted within each sub-group (or overall if Group By is None).",
                width = 1.2,
                values = {
                    INDEX = "Index (default)",
                    NAME  = "Name",
                },
                sorting = { "INDEX", "NAME" },
                get = function()
                    local cf = getCustomFrame(index)
                    return cf and cf.sortMethod or "INDEX"
                end,
                set = function(_, val)
                    if InCombatLockdown() then return end
                    local cf = getCustomFrame(index)
                    if not cf then return end
                    cf.sortMethod = val ~= "INDEX" and val or nil
                    ReloadCustomFrames()
                end,
                disabled = InCombatLockdown,
            },
        },
    }

    -- ── Layout: Grow Direction, Max Columns, Units Per Column ────────────
    -- (Moved from the old "Frames - Sorting" tree entry so each group's
    -- layout settings live alongside its sorting options.)
    local function getCFGHeaderForIndex()
        for _, header in ipairs(BF.groupsUsed or {}) do
            if header.isCustomFrame and header.customGroupIndex == index then
                return header
            end
        end
    end
    local function recalcPosition(newLA)
        local header = getCFGHeaderForIndex()
        if not header or not header:GetLeft() then return end
        local ux, uy = UIParent:GetCenter()
        if not ux or not uy then return end
        local newX = newLA:find("LEFT") and header:GetLeft() or header:GetRight()
        local newY = newLA:find("TOP")  and header:GetTop()  or header:GetBottom()
        if not newX or not newY then return end
        local posKey = "customFrame_" .. index
        local cfgp = BF.cfgDB and BF.cfgDB.profile
        if not cfgp then return end
        if not cfgp.customFrameGroupPositions then
            cfgp.customFrameGroupPositions = {}
        end
        cfgp.customFrameGroupPositions[posKey] = {
            newLA,
            math.floor(newX - ux + 0.5),
            math.floor(newY - uy + 0.5),
        }
    end

    args.growDirectionGroup = {
        type = "group", name = "Grow Direction", inline = true, order = 54,
        args = {
            growDirection = {
                type = "select", name = "Grow Direction", order = 1,
                desc = "Which direction frames grow from the anchor point.",
                values = {
                    DOWN  = "Down (vertical)",
                    UP    = "Up (vertical)",
                    RIGHT = "Right (horizontal)",
                    LEFT  = "Left (horizontal)",
                },
                sorting = { "DOWN", "UP", "RIGHT", "LEFT" },
                get = function()
                    local sorting = getCFFlatSorting(index)
                    if not sorting then return "DOWN" end
                    local dir = sorting.raidGrowDirection
                    if dir == "RIGHT" or dir == "UP" or dir == "LEFT" then return dir end
                    return "DOWN"
                end,
                set = function(_, val)
                    if InCombatLockdown() then return end
                    local flat = getCFFlat(index); if not flat then return end
                    if not flat.sorting then flat.sorting = {} end
                    local sorting = flat.sorting
                    local oldDir = sorting.raidGrowDirection or "DOWN"
                    local oldH = (oldDir == "RIGHT" or oldDir == "LEFT")
                    local newH = (val == "RIGHT" or val == "LEFT")
                    local newSec = sorting.raidSecondaryGrowDirection
                    if oldH ~= newH then newSec = nil end
                    if not newSec then newSec = newH and "DOWN" or "RIGHT" end
                    local newLA = BF:DeriveGroupAnchor(val, newSec)
                    recalcPosition(newLA)
                    if oldH ~= newH then
                        sorting.raidSecondaryGrowDirection = nil
                    end
                    sorting.raidGrowDirection = val
                    flat.raidLayoutAnchor = newLA
                    RefreshCustomFrames()
                end,
                disabled = InCombatLockdown,
            },
            secondaryGrowDirection = {
                type = "select", name = "Secondary Grow Direction", order = 2,
                desc = "Which direction columns/rows extend perpendicular to the primary grow direction.",
                values = function()
                    local sorting = getCFFlatSorting(index)
                    local dir = sorting and sorting.raidGrowDirection
                    if dir == "RIGHT" or dir == "LEFT" then
                        return { DOWN = "Down", UP = "Up" }
                    else
                        return { RIGHT = "Right", LEFT = "Left" }
                    end
                end,
                sorting = function()
                    local sorting = getCFFlatSorting(index)
                    local dir = sorting and sorting.raidGrowDirection
                    if dir == "RIGHT" or dir == "LEFT" then
                        return { "DOWN", "UP" }
                    else
                        return { "RIGHT", "LEFT" }
                    end
                end,
                get = function()
                    local sorting = getCFFlatSorting(index)
                    local sec = sorting and sorting.raidSecondaryGrowDirection
                    if sec then return sec end
                    local dir = sorting and sorting.raidGrowDirection
                    if dir == "RIGHT" or dir == "LEFT" then return "DOWN" end
                    return "RIGHT"
                end,
                set = function(_, val)
                    if InCombatLockdown() then return end
                    local flat = getCFFlat(index); if not flat then return end
                    if not flat.sorting then flat.sorting = {} end
                    local sorting = flat.sorting
                    local dir = sorting.raidGrowDirection or "DOWN"
                    local isDefault = ((dir == "RIGHT" or dir == "LEFT") and val == "DOWN")
                                   or ((dir == "DOWN" or dir == "UP") and val == "RIGHT")
                    local secVal = (not isDefault) and val or nil
                    local newLA = BF:DeriveGroupAnchor(dir, secVal)
                    recalcPosition(newLA)
                    sorting.raidSecondaryGrowDirection = secVal
                    flat.raidLayoutAnchor = newLA
                    RefreshCustomFrames()
                end,
                disabled = InCombatLockdown,
            },
        },
    }
    args.columnsGroup = {
        type = "group", name = "Layout", inline = true, order = 54.5,
        args = {
            cfMaxColumns = {
                type = "range", order = 1,
                name = function()
                    local sorting = getCFFlatSorting(index)
                    local dir = sorting and sorting.raidGrowDirection
                    return (dir == "RIGHT" or dir == "LEFT") and "Max Rows to Show" or "Max Columns to Show"
                end,
                desc = "Maximum number of columns (vertical) or rows (horizontal) to display.",
                min = 1, max = 40, step = 1,
                get = function() local sorting = getCFFlatSorting(index); return (sorting and sorting.maxColumns) or 4 end,
                set = function(_, val)
                    if InCombatLockdown() then return end
                    local flat = getCFFlat(index); if not flat then return end
                    if not flat.sorting then flat.sorting = {} end
                    flat.sorting.maxColumns = val
                    RefreshCustomFrames()
                end,
                disabled = InCombatLockdown,
            },
            cfUnitsPerColumn = {
                type = "range", order = 2,
                name = function()
                    local sorting = getCFFlatSorting(index)
                    local dir = sorting and sorting.raidGrowDirection
                    return (dir == "RIGHT" or dir == "LEFT") and "Units per Row" or "Units per Column"
                end,
                desc = "Units per column (vertical) or per row (horizontal).",
                min = 1, max = 40, step = 1,
                get = function() local sorting = getCFFlatSorting(index); return (sorting and sorting.unitsPerColumn) or 5 end,
                set = function(_, val)
                    if InCombatLockdown() then return end
                    local flat = getCFFlat(index); if not flat then return end
                    if not flat.sorting then flat.sorting = {} end
                    flat.sorting.unitsPerColumn = val
                    RefreshCustomFrames()
                end,
                disabled = InCombatLockdown,
            },
        },
    }

    -- ── Filter: Name List (only shown in namelist mode) ───────────────────
    args.nameListHeader = {
        type = "header", name = "Name List Filter", order = 50,
        hidden = isRoleGroupMode,
    }
    args.nameListDesc = {
        type = "description", order = 50.5, width = "full",
        name = "Enter player names separated by commas. Only players whose names "
            .. "appear in this list will be shown. Names are case-sensitive and "
            .. "should match the in-game character name exactly.",
        hidden = isRoleGroupMode,
    }
    args.nameList = {
        type = "input", name = "Player Names", order = 52,
        desc = "Enter player names separated by commas or newlines.",
        width = "full", multiline = 5,
        hidden = isRoleGroupMode,
        get = function()
            local cf = getCustomFrame(index)
            if not cf or not cf.nameList then return "" end
            return cf.nameList:gsub(",", ", ")
        end,
        set = function(_, val)
            if InCombatLockdown() then return end
            local cf = getCustomFrame(index)
            if not cf then return end
            -- Parse: split on newline, comma, semicolon; trim whitespace; rejoin
            local names = {}
            for name in val:gmatch("[^,;\n]+") do
                name = strtrim(name)
                if name ~= "" then
                    names[#names + 1] = name
                end
            end
            cf.nameList = table.concat(names, ",")
            ReloadCustomFrames()
        end,
        disabled = InCombatLockdown,
    }

    -- ── Keybind: Add/Remove names via mouseover (nameList mode only) ──
    args.keybindGroup = {
        type = "group", name = "Mouseover Keybind", inline = true, order = 53.2,
        hidden = isRoleGroupMode,
        args = {
            enableKeybindAdd = {
                type = "toggle", name = "Enable Mouseover Keybind", order = 1,
                desc = "When enabled, you can press a keybind while mousing over a player "
                    .. "to add or remove them from this group's name list.",
                width = "double",
                get = function()
                    local cf = getCustomFrame(index)
                    return cf and cf.enableKeybindAdd == true
                end,
                set = function(_, val)
                    if InCombatLockdown() then return end
                    local cf = getCustomFrame(index)
                    if not cf then return end
                    cf.enableKeybindAdd = val
                    ReloadCustomFrames()
                end,
                disabled = InCombatLockdown,
            },
            toggleNameKey = {
                type = "keybinding", name = "Add/Remove Name Keybind", order = 2,
                desc = "Press this key while mousing over a player to add them to the name list. "
                    .. "Press again while mousing over them to remove them.",
                width = 1.0,
                hidden = function()
                    local cf = getCustomFrame(index)
                    return not cf or not cf.enableKeybindAdd
                end,
                get = function()
                    local cf = getCustomFrame(index)
                    return cf and cf.toggleNameKey or ""
                end,
                set = function(_, val)
                    if InCombatLockdown() then return end
                    local cf = getCustomFrame(index)
                    if not cf then return end
                    cf.toggleNameKey = val ~= "" and val or nil
                    ReloadCustomFrames()
                end,
                disabled = InCombatLockdown,
            },
        },
    }

    -- Layout Settings have been moved to the "Frames" tree entry.

    -- Aura Settings have been moved to the "Auras" tree entry.

    -- Module toggle sections removed — replaced by per-section override tabs
    -- (Borders & Highlights, Icons, etc.) in Options_CustomFrameSections.lua

    -- ── Sorting (nameList mode only) ───────────────────────────────
    args.nameListSortingHeader = {
        type = "header", name = "Custom Frame Group Layout", order = 53.5,
        hidden = isRoleGroupMode,
    }
    args.nameListGroupBy = {
        type = "select", name = "Sort By", order = 53.6,
        desc = "Choose how units are sorted in this custom frame group.\n\n"
            .. "|cff00ff00Name List Order|r -- Display in the order names were entered.\n"
            .. "|cff00ff00Class|r -- Group units by class.",
        width = 1.2,
        hidden = isRoleGroupMode,
        values = {
            NONE  = "Name List Order",
            CLASS = "Class",
        },
        sorting = { "NONE", "CLASS" },
        get = function()
            local cf = getCustomFrame(index)
            return cf and cf.nameListGroupBy or "NONE"
        end,
        set = function(_, val)
            if InCombatLockdown() then return end
            local cf = getCustomFrame(index)
            if not cf then return end
            cf.nameListGroupBy = val ~= "NONE" and val or nil
            RefreshCustomFrames()
        end,
        disabled = InCombatLockdown,
    }

    -- ── Clear Name List (nameList mode only) ─────────────────────────────
    args.clearNameList = {
        type = "execute", name = "Clear Name List", order = 53,
        desc = "Remove all names from this group's name list.",
        width = "normal",
        hidden = isRoleGroupMode,
        confirm = function()
            local cf = getCustomFrame(index)
            local count = 0
            if cf and cf.nameList and cf.nameList ~= "" then
                for _ in cf.nameList:gmatch("[^,]+") do count = count + 1 end
            end
            return "Clear all " .. count .. " name(s) from this group?"
        end,
        func = function()
            if InCombatLockdown() then return end
            local cf = getCustomFrame(index)
            if not cf then return end
            cf.nameList = ""
            ReloadCustomFrames()
            NotifyChangeSafe()
        end,
        disabled = function()
            if InCombatLockdown() then return true end
            local cf = getCustomFrame(index)
            return not cf or not cf.nameList or cf.nameList == ""
        end,
    }

    -- ── [+] Manage Custom Frame Group (collapsible, mirrors container pattern) ──
    args.manageHeader = { type = "header", name = "Manage Custom Frame Group", order = 100 }
    args.manageToggle = {
        type = "execute",
        name = function()
            return isManageExpanded() and "[-] Manage" or "[+] Manage"
        end,
        order = 101, width = "normal",
        func = function()
            manageExpanded[index] = not isManageExpanded()
            NotifyChangeSafe()
        end,
        disabled = InCombatLockdown,
    }
    args.manageSpacer = {
        type = "description", name = "", order = 101.5, width = "full",
        hidden = function() return not isManageExpanded() end,
    }
    args.manageName = {
        type = "input", name = "Rename Custom Frame Group",
        order = 102, width = "double",
        hidden = function() return not isManageExpanded() end,
        get = get,
        set = function(_, val)
            if InCombatLockdown() then return end
            local cf = getCustomFrame(index)
            if not cf then return end
            cf.name = val ~= "" and val or ("Group " .. index)
            if cf.flat then cf.flat.name = cf.name end
            NotifyChangeSafe()
        end,
        disabled = InCombatLockdown,
    }
    args.manageEnabled = {
        type = "toggle", name = "Enable", order = 103,
        desc = "Enable or disable this custom frame group.",
        hidden = function() return not isManageExpanded() end,
        get = function()
            local cf = getCustomFrame(index)
            return cf and cf.enabled ~= false
        end,
        set = function(_, val)
            if InCombatLockdown() then return end
            local cf = getCustomFrame(index)
            if not cf then return end
            cf.enabled = val
            ReloadCustomFrames()
            NotifyChangeSafe()
        end,
        disabled = InCombatLockdown,
    }
    args.manageRemove = {
        type = "execute", name = "Remove Custom Frame Group",
        order = 104, width = "normal",
        hidden = function() return not isManageExpanded() end,
        confirm = function() return "Remove this custom frame group?" end,
        func = function()
            if InCombatLockdown() then return end
            local groups = getCustomFrames()
            -- Clean up saved position for this group (positions live in cfgDB)
            local cfgp = BF.cfgDB and BF.cfgDB.profile
            if cfgp and cfgp.customFrameGroupPositions then
                cfgp.customFrameGroupPositions["customFrame_" .. index] = nil
                -- Shift positions for groups above this index
                for j = index + 1, #groups do
                    local oldKey = "customFrame_" .. j
                    local newKey = "customFrame_" .. (j - 1)
                    cfgp.customFrameGroupPositions[newKey] = cfgp.customFrameGroupPositions[oldKey]
                    cfgp.customFrameGroupPositions[oldKey] = nil
                end
            end
            -- Clean up the setup mode test header pool (shift entries
            -- down so they stay in sync with the groups array).
            if BF.RemoveCustomFrameTestHeader then
                BF:RemoveCustomFrameTestHeader(index)
            end
            table.remove(groups, index)
            manageExpanded[index] = nil
            -- Rebuild the options tree
            BF:RebuildCustomFrameArgs(NotifyChangeSafe)
            ReloadCustomFrames()
            NotifyChangeSafe()
        end,
        disabled = InCombatLockdown,
    }

    -- Setup Mode settings have been moved to the "Frames" tree entry.

    return args
end

-- ── Rebuild the dynamic container args table ─────────────────────────────
function BF:RebuildCustomFrameArgs(NotifyChangeSafe)
    -- Wipe dynamic group entries but preserve stable tree nodes so AceConfig's
    -- tree state (selected tab, expanded nodes) survives the rebuild.
    -- "groups" is preserved and its args rebuilt in-place (same table reference).
    -- Per-section tree entries (auraText, text, healthPower, borders, absorbs,
    -- icons, tooltips) are built once in BuildCustomFramesOptions and must also
    -- be preserved — otherwise adding/removing a CFG wipes them from the nav.
    local preserve = {
        groups = true, auras = true, enableCustomFrames = true,
        framesSizePos = true, cfgDescription = true,
        -- Per-section tree entries (Options_CustomFrameSections.lua)
        auraText = true, text = true, healthPower = true, borders = true,
        absorbs = true, icons = true, tooltips = true,
    }
    for k in pairs(customFrameArgs) do
        if not preserve[k] then
            customFrameArgs[k] = nil
        end
    end

    -- ── Groups tree entry ──────────────────────────────────────────────
    -- Rebuild args in-place if groups already exists, otherwise create it.
    local groupsArgs
    if customFrameArgs.groups then
        groupsArgs = customFrameArgs.groups.args
        -- Wipe old group entries but keep the addGroup button
        for k in pairs(groupsArgs) do
            if k ~= "addGroup" and k ~= "cfgBaseLayout" then
                groupsArgs[k] = nil
            end
        end
    else
        groupsArgs = {}
    end
    if savedBaseLayoutDropdown then groupsArgs.cfgBaseLayout = savedBaseLayoutDropdown end
    if savedAddGroupButton then groupsArgs.addGroup = savedAddGroupButton end

    local groups = getCustomFrames()
    for i, cf in ipairs(groups) do
        groupsArgs["group_" .. i] = {
            type  = "group",
            name  = function()
                local g = getCustomFrame(i)
                local label = g and g.name or ("Group " .. i)
                if g and g.enabled == false then
                    label = "|cff888888" .. label .. " (Disabled)|r"
                end
                return label
            end,
            order = 10 + i,
            args  = buildCustomFrameGroupOptions(i, NotifyChangeSafe),
        }
    end

    if not customFrameArgs.groups then
        customFrameArgs.groups = {
            type        = "group",
            name        = "Custom Frame Groups",
            order       = 1,
            childGroups = "tab",
            hidden      = function() return BF.cfgDB.profile.customFramesEnabled == false end,
            args        = groupsArgs,
        }
    end

    -- Clamp selectedFramesGroup to valid range
    if selectedFramesGroup > #groups then selectedFramesGroup = #groups end
    if selectedFramesGroup < 1 then selectedFramesGroup = 1 end

    -- ── Frames tree entry ─────────────────────────────────────────────────
    -- Dropdown to select a group, then layout settings for that group.
    local function getIdx() return selectedFramesGroup end
    local function getCF() return getCustomFrame(getIdx()) end

    -- Find the visible CFG header for a given group index.
    -- Mirrors the raid path's getVisibleAnchor() helper.
    local function getCFGHeader(groupIndex)
        for _, header in ipairs(BF.groupsUsed or {}) do
            if header.isCustomFrame and header.customGroupIndex == groupIndex then
                return header
            end
        end
    end

    -- Recalculate saved CFG position when layout anchor changes, so the
    -- bounding box doesn't jump.  Exact replica of the raid pattern from
    -- Options_Frames_Sorting.lua: read the visible header's actual geometry
    -- (GetLeft/GetRight/GetTop/GetBottom), pick the corner for the new
    -- anchor, and save.  The header is already properly sized by SetSize()
    -- in PlaceHeaders / _DoRefreshCustomFrameHeaders.
    --
    -- Call BEFORE updating config so the header still reflects the old
    -- layout (position + size from the previous layout pass).
    local function recalcCFGPosition(newLA)
        local idx = getIdx()
        local header = getCFGHeader(idx)
        if not header or not header:GetLeft() then return end

        local ux, uy = UIParent:GetCenter()
        if not ux or not uy then return end

        -- Pick the new anchor corner from the header's actual edges.
        -- Matches raid pattern: newLA:find("LEFT") and af:GetLeft() or af:GetRight()
        local newX = newLA:find("LEFT") and header:GetLeft() or header:GetRight()
        local newY = newLA:find("TOP")  and header:GetTop()  or header:GetBottom()
        if not newX or not newY then return end

        -- Store as CENTER-relative UI coords (same as SaveDetachedHeaderPosition).
        local posKey = "customFrame_" .. idx
        local cfgp = BF.cfgDB and BF.cfgDB.profile
        if not cfgp then return end
        if not cfgp.customFrameGroupPositions then
            cfgp.customFrameGroupPositions = {}
        end
        cfgp.customFrameGroupPositions[posKey] = {
            newLA,
            math.floor(newX - ux + 0.5),
            math.floor(newY - uy + 0.5),
        }
    end

    -- ── Shared helpers for both tabs ──────────────────────────────────────
    local noGroups = function() return #getCustomFrames() == 0 end

    -- Group selector widget (shared by both tabs, each gets its own copy)
    local function makeGroupSelect()
        return {
            type = "select", name = "Custom Frame Group", order = 1, width = "normal",
            desc = "Select which custom frame group to configure.",
            values = function()
                local vals = {}
                for i, g in ipairs(getCustomFrames()) do
                    vals[i] = g.name or ("Group " .. i)
                end
                return vals
            end,
            get = function() return getIdx() end,
            set = function(_, val)
                selectedFramesGroup = val
                if NotifyChangeSafe then NotifyChangeSafe() end
            end,
            hidden = noGroups,
        }
    end

    -- Helper: is the selected group using the active RP layout's size & spacing?
    local function isUsingActiveLayoutSize()
        local cf = getCF()
        return cf and cf.useActiveLayoutSize == true
    end

    -- ── Tab: Frames - Size & Position ─────────────────────────────────────
    customFrameArgs.framesSizePos = {
        type   = "group",
        name   = "Frames - Size & Position",
        order  = 2,
        hidden = function() return BF.cfgDB.profile.customFramesEnabled == false end,
        args   = {
            groupSelect = makeGroupSelect(),
            noGroupsDesc = {
                type = "description", order = 5, width = "full",
                name = "No custom frame groups exist. Add one first.",
                hidden = function() return #getCustomFrames() > 0 end,
            },
            positionGroup = {
                type = "group", name = "Frame Position", inline = true, order = 6,
                hidden = noGroups,
                args = {
                    _cfPosTracker = {
                        type = "description", name = function()
                            local halfW = math.floor(GetScreenWidth() / 2)
                            local halfH = math.floor(GetScreenHeight() / 2)
                            local posArgs = customFrameArgs.framesSizePos and customFrameArgs.framesSizePos.args
                            local pg = posArgs and posArgs.positionGroup and posArgs.positionGroup.args
                            if pg then
                                if pg.cfAnchorX then pg.cfAnchorX.softMin = -halfW; pg.cfAnchorX.softMax = halfW end
                                if pg.cfAnchorY then pg.cfAnchorY.softMin = -halfH; pg.cfAnchorY.softMax = halfH end
                            end
                            return ""
                        end,
                        order = 0, width = "full",
                    },
                    cfAnchorX = {
                        type = "range", name = "X Position", order = 1,
                        desc = "Horizontal position of this custom frame group (CENTER-relative).",
                        softMin = -1024, softMax = 1024, step = 1,
                        get = function(info)
                            local halfW = math.floor(GetScreenWidth() / 2)
                            info.option.softMin = -halfW
                            info.option.softMax = halfW
                            local cfgp = BF.cfgDB and BF.cfgDB.profile
                            local posKey = "customFrame_" .. getIdx()
                            local pos = cfgp and cfgp.customFrameGroupPositions and cfgp.customFrameGroupPositions[posKey]
                            if pos then return pos[2] or 0 end
                            return 0
                        end,
                        set = function(_, val)
                            if InCombatLockdown() then return end
                            val = math.floor(val + 0.5)
                            local idx = getIdx()
                            local cfgp = BF.cfgDB and BF.cfgDB.profile
                            local posKey = "customFrame_" .. idx
                            if not cfgp.customFrameGroupPositions then cfgp.customFrameGroupPositions = {} end
                            local pos = cfgp.customFrameGroupPositions[posKey]
                            if pos then
                                pos[2] = val
                            else
                                local flat = getCFFlat(idx)
                                local anchor = (flat and flat.raidLayoutAnchor) or "TOPLEFT"
                                cfgp.customFrameGroupPositions[posKey] = { anchor, val, 0 }
                            end
                            -- Move the live header (if in a group)
                            for _, header in ipairs(BF.groupsUsed or {}) do
                                if header.isCustomFrame and header.headerPosKey == posKey then
                                    BF:RestoreDetachedHeaderPosition(header)
                                    break
                                end
                            end
                            -- Move the setup mode test header
                            if BF.RestoreCustomFrameTestHeaderPosition then
                                BF:RestoreCustomFrameTestHeaderPosition(idx)
                            end
                        end,
                        disabled = InCombatLockdown,
                    },
                    cfAnchorY = {
                        type = "range", name = "Y Position", order = 2,
                        desc = "Vertical position of this custom frame group (CENTER-relative).",
                        softMin = -1024, softMax = 1024, step = 1,
                        get = function(info)
                            local halfH = math.floor(GetScreenHeight() / 2)
                            info.option.softMin = -halfH
                            info.option.softMax = halfH
                            local cfgp = BF.cfgDB and BF.cfgDB.profile
                            local posKey = "customFrame_" .. getIdx()
                            local pos = cfgp and cfgp.customFrameGroupPositions and cfgp.customFrameGroupPositions[posKey]
                            if pos then return pos[3] or 0 end
                            return 0
                        end,
                        set = function(_, val)
                            if InCombatLockdown() then return end
                            val = math.floor(val + 0.5)
                            local idx = getIdx()
                            local cfgp = BF.cfgDB and BF.cfgDB.profile
                            local posKey = "customFrame_" .. idx
                            if not cfgp.customFrameGroupPositions then cfgp.customFrameGroupPositions = {} end
                            local pos = cfgp.customFrameGroupPositions[posKey]
                            if pos then
                                pos[3] = val
                            else
                                local flat = getCFFlat(idx)
                                local anchor = (flat and flat.raidLayoutAnchor) or "TOPLEFT"
                                cfgp.customFrameGroupPositions[posKey] = { anchor, 0, val }
                            end
                            -- Move the live header (if in a group)
                            for _, header in ipairs(BF.groupsUsed or {}) do
                                if header.isCustomFrame and header.headerPosKey == posKey then
                                    BF:RestoreDetachedHeaderPosition(header)
                                    break
                                end
                            end
                            -- Move the setup mode test header
                            if BF.RestoreCustomFrameTestHeaderPosition then
                                BF:RestoreCustomFrameTestHeaderPosition(idx)
                            end
                        end,
                        disabled = InCombatLockdown,
                    },
                },
            },
            useActiveLayoutSize = {
                type = "toggle", name = "Use Active Raid/Party Layout's Size & Spacing",
                order = 8, width = "full",
                desc = "When enabled, this custom frame group uses the same frame size, spacing, and scale as the currently active raid or party layout instead of its own settings.",
                hidden = noGroups,
                get = function()
                    return isUsingActiveLayoutSize()
                end,
                set = function(_, val)
                    if InCombatLockdown() then return end
                    local cf = getCF(); if not cf then return end
                    cf.useActiveLayoutSize = val
                    RefreshCustomFrames()
                    if NotifyChangeSafe then NotifyChangeSafe() end
                end,
                disabled = InCombatLockdown,
            },
            sizeGroup = {
                type = "group", name = "Frame Size", inline = true, order = 10,
                hidden = function() return noGroups() or isUsingActiveLayoutSize() end,
                args = {
                    cfFrameWidth = {
                        type = "range", name = "Frame Width", order = 1,
                        desc = "Width of each unit frame in this custom frame group.",
                        min = 0, max = 150, step = 1,
                        get = function() local flat = getCFFlat(getIdx()); return (flat and flat.frameWidth) or 0 end,
                        set = function(_, val)
                            if InCombatLockdown() then return end
                            local flat = getCFFlat(getIdx()); if not flat then return end
                            flat.frameWidth = (val > 0) and val or nil
                            RefreshCustomFrames()
                        end,
                        disabled = InCombatLockdown,
                    },
                    cfFrameHeight = {
                        type = "range", name = "Frame Height", order = 2,
                        desc = "Height of each unit frame in this custom frame group.",
                        min = 0, max = 150, step = 1,
                        get = function() local flat = getCFFlat(getIdx()); return (flat and flat.frameHeight) or 0 end,
                        set = function(_, val)
                            if InCombatLockdown() then return end
                            local flat = getCFFlat(getIdx()); if not flat then return end
                            flat.frameHeight = (val > 0) and val or nil
                            RefreshCustomFrames()
                        end,
                        disabled = InCombatLockdown,
                    },
                },
            },
            spacingGroup = {
                type = "group", name = "Frame Spacing", inline = true, order = 24,
                hidden = function() return noGroups() or isUsingActiveLayoutSize() end,
                args = {
                    cfFrameSpacingH = {
                        type = "range", name = "Frame Spacing (Horizontal)", order = 1,
                        desc = "Horizontal spacing between unit frames.",
                        min = 0, max = 20, step = 1,
                        get = function() local flat = getCFFlat(getIdx()); return (flat and flat.frameSpacingH) or 0 end,
                        set = function(_, val)
                            if InCombatLockdown() then return end
                            local flat = getCFFlat(getIdx()); if not flat then return end
                            flat.frameSpacingH = val
                            RefreshCustomFrames()
                        end,
                        disabled = InCombatLockdown,
                    },
                    cfFrameSpacingV = {
                        type = "range", name = "Frame Spacing (Vertical)", order = 2,
                        desc = "Vertical spacing between unit frames.",
                        min = 0, max = 20, step = 1,
                        get = function() local flat = getCFFlat(getIdx()); return (flat and flat.frameSpacingV) or 0 end,
                        set = function(_, val)
                            if InCombatLockdown() then return end
                            local flat = getCFFlat(getIdx()); if not flat then return end
                            flat.frameSpacingV = val
                            RefreshCustomFrames()
                        end,
                        disabled = InCombatLockdown,
                    },
                },
            },
            scaleGroup = {
                type = "group", name = "Frame Scale", inline = true, order = 27,
                hidden = function() return noGroups() or isUsingActiveLayoutSize() end,
                args = {
                    cfEnableFrameScale = {
                        type = "toggle", name = "Scale Frames", order = 1,
                        desc = "Enable custom frame scaling for this custom frame group.",
                        get = function() local flat = getCFFlat(getIdx()); return flat and flat.enableFrameScale == true end,
                        set = function(_, val)
                            if InCombatLockdown() then return end
                            local flat = getCFFlat(getIdx()); if not flat then return end
                            flat.enableFrameScale = val
                            if not val then flat.frameScale = nil; flat.scaleIndicators = nil end
                            RefreshCustomFrames()
                        end,
                        disabled = InCombatLockdown,
                    },
                    cfFrameScale = {
                        type = "range", name = "Frame Scale", order = 2,
                        desc = "Scale multiplier for frames in this custom frame group.",
                        min = 0.5, max = 3.0, step = 0.05,
                        hidden = function()
                            local flat = getCFFlat(getIdx()); return not (flat and flat.enableFrameScale)
                        end,
                        get = function() local flat = getCFFlat(getIdx()); return (flat and flat.frameScale) or 1.0 end,
                        set = function(_, val)
                            if InCombatLockdown() then return end
                            local flat = getCFFlat(getIdx()); if not flat then return end
                            flat.frameScale = val
                            RefreshCustomFrames()
                        end,
                        disabled = InCombatLockdown,
                    },
                    cfScaleIndicators = {
                        type = "toggle", name = "Apply Scale to Indicators", order = 3,
                        desc = "When enabled, frame scale also scales auras, icons, text, and borders.",
                        hidden = function()
                            local flat = getCFFlat(getIdx()); return not (flat and flat.enableFrameScale)
                        end,
                        get = function()
                            local flat = getCFFlat(getIdx()); if not flat then return true end
                            return flat.scaleIndicators ~= false
                        end,
                        set = function(_, val)
                            if InCombatLockdown() then return end
                            local flat = getCFFlat(getIdx()); if not flat then return end
                            flat.scaleIndicators = val
                            RefreshCustomFrames()
                        end,
                        disabled = InCombatLockdown,
                    },
                },
            },
        },
    }

end

-- ── Main builder ─────────────────────────────────────────────────────────
function BF:BuildCustomFramesOptions(deps)
    local NotifyChangeSafe = deps.NotifyChangeSafe

    -- Add button
    customFrameArgs.addGroup = {
        type  = "execute",
        name  = "Add Custom Frame Group",
        order = 1,
        width = "normal",
        func  = function()
            if InCombatLockdown() then return end
            local groups = getCustomFrames()
            -- Resolve the source layout for deep-copying.
            local cfgp = self.cfgDB and self.cfgDB.profile
            local baseID = cfgp and cfgp.cfgBaseLayoutID or getDefaultRaidFlatID()
            local baseFlat = getSourceFlat(baseID)
            -- Deep-copy the entire base flat. DeepCopy strips metatables,
            -- so we re-wire them below (same pattern as Options_Layouts.lua
            -- copy-layout handler).
            local flat
            if baseFlat then
                flat = self:DeepCopy(baseFlat)
                -- When per-layout is OFF for a section, the source flat may
                -- contain stale per-layout values. Replace those sections
                -- with a deep copy of the current global settings so the
                -- new CFG starts with what the user actually sees.
                local globalP = self.rpDB and self.rpDB.profile
                if globalP then
                    for _, entry in ipairs(self.CFG_OVERRIDABLE_SECTIONS) do
                        local sec = entry.section
                        if not self:IsPerLayoutSection(sec) and globalP[sec] then
                            flat[sec] = self:DeepCopy(globalP[sec])
                        end
                    end
                    -- Same for the auras section (not in CFG_OVERRIDABLE_SECTIONS
                    -- but is a per-layout section with its own override flag).
                    if not self:IsPerLayoutSection("auras") and globalP.auras then
                        flat.auras = self:DeepCopy(globalP.auras)
                    end
                end
            else
                -- No valid base — seed from factory defaults.
                flat = {
                    type    = "raid",
                    anchorX = -260,
                    anchorY = -200,
                }
            end
            -- Find the highest existing "Group N" name and use N+1
            local maxN = 0
            for _, g in ipairs(groups) do
                if g and g.name then
                    local n = g.name:match("^Group (%d+)$")
                    if n and tonumber(n) > maxN then
                        maxN = tonumber(n)
                    end
                end
            end
            local groupName = "Group " .. (maxN + 1)
            flat.name      = groupName
            flat.type      = "raid"
            flat.cfgFlatID = newCFGFlatID()
            -- Ensure invariants
            if flat.anchorX == nil then flat.anchorX = -260 end
            if flat.anchorY == nil then flat.anchorY = -200 end
            if flat.raidLayoutAnchor == nil then flat.raidLayoutAnchor = "TOPLEFT" end
            -- Ensure sorting and auras sub-tables exist
            if not flat.sorting then flat.sorting = {} end
            if not flat.sorting.maxColumns then flat.sorting.maxColumns = 4 end
            if not flat.auras then flat.auras = {} end
            -- Wire metatable defaults (DeepCopy strips metatables)
            self:WireFlatDefaults(flat)
            local sections = self._perLayoutSections
            if sections then
                for i = 1, #sections do
                    self:WireSectionFallback(flat, sections[i])
                end
            end
            if type(rawget(flat, "auras")) == "table" then
                self:WireAurasSubCategoryFallbacks(flat.auras)
            end
            local newGroup = {
                name              = groupName,
                enabled           = true,
                -- Filter mode: defaults to rolegroup (nameListEnabled = false)
                nameListEnabled   = false,
                -- Role filter
                roleFilterEnabled = false,
                roleFilter        = {},
                -- Group filter
                groupFilterEnabled = false,
                groupFilter       = {},
                -- Class filter
                classFilterEnabled = false,
                classFilter       = {},
                -- Name list
                nameList          = "",
                -- Keybinds (nameList mode only)
                enableKeybindAdd  = false,
                toggleNameKey     = nil,
                -- Position (nil = auto-placed on first load)
                anchorX           = nil,
                anchorY           = nil,
                -- Flat layout: fully independent deep-copy seeded from the
                -- base layout. All settings (size, spacing, auras, sections)
                -- are owned by the CFG.
                flat = flat,
            }
            table.insert(groups, newGroup)
            -- Save an initial position so the sliders have a value immediately.
            -- Matches the fallback in ReloadCustomFrameHeadersOnly:
            -- CENTER + (200, 100 - (gi-1)*60) with the flat's anchor.
            local gi = #groups
            local anchor = flat.raidLayoutAnchor or "TOPLEFT"
            local initX, initY = 200, 100 - (gi - 1) * 60
            local cfgp = self.cfgDB and self.cfgDB.profile
            if cfgp then
                if not cfgp.customFrameGroupPositions then
                    cfgp.customFrameGroupPositions = {}
                end
                cfgp.customFrameGroupPositions["customFrame_" .. gi] = { anchor, initX, initY }
            end
            self:RebuildCustomFrameArgs(NotifyChangeSafe)
            ReloadCustomFrames()
            -- Navigate to the new group tab inside the Groups tree entry
            local ACD = LibStub("AceConfigDialog-3.0")
            ACD:SelectGroup("BuzzardFrames", "customFrames", "groups", "group_" .. #groups)
        end,
        disabled = InCombatLockdown,
    }
    savedAddGroupButton = customFrameArgs.addGroup

    -- Base Layout dropdown (shown before the Add button in the Groups tree entry)
    customFrameArgs.cfgBaseLayout = {
        type = "select",
        name = "Initial Source Layout",
        desc = "New custom frame groups will be seeded from this layout. All settings (size, auras, text, borders, etc.) are copied at creation time.",
        order = 0.5,
        width = "normal",
        values = getSourceLayoutValues,
        sorting = getSourceLayoutSorting,
        get = function()
            local cfgp = self.cfgDB and self.cfgDB.profile
            if not cfgp then return nil end
            local id = cfgp.cfgBaseLayoutID
            if id then
                local flat = getSourceFlat(id)
                if flat then return id end
            end
            local defID = getDefaultRaidFlatID()
            if cfgp then cfgp.cfgBaseLayoutID = defID end
            return defID
        end,
        set = function(_, val)
            if InCombatLockdown() then return end
            local cfgp = self.cfgDB and self.cfgDB.profile
            if cfgp then cfgp.cfgBaseLayoutID = val end
        end,
        disabled = InCombatLockdown,
    }
    savedBaseLayoutDropdown = customFrameArgs.cfgBaseLayout

    -- Build initial entries from saved data
    self:RebuildCustomFrameArgs(NotifyChangeSafe)

    -- Remove from root args (now inside the Groups tree entry)
    customFrameArgs.addGroup = nil
    customFrameArgs.cfgBaseLayout = nil

    -- Add the Auras tree entry (built by Options_CustomFrameAuras.lua)
    if self.BuildCustomFrameAurasOptions then
        customFrameArgs.auras = self:BuildCustomFrameAurasOptions({
            NotifyChangeSafe = NotifyChangeSafe,
        })
    end

    -- Add per-section tree entries (built by Options_CustomFrameSections.lua)
    if self.BuildCustomFrameSectionOptions then
        local sections = self:BuildCustomFrameSectionOptions({
            NotifyChangeSafe = NotifyChangeSafe,
        })
        for key, tree in pairs(sections) do
            customFrameArgs[key] = tree
        end
    end

    -- Description (shows on root page above the toggle)
    customFrameArgs.cfgDescription = {
        type = "description",
        name = "\n|cff11ace9Custom Frame Groups|r can be used to show frames for specific groups of units.\n\n"
            .. "For example, to show frames for |cff76CC4BMain Tank|r and |cff76CC4BMain Assist|r in a raid:\n\n"
            .. "1. Add a Custom Frame Group.\n\n"
            .. "2. Select |cff76CC4BRole/Group Filter|r Mode.\n\n"
            .. "3. |cffddddddFilter By|r |cff76CC4BRole|r, and select |cff76CC4BMain Tank|r and |cff76CC4BMain Assist|r.\n\n"
            .. "Custom Frame Groups are fully separate from the Raid/Party Frames "
            .. "and can be positioned in |cff76CC4BSetup Mode|r.",
        order = 0.5,
        width = "full",
        fontSize = "medium",
    }

    -- Global enable toggle (shows on root page of the tree)
    customFrameArgs.enableCustomFrames = {
        type = "toggle",
        name = "Enable Custom Frame Groups",
        desc = "Master toggle for all custom frame groups. When disabled, no custom frame headers are created.",
        order = 0,
        width = "full",
        get = function() return self.cfgDB.profile.customFramesEnabled ~= false end,
        set = function(_, val)
            if InCombatLockdown() then return end
            self.cfgDB.profile.customFramesEnabled = val
            ReloadCustomFrames()
        end,
        disabled = InCombatLockdown,
    }

    return {
        type        = "group",
        name        = "Custom Frame Groups",
        order       = 14,
        childGroups = "tree",
        args        = customFrameArgs,
    }
end
