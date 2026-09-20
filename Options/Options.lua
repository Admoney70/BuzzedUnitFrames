-- ============================================================
-- BuzzardFrames: Options.lua
-- AceConfig options table registration (RegisterOptions).
-- Depends on: Defaults.lua (BF:CreateRaidProfile, BF:CreatePartyProfile, BF:DeepCopy, BF.specData)
--             Core.lua (BF:RefreshAll, BF:ApplyRoleSpecLayout, etc.)
-- ============================================================
local BF = _G["BuzzardFrames"]

-- ============================================================
-- POSITION SLIDER HELPER
-- Computes half-screen dimensions once and applies them to all
-- X/Y position sliders so they share identical ranges.
-- ============================================================
local _posHalfW, _posHalfH
function BF:InitPositionSliderBounds()
    -- Called live, not cached, because GetScreenWidth/Height
    -- may return incorrect values early at login before the
    -- UI is fully laid out.
    _posHalfW = math.floor(GetScreenWidth() / 2)
    _posHalfH = math.floor(GetScreenHeight() / 2)
end

function BF:GetPositionHalfW()
    self:InitPositionSliderBounds()
    return _posHalfW
end

function BF:GetPositionHalfH()
    self:InitPositionSliderBounds()
    return _posHalfH
end

-- Called from slider get() to update softMin/softMax live.
function BF:ClampPositionSlider(info, axis)
    self:InitPositionSliderBounds()
    if axis == "x" then
        info.option.softMin = -_posHalfW
        info.option.softMax = _posHalfW
    else
        info.option.softMin = -_posHalfH
        info.option.softMax = _posHalfH
    end
end

-- Font preview in dropdowns is handled by the LSM30_Font widget
-- (AceGUI-3.0-SharedMediaWidgets) via dialogControl = "LSM30_Font"
-- on each font select in the AceConfig tables.

-- ============================================================
-- LSM30 WIDGET CLICK-ANYWHERE FIX
-- The stock LSM30 widgets only open the dropdown when the small
-- arrow button is clicked.  Hook AceGUI:Create so every LSM30
-- widget frame also responds to clicks on the text/background.
-- ============================================================
do
    local AceGUI = LibStub("AceGUI-3.0", true)
    if AceGUI then
        local LSM_TYPES = { LSM30_Font=true, LSM30_Statusbar=true, LSM30_Border=true, LSM30_Background=true, LSM30_Sound=true }
        local origCreate = AceGUI.Create
        AceGUI.Create = function(self, widgetType, ...)
            local widget = origCreate(self, widgetType, ...)
            if widget and LSM_TYPES[widgetType] and not widget._BF_clickHooked then
                widget._BF_clickHooked = true
                local frame = widget.frame
                if frame and widget.ToggleDrop then
                    frame:EnableMouse(true)
                    frame:SetScript("OnMouseDown", function(f)
                        if not widget.disabled then
                            widget.ToggleDrop(frame)
                        end
                    end)
                end
            end
            return widget
        end
    end
end

-- ============================================================
-- UPDATE OPTIONS STATUS TEXT
-- Updates the Active/Modifying labels in the options panel status
-- bar directly. Called from GroupTypeChanged so it updates
-- immediately on group type change, independent of widget rendering.
-- ============================================================
function BF:UpdateOptionsStatusText()
    local ACD = LibStub("AceConfigDialog-3.0", true)
    local aceFrame = ACD and ACD.OpenFrames and ACD.OpenFrames["BuzzardFrames"]
    if not aceFrame then return end
    local lp = self.rpDB and self.rpDB.profile and self.rpDB.profile.layouts or {}
    local fl = lp.flatLayouts or {}
    local slot = self:GetActiveSlot()
    local activeID = self:ResolveActiveFlat(slot)
    local activeName = (activeID and activeID ~= "none" and fl[activeID] and fl[activeID].name) or "\226\128\148"
    local context = (self.SLOT_LABELS and self.SLOT_LABELS[slot]) or slot or "?"
    local modFlat     = self._modifyingFlat
    local modFlatName = (modFlat and fl[modFlat] and fl[modFlat].name) or "\226\128\148"
    local labelColor = (activeID and activeID == modFlat) and "|cff76CC4B" or "|cff11ace9"
    aceFrame:SetStatusText(labelColor .. "Active:|r |cffffffff" .. activeName .. " |cff87ceeb[Instance Type: " .. context .. "]|r    " .. labelColor .. "Modifying:|r |cffffffff" .. modFlatName .. "|r")
end

function BF:RegisterOptions()
    self:InitPositionSliderBounds()
    local db  = self.db.profile
    local function getLpp() return self.rpDB and self.rpDB.profile and self.rpDB.profile.layouts or {} end
    local AC  = LibStub("AceConfig-3.0")
    local ACD = LibStub("AceConfigDialog-3.0")

    -- Before calling NotifyChange (which triggers AceConfigDialog:Open → ApplyStatus →
    -- ClearAllPoints), snapshot the panel's current pixel position into the ACD status
    -- table so ApplyStatus restores it to exactly where it is right now.
    -- Without this, switching tabs calls NotifyChange while the frame is mid-render
    -- and GetTop()/GetLeft() return stale values, causing the panel to jump.
    -- Optional nav path to select on the next NotifyChange, set via BF:SetPendingNavPath()
    -- Format: { "topLevelKey", "tabKey", "subTabKey", ... }
    -- NotifyChangeSafe writes this into the status table then clears it.
    local pendingNavPath = nil
    local _optionsRef = nil  -- set after options table is built; used by nav path logic
    function BF:SetPendingNavPath(...)
        pendingNavPath = { ... }
    end

    local function NotifyChangeSafe()
        local f = ACD.OpenFrames and ACD.OpenFrames["BuzzardFrames"]
        if f and f.frame then
            local status = ACD:GetStatusTable("BuzzardFrames")
            local top  = f.frame:GetTop()
            local left = f.frame:GetLeft()
            if top  then status.top  = top  end
            if left then status.left = left end
            -- Restore saved size into the status table so ApplyStatus
            -- (triggered by NotifyChange) uses the user's size, not defaults.
            if self.db.global._optionsPanelW then
                status.width  = self.db.global._optionsPanelW
            end
            if self.db.global._optionsPanelH then
                status.height = self.db.global._optionsPanelH
            end
        end
        -- If a pending nav path was requested, write it into the status table
        -- so FeedGroup restores the correct tab selection during the rebuild.
        -- Apply nav path on every rebuild until the correct tab is confirmed selected.
        -- A second spurious rebuild (from test-mode trackers etc.) would otherwise
        -- clobber the selection, so we keep applying until the status agrees.
        local navPath = pendingNavPath
        if navPath then
            pendingNavPath = nil
            local status = ACD:GetStatusTable("BuzzardFrames")
            if not status.groups then status.groups = {} end
            -- Determine if the first path element is a top-level options key
            -- (e.g. "customAuras", "customFrames") or a sub-tab of raidPartyFrames.
            local isTopLevel = _optionsRef and _optionsRef.args[navPath[1]]
                               and navPath[1] ~= "raidPartyFrames"
            if isTopLevel then
                -- Top-level entry: select it directly at root level
                status.groups.selected = navPath[1]
                local walked = {}
                for i = 1, #navPath do
                    local st = ACD:GetStatusTable("BuzzardFrames", walked)
                    if not st.groups then st.groups = {} end
                    st.groups.selected = navPath[i]
                    table.insert(walked, navPath[i])
                end
            else
                -- Sub-tab of raidPartyFrames: prefix with raidPartyFrames
                local treeKey = "raidPartyFrames\001" .. navPath[1]
                status.groups.selected = treeKey
                if not status.groups.groups then status.groups.groups = {} end
                status.groups.groups[treeKey] = true
                local walked = { "raidPartyFrames" }
                for i = 1, #navPath do
                    local st = ACD:GetStatusTable("BuzzardFrames", walked)
                    if not st.groups then st.groups = {} end
                    st.groups.selected = navPath[i]
                    table.insert(walked, navPath[i])
                end
            end
        end
        LibStub("AceConfigRegistry-3.0"):NotifyChange("BuzzardFrames")
    end

    -- Stash NotifyChangeSafe on BF so BF:OnProfileChanged (which lives in
    -- Core_ProfileLifecycle.lua and has no access to this local) can call
    -- it after rebuilding the dynamic Custom Frame Groups / Aura
    -- Customizations args tables on a profile switch. Snapshotting the
    -- panel position and size before NotifyChange happens inside this
    -- closure, so the profile switch mustn't bypass it by calling
    -- AceConfigRegistry:NotifyChange directly.
    BF._notifyChangeSafe = NotifyChangeSafe

    -- Snapshot the options panel position into every location that AceConfigDialog
    -- and our own restore logic use, so any NotifyChange/rebuild triggered by the
    -- following operation restores the panel to exactly where it is right now.
    -- Call this at the start of any options func that changes panel state (e.g.
    -- entering/exiting Setup Mode) to prevent the panel from jumping.
    local function SnapshotPanelPosition()
        local f = ACD.OpenFrames and ACD.OpenFrames["BuzzardFrames"]
        if not f or not f.frame then return end
        local frame = f.frame
        -- 1. Update AceConfigDialog's own status table (used by ApplyStatus)
        local status = ACD:GetStatusTable("BuzzardFrames")
        local top  = frame:GetTop()
        local left = frame:GetLeft()
        if top  then status.top  = top  end
        if left then status.left = left end
        -- Restore saved size into the status table
        if self.db.global._optionsPanelW then
            status.width  = self.db.global._optionsPanelW
        end
        if self.db.global._optionsPanelH then
            status.height = self.db.global._optionsPanelH
        end
        -- 2. Update our own center-based restore coordinates (used by SetupOptionsPanel)
        local x, y   = frame:GetCenter()
        local ux, uy = UIParent:GetWidth() / 2, UIParent:GetHeight() / 2
        if x and y then
            self._optionsPanelSavedX = x - ux
            self._optionsPanelSavedY = y - uy
        end
    end

    local function get(info)
        return self.db.profile[info[#info]]
    end
    -- Write-only: just saves the value. Use this via deps.set in sub-files
    -- or anywhere RefreshAll is not needed (e.g. settings read live at runtime).
    local function set(info, val)
        if InCombatLockdown() then return end
        self.db.profile[info[#info]] = val
    end
    -- Write + full refresh. Use set=setRefresh for layout/geometry settings
    -- that require a full frame rebuild to take effect.
    local function setRefresh(info, val)
        if InCombatLockdown() then return end
        self.db.profile[info[#info]] = val
        self:RefreshAll()
    end
    local function setReload(info, val)
        if InCombatLockdown() then return end
        self.db.profile[info[#info]] = val
        StaticPopup_Show("BUZZARDFRAMES_RELOAD")
    end
    
    -- Helper to safely call RefreshAll from tainted context
    local function safeLayout()
        C_Timer.After(0, function()
            if not InCombatLockdown() then
                self:RefreshAll()
            end
        end)
    end
    
    -- Tier-specific get/set functions
    -- Each accessor accepts `tier` as either a string key into db.profile,
    -- or a function() that returns the sub-table directly (for layout dispatch).
    local function resolveTier(tier)
        if type(tier) == "function" then return tier() end
        return self.db.profile[tier]
    end

    local function getTier(tier)
        return function(info)
            local key = info[#info]
            return resolveTier(tier)[key]
        end
    end
    
    local function setTier(tier)
        return function(info, val)
            if InCombatLockdown() then return end
            local key = info[#info]
            resolveTier(tier)[key] = val
            self:RefreshAll()
        end
    end
    
    local function setTierSpacing(tier)
        return function(info, val)
            if InCombatLockdown() then return end
            local key = info[#info]
            resolveTier(tier)[key] = val
            -- Only reposition existing frames - no need to rebuild from scratch
            if self.ResizeTestFramesInPlace then
                self:ResizeTestFramesInPlace()
            end
            if self.PositionTestResizeHandle and self.testHeader then
                self:PositionTestResizeHandle(self.testHeader, false)
            end
            if self.UpdateFrameSpacing then
                self:UpdateFrameSpacing()
            end
        end
    end

    local function setTierResize(tier)
        return function(info, val)
            if InCombatLockdown() then return end
            local key = info[#info]
            resolveTier(tier)[key] = val
            if self.ResizeAllFrames then
                self:ResizeAllFrames()
            end
            if self.UpdateTestFrames then
                self:UpdateTestFrames()
            end
            if self.RefreshPreviewDummyAuras then self:RefreshPreviewDummyAuras() end
        end
    end
    
    -- (Removed: setTierReload. Was a local helper factory that special-cased
    -- hideBlizzardRaid/hideBlizzardParty for live-hiding but was never wired
    -- to any widget. The real Hide Blizzard toggles live under
    -- raidPartyFrames in this file and go through their own inline setters.)
    
    local function setTierAuras(tier)
        return function(info, val)
            if InCombatLockdown() then return end
            local key = info[#info]
            resolveTier(tier)[key] = val
            self:RefreshAllAuras()
            if self.RefreshPreviewDummyAuras then self:RefreshPreviewDummyAuras() end
        end
    end
    
    local function setTierBigDef(tier)
        return function(info, val)
            if InCombatLockdown() then return end
            local key = info[#info]
            resolveTier(tier)[key] = val
            self:RefreshBigDef()
            if self.RefreshPreviewDummyAuras then self:RefreshPreviewDummyAuras() end
        end
    end
    
    local function getGroupTier(tier)
        return function(info)
            local i = tonumber(info[#info]:match("%d+"))
            return resolveTier(tier).showGroup[i]
        end
    end
    
    local function setGroupTier(tier)
        return function(info, val)
            if InCombatLockdown() then return end
            local i = tonumber(info[#info]:match("%d+"))
            resolveTier(tier).showGroup[i] = val
            -- Targeted rebuild: invalidate caches and reload layout so the
            -- showGroup filter is re-applied to headers. Do NOT call RefreshAll
            -- which runs ApplyProfile and can change the active group type context.
            self:InvalidateRaidProfileCache()
            if self.ReloadLayout then self:ReloadLayout(true) end
        end
    end
    
    -- DELETED (Setup Mode migration): createPartyOptions and createTierOptions
    -- were local helpers for an older tier-based tab layout. They were never
    -- called in the current flat-layout model. createTierOptions also contained
    -- a `pBF.db.global[...]` typo that would have errored on invocation.
    -- The equivalent functionality now lives in BF:BuildFramesOptions
    -- (Options_Frames.lua) and BF:BuildLayoutsOptions (Options_Layouts.lua).

    -- Generate a unique layout ID
    local function newLayoutID()
        local p = self.db.profile
            local lpp = getLpp()
        local i = 1
        repeat
            local id = "layout_" .. i
            if not lpp.layouts[id] then return id end
            i = i + 1
        until false
    end

    -- Build the layouts dropdown values table (id -> display name)
    local function layoutValues()
        local p = self.db.profile
            local lpp = getLpp()
        local activeID = lpp.activeLayout or BF._framesActiveLayout or "default"
        local t = {}
        for id, layout in pairs(lpp.layouts) do
            if id == activeID then
                t[id] = "|cff76CC4B" .. layout.name .. "|r"
            else
                t[id] = layout.name
            end
        end
        return t
    end

    -- Build the flatLayouts dropdown values table (id -> display name).
    -- Used by the top-of-subtab "Modify Layout" dropdown at the
    -- raidPartyFrames parent level. Orders seeded flats first (flat_party,
    -- flat_raid20/30/40) then user flats alphabetically by id.
    local function flatLayoutValues()
        local lpp = getLpp()
        local fl = lpp.flatLayouts or {}
        local t  = {}
        for id, layout in pairs(fl) do
            t[id] = layout.name or id
        end
        return t
    end
    local function flatLayoutSorting()
        local lpp = getLpp()
        local fl = lpp.flatLayouts or {}
        local preferred = { "flat_party", "flat_raid20", "flat_raid30", "flat_raid40" }
        local keys = {}
        local seen = {}
        for _, id in ipairs(preferred) do
            if fl[id] then keys[#keys + 1] = id; seen[id] = true end
        end
        local extras = {}
        for id in pairs(fl) do
            if not seen[id] then extras[#extras + 1] = id end
        end
        table.sort(extras)
        for _, id in ipairs(extras) do keys[#keys + 1] = id end
        return keys
    end

    -- Ensure a layout has all required sub-tables (migration safety).
    -- Tiers that already exist get their Initialized flag stamped so InitRaidTier
    -- knows they are a valid donor.  Missing tiers are created via InitRaidTier so
    -- they inherit from the nearest existing tier rather than bare defaults.
    --
    -- CRITICAL: This function was written for the OLD-style layout container
    -- (which has party/raid40/raid30/raid20 sub-tables). Under the flat model
    -- a flat has NO tier sub-tables -- it IS the single config. Calling this
    -- on a flat would materialize spurious party/raid* sub-tables full of
    -- default data on the flat, bloating SavedVariables and defeating the
    -- sparse-storage design (Core_FlatDefaults.lua).
    --
    -- Detect flats via their `type` field (set to "party" or "raid" by
    -- WireFlatDefaults / the v19/v20 migrations) and no-op on them. Old
    -- layout containers have no `type` field so they still flow through
    -- the original code path below.
    local function ensureLayout(layout)
        if type(layout) ~= "table" then return end
        if layout.type == "party" or layout.type == "raid" then
            -- Flat -- nothing to do. The metatable __index fallback wired by
            -- BF:WireFlatDefaults (Core_FlatDefaults.lua) supplies any
            -- missing keys transparently.
            return
        end
        local lpp = getLpp()
        local id
        for k, v in pairs(lpp.layouts) do
            if v == layout then id = k; break end
        end
        if not layout.party then layout.party = self:CreatePartyProfile() end
        -- Stamp existing tiers first so InitRaidTier can use them as donors
        if layout.raid40 then layout.raid40Initialized = true end
        if layout.raid30 then layout.raid30Initialized = true end
        if layout.raid20 then layout.raid20Initialized = true end
        -- Create any missing tiers, inheriting from the nearest initialized tier
        if not layout.raid40 and id then self:InitRaidTier(id, "raid40") end
        if not layout.raid30 and id then self:InitRaidTier(id, "raid30") end
        if not layout.raid20 and id then self:InitRaidTier(id, "raid20") end
        -- Fallback if id couldn't be found (shouldn't happen, but be safe)
        if not layout.raid40 then layout.raid40 = self:CreateRaidProfile(-200, 100) end
        if not layout.raid30 then layout.raid30 = self:CreateRaidProfile(-200, 100) end
        if not layout.raid20 then layout.raid20 = self:CreateRaidProfile(-200, 100) end

        -- Backfill any keys that were added after this layout was created.
        -- Only sets a key if it is completely absent (nil) — never overwrites.
        local function backfill(tbl, defaults)
            for k, v in pairs(defaults) do
                if tbl[k] == nil then tbl[k] = v end
            end
        end
        local dispelDefaults = {
            showDispelIndicator     = true,
            dispelIndicatorStyle    = "icon",
            dispelIndicatorSize     = 12,
            dispelIndicatorPosition = "TOPRIGHT",
        }
        local groupOrderDefaults = {
            customGroupOrdering = false,
            groupOrderingMode   = "TANK_HEALER_DPS",
        }
        local auraPositionRaidDefaults = {
            buffAnchorPoint      = "BOTTOMRIGHT",
            buffOffsetX          = 0,
            buffOffsetY          = 0,
            buffGrowDirection    = "LEFT",
            debuffAnchorPoint    = "BOTTOMLEFT",
            debuffOffsetX        = 0,
            debuffOffsetY        = 0,
            debuffGrowDirection  = "RIGHT",
            privateAuraGrowDirection = "LEFT",
        }
        local auraPositionPartyDefaults = {
            buffAnchorPoint      = "BOTTOMRIGHT",
            buffOffsetX          = 0,
            buffOffsetY          = 0,
            buffGrowDirection    = "LEFT",
            debuffAnchorPoint    = "BOTTOMLEFT",
            debuffOffsetX        = 0,
            debuffOffsetY        = 0,
            debuffGrowDirection  = "RIGHT",
            privateAuraGrowDirection = "LEFT",
        }
        -- scaleIndicators must be explicitly true/false (never nil) so that the
        -- ~= false check in ResizeAllFrames/_ReconfigureTestFrames reflects what
        -- the user has actually configured.  Without this, existing profiles that
        -- pre-date the setting have nil here, which ~= false evaluates as true and
        -- causes indicators to scale even when the checkbox appears unchecked.
        local scaleDefaults = {
            enableFrameScale = false,
            frameScale      = 1.0,
            scaleIndicators = true,
        }
        for _, tier in ipairs({ layout.raid40, layout.raid30, layout.raid20 }) do
            if tier then
                backfill(tier, dispelDefaults)
                backfill(tier, auraPositionRaidDefaults)
                backfill(tier, scaleDefaults)
            end
        end
        local customBuffContainerDefaults = {
            customBuffContainers = {},
        }
        for _, tier in ipairs({ layout.raid40, layout.raid30, layout.raid20 }) do
            if tier then
                backfill(tier, customBuffContainerDefaults)
            end
        end
        if layout.party then
            backfill(layout.party, dispelDefaults)
            backfill(layout.party, groupOrderDefaults)
            backfill(layout.party, auraPositionPartyDefaults)
            backfill(layout.party, scaleDefaults)
            backfill(layout.party, customBuffContainerDefaults)
        end
    end

    local function getActiveSection()
        local ACD = LibStub("AceConfigDialog-3.0", true)
        if ACD then
            local st = ACD:GetStatusTable("BuzzardFrames")
            if st and st.groups then
                local selected = st.groups.selected
                if selected then
                    -- Strip the raidPartyFrames parent prefix if present,
                    -- then take the first path segment.
                    local stripped = selected:gsub("^raidPartyFrames\001", "")
                    return stripped:match("^([^\001]+)") or stripped
                end
                return "roleSpecLayouts"
            end
        end
        return "roleSpecLayouts"
    end
    -- Returns true only when a Raid/Party Frames child tab is selected.
    local function isRaidPartySection()
        local ACD = LibStub("AceConfigDialog-3.0", true)
        if ACD then
            local st = ACD:GetStatusTable("BuzzardFrames")
            if st and st.groups then
                local selected = st.groups.selected or ""
                -- Must start with raidPartyFrames (or be one of its children)
                return selected == "raidPartyFrames"
                    or selected:sub(1, #"raidPartyFrames\001") == "raidPartyFrames\001"
            end
        end
        return false
    end
    local function showDropdowns()
        local s = getActiveSection()
        return s == "frames" or s == "auras"
    end
    local function showSetupMode()
        -- Hide on the parent node itself; only show on child tabs
        if not isRaidPartySection() then return false end
        local s = getActiveSection()
        return s ~= "raidPartyFrames"
    end

    -- ── Shared aura profile helpers ──────────────────────────────────────────
    -- v27 Step 16 refactor: sub-category-aware routing.
    --
    -- Storage shape (post-v27):
    --   * Per-layout OFF (default): keys live at rpDB.profile.auras.<subcat>[key].
    --     `GetSectionProfile("auras", flat)` returns the global auras table
    --     (ignoring the flat) and `[subcat]` indexes the always-populated
    --     global sub-category.
    --   * Per-layout ON: keys live at flat.auras.<subcat>[key] when materialized,
    --     else fall through via the two-tier metatable chain:
    --       flat.auras.__index           = rpDB.profile.auras
    --       flat.auras.<subcat>.__index  = rpDB.profile.auras.<subcat>
    --     so a read of a non-materialized sub-category transparently hits the
    --     global sub-category table.
    --
    -- AURAS_SUBCATEGORY_OF (Core_ProfileAPI.lua) maps every aura key -> its
    -- sub-category. getAuras_shared / setAuras_shared / setAurasBigDef_shared
    -- consult the map on every get/set and route through the correct
    -- sub-category automatically -- widgets use plain `get = getAuras,
    -- set = setAuras` without any sub-category knowledge of their own.
    --
    -- getAurasProfile_shared has two modes:
    --   * No arg: returns the flat root (legacy shape, preserved for
    --     buildCopyToDropdown callers that iterate rawkeys).
    --   * subcat string: returns the resolved sub-category view
    --     (either rpDB.profile.auras.<subcat> or flat.auras.<subcat>),
    --     used by predicates and inline reads in Options_Auras.lua
    --     (e.g. `getAurasProfile("buffs").showBuffs`).
    --
    -- Used by both the Auras nav tab and the Tooltips nav tab so neither
    -- duplicates these closures.
    local function getAurasProfile_shared(subcat)
        local lpp = getLpp()
        local fl  = lpp.flatLayouts or {}
        local mf  = self._modifyingFlat
        local flat
        if mf and fl[mf] then
            ensureLayout(fl[mf])
            flat = fl[mf]
        else
            -- Fallback: party flat (should always exist post-migration)
            ensureLayout(fl.flat_party)
            flat = fl.flat_party
        end
        if subcat then
            -- Route through GetSectionProfile so per-layout ON returns
            -- flat.auras (with its sub-category metatable fallbacks),
            -- while per-layout OFF returns the global rpDB.profile.auras.
            -- Indexing [subcat] on either surface correctly resolves the
            -- sub-category view (materialized + metatable-wired when ON,
            -- rawkey global sub-category when OFF).
            local sp = self:GetSectionProfile("auras", flat)
            return sp and sp[subcat]
        end
        return flat
    end

    -- Read: route via AURAS_SUBCATEGORY_OF so the widget just passes its
    -- info[#info] key and we do the lookup. For keys not in the map
    -- (shouldn't happen for aura widgets, but defensive), fall back to
    -- flat-root read.
    local function getAuras_shared(info)
        local key = info[#info]
        local subcat = BF.AURAS_SUBCATEGORY_OF[key]
        if subcat then
            local view = getAurasProfile_shared(subcat)
            return view and view[key]
        end
        return getAurasProfile_shared()[key]
    end

    -- Write: route via AURAS_SUBCATEGORY_OF. Per-layout ON uses
    -- GetOrCreateAurasSubCategory to lazily materialize the per-flat
    -- sub-category (with metatable wiring). Per-layout OFF writes
    -- directly to the global sub-category (always populated by defaults,
    -- so no lazy materialization needed).
    -- Per-subcategory scoped refresh dispatch. Each aura subcategory
    -- routes to its own RefreshXOnly helper so settings changes only
    -- touch the indicator(s) that actually read their inputs. The
    -- broad RefreshAllAuras path is reserved for changes with no
    -- detectable subcategory (legacy flat-root writes, defensive path).
    -- See Docs/REFRESH_SCOPING_PLAN.md.
    local SUBCAT_REFRESH = {
        buffs            = "RefreshBuffsOnly",
        debuffs          = "RefreshDebuffsOnly",
        privateAuras     = "RefreshPrivateAurasOnly",
        bigDef           = "RefreshBigDefOnly",
        important        = "RefreshImportantOnly",
        crowdControl     = "RefreshCrowdControlOnly",
        dispelIndicator  = "RefreshDispelOnly",
    }

    -- Write helper: routes the value into the per-layout or global
    -- profile via AURAS_SUBCATEGORY_OF. Returns (key, subcat) so
    -- callers can dispatch their own refresh and short-circuit the
    -- "set + RefreshAllAuras" pattern in nested setters.
    local function writeAurasValue(info, val)
        local key = info[#info]
        local subcat = BF.AURAS_SUBCATEGORY_OF[key]
        if subcat then
            if self:IsPerLayoutSection("auras") then
                local flat = getAurasProfile_shared()
                local sub = self:GetOrCreateAurasSubCategory(flat, subcat)
                if sub then sub[key] = val end
                BF:InvalidateFlatAuraCache(flat)
            else
                local gp = self.rpDB.profile.auras
                if gp then
                    gp[subcat] = gp[subcat] or {}
                    gp[subcat][key] = val
                end
                BF:InvalidateGlobalSectionFlatCaches("auras")
            end
        else
            -- Legacy flat-root write (defensive path; shouldn't fire for
            -- any current aura widget).
            local flat = getAurasProfile_shared()
            flat[key] = val
            if self:IsPerLayoutSection("auras") then
                BF:InvalidateFlatAuraCache(flat)
            else
                BF:InvalidateGlobalSectionFlatCaches("auras")
            end
        end
        return key, subcat
    end

    local function setAuras_shared(info, val)
        if InCombatLockdown() then return end
        local key, subcat = writeAurasValue(info, val)
        -- Invalidate the raid profile cache so UpdateAuraSizeCache re-reads
        -- the freshly written value instead of serving a stale cached copy.
        self:InvalidateRaidProfileCache()
        -- Clear position cache so any anchor/offset changes are immediately applied
        if key:find("Anchor") or key:find("Offset") or key:find("GrowDir") or key:find("PerRow") or key:find("Size") then
            for _, frame in pairs(BF.activeFrames or {}) do
                if frame.buffFrames then
                    for _, icon in ipairs(frame.buffFrames) do icon.SF_LastIndex = nil end
                end
                if frame.debuffFrames then
                    for _, icon in ipairs(frame.debuffFrames) do icon.SF_LastIndex = nil; icon.SF_LastOffset = nil end
                end
            end
        end
        -- Dispatch to the scoped refresh for this subcategory; fall back
        -- to the broad path when subcat is nil (legacy keys).
        local fnName = subcat and SUBCAT_REFRESH[subcat]
        if fnName and self[fnName] then
            self[fnName](self)
        else
            self:RefreshAllAuras()
        end
        if self.RefreshPreviewDummyAuras then self:RefreshPreviewDummyAuras() end
    end

    -- Write + RefreshAllPrivateAuras: same sub-category routing as
    -- setAuras_shared, but fires ONLY the icon-path refresh defined in
    -- PrivateAuras.lua (BF:RefreshAllPrivateAuras) instead of the full
    -- RefreshAllAuras. Used by every private-aura-only widget in the
    -- Private Auras subtab so that changing e.g. privateAuraSize does
    -- NOT re-lay out regular buffs/debuffs / re-apply stack text /
    -- invalidate container icon caches / re-run standard aura indicators.
    --
    -- Mirrors Grid2's pattern (Grid2Options:RefreshIndicator(ind, "Layout"))
    -- where every private-aura option setter touches only the private-aura
    -- indicator. The icon path's per-frame work is identical to Grid2's
    -- indicator:LayoutAllFrames -> indicator:Layout(f) (which nils
    -- auraUnit) -> next Update sees the nil and re-registers anchors
    -- (RemovePrivateAuraAnchor + AddPrivateAuraAnchor on every slot).
    --
    -- The pvpSwap* swap toggles are NOT routed here -- they affect both
    -- debuff and private-aura geometry (swapped in AuraCache) so they
    -- still need the full RefreshAllAuras path via setAuras_shared.
    local function setAurasPrivate_shared(info, val)
        if InCombatLockdown() then return end
        writeAurasValue(info, val)
        -- Scoped refresh: only the private aura icon indicator + the
        -- one debuff cross-effect when extraDebuffYOffset moves.
        if self.RefreshPrivateAurasOnly then self:RefreshPrivateAurasOnly() end
        -- Dispel overlay refresh stays — some private aura settings
        -- (anchor, geometry) feed the dispel overlay's positioning.
        if self.RefreshAllPrivateAuraDispelOverlays then self:RefreshAllPrivateAuraDispelOverlays() end
    end

    -- Used by the Big Def / Important / Crowd Control tabs. Routes
    -- each subcategory key to its own RefreshXOnly path via the
    -- SUBCAT_REFRESH dispatch instead of running the broad RefreshBigDef
    -- (which rebuilt every cache + ran UpdateStandardAuras = 8-indicator
    -- sweep). See Docs/REFRESH_SCOPING_PLAN.md.
    local function setAurasBigDef_shared(info, val)
        if InCombatLockdown() then return end
        local key, subcat = writeAurasValue(info, val)
        self:InvalidateRaidProfileCache()
        local fnName = subcat and SUBCAT_REFRESH[subcat]
        if fnName and self[fnName] then
            self[fnName](self)
        else
            -- Defensive: a key in this setter without a routable subcat
            -- shouldn't happen for current widgets, but fall back to the
            -- old behaviour rather than silently doing nothing.
            self:RefreshBigDef()
        end
        if self.RefreshPreviewDummyAuras then self:RefreshPreviewDummyAuras() end
    end
    local function aurasDisabled_shared()
        -- Under the flat model, a flat is edited as a whole unit; there
        -- is no per-raid-tier disabling within a single flat. Keep the
        -- controls enabled whenever the panel is open.
        return false
    end

    -- ── Copy-Settings Dropdown Helper ────────────────────────────────────────
    -- Returns an AceConfig select widget that lets the user copy the current
    -- flat's settings to one or all other flats of the same type.
    --
    -- getSourceProfile  : function() -> the flat table being shown (the
    --                     currently-modifying flat's data)
    -- copyKeys          : nil  (copy entire flat)  OR  list of key strings
    --                     (copy only those keys)
    -- sectionName       : human-readable label used in confirmation messages
    --
    -- Under the flat model, source and all targets are always of the same
    -- type (party or raid), so no party↔raid spacing reconciliation is
    -- needed. Position keys (anchorX/Y) and identity keys (name, type)
    -- are still skipped on bulk copies so those don't leak between flats.
    local function buildCopyToDropdown(getSourceProfile, copyKeys, sectionName)
        local function currentFlatID() return self._modifyingFlat end
        local function currentFlat()
            local fl = self.rpDB.profile.layouts.flatLayouts or {}
            return fl[currentFlatID()]
        end

        -- List of (id, name) pairs of eligible copy targets: all flats of
        -- the same type as the currently-modifying flat, except the flat
        -- itself.
        local function getEligibleTargets()
            local fl    = self.rpDB.profile.layouts.flatLayouts or {}
            local src   = currentFlat()
            local curID = currentFlatID()
            local t     = {}
            if not src then return t end
            for id, flat in pairs(fl) do
                if id ~= curID and flat.type == src.type then
                    t[#t + 1] = { id = id, name = flat.name or id }
                end
            end
            table.sort(t, function(a, b) return a.name < b.name end)
            return t
        end

        local function getTargetFlat(targetID)
            local fl = self.rpDB.profile.layouts.flatLayouts or {}
            return fl[targetID]
        end

        local function doCopy(targetID)
            if InCombatLockdown() then return end
            local src = getSourceProfile()
            local dst = getTargetFlat(targetID)
            if not src or not dst then return end
            if copyKeys then
                for _, k in ipairs(copyKeys) do
                    if src[k] ~= nil then
                        if type(src[k]) == "table" then
                            dst[k] = self:DeepCopy(src[k])
                        else
                            dst[k] = src[k]
                        end
                    end
                end
            else
                -- Position keys are intentionally excluded so positions don't
                -- leak between flats. Identity keys (name, type) are also
                -- preserved on the destination.
                local SKIP_KEYS = {
                    name=true, type=true,
                    anchorX=true, anchorY=true,
                }
                for k, v in pairs(src) do
                    if not SKIP_KEYS[k] then
                        if type(v) == "table" then
                            dst[k] = self:DeepCopy(v)
                        else
                            dst[k] = v
                        end
                    end
                end
            end
            self:InvalidateRaidProfileCache()
            self:RefreshAll()
            NotifyChangeSafe()
        end

        return {
            type  = "select",
            name  = "Copy these settings to",
            desc  = "Copy the current " .. sectionName .. " settings to another Layout of the same type.",
            order = 9999,
            hidden = function() return #getEligibleTargets() == 0 end,
            confirm = function(_, val)
                local src = currentFlat()
                local srcName = (src and src.name) or "current Layout"
                if val == "__all" then
                    return "Copy all " .. sectionName .. " settings from \"" .. srcName
                        .. "\" to all other Layouts? This will overwrite every setting in "
                        .. sectionName .. " section for all other Layouts."
                else
                    local fl = self.rpDB.profile.layouts.flatLayouts or {}
                    local dstName = (fl[val] and fl[val].name) or val
                    return "Copy all " .. sectionName .. " settings from \"" .. srcName
                        .. "\" to \"" .. dstName .. "\"? This will overwrite every setting in "
                        .. sectionName .. " section for the \"" .. dstName .. "\" Layout."
                end
            end,
            values = function()
                local opts    = {}
                local targets = getEligibleTargets()
                for _, e in ipairs(targets) do opts[e.id] = e.name end
                if #targets > 1 then opts["__all"] = "All (same type)" end
                return opts
            end,
            get = function() return nil end,  -- stateless: nothing selected by default
            set = function(_, val)
                if val == "__all" then
                    for _, e in ipairs(getEligibleTargets()) do doCopy(e.id) end
                else
                    doCopy(val)
                end
            end,
            sorting = function()
                local order   = {}
                local targets = getEligibleTargets()
                for _, e in ipairs(targets) do order[#order + 1] = e.id end
                if #targets > 1 then order[#order + 1] = "__all" end
                return order
            end,
        }
    end
    -- ── End Copy-Settings Helper ──────────────────────────────────────────────

    -- ── Section-Scoped Copy-Settings Helper ────────────────────────────────
    -- Used by sections that support the "Separate configuration per Layout"
    -- toggle. Copies only the per-flat section sub-table (flat[section]) from
    -- the currently-modifying flat to one or all other flats of the same type.
    --
    -- section : storage key, e.g. "sorting", "auras", "icons"
    -- keys    : nil  (copy the whole section sub-table) OR
    --           list of keys inside the sub-table (copy only those)
    -- label   : human-readable section name for the dropdown's desc text
    -- restrictSameType : when true, only allow copying between flats of the
    --                    same type (party→party, raid→raid). Default false
    --                    (all other flats of any type are eligible targets).
    --                    Pass true for sections whose keys are type-specific
    --                    (e.g. sorting's raid-only grid keys vs party-only
    --                    growDirection). Most sections can safely copy
    --                    across types because their keys (fonts, colors,
    --                    icon toggles, etc.) are type-neutral.
    --
    -- Dropdown is hidden unless the section's per-layout toggle is ON -- when
    -- OFF, all flats share the same global rpDB.profile[section] so a copy
    -- between flats is a no-op.
    local function buildSectionCopyToDropdown(section, keys, label, restrictSameType)
        local function currentFlatID() return self._modifyingFlat end
        local function currentFlat()
            local fl = self.rpDB.profile.layouts.flatLayouts or {}
            return fl[currentFlatID()]
        end

        local function getEligibleTargets()
            local fl    = self.rpDB.profile.layouts.flatLayouts or {}
            local src   = currentFlat()
            local curID = currentFlatID()
            local t     = {}
            if not src then return t end
            for id, flat in pairs(fl) do
                if id ~= curID and (not restrictSameType or flat.type == src.type) then
                    t[#t + 1] = { id = id, name = flat.name or id }
                end
            end
            table.sort(t, function(a, b) return a.name < b.name end)
            return t
        end

        local function getTargetFlat(targetID)
            local fl = self.rpDB.profile.layouts.flatLayouts or {}
            return fl[targetID]
        end

        local function doCopy(targetID)
            if InCombatLockdown() then return end
            local srcFlat = currentFlat()
            local dstFlat = getTargetFlat(targetID)
            if not srcFlat or not dstFlat then return end
            -- Source: the per-flat sub-table on the currently-modifying flat.
            -- If it does not exist (toggle ON but flat never seeded), fall
            -- back to the global so the user still gets a sane copy.
            local srcSection = srcFlat[section]
            if type(srcSection) ~= "table" then
                srcSection = self.rpDB.profile[section]
            end
            if type(srcSection) ~= "table" then return end
            -- Ensure destination sub-table exists before writing into it.
            if type(dstFlat[section]) ~= "table" then
                dstFlat[section] = {}
            end
            local dstSection = dstFlat[section]
            if keys then
                for _, k in ipairs(keys) do
                    if srcSection[k] ~= nil then
                        if type(srcSection[k]) == "table" then
                            dstSection[k] = self:DeepCopy(srcSection[k])
                        else
                            dstSection[k] = srcSection[k]
                        end
                    end
                end
            else
                for k, v in pairs(srcSection) do
                    if type(v) == "table" then
                        dstSection[k] = self:DeepCopy(v)
                    else
                        dstSection[k] = v
                    end
                end
            end
            self:InvalidateRaidProfileCache()
            self:RefreshAll()
            NotifyChangeSafe()
        end

        return {
            type  = "select",
            name  = "Copy these settings to",
            desc  = "Copy the current " .. label .. " settings to another Layout"
                    .. (restrictSameType and " of the same type" or "")
                    .. ". Only visible when \"Separate configuration per Layout\" is enabled for this section.",
            order = 9999,
            hidden = function()
                -- Hide when the per-layout toggle is OFF (all flats share the
                -- global, so copy is a no-op) OR when there are no eligible
                -- targets to copy to (e.g. modifying the only party flat and
                -- restrictSameType is on; or only one flat exists total).
                if not self:IsPerLayoutSection(section) then return true end
                return #getEligibleTargets() == 0
            end,
            confirm = function(_, val)
                local src = currentFlat()
                local srcName = (src and src.name) or "current Layout"
                if val == "__all" then
                    return "Copy all " .. label .. " settings from \"" .. srcName
                        .. "\" to all other Layouts? This will overwrite every setting in "
                        .. label .. " section for all other Layouts."
                else
                    local fl = self.rpDB.profile.layouts.flatLayouts or {}
                    local dstName = (fl[val] and fl[val].name) or val
                    return "Copy all " .. label .. " settings from \"" .. srcName
                        .. "\" to \"" .. dstName .. "\"? This will overwrite every setting in "
                        .. label .. " section for the \"" .. dstName .. "\" Layout."
                end
            end,
            values = function()
                local opts    = {}
                local targets = getEligibleTargets()
                for _, e in ipairs(targets) do opts[e.id] = e.name end
                if #targets > 1 then opts["__all"] = restrictSameType and "All (same type)" or "All Layouts" end
                return opts
            end,
            get = function() return nil end,
            set = function(_, val)
                if val == "__all" then
                    for _, e in ipairs(getEligibleTargets()) do doCopy(e.id) end
                else
                    doCopy(val)
                end
            end,
            sorting = function()
                local order   = {}
                local targets = getEligibleTargets()
                for _, e in ipairs(targets) do order[#order + 1] = e.id end
                if #targets > 1 then order[#order + 1] = "__all" end
                return order
            end,
        }
    end
    -- ── End Section-Scoped Copy-Settings Helper ────────────────────────

    -- ── Auras Section-Scoped Subtab-Aware Copy-Settings Helper ──────────────
    -- Specialization of buildSectionCopyToDropdown used by the auto-injected
    -- Copy dropdown at the top of the Auras tab (via injectSubTab).
    --
    -- Unlike buildSectionCopyToDropdown (which copies the entire flat[section]
    -- sub-table), this variant copies ONLY the sub-category matching the
    -- currently-visible aura subtab. The active subtab is tracked via
    -- BF._currentAurasSubcat, mutated by per-subtab _subcatTracker description
    -- widgets in Options_Auras.lua (same pattern as the existing _sectionTracker).
    --
    -- Labels/desc/confirm text adapt to the active subtab so the user always
    -- sees exactly what's being copied.
    --
    -- Hidden semantics match buildSectionCopyToDropdown: only visible when
    -- the auras per-layout toggle is ON and at least one eligible target exists.
    local AURAS_SUBCAT_LABELS = {
        buffs           = "Buffs",
        debuffs         = "Debuffs",
        privateAuras    = "Private Auras",
        bigDef          = "Big Defensive",
        important       = "Important",
        crowdControl    = "Crowd Control",
        dispelIndicator = "Dispellable Debuffs",
    }
    local function currentAurasSubcat()
        return BF._currentAurasSubcat or "buffs"
    end
    local function currentAurasSubcatLabel()
        return AURAS_SUBCAT_LABELS[currentAurasSubcat()] or "Auras"
    end

    local function buildAurasSectionSubcatAwareCopyToDropdown()
        local function currentFlatID() return self._modifyingFlat end
        local function currentFlat()
            local fl = self.rpDB.profile.layouts.flatLayouts or {}
            return fl[currentFlatID()]
        end

        local function getEligibleTargets()
            local fl    = self.rpDB.profile.layouts.flatLayouts or {}
            local src   = currentFlat()
            local curID = currentFlatID()
            local t     = {}
            if not src then return t end
            for id, flat in pairs(fl) do
                -- No same-type restriction: aura sub-category keys are type-neutral.
                if id ~= curID then
                    t[#t + 1] = { id = id, name = flat.name or id }
                end
            end
            table.sort(t, function(a, b) return a.name < b.name end)
            return t
        end

        local function getTargetFlat(targetID)
            local fl = self.rpDB.profile.layouts.flatLayouts or {}
            return fl[targetID]
        end

        local function doCopy(targetID)
            if InCombatLockdown() then return end
            local srcFlat = currentFlat()
            local dstFlat = getTargetFlat(targetID)
            if not srcFlat or not dstFlat then return end
            local subcat = currentAurasSubcat()
            -- Source view: resolved through GetSectionProfile so un-materialized
            -- sub-categories on the source flat fall through to the global via
            -- the two-tier metatable chain. We copy all keys present in the
            -- source subtable (either rawkeys or inherited via metatable).
            -- Reading values (not rawkeys) ensures a pristine source still
            -- produces a copy populated with defaults.
            local srcSection = self:GetSectionProfile("auras", srcFlat)
            local srcSub     = srcSection and srcSection[subcat]
            if type(srcSub) ~= "table" then return end
            -- Destination: lazily materialize flat.auras.<subcat> with the
            -- metatable chain wired, then write rawkeys directly.
            local dstSub = self:GetOrCreateAurasSubCategory(dstFlat, subcat)
            if type(dstSub) ~= "table" then return end
            for k, v in pairs(srcSub) do
                if type(v) == "table" then
                    dstSub[k] = self:DeepCopy(v)
                else
                    dstSub[k] = v
                end
            end
            self:InvalidateRaidProfileCache()
            self:RefreshAll()
            NotifyChangeSafe()
        end

        return {
            type  = "select",
            name  = "Copy these settings to",
            desc  = "Copy all settings in the current subtab to another Layout.",
            order = 0.6,
            width = "normal",
            hidden = function()
                if not self:IsPerLayoutSection("auras") then return true end
                return #getEligibleTargets() == 0
            end,
            confirm = function(_, val)
                local src = currentFlat()
                local srcName = (src and src.name) or "current Layout"
                local label = currentAurasSubcatLabel()
                if val == "__all" then
                    return "Copy all " .. label .. " settings from \"" .. srcName
                        .. "\" to all other Layouts? This will overwrite the " .. label
                        .. " settings of every other Layout."
                else
                    local fl = self.rpDB.profile.layouts.flatLayouts or {}
                    local dstName = (fl[val] and fl[val].name) or val
                    return "Copy all " .. label .. " settings from \"" .. srcName
                        .. "\" to \"" .. dstName .. "\"? This will overwrite the " .. label
                        .. " settings of the \"" .. dstName .. "\" Layout."
                end
            end,
            values = function()
                local opts    = {}
                local targets = getEligibleTargets()
                for _, e in ipairs(targets) do opts[e.id] = e.name end
                if #targets > 1 then opts["__all"] = "All Layouts" end
                return opts
            end,
            get = function() return nil end,
            set = function(_, val)
                if val == "__all" then
                    for _, e in ipairs(getEligibleTargets()) do doCopy(e.id) end
                else
                    doCopy(val)
                end
            end,
            sorting = function()
                local order   = {}
                local targets = getEligibleTargets()
                for _, e in ipairs(targets) do order[#order + 1] = e.id end
                if #targets > 1 then order[#order + 1] = "__all" end
                return order
            end,
        }
    end
    -- ── End Auras Section-Scoped Subtab-Aware Copy Helper ────────────────

    -- ── Aura Text Section-Scoped Subtab-Aware Copy Helper (v30) ─────────
    -- Specialization of buildSectionCopyToDropdown used by the auto-injected
    -- Copy dropdown at the top of the Aura Text tab (via injectSubTab).
    --
    -- Unlike buildSectionCopyToDropdown (which copies the entire flat[section]
    -- sub-table), this variant copies ONLY the sub-category matching the
    -- currently-visible auraText subtab. The active subtab is tracked via
    -- BF._currentAuraTextSubcat, mutated by per-subtab _subcatTracker description
    -- widgets in Options_AuraText.lua.
    --
    -- The unified "Duration Text" subtab (shown when globalAuraTextConfig is ON)
    -- and the per-type subtabs (shown when OFF) map to distinct sub-categories
    -- ("global" vs "buffs"/"debuffs"/"bigDef"/"important"/"crowdControl"/
    -- "privateAuras"), so the copy operation always affects exactly the keys
    -- visible on the current subtab.
    --
    -- Hidden semantics match buildSectionCopyToDropdown: only visible when the
    -- auraText per-layout toggle is ON and at least one eligible target exists.
    local AURA_TEXT_SUBCAT_LABELS = {
        stackText    = "Stack Text",
        global       = "Duration Text",
        buffs        = "Buffs",
        debuffs      = "Debuffs",
        bigDef       = "Big Defensive",
        important    = "Important",
        crowdControl = "Crowd Control",
        privateAuras = "Private Auras",
    }
    local function currentAuraTextSubcat()
        return BF._currentAuraTextSubcat or "global"
    end
    local function currentAuraTextSubcatLabel()
        return AURA_TEXT_SUBCAT_LABELS[currentAuraTextSubcat()] or "Aura Cooldown Text"
    end

    local function buildAuraTextSectionSubcatAwareCopyToDropdown()
        local function currentFlatID() return self._modifyingFlat end
        local function currentFlat()
            local fl = self.rpDB.profile.layouts.flatLayouts or {}
            return fl[currentFlatID()]
        end

        local function getEligibleTargets()
            local fl    = self.rpDB.profile.layouts.flatLayouts or {}
            local src   = currentFlat()
            local curID = currentFlatID()
            local t     = {}
            if not src then return t end
            for id, flat in pairs(fl) do
                -- No same-type restriction: auraText sub-category keys are
                -- type-neutral (stack font, threshold colors, etc. are all
                -- party/raid-agnostic).
                if id ~= curID then
                    t[#t + 1] = { id = id, name = flat.name or id }
                end
            end
            table.sort(t, function(a, b) return a.name < b.name end)
            return t
        end

        local function getTargetFlat(targetID)
            local fl = self.rpDB.profile.layouts.flatLayouts or {}
            return fl[targetID]
        end

        local function doCopy(targetID)
            if InCombatLockdown() then return end
            local srcFlat = currentFlat()
            local dstFlat = getTargetFlat(targetID)
            if not srcFlat or not dstFlat then return end
            local subcat = currentAuraTextSubcat()
            -- Source view: resolved through GetSectionProfile so un-materialized
            -- sub-categories on the source flat fall through to the global via
            -- the two-tier metatable chain. Reading values (not rawkeys) ensures
            -- a pristine source still produces a copy populated with defaults.
            local srcSection = self:GetSectionProfile("auraText", srcFlat)
            local srcSub     = srcSection and srcSection[subcat]
            if type(srcSub) ~= "table" then return end
            -- Destination: lazily materialize flat.auraText.<subcat> with the
            -- metatable chain wired, then write rawkeys directly.
            local dstSub = self:GetOrCreateAuraTextSubCategory(dstFlat, subcat)
            if type(dstSub) ~= "table" then return end
            for k, v in pairs(srcSub) do
                if type(v) == "table" then
                    dstSub[k] = self:DeepCopy(v)
                else
                    dstSub[k] = v
                end
            end
            self:InvalidateRaidProfileCache()
            self:RefreshAll()
            NotifyChangeSafe()
        end

        return {
            type  = "select",
            name  = "Copy these settings to",
            desc  = "Copy all settings in the current subtab to another Layout.",
            order = 0.6,
            width = "normal",
            hidden = function()
                if not self:IsPerLayoutSection("auraText") then return true end
                return #getEligibleTargets() == 0
            end,
            confirm = function(_, val)
                local src = currentFlat()
                local srcName = (src and src.name) or "current Layout"
                local label = currentAuraTextSubcatLabel()
                if val == "__all" then
                    return "Copy all " .. label .. " settings from \"" .. srcName
                        .. "\" to all other Layouts? This will overwrite the " .. label
                        .. " settings of every other Layout."
                else
                    local fl = self.rpDB.profile.layouts.flatLayouts or {}
                    local dstName = (fl[val] and fl[val].name) or val
                    return "Copy all " .. label .. " settings from \"" .. srcName
                        .. "\" to \"" .. dstName .. "\"? This will overwrite the " .. label
                        .. " settings of the \"" .. dstName .. "\" Layout."
                end
            end,
            values = function()
                local opts    = {}
                local targets = getEligibleTargets()
                for _, e in ipairs(targets) do opts[e.id] = e.name end
                if #targets > 1 then opts["__all"] = "All Layouts" end
                return opts
            end,
            get = function() return nil end,
            set = function(_, val)
                if val == "__all" then
                    for _, e in ipairs(getEligibleTargets()) do doCopy(e.id) end
                else
                    doCopy(val)
                end
            end,
            sorting = function()
                local order   = {}
                local targets = getEligibleTargets()
                for _, e in ipairs(targets) do order[#order + 1] = e.id end
                if #targets > 1 then order[#order + 1] = "__all" end
                return order
            end,
        }
    end
    -- ── End Aura Text Section-Scoped Subtab-Aware Copy Helper ───────────────

    -- (Historical note: pre-v24, getTooltip_global / setTooltip_global /
    -- setTooltipBigDef_global lived here and wrote to self.db.profile[key].
    -- v24 unified every tooltip widget onto the standard makeRpGet("tooltips")
    -- / makeRpSet("tooltips") routing through GetSectionProfile. Side effects
    -- (RefreshAllAuras, RefreshPreviewDummyAuras) now live in the single
    -- setTP helper inside Options_Tooltips.lua. See Core_Migrations.lua
    -- MigrateTooltipsLocation for the storage relocation.)

    local options = {
        type = "group",
        name = "|cff11ace9Buzzard Frames|r",
        childGroups = "tree",
        args = {

            -- ── Raid/Party Frames parent tab ──────────────────────────────
            raidPartyFrames = {
                type        = "group",
                name        = "|cff11ace9Raid/Party Frames|r",
                order       = 1,
                childGroups = "tree",
                args = {

            -- Section tracker: reset _currentSection when the root tab renders
            -- so dummy auras are hidden when navigating away from aura sub-tabs.
            _rootSectionTracker = {
                type = "description", name = function()
                    if self._currentSection ~= "root" then
                        self._currentSection = "root"
                        if BF.RefreshPreviewDummyAuras then BF:RefreshPreviewDummyAuras() end
                    end
                    return ""
                end, order = -99, width = "full",
            },

            -- ── Enable Party/Raid Frames toggles ─────────────────────────────
            enablePartyFrames = {
                type     = "toggle",
                name     = "Enable Party Frames",
                desc     = "Enable BuzzardFrames for party groups. Requires a UI reload to take effect.",
                order    = -20,
                width    = "normal",
                get      = function() return self.db.global.partyFramesEnabled ~= false end,
                set      = function(_, val)
                    if InCombatLockdown() then return end
                    self.db.global.partyFramesEnabled = val
                    C_Timer.After(0, function() StaticPopup_Show("BUZZARDFRAMES_RELOAD") end)
                end,
                disabled = InCombatLockdown,
            },
            enableRaidFrames = {
                type     = "toggle",
                name     = "Enable Raid Frames",
                desc     = "Enable BuzzardFrames for raid groups. Requires a UI reload to take effect.",
                order    = -19.5,
                width    = "normal",
                get      = function() return self.db.global.raidFramesEnabled ~= false end,
                set      = function(_, val)
                    if InCombatLockdown() then return end
                    self.db.global.raidFramesEnabled = val
                    C_Timer.After(0, function() StaticPopup_Show("BUZZARDFRAMES_RELOAD") end)
                end,
                disabled = InCombatLockdown,
            },
            hideBlizzardPartyGroup = {
                type     = "group",
                name     = "Hide Blizzard Party",
                order    = -19,
                inline   = true,
                args     = {
                    hideBlizzardParty = {
                        type     = "toggle",
                        name     = "Hide Blizzard Party Frames",
                        desc     = "Hide the default Blizzard party frames while BuzzardFrames is active. Requires a UI reload to apply.",
                        order    = 1,
                        width    = "normal",
                        disabled = InCombatLockdown,
                        get      = function() return self.db.global.hideBlizzardParty end,
                        set      = function(_, val)
                            if InCombatLockdown() then return end
                            self.db.global.hideBlizzardParty = val
                            -- Both directions need a reload, matching Grid2's
                            -- pattern (GridGeneral.lua "Hide Blizzard Frames"):
                            -- the hide path installs hooks that can't be
                            -- uninstalled, and live-hiding party frames is
                            -- fragile across solo<->group transitions.
                            StaticPopup_Show("BUZZARDFRAMES_RELOAD")
                        end,
                    },
                },
            },
            hideBlizzardRaidGroup = {
                type     = "group",
                name     = "Hide Blizzard Raid",
                order    = -18,
                inline   = true,
                args     = {
                    hideBlizzardRaid = {
                        type     = "toggle",
                        name     = "Hide Blizzard Raid Frames",
                        desc     = "Hide the default Blizzard raid frames while BuzzardFrames is active. Requires a UI reload to apply.",
                        order    = 1,
                        width    = "normal",
                        disabled = InCombatLockdown,
                        get      = function() return self.db.global.hideBlizzardRaid end,
                        set      = function(_, val)
                            if InCombatLockdown() then return end
                            self.db.global.hideBlizzardRaid = val
                            -- Both directions reload, matching Grid2. See
                            -- the hideBlizzardParty setter above for the
                            -- rationale.
                            StaticPopup_Show("BUZZARDFRAMES_RELOAD")
                        end,
                    },
                },
            },
            hideBlizzardPanelGroup = {
                type     = "group",
                name     = "Hide Blizzard Panel",
                order    = -17,
                inline   = true,
                args     = {
                    hideBlizzardRaidManager = {
                        type     = "toggle",
                        name     = "Hide Blizzard Raid Tools Panel",
                        desc     = "Also hide the Blizzard raid tools panel (ready check, role poll, etc.) shown on the left side of the screen. Changing this requires a UI reload.",
                        order    = 1,
                        width    = "normal",
                        disabled = InCombatLockdown,
                        get      = function() return self.db.global.hideBlizzardRaidManager end,
                        set      = function(_, val)
                            if InCombatLockdown() then return end
                            self.db.global.hideBlizzardRaidManager = val
                            StaticPopup_Show("BUZZARDFRAMES_RELOAD")
                        end,
                    },
                },
            },

            -- Setup Mode button is now in the AceConfigDialog panel chrome
            -- (bottom-right corner) — see Core_AceConfigDialog.lua. Modify Layout
            -- dropdown is declared per-sub-tab because AceConfig parent inline
            -- args vanish when a child page is open.
            globalSetupTracker = {
                type   = "description",
                hidden = function() return not showSetupMode() end,
                name  = function()
                    self.lastViewedTab = self:GetActiveSlot()
                    -- Update built-in AceGUI status bar (wide box left of Close button)
                    local ACD = LibStub("AceConfigDialog-3.0", true)
                    local aceFrame = ACD and ACD.OpenFrames and ACD.OpenFrames["BuzzardFrames"]
                    if aceFrame then
                        local lpp = getLpp()
                        local fl  = lpp.flatLayouts or {}
                        local slot = self:GetActiveSlot()
                        local activeID = self:ResolveActiveFlat(slot)
                        local activeName = (activeID and activeID ~= "none" and fl[activeID] and fl[activeID].name) or "\226\128\148"
                        local context = (self.SLOT_LABELS and self.SLOT_LABELS[slot]) or slot or "?"
                        local modFlat     = self._modifyingFlat
                        local modFlatName = (modFlat and fl[modFlat] and fl[modFlat].name) or "\226\128\148"
                        local labelColor = (activeID and activeID == modFlat) and "|cff76CC4B" or "|cff11ace9"
                        aceFrame:SetStatusText(labelColor .. "Active:|r |cffffffff" .. activeName .. " |cff87ceeb[Instance Type: " .. context .. "]|r    " .. labelColor .. "Modifying:|r |cffffffff" .. modFlatName .. "|r")
                    end
                    return ""
                end,
                order = -11,
                width = "full",
            },


            -- ── sub-tabs (hidden when Raid/Party Frames are disabled) ────────────
                },
            }, -- end raidPartyFrames
        }
    }

    -- Inject sub-tabs into raidPartyFrames.args after building, so we can
    -- stamp a hidden() function onto each one that hides when both party and raid are disabled.
    local raidPartyArgs = options.args.raidPartyFrames.args
    local function raidPartyHidden() return self.db.global.partyFramesEnabled == false and self.db.global.raidFramesEnabled == false end

    -- Maps sub-tab args key -> storage section key for sections that support
    -- the "Separate configuration per Layout" toggle. Consulted by the chrome
    -- "Modifying Layout" dropdown in Core_AceConfigDialog.lua to decide when
    -- to surface the dropdown (shown for frames + any section whose toggle is
    -- ON).
    BF._perLayoutSectionByTab = BF._perLayoutSectionByTab or {}

    local function injectSubTab(key, tbl, perLayoutSection, sectionLabel, restrictSameTypeCopy)
        tbl.hidden = raidPartyHidden
        if perLayoutSection then
            BF._perLayoutSectionByTab[key] = perLayoutSection
            tbl.args = tbl.args or {}
            -- AceConfigDialog's compareOptions sorts negative orders AFTER positive ones
            -- (see Libs/AceConfig-3.0/AceConfigDialog-3.0/AceConfigDialog-3.0.lua, the
            -- `if OrderA < 0 then if OrderB >= 0 then return false` branch). So a small
            -- positive order -- less than every section's first content widget (which
            -- start at 1) -- is how we get these widgets to actually render at the top.
            --
            -- The toggle and the Copy Settings dropdown sit on the same row:
            -- toggle at 1.5 width, dropdown at normal (1.0) width. They don't
            -- fill the full panel width -- trailing space after them is OK.
            tbl.args._perLayoutToggle = {
                type  = "toggle",
                -- Sky blue (|cff87ceeb) to visually distinguish
                -- this meta-configuration toggle from the section's regular
                -- setting toggles.
                name  = "|cff87ceebEnable per-Layout configuration for this section|r",
                desc  = "By default, these settings are global and affect all Layouts. Enabling this option will add the \"Modifying Layout\" dropdown at the top of the panel, allowing you to have different settings for each Layout (e.g. Party vs Raid).",
                order = 0.5,
                width = 1.5,
                get   = function() return self:IsPerLayoutSection(perLayoutSection) end,
                set   = function(_, val)
                    if InCombatLockdown() then return end
                    self:SetSectionPerLayout(perLayoutSection, val)
                end,
                disabled = InCombatLockdown,
            }
            -- Copy Settings dropdown on the same row, right of the toggle.
            -- The dropdown's built-in `hidden` function hides it when the
            -- per-layout toggle is OFF (copies between flats are no-ops in
            -- that state since all flats share the global). When hidden
            -- the toggle still rolls up to the full row width via AceGUI's
            -- auto-flow.
            local copyDropdown
            if perLayoutSection == "auras" then
                -- Auras section uses a subtab-aware variant that copies only
                -- the currently-visible subtab's sub-category (tracked via
                -- BF._currentAurasSubcat, set by per-subtab _subcatTracker
                -- widgets in Options_Auras.lua). Labels and confirm text
                -- adapt to the active subtab.
                copyDropdown = buildAurasSectionSubcatAwareCopyToDropdown()
            elseif perLayoutSection == "auraText" then
                -- Aura Text section (v30): same subtab-aware variant pattern
                -- as auras. Copies the sub-category matching the currently-
                -- visible auraText subtab (tracked via BF._currentAuraTextSubcat,
                -- set by per-subtab _subcatTracker widgets in
                -- Options_AuraText.lua). The unified "Duration Text" subtab
                -- (when globalAuraTextConfig is ON) copies auraText.global;
                -- the per-type subtabs copy auraText.buffs / debuffs / etc.
                copyDropdown = buildAuraTextSectionSubcatAwareCopyToDropdown()
            else
                local label = sectionLabel
                    or (perLayoutSection:sub(1,1):upper() .. perLayoutSection:sub(2))
                copyDropdown = buildSectionCopyToDropdown(perLayoutSection, nil, label, restrictSameTypeCopy)
            end
            copyDropdown.order = 0.6
            copyDropdown.width = "normal"
            tbl.args._perLayoutCopyTo = copyDropdown

            -- Aura Text (v30): inject the globalAuraTextConfig meta-toggle
            -- on its own full-width row at order 0.7, immediately below the
            -- per-layout toggle (0.5) + copy dropdown (0.6) row. This toggle
            -- governs which subtabs are visible in Options_AuraText.lua:
            -- ON -> unified "Duration Text" subtab; OFF -> per-type subtabs.
            -- Routes through GetSectionProfile so when the per-layout toggle
            -- is ON it writes to the modifying flat's auraText; when OFF it
            -- writes to the global rpDB.profile.auraText.
            if perLayoutSection == "auraText" then
                tbl.args._globalAuraTextConfigToggle = {
                    type  = "toggle",
                    name  = "Use global duration text config for all aura types",
                    desc  = "When enabled, a unified \"Duration Text\" subtab applies the same font, threshold, and swipe settings to Buffs, Debuffs, Big Defensives, Private Auras, Important auras, and Crowd Control. Disable this to configure each aura type independently (seven per-type subtabs appear instead).",
                    order = 0.7,
                    width = "full",
                    get   = function()
                        local at = self:GetSectionProfile("auraText", self:GetModifyingProfile()) or {}
                        return at.globalAuraTextConfig ~= false
                    end,
                    set   = function(_, val)
                        if InCombatLockdown() then return end
                        local at = self:GetSectionProfile("auraText", self:GetModifyingProfile())
                        if at then at.globalAuraTextConfig = val end
                        self:InvalidateRaidProfileCache()
                        self:RefreshAllAuras()
                        NotifyChangeSafe()
                    end,
                    disabled = InCombatLockdown,
                }
            end
        end
        raidPartyArgs[key] = tbl
    end

    -- Per-rpDB-sub-table get/set factories for Options sub-tabs.
    -- Each sub-tab receives get/set that read/write its own rpDB sub-table.
    --
    -- These route through BF:GetSectionProfile(subTable, BF:GetModifyingProfile())
    -- so sections whose "Separate configuration per Layout" toggle is ON
    -- read/write the per-flat sub-table (flat[subTable]) instead of the
    -- global rpDB.profile[subTable]. When the toggle is OFF (default for
    -- every section), GetSectionProfile ignores the flat argument and
    -- returns the global -- identical behaviour to the old direct access.
    local function makeRpGet(subTable)
        return function(info)
            local sp = self:GetSectionProfile(subTable, self:GetModifyingProfile())
            return sp and sp[info[#info]]
        end
    end
    local function makeRpSet(subTable, invalidatesAuraCache)
        return function(info, val)
            if InCombatLockdown() then return end
            local flat = self:GetModifyingProfile()
            local sp = self:GetSectionProfile(subTable, flat)
            if sp then sp[info[#info]] = val end
            if invalidatesAuraCache then
                if self:IsPerLayoutSection(subTable) then
                    BF:InvalidateFlatAuraCache(flat)
                else
                    BF:InvalidateGlobalSectionFlatCaches(subTable)
                end
            end
        end
    end
    local function makeRpSetRefresh(subTable)
        return function(info, val)
            if InCombatLockdown() then return end
            local sp = self:GetSectionProfile(subTable, self:GetModifyingProfile())
            if sp then sp[info[#info]] = val end
            self:RefreshAll()
        end
    end

    local getLayouts     = makeRpGet("layouts")
    local setLayouts     = makeRpSet("layouts")
    local getBorders     = makeRpGet("borders")
    local setBorders     = makeRpSet("borders")
    local getHealthPower = makeRpGet("healthPower")
    local setHealthPower = makeRpSet("healthPower", true)
    local getAbsorbs     = makeRpGet("absorbs")
    local setAbsorbs     = makeRpSet("absorbs")
    local getText        = makeRpGet("text")
    local setText        = makeRpSet("text")
    -- v30: auraText no longer routes via makeRpGet/makeRpSet because the
    -- section is nested two levels deep (auraText.<subcat>.<key>). The
    -- flat wrappers produced by makeRp* don't know how to walk the
    -- sub-category map, so Options_AuraText.lua now uses its own
    -- subcat-aware helpers (getATKey / setATKey routed through
    -- AURA_TEXT_SUBCATEGORY_OF + GetOrCreateAuraTextSubCategory).
    local getIcons       = makeRpGet("icons")
    local setIcons       = makeRpSet("icons", true)
    local getTooltips    = makeRpGet("tooltips")
    local setTooltips    = makeRpSet("tooltips", true)
    local getAuras       = makeRpGet("auras")
    local setAuras       = makeRpSet("auras")

    injectSubTab("frames", self:BuildFramesOptions({
        self               = self,
        ensureLayout       = ensureLayout,
        NotifyChangeSafe   = NotifyChangeSafe,
        buildCopyToDropdown = buildCopyToDropdown,
        safeLayout         = safeLayout,
    }))
    injectSubTab("framesSorting", self:BuildFramesSortingOptions({
        self = self,
        buildSectionCopyToDropdown = buildSectionCopyToDropdown,
    }), "sorting", nil, true)
    injectSubTab("auras", self:BuildAurasOptions({
        self                  = self,
        NotifyChangeSafe      = NotifyChangeSafe,
        getAurasProfile_shared = getAurasProfile_shared,
        getAuras_shared       = getAuras_shared,
        setAuras_shared       = setAuras_shared,
        setAurasPrivate_shared = setAurasPrivate_shared,
        setAurasBigDef_shared = setAurasBigDef_shared,
        aurasDisabled_shared  = aurasDisabled_shared,
        -- Copy Settings is handled centrally by injectSubTab via
        -- buildAurasSectionSubcatAwareCopyToDropdown (auto-injected at the top
        -- of the Auras tab alongside the per-layout toggle). Per-subtab Copy
        -- dropdowns have been removed; BF._currentAurasSubcat is tracked by
        -- _subcatTracker widgets inside BuildAurasOptions and read by the
        -- auto-injected dropdown at click time.
    }), "auras")
    injectSubTab("icons", self:BuildIconsOptions({
        self             = self,
        NotifyChangeSafe = NotifyChangeSafe,
        get              = getIcons,
        set              = setIcons,
        safeLayout       = safeLayout,
        buildSectionCopyToDropdown = buildSectionCopyToDropdown,
    }), "icons")
    injectSubTab("text", self:BuildTextOptions({
        self             = self,
        NotifyChangeSafe = NotifyChangeSafe,
        get              = getText,
        set              = setText,
        safeLayout       = safeLayout,
        buildSectionCopyToDropdown = buildSectionCopyToDropdown,
    }), "text")
    injectSubTab("borders", self:BuildBordersOptions({
        self             = self,
        NotifyChangeSafe = NotifyChangeSafe,
        get              = getBorders,
        set              = setBorders,
    }), "borders")
    injectSubTab("healthPower", self:BuildHealthPowerOptions({
        self             = self,
        NotifyChangeSafe = NotifyChangeSafe,
        get              = getHealthPower,
        set              = setHealthPower,
        buildSectionCopyToDropdown = buildSectionCopyToDropdown,
    }), "healthPower")
    injectSubTab("tooltips", self:BuildTooltipsOptions({
        self                    = self,
        NotifyChangeSafe        = NotifyChangeSafe,
        get                     = getTooltips,
        set                     = setTooltips,
        getAurasProfile_shared  = getAurasProfile_shared,
        buildSectionCopyToDropdown = buildSectionCopyToDropdown,
    }), "tooltips")
    injectSubTab("preview", self:BuildPreviewOptions({
        self             = self,
        NotifyChangeSafe = NotifyChangeSafe,
        get              = get,
        set              = set,
    }))
    injectSubTab("roleSpecLayouts", self:BuildLayoutsOptions({
        self             = self,
        NotifyChangeSafe = NotifyChangeSafe,
        ensureLayout     = ensureLayout,
    }))

    injectSubTab("auraText", self:BuildAuraTextOptions({
        self             = self,
        NotifyChangeSafe = NotifyChangeSafe,
        -- Copy Settings is handled centrally by injectSubTab via
        -- buildAuraTextSectionSubcatAwareCopyToDropdown (auto-injected at
        -- the top of the Aura Text tab alongside the per-layout toggle).
        -- Per-subtab Copy dropdowns have been removed;
        -- BF._currentAuraTextSubcat is tracked by _subcatTracker widgets
        -- inside BuildAuraTextOptions and read by the auto-injected
        -- dropdown at click time.
    }), "auraText")

    -- Aura Customizations is a top-level nav entry (not a sub-tab of raidPartyFrames)
    -- so it's injected below as options.args.customAuras

    -- Custom Frame Groups is a top-level nav entry (not a sub-tab of raidPartyFrames)
    -- so it's injected below as options.args.customFrames

    injectSubTab("absorbs", self:BuildAbsorbsOptions({
        self             = self,
        NotifyChangeSafe = NotifyChangeSafe,
        get              = getAbsorbs,
        set              = setAbsorbs,
        buildSectionCopyToDropdown = buildSectionCopyToDropdown,
    }), "absorbs")

    -- Add Aura Customizations as a top-level nav entry
    local customAurasOpts = self:BuildCustomAurasOptions({
        NotifyChangeSafe = NotifyChangeSafe,
    })
    customAurasOpts.order = 1.5
    customAurasOpts.name = "|cff11ace9" .. (customAurasOpts.name or "Aura Customizations") .. "|r"
    options.args.customAuras = customAurasOpts

    -- Add Custom Frame Groups as a top-level nav entry
    local customFramesOpts = self:BuildCustomFramesOptions({
        NotifyChangeSafe = NotifyChangeSafe,
    })
    customFramesOpts.order = 2
    customFramesOpts.name = "|cff11ace9" .. (customFramesOpts.name or "Custom Frame Groups") .. "|r"
    options.args.customFrames = customFramesOpts

    -- Add Unit Frames tab
    options.args.unitFrames = {
        type        = "group",
        name        = "|cff11ace9Unit Frames|r",
        order       = 3,
        childGroups = "tree",
        args        = self:BuildPTFOptionsTable().args,
    }

    -- Add Incoming Casts as a root-level entry (after Unit Frames)
    local icOpts = self:BuildIncomingCastsOptions({
        self             = self,
        NotifyChangeSafe = NotifyChangeSafe,
        get              = get,
        set              = set,
    })
    icOpts.order = 4
    icOpts.name = "|cff11ace9" .. (icOpts.name or "Incoming Casts") .. "|r"
    options.args.incomingCasts = icOpts

    -- Add Profiles as a root-level entry (after Incoming Casts)
    local profilesOpts = self:BuildProfilesOptions({
        self             = self,
        NotifyChangeSafe = NotifyChangeSafe,
    })
    profilesOpts.order = 5
    profilesOpts.name = "|cff11ace9" .. (profilesOpts.name or "Profiles") .. "|r"
    options.args.profiles = profilesOpts

    -- Add Colors as a root-level entry (after Profiles).
    -- Houses global color settings that are shared across all Layouts
    -- (e.g. Power Bar Colors, which also drive the oUF Unit Frames power
    -- element -- see Options_Colors.lua header for rationale).
    local colorsOpts = self:BuildColorsOptions({
        self             = self,
        NotifyChangeSafe = NotifyChangeSafe,
    })
    colorsOpts.order = 6
    colorsOpts.name = "|cff11ace9" .. (colorsOpts.name or "Colors") .. "|r"
    options.args.colors = colorsOpts

    AC:RegisterOptionsTable("BuzzardFrames", options)
    _optionsRef = options  -- enable nav path logic to detect top-level keys
    -- Restore user's panel size from saved profile, or apply defaults.
    -- ACD:SetDefaultSize overwrites status.width/height every call, so we
    -- write directly to the status table and only use defaults when no
    -- saved size exists in the profile.
    local sizeStatus = ACD:GetStatusTable("BuzzardFrames")
    sizeStatus.width  = self.db.global._optionsPanelW or 820
    sizeStatus.height = self.db.global._optionsPanelH or 760
    self:RegisterChatCommand("bf", "OnChatCommand")
    self:RegisterChatCommand("buzzard", "OnChatCommand")
    self:RegisterChatCommand("buzzardframes", "OnChatCommand")
end