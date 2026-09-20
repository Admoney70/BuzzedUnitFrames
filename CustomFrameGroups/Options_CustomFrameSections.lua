-- ============================================================
-- BuzzardFrames: Options_CustomFrameSections.lua
-- Builds per-section tree entries for Custom Frame Groups:
--   Aura Cooldown Text, Text, Health & Power Bars,
--   Borders & Highlights, Absorbs & Heal Prediction, Icons, Tooltips
--
-- Each section REUSES the shared widget definitions from its
-- corresponding Options_*.lua builder. A proxy `self` routes
-- GetModifyingProfile() and GetSectionProfile() to the selected
-- CFG's flat instead of the RP modifying profile. The full RP
-- widget tree is kept as-is; only root-level RP widgets
-- (_sectionTracker, per-layout copy dropdown) are stripped and
-- replaced with CFG equivalents (group selector, override toggle).
--
-- Inheritance: when override is OFF, the section sub-table is
-- stashed and reads fall through the metatable chain to the
-- base raid flat. When override is ON, the stash is restored
-- (or inherited values are copied on first enable).
-- ============================================================
local BF = _G["BuzzardFrames"]

-- ── Shared helpers ────────────────────────────────────────────
local function getCustomFrames()
    local p = BF.cfgDB and BF.cfgDB.profile
    if not p then return {} end
    if not p.customFrameGroups then p.customFrameGroups = {} end
    return p.customFrameGroups
end

local function RefreshCustomFrames()
    if InCombatLockdown() then return end
    if BF.RefreshCustomFrameHeaders then BF:RefreshCustomFrameHeaders() end
    if BF.UpdateCustomFrameTestFrames then BF:UpdateCustomFrameTestFrames() end
end

-- ============================================================
-- Section definitions: each entry produces one tree tab.
-- ============================================================
local SECTION_DEFS = {
    {
        key        = "auraText",
        name       = "Aura Cooldown Text",
        order      = 4,
        flag       = "overrideAuraText",
        builder    = "BuildAuraTextOptions",
        section    = "auraText",
    },
    {
        key        = "text",
        name       = "Text",
        order      = 5,
        flag       = "overrideText",
        builder    = "BuildTextOptions",
        section    = "text",
    },
    {
        key        = "healthPower",
        name       = "Health & Power Bars",
        order      = 6,
        flag       = "overrideHealthPower",
        builder    = "BuildHealthPowerOptions",
        section    = "healthPower",
    },
    {
        key        = "borders",
        name       = "Borders & Highlights",
        order      = 7,
        flag       = "overrideBorders",
        builder    = "BuildBordersOptions",
        section    = "borders",
    },
    {
        key        = "absorbs",
        name       = "Absorbs & Heal Prediction",
        order      = 8,
        flag       = "overrideAbsorbs",
        builder    = "BuildAbsorbsOptions",
        section    = "absorbs",
    },
    {
        key        = "icons",
        name       = "Icons",
        order      = 9,
        flag       = "overrideIcons",
        builder    = "BuildIconsOptions",
        section    = "icons",
    },
    -- NOTE: The "Cast Bars" section is intentionally NOT built for Custom
    -- Frame Groups (owner decision 2026-08-13). Cast bars are configured
    -- only on the main party/raid options. The data-layer machinery
    -- (overrideCastBar in CFG_OVERRIDABLE_SECTIONS, the RebindCastBarStatus
    -- CFG scan in BFStatus.lua, and the enabled=false seeding when a CFG is
    -- created in Options_CustomFrames.lua) is kept so any pre-existing
    -- dormant CFG castBar data stays inert -- there is simply no options UI
    -- to turn overrideCastBar on. To re-expose the section, restore the
    -- entry that used to sit here:
    --   { key="castBar", name="Cast Bars", order=9.5,
    --     flag="overrideCastBar", builder="BuildCastBarOptions",
    --     section="castBar" }
    {
        key        = "tooltips",
        name       = "Tooltips",
        order      = 10,
        flag       = "overrideTooltips",
        builder    = "BuildTooltipsOptions",
        section    = "tooltips",
    },
}

-- ============================================================
-- BF:BuildCustomFrameSectionOptions(deps)
--
-- Returns a table { key = sectionTree, ... } for injection into
-- the customFrameArgs table in Options_CustomFrames.lua.
-- ============================================================
function BF:BuildCustomFrameSectionOptions(deps)
    local NotifyChangeSafe = deps.NotifyChangeSafe
    local result = {}

    for _, def in ipairs(SECTION_DEFS) do
        -- Per-section selected-group state (session-only)
        local selectedGroup = 1

        local function getIdx()
            local n = #getCustomFrames()
            if selectedGroup > n then selectedGroup = n end
            if selectedGroup < 1 then selectedGroup = 1 end
            return selectedGroup
        end
        local function getCF() return getCustomFrames()[getIdx()] end
        local function noGroups() return #getCustomFrames() == 0 end

        local function isOverride()
            local cf = getCF()
            return cf and cf[def.flag] == true
        end

        -- ── Build a proxy self for the shared builder ─────────────
        -- The proxy intercepts GetModifyingProfile() to return the
        -- CFG's flat, and GetSectionProfile() to route directly to
        -- the CFG flat's section sub-table. All other method calls
        -- fall through to the real BF object.
        -- Refresh helper: invalidate caches and re-layout CFG live +
        -- setup-mode frames so section overrides take effect visually.
        local function RefreshCFGAfterSettingChange()
            -- CFG-scoped refresh: only invalidate CFG flat caches and
            -- re-render CFG frames. Main/RP frame state is never touched.
            local cfgp = BF.cfgDB and BF.cfgDB.profile
            local groups = cfgp and cfgp.customFrameGroups
            if groups then
                for _, grp in ipairs(groups) do
                    local flat = grp and grp.flat
                    if flat then
                        if flat._sectionCache then
                            for k in pairs(flat._sectionCache) do
                                flat._sectionCache[k] = nil
                            end
                        end
                        if flat._auraCache then
                            for k in pairs(flat._auraCache) do
                                flat._auraCache[k] = nil
                            end
                        end
                        -- Mark dirty so UpdateAuraSizeCache rebuilds it.
                        if BF.InvalidateFlatAuraCache then BF:InvalidateFlatAuraCache(flat) end
                    end
                end
            end
            RefreshCustomFrames()
            if BF.RefreshCFGAurasOnly then BF:RefreshCFGAurasOnly() end
            if BF.RefreshPreviewFrames then BF:RefreshPreviewFrames() end
        end

        local proxySelf = setmetatable({}, {
            __index = function(_, k)
                if k == "GetModifyingProfile" then
                    return function()
                        local cf = getCF()
                        return cf and cf.flat
                    end
                end
                if k == "GetSectionProfile" then
                    return function(_, sectionName, flat)
                        -- If flat is nil (e.g. called without args), fall
                        -- back to the CFG's flat.
                        if not flat then
                            local cf = getCF()
                            flat = cf and cf.flat
                        end
                        if not flat then return nil end
                        -- Ensure the section sub-table exists, with metatable
                        -- fallback to global so un-customized keys inherit.
                        if not flat[sectionName] then
                            flat[sectionName] = {}
                            BF:WireSectionFallback(flat, sectionName)
                        end
                        return flat[sectionName]
                    end
                end
                -- CFGs always route to their own flat, so per-layout
                -- is effectively always ON for builders that branch on it
                -- (e.g. AuraText uses IsPerLayoutSection to decide
                -- whether to write to the flat or the global table).
                if k == "IsPerLayoutSection" then
                    return function() return true end
                end
                -- v93: same rule for the PER-SUBTAB test (2026-08-24 split).
                -- BF:WriteSectionKey and BF:SectionKeyTable -- the write router
                -- every shared builder's helper goes through (writeSP in
                -- Options_Borders, writeT in Options_Text, writeIP in
                -- Options_Icons / _HealthPower / _Absorbs) -- gate their
                -- "write to the modifying flat" branch on
                -- IsPerLayoutSectionSubtab, NOT IsPerLayoutSection. That was
                -- not intercepted here, so it read the RP per-Layout toggles:
                -- a CFG setting persisted only when the matching RP subtab
                -- toggle happened to be ON, and otherwise leaked to the global
                -- table while the (proxied) read still came from the CFG flat --
                -- i.e. the widget snapped back. Owner-reported via the CFG
                -- Aggro Border Width slider, which uses writeSP; the three
                -- widgets above it on the same subtab use deps.set (which the
                -- CFG builder supplies directly) and so always worked.
                --
                -- Returning true makes WriteSectionKey take its flat branch and
                -- pick up the CFG flat from the proxied GetModifyingProfile,
                -- which is the same contract as IsPerLayoutSection above.
                -- The RP per-Layout toggle WIDGETS are stripped from the CFG
                -- tree (rootArgs._perLayoutToggle = nil, below), so nothing in
                -- a CFG page can present this as a user-facing choice.
                if k == "IsPerLayoutSectionSubtab" then
                    return function() return true end
                end
                return BF[k]
            end,
        })

        -- ── Call the shared builder ───────────────────────────────
        local builderFn = BF[def.builder]
        local sectionTree
        if builderFn then
            sectionTree = builderFn(proxySelf, {
                self                       = proxySelf,
                NotifyChangeSafe           = NotifyChangeSafe,
                get                        = function(info) -- info-based get
                    local cf = getCF()
                    if not cf or not cf.flat then return nil end
                    local sub = cf.flat[def.section]
                    return sub and sub[info[#info]]
                end,
                set                        = function(info, val) -- info-based set
                    if InCombatLockdown() then return end
                    local cf = getCF()
                    if not cf or not cf.flat then return end
                    if not cf.flat[def.section] then cf.flat[def.section] = {} end
                    cf.flat[def.section][info[#info]] = val
                    -- CFG-scoped: only invalidate CFG caches, never touch main frames.
                    RefreshCFGAfterSettingChange()
                end,
                buildSectionCopyToDropdown = function() return nil end,
            })
        end

        -- ── Wrap every `set` in the tree so CFG frames also refresh ──
        -- Shared builders use custom set handlers that call RP-specific
        -- refresh methods (RefreshColors, RefreshHealthBarLayout, etc.)
        -- which only iterate BF.activeFrames (RP frames). Wrapping
        -- every set ensures CFG live + setup-mode + preview frames are
        -- also refreshed, regardless of what the original setter does.
        if sectionTree then
            local function wrapSets(node)
                if type(node) ~= "table" then return end
                if node.set and type(node.set) == "function" then
                    local origSet = node.set
                    node.set = function(...)
                        origSet(...)
                        RefreshCFGAfterSettingChange()
                    end
                end
                if node.args then
                    for _, child in pairs(node.args) do
                        wrapSets(child)
                    end
                end
            end
            wrapSets(sectionTree)
        end

        if not sectionTree then
            -- Builder not available yet — create a placeholder tab.
            sectionTree = {
                type = "group", name = def.name, order = def.order,
                args = {},
            }
        end

        local rootArgs = sectionTree.args

        -- ── Strip RP-specific root widgets ────────────────────────
        -- Remove _sectionTracker, per-layout toggle, copy dropdown,
        -- and any _perLayoutToggle or _copyToDropdown widgets.
        rootArgs._sectionTracker    = nil
        rootArgs._perLayoutToggle   = nil
        rootArgs._perLayoutDesc     = nil
        rootArgs._copyToDropdown    = nil
        rootArgs.perLayoutToggle    = nil
        rootArgs.sectionCopyTo      = nil

        -- ── CFG section tracker (for preview aura visibility) ────
        local cfgSectionName = "customFrame" .. def.key:sub(1,1):upper() .. def.key:sub(2)
        rootArgs._sectionTracker = {
            type = "description", order = -100, width = "full",
            name = function()
                if BF._currentSection ~= cfgSectionName then
                    BF._currentSection = cfgSectionName
                    if not InCombatLockdown() and BF.RefreshPreviewDummyAuras then
                        BF:RefreshPreviewDummyAuras()
                    end
                end
                return ""
            end,
        }

        -- ── Add CFG-specific widgets ──────────────────────────────
        rootArgs.groupSelect = {
            type = "select", name = "Custom Frame Group",
            order = 0.01, width = "normal",
            values = function()
                local vals = {}
                for i, g in ipairs(getCustomFrames()) do
                    vals[i] = g.name or ("Group " .. i)
                end
                return vals
            end,
            get = function() return getIdx() end,
            set = function(_, val)
                selectedGroup = val
                if NotifyChangeSafe then NotifyChangeSafe() end
            end,
            hidden = noGroups,
        }
        rootArgs.noGroupsDesc = {
            type = "description", order = 0.02, width = "full",
            name = "No custom frame groups exist. Add one first.",
            hidden = function() return #getCustomFrames() > 0 end,
        }

        -- Override toggle: ALWAYS visible once a group exists (v65 §6.3).
        -- It used to be hidden whenever the section was per-Layout, because
        -- the resolvers short-circuited the flag in that state and the
        -- checkbox would have read unchecked while the group demonstrably
        -- used its own data. The flag is authoritative now, so the choice
        -- exists in every state: override ON = the group's own section,
        -- override OFF = follow the active Layout (§6.3a).
        local overrideName = "Override " .. def.name .. " settings for this Custom Frame Group"
        rootArgs["override_" .. def.key] = {
            type = "toggle", name = overrideName,
            order = 0.03, width = "full",
            desc = "When enabled, this custom frame group uses its own "
                .. def.name .. " settings instead of using the global settings.",
            hidden = noGroups,
            get = function() return isOverride() end,
            set = function(_, val)
                if InCombatLockdown() then return end
                local cf = getCF()
                if not cf or not cf.flat then return end
                cf[def.flag] = val
                -- Ensure the section sub-table exists when override is turned ON.
                -- Wire the metatable fallback so un-customized keys inherit
                -- from the global rpDB.profile[section] (sparse storage).
                if val and not rawget(cf.flat, def.section) then
                    local sub = {}
                    -- Cast bars: a freshly materialized CFG castBar section
                    -- always seeds OFF (owner rule 2026-08-13) — without the
                    -- rawkey it would inherit a global enabled=true through
                    -- the fallback the moment the override goes live.
                    if def.section == "castBar" then
                        sub.enabled = false
                    end
                    cf.flat[def.section] = sub
                    BF:WireSectionFallback(cf.flat, def.section)
                end
                -- CFG-scoped: only invalidate CFG caches, never touch main frames.
                RefreshCFGAfterSettingChange()
                if NotifyChangeSafe then NotifyChangeSafe() end
            end,
            disabled = InCombatLockdown,
        }

        -- ── Hide all content when the override is off ──
        -- v65 §6.3: this used to also require the section's per-Layout toggle
        -- to be OFF. The per-Layout dimension no longer participates on the
        -- CFG axis at all: override OFF means the group renders from
        -- somewhere else (the active Layout, §6.3a), so the per-group widgets
        -- here would be editing a table nothing reads.
        local cfgWidgetKeys = {
            groupSelect = true, noGroupsDesc = true,
            ["override_" .. def.key] = true,
        }
        for argKey, arg in pairs(rootArgs) do
            if type(arg) == "table" and not cfgWidgetKeys[argKey] then
                local origHidden = arg.hidden
                arg.hidden = function()
                    if noGroups() then return true end
                    if not isOverride() then return true end
                    if type(origHidden) == "function" then return origHidden() end
                    return origHidden and true or false
                end
            end
        end

        -- ── Override root properties for CFG context ──────────────
        sectionTree.order  = def.order
        sectionTree.name   = def.name
        sectionTree.hidden = function()
            return BF.cfgDB.profile.customFramesEnabled == false
        end

        result[def.key] = sectionTree
    end

    return result
end
