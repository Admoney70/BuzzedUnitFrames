-- ============================================================
-- BuzzardFrames: Options_CustomFrameAuras.lua
-- Builds the "Auras" tree entry for Custom Frame Groups.
--
-- REUSES the shared widget definitions from Options_Auras.lua
-- via BF:BuildAurasOptions(deps). CFG-specific deps closures
-- route reads/writes to grp.flat.auras.<subcat>.<key> for the
-- selected custom frame group. The full RP widget tree is kept
-- as-is so CFGs have the same settings; only the root-level
-- RP widgets (_sectionTracker, preview toggles) are replaced
-- with CFG equivalents (group selector, copy section).
--
-- This means any widget additions/changes in Options_Auras.lua
-- automatically appear in the CFG Auras tab too, with no
-- duplicate maintenance.
-- ============================================================
local BF = _G["BuzzardFrames"]

-- Session-only state
local selectedAurasGroup = 1

local function getCustomFrames()
    local p = BF.cfgDB and BF.cfgDB.profile
    if not p then return {} end
    if not p.customFrameGroups then p.customFrameGroups = {} end
    return p.customFrameGroups
end

local function getCustomFrame(index)
    return getCustomFrames()[index]
end

local function RefreshCustomFrameAuras()
    if InCombatLockdown() then return end
    -- CFG-scoped refresh: only invalidate and re-render custom frame
    -- group state. Main/RP frame caches and icons are never touched,
    -- so a CFG aura setting change (spacing, size, etc.) cannot leak
    -- into party/raid frames.
    --
    -- 1. Wipe only CFG flat caches so PopulateCFGAuraCache reads fresh values.
    --    Mark the flat dirty so UpdateAuraSizeCache rebuilds it (under the
    --    per-flat-on-demand model UpdateAuraSizeCache no longer rebuilds
    --    every CFG cache unconditionally).
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
                if BF.InvalidateFlatAuraCache then BF:InvalidateFlatAuraCache(flat) end
            end
        end
    end
    -- 2. Rebuild aura caches (global cache is re-derived from main profile
    --    so its values won't change; per-CFG caches pick up the new values).
    if BF.RefreshCFGAurasOnly then
        BF:RefreshCFGAurasOnly()
    end
    -- 3. Update CFG test frames and preview dummies.
    if BF.UpdateCustomFrameTestFrames then BF:UpdateCustomFrameTestFrames() end
    if BF.RefreshPreviewDummyAuras then BF:RefreshPreviewDummyAuras() end
end

function BF:BuildCustomFrameAurasOptions(deps)
    local NotifyChangeSafe = deps.NotifyChangeSafe

    local function getIdx()
        local n = #getCustomFrames()
        if selectedAurasGroup > n then selectedAurasGroup = n end
        if selectedAurasGroup < 1 then selectedAurasGroup = 1 end
        return selectedAurasGroup
    end
    local function getCF()  return getCustomFrame(getIdx()) end

    local SUBCAT_OF = BF.AURAS_SUBCATEGORY_OF

    -- ── CFG-specific write helper ──────────────────────────────────
    -- Routes info[#info] through AURAS_SUBCATEGORY_OF, lazily
    -- materializes the sub-category table, then writes the value.
    local function cfgWrite(info, val)
        if InCombatLockdown() then return end
        local cf = getCF()
        if not cf or not cf.flat then return end
        local key = info[#info]
        local subcat = SUBCAT_OF[key]
        if subcat then
            local sub = BF:GetOrCreateAurasSubCategory(cf.flat, subcat)
            if sub then sub[key] = val end
        end
    end

    -- ── Build deps for the shared BuildAurasOptions builder ────────
    -- These closures route all reads/writes to the selected CFG's
    -- flat.auras sub-categories instead of the RP flat/global tables.
    local cfgAuraDeps = {
        self = BF,
        NotifyChangeSafe = NotifyChangeSafe,

        getAurasProfile_shared = function(subcat)
            local cf = getCF()
            if not cf or not cf.flat then return nil end
            local aurasP = cf.flat.auras
            if not subcat then return aurasP end
            return aurasP and aurasP[subcat]
        end,

        getAuras_shared = function(info)
            local key = info[#info]
            local subcat = SUBCAT_OF[key]
            if subcat then
                local cf = getCF()
                if not cf or not cf.flat then return nil end
                local sub = cf.flat.auras and cf.flat.auras[subcat]
                return sub and sub[key]
            end
            return nil
        end,

        -- All three setters use the same write + refresh path for CFGs.
        -- RP distinguishes setAuras / setAurasPrivate / setAurasBigDef
        -- for different refresh granularity, but CFGs just do a full
        -- ReloadCustomFrameHeadersOnly which covers everything.
        setAuras_shared = function(info, val)
            cfgWrite(info, val)
            RefreshCustomFrameAuras()
        end,

        setAurasPrivate_shared = function(info, val)
            cfgWrite(info, val)
            RefreshCustomFrameAuras()
        end,

        setAurasBigDef_shared = function(info, val)
            cfgWrite(info, val)
            RefreshCustomFrameAuras()
        end,

        aurasDisabled_shared = function()
            return InCombatLockdown()
        end,
    }

    -- ── Build the shared aura options tree ─────────────────────────
    local aurasTree = BF:BuildAurasOptions(cfgAuraDeps)
    local rootArgs = aurasTree.args

    -- ── Replace the RP section tracker with CFG equivalent ───────────
    -- The RP version sets _currentSection = "auras"; the CFG version
    -- needs "customFrameAuras" so preview frames show the right context.
    rootArgs._sectionTracker = nil

    -- ── Hide all tabs when no CFG groups exist ─────────────────────
    local function noGroups() return #getCustomFrames() == 0 end

    for _, tabKey in ipairs({"tabBuffs", "tabDebuffs", "tabPrivate",
                             "tabBigDef", "tabImportant", "tabCrowdControl",
                             "tabDispel"}) do
        local tab = rootArgs[tabKey]
        if tab then
            tab.hidden = noGroups
        end
    end

    -- ── Add CFG-specific widgets ───────────────────────────────────
    -- Section tracker (CFG-specific: sets _currentSection for preview)
    rootArgs._sectionTracker = {
        type = "description", order = -100, width = "full",
        name = function()
            if BF._currentSection ~= "customFrameAuras" then
                BF._currentSection = "customFrameAuras"
                if not InCombatLockdown() and BF.RefreshPreviewDummyAuras then
                    BF:RefreshPreviewDummyAuras()
                end
            end
            return ""
        end,
    }

    -- Group selector dropdown
    rootArgs.groupSelect = {
        type = "select", name = "Custom Frame Group", order = -10, width = "normal",
        values = function()
            local vals = {}
            for i, g in ipairs(getCustomFrames()) do
                vals[i] = g.name or ("Group " .. i)
            end
            return vals
        end,
        get = function() return getIdx() end,
        set = function(_, val)
            selectedAurasGroup = val
            if NotifyChangeSafe then NotifyChangeSafe() end
        end,
        hidden = noGroups,
    }
    rootArgs.noGroupsDesc = {
        type = "description", order = -9, width = "full",
        name = "No custom frame groups exist. Add one first.",
        hidden = function() return #getCustomFrames() > 0 end,
    }

    -- ── Override Auras toggle ─────────────────────────────────────
    -- Hidden when per-layout is ON for "auras" (CFGs always use their
    -- own aura data, no override choice needed). Shown when per-layout
    -- is OFF (user chooses: override ON = CFG's own, override OFF = global).
    local function isAurasOverride()
        local cf = getCF()
        return cf and cf.overrideAuras == true
    end

    rootArgs.overrideAuras = {
        type = "toggle", name = "Override Auras settings for this Custom Frame Group",
        order = -8, width = "full",
        desc = "When enabled, this custom frame group uses its own aura settings instead of using the global settings.",
        hidden = function()
            if noGroups() then return true end
            return BF:IsPerLayoutSection("auras")
        end,
        get = function() return isAurasOverride() end,
        set = function(_, val)
            if InCombatLockdown() then return end
            local cf = getCF(); if not cf or not cf.flat then return end
            cf.overrideAuras = val
            -- Ensure auras sub-table exists when override is turned ON.
            -- Wire metatable fallbacks so un-customized keys inherit
            -- from rpDB.profile.auras and its sub-categories.
            if val and not rawget(cf.flat, "auras") then
                cf.flat.auras = {}
                BF:WireSectionFallback(cf.flat, "auras")
                BF:WireAurasSubCategoryFallbacks(cf.flat.auras)
            end
            RefreshCustomFrameAuras()
            if NotifyChangeSafe then NotifyChangeSafe() end
        end,
        disabled = InCombatLockdown,
    }

    -- ── Hide all tabs when override is off AND per-layout is off ──
    -- When per-layout is ON, CFGs always use their own aura data.
    -- When per-layout is OFF and override is OFF, global settings apply.
    for _, tabKey in ipairs({"tabBuffs", "tabDebuffs", "tabPrivate",
                             "tabBigDef", "tabImportant", "tabCrowdControl",
                             "tabDispel"}) do
        local tab = rootArgs[tabKey]
        if tab then
            local origHidden = tab.hidden
            tab.hidden = function()
                if noGroups() then return true end
                if not BF:IsPerLayoutSection("auras") and not isAurasOverride() then
                    return true
                end
                return origHidden and origHidden()
            end
        end
    end

    -- ── Override root properties for CFG context ───────────────────
    aurasTree.order = 3
    aurasTree.hidden = function() return BF.cfgDB.profile.customFramesEnabled == false end

    return aurasTree
end
