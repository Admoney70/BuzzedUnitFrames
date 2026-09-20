-- ============================================================
-- BuzzardFrames: CustomFrames.lua
-- Custom frame groups: secondary sets of unit frames with
-- configurable filters (role, raid group, name list).
--
-- Architecture mirrors Grid2Layout:AddSpecialHeaders():
--   - Each enabled custom frame group becomes one additional
--     SecureGroupHeaderTemplate header appended after the main
--     layout headers during LoadLayout.
--   - Filter attributes (roleFilter, groupFilter, nameList) are
--     set directly on the secure header via SetHeaderAttributes.
--   - Each custom frame group is always detached (independently
--     positionable), matching Grid2's detachHeader = true pattern.
--
-- SECURE HEADER CONSTRAINT:
--   nameList CANNOT be combined with roleFilter or groupFilter on
--   a SecureGroupHeaderTemplate. The options UI enforces this by
--   making nameList mutually exclusive with role/group filters.
--   roleFilter + groupFilter CAN be combined (strictFiltering=true).
--
-- FUTURE MODULE-LEVEL TOGGLES:
--   The group definition table reserves space for inheritance flags
--   (e.g. showAuras, showIcons) that control whether the custom
--   frame group inherits specific visual modules from the main
--   frames. These are not yet implemented but the data structure
--   is ready for them.
-- ============================================================
local BF = LibStub("AceAddon-3.0"):GetAddon("BuzzardFrames")

-- ============================================================
-- ROLE → CLASS MAPPING
-- Built from BF.specData so it stays in sync with the spec table.
-- Each role maps to a set of class tokens (uppercase English names
-- matching CLASS_SORT_ORDER / SecureGroupHeaderTemplate values).
-- ============================================================

-- Deferred build: specData lives in Defaults.lua which loads before
-- CustomFrames.lua, so it's safe to read at file scope.
local ROLE_CLASSES = {}  -- ROLE_CLASSES["TANK"] = { WARRIOR=true, PALADIN=true, ... }
local CLASS_DISPLAY_NAMES = {}  -- CLASS_DISPLAY_NAMES["WARRIOR"] = "Warrior"

do
    -- Build ROLE_CLASSES from specData. The class token is read straight off
    -- the spec entry (Defaults.lua) -- this file used to carry its own
    -- hardcoded specID -> class table, which was a second copy of the same
    -- mapping that had to be edited every time Blizzard shipped a spec.
    for _, spec in ipairs(BF.specData) do
        local role  = spec.role
        local class = spec.class
        if role and class then
            if not ROLE_CLASSES[role] then ROLE_CLASSES[role] = {} end
            ROLE_CLASSES[role][class] = true
        end
    end

    -- Human-readable class names for the options UI
    CLASS_DISPLAY_NAMES = {
        DEATHKNIGHT = "Death Knight",
        DEMONHUNTER = "Demon Hunter",
        DRUID       = "Druid",
        EVOKER      = "Evoker",
        HUNTER      = "Hunter",
        MAGE        = "Mage",
        MONK        = "Monk",
        PALADIN     = "Paladin",
        PRIEST      = "Priest",
        ROGUE       = "Rogue",
        SHAMAN      = "Shaman",
        WARLOCK     = "Warlock",
        WARRIOR     = "Warrior",
    }
end

-- Expose for the options panel (Pages_CustomFrames.lua)
BF.ROLE_CLASSES       = ROLE_CLASSES
BF.CLASS_DISPLAY_NAMES = CLASS_DISPLAY_NAMES

-- Sorted class list for consistent UI ordering (alphabetical)
BF.CLASS_SORT_ORDER_ALPHA = {
    "DEATHKNIGHT", "DEMONHUNTER", "DRUID", "EVOKER", "HUNTER",
    "MAGE", "MONK", "PALADIN", "PRIEST", "ROGUE",
    "SHAMAN", "WARLOCK", "WARRIOR",
}

-- ============================================================
-- DATA HELPERS
-- ============================================================

function BF:GetCustomFrameGroups()
    local p = self.cfgDB.profile
    if not p.customFrameGroups then
        p.customFrameGroups = {}
    end
    return p.customFrameGroups
end

-- ── CFG flat ID helpers ───────────────────────────────────────────────
-- Each CFG flat gets a stable unique ID (stored in flat.cfgFlatID) so it
-- can be referenced reliably even after groups are deleted or reordered.
-- The options panel (Pages_CustomFrames.lua) mints IDs with the same
-- first-unused-slot rule when it creates a group, as does the dbVersion 52
-- migration in Core_Migrations.lua.
local function getCustomFrames()
    local p = BF.cfgDB and BF.cfgDB.profile
    if not p then return {} end
    if not p.customFrameGroups then p.customFrameGroups = {} end
    return p.customFrameGroups
end

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

-- The GROUP owning `flatID`, or nil if no live group owns it. The
-- per-Layout question for a CFG scope is answered by a flag on the GROUP,
-- not on its flat: BF:IsContainerPerLayoutActive (AuraCustomizations.lua)
-- reads group[BF.AURAS_GROUP_CFG_FLAG[<the subtab's group>]]. One scan,
-- several callers (DebuffIcons, DummyAuras, the options panel), so the
-- "is this scope key CFG-owned?" classification cannot drift between them.
function BF:ResolveCFGGroupByFlatID(flatID)
    if type(flatID) ~= "string" then return nil end
    local groups = getCustomFrames()
    for _, grp in ipairs(groups) do
        if grp and grp.flat and grp.flat.cfgFlatID == flatID then
            return grp
        end
    end
    return nil
end

-- The CFG flat table owning `flatID`, or nil if no group owns it. Runtime
-- code that has to tell a CFG flat ID apart from a raid/party flat ID --
-- InvalidateContainerSettingsCacheCFGOnly in AuraCustomizations.lua --
-- asks here instead of duplicating the scan.
function BF:ResolveCFGFlatByID(flatID)
    local grp = self:ResolveCFGGroupByFlatID(flatID)
    return grp and grp.flat or nil
end

-- Resolve the stable cfgFlatID for the group at `index`, minting one if
-- the group predates the ID scheme. BF:ResolveGroupTypeKey needs the ID
-- the first time a CFG frame renders auras -- which can be before the user
-- has ever opened the options panel.
function BF:GetCFGFlatID(index)
    local grp = getCustomFrames()[index]
    if not (grp and grp.flat) then return nil end
    if not grp.flat.cfgFlatID then
        grp.flat.cfgFlatID = newCFGFlatID()
    end
    return grp.flat.cfgFlatID
end

-- ============================================================
-- ShouldSkipCustomFrameGroup(group)
-- Returns true when the group's filters would match zero units,
-- meaning no header should be created and test frames should be
-- hidden.  Shared by GetCustomFrameHeaderDefs (real headers) and
-- the setup-mode test frame system.
-- ============================================================
function BF:ShouldSkipCustomFrameGroup(group)
    if not group or group.enabled == false then return true end

    local hasRole  = group.roleFilterEnabled and group.roleFilter
    local hasGroup = group.groupFilterEnabled and group.groupFilter
    local hasName  = group.nameListEnabled and group.nameList and group.nameList ~= ""

    local inRaid = BF:ResolveActiveIsRaid()
    local hasAnyRoleSelected = false
    if hasRole then
        local mt = inRaid and group.roleFilter.MAINTANK
        local ma = inRaid and group.roleFilter.MAINASSIST
        hasAnyRoleSelected = (mt or ma or group.roleFilter.TANK or group.roleFilter.HEALER or group.roleFilter.DAMAGER) and true or false
    end
    local hasAnyGroupSelected = false
    if hasGroup then
        for g = 1, 8 do
            if group.groupFilter[g] then hasAnyGroupSelected = true; break end
        end
    end
    local hasAnyClassSelected = false
    if group.classFilterEnabled and group.classFilter then
        for _, cls in ipairs(BF.CLASS_SORT_ORDER_ALPHA) do
            if group.classFilter[cls] then hasAnyClassSelected = true; break end
        end
    end

    if group.nameListEnabled and not hasName then
        return true
    elseif not hasName and not hasAnyRoleSelected
           and not hasAnyGroupSelected and not hasAnyClassSelected then
        return true
    end
    return false
end

-- ============================================================
-- HEADER DEFINITION BUILDER
-- Converts saved custom frame group config into header definition
-- tables that BF:AddHeader() understands.
--
-- Grid2 equivalent: the loop inside AddSpecialHeaders() that reads
-- specialHeaders[name] and builds a template table with filter
-- attributes, then calls AddHeader(temp, nil, index+10000, name).
--
-- Returns: array of { headerDef, groupIndex } pairs for enabled groups.
--          headerDef is a table of SecureGroupHeaderTemplate attributes.
--          groupIndex is the 1-based index into customFrameGroups (used
--          for position save/restore keying).
-- ============================================================
-- ============================================================
-- nameList resolution (shared by the header-def builder and the
-- add/remove keybind fast path below, so both push the exact same
-- attribute value).
--
-- The class-sorted variant is cached on the group and rebuilt whenever
-- the source list changes (the roster may also have changed, so the
-- name→class map is rebuilt with it).
-- ============================================================
local function EnsureClassSortedNameList(group)
    if group._nameListSortedByClass
       and group._nameListSortedSource == group.nameList then
        return
    end
    local names = {}
    for name in group.nameList:gmatch("[^,]+") do
        names[#names + 1] = strtrim(name)
    end
    -- Build name→class map from the current group roster
    local nameClass = {}
    local numMembers = GetNumGroupMembers()
    local inRaid = IsInRaid()
    if inRaid then
        for ri = 1, numMembers do
            local rName, _, _, _, _, rClass = GetRaidRosterInfo(ri)
            if rName and rClass then
                nameClass[rName] = rClass
            end
        end
    else
        local pName = UnitName("player")
        local _, pClass = UnitClass("player")
        if pName and pClass then nameClass[pName] = pClass end
        for pi = 1, 4 do
            local unit = "party" .. pi
            if UnitExists(unit) then
                local uName, uServer = UnitName(unit)
                local _, uClass = UnitClass(unit)
                if uName and uClass then
                    local fullName = (uServer and uServer ~= "") and (uName .. "-" .. uServer) or uName
                    nameClass[fullName] = uClass
                    nameClass[uName] = uClass
                end
            end
        end
    end
    -- Build class order lookup
    local classOrder = {}
    for idx, cls in ipairs(BF.CLASS_SORT_ORDER_ALPHA) do
        classOrder[cls] = idx
    end
    local unknownOrder = #BF.CLASS_SORT_ORDER_ALPHA + 1
    table.sort(names, function(a, b)
        local ca = nameClass[a] or nameClass[a:match("^[^-]+")]
        local cb = nameClass[b] or nameClass[b:match("^[^-]+")]
        local oa = ca and classOrder[ca] or unknownOrder
        local ob = cb and classOrder[cb] or unknownOrder
        if oa ~= ob then return oa < ob end
        return a < b
    end)
    group._nameListSortedByClass = table.concat(names, ",")
    group._nameListSortedSource = group.nameList
end

-- Returns the nameList string that belongs on the header for this group.
local function ResolveGroupNameList(group)
    EnsureClassSortedNameList(group)
    if group.nameListGroupBy == "CLASS" then
        return group._nameListSortedByClass
    end
    return group.nameList
end

function BF:GetCustomFrameHeaderDefs()
    -- Global toggle: if custom frames are disabled, return no headers.
    local p = self.cfgDB and self.cfgDB.profile
    if p and p.customFramesEnabled == false then return {} end

    local groups = self:GetCustomFrameGroups()
    local defs = {}

    for i, group in ipairs(groups) do
        if group.enabled ~= false then
            -- Context-based visibility: skip the group entirely if it
            -- shouldn't be shown in the current party/raid context.
            -- This avoids creating headers, pre-creating child frames,
            -- and including them in PlaceHeaders/ResizeAllFrames sweeps
            -- when the group is configured to be hidden in this context.
            if BF._contextIsParty and group.showInParty == false then
                -- In party but group says don't show in party
            elseif BF._contextIsRaid and group.showInRaid == false then
                -- In raid but group says don't show in raid
            elseif not IsInGroup() and group.excludePlayer then
                -- Solo with excludePlayer: the player is the only unit and
                -- would be excluded, so skip the group entirely rather than
                -- showing an empty header.
            else
            -- (the rest of the group processing is inside this else block)

            local def = {}

            -- ── Filter attributes ────────────────────────────────────
            -- Exactly one filter category is active at a time when nameList
            -- is involved. roleFilter + groupFilter can be combined.
            -- This mirrors Grid2's secure header attribute assignment.

            local hasRole  = group.roleFilterEnabled and group.roleFilter
            local hasGroup = group.groupFilterEnabled and group.groupFilter
            local hasName  = group.nameListEnabled and group.nameList and group.nameList ~= ""

            -- Check whether each enabled filter actually has any selections.
            -- A filter category can be "enabled" with zero checkboxes ticked,
            -- which previously fell through to show all units (groupFilter="auto").
            -- MAINTANK and MAINASSIST are raid-only assignments (GetPartyAssignment);
            -- they don't exist in party or solo, so exclude them from selection
            -- checks and the roleFilter string when not in a raid. Without this
            -- guard the SecureGroupHeaderTemplate shows the player as matching
            -- these roles even when solo or in a party.
            local inRaid = BF:ResolveActiveIsRaid()
            local hasAnyRoleSelected = false
            if hasRole then
                local mt = inRaid and group.roleFilter.MAINTANK
                local ma = inRaid and group.roleFilter.MAINASSIST
                hasAnyRoleSelected = (mt or ma or group.roleFilter.TANK or group.roleFilter.HEALER or group.roleFilter.DAMAGER) and true or false
            end
            local hasAnyGroupSelected = false
            if hasGroup then
                for g = 1, 8 do
                    if group.groupFilter[g] then hasAnyGroupSelected = true; break end
                end
            end
            local hasAnyClassSelected = false
            if group.classFilterEnabled and group.classFilter then
                for _, cls in ipairs(BF.CLASS_SORT_ORDER_ALPHA) do
                    if group.classFilter[cls] then hasAnyClassSelected = true; break end
                end
            end

            -- If nameList mode is enabled but the list is empty, skip this
            -- group entirely. Don't fall through to role/group filters —
            -- the user chose nameList mode, the list is just empty.
            -- Likewise, if no filter has any actual selections, skip the
            -- group rather than showing all units. An unfiltered custom frame
            -- group is indistinguishable from the main frames and wastes CPU.
            local skipGroup = false
            if group.nameListEnabled and not hasName then
                -- Nothing to show — don't create a header for this group
                skipGroup = true
            elseif not hasName and not hasAnyRoleSelected
                   and not hasAnyGroupSelected and not hasAnyClassSelected then
                -- No filters of any kind have actual selections — skip
                skipGroup = true
            elseif hasName then
                -- Name list filter (mutually exclusive with role/group in
                -- the secure header). Options UI enforces this constraint.
                -- Do NOT set groupFilter here. When nameList is the sole
                -- filter, Blizzard's SecureGroupHeaderTemplate uses it
                -- directly to match units by name. Setting groupFilter
                -- would cause OR logic (match group OR name) which passes
                -- everyone since all units are in groups 1-8.
                --
                -- Build a class-sorted version of the name list and cache
                -- it so switching the dropdown doesn't require a rebuild.
                -- The cache is refreshed every layout reload (roster may
                -- have changed).
                def.nameList = ResolveGroupNameList(group)
                def.sortMethod = "NAMELIST"
            else
                -- Role filter
                if hasRole then
                    local roles = {}
                    -- MAINTANK/MAINASSIST are raid-only; skip when not in raid
                    if inRaid and group.roleFilter.MAINTANK   then roles[#roles + 1] = "MAINTANK"   end
                    if inRaid and group.roleFilter.MAINASSIST then roles[#roles + 1] = "MAINASSIST" end
                    if group.roleFilter.TANK       then roles[#roles + 1] = "TANK"       end
                    if group.roleFilter.HEALER     then roles[#roles + 1] = "HEALER"     end
                    if group.roleFilter.DAMAGER    then roles[#roles + 1] = "DAMAGER"    end
                    if #roles > 0 then
                        def.roleFilter = table.concat(roles, ",")
                    end
                end

                -- Group filter
                if hasGroup then
                    local nums = {}
                    for g = 1, 8 do
                        if group.groupFilter[g] then
                            nums[#nums + 1] = tostring(g)
                        end
                    end
                    if #nums > 0 then
                        def.groupFilter = table.concat(nums, ",")
                    end
                end

                -- SecureGroupHeaderTemplate filtering mechanics:
                -- The secure header's roleFilter alone does NOT filter units.
                -- It requires strictFiltering=true AND all class names appended
                -- to groupFilter. This is exactly what Grid2 does in
                -- FixHeaderAttributes: when strictFiltering is set, it appends
                -- all class names to groupFilter so the "class match" always
                -- passes and only the role check actually filters.
                --
                -- So for ANY roleFilter usage, we must set strictFiltering=true
                -- and ensure groupFilter includes all class names.
                if def.roleFilter then
                    def.strictFiltering = true

                    -- Determine which classes to include in groupFilter.
                    -- If the user enabled class filtering and selected specific
                    -- classes, use only those. Otherwise, include ALL classes
                    -- eligible for the selected roles (so the class check in
                    -- strictFiltering always passes for role-eligible units).
                    local classStr
                    local hasClassFilter = group.classFilterEnabled and group.classFilter
                    if hasClassFilter then
                        local selected = {}
                        for _, cls in ipairs(BF.CLASS_SORT_ORDER_ALPHA) do
                            if group.classFilter[cls] then
                                selected[#selected + 1] = cls
                            end
                        end
                        if #selected > 0 then
                            classStr = table.concat(selected, ",")
                        end
                    end
                    if not classStr then
                        -- No class filter active: include all classes that can
                        -- perform the selected roles so the class check is a no-op.
                        -- Roles without a ROLE_CLASSES entry (e.g. MAINTANK,
                        -- MAINASSIST) are manual raid assignments that any class
                        -- can hold, so we fall back to all classes.
                        local allForRoles = {}
                        local seen = {}
                        local hasUnmappedRole = false
                        for role in def.roleFilter:gmatch("[^,]+") do
                            local rc = ROLE_CLASSES[role]
                            if rc then
                                for cls in pairs(rc) do
                                    if not seen[cls] then
                                        seen[cls] = true
                                        allForRoles[#allForRoles + 1] = cls
                                    end
                                end
                            else
                                hasUnmappedRole = true
                            end
                        end
                        -- If any role has no class mapping, include all classes.
                        if hasUnmappedRole then
                            for _, cls in ipairs(BF.CLASS_SORT_ORDER_ALPHA) do
                                if not seen[cls] then
                                    seen[cls] = true
                                    allForRoles[#allForRoles + 1] = cls
                                end
                            end
                        end
                        table.sort(allForRoles)
                        classStr = table.concat(allForRoles, ",")
                    end

                    -- Build groupFilter: group numbers + class names
                    local baseGF = def.groupFilter or "auto"
                    if baseGF == "auto" then
                        -- "auto" is resolved to group numbers by FixHeaderAttributes.
                        -- FixHeaderAttributes will append classes via strictFiltering
                        -- handling. Store the class string for it to use.
                        def.groupFilter = "auto"
                        def._classString = classStr
                    else
                        if classStr and classStr ~= "" then
                            def.groupFilter = baseGF .. "," .. classStr
                        end
                    end
                elseif not def.groupFilter then
                    -- No role filter: check if class filter alone is active.
                    -- Class-only filtering works by putting class names in
                    -- groupFilter without roleFilter (no strictFiltering needed).
                    local hasClassFilter = group.classFilterEnabled and group.classFilter
                    if hasClassFilter then
                        local selected = {}
                        for _, cls in ipairs(BF.CLASS_SORT_ORDER_ALPHA) do
                            if group.classFilter[cls] then
                                selected[#selected + 1] = cls
                            end
                        end
                        if #selected > 0 then
                            -- Group numbers + selected class names.
                            -- strictFiltering = true means unit must match
                            -- BOTH a group number AND a class name.
                            def.groupFilter = "auto"
                            def._classString = table.concat(selected, ",")
                            def.strictFiltering = true
                        else
                            def.groupFilter = "auto"
                        end
                    else
                        def.groupFilter = "auto"
                    end
                end
            end

            if not skipGroup then
                -- ── Sorting / Group By ────────────────────────────────────
                -- SecureGroupHeaderTemplate's groupBy attribute pre-sorts
                -- units into visual sub-groups. groupingOrder defines the
                -- display order of those sub-groups.
                if not hasName then
                    if group.groupBy then
                        def.groupBy = group.groupBy
                        -- Set appropriate default groupingOrder for each groupBy mode
                        if group.groupBy == "ASSIGNEDROLE" then
                            def.groupingOrder = "TANK,HEALER,DAMAGER,NONE"
                        elseif group.groupBy == "GROUP" then
                            def.groupingOrder = "1,2,3,4,5,6,7,8"
                        elseif group.groupBy == "CLASS" then
                            def.groupingOrder = table.concat(BF.CLASS_SORT_ORDER_ALPHA, ",")
                        end
                    end
                    if group.sortMethod then
                        def.sortMethod = group.sortMethod
                    end
                end

                -- ── Layout attributes ────────────────────────────────────
                -- Grid2 pattern: unitsPerColumn and maxColumns control the
                -- grid layout within the header. "auto" defers to instance size.
                local sorting = group.flat and group.flat.sorting
                local cfMaxCols, cfUPC = BF:GetCFGGridDims(sorting)
                def.unitsPerColumn = cfUPC
                def.maxColumns     = cfMaxCols

                -- Always detached (independently positionable).
                -- Grid2 pattern: detachHeader = true on all special headers.
                def.detachHeader = true

                -- Visibility: show in all group contexts.
                -- Grid2 pattern: showSolo/showPlayer/showParty/showRaid are
                -- inherited from customDefaults (all true) unless overridden.
                -- We set them explicitly here for clarity.
                def.showSolo   = group.showSolo ~= false
                def.showPlayer = not group.excludePlayer
                def.showParty  = group.showInParty ~= false
                def.showRaid   = group.showInRaid ~= false

                defs[#defs + 1] = {
                    headerDef  = def,
                    groupIndex = i,
                    groupName  = group.name or ("Group " .. i),
                }
            end
        end -- else (context visibility check)
        end -- if group.enabled
    end

    return defs
end

-- ============================================================
-- KEYBIND SYSTEM
-- Per-group keybinds to add/remove the mouseover unit's name
-- to/from a custom frame group's nameList.
--
-- Uses SetOverrideBindingClick on a hidden button per enabled
-- group with keybinds configured. The button toggles the
-- mouseover unit's name (add if absent, remove if present).
-- Buttons are pooled and reused across layout reloads.
-- ============================================================

local keybindButtons = {}  -- pool: keybindButtons[i] = Button
local activeKeybindCount = 0

-- Get or create a hidden keybind button for group slot `slot`.
local function GetKeybindButton(slot)
    if keybindButtons[slot] then return keybindButtons[slot] end

    local btn = CreateFrame("Button", "BFCustomFrameToggleName" .. slot, UIParent)
    btn:SetSize(1, 1)
    btn:Hide()
    btn:EnableMouse(false)
    btn:RegisterForClicks("AnyDown")

    keybindButtons[slot] = btn
    return btn
end

-- Called after AddCustomFrameHeaders builds the detached headers.
-- Sets up override bindings for groups that have keybinds configured.
function BF:SetupCustomFrameKeybinds()
    self:ClearCustomFrameKeybinds()

    local groups = self:GetCustomFrameGroups()
    local slot = 0

    for i, group in ipairs(groups) do
        if group.enabled ~= false
           and group.nameListEnabled
           and group.enableKeybindAdd then

            if group.toggleNameKey and group.toggleNameKey ~= "" then
                slot = slot + 1
                local btn = GetKeybindButton(slot)
                local groupIndex = i  -- capture for closures

                btn:SetScript("OnClick", function()
                    -- pcall guard: in combat the override binding may still
                    -- fire the OnClick but ToggleNameInCustomGroup will bail
                    -- at InCombatLockdown(). pcall ensures no Lua error ever
                    -- propagates regardless of taint or combat state.
                    pcall(BF.ToggleNameInCustomGroup, BF, groupIndex)
                end)
                SetOverrideBindingClick(btn, true, group.toggleNameKey, btn:GetName())
            end
        end
    end

    activeKeybindCount = slot
end

-- Clear all override bindings from previous layout.
function BF:ClearCustomFrameKeybinds()
    for slot = 1, activeKeybindCount do
        local btn = keybindButtons[slot]
        if btn then
            ClearOverrideBindings(btn)
            btn:SetScript("OnClick", nil)
        end
    end
    activeKeybindCount = 0
end

-- ============================================================
-- v53 PERF: nameList-only fast path (add/remove one unit).
--
-- The keybind used to route through BF:ReloadCustomFrameHeadersOnly,
-- which Reset()s EVERY custom frame group header, rebuilds the aura
-- settings cache for EVERY scope, re-adds every header from config and
-- then runs frame:Layout() over all of every group's pre-created frames
-- — a visible hitch for a change that touches exactly one secure
-- attribute on one header.
--
-- Nothing else moved: the only thing a name toggle changes is the
-- header's "nameList". Setting it on a VISIBLE SecureGroupHeaderTemplate
-- immediately re-runs SecureGroupHeader_Update, which re-assigns the
-- unit attribute per child and fires OnAttributeChanged → SetFrameUnit →
-- OnUnitChanged for the frames that actually changed. That is all the
-- frame-side work a name change requires.
--
-- Structural changes still take the full path: a group that loses its
-- last name (its header must go away), one that gains its first name
-- (no header exists yet), a disabled group, or a header that is not
-- currently in nameList mode.
--
-- PTR-VERIFY: that a lone SetAttribute("nameList", …) on a VISIBLE header
-- re-runs SecureGroupHeader_Update on its own (asserted by the comment on
-- the CFG settings-refresh path in BFLayout.lua, which hides the header
-- across attribute mutations precisely because every set fires an update).
-- If it does not, the frame will not appear until the next header
-- Show/Hide — add header:Update() here and re-register the private aura
-- anchors, as ReloadCustomFrameHeadersOnly does. A hidden-for-context
-- header correctly picks the new list up on its next Show.
--
-- Returns true when the fast path handled the change.
-- ============================================================
function BF:ApplyCustomGroupNameListOnly(groupIndex)
    if InCombatLockdown() then return false end
    local groups = self:GetCustomFrameGroups()
    local group  = groups and groups[groupIndex]
    if not group then return false end
    if group.enabled == false or not group.nameListEnabled then return false end
    if not group.nameList or group.nameList == "" then return false end
    if not self.groupsUsed then return false end

    local header
    for _, h in ipairs(self.groupsUsed) do
        if h.isCustomFrame and h.customGroupIndex == groupIndex then
            header = h
            break
        end
    end
    if not header then return false end
    -- A header with no live nameList attribute was built from
    -- role/group/class filters (or from an empty list) — switching filter
    -- category is structural, so hand it to the full rebuild.
    local cur = header:GetAttribute("nameList")
    if not cur or cur == "" then return false end
    if not header:CanChangeAttribute() then return false end

    local list = ResolveGroupNameList(group)
    if not list or list == "" then return false end

    -- v53 Phase 2.1: this header carries only as many child frames as the
    -- roster can fill (BF:GetCustomHeaderInitialFrameCount), so make sure the
    -- pool covers the new list BEFORE the secure header has to grow it from
    -- inside its own update. Refused while restricted — but this whole
    -- function already bailed on InCombatLockdown, and a no-op when capacity
    -- is already there (the headroom absorbs a single added name).
    if self.ForceFramesCreation and self.GetCustomHeaderInitialFrameCount
       and not (self.IsAuraCreationRestricted and self:IsAuraCreationRestricted()) then
        self:ForceFramesCreation(header, self:GetCustomHeaderInitialFrameCount(header))
    end

    -- Grid2 pattern: only set if necessary.
    if list ~= cur then
        header:SetAttribute("nameList", list)
    end

    -- The set of units shown changed, so the polled range roster did too.
    if self.SyncRangeChecker then self:SyncRangeChecker() end

    -- Deferred, scoped to this header: the secure header has re-assigned
    -- its children by the time this runs. Frames whose unit changed were
    -- already carried through OnUnitChanged; this mirrors the tail of
    -- ReloadCustomFrameHeadersOnly for the handful of frames that are
    -- actually populated (no header Reset happened, so no frame:Layout()
    -- sweep is needed — header geometry and the aura caches are
    -- untouched).
    C_Timer.After(0, function()
        for _, frame in ipairs(header) do
            if frame and frame.unit and frame:IsShown() then
                self:UpdateFrameIndicators(frame, frame.unit)
                -- SecureGroupHeader_Update hides/shows children as the
                -- assignment changes, which invalidates their private
                -- aura anchor handles.
                if self.RegisterPrivateAuraDispelOverlayOnly then
                    self:RegisterPrivateAuraDispelOverlayOnly(frame)
                end
            end
        end
        if self.FlushDeferredIndicatorUpdates then
            self:FlushDeferredIndicatorUpdates()
        end
    end)

    return true
end

-- Toggle the mouseover unit's name in a custom frame group's nameList.
-- If the name is already present, remove it. If not, add it.
function BF:ToggleNameInCustomGroup(groupIndex)
    if InCombatLockdown() then
        print("|cffff8800BuzzardFrames:|r Cannot modify name list during combat.")
        return
    end

    -- Try the mouseover unit first, then fall back to the unit frame
    -- under the cursor. Out-of-zone raid members may not register as
    -- a "mouseover" unit even though their frame is rendered and the
    -- cursor is over it. oUF frames store their unit token as frame.unit.
    local unit = "mouseover"
    if not UnitExists(unit) then
        local frame = GetMouseFocus and GetMouseFocus() or GetMouseFoci and GetMouseFoci()[1]
        if frame and frame.unit then
            unit = frame.unit
        else
            return
        end
    end

    local name, server = UnitName(unit)
    if not name or name == "" or name == UNKNOWNOBJECT then return end
    -- Append server name for cross-realm players
    if server and server ~= "" then
        name = name .. "-" .. server
    end

    local groups = self:GetCustomFrameGroups()
    local group = groups[groupIndex]
    if not group then return end

    -- Check if name is already in the list
    local existing = group.nameList or ""
    local names = {}
    local found = false
    for n in existing:gmatch("[^,]+") do
        n = strtrim(n)
        if n == name then
            found = true
            -- skip it (removes from list)
        else
            names[#names + 1] = n
        end
    end

    if found then
        -- Remove
        group.nameList = table.concat(names, ",")
    else
        -- Add
        if existing == "" then
            group.nameList = name
        else
            group.nameList = existing .. "," .. name
        end
    end

    -- v53 PERF: one attribute on one header when the change is
    -- non-structural (Phase 3); one NEW header when this group is gaining
    -- its first name (Phase 2.1); full CFG rebuild only when it is neither.
    --
    -- The first-name case used to take the full rebuild, and that is where
    -- the "adding the FIRST frame to a group hitches hard" report came from:
    -- the group has no header while its list is empty (GetCustomFrameHeaderDefs
    -- skips it), so the rebuild had to spawn a fresh header — and a fresh
    -- header's ForceFramesCreation built the whole 8x5 grid, 40 unit frames
    -- with all their indicators and aura containers, in one keypress. Every
    -- later add reuses that header, which is why only the first one hurt.
    if not self:ApplyCustomGroupNameListOnly(groupIndex) then
        local handled = false
        if self.AddCustomFrameHeaderForGroup then
            handled = self:AddCustomFrameHeaderForGroup(groupIndex)
        end
        if not handled then
            if self.ReloadCustomFrameHeadersOnly then
                self:ReloadCustomFrameHeadersOnly()
            else
                self:ReloadLayout(true)
            end
        end
    end

    -- Notify options panel if open
    BF:RefreshPanel("cfgMembers")
end
