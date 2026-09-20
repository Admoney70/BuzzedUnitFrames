-- ============================================================
-- BuzzardFrames: Options_Preview.lua
--
-- AceConfig options table for the "Preview & Special Options" tab.
-- Also contains HideDummyAuras (used by both system and data files).
--
-- Look here when the Preview options UI is broken.
-- ============================================================
local BF = _G["BuzzardFrames"]

-- rpDB sub-table accessors (live reads, safe in any scope)
local function _rpDB() return BF.rpDB and BF.rpDB.profile or {} end
local function _rp_layouts() return _rpDB().layouts or {} end

-- Imports from Options_PreviewData.lua (resolved at call time, after Data loads)
local function _TYPE_DEFAULTS()        return BF._preview and BF._preview.TYPE_DEFAULTS end
local function _CF_FAKE_UNIT_DEFAULTS() return BF._preview.CF_FAKE_UNIT_DEFAULTS end
local MAX_CF_PREVIEWS       = 4
local CF_PREVIEW_COLOR      = "|cffffcc88"

-- Cleans up all dummy aura visuals on a preview frame.
-- Called from various preview refresh/hide paths below.
function BF:HideDummyAuras(frame)
    if not frame then return end
    if frame.SF_DummyRestartTimer then
        frame.SF_DummyRestartTimer:Cancel()
        frame.SF_DummyRestartTimer = nil
    end
    if self.HideDummyContainerAuras then self:HideDummyContainerAuras(frame) end
    if frame.buffFrames then
        for _, icon in ipairs(frame.buffFrames) do if icon:IsShown() then icon:Hide() end end
    end
    if frame.debuffFrames then
        for _, icon in ipairs(frame.debuffFrames) do if icon:IsShown() then icon:Hide() end end
    end
    if frame.bigDefIcons then
        for _, icon in ipairs(frame.bigDefIcons) do if icon:IsShown() then icon:Hide() end end
    elseif frame.bigDefIcon and frame.bigDefIcon:IsShown() then
        frame.bigDefIcon:Hide()
    end
    if frame.importantIcons then
        for _, icon in ipairs(frame.importantIcons) do if icon:IsShown() then icon:Hide() end end
    end
    if frame.crowdControlIcons then
        for _, icon in ipairs(frame.crowdControlIcons) do if icon:IsShown() then icon:Hide() end end
    elseif frame.crowdControlIcon and frame.crowdControlIcon:IsShown() then
        frame.crowdControlIcon:Hide()
    end
    if frame.dispelDebuffBorder then self:SetBorderColor(frame.dispelDebuffBorder, 0, 0, 0, 0) end
    if frame.dispelDebuffOverlay and frame.dispelDebuffOverlay:IsShown() then frame.dispelDebuffOverlay:Hide() end
    if frame.dispelDebuffIndicator and frame.dispelDebuffIndicator:IsShown() then frame.dispelDebuffIndicator:Hide() end
    -- Clear per-spell preview effects applied by ShowSingleSpellPreview
    if frame.buffOverlay and frame.buffOverlay:IsShown() then frame.buffOverlay:Hide() end
    if frame.buffColorOverlay and frame.buffColorOverlay:IsShown() then frame.buffColorOverlay:Hide() end
    if frame.dummyPrivateAuras then
        for _, pa in ipairs(frame.dummyPrivateAuras) do if pa:IsShown() then pa:Hide() end end
    end
end

-- ============================================================
function BF:BuildPreviewOptions(deps)
    local self             = deps.self
    local NotifyChangeSafe = deps.NotifyChangeSafe
    local get              = deps.get
    local set              = deps.set

    local function hasCustomLayouts()
        local p = self.db.profile
        if not _rp_layouts().enableRoleLayouts and not _rp_layouts().enableSpecLayouts then return false end
        local count = 0
        for _ in pairs(_rp_layouts().layouts) do count = count + 1 end
        return count > 1
    end

    local function layoutValues()
        local p = self.db.profile
        local activeID = _rp_layouts().activeLayout or BF._framesActiveLayout or "default"
        local t = {}
        for id, layout in pairs(_rp_layouts().layouts) do
            if id == activeID then
                t[id] = "|cff76CC4B" .. layout.name .. "|r"
            else
                t[id] = layout.name
            end
        end
        return t
    end

    -- ── Preview Units builder ────────────────────────────────────────
    -- The Preview Units subtab shows entries only for flats currently
    -- in the preview set: {editing flat} ∪ pinned flats. It regenerates
    -- whenever the set changes (via BF._regeneratePreviewArgs).
    --
    -- Layout of the tab:
    --   1. "+ Add preview…" dropdown at top (was previously on its own
    --      Pinned Previews subtab).
    --   2. One inline group per flat in the active preview set. The
    --      editing flat comes first and has no Remove button (it's in
    --      the set by virtue of being edited, not by being pinned).
    --      All subsequent flats are pinned and get a Remove button
    --      appended at the bottom of their group.
    --   3. CF preview unit groups (one per enabled custom frame group).
    --   4. "Reset All to Defaults" button at the bottom.
    local CLASS_LIST = {
        WARRIOR = "Warrior", PALADIN = "Paladin", HUNTER = "Hunter",
        ROGUE = "Rogue", PRIEST = "Priest", DEATHKNIGHT = "Death Knight",
        SHAMAN = "Shaman", MAGE = "Mage", WARLOCK = "Warlock",
        MONK = "Monk", DRUID = "Druid", DEMONHUNTER = "Demon Hunter",
        EVOKER = "Evoker",
    }
    local CLASS_SORTING = {
        "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST",
        "DEATHKNIGHT", "SHAMAN", "MAGE", "WARLOCK", "MONK",
        "DRUID", "DEMONHUNTER", "EVOKER",
    }
    local ROLE_LIST    = { TANK = "Tank", HEALER = "Healer", DAMAGER = "DPS" }
    local ROLE_SORTING = { "TANK", "HEALER", "DAMAGER" }

    -- Colour the flat name in UI by its type (matches preview label colours).
    local TYPE_COLORS = {
        party = "|cffaaffaa",
        raid  = "|cffaaccff",
    }

    -- Return the active preview set in stable display order.
    --
    -- Pinning model: all flats are pinned by default. The user
    -- explicitly unpins a flat by clicking "Hide this preview",
    -- which adds an entry to self.rpDB.profile._unpinnedPreviewFlats.
    -- A flat is pinned whenever it has no entry in that unpin set.
    -- New flats created by the user are automatically included in
    -- the preview pane with no seeding step.
    --
    -- The editing flat is NOT forced into the set — unpinning the
    -- flat you're currently editing hides it immediately.
    --
    -- Order is purely structural and does NOT depend on which flat
    -- is currently being edited: seeded flats in fixed order
    -- (flat_party, flat_raid20, flat_raid30, flat_raid40) first,
    -- then any remaining flats alphabetically. This keeps the tab
    -- layout (and the preview frames on screen) stable as the user
    -- switches between editing different flats.
    --
    -- The same rule is mirrored in Options_PreviewSystem.lua's
    -- ComputeActivePreviewSet; the two must stay in lockstep so the
    -- tab and the rendered frames show entries in the same order.
    local function computeActivePreviewOrder()
        local fl       = _rp_layouts().flatLayouts or {}
        local unpinned = self.rpDB.profile._unpinnedPreviewFlats or {}

        -- Active set: every flat not explicitly unpinned.
        local active = {}
        for id in pairs(fl) do
            if not unpinned[id] then active[id] = true end
        end

        local order = {}
        local seen  = {}

        local preferred = { "flat_party", "flat_raid20", "flat_raid30", "flat_raid40" }
        for _, id in ipairs(preferred) do
            if active[id] and not seen[id] then
                order[#order + 1] = id
                seen[id]          = true
            end
        end
        local extras = {}
        for id in pairs(active) do
            if not seen[id] then extras[#extras + 1] = id end
        end
        table.sort(extras)
        for _, id in ipairs(extras) do
            order[#order + 1] = id
            seen[id]          = true
        end
        return order
    end

    -- Build one inline group for a flat's preview unit config.
    -- Closes over flatID so get/set handlers write the right key.
    -- Includes a Remove button that unpins the flat. The Remove button
    -- is hidden for the editing flat: it's in the preview set by virtue
    -- of being edited, not by being pinned, so removing it would have
    -- no effect (it would immediately reappear on regenerate).
    local function buildFlatUnitGroup(flatID, orderIndex)
        local getDef = function()
            return (BF._preview and BF._preview.GetFlatTypeDefault
                and BF._preview.GetFlatTypeDefault(flatID))
                or { class = "WARRIOR", role = "TANK", hp = 0.75 }
        end
        local function getOv()
            local p = self.rpDB and self.rpDB.profile
            return p and p._previewUnitsByFlat and p._previewUnitsByFlat[flatID]
        end
        local function ensureOv()
            self.rpDB.profile._previewUnitsByFlat = self.rpDB.profile._previewUnitsByFlat or {}
            self.rpDB.profile._previewUnitsByFlat[flatID] =
                self.rpDB.profile._previewUnitsByFlat[flatID] or {}
            return self.rpDB.profile._previewUnitsByFlat[flatID]
        end
        return {
            type   = "group",
            inline = true,
            order  = orderIndex,
            name   = function()
                local fl   = _rp_layouts().flatLayouts or {}
                local flat = fl[flatID]
                if not flat then return flatID end
                local color   = TYPE_COLORS[flat.type] or "|cffffffff"
                local typeTag = (flat.type == "party") and "(Party)" or "(Raid)"
                return string.format("%s%s|r %s", color, flat.name or flatID, typeTag)
            end,
            args = {
                classSelect = {
                    type = "select", name = "Class", order = 1, width = "normal",
                    values  = CLASS_LIST,
                    sorting = CLASS_SORTING,
                    get = function()
                        local ov = getOv()
                        return (ov and ov.class) or getDef().class
                    end,
                    set = function(_, val)
                        ensureOv().class = val
                        if BF.RefreshPreviewFrames then BF:RefreshPreviewFrames() end
                    end,
                },
                roleSelect = {
                    type = "select", name = "Role", order = 2, width = "normal",
                    values  = ROLE_LIST,
                    sorting = ROLE_SORTING,
                    get = function()
                        local ov = getOv()
                        return (ov and ov.role) or getDef().role
                    end,
                    set = function(_, val)
                        ensureOv().role = val
                        if BF.RefreshPreviewFrames then BF:RefreshPreviewFrames() end
                    end,
                },
                healthPct = {
                    type = "range", name = "Health %", order = 3, width = "normal",
                    min = 0, max = 1, step = 0.01, isPercent = true,
                    get = function()
                        local ov = getOv()
                        return (ov and ov.hp) or getDef().hp
                    end,
                    set = function(_, val)
                        ensureOv().hp = val
                        if BF.RefreshPreviewFrames then BF:RefreshPreviewFrames() end
                    end,
                },
                remove = {
                    type   = "execute",
                    name   = "Hide this preview",
                    order  = 10,
                    width  = "normal",
                    func   = function()
                        self.rpDB.profile._unpinnedPreviewFlats = self.rpDB.profile._unpinnedPreviewFlats or {}
                        self.rpDB.profile._unpinnedPreviewFlats[flatID] = true
                        if BF._regeneratePreviewArgs then BF._regeneratePreviewArgs() end
                        if BF.RefreshPreviewFrames then BF:RefreshPreviewFrames() end
                        LibStub("AceConfigRegistry-3.0"):NotifyChange("BuzzardFrames")
                    end,
                },
            },
        }
    end

    -- Build args for tabPreviewUnits: "+ Add preview…" dropdown, then
    -- one inline group per flat in the active preview set, plus the
    -- CF preview unit entries (unchanged — CF system is outside the
    -- flat model). Each flat group has a Remove button except the
    -- editing flat (see buildFlatUnitGroup).
    local function buildPreviewUnitsArgs()
        local args = {}

        args._sectionTracker = {
            type = "description", order = -1, width = "full",
            name = function()
                if self._currentSection ~= "previewUnits" then
                    self._currentSection = "previewUnits"
                    if self.RefreshPreviewDummyAuras and not InCombatLockdown() then
                        self:RefreshPreviewDummyAuras()
                    end
                end
                return ""
            end,
        }

        -- "+ Add preview…" dropdown: re-pins a flat the user has
        -- previously unpinned via the Remove button. Only lists flats
        -- currently in the unpinned set; if nothing is unpinned the
        -- dropdown is disabled.
        args.addPreview = {
            type    = "select",
            name    = "+ Add preview\226\128\166",  -- "… " (horizontal ellipsis, UTF-8)
            order   = 0,
            width   = "normal",
            values  = function()
                local t = {}
                local flNow       = _rp_layouts().flatLayouts or {}
                local unpinnedNow = self.rpDB.profile._unpinnedPreviewFlats or {}
                for id, flat in pairs(flNow) do
                    if unpinnedNow[id] then
                        local color   = TYPE_COLORS[flat.type] or "|cffffffff"
                        local typeTag = (flat.type == "party") and "(Party)" or "(Raid)"
                        t[id] = string.format("%s%s|r %s", color, flat.name or id, typeTag)
                    end
                end
                return t
            end,
            sorting = function()
                local keys    = {}
                local flNow       = _rp_layouts().flatLayouts or {}
                local unpinnedNow = self.rpDB.profile._unpinnedPreviewFlats or {}
                local seeded  = { "flat_party", "flat_raid20", "flat_raid30", "flat_raid40" }
                local added   = {}
                for _, id in ipairs(seeded) do
                    if flNow[id] and unpinnedNow[id] then
                        keys[#keys + 1] = id
                        added[id]       = true
                    end
                end
                local extras = {}
                for id in pairs(flNow) do
                    if not added[id] and unpinnedNow[id] then
                        extras[#extras + 1] = id
                    end
                end
                table.sort(extras)
                for _, id in ipairs(extras) do keys[#keys + 1] = id end
                return keys
            end,
            get = function() return nil end,
            set = function(_, flatID)
                local unpinnedNow = self.rpDB.profile._unpinnedPreviewFlats
                if unpinnedNow then unpinnedNow[flatID] = nil end
                if BF._regeneratePreviewArgs then BF._regeneratePreviewArgs() end
                if BF.RefreshPreviewFrames then BF:RefreshPreviewFrames() end
                LibStub("AceConfigRegistry-3.0"):NotifyChange("BuzzardFrames")
            end,
            disabled = function()
                local unpinnedNow = self.rpDB.profile._unpinnedPreviewFlats
                if not unpinnedNow then return true end
                for _ in pairs(unpinnedNow) do return false end
                return true
            end,
        }

        local order = computeActivePreviewOrder()
        if #order == 0 then
            args._empty = {
                type  = "description",
                order = 1,
                name  = "|cff888888No active preview. Pick a layout in \"Modifying Layout\" or use the dropdown above to add one.|r",
                width = "full",
            }
        else
            for i, flatID in ipairs(order) do
                args["flat_" .. flatID] = buildFlatUnitGroup(flatID, i)
            end
        end

        -- Custom Frame Group preview unit entries. Each CF slot shows if
        -- its Custom Frame Group is enabled AND the user hasn't hidden
        -- this specific preview via its Remove button. The hidden flag
        -- lives in self.rpDB.profile._hiddenCFPreviewSlots[tierKey].
        -- When set, both this config entry AND the preview frame itself
        -- are hidden (see Options_PreviewSystem.lua's CF rendering path).
        for cfSlot = 1, MAX_CF_PREVIEWS do
            local tierKey = "cf" .. cfSlot
            local cfDef = _CF_FAKE_UNIT_DEFAULTS()[cfSlot] or _CF_FAKE_UNIT_DEFAULTS()[1]
            args[tierKey .. "Group"] = {
                type = "group", inline = true, order = 100 + cfSlot,
                name = function()
                    local enabledCFs = BF._preview.EnabledCFGroups()
                    local entry = enabledCFs[cfSlot]
                    if entry then
                        local gName = entry.group.name or ("Group " .. entry.index)
                        return string.format("%sCustom Frame Group: %s|r", CF_PREVIEW_COLOR, gName)
                    end
                    return "Custom Frame " .. cfSlot
                end,
                hidden = function()
                    local enabledCFs = BF._preview.EnabledCFGroups()
                    if not enabledCFs[cfSlot] then return true end
                    local hidden = self.rpDB.profile._hiddenCFPreviewSlots
                    return hidden and hidden[tierKey] == true
                end,
                args = {
                    classSelect = {
                        type = "select", name = "Class", order = 1, width = "normal",
                        values = CLASS_LIST,
                        sorting = CLASS_SORTING,
                        get = function()
                            local ov = self.db.profile.previewUnits and self.db.profile.previewUnits[tierKey]
                            return (ov and ov.class) or cfDef.class
                        end,
                        set = function(_, val)
                            self.db.profile.previewUnits = self.db.profile.previewUnits or {}
                            self.db.profile.previewUnits[tierKey] = self.db.profile.previewUnits[tierKey] or {}
                            self.db.profile.previewUnits[tierKey].class = val
                            if BF.RefreshPreviewFrames then BF:RefreshPreviewFrames() end
                        end,
                    },
                    roleSelect = {
                        type = "select", name = "Role", order = 2, width = "normal",
                        values = ROLE_LIST,
                        sorting = ROLE_SORTING,
                        get = function()
                            local ov = self.db.profile.previewUnits and self.db.profile.previewUnits[tierKey]
                            return (ov and ov.role) or cfDef.role
                        end,
                        set = function(_, val)
                            self.db.profile.previewUnits = self.db.profile.previewUnits or {}
                            self.db.profile.previewUnits[tierKey] = self.db.profile.previewUnits[tierKey] or {}
                            self.db.profile.previewUnits[tierKey].role = val
                            if BF.RefreshPreviewFrames then BF:RefreshPreviewFrames() end
                        end,
                    },
                    healthPct = {
                        type = "range", name = "Health %", order = 3, width = "normal",
                        min = 0, max = 1, step = 0.01, isPercent = true,
                        get = function()
                            local ov = self.db.profile.previewUnits and self.db.profile.previewUnits[tierKey]
                            return (ov and ov.hp) or cfDef.hp
                        end,
                        set = function(_, val)
                            self.db.profile.previewUnits = self.db.profile.previewUnits or {}
                            self.db.profile.previewUnits[tierKey] = self.db.profile.previewUnits[tierKey] or {}
                            self.db.profile.previewUnits[tierKey].hp = val
                            if BF.RefreshPreviewFrames then BF:RefreshPreviewFrames() end
                        end,
                    },
                    remove = {
                        type   = "execute",
                        name   = "Hide this preview",
                        order  = 10,
                        width  = "normal",
                        func   = function()
                            self.rpDB.profile._hiddenCFPreviewSlots = self.rpDB.profile._hiddenCFPreviewSlots or {}
                            self.rpDB.profile._hiddenCFPreviewSlots[tierKey] = true
                            if BF._regeneratePreviewArgs then BF._regeneratePreviewArgs() end
                            if BF.RefreshPreviewFrames then BF:RefreshPreviewFrames() end
                            LibStub("AceConfigRegistry-3.0"):NotifyChange("BuzzardFrames")
                        end,
                    },
                },
            }
        end

        args.resetAll = {
            type = "execute", name = "Reset All to Defaults", order = 999,
            func = function()
                self.rpDB.profile._previewUnitsByFlat    = nil
                self.rpDB.profile._hiddenCFPreviewSlots  = nil
                self.rpDB.profile._unpinnedPreviewFlats  = nil
                self.db.profile.previewUnits             = nil
                if BF.RefreshPreviewFrames then BF:RefreshPreviewFrames() end
            end,
        }
        return args
    end

    -- Mutable subtab so BF._regeneratePreviewArgs can rebuild it in
    -- place whenever the preview set changes (flat create/delete,
    -- editing flat change, add/remove pin).
    local tabPreviewUnits = {
        type  = "group",
        name  = "Preview Units",
        order = 1.25,
        args  = buildPreviewUnitsArgs(),
    }

    -- Exposed so Options_Layouts.lua (flat create/delete) and
    -- Core_AceConfigDialog.lua (Modifying Layout dropdown) can
    -- trigger a regenerate after mutating the active set.
    BF._regeneratePreviewArgs = function()
        tabPreviewUnits.args = buildPreviewUnitsArgs()
    end

    return {
        type        = "group",
        name        = "Preview & Special Options",
        order       = 15,
        childGroups = "tab",
        args        = {
            _sectionTracker = {
                type  = "description",
                name  = function()
                    if self._currentSection ~= "preview" then
                        self._currentSection = "preview"
                        if not InCombatLockdown() then NotifyChangeSafe() end
                    end
                    return ""
                end,
                order = 0,
                width = "full",
            },

            tabPreview = {
                type  = "group",
                name  = "Preview",
                order = 1,
                args  = {
            _sectionTracker = {
                type = "description", order = -1, width = "full",
                name = function()
                    if self._currentSection ~= "preview" then
                        self._currentSection = "preview"
                        if self.RefreshPreviewDummyAuras and not InCombatLockdown() then
                            self:RefreshPreviewDummyAuras()
                        end
                    end
                    return ""
                end,
            },
            previewFramesHeader = {
                type  = "header",
                name  = "Preview Frames",
                order = 0.1,
            },
            showPreview = {
                type   = "toggle",
                name   = "Show Preview",
                desc   = "Show frame size previews to the left of this panel whenever it is open.",
                order  = 0.5,
                get    = function() return self.db.global.showPreview ~= false end,
                set    = function(_, val)
                    self.db.global.showPreview = val
                    if not val then BF:HidePreviewFrames() end
                    NotifyChangeSafe()
                end,
            },
            previewOutOfRange = {
                type   = "toggle",
                name   = "Preview Out of Range",
                desc   = "Simulate out-of-range fade on the preview frames.",
                order  = 0.6,
                hidden = function() return self.db.global.showPreview == false end,
                get    = function() return BF._previewOOR == true end,
                set    = function(_, val)
                    BF._previewOOR = val or nil
                    if BF.RefreshPreviewStatus then BF:RefreshPreviewStatus() end
                end,
            },

            previewLayoutSelect = {
                type   = "select",
                name   = "Layout",
                desc   = "Choose which layout to preview.",
                order  = 1,
                values = layoutValues,
                hidden = function() return self.db.global.showPreview == false or not hasCustomLayouts() end,
                get    = function()
                    local p = self.db.profile
                    local id = BF._previewLayoutID or self._framesActiveLayout or "default"
                    if not _rp_layouts().layouts[id] then id = "default" end
                    return id
                end,
                set    = function(_, val)
                    BF._previewLayoutID = val
                    NotifyChangeSafe()
                end,
            },

            previewStatusGroup = {
                type   = "group",
                name   = "Preview Status",
                inline = true,
                order  = 1.5,
                hidden = function() return self.db.global.showPreview == false end,
                args   = {
                    previewStatusSelect = {
                        type    = "select",
                        name    = "Status Action",
                        order   = 1,
                        values  = {
                            alive   = "Set Alive",
                            dead    = "Kill the Buzzards",
                            offline = "Disconnect the Buzzards",
                            afk     = "Set AFK",
                        },
                        sorting = { "alive", "dead", "offline", "afk" },
                        get = function() return BF._previewStatus or "alive" end,
                        set = function(_, val)
                            BF._previewStatus = (val == "alive") and nil or val
                            if val ~= "dead" then BF._previewResurrect = nil; BF._previewGhost = nil end
                            if BF.RefreshPreviewStatus then BF:RefreshPreviewStatus() end
                        end,
                    },
                    setGhost = {
                        type   = "toggle",
                        name   = "Set Ghost",
                        order  = 2,
                        hidden = function() return (BF._previewStatus or "alive") ~= "dead" end,
                        get    = function() return BF._previewGhost == true end,
                        set    = function(_, val)
                            BF._previewGhost = val or nil
                            if BF.RefreshPreviewStatus then BF:RefreshPreviewStatus() end
                        end,
                    },
                    resurrectBuzzards = {
                        type   = "toggle",
                        name   = "Resurrect the Buzzards",
                        order  = 3,
                        hidden = function() return (BF._previewStatus or "alive") ~= "dead" end,
                        get    = function() return BF._previewResurrect == true end,
                        set    = function(_, val)
                            BF._previewResurrect = val or nil
                            if BF.RefreshPreviewStatus then BF:RefreshPreviewStatus() end
                        end,
                    },
                },
            },

            previewRenderer = {
                type   = "description",
                name   = function()
                    BF:RefreshPreviewFrames()
                    return ""
                end,
                order  = 2,
                width  = "full",
                hidden = function() return self.db.global.showPreview == false end,
            },

            setupModeHeader = {
                type  = "header",
                name  = "Setup Mode",
                order = 2.5,
            },
            setupModeDesc = {
                type  = "description",
                name  = "To view or change the frame positions, toggle Setup Mode using the button in the top left of the options panel, or right-click the Buzzard Frames minimap button. Change the Modifying Layout dropdown to position the frames for non-active Layouts.",
                order = 3,
                width = "full",
            },
            showSetupGrid = {
                type  = "toggle",
                name  = "Show Grid in Setup Mode",
                desc  = "Show a positioning grid overlay while in Setup Mode.",
                order = 10,
                width = "normal",
                get   = function() return self.db.profile.showSetupGrid end,
                set   = function(_, val)
                    self.db.profile.showSetupGrid = val
                    if self.UpdateSetupGrid then self:UpdateSetupGrid() end
                end,
            },
                },  -- end tabPreview.args
            },      -- end tabPreview

            tabPreviewUnits = tabPreviewUnits,


            tabPreviewAuras = {
                type  = "group",
                name  = "Preview Auras",
                order = 1.5,
                args  = {
                    _sectionTracker = {
                        type = "description", order = -1, width = "full",
                        name = function()
                            if self._currentSection ~= "previewAuras" then
                                self._currentSection = "previewAuras"
                                if self.RefreshPreviewDummyAuras and not InCombatLockdown() then
                                    self:RefreshPreviewDummyAuras()
                                end
                            end
                            return ""
                        end,
                    },
                    showPreviewAurasHeader = {
                        type  = "header",
                        name  = "Show Preview Auras",
                        order = 0.1,
                    },
                    showDummyBuffs = {
                        type = "toggle", name = "Preview Buffs", order = 0.2,
                        desc = "Show dummy buff icons on preview frames.",
                        get = function() return BF.db.global.showDummyBuffs ~= false end,
                        set = function(_, val)
                            BF.db.global.showDummyBuffs = val
                            if BF.RefreshPreviewDummyAuras then BF:RefreshPreviewDummyAuras() end
                        end,
                    },
                    showDummyDebuffs = {
                        type = "toggle", name = "Preview Debuffs", order = 0.3,
                        desc = "Show dummy debuff icons on preview frames.",
                        get = function() return BF.db.global.showDummyDebuffs ~= false end,
                        set = function(_, val)
                            BF.db.global.showDummyDebuffs = val
                            if BF.RefreshPreviewDummyAuras then BF:RefreshPreviewDummyAuras() end
                        end,
                    },
                    showDummyPrivateAuras = {
                        type = "toggle", name = "Preview Private Auras", order = 0.4,
                        desc = "Show dummy private aura icons on preview frames.",
                        get = function() return BF.db.global.showDummyPrivateAuras ~= false end,
                        set = function(_, val)
                            BF.db.global.showDummyPrivateAuras = val
                            if BF.RefreshPreviewDummyAuras then BF:RefreshPreviewDummyAuras() end
                        end,
                    },
                    showDummyBigDef = {
                        type = "toggle", name = "Preview Big Defensive", order = 0.5,
                        desc = "Show dummy Big Defensive icons on preview frames.",
                        get = function() return BF.db.global.showDummyBigDef ~= false end,
                        set = function(_, val)
                            BF.db.global.showDummyBigDef = val
                            if BF.RefreshPreviewDummyAuras then BF:RefreshPreviewDummyAuras() end
                        end,
                    },
                    showDummyImportant = {
                        type = "toggle", name = "Preview Important Buffs", order = 0.6,
                        desc = "Show dummy Important buff icons on preview frames.",
                        get = function() return BF.db.global.showDummyImportant ~= false end,
                        set = function(_, val)
                            BF.db.global.showDummyImportant = val
                            if BF.RefreshPreviewDummyAuras then BF:RefreshPreviewDummyAuras() end
                        end,
                    },
                    showDummyCrowdControl = {
                        type = "toggle", name = "Preview Crowd Control", order = 0.7,
                        desc = "Show dummy Crowd Control debuff icons on preview frames.",
                        get = function() return BF.db.global.showDummyCrowdControl ~= false end,
                        set = function(_, val)
                            BF.db.global.showDummyCrowdControl = val
                            if BF.RefreshPreviewDummyAuras then BF:RefreshPreviewDummyAuras() end
                        end,
                    },
                    previewAuraCountHeader = {
                        type  = "header",
                        name  = "Number of Preview Auras",
                        order = 1,
                    },
                    previewBuffCount = {
                        type  = "range",
                        name  = "Buffs",
                        desc  = "Number of dummy buff icons shown on each preview frame.",
                        order = 2,
                        min   = 0, max = 8, step = 1,
                        get   = function() return self.db.profile.previewBuffCount or 4 end,
                        set   = function(_, val)
                            self.db.profile.previewBuffCount = val
                            if BF.RefreshPreviewDummyAuras then BF:RefreshPreviewDummyAuras() end
                        end,
                    },
                    previewDebuffCount = {
                        type  = "range",
                        name  = "Debuffs",
                        desc  = "Number of dummy debuff icons shown on each preview frame.",
                        order = 3,
                        min   = 0, max = 8, step = 1,
                        get   = function() return self.db.profile.previewDebuffCount or 4 end,
                        set   = function(_, val)
                            self.db.profile.previewDebuffCount = val
                            if BF.RefreshPreviewDummyAuras then BF:RefreshPreviewDummyAuras() end
                        end,
                    },
                    previewPrivateAuraCount = {
                        type  = "range",
                        name  = "Private Auras",
                        desc  = "Number of dummy private aura icons shown on each preview frame.",
                        order = 4,
                        min   = 0, max = 5, step = 1,
                        get   = function() return self.db.profile.previewPrivateAuraCount or 2 end,
                        set   = function(_, val)
                            self.db.profile.previewPrivateAuraCount = val
                            if BF.RefreshPreviewDummyAuras then BF:RefreshPreviewDummyAuras() end
                        end,
                    },

                },  -- end tabPreviewAuras.args
            },      -- end tabPreviewAuras

            tabSpecialOptions = {
                type = "group", name = "Special Options", order = 2,
                args = {
                    _sectionTracker = {
                        type = "description", order = -1, width = "full",
                        name = function()
                            if self._currentSection ~= "specialOptions" then
                                self._currentSection = "specialOptions"
                                if self.RefreshPreviewDummyAuras and not InCombatLockdown() then
                                    self:RefreshPreviewDummyAuras()
                                end
                            end
                            return ""
                        end,
                    },
                    experimentalHeader = { type="header", name="Experimental Options", order=0.1 },
                    enableExperimentalOptions = {
                        type="toggle", name="Enable Experimental Options", order=0.2,
                        desc="Enables experimental options that may not be fully tested. Use at your own risk.",
                        get=function() return self.db.profile.enableExperimentalOptions end,
                        set=function(_, val)
                            if InCombatLockdown() then return end
                            self.db.profile.enableExperimentalOptions = val
                            NotifyChangeSafe()
                        end,
                    },
                    buffOrderHeader = { type="header", name="Reverse Buffs", order=1 },
                    reverseBuffs = { type="toggle", name="Reverse Buff Order", order=2, desc="Show buffs in reverse order (most recently applied first)",
                        get=function() return self.db.profile.reverseBuffs end,
                        set=function(_, val)
                            if InCombatLockdown() then return end
                            self.db.profile.reverseBuffs = val
                            -- Profile-wide setting consumed by every flat's
                            -- aura cache; conservatively invalidate all.
                            if self.InvalidateAllFlatAuraCaches then self:InvalidateAllFlatAuraCaches() end
                            self:RefreshAllAuras()
                            if self.RefreshPreviewDummyAuras then self:RefreshPreviewDummyAuras() end
                        end,
                    },
                    autoFitWidthSpacer = { type="description", name="", order=23.5, hidden=function()
                        if not self.db.profile.enableExperimentalOptions then return true end
                        local p = self.db.profile
                        if _rp_layouts().separateRaidBySize then
                            local count = (_rp_layouts().enableRaid40 ~= false and 1 or 0)
                                        + (_rp_layouts().enableRaid30 ~= false and 1 or 0)
                                        + (_rp_layouts().enableRaid20 ~= false and 1 or 0)
                            if count > 1 then return true end
                        end
                        return false
                    end },
                    autoFitWidthHeader = { type="header", name="Raid Frame Fitting", order=23.6, hidden=function()
                        if not self.db.profile.enableExperimentalOptions then return true end
                        local p = self.db.profile
                        if _rp_layouts().separateRaidBySize then
                            local count = (_rp_layouts().enableRaid40 ~= false and 1 or 0)
                                        + (_rp_layouts().enableRaid30 ~= false and 1 or 0)
                                        + (_rp_layouts().enableRaid20 ~= false and 1 or 0)
                            if count > 1 then return true end
                        end
                        return false
                    end },
                    scaleRaidToFit = {
                        type  = "toggle",
                        name  = "Auto set raidframe widths to fit",
                        desc  = "Automatically widens raid frames so all columns fill the same total space as a full 40-man raid. E.g. in a 30-man (6 columns) the frames expand so those 6 columns span the same width that 8 columns would at the base setting. Has no effect in 40-man raids.",
                        order = 23.7,
                        width = "full",
                        hidden = function()
                            if not self.db.profile.enableExperimentalOptions then return true end
                            local p = self.db.profile
                            if _rp_layouts().separateRaidBySize then
                                local count = (_rp_layouts().enableRaid40 ~= false and 1 or 0)
                                            + (_rp_layouts().enableRaid30 ~= false and 1 or 0)
                                            + (_rp_layouts().enableRaid20 ~= false and 1 or 0)
                                if count > 1 then return true end
                            end
                            return false
                        end,
                        get = function() return self.rpDB.profile.layouts.scaleRaidToFit == true end,
                        set = function(_, val)
                            if InCombatLockdown() then return end
                            self.rpDB.profile.layouts.scaleRaidToFit = val
                            self:InvalidateRaidProfileCache()
                            if self.RefreshProfileCache then self:RefreshProfileCache() end
                            self:RebuildHeaders()
                            for frame in pairs(self.activeFrames or {}) do
                                if frame.unit then self:LayoutFrame(frame) end
                            end
                            -- Refresh setup mode if it's active so the flex
                            -- placeholder appears/disappears immediately.
                            if BF.db.global.setupModeActive and self.UpdateSetupFrames then
                                self:UpdateSetupFrames()
                            end
                        end,
                        disabled = InCombatLockdown,
                    },
                    scaleRaidToFitMaxWidth = {
                        type  = "range",
                        name  = "Frame Max Width",
                        desc  = "Cap the fitted width at this value. If the auto-fit formula would produce a wider frame, this limit is used instead.",
                        order = 23.8,
                        min   = 20, max = 150, step = 1,
                        width = "normal",
                        hidden = function()
                            if not self.db.profile.enableExperimentalOptions then return true end
                            if not self.rpDB.profile.layouts.scaleRaidToFit then return true end
                            local p = self.db.profile
                            if _rp_layouts().separateRaidBySize then
                                local count = (_rp_layouts().enableRaid40 ~= false and 1 or 0)
                                            + (_rp_layouts().enableRaid30 ~= false and 1 or 0)
                                            + (_rp_layouts().enableRaid20 ~= false and 1 or 0)
                                if count > 1 then return true end
                            end
                            return false
                        end,
                        get = function() return self.rpDB.profile.layouts.scaleRaidToFitMaxWidth or 80 end,
                        set = function(_, val)
                            if InCombatLockdown() then return end
                            self.rpDB.profile.layouts.scaleRaidToFitMaxWidth = val
                            self:InvalidateRaidProfileCache()
                            if self.RefreshProfileCache then self:RefreshProfileCache() end
                            -- Light path: setup mode resize is cheap (small frame
                            -- count) and runs on every slider tick so the user
                            -- sees immediate feedback while dragging.
                            if BF.db.global.setupModeActive and self.ResizeTestFramesInPlace then
                                self:ResizeTestFramesInPlace()
                            end
                            -- Heavy path: ResizeAllFrames iterates every header
                            -- and child and calls Layout() on each. Debounce so
                            -- it only fires once the user stops dragging.
                            if self._fitMaxWidthTimer then self._fitMaxWidthTimer:Cancel() end
                            self._fitMaxWidthTimer = C_Timer.NewTimer(0.3, function()
                                self._fitMaxWidthTimer = nil
                                if InCombatLockdown() then return end
                                if self.ResizeAllFrames then self:ResizeAllFrames() end
                            end)
                        end,
                        disabled = InCombatLockdown,
                    },
                    -- v27 (§17.13): the old Battleground pvpSwap toggle was
                    -- removed from this tab. The setting now lives in two new
                    -- widgets under Raid/Party Frames → Auras → Private Auras
                    -- subtab: pvpSwapDebuffsPrivateBattleground (raid flats)
                    -- and pvpSwapDebuffsPrivateParty (party frames). The v27
                    -- migration (MigrateAurasToSection) relocates existing
                    -- db.profile.pvpSwapDebuffsPrivate values into the new
                    -- nested storage so users who enabled the toggle
                    -- pre-v27 keep their behaviour.
                    -- Duration-map overlay poll options REMOVED.
                    -- Duration-mapped buff overlays now render via Blizzard's
                    -- native StatusBar:SetTimerDuration (C-side ticking), so
                    -- there is no Lua poll interval to expose.
                },
            },
        },
    }
end