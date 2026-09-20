-- ============================================================
-- BuzzardFrames: Options_Profiles.lua
-- Builds and returns the "Profiles" nav-tab args table.
-- Called from Options.lua: BF:BuildProfilesOptions(deps)
--
-- Follows Grid2's profile management pattern:
--   GridProfile.lua      — per-module (Grid2: per-spec) profile dropdown
--   GridExportImport.lua — Serialize + compress + hex encode/decode
--
-- As of dbVersion 18 each of the five modules (Raid/Party Frames, Aura
-- Customizations, Custom Frame Groups, Unit Frames, Incoming Casts) has
-- its own independent top-level AceDB. Each module's profile selection
-- is stored in that DB's own profileKeys[charKey] and switched via the
-- standard AceDB :SetProfile API. The parent DB (BuzzardFramesDB) still
-- exists but only holds cross-cutting db.global state; its profile is
-- not switched from this UI.
-- ============================================================
local BF = _G["BuzzardFrames"]

-- ============================================================
-- IMPORT / EXPORT HELPERS
-- Direct port of Grid2Options/GridExportImport.lua patterns:
-- AceSerializer-3.0 → LibCompress:CompressHuffman → HexEncode
-- ============================================================

-- Plain hexadecimal encoding (Grid2's HexEncode)
local function HexEncode(s, title)
    local hex = { "0","1","2","3","4","5","6","7","8","9","A","B","C","D","E","F" }
    local b_rshift = bit.rshift
    local b_and    = bit.band
    local byte     = string.byte
    local t = { string.format("[=== %s profile ===]", title or "") }
    local j = 0
    for i = 1, #s do
        if j <= 0 then
            t[#t + 1] = "\n"
            j = 32
        end
        j = j - 1
        local b = byte(s, i)
        t[#t + 1] = hex[b_and(b, 15) + 1]
        t[#t + 1] = hex[b_and(b_rshift(b, 4), 15) + 1]
    end
    t[#t + 1] = "\n"
    t[#t + 1] = t[1]
    return table.concat(t)
end

-- Plain hexadecimal decoding (Grid2's HexDecode)
local function HexDecode(s)
    s = s:gsub("%[.-%]", ""):gsub("[^0123456789ABCDEF]", "")
    if #s == 0 or #s % 2 ~= 0 then return false, "Invalid hex string" end
    local b_lshift = bit.lshift
    local byte     = string.byte
    local char     = string.char
    local t = {}
    local i = 1
    repeat
        local bl = byte(s, i)
        bl = bl >= 65 and bl - 55 or bl - 48
        i = i + 1
        local bh = byte(s, i)
        bh = bh >= 65 and bh - 55 or bh - 48
        i = i + 1
        t[#t + 1] = char(b_lshift(bh, 4) + bl)
    until i >= #s
    return table.concat(t)
end

-- Shallow root-key merge (Grid2's MoveTableKeys from GridExportImport.lua).
-- Not a deep copy: only top-level keys are duplicated. The import flow uses
-- this to pour an imported module's section onto a freshly-created namespace
-- profile; sub-tables are shared by reference, which is fine because the
-- serializer already reconstructed fresh tables during deserialization.
local function MoveTableKeys(src, dst)
    if src and dst then
        for k, v in pairs(src) do
            dst[k] = v
        end
    end
end

-- Full decode pipeline (Grid2's UnserializeProfile from GridExportImport.lua,
-- adapted for hex-only use since BF doesn't support addon-channel transfer).
-- Returns (true, decoded_table) on success, (false, error_message) on failure.
local function UnserializeProfile(data)
    local Compressor = LibStub("LibCompress")
    local decoded, err = HexDecode(data)
    if not decoded then
        return false, err or "Hex decode failed"
    end
    local decompressed, decErr = Compressor:DecompressHuffman(decoded)
    if not decompressed then
        return false, "Decompression failed: " .. tostring(decErr or "unknown error")
    end
    local Serializer = LibStub("AceSerializer-3.0")
    local ok, result = Serializer:Deserialize(decompressed)
    if not ok then
        return false, "Deserialization failed: " .. tostring(result or "unknown error")
    end
    return true, result
end

-- Extract the profile name from the `[=== <n> profile ===]` header that
-- HexEncode writes. Returns the trimmed name, or nil if the string is
-- missing / malformed. Verbatim Grid2 ExtractProfileName (GridExportImport.lua).
local function ExtractProfileName(data)
    local header = string.sub(data, 1, 64)
    local name = (header:match("%[(.-)%]") or header):gsub("=", ""):gsub("profile", ""):trim()
    if name ~= "" then
        return name
    end
end

-- ============================================================
-- MODULAR IMPORT STATE (dbVersion 18)
-- ============================================================
-- File-local state for the Import sub-tab. Populated by the Decode button's
-- `func`, consumed by the Import button's `func`, and cleared when the
-- Import finishes or the user clicks Reset. Not persisted — the pasted
-- string and decoded intermediate are transient session state, not config.
local MODULE_KEYS = { "RaidPartyFrames", "AuraCustomizations", "CustomFrameGroups", "UnitFrames", "IncomingCasts" }
local MODULE_LABELS = {
    RaidPartyFrames    = "Raid/Party Frames",
    AuraCustomizations = "Aura Customizations",
    CustomFrameGroups  = "Custom Frame Groups",
    UnitFrames         = "Unit Frames",
    IncomingCasts      = "Incoming Casts",
}
local MODULE_DB_FIELD = {
    RaidPartyFrames    = "rpDB",
    AuraCustomizations = "acDB",
    CustomFrameGroups  = "cfgDB",
    UnitFrames         = "ufDB",
    IncomingCasts      = "icDB",
}
local importState = {
    pasted  = "",    -- editbox contents
    decoded = nil,   -- successful deserialize result (the config table)
    error   = nil,   -- human-readable message on decode failure
    name    = "",    -- user's input for the final profile name
    include = {},    -- MODULE_KEYS subset that will actually import
}

local function ResetImportState()
    importState.pasted  = ""
    importState.decoded = nil
    importState.error   = nil
    importState.name    = ""
    importState.include = {}
end

-- Attempt to decode a pasted modular export string. On success, populates
-- importState.decoded, importState.include (all present modules checked),
-- and importState.name (from the header via ExtractProfileName). On
-- failure, populates importState.error and clears the rest.
-- Only _format == 2 strings are accepted — pre-v17 exports are rejected
-- with a clear message directing the user to re-export.
local function DecodeImportString(data)
    importState.decoded = nil
    importState.error   = nil
    importState.name    = ""
    importState.include = {}

    if type(data) ~= "string" or data:match("^%s*$") then
        importState.error = "Paste an exported profile string above, then click Decode."
        return
    end

    local ok, result = UnserializeProfile(data)
    if not ok then
        importState.error = "Decode failed: " .. tostring(result)
        return
    end
    if type(result) ~= "table" then
        importState.error = "Decode failed: expected a table, got " .. type(result) .. "."
        return
    end
    if result._format ~= 2 then
        importState.error = "This export string is from an older BuzzardFrames version and is no longer supported. Please re-export from the new version."
        return
    end

    -- Pre-check: at least one known module must be present.
    local any = false
    for _, key in ipairs(MODULE_KEYS) do
        if type(result[key]) == "table" then
            any = true
            importState.include[key] = true  -- all present modules checked by default
        end
    end
    if not any then
        importState.error = "Decoded string contains no recognized modules."
        return
    end

    importState.decoded = result
    importState.name    = ExtractProfileName(data) or ""
end

-- Find a name that doesn't collide with any existing profile in any of the
-- selected namespaces. Adapts Grid2's ValidateProfileName pattern from
-- GridExportImport.lua lines 156-171 by checking across N namespaces instead
-- of the single parent DB. The first-available name wins, appending " 2",
-- " 3", etc. until unique across ALL selected namespaces simultaneously.
local function DisambiguateProfileName(baseName, include)
    baseName = (baseName ~= "" and baseName) or (UnitName("player") .. " - " .. GetRealmName())

    local function nameTaken(name)
        for _, key in ipairs(MODULE_KEYS) do
            if include[key] then
                local db = BF[MODULE_DB_FIELD[key]]
                if db then
                    for _, existing in ipairs(db:GetProfiles()) do
                        if existing == name then return true end
                    end
                end
            end
        end
        return false
    end

    local candidate = baseName
    local i = 1
    while nameTaken(candidate) do
        i = i + 1
        candidate = baseName .. " " .. i
    end
    return candidate
end

-- Commit the decoded import into new sub-profile entries in each selected
-- namespace. Follows Grid2's ImportCurrentProfile pattern from
-- GridExportImport.lua (the inner loop that calls MoveTableKeys on each
-- namespace's profile after SetProfile has created/switched it), adapted
-- to run on namespaces directly rather than via parent-profile cascade.
--
-- Namespace SetProfile does NOT cascade up to the parent. Under v18
-- each module DB fires its own OnProfileChanged; callbacks are routed
-- to BF:OnProfileChanged (see Core_DB.lua registration block). We do
-- NOT detach callbacks here because SetProfile(finalName) is followed
-- immediately by MoveTableKeys before any user interaction, so a
-- transient RefreshAll between those two calls is harmless.
--
-- Each module's SetProfile+MoveTableKeys pair is wrapped in pcall so that
-- a failure on one module doesn't block the others. Failures are collected
-- and reported alongside the successes at the end of the loop.
local function ImportDecodedProfile()
    if not importState.decoded then return end

    local baseName = importState.name
    if baseName:match("^%s*$") then
        baseName = ""  -- DisambiguateProfileName will substitute a default
    end
    local finalName = DisambiguateProfileName(baseName, importState.include)

    local importedLabels = {}
    local failedLabels   = {}
    for _, key in ipairs(MODULE_KEYS) do
        if importState.include[key] and type(importState.decoded[key]) == "table" then
            local db = BF[MODULE_DB_FIELD[key]]
            if db then
                local ok, err = pcall(function()
                    db:SetProfile(finalName)
                    MoveTableKeys(importState.decoded[key], db.profile)
                end)
                if ok then
                    importedLabels[#importedLabels + 1] = MODULE_LABELS[key]
                else
                    failedLabels[#failedLabels + 1] = MODULE_LABELS[key] .. " (" .. tostring(err) .. ")"
                end
            end
        end
    end

    -- Merge global colors from the export into rpDB.profile.colors.
    -- When an RP profile is imported, MoveTableKeys already overwrites
    -- rpDB.profile (which includes .colors). This handles the case where
    -- only non-RP modules were selected (e.g. UF-only import) -- the
    -- _globalColors sidecar still carries the exporter's gradient /
    -- class / power colors so they arrive on the recipient's machine.
    local importedColors = importState.decoded._globalColors
    if type(importedColors) == "table" then
        local rpP = BF.rpDB and BF.rpDB.profile
        if rpP then
            if not rpP.colors then rpP.colors = {} end
            for k, v in pairs(importedColors) do
                rpP.colors[k] = v
            end
        end
    end

    -- Legacy backward compat: old exports (pre-independent-flat) bundled
    -- _baseLayouts containing the RP flat each CFG inherited from. Current
    -- exports no longer produce this (each CFG has its own deep-copied flat),
    -- but we still handle it for old export strings.
    local cfgP = BF.cfgDB and BF.cfgDB.profile
    if cfgP and cfgP._baseLayouts then
        local rpLayouts = BF.rpDB and BF.rpDB.profile and BF.rpDB.profile.layouts
        if rpLayouts then
            if not rpLayouts.flatLayouts then rpLayouts.flatLayouts = {} end
            local fl = rpLayouts.flatLayouts
            for flatID, flatData in pairs(cfgP._baseLayouts) do
                if not fl[flatID] then
                    fl[flatID] = flatData
                    local flatName = flatData.name or flatID
                    print("|cffd3ff7dBuzzardFrames:|r Imported base layout \"" .. flatName .. "\" (required by Custom Frame Group)")
                end
            end
        end
        cfgP._baseLayouts = nil  -- clean up; not a real profile key
    end

    -- Wire metatable __index templates on imported flats so un-customized
    -- keys fall through to defaults. Imported profiles land fully-
    -- materialized from the exporter; this makes them sparse-compatible
    -- on next logout, and ensures reads of un-customized keys resolve
    -- correctly if the exporter stripped anything default-equal.
    -- See Core_FlatDefaults.lua.
    if BF.RehydrateFlats then BF:RehydrateFlats() end
    if BF.RehydrateCFGFlats then BF:RehydrateCFGFlats() end

    if #importedLabels > 0 then
        print(string.format(
            "|cffd3ff7dBuzzardFrames:|r Imported as '%s': %s",
            finalName,
            table.concat(importedLabels, ", ")
        ))
    end
    if #failedLabels > 0 then
        print(string.format(
            "|cffff4444BuzzardFrames:|r Import failed for: %s",
            table.concat(failedLabels, ", ")
        ))
    end

    ResetImportState()
end

-- ============================================================
-- MODULAR EXPORT (dbVersion 18)
-- ============================================================
-- Builds a modular config table containing only the modules the user
-- selected, then serializes+compresses+hex-encodes. Matches Grid2's
-- ExportCurrentProfile pattern from GridExportImport.lua:
--   config = { <module_name> = <namespace_profile>, ... }
--   result = HexEncode(Compressor:CompressHuffman(Serializer:Serialize(config)), title)
--
-- The `_format = 2` marker distinguishes modular exports from pre-v17
-- strings. The Import sub-tab will reject anything without this marker.
--
-- `include` is a table keyed by module name (RaidPartyFrames,
-- AuraCustomizations, CustomFrameGroups, UnitFrames, IncomingCasts) with
-- boolean values. Only modules with `include[key] == true` are exported.
--
-- `name` is the header title written into the HexEncode output; the
-- recipient's Import tab reads it via ExtractProfileName to pre-fill the
-- profile-name input. Blank or nil falls back to the parent profile name
-- (which under v18+ is not user-facing, but is still a valid string).
local function ExportModularProfile(include, name)
    local Serializer = LibStub("AceSerializer-3.0")
    local Compressor = LibStub("LibCompress")
    local config = { _format = 2 }
    if include.RaidPartyFrames    then config.RaidPartyFrames    = BF.rpDB.profile  end
    if include.AuraCustomizations then config.AuraCustomizations = BF.acDB.profile  end
    if include.CustomFrameGroups  then
        -- Each CFG group now has its own independent deep-copied flat
        -- (grp.flat) — no base layout reference to bundle. Just export
        -- the cfgDB profile directly; the flat is serialized as part of
        -- each group entry.
        config.CustomFrameGroups = BF.cfgDB.profile
    end
    if include.UnitFrames         then config.UnitFrames         = BF.ufDB.profile  end
    if include.IncomingCasts      then config.IncomingCasts      = BF.icDB.profile  end
    -- Always bundle global colors (health gradient, bg gradient, class
    -- colors, power colors) so they travel with any module export.
    -- Stored as a standalone key; the importer merges it back into
    -- rpDB.profile.colors on the receiving end.
    local colors = BF.rpDB and BF.rpDB.profile and BF.rpDB.profile.colors
    if colors then config._globalColors = colors end
    local compressed = Compressor:CompressHuffman(Serializer:Serialize(config))
    local title
    if name and not name:match("^%s*$") then
        title = name
    else
        title = BF.db:GetCurrentProfile()
    end
    return HexEncode(compressed, title)
end

-- Show an AceGUI frame with a MultiLineEditBox for copy/paste
local function ShowSerializeFrame(title, subtitle, data, onAccept)
    local AceGUI = LibStub("AceGUI-3.0")
    local frame = AceGUI:Create("Frame")
    frame:SetTitle("BuzzardFrames: Profile Import/Export")
    frame:SetStatusText(subtitle)
    frame:SetLayout("Flow")
    frame:SetCallback("OnClose", function(widget) AceGUI:Release(widget) end)
    frame:SetWidth(525)
    frame:SetHeight(375)

    local editbox = AceGUI:Create("MultiLineEditBox")
    editbox.editBox:SetFontObject(GameFontHighlightSmall)
    editbox:SetLabel(title)
    editbox:SetFullWidth(true)
    editbox:SetFullHeight(true)
    frame:AddChild(editbox)

    if data then
        -- Export mode: show data for copying
        editbox:DisableButton(true)
        editbox:SetText(data)
        editbox.editBox:SetFocus()
        editbox.editBox:HighlightText()
        editbox:SetCallback("OnLeave", function(widget)
            widget.editBox:HighlightText()
            widget:SetFocus()
        end)
        editbox:SetCallback("OnEnter", function(widget)
            widget.editBox:HighlightText()
            widget:SetFocus()
        end)
    else
        -- Import mode: accept pasted data
        editbox:DisableButton(false)
        editbox.button:SetScript("OnClick", function()
            frame:Hide()
            if onAccept then onAccept(editbox:GetText()) end
            collectgarbage()
        end)
    end
end

-- ============================================================
-- PROFILE OPTIONS TABLE BUILDER
-- ============================================================
function BF:BuildProfilesOptions(deps)
    local self             = deps.self
    local NotifyChangeSafe = deps.NotifyChangeSafe

    return {
        type        = "group",
        name        = "Profiles",
        order       = 13,
        childGroups = "tab",
        args        = {
            -- ── Tab: General (switch/create/copy/delete) ───────────────
            tabGeneral = {
                type  = "group",
                name  = "General",
                order = 1,
                args  = {
                    desc = {
                        type  = "description",
                        order = 1,
                        name  = "BuzzardFrames Profiles are global, not character-specific. Profiles are now modular, changing the profile for one module does not affect the other modules.\nUse the Profile Management tab to rename, clone, or delete profiles.\n",
                    },
                    moduleHeader = {
                        type  = "header",
                        order = 2,
                        name  = "Module Profiles",
                    },
                    -- Five per-module profile dropdowns. Adapts Grid2's per-spec
                    -- dropdown pattern from GridProfile.lua lines 80-96 (one
                    -- `select` widget per unit of choice, reading/writing the
                    -- current profile name). The unit of choice for Grid2 is a
                    -- spec; for BF it is a module's AceDB. Each module DB has
                    -- its own OnProfileChanged callback registered in Core_DB
                    -- which fires the shared BF:OnProfileChanged refresh
                    -- pipeline, so the `set` handler only needs to call
                    -- SetProfile and nudge the UI to re-read values.
                    module_RaidPartyFrames = {
                        type     = "select",
                        name     = "Raid/Party Frames",
                        desc     = "The profile that Raid/Party Frames uses. Switching takes effect immediately.",
                        order    = 11,
                        width    = "double",
                        values   = function()
                            local current = BF.rpDB and BF.rpDB:GetCurrentProfile() or "Default"
                            local t = {}
                            if BF.rpDB then
                                for _, name in ipairs(BF.rpDB:GetProfiles()) do
                                    if name == current then
                                        t[name] = "|cff76CC4B" .. name .. "|r"
                                    else
                                        t[name] = name
                                    end
                                end
                            end
                            return t
                        end,
                        get      = function()
                            return BF.rpDB and BF.rpDB:GetCurrentProfile() or "Default"
                        end,
                        set      = function(_, val)
                            if InCombatLockdown() then return end
                            BF.rpDB:SetProfile(val)
                            NotifyChangeSafe()
                        end,
                        validate = function()
                            return not InCombatLockdown() or "Profile cannot be changed in combat"
                        end,
                        disabled = InCombatLockdown,
                    },
                    module_AuraCustomizations = {
                        type     = "select",
                        name     = "Aura Customizations",
                        desc     = "The profile that Aura Customizations uses. Switching takes effect immediately.",
                        order    = 12,
                        width    = "double",
                        values   = function()
                            local current = BF.acDB and BF.acDB:GetCurrentProfile() or "Default"
                            local t = {}
                            if BF.acDB then
                                for _, name in ipairs(BF.acDB:GetProfiles()) do
                                    if name == current then
                                        t[name] = "|cff76CC4B" .. name .. "|r"
                                    else
                                        t[name] = name
                                    end
                                end
                            end
                            return t
                        end,
                        get      = function()
                            return BF.acDB and BF.acDB:GetCurrentProfile() or "Default"
                        end,
                        set      = function(_, val)
                            if InCombatLockdown() then return end
                            BF.acDB:SetProfile(val)
                            NotifyChangeSafe()
                        end,
                        validate = function()
                            return not InCombatLockdown() or "Profile cannot be changed in combat"
                        end,
                        disabled = InCombatLockdown,
                    },
                    module_CustomFrameGroups = {
                        type     = "select",
                        name     = "Custom Frame Groups",
                        desc     = "The profile that Custom Frame Groups uses. Switching takes effect immediately.",
                        order    = 13,
                        width    = "double",
                        values   = function()
                            local current = BF.cfgDB and BF.cfgDB:GetCurrentProfile() or "Default"
                            local t = {}
                            if BF.cfgDB then
                                for _, name in ipairs(BF.cfgDB:GetProfiles()) do
                                    if name == current then
                                        t[name] = "|cff76CC4B" .. name .. "|r"
                                    else
                                        t[name] = name
                                    end
                                end
                            end
                            return t
                        end,
                        get      = function()
                            return BF.cfgDB and BF.cfgDB:GetCurrentProfile() or "Default"
                        end,
                        set      = function(_, val)
                            if InCombatLockdown() then return end
                            BF.cfgDB:SetProfile(val)
                            NotifyChangeSafe()
                        end,
                        validate = function()
                            return not InCombatLockdown() or "Profile cannot be changed in combat"
                        end,
                        disabled = InCombatLockdown,
                    },
                    module_UnitFrames = {
                        type     = "select",
                        name     = "Unit Frames",
                        desc     = "The profile that Unit Frames uses. Switching takes effect immediately.",
                        order    = 14,
                        width    = "double",
                        values   = function()
                            local current = BF.ufDB and BF.ufDB:GetCurrentProfile() or "Default"
                            local t = {}
                            if BF.ufDB then
                                for _, name in ipairs(BF.ufDB:GetProfiles()) do
                                    if name == current then
                                        t[name] = "|cff76CC4B" .. name .. "|r"
                                    else
                                        t[name] = name
                                    end
                                end
                            end
                            return t
                        end,
                        get      = function()
                            return BF.ufDB and BF.ufDB:GetCurrentProfile() or "Default"
                        end,
                        set      = function(_, val)
                            if InCombatLockdown() then return end
                            BF.ufDB:SetProfile(val)
                            NotifyChangeSafe()
                        end,
                        validate = function()
                            return not InCombatLockdown() or "Profile cannot be changed in combat"
                        end,
                        disabled = InCombatLockdown,
                    },
                    module_IncomingCasts = {
                        type     = "select",
                        name     = "Incoming Casts",
                        desc     = "The profile that Incoming Casts uses. Switching takes effect immediately.",
                        order    = 15,
                        width    = "double",
                        values   = function()
                            local current = BF.icDB and BF.icDB:GetCurrentProfile() or "Default"
                            local t = {}
                            if BF.icDB then
                                for _, name in ipairs(BF.icDB:GetProfiles()) do
                                    if name == current then
                                        t[name] = "|cff76CC4B" .. name .. "|r"
                                    else
                                        t[name] = name
                                    end
                                end
                            end
                            return t
                        end,
                        get      = function()
                            return BF.icDB and BF.icDB:GetCurrentProfile() or "Default"
                        end,
                        set      = function(_, val)
                            if InCombatLockdown() then return end
                            BF.icDB:SetProfile(val)
                            NotifyChangeSafe()
                        end,
                        validate = function()
                            return not InCombatLockdown() or "Profile cannot be changed in combat"
                        end,
                        disabled = InCombatLockdown,
                    },
                },
            },

            -- ── Tab: Profile Management (rename/delete/clone) ────────────
            tabManage = {
                type  = "group",
                name  = "Profile Management",
                order = 1.5,
                args  = (function()
                    -- Session-only state for the management UI
                    local mgmtModule  = nil   -- selected MODULE_KEYS entry
                    local mgmtProfile = nil   -- selected profile name
                    local mgmtRename  = ""    -- rename input value

                    local function getModuleDB()
                        if not mgmtModule then return nil end
                        return BF[MODULE_DB_FIELD[mgmtModule]]
                    end

                    local function getProfileList()
                        local db = getModuleDB()
                        if not db then return {} end
                        local t = {}
                        for _, name in ipairs(db:GetProfiles()) do
                            t[name] = name
                        end
                        return t
                    end

                    local function isActiveProfile()
                        local db = getModuleDB()
                        return db and mgmtProfile == db:GetCurrentProfile()
                    end

                    return {
                        moduleSelect = {
                            type   = "select",
                            order  = 1,
                            name   = "Module",
                            desc   = "Select which module's profiles to manage.",
                            width  = "double",
                            values = function()
                                local t = {}
                                for _, key in ipairs(MODULE_KEYS) do
                                    t[key] = MODULE_LABELS[key]
                                end
                                return t
                            end,
                            sorting = MODULE_KEYS,
                            get = function() return mgmtModule end,
                            set = function(_, val)
                                mgmtModule  = val
                                mgmtProfile = nil
                                mgmtRename  = ""
                                NotifyChangeSafe()
                            end,
                        },
                        profileSelect = {
                            type   = "select",
                            order  = 2,
                            name   = "Profile",
                            desc   = "Select a profile to manage.",
                            width  = "double",
                            hidden = function() return not mgmtModule end,
                            values = function()
                                local db = getModuleDB()
                                if not db then return {} end
                                local current = db:GetCurrentProfile()
                                local t = {}
                                for _, name in ipairs(db:GetProfiles()) do
                                    if name == current then
                                        t[name] = "|cff76CC4B" .. name .. "|r"
                                    else
                                        t[name] = name
                                    end
                                end
                                return t
                            end,
                            get = function() return mgmtProfile end,
                            set = function(_, val)
                                mgmtProfile = val
                                mgmtRename  = val or ""
                                NotifyChangeSafe()
                            end,
                        },

                        -- ── Actions (shown after both dropdowns are selected) ──
                        actionsHeader = {
                            type   = "header",
                            order  = 10,
                            name   = function()
                                return mgmtProfile and (MODULE_LABELS[mgmtModule] .. " — " .. mgmtProfile) or ""
                            end,
                            hidden = function() return not mgmtProfile end,
                        },

                        -- Rename
                        renameInput = {
                            type   = "input",
                            order  = 11,
                            name   = "Rename",
                            desc   = "Type a new name and press Enter to rename this profile.",
                            width  = "double",
                            hidden = function() return not mgmtProfile end,
                            get    = function() return mgmtRename end,
                            set    = function(_, val)
                                if not val or val:match("^%s*$") then return end
                                local db = getModuleDB()
                                if not db or not mgmtProfile then return end
                                -- Check for name collision
                                for _, existing in ipairs(db:GetProfiles()) do
                                    if existing == val then
                                        print("|cffff4444BuzzardFrames:|r A profile named \"" .. val .. "\" already exists in " .. MODULE_LABELS[mgmtModule] .. ".")
                                        return
                                    end
                                end
                                -- AceDB doesn't have a rename API. Rename = copy data
                                -- to new name, switch if active, delete old.
                                local sv = _G[({
                                    RaidPartyFrames    = "BuzzardFramesRaidPartyFramesDB",
                                    AuraCustomizations = "BuzzardFramesAuraCustomizationsDB",
                                    CustomFrameGroups  = "BuzzardFramesCustomFrameGroupsDB",
                                    UnitFrames         = "BuzzardFramesUnitFramesDB",
                                    IncomingCasts      = "BuzzardFramesIncomingCastsDB",
                                })[mgmtModule]]
                                if not sv or not sv.profiles or not sv.profiles[mgmtProfile] then return end
                                local wasActive = isActiveProfile()
                                sv.profiles[val] = sv.profiles[mgmtProfile]
                                sv.profiles[mgmtProfile] = nil
                                -- Update profileKeys entries that pointed to the old name
                                if sv.profileKeys then
                                    for charKey, profName in pairs(sv.profileKeys) do
                                        if profName == mgmtProfile then
                                            sv.profileKeys[charKey] = val
                                        end
                                    end
                                end
                                if wasActive then
                                    db:SetProfile(val)
                                end
                                print("|cffd3ff7dBuzzardFrames:|r Renamed " .. MODULE_LABELS[mgmtModule] .. " profile \"" .. mgmtProfile .. "\" to \"" .. val .. "\".")
                                mgmtProfile = val
                                mgmtRename  = val
                                NotifyChangeSafe()
                            end,
                        },

                        -- Clone
                        cloneButton = {
                            type    = "execute",
                            order   = 12,
                            name    = "Clone",
                            desc    = "Create a copy of this profile with a new name.",
                            width   = "normal",
                            hidden  = function() return not mgmtProfile end,
                            func    = function()
                                local db = getModuleDB()
                                if not db or not mgmtProfile then return end
                                local sv = _G[({
                                    RaidPartyFrames    = "BuzzardFramesRaidPartyFramesDB",
                                    AuraCustomizations = "BuzzardFramesAuraCustomizationsDB",
                                    CustomFrameGroups  = "BuzzardFramesCustomFrameGroupsDB",
                                    UnitFrames         = "BuzzardFramesUnitFramesDB",
                                    IncomingCasts      = "BuzzardFramesIncomingCastsDB",
                                })[mgmtModule]]
                                if not sv or not sv.profiles or not sv.profiles[mgmtProfile] then return end
                                -- Find a unique name
                                local base = mgmtProfile .. " Copy"
                                local candidate = base
                                local i = 1
                                local taken = {}
                                for _, name in ipairs(db:GetProfiles()) do taken[name] = true end
                                while taken[candidate] do
                                    i = i + 1
                                    candidate = base .. " " .. i
                                end
                                -- Deep copy the profile data
                                sv.profiles[candidate] = BF:DeepCopy(sv.profiles[mgmtProfile])
                                print("|cffd3ff7dBuzzardFrames:|r Cloned " .. MODULE_LABELS[mgmtModule] .. " profile \"" .. mgmtProfile .. "\" as \"" .. candidate .. "\".")
                                mgmtProfile = candidate
                                mgmtRename  = candidate
                                NotifyChangeSafe()
                            end,
                        },

                        -- Delete
                        deleteButton = {
                            type    = "execute",
                            order   = 13,
                            name    = "Delete",
                            desc    = "Permanently delete this profile.",
                            width   = "normal",
                            hidden  = function() return not mgmtProfile end,
                            disabled = function()
                                -- Can't delete the currently active profile or Default
                                return isActiveProfile() or mgmtProfile == "Default"
                            end,
                            confirm = function()
                                return "Permanently delete " .. MODULE_LABELS[mgmtModule] .. " profile \"" .. mgmtProfile .. "\"? This cannot be undone."
                            end,
                            func    = function()
                                local db = getModuleDB()
                                if not db or not mgmtProfile then return end
                                db:DeleteProfile(mgmtProfile, true)
                                print("|cffd3ff7dBuzzardFrames:|r Deleted " .. MODULE_LABELS[mgmtModule] .. " profile \"" .. mgmtProfile .. "\".")
                                mgmtProfile = nil
                                mgmtRename  = ""
                                NotifyChangeSafe()
                            end,
                        },
                        deleteNote = {
                            type   = "description",
                            order  = 14,
                            name   = function()
                                if mgmtProfile == "Default" then
                                    return "|cffaaaaaaThe Default profile cannot be deleted.|r"
                                end
                                return "|cffaaaaaaThe currently active profile cannot be deleted. Switch to a different profile first.|r"
                            end,
                            hidden = function() return not mgmtProfile or (not isActiveProfile() and mgmtProfile ~= "Default") end,
                        },
                    }
                end)(),
            },

            -- ── Tab: Export (dbVersion 17 modular export) ─────────────
            -- Exports the currently-active namespace profiles of the
            -- user-selected modules as a hex-encoded string, marked with
            -- `_format = 2` so the Import tab can reject pre-v17 strings.
            tabExport = {
                type  = "group",
                name  = "Export",
                order = 2,
                args  = {
                    exportDesc = {
                        type  = "description",
                        order = 1,
                        name  = "Export the currently-active profiles of one or more modules as a text string you can share with others. Recipients paste it into the Import tab on their end.\n\nEach module toggle below controls whether that module's active profile is included in the exported string.\n",
                    },
                    exportName = {
                        type  = "input",
                        order = 2,
                        name  = "Export Name",
                        desc  = "This name is embedded in the export string and pre-fills the recipient's Import tab. Leave blank to use the default.",
                        width = "double",
                        get   = function() return self.db.global.exportProfileName or "" end,
                        set   = function(_, val) self.db.global.exportProfileName = val or "" end,
                        validate = function(_, val)
                            -- The header format is "[=== <n> profile ===]" and the
                            -- recipient extracts the name with a %[(.-)%] pattern.
                            -- A user-supplied '[' or ']' would truncate that capture.
                            if type(val) == "string" and (val:find("[", 1, true) or val:find("]", 1, true)) then
                                return "Export name cannot contain '[' or ']' characters."
                            end
                            return true
                        end,
                    },
                    exportButton = {
                        type  = "execute",
                        name  = "Export",
                        desc  = "Export the checked modules' active profiles to a text string you can copy.",
                        order = 3,
                        width = "normal",
                        disabled = function()
                            -- Button is disabled when zero modules are checked.
                            local inc = self.db.global.exportIncludeModules
                            if not inc then return false end  -- default-all-on, not disabled
                            for _, key in ipairs({"RaidPartyFrames","AuraCustomizations","CustomFrameGroups","UnitFrames","IncomingCasts"}) do
                                if inc[key] then return false end
                            end
                            return true
                        end,
                        func  = function()
                            local inc = self.db.global.exportIncludeModules or {
                                RaidPartyFrames    = true,
                                AuraCustomizations = true,
                                CustomFrameGroups  = true,
                                UnitFrames         = true,
                                IncomingCasts      = true,
                            }
                            local data = ExportModularProfile(inc, self.db.global.exportProfileName)
                            ShowSerializeFrame(
                                "Modular profile export (paste into another character's Import tab)",
                                "Press CTRL-C to copy the text to your clipboard",
                                data
                            )
                        end,
                    },
                    includeHeader = {
                        type  = "header",
                        order = 10,
                        name  = "Include Modules",
                    },
                    includeDesc = {
                        type  = "description",
                        order = 11,
                        name  = "Choose which modules' active profiles to include in the exported string.\n",
                    },
                    includeRaidPartyFrames = {
                        type  = "toggle",
                        order = 20,
                        name  = "Raid/Party Frames",
                        desc  = "Include the currently-active Raid/Party Frames profile in the export.",
                        width = "full",
                        get   = function()
                            local inc = self.db.global.exportIncludeModules
                            if not inc then return true end  -- default-all-on
                            return inc.RaidPartyFrames ~= false
                        end,
                        set   = function(_, val)
                            self.db.global.exportIncludeModules = self.db.global.exportIncludeModules or {}
                            self.db.global.exportIncludeModules.RaidPartyFrames = val
                        end,
                    },
                    includeAuraCustomizations = {
                        type  = "toggle",
                        order = 21,
                        name  = "Aura Customizations",
                        desc  = "Include the currently-active Aura Customizations profile in the export.",
                        width = "full",
                        get   = function()
                            local inc = self.db.global.exportIncludeModules
                            if not inc then return true end
                            return inc.AuraCustomizations ~= false
                        end,
                        set   = function(_, val)
                            self.db.global.exportIncludeModules = self.db.global.exportIncludeModules or {}
                            self.db.global.exportIncludeModules.AuraCustomizations = val
                        end,
                    },
                    includeCustomFrameGroups = {
                        type  = "toggle",
                        order = 22,
                        name  = "Custom Frame Groups",
                        desc  = "Include the currently-active Custom Frame Groups profile in the export.",
                        width = "full",
                        get   = function()
                            local inc = self.db.global.exportIncludeModules
                            if not inc then return true end
                            return inc.CustomFrameGroups ~= false
                        end,
                        set   = function(_, val)
                            self.db.global.exportIncludeModules = self.db.global.exportIncludeModules or {}
                            self.db.global.exportIncludeModules.CustomFrameGroups = val
                        end,
                    },
                    includeUnitFrames = {
                        type  = "toggle",
                        order = 23,
                        name  = "Unit Frames",
                        desc  = "Include the currently-active Unit Frames profile in the export.",
                        width = "full",
                        get   = function()
                            local inc = self.db.global.exportIncludeModules
                            if not inc then return true end
                            return inc.UnitFrames ~= false
                        end,
                        set   = function(_, val)
                            self.db.global.exportIncludeModules = self.db.global.exportIncludeModules or {}
                            self.db.global.exportIncludeModules.UnitFrames = val
                        end,
                    },
                    includeIncomingCasts = {
                        type  = "toggle",
                        order = 24,
                        name  = "Incoming Casts",
                        desc  = "Include the currently-active Incoming Casts profile in the export.",
                        width = "full",
                        get   = function()
                            local inc = self.db.global.exportIncludeModules
                            if not inc then return true end
                            return inc.IncomingCasts ~= false
                        end,
                        set   = function(_, val)
                            self.db.global.exportIncludeModules = self.db.global.exportIncludeModules or {}
                            self.db.global.exportIncludeModules.IncomingCasts = val
                        end,
                    },
                },
            },

            -- ── Tab: Import (dbVersion 17 modular import) ─────────────
            -- Accepts a pasted `_format = 2` modular export string, lets
            -- the user pick which modules to import and a profile name,
            -- then writes a new namespace profile entry per selected
            -- module. Non-destructive: existing profiles are untouched.
            --
            -- Flow (plan §5):
            --   1. Paste hex-encoded string into the editbox.
            --   2. Click Decode. On failure, an error description appears.
            --   3. On success, per-module checkboxes + name input + Import
            --      button appear (all modules checked by default, name
            --      pre-filled from the string's header).
            --   4. Click Import. Each selected module gets a new namespace
            --      profile entry under a disambiguated name.
            --
            -- All widgets below the editbox read file-local `importState`
            -- rather than SavedVariables because the pasted string and
            -- decoded intermediate are session-transient.
            tabImport = {
                type  = "group",
                name  = "Import",
                order = 3,
                args  = {
                    importDesc = {
                        type  = "description",
                        order = 1,
                        name  = "Paste an exported profile string below and click Accept. The profile information will be decoded. You can then select which modules to import and rename the profile, then click Import.\n\nImporting creates new profiles for the selected modules. Your current profile settings will not be overwritten.\n",
                    },
                    pasteBox = {
                        type       = "input",
                        order      = 2,
                        name       = "Paste Export String",
                        desc       = "Paste the full exported string here and click Accept. The string will be decoded automatically.",
                        width      = "full",
                        multiline  = 10,
                        get        = function() return importState.pasted end,
                        set        = function(_, val)
                            importState.pasted = val or ""
                            -- Auto-decode on Accept so the user doesn't need
                            -- to click a separate Decode button.
                            DecodeImportString(importState.pasted)
                            NotifyChangeSafe()
                        end,
                    },
                    resetButton = {
                        type   = "execute",
                        order  = 4,
                        name   = "Reset",
                        desc   = "Clear the pasted string, decoded contents, and name input.",
                        width  = "normal",
                        hidden = function() return not (importState.decoded or importState.error) end,
                        func   = function()
                            ResetImportState()
                            NotifyChangeSafe()
                        end,
                    },

                    -- Error message (shown on decode failure)
                    errorHeader = {
                        type   = "header",
                        order  = 10,
                        name   = "Error",
                        hidden = function() return not importState.error end,
                    },
                    errorText = {
                        type   = "description",
                        order  = 11,
                        name   = function() return "|cffff4444" .. (importState.error or "") .. "|r" end,
                        hidden = function() return not importState.error end,
                    },

                    -- Post-decode section (shown on successful decode)
                    containsHeader = {
                        type   = "header",
                        order  = 20,
                        name   = "This string contains",
                        hidden = function() return not importState.decoded end,
                    },
                    containsDesc = {
                        type   = "description",
                        order  = 21,
                        name   = "Uncheck any modules you don't want to import.\n",
                        hidden = function() return not importState.decoded end,
                    },
                    includeRaidPartyFrames = {
                        type   = "toggle",
                        order  = 30,
                        name   = "Raid/Party Frames",
                        width  = "full",
                        hidden = function()
                            return not importState.decoded or type(importState.decoded.RaidPartyFrames) ~= "table"
                        end,
                        get    = function() return importState.include.RaidPartyFrames == true end,
                        set    = function(_, val) importState.include.RaidPartyFrames = val end,
                    },
                    includeAuraCustomizations = {
                        type   = "toggle",
                        order  = 31,
                        name   = "Aura Customizations",
                        width  = "full",
                        hidden = function()
                            return not importState.decoded or type(importState.decoded.AuraCustomizations) ~= "table"
                        end,
                        get    = function() return importState.include.AuraCustomizations == true end,
                        set    = function(_, val) importState.include.AuraCustomizations = val end,
                    },
                    includeCustomFrameGroups = {
                        type   = "toggle",
                        order  = 32,
                        name   = "Custom Frame Groups",
                        width  = "full",
                        hidden = function()
                            return not importState.decoded or type(importState.decoded.CustomFrameGroups) ~= "table"
                        end,
                        get    = function() return importState.include.CustomFrameGroups == true end,
                        set    = function(_, val) importState.include.CustomFrameGroups = val end,
                    },
                    includeUnitFrames = {
                        type   = "toggle",
                        order  = 33,
                        name   = "Unit Frames",
                        width  = "full",
                        hidden = function()
                            return not importState.decoded or type(importState.decoded.UnitFrames) ~= "table"
                        end,
                        get    = function() return importState.include.UnitFrames == true end,
                        set    = function(_, val) importState.include.UnitFrames = val end,
                    },
                    includeIncomingCasts = {
                        type   = "toggle",
                        order  = 34,
                        name   = "Incoming Casts",
                        width  = "full",
                        hidden = function()
                            return not importState.decoded or type(importState.decoded.IncomingCasts) ~= "table"
                        end,
                        get    = function() return importState.include.IncomingCasts == true end,
                        set    = function(_, val) importState.include.IncomingCasts = val end,
                    },

                    -- Name input + Import button (shown on successful decode)
                    nameHeader = {
                        type   = "header",
                        order  = 40,
                        name   = "Import as profile name",
                        hidden = function() return not importState.decoded end,
                    },
                    nameInput = {
                        type   = "input",
                        order  = 41,
                        name   = "Profile Name",
                        desc   = "The name that each selected module's imported data will be saved as. If this name already exists in any selected module, a numeric suffix will be appended automatically.",
                        width  = "double",
                        hidden = function() return not importState.decoded end,
                        get    = function() return importState.name end,
                        set    = function(_, val) importState.name = val or "" end,
                    },
                    importButton = {
                        type   = "execute",
                        order  = 42,
                        name   = "Import",
                        desc   = "Create a new profile in each selected module with the imported data.",
                        width  = "normal",
                        hidden = function() return not importState.decoded end,
                        disabled = function()
                            if not importState.decoded then return true end
                            if importState.name:match("^%s*$") then return true end
                            for _, key in ipairs(MODULE_KEYS) do
                                if importState.include[key] then return false end
                            end
                            return true
                        end,
                        func   = function()
                            ImportDecodedProfile()
                            NotifyChangeSafe()
                        end,
                    },
                },
            },
        },
    }
end
