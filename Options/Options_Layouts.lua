-- ============================================================
-- BuzzardFrames: Options_Layouts.lua
-- Builds and returns the "Layouts" nav-tab args table.
-- Called from Options.lua: BF:BuildLayoutsOptions(deps)
-- ============================================================
local BF = _G["BuzzardFrames"]

-- ============================================================
-- SHARED SLOT CONSTANTS (hoisted from tabInstanceTypes /
-- tabLayoutManagement closures so File 11 (Preview) and the
-- new Role/Spec Layouts tab can reuse them.)
-- ============================================================
-- Slot → flat type: party-typed slots only accept party flats;
-- raid-typed slots only accept raid flats.
BF.SLOT_TYPE = {
    solo           = "party",
    openWorldParty = "party",
    dungeon        = "party",
    delve          = "party",
    arena          = "party",
    raidOpen       = "raid",
    raid20         = "raid",
    raid30         = "raid",
    raid40         = "raid",
    bg15           = "raid",
    bg40           = "raid",
}

-- Human-readable slot labels (used by Preview labels, the
-- "layout in use" popup in Layout Management, etc.)
BF.SLOT_LABELS = {
    solo           = "Solo",
    openWorldParty = "Party (Open World)",
    dungeon        = "Dungeon",
    delve          = "Delve",
    arena          = "Arena",
    raidOpen       = "Raid (Open World)",
    raid20         = "Raid (20 Man)",
    raid30         = "Raid (30 Man)",
    raid40         = "Raid (40 Man)",
    bg15           = "Battleground (15 Man)",
    bg40           = "Battleground (40 Man)",
}

-- deps is a table of upvalue references passed in from RegisterOptions:
--   deps.self             - the BF addon object
--   deps.NotifyChangeSafe - local function from RegisterOptions
--   deps.ensureLayout     - local function from RegisterOptions
function BF:BuildLayoutsOptions(deps)
    local self             = deps.self
    local NotifyChangeSafe = deps.NotifyChangeSafe
    local ensureLayout     = deps.ensureLayout

    -- Build the layouts dropdown values table (id -> display name)
    local function layoutValues()
        local p = self.rpDB.profile.layouts
        local activeID = p.activeLayout or self._framesActiveLayout or "default"
        local t = {}
        for id, layout in pairs(p.layouts) do
            if id == activeID then
                t[id] = "|cff76CC4B" .. layout.name .. "|r"
            else
                t[id] = layout.name
            end
        end
        return t
    end

    -- Generate a unique layout ID
    local function newLayoutID()
        local p = self.rpDB.profile.layouts
        local i = 1
        repeat
            local id = "layout_" .. i
            if not p.layouts[id] then return id end
            i = i + 1
        until false
    end

    -- Generate a unique flat-layout ID. Format: flat_1, flat_2, …
    -- Skips IDs already present in flatLayouts as well as the
    -- reserved seeded IDs (flat_party, flat_raidNN) so seeded slots
    -- remain recognizable by prefix alone.
    local function newFlatID()
        local fl = self.rpDB.profile.layouts.flatLayouts or {}
        local i = 1
        repeat
            local id = "flat_" .. i
            if not fl[id] then return id end
            i = i + 1
        until false
    end

    -- Seeded flats are created by the migration / fresh-install
    -- defaults and must not be renamed or deleted, so the user can
    -- always rely on their presence as fallbacks.
    local SEEDED_FLATS = {
        flat_party  = true,
        flat_raid20 = true,
        flat_raid30 = true,
        flat_raid40 = true,
    }
    local function isSeededFlat(id)
        return SEEDED_FLATS[id] == true
    end

    return {
        type        = "group",
        name        = "Layouts",
        order       = 12,
        childGroups = "tab",
        args        = {
            _sectionTracker = { type="description", name=function() if self._currentSection ~= "roleSpecLayouts" then self._currentSection="roleSpecLayouts"; if not InCombatLockdown() then NotifyChangeSafe() end end; return "" end, order=0, width="full" },
            tabInstanceTypes = {
                type  = "group",
                name  = "Layouts by Instance Type",
                order = 0.6,
                args  = (function()
                    -- Slot → flat type mapping. Party-typed slots (small
                    -- groups) only offer party-type flats; raid-typed
                    -- slots only offer raid-type flats. This prevents
                    -- assigning a party layout to a 40-man raid slot
                    -- and vice versa.
                    -- Slot → flat type mapping. Hoisted to BF.SLOT_TYPE
                    -- so File 11 and the new Role/Spec Layouts tab can
                    -- share the same constants. Local alias preserved
                    -- for the existing helpers in this closure.
                    local SLOT_TYPE = BF.SLOT_TYPE

                    -- Build the flat-layout dropdown values table for a given
                    -- slot. Filters to flats whose `type` matches requiredType.
                    -- For the solo slot only, prepend a "None" option.
                    local function flatValues(requiredType, includeNone)
                        local fl = self.rpDB.profile.layouts.flatLayouts or {}
                        local t  = {}
                        if includeNone then t.none = "None" end
                        for id, layout in pairs(fl) do
                            if layout.type == requiredType then
                                t[id] = layout.name or id
                            end
                        end
                        return t
                    end

                    local function flatSorting(requiredType, includeNone)
                        local fl = self.rpDB.profile.layouts.flatLayouts or {}
                        local keys = {}
                        if includeNone then keys[#keys + 1] = "none" end
                        -- Stable order: flat_party first (if present), then
                        -- flat_raid20, flat_raid30, flat_raid40 in that order,
                        -- then any other flats alphabetically by id. Each
                        -- only included if its type matches requiredType.
                        local preferred = { "flat_party", "flat_raid20", "flat_raid30", "flat_raid40" }
                        local seen = {}
                        for _, id in ipairs(preferred) do
                            if fl[id] and fl[id].type == requiredType then
                                keys[#keys + 1] = id; seen[id] = true
                            end
                        end
                        local extras = {}
                        for id, layout in pairs(fl) do
                            if not seen[id] and layout.type == requiredType then
                                extras[#extras + 1] = id
                            end
                        end
                        table.sort(extras)
                        for _, id in ipairs(extras) do keys[#keys + 1] = id end
                        return keys
                    end

                    -- Factory for the per-slot dropdown. includeNone is true
                    -- only for the solo slot. The slot's required flat type
                    -- is resolved via SLOT_TYPE.
                    local function slotSelect(slotKey, label, orderN, slotDesc, includeNone)
                        local requiredType = SLOT_TYPE[slotKey]
                        return {
                            type    = "select",
                            name    = function()
                                local active = self:GetActiveSlot()
                                if slotKey == active then
                                    return "|cff76CC4B" .. label .. "|r"
                                end
                                return label
                            end,
                            desc    = slotDesc,
                            order   = orderN,
                            width   = "normal",
                            values  = function() return flatValues(requiredType, includeNone) end,
                            sorting = function() return flatSorting(requiredType, includeNone) end,
                            get = function()
                                local p = self.rpDB.profile.layouts
                                if not p.instanceLayoutAssignment then p.instanceLayoutAssignment = {} end
                                return p.instanceLayoutAssignment[slotKey]
                            end,
                            set = function(_, val)
                                local p = self.rpDB.profile.layouts
                                if not p.instanceLayoutAssignment then p.instanceLayoutAssignment = {} end
                                p.instanceLayoutAssignment[slotKey] = val
                                -- Same pattern as slotOverrideSelect (role/spec
                                -- overrides further down in this file): invalidating
                                -- the raid profile cache and calling RefreshAll is
                                -- what makes the live frames rebuild against the
                                -- newly-assigned flat. Without it, the assignment
                                -- was only taking effect when something else
                                -- (entering/exiting setup mode, zoning) triggered
                                -- a refresh.
                                self:InvalidateRaidProfileCache()
                                -- If the slot being changed is the currently-active
                                -- slot, the active flat just changed. Point
                                -- _modifyingFlat at the newly-resolved active flat
                                -- so the chrome "Modifying Layout" dropdown and
                                -- Setup Mode's test frames follow the user's
                                -- intent. Without this sync, setup mode keeps
                                -- editing the previous flat's settings (position,
                                -- size, grow direction) via GetModifyingProfile(),
                                -- and the test header continues rendering the old
                                -- layout. No writes to either flat happen here;
                                -- we're only retargeting the pointer. Mirrors the
                                -- reset-to-active behaviour in BF:OpenOptions for
                                -- the "panel opened while setup mode off" case.
                                if slotKey == self:GetActiveSlot() then
                                    local fl       = p.flatLayouts or {}
                                    local newActive = self:ResolveActiveFlat(slotKey)
                                    if newActive and newActive ~= "none" and fl[newActive] then
                                        BF._modifyingFlat = newActive
                                    else
                                        BF._modifyingFlat = fl.flat_party and "flat_party" or nil
                                    end
                                    -- Refresh the chrome dropdown label so the
                                    -- panel shows the new Modifying Layout
                                    -- selection without waiting for the dropdown
                                    -- to be re-opened.
                                    local ACD = LibStub("AceConfigDialog-3.0", true)
                                    local aceFrame = ACD and ACD.OpenFrames and ACD.OpenFrames["BuzzardFrames"]
                                    if aceFrame and aceFrame.frame and aceFrame.frame._BF_RefreshLayoutDDText then
                                        aceFrame.frame._BF_RefreshLayoutDDText()
                                    end
                                end
                                if self.RefreshAll then self:RefreshAll() end
                                -- When Setup Mode is active, RefreshAll -> ApplyProfile
                                -- rebuilds the real frames and re-anchors the test
                                -- anchor (Step 6 in ApplyProfile), but does NOT
                                -- rebuild the test header itself. If the modifying
                                -- flat we just retargeted has different dimensions,
                                -- grow direction, or frame count than the previous
                                -- one, the test header needs to be reconfigured to
                                -- match. Same pattern used by ToggleSetupMode's
                                -- enter path after setting _modifyingFlat.
                                if self.db and self.db.global and self.db.global.setupModeActive then
                                    if self.UpdateSetupFrames    then self:UpdateSetupFrames()    end
                                    if self.UpdateAnchorPosition then self:UpdateAnchorPosition() end
                                end
                                NotifyChangeSafe()
                            end,
                        }
                    end

                    return {
                        instanceTypesDesc = {
                            type  = "description",
                            name  = "Assign a Layout to each instance type.",
                            order = 0,
                            width = "full",
                        },
                        showLayoutAnnounce = {
                            type  = "toggle",
                            name  = "Announce Layout changes",
                            desc  = "Shows a private notification in your chat window when the addon automatically switches your layout.",
                            order = 0.5,
                            width = "full",
                            get   = function() return self.rpDB.profile.layouts.showLayoutAnnounce end,
                            set   = function(_, val) self.rpDB.profile.layouts.showLayoutAnnounce = val end,
                        },
                        openWorldGroup = {
                            type   = "group",
                            name   = "Open World",
                            order  = 1,
                            inline = true,
                            args   = {
                                solo           = slotSelect("solo",           "Solo",              1, "Layout used when you are alone in the open world.", true),
                                openWorldParty = slotSelect("openWorldParty", "Party",             2, "Layout used when you are in a 5-player party in the open world."),
                                raidOpen       = slotSelect("raidOpen",       "Raid (Open World)", 3, "Layout used when you are in a raid group in the open world."),
                            },
                        },
                        dungeonGroup = {
                            type   = "group",
                            name   = "Dungeon",
                            order  = 2,
                            inline = true,
                            args   = {
                                dungeon = slotSelect("dungeon", "Dungeon", 1, "Layout used when you are in a 5-player dungeon or party."),
                                delve   = slotSelect("delve",   "Delve",   2, "Layout used when you are in a Delve."),
                            },
                        },
                        raidGroup = {
                            type   = "group",
                            name   = "Raid",
                            order  = 3,
                            inline = true,
                            args   = {
                                raid20 = slotSelect("raid20", "Raid (20 Man)", 2, "Layout used when you are in a 20-player raid instance."),
                                raid30 = slotSelect("raid30", "Raid (30 Man)", 3, "Layout used when you are in a 30-player raid instance."),
                                raid40 = slotSelect("raid40", "Raid (40 Man)", 4, "Layout used when you are in a 40-player raid instance."),
                            },
                        },
                        pvpGroup = {
                            type   = "group",
                            name   = "PvP",
                            order  = 4,
                            inline = true,
                            args   = {
                                arena = slotSelect("arena", "Arena",                  1, "Layout used when you are in an Arena match."),
                                bg15  = slotSelect("bg15",  "Battleground (15 Man)",  2, "Layout used when you are in a 15-player Battleground."),
                                bg40  = slotSelect("bg40",  "Battleground (40 Man)",  3, "Layout used when you are in a 40-player Battleground."),
                            },
                        },
                    }
                end)(),
            },
            tabLayoutManagement = {
                type        = "group",
                name        = "Layout Management",
                order       = 0.7,
                childGroups = "tab",
                args        = (function()
                    -- Human-readable slot labels for the "in use" popup that
                    -- blocks deletion of a flat assigned to one or more slots.
                    -- Human-readable slot labels. Hoisted to BF.SLOT_LABELS.
                    -- Local alias preserved for existing closure consumers.
                    local SLOT_LABELS = BF.SLOT_LABELS

                    -- Build id→name dropdown values for flatLayouts, optionally
                    -- filtered by type and optionally excluding seeded flats.
                    local function listFlats(filterType, excludeSeeded)
                        local fl = self.rpDB.profile.layouts.flatLayouts or {}
                        local t  = {}
                        for id, layout in pairs(fl) do
                            local typeOk    = (filterType == nil)    or (layout.type == filterType)
                            local seededOk  = (not excludeSeeded)    or (not isSeededFlat(id))
                            if typeOk and seededOk then
                                t[id] = layout.name or id
                            end
                        end
                        return t
                    end

                    -- Stable sort order used by every flat dropdown: seeded
                    -- flats first (flat_party, flat_raid20/30/40), then any
                    -- other flats alphabetically by id.
                    local function sortFlats(filterType, excludeSeeded)
                        local fl = self.rpDB.profile.layouts.flatLayouts or {}
                        local keys = {}
                        local preferred = { "flat_party", "flat_raid20", "flat_raid30", "flat_raid40" }
                        local seen = {}
                        if not excludeSeeded then
                            for _, id in ipairs(preferred) do
                                local layout = fl[id]
                                if layout and (filterType == nil or layout.type == filterType) then
                                    keys[#keys + 1] = id; seen[id] = true
                                end
                            end
                        end
                        local extras = {}
                        for id, layout in pairs(fl) do
                            if not seen[id] then
                                local typeOk    = (filterType == nil)   or (layout.type == filterType)
                                local seededOk  = (not excludeSeeded)   or (not isSeededFlat(id))
                                if typeOk and seededOk then
                                    extras[#extras + 1] = id
                                end
                            end
                        end
                        table.sort(extras)
                        for _, id in ipairs(extras) do keys[#keys + 1] = id end
                        return keys
                    end

                    -- Is there any non-seeded flat at all? Used to hide
                    -- the Rename and Remove selectors when there's nothing
                    -- to act on.
                    local function anyUserFlats()
                        local fl = self.rpDB.profile.layouts.flatLayouts or {}
                        for id in pairs(fl) do
                            if not isSeededFlat(id) then return true end
                        end
                        return false
                    end

                    return {
                        managementDesc = {
                            type  = "description",
                            name  = "Create, rename, copy, or remove Layouts. Each Layout has a type (Party or Raid); assignments in the 'Layouts by Instance Type' tab are filtered so only type-compatible Layouts appear for each slot.",
                            order = 0,
                            width = "full",
                        },

                        -- ── Tab: Create ─────────────────────────────────────────
                        tabCreateFlat = {
                            type  = "group",
                            name  = "Create",
                            order = 1,
                            args  = {
                                createFlatType = {
                                    type    = "select",
                                    name    = "Type",
                                    desc    = "Party Layouts are used for 5-player groups (Solo, Party, Dungeon, Delve, Arena). Raid Layouts are used for raid groups and battlegrounds.",
                                    order   = 1,
                                    width   = "normal",
                                    values  = { party = "Party", raid = "Raid" },
                                    sorting = { "party", "raid" },
                                    get     = function() return self._createFlatType or "party" end,
                                    set     = function(_, val)
                                        self._createFlatType = val
                                        -- Reset copy-from when type changes; it may
                                        -- no longer be valid under the new type.
                                        self._createFlatCopyFrom = nil
                                        LibStub("AceConfigRegistry-3.0"):NotifyChange("BuzzardFrames")
                                    end,
                                },
                                createFlatCopyFrom = {
                                    type    = "select",
                                    name    = "Copy Settings From",
                                    desc    = "Choose an existing Layout of the same type to copy settings from. Defaults to the seeded Layout for the chosen type.",
                                    order   = 2,
                                    width   = "normal",
                                    values  = function()
                                        local t = self._createFlatType or "party"
                                        return listFlats(t, false)
                                    end,
                                    sorting = function()
                                        local t = self._createFlatType or "party"
                                        return sortFlats(t, false)
                                    end,
                                    get     = function()
                                        local t = self._createFlatType or "party"
                                        local defaultID = (t == "party") and "flat_party" or "flat_raid40"
                                        local chosen = self._createFlatCopyFrom
                                        local fl = self.rpDB.profile.layouts.flatLayouts or {}
                                        if chosen and fl[chosen] and fl[chosen].type == t then return chosen end
                                        if fl[defaultID] then return defaultID end
                                        -- Fallback: first flat of the right type.
                                        for id, layout in pairs(fl) do
                                            if layout.type == t then return id end
                                        end
                                        return nil
                                    end,
                                    set     = function(_, val)
                                        self._createFlatCopyFrom = val
                                        LibStub("AceConfigRegistry-3.0"):NotifyChange("BuzzardFrames")
                                    end,
                                },
                                createFlatName = {
                                    type  = "input",
                                    name  = "Create Layout",
                                    desc  = "Type a name and press Enter (or click OK) to create the new Layout.",
                                    order = 3,
                                    width = "double",
                                    get   = function() return "" end,
                                    set   = function(_, val)
                                        if not val or val:match("^%s*$") then return end
                                        local p  = self.rpDB.profile.layouts
                                        p.flatLayouts = p.flatLayouts or {}
                                        -- Name-uniqueness check across all flats.
                                        for _, layout in pairs(p.flatLayouts) do
                                            if layout.name == val then
                                                print("BuzzardFrames: A Layout named \"" .. val .. "\" already exists.")
                                                return
                                            end
                                        end
                                        local newType = self._createFlatType or "party"
                                        local src     = self._createFlatCopyFrom
                                                      or ((newType == "party") and "flat_party" or "flat_raid40")
                                        local newID   = newFlatID()
                                        local flat
                                        if p.flatLayouts[src] and p.flatLayouts[src].type == newType then
                                            flat = self:DeepCopy(p.flatLayouts[src])
                                        else
                                            -- Source invalid/missing → seed from factory defaults.
                                            if newType == "party" then
                                                flat = self:CreateFlatPartyLayout(val)
                                            else
                                                flat = self:CreateFlatRaidLayout(val, -260, -200)
                                            end
                                        end
                                        flat.name = val
                                        flat.type = newType
                                        -- Wire metatable __index template so unmodified keys
                                        -- fall through to CreateRaidProfile/CreatePartyProfile
                                        -- defaults. See Core_FlatDefaults.lua. Required for
                                        -- any newly-created flat so reads of un-customized
                                        -- keys don't return nil.
                                        self:WireFlatDefaults(flat)
                                        p.flatLayouts[newID] = flat
                                        -- DeepCopy strips metatables. WireFlatDefaults re-wires
                                        -- the top-level __index template, but the per-section
                                        -- and per-aura-subcategory fallbacks (flat.auras ->
                                        -- rpDB.profile.auras and flat.auras.<subcat> -> global
                                        -- sub-table) also need re-wiring or un-customized keys
                                        -- like maxPrivateAuras / privateAuraGrowDirection return
                                        -- nil on the copy. RehydrateFlats runs the full wiring
                                        -- pass and is idempotent.
                                        self:RehydrateFlats()
                                        -- New flat has no _auraCache yet; mark it
                                        -- dirty so the next UpdateAuraSizeCache builds one.
                                        if self.InvalidateFlatAuraCache then self:InvalidateFlatAuraCache(flat) end
                                        self._createFlatCopyFrom = nil
                                        local srcName = (p.flatLayouts[src] and p.flatLayouts[src].name) or src
                                        print("BuzzardFrames: Created Layout \"" .. val .. "\" (" .. newType .. ", copied from \"" .. srcName .. "\")")
                                        if BF._regeneratePreviewArgs then BF._regeneratePreviewArgs() end
                                        if BF.RefreshPreviewFrames then BF:RefreshPreviewFrames() end
                                        LibStub("AceConfigRegistry-3.0"):NotifyChange("BuzzardFrames")
                                    end,
                                },
                            },
                        },

                        -- ── Tab: Edit (rename + copy) ──────────────────────────
                        tabEditFlat = {
                            type  = "group",
                            name  = "Edit",
                            order = 2,
                            args  = {
                                renameHeader = {
                                    type  = "header",
                                    name  = "Rename Layout",
                                    order = 1,
                                },
                                renameFlatSelect = {
                                    type    = "select",
                                    name    = "Rename Layout",
                                    desc    = "Select a Layout to rename.",
                                    order   = 2,
                                    width   = "normal",
                                    values  = function() return listFlats(nil) end,
                                    sorting = function() return sortFlats(nil) end,
                                    get     = function()
                                        local fl = self.rpDB.profile.layouts.flatLayouts or {}
                                        if self._renameFlatID and fl[self._renameFlatID] then
                                            return self._renameFlatID
                                        end
                                        return nil
                                    end,
                                    set     = function(_, val)
                                        self._renameFlatID = val
                                        LibStub("AceConfigRegistry-3.0"):NotifyChange("BuzzardFrames")
                                    end,
                                },
                                renameFlatInput = {
                                    type   = "input",
                                    name   = "New Name",
                                    desc   = "Type a new name and press Enter (or click OK) to rename the selected Layout.",
                                    order  = 3,
                                    width  = "double",
                                    hidden = function() return not self._renameFlatID end,
                                    get    = function()
                                        local fl = self.rpDB.profile.layouts.flatLayouts or {}
                                        local id = self._renameFlatID
                                        if id and fl[id] then return fl[id].name or "" end
                                        return ""
                                    end,
                                    set    = function(_, val)
                                        if not val or val:match("^%s*$") then return end
                                        local p  = self.rpDB.profile.layouts
                                        local fl = p.flatLayouts or {}
                                        local id = self._renameFlatID
                                        if not id or not fl[id] then return end
                                        for oid, layout in pairs(fl) do
                                            if oid ~= id and layout.name == val then
                                                print("BuzzardFrames: A Layout named \"" .. val .. "\" already exists.")
                                                return
                                            end
                                        end
                                        local oldName = fl[id].name
                                        fl[id].name   = val
                                        print("BuzzardFrames: Renamed Layout \"" .. oldName .. "\" to \"" .. val .. "\"")
                                        LibStub("AceConfigRegistry-3.0"):NotifyChange("BuzzardFrames")
                                    end,
                                },

                                copyHeader = {
                                    type  = "header",
                                    name  = "Copy Layout Settings",
                                    order = 10,
                                },
                                copyFlatFrom = {
                                    type    = "select",
                                    name    = "Copy From",
                                    desc    = "Select the source Layout to copy settings from.",
                                    order   = 11,
                                    width   = "normal",
                                    values  = function() return listFlats(nil, false) end,
                                    sorting = function() return sortFlats(nil, false) end,
                                    get     = function()
                                        local fl = self.rpDB.profile.layouts.flatLayouts or {}
                                        if self._copyFlatFrom and fl[self._copyFlatFrom] then
                                            return self._copyFlatFrom
                                        end
                                        return nil
                                    end,
                                    set     = function(_, val)
                                        self._copyFlatFrom = val
                                        -- Reset destination when source changes; it
                                        -- may no longer share the source's type.
                                        self._copyFlatTo = nil
                                        LibStub("AceConfigRegistry-3.0"):NotifyChange("BuzzardFrames")
                                    end,
                                },
                                copyFlatTo = {
                                    type    = "select",
                                    name    = "To",
                                    desc    = "Select the destination Layout to overwrite. Only Layouts of the same type as the source are shown.",
                                    order   = 12,
                                    width   = "normal",
                                    values  = function()
                                        local fl = self.rpDB.profile.layouts.flatLayouts or {}
                                        local fromID = self._copyFlatFrom
                                        if not fromID or not fl[fromID] then return {} end
                                        local srcType = fl[fromID].type
                                        local t = {}
                                        for id, layout in pairs(fl) do
                                            if id ~= fromID and layout.type == srcType then
                                                t[id] = layout.name or id
                                            end
                                        end
                                        return t
                                    end,
                                    sorting = function()
                                        local fl = self.rpDB.profile.layouts.flatLayouts or {}
                                        local fromID = self._copyFlatFrom
                                        if not fromID or not fl[fromID] then return {} end
                                        local srcType = fl[fromID].type
                                        local all = sortFlats(srcType, false)
                                        local filtered = {}
                                        for _, id in ipairs(all) do
                                            if id ~= fromID then filtered[#filtered + 1] = id end
                                        end
                                        return filtered
                                    end,
                                    get     = function() return self._copyFlatTo end,
                                    set     = function(_, val)
                                        self._copyFlatTo = val
                                        LibStub("AceConfigRegistry-3.0"):NotifyChange("BuzzardFrames")
                                    end,
                                },
                                copyFlatExecute = {
                                    type     = "execute",
                                    name     = "Copy Settings",
                                    desc     = "Overwrite the destination Layout with all settings from the source Layout.",
                                    order    = 13,
                                    width    = "normal",
                                    disabled = function() return not self._copyFlatFrom or not self._copyFlatTo end,
                                    confirm  = function()
                                        local fl = self.rpDB.profile.layouts.flatLayouts or {}
                                        local fromName = self._copyFlatFrom and fl[self._copyFlatFrom] and fl[self._copyFlatFrom].name or "?"
                                        local toName   = self._copyFlatTo   and fl[self._copyFlatTo]   and fl[self._copyFlatTo].name   or "?"
                                        return "Copy all settings from \"" .. fromName .. "\" into \"" .. toName .. "\"? This will overwrite all of \"" .. toName .. "\"'s settings."
                                    end,
                                    func = function()
                                        local p  = self.rpDB.profile.layouts
                                        local fl = p.flatLayouts or {}
                                        local from = self._copyFlatFrom
                                        local to   = self._copyFlatTo
                                        if not from or not to or not fl[from] or not fl[to] then return end
                                        if fl[from].type ~= fl[to].type then
                                            print("BuzzardFrames: Cannot copy \"" .. fl[from].name .. "\" into \"" .. fl[to].name .. "\" — Layouts are different types.")
                                            return
                                        end
                                        local toName = fl[to].name
                                        local copy   = self:DeepCopy(fl[from])
                                        copy.name = toName          -- preserve destination's name
                                        copy.type = fl[to].type     -- and type (sanity)
                                        -- Wire metatable __index template on the copy so
                                        -- unmodified keys fall through. See Core_FlatDefaults.lua.
                                        self:WireFlatDefaults(copy)
                                        fl[to] = copy
                                        -- DeepCopy strips metatables. WireFlatDefaults re-wires
                                        -- the top-level __index template, but the per-section
                                        -- and per-aura-subcategory fallbacks (flat.auras ->
                                        -- rpDB.profile.auras and flat.auras.<subcat> -> global
                                        -- sub-table) also need re-wiring or un-customized keys
                                        -- like maxPrivateAuras / privateAuraGrowDirection return
                                        -- nil on the copy. RehydrateFlats runs the full wiring
                                        -- pass and is idempotent.
                                        self:RehydrateFlats()
                                        print("BuzzardFrames: Copied settings from \"" .. fl[from].name .. "\" into \"" .. toName .. "\"")
                                        self._copyFlatFrom = nil
                                        self._copyFlatTo   = nil
                                        LibStub("AceConfigRegistry-3.0"):NotifyChange("BuzzardFrames")
                                    end,
                                },
                            },
                        },

                        -- ── Tab: Remove ─────────────────────────────────────────
                        tabRemoveFlat = {
                            type  = "group",
                            name  = "Remove",
                            order = 3,
                            args  = {
                                removeFlat = {
                                    type    = "select",
                                    name    = "Remove Layout",
                                    desc    = "Select a Layout to permanently delete it. Seeded Layouts cannot be deleted.",
                                    order   = 1,
                                    width   = "normal",
                                    hidden  = function() return not anyUserFlats() end,
                                    values  = function() return listFlats(nil, true) end,
                                    sorting = function() return sortFlats(nil, true) end,
                                    confirm = function(_, val)
                                        local fl = self.rpDB.profile.layouts.flatLayouts or {}
                                        local name = fl[val] and fl[val].name or val
                                        return "Are you sure you want to delete Layout \"" .. name .. "\"? This cannot be undone."
                                    end,
                                    get = function() return nil end,
                                    set = function(_, val)
                                        local p  = self.rpDB.profile.layouts
                                        local fl = p.flatLayouts or {}
                                        if not fl[val] or isSeededFlat(val) then return end
                                        local name = fl[val].name or val
                                        -- Usage check: is this flat assigned to any slot?
                                        local usages = {}
                                        if p.instanceLayoutAssignment then
                                            for slotKey, assignedID in pairs(p.instanceLayoutAssignment) do
                                                if assignedID == val then
                                                    table.insert(usages, SLOT_LABELS[slotKey] or slotKey)
                                                end
                                            end
                                        end
                                        -- CFG check: is this flat the base layout for any CFG?
                                        local cfgGroups = BF.cfgDB and BF.cfgDB.profile
                                            and BF.cfgDB.profile.customFrameGroups
                                        if cfgGroups then
                                            for _, grp in ipairs(cfgGroups) do
                                                if grp.baseLayoutID == val then
                                                    table.insert(usages, "Custom Frame Group: " .. (grp.name or "Unnamed"))
                                                end
                                            end
                                        end
                                        if #usages > 0 then
                                            local msg = "Cannot delete Layout \"" .. name .. "\" — it is assigned in " .. #usages .. " slot(s):\n"
                                            for _, u in ipairs(usages) do
                                                msg = msg .. "\n• " .. u
                                            end
                                            StaticPopup_Show("BUZZARDFRAMES_LAYOUT_IN_USE", msg)
                                            return
                                        end
                                        -- If Setup Mode is on and the flat being deleted is the
                                        -- one currently being edited, exit Setup Mode first.
                                        -- GetModifyingProfile() would return nil on the next
                                        -- setup-mode tick otherwise, and any pending drag/resize
                                        -- MouseUp would try to write anchorX/Y/frameWidth back
                                        -- to a profile that no longer exists.
                                        if BF._modifyingFlat == val
                                           and BF.db and BF.db.global and BF.db.global.setupModeActive
                                           and BF.ExitSetupMode then
                                            BF:ExitSetupMode()
                                        end
                                        fl[val] = nil
                                        -- Drop any stale references to the deleted flat
                                        local pp = self.rpDB.profile
                                        if pp._pinnedPreviewFlats then pp._pinnedPreviewFlats[val] = nil end
                                        if pp._previewUnitsByFlat  then pp._previewUnitsByFlat[val]  = nil end
                                        if BF._modifyingFlat == val then BF._modifyingFlat = nil end
                                        print("BuzzardFrames: Removed Layout \"" .. name .. "\"")
                                        if BF._regeneratePreviewArgs then BF._regeneratePreviewArgs() end
                                        if BF.RefreshPreviewFrames then BF:RefreshPreviewFrames() end
                                        LibStub("AceConfigRegistry-3.0"):NotifyChange("BuzzardFrames")
                                    end,
                                },
                                noFlatsNote = {
                                    type   = "description",
                                    name   = "No custom Layouts to remove. Seeded Layouts (Party, Raid (40), etc.) cannot be deleted.",
                                    order  = 2,
                                    hidden = function() return anyUserFlats() end,
                                },
                            },
                        },
                    }
                end)(),
            },
            -- ================================================================
            -- tabLayoutsWrapper: Role/Spec Layouts tab
            -- ================================================================
            -- Structure:
            --   - childGroups = "tree" so each added role/spec is a tree
            --     child of "Role/Spec Layouts" in the left nav
            --   - "Add Role Overrides" / "Add Spec Overrides" dropdowns live
            --     as non-group args, rendering on the tree's root page
            --     alongside the precedence description
            --   - Each role/spec entry shows an 11-slot override grid
            --   - Presence of a key in roleOverrides/specOverrides (with
            --     the _present marker) is the sole enable gate; no toggles
            tabLayoutsWrapper = (function()
                -- Fixed role definitions (Tank/Healer/DPS in tree order).
                local ROLE_DEFS = {
                    { key = "TANK",    label = "Tank",   order = 1, atlas = "roleicon-tiny-tank"   },
                    { key = "HEALER",  label = "Healer", order = 2, atlas = "roleicon-tiny-healer" },
                    { key = "DAMAGER", label = "DPS",    order = 3, atlas = "roleicon-tiny-dps"    },
                }

                -- Forward-declare wrapper + regenerateTreeArgs at the top
                -- of the IIFE so that every nested function below
                -- (overrideGroup's deleteSelf, the Add dropdown setters,
                -- etc.) captures them as upvalues rather than globals.
                -- Actual assignments happen at the bottom of the IIFE.
                local wrapper
                local regenerateTreeArgs

                -- Shared helper: produce values/sorting for a slot override dropdown.
                -- includeSoloNone = true only for the solo slot.
                local function overrideSlotValues(slotKey, includeSoloNone)
                    local fl       = self.rpDB.profile.layouts.flatLayouts or {}
                    local ila      = self.rpDB.profile.layouts.instanceLayoutAssignment or {}
                    local required = (BF.SLOT_TYPE or {})[slotKey]
                    local globalID = ila[slotKey]
                    local globalName
                    if not globalID or globalID == "none" then
                        globalName = "None"
                    elseif fl[globalID] then
                        globalName = fl[globalID].name or globalID
                    else
                        globalName = globalID
                    end
                    local t = { __global = "Use global setting (" .. globalName .. ")" }
                    if includeSoloNone then t.none = "None" end
                    for id, layout in pairs(fl) do
                        if layout.type == required then
                            t[id] = layout.name or id
                        end
                    end
                    return t
                end

                local function overrideSlotSorting(slotKey, includeSoloNone)
                    local fl       = self.rpDB.profile.layouts.flatLayouts or {}
                    local required = (BF.SLOT_TYPE or {})[slotKey]
                    local keys = { "__global" }
                    if includeSoloNone then keys[#keys + 1] = "none" end
                    local preferred = { "flat_party", "flat_raid20", "flat_raid30", "flat_raid40" }
                    local seen = {}
                    for _, id in ipairs(preferred) do
                        if fl[id] and fl[id].type == required then
                            keys[#keys + 1] = id; seen[id] = true
                        end
                    end
                    local extras = {}
                    for id, layout in pairs(fl) do
                        if not seen[id] and layout.type == required then
                            extras[#extras + 1] = id
                        end
                    end
                    table.sort(extras)
                    for _, id in ipairs(extras) do keys[#keys + 1] = id end
                    return keys
                end

                -- Factory: build one per-slot dropdown for a role or spec entry.
                local function slotOverrideSelect(kind, entryKey, slotKey, slotLabel, slotOrder)
                    local includeNone = (slotKey == "solo")
                    local function overridesTable()
                        local p = self.rpDB.profile.layouts
                        if kind == "role" then
                            p.roleOverrides = p.roleOverrides or { HEALER = {}, TANK = {}, DAMAGER = {} }
                            p.roleOverrides[entryKey] = p.roleOverrides[entryKey] or {}
                            return p.roleOverrides[entryKey]
                        else
                            p.specOverrides = p.specOverrides or {}
                            p.specOverrides[entryKey] = p.specOverrides[entryKey] or {}
                            return p.specOverrides[entryKey]
                        end
                    end
                    return {
                        type    = "select",
                        name    = slotLabel,
                        order   = slotOrder,
                        width   = "double",
                        values  = function() return overrideSlotValues(slotKey, includeNone) end,
                        sorting = function() return overrideSlotSorting(slotKey, includeNone) end,
                        get     = function()
                            local ot = overridesTable()
                            return ot[slotKey] or "__global"
                        end,
                        set     = function(_, val)
                            local ot = overridesTable()
                            ot[slotKey] = (val == "__global") and nil or val
                            self:InvalidateRaidProfileCache()
                            if self.RefreshAll then self:RefreshAll() end
                        end,
                    }
                end

                -- Builds the right-pane content (title + delete + 11-slot grid)
                -- for one role or spec entry.
                -- kind = "role" | "spec"; entryKey = "TANK"/"HEALER"/"DAMAGER"
                -- for role, or specID string for spec.
                local function overrideGroup(kind, entryKey, label, order)
                    local function typeBadge()
                        return (kind == "role")
                            and "|cff7f77ddRole override|r"
                            or  "|cff1d9e75Spec override|r"
                    end
                    local function deleteSelf()
                        local p = self.rpDB.profile.layouts
                        if kind == "role" then
                            if p.roleOverrides then p.roleOverrides[entryKey] = nil end
                        else
                            if p.specOverrides then p.specOverrides[entryKey] = nil end
                        end
                        self:InvalidateRaidProfileCache()
                        if self.RefreshAll then self:RefreshAll() end
                        -- Rebuild the wrapper's args so the deleted tree
                        -- child is removed. Without this, NotifyChange
                        -- re-reads the same stale args table and the entry
                        -- stays in the tree.
                        regenerateTreeArgs()
                        -- Navigate back to the wrapper root before the tree
                        -- child we're currently on disappears. Otherwise
                        -- the right pane stays on a node whose data is nil.
                        local ACD = LibStub("AceConfigDialog-3.0", true)
                        if ACD then
                            ACD:SelectGroup("BuzzardFrames", "raidPartyFrames",
                                "roleSpecLayouts", "tabLayoutsWrapper")
                        end
                        LibStub("AceConfigRegistry-3.0"):NotifyChange("BuzzardFrames")
                    end
                    return {
                        type  = "group",
                        name  = label,
                        order = order,
                        args  = {
                            titleHeader = {
                                type  = "header",
                                name  = label .. "    " .. typeBadge(),
                                order = 1,
                            },
                            openWorldGroup = {
                                type = "group", name = "Open World", order = 10, inline = true,
                                args = {
                                    solo           = slotOverrideSelect(kind, entryKey, "solo",           "Solo",              1),
                                    openWorldParty = slotOverrideSelect(kind, entryKey, "openWorldParty", "Party",             2),
                                    raidOpen       = slotOverrideSelect(kind, entryKey, "raidOpen",       "Raid (Open World)", 3),
                                },
                            },
                            dungeonGroup = {
                                type = "group", name = "Dungeon", order = 20, inline = true,
                                args = {
                                    dungeon = slotOverrideSelect(kind, entryKey, "dungeon", "Dungeon", 1),
                                    delve   = slotOverrideSelect(kind, entryKey, "delve",   "Delve",   2),
                                },
                            },
                            raidGroup = {
                                type = "group", name = "Raid", order = 30, inline = true,
                                args = {
                                    raid20 = slotOverrideSelect(kind, entryKey, "raid20", "Raid (20 Man)", 1),
                                    raid30 = slotOverrideSelect(kind, entryKey, "raid30", "Raid (30 Man)", 2),
                                    raid40 = slotOverrideSelect(kind, entryKey, "raid40", "Raid (40 Man)", 3),
                                },
                            },
                            pvpGroup = {
                                type = "group", name = "PvP", order = 40, inline = true,
                                args = {
                                    arena = slotOverrideSelect(kind, entryKey, "arena", "Arena",                 1),
                                    bg15  = slotOverrideSelect(kind, entryKey, "bg15",  "Battleground (15 Man)", 2),
                                    bg40  = slotOverrideSelect(kind, entryKey, "bg40",  "Battleground (40 Man)", 3),
                                },
                            },
                            -- Remove button lives at the bottom of the pane
                            -- so destructive actions aren't the first thing
                            -- the user sees after selecting an entry.
                            removeSpacer = {
                                type  = "description",
                                name  = " ",
                                order = 99,
                                width = "full",
                            },
                            removeButton = {
                                type    = "execute",
                                name    = "Remove",
                                desc    = "Remove this override entry. The role/spec will revert to using global settings.",
                                order   = 100,
                                width   = "normal",
                                confirm = function()
                                    return "Remove this " .. kind .. " override? The " .. kind .. " will revert to using global settings."
                                end,
                                func    = deleteSelf,
                            },
                        },
                    }
                end

                -- Build the childGroups="select" args table from current
                -- roleOverrides/specOverrides state. Called at registration
                -- time AND on every add/remove via regenerateTreeArgs().
                local function buildTreeArgs()
                    local p  = self.rpDB.profile.layouts
                    local ro = p.roleOverrides or {}
                    local so = p.specOverrides or {}
                    local args = {}

                    -- Roles in fixed Tank -> Healer -> DPS order,
                    -- only if _present marker is set.
                    for _, def in ipairs(ROLE_DEFS) do
                        if ro[def.key] and ro[def.key]._present then
                            local icon = (CreateAtlasMarkup and CreateAtlasMarkup(def.atlas, 16, 16)) or ""
                            args["role_" .. def.key] = overrideGroup("role", def.key, icon .. " " .. def.label, def.order)
                        end
                    end

                    -- Specs: sort alphabetically by name, only _present entries.
                    -- Orders start at 100 so they always sort after roles
                    -- (which use orders 1-3), giving natural visual separation
                    -- without a divider.
                    local specList = {}
                    for idStr, entry in pairs(so) do
                        if type(entry) == "table" and entry._present then
                            local id = tonumber(idStr)
                            local s  = BF.specByID and BF.specByID[id]
                            if s then
                                specList[#specList + 1] = { idStr = idStr, name = s.name, icon = s.icon }
                            end
                        end
                    end
                    table.sort(specList, function(a, b) return a.name < b.name end)

                    for i, sp in ipairs(specList) do
                        local nameText = "|T" .. sp.icon .. ":14|t " .. sp.name
                        args["spec_" .. sp.idStr] = overrideGroup("spec", sp.idStr, nameText, 100 + i)
                    end

                    return args
                end

                -- Structural note: role/spec entries are tree children of
                -- the wrapper itself (childGroups="tree") so they appear as
                -- navigable nodes in the left-side tree below "Role/Spec
                -- Layouts", instead of being selected via a dropdown in the
                -- right pane. Pattern copied from BF's
                -- BuildCustomFramesOptions (Options_CustomFrames.lua):
                -- childGroups="tree" makes child groups into tree nodes
                -- while non-group args (the two Add dropdowns) render on
                -- the tree's root page.

                local addRoleDropdown = {
                    type    = "select",
                    name    = "Add Role Overrides",
                    order   = 1,
                    width   = "normal",
                    values  = function()
                        local t = {}
                        local p = self.rpDB.profile.layouts
                        p.roleOverrides = p.roleOverrides or { HEALER = {}, TANK = {}, DAMAGER = {} }
                        for _, def in ipairs(ROLE_DEFS) do
                            if not (p.roleOverrides[def.key] and p.roleOverrides[def.key]._present) then
                                local icon = (CreateAtlasMarkup and CreateAtlasMarkup(def.atlas, 16, 16)) or ""
                                t[def.key] = icon .. " " .. def.label
                            end
                        end
                        return t
                    end,
                    sorting = function()
                        local p = self.rpDB.profile.layouts
                        p.roleOverrides = p.roleOverrides or { HEALER = {}, TANK = {}, DAMAGER = {} }
                        local keys = {}
                        for _, def in ipairs(ROLE_DEFS) do
                            if not (p.roleOverrides[def.key] and p.roleOverrides[def.key]._present) then
                                keys[#keys + 1] = def.key
                            end
                        end
                        return keys
                    end,
                    get     = function() return nil end,
                    set     = function(_, val)
                        local p = self.rpDB.profile.layouts
                        p.roleOverrides = p.roleOverrides or { HEALER = {}, TANK = {}, DAMAGER = {} }
                        p.roleOverrides[val] = p.roleOverrides[val] or {}
                        p.roleOverrides[val]._present = true
                        self:InvalidateRaidProfileCache()
                        if self.RefreshAll then self:RefreshAll() end
                        regenerateTreeArgs()
                        LibStub("AceConfigRegistry-3.0"):NotifyChange("BuzzardFrames")
                        -- Auto-navigate to the newly-added role tree node.
                        -- Mirrors the customFrames add-group pattern.
                        local ACD = LibStub("AceConfigDialog-3.0", true)
                        if ACD then
                            ACD:SelectGroup("BuzzardFrames", "raidPartyFrames",
                                "roleSpecLayouts", "tabLayoutsWrapper", "role_" .. val)
                        end
                    end,
                }
                local addSpecDropdown = {
                    type    = "select",
                    name    = "Add Spec Overrides",
                    order   = 2,
                    width   = "normal",
                    values  = function()
                        local t = {}
                        local p = self.rpDB.profile.layouts
                        p.specOverrides = p.specOverrides or {}
                        if BF.specData then
                            for _, s in ipairs(BF.specData) do
                                local idStr = tostring(s.id)
                                local entry = p.specOverrides[idStr]
                                if not (type(entry) == "table" and entry._present) then
                                    t[idStr] = "|T" .. s.icon .. ":14|t " .. s.name
                                end
                            end
                        end
                        return t
                    end,
                    sorting = function()
                        local p = self.rpDB.profile.layouts
                        p.specOverrides = p.specOverrides or {}
                        local list = {}
                        if BF.specData then
                            for _, s in ipairs(BF.specData) do
                                local idStr = tostring(s.id)
                                local entry = p.specOverrides[idStr]
                                if not (type(entry) == "table" and entry._present) then
                                    list[#list + 1] = { id = idStr, name = s.name }
                                end
                            end
                        end
                        table.sort(list, function(a, b) return a.name < b.name end)
                        local keys = {}
                        for _, e in ipairs(list) do keys[#keys + 1] = e.id end
                        return keys
                    end,
                    get     = function() return nil end,
                    set     = function(_, val)
                        local p = self.rpDB.profile.layouts
                        p.specOverrides = p.specOverrides or {}
                        p.specOverrides[val] = p.specOverrides[val] or {}
                        p.specOverrides[val]._present = true
                        self:InvalidateRaidProfileCache()
                        if self.RefreshAll then self:RefreshAll() end
                        regenerateTreeArgs()
                        LibStub("AceConfigRegistry-3.0"):NotifyChange("BuzzardFrames")
                        -- Auto-navigate to the newly-added spec tree node.
                        local ACD = LibStub("AceConfigDialog-3.0", true)
                        if ACD then
                            ACD:SelectGroup("BuzzardFrames", "raidPartyFrames",
                                "roleSpecLayouts", "tabLayoutsWrapper", "spec_" .. val)
                        end
                    end,
                }

                -- Merges the dynamic role/spec tree entries (regenerated
                -- on add/delete) with the root-page content: the precedence
                -- description and the two static Add dropdowns.
                local function buildWrapperArgs()
                    local args = buildTreeArgs()
                    args.rootPrecedenceDesc = {
                        type  = "description",
                        name  = "If conflicting Role and Spec overrides are defined (e.g. both Healer and Resto Shaman are defined and have different settings), the Spec overrides take priority.",
                        order = 0,
                        width = "full",
                    }
                    args.addRoleDropdown = addRoleDropdown
                    args.addSpecDropdown = addSpecDropdown
                    return args
                end

                wrapper = {
                    type        = "group",
                    name        = "Role/Spec Layouts",
                    order       = 2,
                    childGroups = "tree",
                    args        = buildWrapperArgs(),
                }

                regenerateTreeArgs = function()
                    wrapper.args = buildWrapperArgs()
                end

                return wrapper
            end)(),
        },  -- end args
    }
end
