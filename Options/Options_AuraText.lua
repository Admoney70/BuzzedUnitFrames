-- ============================================================
-- BuzzardFrames: Options_AuraText.lua
-- Builds and returns the "Aura Text" nav-tab args table.
-- Called from Options.lua: BF:BuildAuraTextOptions(deps)
--
-- v30 per-layout rollout: every widget routes through
--   BF:GetSectionProfile("auraText", BF:GetModifyingProfile())
-- with a sub-category-aware helper (getATSub). Sub-categories:
--   stackText  -- Stack Text subtab (always visible)
--   global     -- Duration Text subtab (visible when globalAuraTextConfig ON)
--   buffs / debuffs / bigDef / important / crowdControl / privateAuras
--                -- per-type Duration Text subtabs (visible when globalAuraTextConfig OFF)
--
-- globalAuraTextConfig lives at auraText top-level (NOT inside any
-- sub-category) and gates subtab visibility. The widget for it is
-- injected by Options.lua's injectSubTab (order 0.7, width "full")
-- so it sits on its own row after the per-layout toggle + copy
-- dropdown pair.
--
-- Every subtab has a `_subcatTracker` description widget (order -100)
-- whose `name` callback fires on every render of its containing group.
-- The callback updates BF._currentAuraTextSubcat so the auto-injected
-- subtab-aware Copy Settings dropdown at the top of this tab knows
-- which sub-category to copy. Mirror of the auras v27 pattern.
-- ============================================================
local BF = _G["BuzzardFrames"]

function BF:BuildAuraTextOptions(deps)
    local self             = deps.self
    local NotifyChangeSafe = deps.NotifyChangeSafe

    -- ── Routing helpers ───────────────────────────────────────────
    -- getAT() returns the auraText section table for the currently-modifying
    -- flat (flat.auraText when per-layout is ON, rpDB.profile.auraText when
    -- OFF). atSub(subcat) returns the named sub-category view.
    local function getAT()
        return self:GetSectionProfile("auraText", self:GetModifyingProfile()) or {}
    end
    local function getATSub(subcat)
        local at = getAT()
        return at[subcat]   -- may return nil on per-flat ON with un-materialized subcat
                            -- if the metatable fallback isn't wired (shouldn't happen
                            -- post-RehydrateFlats); callers guard with `or {}` below.
    end

    -- Read by key: routes info[#info] through AURA_TEXT_SUBCATEGORY_OF.
    local function getATKey(info)
        local key = info[#info]
        local subcat = BF.AURA_TEXT_SUBCATEGORY_OF[key]
        if subcat then
            local sub = getATSub(subcat)
            return sub and sub[key]
        end
        -- globalAuraTextConfig (top-level) and any defensive unmapped keys
        local at = getAT()
        return at[key]
    end

    -- Write by key: routes info[#info] through AURA_TEXT_SUBCATEGORY_OF.
    -- Per-layout ON: lazily materialize flat.auraText.<subcat> via
    -- GetOrCreateAuraTextSubCategory so the write lands on the flat's
    -- sparse rawkey. Per-layout OFF: write directly to the global
    -- rpDB.profile.auraText.<subcat> sub-table (always populated).
    local function setATKey(info, val)
        if InCombatLockdown() then return end
        local key = info[#info]
        local subcat = BF.AURA_TEXT_SUBCATEGORY_OF[key]
        if subcat then
            if self:IsPerLayoutSection("auraText") then
                local flat = self:GetModifyingProfile()
                local sub  = self:GetOrCreateAuraTextSubCategory(flat, subcat)
                if sub then sub[key] = val end
                BF:InvalidateFlatAuraCache(flat)
            else
                local gp = self.rpDB.profile.auraText
                if gp then
                    gp[subcat] = gp[subcat] or {}
                    gp[subcat][key] = val
                end
                BF:InvalidateGlobalSectionFlatCaches("auraText")
            end
        else
            -- Top-level auraText key (e.g. globalAuraTextConfig).
            -- Modifying-flat write: per-layout ON -> flat.auraText, OFF -> global.
            local at = getAT()
            if at then at[key] = val end
            if self:IsPerLayoutSection("auraText") then
                BF:InvalidateFlatAuraCache(self:GetModifyingProfile())
            else
                BF:InvalidateGlobalSectionFlatCaches("auraText")
            end
        end
        self:InvalidateRaidProfileCache()
    end

    -- Shorthand closures passed as get/set on widgets. Each one pairs with
    -- a tiny side-effect trailer (RefreshAllAuras / ThresholdRefreshDebounced /
    -- ApplyStackTextStyle) written inline so the refresh shape stays
    -- transparent to the reader.
    local function getAT_(info) return getATKey(info) end

    -- Per-subcategory preview refresh dispatch.
    -- Each subcategory in AURA_TEXT_SUBCATEGORY_OF maps to a dedicated
    -- BF:RefreshPreviewDummy<X>() method that repaints ONLY that aura type
    -- on the Options preview frames. This is a no-op when the Options
    -- panel is closed (ShouldShowPreviewAuras returns false).
    -- globalAuraTextConfig (the top-level toggle that flips between
    -- global and per-type subtabs) isn't in AURA_TEXT_SUBCATEGORY_OF,
    -- so RefreshPreviewForSubcat is never called for it; that toggle
    -- only changes which subtab widgets render, not how auras paint.
    local function RefreshPreviewForSubcat(subcat)
        if not subcat then return end
        if     subcat == "buffs"        then BF:RefreshPreviewDummyBuffs()
        elseif subcat == "debuffs"      then BF:RefreshPreviewDummyDebuffs()
        elseif subcat == "bigDef"       then BF:RefreshPreviewDummyBigDef()
        elseif subcat == "important"    then BF:RefreshPreviewDummyImportant()
        elseif subcat == "crowdControl" then BF:RefreshPreviewDummyCrowdControl()
        elseif subcat == "privateAuras" then BF:RefreshPreviewDummyPrivateAuras()
        elseif subcat == "stackText"    then BF:RefreshPreviewDummyStackText()
        elseif subcat == "global"       then BF:RefreshPreviewDummyGlobal()
        end
    end
    local function RefreshPreviewForInfo(info)
        if not info then return end
        local key = info[#info]
        RefreshPreviewForSubcat(BF.AURA_TEXT_SUBCATEGORY_OF[key])
    end

    -- Per-aura-text-subcategory scoped refresh dispatch. Routes each
    -- aura text setter to the matching RefreshXOnly so settings changes
    -- only re-Layout the indicator(s) they actually affect.
    --   global    → RefreshAllAuras (genuinely cross-cutting when the
    --               globalAuraTextConfig toggle is on)
    --   stackText → RefreshAllAuras (stack text appears on every aura
    --               type's icons; ApplyStackTextStyle alone isn't enough
    --               to re-stamp font/size/border/scale on icons)
    --   per-type  → RefreshXOnly for that type
    -- See Docs/REFRESH_SCOPING_PLAN.md.
    local SUBCAT_REFRESH = {
        buffs        = "RefreshBuffsOnly",
        debuffs      = "RefreshDebuffsOnly",
        bigDef       = "RefreshBigDefOnly",
        important    = "RefreshImportantOnly",
        crowdControl = "RefreshCrowdControlOnly",
        privateAuras = "RefreshPrivateAurasOnly",
    }
    local function DispatchRefreshForKey(key)
        local subcat = key and BF.AURA_TEXT_SUBCATEGORY_OF[key]
        local fnName = subcat and SUBCAT_REFRESH[subcat]
        if fnName and self[fnName] then
            self[fnName](self)
        else
            self:RefreshAllAuras()
        end
    end

    -- Debounced refresh: coalesces rapid slider changes into a single
    -- RebuildExpiringColorCurves + scoped refresh call after a short delay.
    -- Also coalesces per-subcategory preview refreshes: callers append the
    -- subcat(s) they touched to _thresholdPendingSubcats via
    -- ThresholdRefreshDebouncedFor(info), and the debounced callback fires
    -- one RefreshPreviewForSubcat per accumulated subcat. Handles the edge
    -- case where rapid edits span multiple types (e.g. a user drags a buff
    -- threshold slider then a debuff one within 50ms) so every touched
    -- subcat's preview gets refreshed, not just the last one written.
    local _thresholdRefreshTimer = nil
    local _thresholdPendingSubcats = {}
    local function ThresholdRefreshDebounced()
        if _thresholdRefreshTimer then _thresholdRefreshTimer:Cancel() end
        _thresholdRefreshTimer = C_Timer.NewTimer(0.05, function()
            _thresholdRefreshTimer = nil
            BF:RebuildExpiringColorCurves()
            -- Dispatch a scoped refresh per accumulated subcat. When
            -- multiple subcats were touched in the debounce window, each
            -- one fires its own scoped refresh. global / stackText fall
            -- through to RefreshAllAuras inside DispatchRefreshForKey.
            -- Build a synthetic key from any field in the subcat by
            -- finding the first matching key; cheaper to just dispatch
            -- per subcat directly:
            for subcat in pairs(_thresholdPendingSubcats) do
                local fnName = SUBCAT_REFRESH[subcat]
                if fnName and self[fnName] then
                    self[fnName](self)
                else
                    self:RefreshAllAuras()
                    break  -- RefreshAllAuras covers everything; no point looping
                end
            end
            -- Fire one preview refresh per accumulated subcat, then clear.
            for subcat in pairs(_thresholdPendingSubcats) do
                RefreshPreviewForSubcat(subcat)
                _thresholdPendingSubcats[subcat] = nil
            end
        end)
    end
    local function ThresholdRefreshDebouncedFor(info)
        local key = info and info[#info]
        local subcat = key and BF.AURA_TEXT_SUBCATEGORY_OF[key]
        if subcat then _thresholdPendingSubcats[subcat] = true end
        ThresholdRefreshDebounced()
    end

    -- Standard setter for the vast majority of widgets: write + scoped refresh.
    -- The refresh is dispatched per-subcategory via DispatchRefreshForKey
    -- (global / stackText fall through to RefreshAllAuras inside that helper).
    local function setAT(info, val)
        setATKey(info, val)
        DispatchRefreshForKey(info and info[#info])
        RefreshPreviewForInfo(info)
    end

    -- Threshold setter variant: write + debounced curve rebuild.
    -- When hideAbove1Min is toggled ON, auto-disable the corresponding dispel color toggle.
    local hideToDispelMap = {
        debuffHideDurationAbove1Min = "debuffDurationDispelColor",
        globalHideDurationAbove1Min = "globalDebuffDurationDispelColor",
    }
    -- Map primary threshold keys to their secondary counterparts for clamping.
    local primaryToSecondaryThreshold = {
        globalThresholdColorThreshold    = "globalThreshold2ColorThreshold",
        buffThresholdColorThreshold      = "buffThreshold2ColorThreshold",
        debuffThresholdColorThreshold    = "debuffThreshold2ColorThreshold",
        bigDefThresholdColorThreshold    = "bigDefThreshold2ColorThreshold",
        importantThresholdColorThreshold = "importantThreshold2ColorThreshold",
    }

    local function setAT_Threshold(info, val)
        setATKey(info, val)
        -- Clamp secondary threshold when primary threshold is lowered
        if type(val) == "number" then
            local key = info[#info]
            local secKey = primaryToSecondaryThreshold[key]
            if secKey then
                local subcat = BF.AURA_TEXT_SUBCATEGORY_OF[secKey]
                if subcat then
                    local sub = getATSub(subcat)
                    if sub and sub[secKey] and sub[secKey] >= val then
                        sub[secKey] = math.max(1, val - 1)
                    end
                end
            end
        end
        -- Auto-disable dispel color when hideAbove1Min is enabled
        if val == true then
            local key = info[#info]
            local dispelKey = hideToDispelMap[key]
            if dispelKey then
                local subcat = BF.AURA_TEXT_SUBCATEGORY_OF[dispelKey]
                if subcat then
                    if self:IsPerLayoutSection("auraText") then
                        local flat = self:GetModifyingProfile()
                        local sub = self:GetOrCreateAuraTextSubCategory(flat, subcat)
                        if sub then sub[dispelKey] = false end
                    else
                        local gp = self.rpDB.profile.auraText
                        if gp then
                            gp[subcat] = gp[subcat] or {}
                            gp[subcat][dispelKey] = false
                        end
                    end
                    self:InvalidateRaidProfileCache()
                end
            end
        end
        ThresholdRefreshDebouncedFor(info)
    end

    -- Stack text setter variant: write + ApplyStackTextStyle + NotifyChangeSafe.
    local function setAT_Stack(info, val)
        setATKey(info, val)
        self:ApplyStackTextStyle()
        NotifyChangeSafe()
        BF:RefreshPreviewDummyStackText()
    end

    -- Stack text setter variant: write + RefreshAllAuras (for font/anchor/offset).
    -- Stack text appears on every aura indicator's icons, so this stays as
    -- the broad path — there's no per-indicator alternative.
    local function setAT_StackRefresh(info, val)
        setATKey(info, val)
        self:RefreshAllAuras()
        BF:RefreshPreviewDummyStackText()
    end

    -- Color get/set adapter (AceConfig passes 4 values for color widgets).
    local function getColor(info)
        local c = getATKey(info) or { r = 1, g = 1, b = 1 }
        return c.r, c.g, c.b, c.a or 1
    end
    local function setColor_Threshold(info, r, g, b, a)
        setATKey(info, { r = r, g = g, b = b, a = a })
        ThresholdRefreshDebouncedFor(info)
    end

    -- LSM font values
    local function lsmFontValues()
        local LSM = LibStub("LibSharedMedia-3.0", true)
        local vals = { DEFAULT = "Game Default" }
        if LSM then for n, p in pairs(LSM:HashTable("font")) do vals[p] = n end end
        return vals
    end

    local FONT_BORDER_VALUES = {
        [""]                        = "None",
        ["OUTLINE"]                 = "Outline",
        ["THICKOUTLINE"]            = "Thick Outline",
        ["MONOCHROME"]              = "Monochrome",
        ["OUTLINE, MONOCHROME"]     = "Outline + Monochrome",
        ["THICKOUTLINE, MONOCHROME"]= "Thick Outline + Monochrome",
    }

    -- Predicate helpers (each reads the right sub-category via getATKey).
    local function isGlobal()
        local at = getAT()
        return at.globalAuraTextConfig ~= false
    end
    local function notGlobal() return not isGlobal() end

    -- Show-toggle predicates per subtab.
    local function globalDurationHidden()
        local g = getATSub("global") or {}
        return g.globalDurationShow == false
    end
    local function buffDurationHidden()
        local b = getATSub("buffs") or {}
        return b.showBuffDuration == false
    end
    local function debuffDurationHidden()
        local d = getATSub("debuffs") or {}
        return d.showDebuffDuration == false
    end
    local function bigDefDurationHidden()
        local b = getATSub("bigDef") or {}
        return not b.showBigDefDuration
    end
    local function importantDurationHidden()
        local i = getATSub("important") or {}
        return not i.showImportantDuration
    end
    local function crowdControlDurationHidden()
        local c = getATSub("crowdControl") or {}
        return not c.showCrowdControlDuration
    end
    local function stackTextHidden()
        local s = getATSub("stackText") or {}
        return s.showStackText == false
    end

    -- Per-subtab tracker: description widget whose `name` callback fires
    -- on every render of its containing group. We piggyback the render
    -- to update BF._currentAuraTextSubcat so the auto-injected subtab-
    -- aware Copy dropdown knows what to copy. Mirrors the auras v27
    -- _subcatTracker pattern.
    local function makeSubcatTracker(subcat)
        return {
            type  = "description",
            name  = function()
                BF._currentAuraTextSubcat = subcat
                return ""
            end,
            order = -100,
            width = "full",
        }
    end

    local result = {
        type        = "group",
        name        = "Aura Cooldown Text",
        order       = 3,
        childGroups = "tab",
        args        = {
            _sectionTracker = {
                type = "description", order = 0, width = "full",
                name = function()
                    if self._currentSection ~= "auraText" then
                        self._currentSection = "auraText"
                        if not InCombatLockdown() then NotifyChangeSafe() end
                    end
                    return ""
                end,
            },

            -- ── Unified tab (shown when globalAuraTextConfig is ON) ──────────
            durationText = {
                type   = "group",
                name   = "Duration Text",
                order  = 1,
                hidden = notGlobal,
                args   = {
                    _subcatTracker = makeSubcatTracker("global"),
                    durationTextHeader = { type = "header", name = "Duration Text", order = 1 },
                    globalDurationShow = {
                        type = "toggle", name = "Show Duration Text", order = 2,
                        desc = "Show duration text on Buffs, Debuffs, Big Defensives, and Private Auras.",
                        get  = getAT_, set = setAT,
                        disabled = InCombatLockdown,
                    },
                    globalAutoScale = {
                        type = "toggle", name = "Auto Scale Duration Text", order = 2.5,
                        desc = "When enabled, duration text size scales proportionally with the aura icon size. Use the scale slider to fine-tune. When disabled, a fixed font size is used instead.",
                        get = getAT_, set = setAT,
                        disabled = function() return InCombatLockdown() or globalDurationHidden() end,
                    },
                    globalTimerScale = {
                        type = "range", name = "Duration Text Scale", order = 3,
                        min = 0.1, max = 3.0, step = 0.1,
                        hidden = function()
                            local g = getATSub("global") or {}
                            return g.globalAutoScale ~= true
                        end,
                        get = getAT_, set = setAT,
                        disabled = function() return InCombatLockdown() or globalDurationHidden() end,
                    },
                    globalFontSize = {
                        type = "range", name = "Font Size", order = 3,
                        min = 6, max = 24, step = 1,
                        hidden = function()
                            local g = getATSub("global") or {}
                            return g.globalAutoScale == true
                        end,
                        get = getAT_, set = setAT,
                        disabled = function() return InCombatLockdown() or globalDurationHidden() end,
                    },
                    globalFontGroup = {
                        type = "group", name = "Font", inline = true, order = 3.6,
                        args = {
                            globalDurationFont = {
                                type = "select", name = "Font", order = 1,
                                disabled = InCombatLockdown,
                                values = lsmFontValues,
                                get = getAT_, set = setAT,
                            },
                            globalDurationBorder = {
                                type = "select", name = "Font Border", order = 2,
                                disabled = InCombatLockdown,
                                values = FONT_BORDER_VALUES,
                                get = getAT_, set = setAT,
                            },
                        },
                    },
                    globalHideDurationAbove1Min = {
                        type = "toggle", name = "Hide Duration Text Above 1 Minute", order = 3.61, width = "full",
                        desc = "When enabled, the duration text is hidden when the remaining time is above 59 seconds.",
                        get = getAT_, set = setAT_Threshold,
                        disabled = function() return InCombatLockdown() or globalDurationHidden() end,
                        hidden = globalDurationHidden,
                    },
                    thresholdColorGroup = {
                        type = "group", name = "Duration Text Color", inline = true, order = 3.7,
                        hidden = globalDurationHidden,
                        args = {
                            globalFontColor = {
                                type = "color", name = "Duration Text Color", order = 0.1, hasAlpha = true,
                                desc = "Color of the duration timer text. When Threshold Color is enabled, this is the color used above the threshold.",
                                get = getColor, set = setColor_Threshold,
                                disabled = function() return InCombatLockdown() or globalDurationHidden() end,
                            },
                            globalColorAuraBorder = {
                                type = "toggle", name = "Also Color Buff Borders", order = 0.2,
                                desc = "When enabled, the buff icon border uses the Font Color. If Threshold Color is also enabled, the border uses the threshold colors below the threshold and the Font Color above it. Does not apply to debuff borders.",
                                get = getAT_, set = setAT_Threshold,
                                disabled = function() return InCombatLockdown() or globalDurationHidden() end,
                            },
                            globalDebuffDurationDispelColor = {
                                type = "toggle", name = "Use Dispel Type Color for Debuff Duration Text", order = 0.3, width = 1.5,
                                desc = "When enabled, debuff duration text is colored to match the dispel type (Magic, Curse, Disease, Poison, etc.).\n\nThis option cannot be enabled while 'Hide Duration Text Above 1 Minute' is active, as it is not possible for both options to work simultaneously.",
                                get = getAT_, set = function(info, val)
                                    if InCombatLockdown() or globalDurationHidden() then return end
                                    if val then
                                        local g = getATSub("global") or {}
                                        if g.globalHideDurationAbove1Min then
                                            setATKey(info, false)
                                            DispatchRefreshForKey(info and info[#info])
                                            RefreshPreviewForSubcat("global")
                                            return
                                        end
                                    end
                                    setAT(info, val)
                                end,
                                disabled = function() return InCombatLockdown() or globalDurationHidden() end,
                            },
                            globalThresholdColorEnabled = {
                                type = "toggle", name = "Change Color based on Remaining Time", order = 1, width = "full",
                                desc = "When enabled, the duration text changes color when the remaining duration falls below the threshold.",
                                get = getAT_, set = setAT_Threshold,
                                disabled = function() return InCombatLockdown() or globalDurationHidden() end,
                            },
                            globalThresholdColor = {
                                type = "color", name = "Threshold Color", order = 2, hasAlpha = true,
                                get = getColor, set = setColor_Threshold,
                                disabled = function()
                                    local g = getATSub("global") or {}
                                    return InCombatLockdown() or not g.globalThresholdColorEnabled or globalDurationHidden()
                                end,
                                hidden = function()
                                    local g = getATSub("global") or {}
                                    return not g.globalThresholdColorEnabled
                                end,
                            },
                            globalThresholdColorThreshold = {
                                type = "range", name = "Threshold (seconds)", order = 3,
                                min = 1, max = 59, step = 1,
                                get = getAT_, set = setAT_Threshold,
                                disabled = function()
                                    local g = getATSub("global") or {}
                                    return InCombatLockdown() or not g.globalThresholdColorEnabled or globalDurationHidden()
                                end,
                                hidden = function()
                                    local g = getATSub("global") or {}
                                    return not g.globalThresholdColorEnabled
                                end,
                            },
                            globalThreshold2ColorEnabled = {
                                type = "toggle", name = "Enable Secondary Threshold", order = 4, width = "full",
                                desc = "When enabled, a second color is applied when the remaining duration falls below a lower threshold.",
                                get = getAT_, set = setAT_Threshold,
                                disabled = function()
                                    local g = getATSub("global") or {}
                                    return InCombatLockdown() or not g.globalThresholdColorEnabled or globalDurationHidden()
                                end,
                                hidden = function()
                                    local g = getATSub("global") or {}
                                    return not g.globalThresholdColorEnabled
                                end,
                            },
                            globalThreshold2Color = {
                                type = "color", name = "Secondary Threshold Color", order = 5, hasAlpha = true,
                                get = getColor, set = setColor_Threshold,
                                disabled = function()
                                    local g = getATSub("global") or {}
                                    return InCombatLockdown() or not g.globalThreshold2ColorEnabled or not g.globalThresholdColorEnabled
                                end,
                                hidden = function()
                                    local g = getATSub("global") or {}
                                    return not g.globalThreshold2ColorEnabled or not g.globalThresholdColorEnabled
                                end,
                            },
                            globalThreshold2ColorThreshold = {
                                type = "range", name = "Secondary Threshold (seconds)", order = 6,
                                min = 1, max = 59, step = 1,
                                get = function()
                                    local g = getATSub("global") or {}
                                    local limit = math.max(1, (g.globalThresholdColorThreshold or 8) - 1)
                                    return math.min(g.globalThreshold2ColorThreshold or 4, limit)
                                end,
                                set = function(info, val)
                                    if InCombatLockdown() then return end
                                    local g = getATSub("global") or {}
                                    local limit = math.max(1, (g.globalThresholdColorThreshold or 8) - 1)
                                    setATKey(info, math.min(val, limit))
                                    ThresholdRefreshDebouncedFor(info)
                                end,
                                disabled = function()
                                    local g = getATSub("global") or {}
                                    return InCombatLockdown() or not g.globalThreshold2ColorEnabled or not g.globalThresholdColorEnabled
                                end,
                                hidden = function()
                                    local g = getATSub("global") or {}
                                    return not g.globalThreshold2ColorEnabled or not g.globalThresholdColorEnabled
                                end,
                            },
                        },
                    },
                    cooldownSwipeGroup = {
                        type = "group", name = "Cooldown Swipe", inline = true, order = 0.1,
                        args = {
                            globalShowSwipe = {
                                -- UI: "Show Cooldown Swipe"; storage: globalDisableSwipe (inverted)
                                type = "toggle", name = "Show Cooldown Swipe", order = 1,
                                get = function()
                                    local g = getATSub("global") or {}
                                    return not (g.globalDisableSwipe or false)
                                end,
                                set = function(_, val)
                                    if InCombatLockdown() then return end
                                    setATKey({ [1] = "globalDisableSwipe", n = 1 }, not val)
                                    DispatchRefreshForKey("globalDisableSwipe")
                                    RefreshPreviewForSubcat("global")
                                end,
                                disabled = InCombatLockdown,
                            },
                            globalReverseSwipe = {
                                type   = "toggle", name = "Reverse Swipe Direction", order = 2,
                                hidden = function()
                                    local g = getATSub("global") or {}
                                    return g.globalDisableSwipe or false
                                end,
                                get = getAT_, set = setAT,
                                disabled = InCombatLockdown,
                            },
                            globalShowSpark = {
                                type = "toggle", name = "Show Cooldown Spark", order = 3,
                                get = function()
                                    local g = getATSub("global") or {}
                                    return not (g.globalDisableSpark or false)
                                end,
                                set = function(_, val)
                                    if InCombatLockdown() then return end
                                    setATKey({ [1] = "globalDisableSpark", n = 1 }, not val)
                                    DispatchRefreshForKey("globalDisableSpark")
                                    RefreshPreviewForSubcat("global")
                                end,
                                disabled = InCombatLockdown,
                            },
                        },
                    },
                },
            },

            -- ── Per-type tabs (shown when globalAuraTextConfig is OFF) ───────
            buffDurationText = {
                type   = "group",
                name   = "Buff Duration Text",
                order  = 1,
                hidden = isGlobal,
                args   = {
                    _subcatTracker = makeSubcatTracker("buffs"),
                    durationTextHeader = { type = "header", name = "Duration Text", order = 1 },
                    showBuffDuration = {
                        type = "toggle", name = "Show Duration Text", order = 2,
                        get = getAT_, set = setAT,
                        disabled = InCombatLockdown,
                    },
                    buffAutoScale = {
                        type = "toggle", name = "Auto Scale Duration Text", order = 2.5,
                        desc = "When enabled, duration text size scales proportionally with the aura icon size. Use the scale slider to fine-tune. When disabled, a fixed font size is used instead.",
                        hidden = buffDurationHidden,
                        get = getAT_, set = setAT,
                        disabled = function() return InCombatLockdown() or buffDurationHidden() end,
                    },
                    buffTimerScale = {
                        type = "range", name = "Duration Text Scale", order = 3,
                        min = 0.1, max = 3.0, step = 0.1,
                        hidden = function()
                            local b = getATSub("buffs") or {}
                            return buffDurationHidden() or b.buffAutoScale ~= true
                        end,
                        get = getAT_, set = setAT,
                        disabled = function() return InCombatLockdown() or buffDurationHidden() end,
                    },
                    buffFontSize = {
                        type = "range", name = "Font Size", order = 3,
                        min = 6, max = 24, step = 1,
                        hidden = function()
                            local b = getATSub("buffs") or {}
                            return buffDurationHidden() or b.buffAutoScale == true
                        end,
                        get = getAT_, set = setAT,
                        disabled = function() return InCombatLockdown() or buffDurationHidden() end,
                    },
                    buffFontGroup = {
                        type = "group", name = "Font", inline = true, order = 3.6,
                        hidden = buffDurationHidden,
                        args = {
                            buffDurationFont = {
                                type = "select", name = "Font", order = 1,
                                disabled = InCombatLockdown,
                                values = lsmFontValues,
                                get = getAT_, set = setAT,
                            },
                            buffDurationBorder = {
                                type = "select", name = "Font Border", order = 2,
                                disabled = InCombatLockdown,
                                values = FONT_BORDER_VALUES,
                                get = getAT_, set = setAT,
                            },
                        },
                    },
                    buffHideDurationAbove1Min = {
                        type = "toggle", name = "Hide Duration Text Above 1 Minute", order = 3.61, width = "full",
                        desc = "When enabled, the duration text is hidden when the remaining time is above 59 seconds.",
                        get = getAT_, set = setAT_Threshold,
                        disabled = function() return InCombatLockdown() or buffDurationHidden() end,
                        hidden = buffDurationHidden,
                    },
                    thresholdColorGroup = {
                        type = "group", name = "Duration Text Color", inline = true, order = 3.7,
                        hidden = buffDurationHidden,
                        args = {
                            buffFontColor = {
                                type = "color", name = "Duration Text Color", order = 0.1, hasAlpha = true,
                                desc = "Color of the buff duration timer text. When Threshold Color is enabled, this is the color used above the threshold.",
                                get = getColor, set = setColor_Threshold,
                                disabled = function() return InCombatLockdown() or buffDurationHidden() end,
                            },
                            buffColorAuraBorder = {
                                type = "toggle", name = "Also Color Aura Borders", order = 0.2,
                                desc = "When enabled, the buff icon border uses the Font Color. If Threshold Color is also enabled, the border uses the threshold colors below the threshold and the Font Color above it.",
                                get = getAT_, set = setAT_Threshold,
                                disabled = function() return InCombatLockdown() or buffDurationHidden() end,
                            },
                            buffThresholdColorEnabled = {
                                type = "toggle", name = "Change Color based on Remaining Time", order = 1, width = "full",
                                desc = "When enabled, the duration text changes color when the remaining duration falls below the threshold.",
                                get = getAT_, set = setAT_Threshold,
                                disabled = function() return InCombatLockdown() or buffDurationHidden() end,
                            },
                            buffThresholdColor = {
                                type = "color", name = "Threshold Color", order = 2, hasAlpha = true,
                                get = getColor, set = setColor_Threshold,
                                disabled = function()
                                    local b = getATSub("buffs") or {}
                                    return InCombatLockdown() or not b.buffThresholdColorEnabled or buffDurationHidden()
                                end,
                                hidden = function()
                                    local b = getATSub("buffs") or {}
                                    return not b.buffThresholdColorEnabled
                                end,
                            },
                            buffThresholdColorThreshold = {
                                type = "range", name = "Threshold (seconds)", order = 3,
                                min = 1, max = 59, step = 1,
                                get = getAT_, set = setAT_Threshold,
                                disabled = function()
                                    local b = getATSub("buffs") or {}
                                    return InCombatLockdown() or not b.buffThresholdColorEnabled or buffDurationHidden()
                                end,
                                hidden = function()
                                    local b = getATSub("buffs") or {}
                                    return not b.buffThresholdColorEnabled
                                end,
                            },
                            buffThreshold2ColorEnabled = {
                                type = "toggle", name = "Enable Secondary Threshold", order = 4, width = "full",
                                desc = "When enabled, a second color is applied when the remaining duration falls below a lower threshold.",
                                get = getAT_, set = setAT_Threshold,
                                disabled = function()
                                    local b = getATSub("buffs") or {}
                                    return InCombatLockdown() or not b.buffThresholdColorEnabled or buffDurationHidden()
                                end,
                                hidden = function()
                                    local b = getATSub("buffs") or {}
                                    return not b.buffThresholdColorEnabled
                                end,
                            },
                            buffThreshold2Color = {
                                type = "color", name = "Secondary Threshold Color", order = 5, hasAlpha = true,
                                get = getColor, set = setColor_Threshold,
                                disabled = function()
                                    local b = getATSub("buffs") or {}
                                    return InCombatLockdown() or not b.buffThreshold2ColorEnabled or not b.buffThresholdColorEnabled
                                end,
                                hidden = function()
                                    local b = getATSub("buffs") or {}
                                    return not b.buffThreshold2ColorEnabled or not b.buffThresholdColorEnabled
                                end,
                            },
                            buffThreshold2ColorThreshold = {
                                type = "range", name = "Secondary Threshold (seconds)", order = 6,
                                min = 1, max = 59, step = 1,
                                get = function()
                                    local b = getATSub("buffs") or {}
                                    local limit = math.max(1, (b.buffThresholdColorThreshold or 8) - 1)
                                    return math.min(b.buffThreshold2ColorThreshold or 4, limit)
                                end,
                                set = function(info, val)
                                    if InCombatLockdown() then return end
                                    local b = getATSub("buffs") or {}
                                    local limit = math.max(1, (b.buffThresholdColorThreshold or 8) - 1)
                                    setATKey(info, math.min(val, limit))
                                    ThresholdRefreshDebouncedFor(info)
                                end,
                                disabled = function()
                                    local b = getATSub("buffs") or {}
                                    return InCombatLockdown() or not b.buffThreshold2ColorEnabled or not b.buffThresholdColorEnabled
                                end,
                                hidden = function()
                                    local b = getATSub("buffs") or {}
                                    return not b.buffThreshold2ColorEnabled or not b.buffThresholdColorEnabled
                                end,
                            },
                        },
                    },
                    cooldownSwipeGroup = {
                        type = "group", name = "Cooldown Swipe", inline = true, order = 0.1,
                        args = {
                            showBuffSwipe = {
                                type = "toggle", name = "Show Cooldown Swipe", order = 1,
                                get = function()
                                    local b = getATSub("buffs") or {}
                                    return not (b.disableBuffSwipe or false)
                                end,
                                set = function(_, val)
                                    if InCombatLockdown() then return end
                                    setATKey({ [1] = "disableBuffSwipe", n = 1 }, not val)
                                    DispatchRefreshForKey("disableBuffSwipe")
                                    RefreshPreviewForSubcat("buffs")
                                end,
                                disabled = InCombatLockdown,
                            },
                            reverseBuffSwipe = {
                                type   = "toggle", name = "Reverse Swipe Direction", order = 2,
                                hidden = function()
                                    local b = getATSub("buffs") or {}
                                    return b.disableBuffSwipe or false
                                end,
                                get = getAT_, set = setAT,
                                disabled = InCombatLockdown,
                            },
                            showBuffSpark = {
                                type = "toggle", name = "Show Cooldown Spark", order = 3,
                                get = function()
                                    local b = getATSub("buffs") or {}
                                    return not (b.disableBuffSpark or false)
                                end,
                                set = function(_, val)
                                    if InCombatLockdown() then return end
                                    setATKey({ [1] = "disableBuffSpark", n = 1 }, not val)
                                    DispatchRefreshForKey("disableBuffSpark")
                                    RefreshPreviewForSubcat("buffs")
                                end,
                                disabled = InCombatLockdown,
                            },
                        },
                    },
                },
            },

            debuffDurationText = {
                type   = "group",
                name   = "Debuff Duration Text",
                order  = 2,
                hidden = isGlobal,
                args   = {
                    _subcatTracker = makeSubcatTracker("debuffs"),
                    durationTextHeader = { type = "header", name = "Duration Text", order = 1 },
                    showDebuffDuration = {
                        type = "toggle", name = "Show Duration Text", order = 2,
                        get = getAT_, set = setAT,
                        disabled = InCombatLockdown,
                    },
                    debuffAutoScale = {
                        type = "toggle", name = "Auto Scale Duration Text", order = 2.5,
                        desc = "When enabled, duration text size scales proportionally with the aura icon size. Use the scale slider to fine-tune. When disabled, a fixed font size is used instead.",
                        hidden = debuffDurationHidden,
                        get = getAT_, set = setAT,
                        disabled = function() return InCombatLockdown() or debuffDurationHidden() end,
                    },
                    debuffTimerScale = {
                        type = "range", name = "Duration Text Scale", order = 3,
                        min = 0.1, max = 3.0, step = 0.1,
                        hidden = function()
                            local d = getATSub("debuffs") or {}
                            return debuffDurationHidden() or d.debuffAutoScale ~= true
                        end,
                        get = getAT_, set = setAT,
                        disabled = function() return InCombatLockdown() or debuffDurationHidden() end,
                    },
                    debuffFontSize = {
                        type = "range", name = "Font Size", order = 3,
                        min = 6, max = 24, step = 1,
                        hidden = function()
                            local d = getATSub("debuffs") or {}
                            return debuffDurationHidden() or d.debuffAutoScale == true
                        end,
                        get = getAT_, set = setAT,
                        disabled = function() return InCombatLockdown() or debuffDurationHidden() end,
                    },
                    debuffFontGroup = {
                        type = "group", name = "Font", inline = true, order = 3.6,
                        hidden = debuffDurationHidden,
                        args = {
                            debuffDurationFont = {
                                type = "select", name = "Font", order = 1,
                                disabled = InCombatLockdown,
                                values = lsmFontValues,
                                get = getAT_, set = setAT,
                            },
                            debuffDurationBorder = {
                                type = "select", name = "Font Border", order = 2,
                                disabled = InCombatLockdown,
                                values = FONT_BORDER_VALUES,
                                get = getAT_, set = setAT,
                            },
                        },
                    },
                    debuffHideDurationAbove1Min = {
                        type = "toggle", name = "Hide Duration Text Above 1 Minute", order = 3.61, width = "full",
                        desc = "When enabled, the duration text is hidden when the remaining time is above 59 seconds.",
                        get = getAT_, set = setAT_Threshold,
                        disabled = function() return InCombatLockdown() or debuffDurationHidden() end,
                        hidden = debuffDurationHidden,
                    },
                    thresholdColorGroup = {
                        type = "group", name = "Duration Text Color", inline = true, order = 3.7,
                        hidden = debuffDurationHidden,
                        args = {
                            debuffFontColor = {
                                type = "color", name = "Duration Text Color", order = 0.1, hasAlpha = true,
                                desc = "Color of the debuff duration timer text. When Threshold Color is enabled, this is the color used above the threshold. When 'Use Dispel Type Color' is enabled, the dispel color overrides this.",
                                get = getColor, set = setColor_Threshold,
                                disabled = function() return InCombatLockdown() or debuffDurationHidden() end,
                            },
                            debuffDurationDispelColor = {
                                type = "toggle", name = "Use Dispel Type Color for Duration Text", order = 0.2, width = 1.5,
                                desc = "When enabled, debuff duration text is colored to match the dispel type (Magic, Curse, Disease, Poison, etc.).\n\nThis option cannot be enabled while 'Hide Duration Text Above 1 Minute' is active, as it is not possible for both options to work simultaneously.",
                                get = getAT_, set = function(info, val)
                                    if InCombatLockdown() or debuffDurationHidden() then return end
                                    if val then
                                        local d = getATSub("debuffs") or {}
                                        if d.debuffHideDurationAbove1Min then
                                            setATKey(info, false)
                                            DispatchRefreshForKey(info and info[#info])
                                            RefreshPreviewForSubcat("debuffs")
                                            return
                                        end
                                    end
                                    setAT(info, val)
                                end,
                                disabled = function() return InCombatLockdown() or debuffDurationHidden() end,
                            },
                            debuffThresholdColorEnabled = {
                                type = "toggle", name = "Change Color based on Remaining Time", order = 1, width = "full",
                                desc = "When enabled, the duration text changes color when the remaining duration falls below the threshold.",
                                get = getAT_, set = setAT_Threshold,
                                disabled = function() return InCombatLockdown() or debuffDurationHidden() end,
                            },
                            debuffThresholdColor = {
                                type = "color", name = "Threshold Color", order = 2, hasAlpha = true,
                                get = getColor, set = setColor_Threshold,
                                disabled = function()
                                    local d = getATSub("debuffs") or {}
                                    return InCombatLockdown() or not d.debuffThresholdColorEnabled or debuffDurationHidden()
                                end,
                                hidden = function()
                                    local d = getATSub("debuffs") or {}
                                    return not d.debuffThresholdColorEnabled
                                end,
                            },
                            debuffThresholdColorThreshold = {
                                type = "range", name = "Threshold (seconds)", order = 3,
                                min = 1, max = 59, step = 1,
                                get = getAT_, set = setAT_Threshold,
                                disabled = function()
                                    local d = getATSub("debuffs") or {}
                                    return InCombatLockdown() or not d.debuffThresholdColorEnabled or debuffDurationHidden()
                                end,
                                hidden = function()
                                    local d = getATSub("debuffs") or {}
                                    return not d.debuffThresholdColorEnabled
                                end,
                            },
                            debuffThreshold2ColorEnabled = {
                                type = "toggle", name = "Enable Secondary Threshold", order = 4, width = "full",
                                desc = "When enabled, a second color is applied when the remaining duration falls below a lower threshold.",
                                get = getAT_, set = setAT_Threshold,
                                disabled = function()
                                    local d = getATSub("debuffs") or {}
                                    return InCombatLockdown() or not d.debuffThresholdColorEnabled or debuffDurationHidden()
                                end,
                                hidden = function()
                                    local d = getATSub("debuffs") or {}
                                    return not d.debuffThresholdColorEnabled
                                end,
                            },
                            debuffThreshold2Color = {
                                type = "color", name = "Secondary Threshold Color", order = 5, hasAlpha = true,
                                get = getColor, set = setColor_Threshold,
                                disabled = function()
                                    local d = getATSub("debuffs") or {}
                                    return InCombatLockdown() or not d.debuffThreshold2ColorEnabled or not d.debuffThresholdColorEnabled
                                end,
                                hidden = function()
                                    local d = getATSub("debuffs") or {}
                                    return not d.debuffThreshold2ColorEnabled or not d.debuffThresholdColorEnabled
                                end,
                            },
                            debuffThreshold2ColorThreshold = {
                                type = "range", name = "Secondary Threshold (seconds)", order = 6,
                                min = 1, max = 59, step = 1,
                                get = function()
                                    local d = getATSub("debuffs") or {}
                                    local limit = math.max(1, (d.debuffThresholdColorThreshold or 8) - 1)
                                    return math.min(d.debuffThreshold2ColorThreshold or 4, limit)
                                end,
                                set = function(info, val)
                                    if InCombatLockdown() then return end
                                    local d = getATSub("debuffs") or {}
                                    local limit = math.max(1, (d.debuffThresholdColorThreshold or 8) - 1)
                                    setATKey(info, math.min(val, limit))
                                    ThresholdRefreshDebouncedFor(info)
                                end,
                                disabled = function()
                                    local d = getATSub("debuffs") or {}
                                    return InCombatLockdown() or not d.debuffThreshold2ColorEnabled or not d.debuffThresholdColorEnabled
                                end,
                                hidden = function()
                                    local d = getATSub("debuffs") or {}
                                    return not d.debuffThreshold2ColorEnabled or not d.debuffThresholdColorEnabled
                                end,
                            },
                            debuffThresholdBorderEnabled = {
                                type = "toggle", name = "Also Apply to Aura Border", order = 7, width = "full",
                                desc = "Removed - debuff threshold borders have been removed for performance.",
                                get = function() return false end,
                                set = function() end,
                                hidden = true,
                            },
                        },
                    },
                    cooldownSwipeGroup = {
                        type = "group", name = "Cooldown Swipe", inline = true, order = 0.1,
                        args = {
                            showDebuffSwipe = {
                                type = "toggle", name = "Show Cooldown Swipe", order = 1,
                                get = function()
                                    local d = getATSub("debuffs") or {}
                                    return not (d.disableDebuffSwipe or false)
                                end,
                                set = function(_, val)
                                    if InCombatLockdown() then return end
                                    setATKey({ [1] = "disableDebuffSwipe", n = 1 }, not val)
                                    DispatchRefreshForKey("disableDebuffSwipe")
                                    RefreshPreviewForSubcat("debuffs")
                                end,
                                disabled = InCombatLockdown,
                            },
                            reverseDebuffSwipe = {
                                type   = "toggle", name = "Reverse Swipe Direction", order = 2,
                                hidden = function()
                                    local d = getATSub("debuffs") or {}
                                    return d.disableDebuffSwipe or false
                                end,
                                get = getAT_, set = setAT,
                                disabled = InCombatLockdown,
                            },
                            showDebuffSpark = {
                                type = "toggle", name = "Show Cooldown Spark", order = 3,
                                get = function()
                                    local d = getATSub("debuffs") or {}
                                    return not (d.disableDebuffSpark or false)
                                end,
                                set = function(_, val)
                                    if InCombatLockdown() then return end
                                    setATKey({ [1] = "disableDebuffSpark", n = 1 }, not val)
                                    DispatchRefreshForKey("disableDebuffSpark")
                                    RefreshPreviewForSubcat("debuffs")
                                end,
                                disabled = InCombatLockdown,
                            },
                        },
                    },
                },
            },

            bigDefDurationText = {
                type   = "group",
                name   = "Big Defensive Duration Text",
                order  = 3,
                hidden = isGlobal,
                args   = {
                    _subcatTracker = makeSubcatTracker("bigDef"),
                    durationTextHeader = { type = "header", name = "Duration Text", order = 1 },
                    showBigDefDuration = {
                        type = "toggle", name = "Show Duration Text", order = 2,
                        get = getAT_, set = setAT,
                        disabled = InCombatLockdown,
                    },
                    bigDefAutoScale = {
                        type = "toggle", name = "Auto Scale Duration Text", order = 2.5,
                        desc = "When enabled, duration text size scales proportionally with the aura icon size. Use the scale slider to fine-tune. When disabled, a fixed font size is used instead.",
                        hidden = bigDefDurationHidden,
                        get = getAT_, set = setAT,
                        disabled = function() return InCombatLockdown() or bigDefDurationHidden() end,
                    },
                    bigDefTimerScale = {
                        type = "range", name = "Duration Text Scale", order = 3,
                        min = 0.1, max = 3.0, step = 0.1,
                        hidden = function()
                            local b = getATSub("bigDef") or {}
                            return bigDefDurationHidden() or b.bigDefAutoScale ~= true
                        end,
                        get = getAT_, set = setAT,
                        disabled = function() return InCombatLockdown() or bigDefDurationHidden() end,
                    },
                    bigDefFontSize = {
                        type = "range", name = "Font Size", order = 3,
                        min = 6, max = 24, step = 1,
                        hidden = function()
                            local b = getATSub("bigDef") or {}
                            return bigDefDurationHidden() or b.bigDefAutoScale == true
                        end,
                        get = getAT_, set = setAT,
                        disabled = function() return InCombatLockdown() or bigDefDurationHidden() end,
                    },
                    bigDefFontGroup = {
                        type = "group", name = "Font", inline = true, order = 3.6,
                        hidden = bigDefDurationHidden,
                        args = {
                            bigDefDurationFont = {
                                type = "select", name = "Font", order = 1,
                                disabled = InCombatLockdown,
                                values = lsmFontValues,
                                get = getAT_, set = setAT,
                            },
                            bigDefDurationBorder = {
                                type = "select", name = "Font Border", order = 2,
                                disabled = InCombatLockdown,
                                values = FONT_BORDER_VALUES,
                                get = getAT_, set = setAT,
                            },
                        },
                    },
                    bigDefHideDurationAbove1Min = {
                        type = "toggle", name = "Hide Duration Text Above 1 Minute", order = 3.61, width = "full",
                        desc = "When enabled, the duration text is hidden when the remaining time is above 59 seconds.",
                        get = getAT_, set = setAT_Threshold,
                        disabled = function() return InCombatLockdown() or bigDefDurationHidden() end,
                        hidden = bigDefDurationHidden,
                    },
                    thresholdColorGroup = {
                        type = "group", name = "Duration Text Color", inline = true, order = 3.7,
                        hidden = bigDefDurationHidden,
                        args = {
                            bigDefFontColor = {
                                type = "color", name = "Duration Text Color", order = 0.1, hasAlpha = true,
                                desc = "Color of the big defensive duration timer text. When Threshold Color is enabled, this is the color used above the threshold.",
                                get = getColor, set = setColor_Threshold,
                                disabled = function() return InCombatLockdown() or bigDefDurationHidden() end,
                            },
                            bigDefColorAuraBorder = {
                                type = "toggle", name = "Also Color Aura Borders", order = 0.2,
                                desc = "When enabled, the big defensive icon border uses the Font Color. If Threshold Color is also enabled, the border uses the threshold colors below the threshold and the Font Color above it.",
                                get = getAT_, set = setAT_Threshold,
                                disabled = function() return InCombatLockdown() or bigDefDurationHidden() end,
                            },
                            bigDefThresholdColorEnabled = {
                                type = "toggle", name = "Change Color based on Remaining Time", order = 1, width = "full",
                                desc = "When enabled, the duration text changes color when the remaining duration falls below the threshold.",
                                get = getAT_, set = setAT_Threshold,
                                disabled = function() return InCombatLockdown() or bigDefDurationHidden() end,
                            },
                            bigDefThresholdColor = {
                                type = "color", name = "Threshold Color", order = 2, hasAlpha = true,
                                get = getColor, set = setColor_Threshold,
                                disabled = function()
                                    local b = getATSub("bigDef") or {}
                                    return InCombatLockdown() or not b.bigDefThresholdColorEnabled or bigDefDurationHidden()
                                end,
                                hidden = function()
                                    local b = getATSub("bigDef") or {}
                                    return not b.bigDefThresholdColorEnabled
                                end,
                            },
                            bigDefThresholdColorThreshold = {
                                type = "range", name = "Threshold (seconds)", order = 3,
                                min = 1, max = 59, step = 1,
                                get = getAT_, set = setAT_Threshold,
                                disabled = function()
                                    local b = getATSub("bigDef") or {}
                                    return InCombatLockdown() or not b.bigDefThresholdColorEnabled or bigDefDurationHidden()
                                end,
                                hidden = function()
                                    local b = getATSub("bigDef") or {}
                                    return not b.bigDefThresholdColorEnabled
                                end,
                            },
                            bigDefThreshold2ColorEnabled = {
                                type = "toggle", name = "Enable Secondary Threshold", order = 4, width = "full",
                                desc = "When enabled, a second color is applied when the remaining duration falls below a lower threshold.",
                                get = getAT_, set = setAT_Threshold,
                                disabled = function()
                                    local b = getATSub("bigDef") or {}
                                    return InCombatLockdown() or not b.bigDefThresholdColorEnabled or bigDefDurationHidden()
                                end,
                                hidden = function()
                                    local b = getATSub("bigDef") or {}
                                    return not b.bigDefThresholdColorEnabled
                                end,
                            },
                            bigDefThreshold2Color = {
                                type = "color", name = "Secondary Threshold Color", order = 5, hasAlpha = true,
                                get = getColor, set = setColor_Threshold,
                                disabled = function()
                                    local b = getATSub("bigDef") or {}
                                    return InCombatLockdown() or not b.bigDefThreshold2ColorEnabled or not b.bigDefThresholdColorEnabled
                                end,
                                hidden = function()
                                    local b = getATSub("bigDef") or {}
                                    return not b.bigDefThreshold2ColorEnabled or not b.bigDefThresholdColorEnabled
                                end,
                            },
                            bigDefThreshold2ColorThreshold = {
                                type = "range", name = "Secondary Threshold (seconds)", order = 6,
                                min = 1, max = 59, step = 1,
                                get = function()
                                    local b = getATSub("bigDef") or {}
                                    local limit = math.max(1, (b.bigDefThresholdColorThreshold or 8) - 1)
                                    return math.min(b.bigDefThreshold2ColorThreshold or 4, limit)
                                end,
                                set = function(info, val)
                                    if InCombatLockdown() then return end
                                    local b = getATSub("bigDef") or {}
                                    local limit = math.max(1, (b.bigDefThresholdColorThreshold or 8) - 1)
                                    setATKey(info, math.min(val, limit))
                                    ThresholdRefreshDebouncedFor(info)
                                end,
                                disabled = function()
                                    local b = getATSub("bigDef") or {}
                                    return InCombatLockdown() or not b.bigDefThreshold2ColorEnabled or not b.bigDefThresholdColorEnabled
                                end,
                                hidden = function()
                                    local b = getATSub("bigDef") or {}
                                    return not b.bigDefThreshold2ColorEnabled or not b.bigDefThresholdColorEnabled
                                end,
                            },
                        },
                    },
                    cooldownSwipeGroup = {
                        type = "group", name = "Cooldown Swipe", inline = true, order = 0.1,
                        args = {
                            showBigDefSwipe = {
                                type = "toggle", name = "Show Cooldown Swipe", order = 1,
                                get = function()
                                    local b = getATSub("bigDef") or {}
                                    return not (b.disableBigDefSwipe or false)
                                end,
                                set = function(_, val)
                                    if InCombatLockdown() then return end
                                    setATKey({ [1] = "disableBigDefSwipe", n = 1 }, not val)
                                    DispatchRefreshForKey("disableBigDefSwipe")
                                    RefreshPreviewForSubcat("bigDef")
                                end,
                                disabled = InCombatLockdown,
                            },
                            reverseBigDefSwipe = {
                                type   = "toggle", name = "Reverse Swipe Direction", order = 2,
                                hidden = function()
                                    local b = getATSub("bigDef") or {}
                                    return b.disableBigDefSwipe or false
                                end,
                                get = getAT_, set = setAT,
                                disabled = InCombatLockdown,
                            },
                            showBigDefSpark = {
                                type = "toggle", name = "Show Cooldown Spark", order = 3,
                                get = function()
                                    local b = getATSub("bigDef") or {}
                                    return not (b.disableBigDefSpark or false)
                                end,
                                set = function(_, val)
                                    if InCombatLockdown() then return end
                                    setATKey({ [1] = "disableBigDefSpark", n = 1 }, not val)
                                    DispatchRefreshForKey("disableBigDefSpark")
                                    RefreshPreviewForSubcat("bigDef")
                                end,
                                disabled = InCombatLockdown,
                            },
                        },
                    },
                },
            },

            importantDurationText = {
                type   = "group",
                name   = "Important Aura Duration Text",
                order  = 3.5,
                hidden = isGlobal,
                args   = {
                    _subcatTracker = makeSubcatTracker("important"),
                    durationTextHeader = { type = "header", name = "Duration Text", order = 1 },
                    showImportantDuration = {
                        type = "toggle", name = "Show Duration Text", order = 2,
                        get = getAT_, set = setAT,
                        disabled = InCombatLockdown,
                    },
                    importantAutoScale = {
                        type = "toggle", name = "Auto Scale Duration Text", order = 2.5,
                        desc = "When enabled, duration text size scales proportionally with the aura icon size. Use the scale slider to fine-tune. When disabled, a fixed font size is used instead.",
                        hidden = importantDurationHidden,
                        get = getAT_, set = setAT,
                        disabled = function() return InCombatLockdown() or importantDurationHidden() end,
                    },
                    importantTimerScale = {
                        type = "range", name = "Duration Text Scale", order = 3,
                        min = 0.1, max = 3.0, step = 0.1,
                        hidden = function()
                            local i = getATSub("important") or {}
                            return importantDurationHidden() or i.importantAutoScale ~= true
                        end,
                        get = getAT_, set = setAT,
                        disabled = function() return InCombatLockdown() or importantDurationHidden() end,
                    },
                    importantFontSize = {
                        type = "range", name = "Font Size", order = 3,
                        min = 6, max = 24, step = 1,
                        hidden = function()
                            local i = getATSub("important") or {}
                            return importantDurationHidden() or i.importantAutoScale == true
                        end,
                        get = getAT_, set = setAT,
                        disabled = function() return InCombatLockdown() or importantDurationHidden() end,
                    },
                    importantFontGroup = {
                        type = "group", name = "Font", inline = true, order = 3.6,
                        hidden = importantDurationHidden,
                        args = {
                            importantDurationFont = {
                                type = "select", name = "Font", order = 1,
                                disabled = InCombatLockdown,
                                values = lsmFontValues,
                                get = getAT_, set = setAT,
                            },
                            importantDurationBorder = {
                                type = "select", name = "Font Border", order = 2,
                                disabled = InCombatLockdown,
                                values = FONT_BORDER_VALUES,
                                get = getAT_, set = setAT,
                            },
                        },
                    },
                    importantHideDurationAbove1Min = {
                        type = "toggle", name = "Hide Duration Text Above 1 Minute", order = 3.61, width = "full",
                        desc = "When enabled, the duration text is hidden when the remaining time is above 59 seconds.",
                        get = getAT_, set = setAT_Threshold,
                        disabled = function() return InCombatLockdown() or importantDurationHidden() end,
                        hidden = importantDurationHidden,
                    },
                    thresholdColorGroup = {
                        type = "group", name = "Duration Text Color", inline = true, order = 3.7,
                        hidden = importantDurationHidden,
                        args = {
                            importantFontColor = {
                                type = "color", name = "Duration Text Color", order = 0.1, hasAlpha = true,
                                desc = "Color of the important aura duration timer text. When Threshold Color is enabled, this is the color used above the threshold.",
                                get = getColor, set = setColor_Threshold,
                                disabled = function() return InCombatLockdown() or importantDurationHidden() end,
                            },
                            importantColorAuraBorder = {
                                type = "toggle", name = "Also Color Aura Borders", order = 0.2,
                                desc = "When enabled, the important aura icon border uses the Font Color. If Threshold Color is also enabled, the border uses the threshold colors below the threshold and the Font Color above it.",
                                get = getAT_, set = setAT_Threshold,
                                disabled = function() return InCombatLockdown() or importantDurationHidden() end,
                            },
                            importantThresholdColorEnabled = {
                                type = "toggle", name = "Change Color based on Remaining Time", order = 1, width = "full",
                                desc = "When enabled, the duration text changes color when the remaining duration falls below the threshold.",
                                get = getAT_, set = setAT_Threshold,
                                disabled = function() return InCombatLockdown() or importantDurationHidden() end,
                            },
                            importantThresholdColor = {
                                type = "color", name = "Threshold Color", order = 2, hasAlpha = true,
                                get = getColor, set = setColor_Threshold,
                                disabled = function()
                                    local i = getATSub("important") or {}
                                    return InCombatLockdown() or not i.importantThresholdColorEnabled or importantDurationHidden()
                                end,
                                hidden = function()
                                    local i = getATSub("important") or {}
                                    return not i.importantThresholdColorEnabled
                                end,
                            },
                            importantThresholdColorThreshold = {
                                type = "range", name = "Threshold (seconds)", order = 3,
                                min = 1, max = 59, step = 1,
                                get = getAT_, set = setAT_Threshold,
                                disabled = function()
                                    local i = getATSub("important") or {}
                                    return InCombatLockdown() or not i.importantThresholdColorEnabled or importantDurationHidden()
                                end,
                                hidden = function()
                                    local i = getATSub("important") or {}
                                    return not i.importantThresholdColorEnabled
                                end,
                            },
                            importantThreshold2ColorEnabled = {
                                type = "toggle", name = "Enable Secondary Threshold", order = 4, width = "full",
                                desc = "When enabled, a second color is applied when the remaining duration falls below a lower threshold.",
                                get = getAT_, set = setAT_Threshold,
                                disabled = function()
                                    local i = getATSub("important") or {}
                                    return InCombatLockdown() or not i.importantThresholdColorEnabled or importantDurationHidden()
                                end,
                                hidden = function()
                                    local i = getATSub("important") or {}
                                    return not i.importantThresholdColorEnabled
                                end,
                            },
                            importantThreshold2Color = {
                                type = "color", name = "Secondary Threshold Color", order = 5, hasAlpha = true,
                                get = getColor, set = setColor_Threshold,
                                disabled = function()
                                    local i = getATSub("important") or {}
                                    return InCombatLockdown() or not i.importantThreshold2ColorEnabled or not i.importantThresholdColorEnabled
                                end,
                                hidden = function()
                                    local i = getATSub("important") or {}
                                    return not i.importantThreshold2ColorEnabled or not i.importantThresholdColorEnabled
                                end,
                            },
                            importantThreshold2ColorThreshold = {
                                type = "range", name = "Secondary Threshold (seconds)", order = 6,
                                min = 1, max = 59, step = 1,
                                get = function()
                                    local i = getATSub("important") or {}
                                    local limit = math.max(1, (i.importantThresholdColorThreshold or 8) - 1)
                                    return math.min(i.importantThreshold2ColorThreshold or 4, limit)
                                end,
                                set = function(info, val)
                                    if InCombatLockdown() then return end
                                    local i = getATSub("important") or {}
                                    local limit = math.max(1, (i.importantThresholdColorThreshold or 8) - 1)
                                    setATKey(info, math.min(val, limit))
                                    ThresholdRefreshDebouncedFor(info)
                                end,
                                disabled = function()
                                    local i = getATSub("important") or {}
                                    return InCombatLockdown() or not i.importantThreshold2ColorEnabled or not i.importantThresholdColorEnabled
                                end,
                                hidden = function()
                                    local i = getATSub("important") or {}
                                    return not i.importantThreshold2ColorEnabled or not i.importantThresholdColorEnabled
                                end,
                            },
                        },
                    },
                    cooldownSwipeGroup = {
                        type = "group", name = "Cooldown Swipe", inline = true, order = 0.1,
                        args = {
                            showImportantSwipe = {
                                type = "toggle", name = "Show Cooldown Swipe", order = 1,
                                get = function()
                                    local i = getATSub("important") or {}
                                    return not (i.disableImportantSwipe or false)
                                end,
                                set = function(_, val)
                                    if InCombatLockdown() then return end
                                    setATKey({ [1] = "disableImportantSwipe", n = 1 }, not val)
                                    DispatchRefreshForKey("disableImportantSwipe")
                                    RefreshPreviewForSubcat("important")
                                end,
                                disabled = InCombatLockdown,
                            },
                            reverseImportantSwipe = {
                                type   = "toggle", name = "Reverse Swipe Direction", order = 2,
                                hidden = function()
                                    local i = getATSub("important") or {}
                                    return i.disableImportantSwipe or false
                                end,
                                get = getAT_, set = setAT,
                                disabled = InCombatLockdown,
                            },
                            showImportantSpark = {
                                type = "toggle", name = "Show Cooldown Spark", order = 3,
                                get = function()
                                    local i = getATSub("important") or {}
                                    return not (i.disableImportantSpark or false)
                                end,
                                set = function(_, val)
                                    if InCombatLockdown() then return end
                                    setATKey({ [1] = "disableImportantSpark", n = 1 }, not val)
                                    DispatchRefreshForKey("disableImportantSpark")
                                    RefreshPreviewForSubcat("important")
                                end,
                                disabled = InCombatLockdown,
                            },
                        },
                    },
                },
            },

            crowdControlDurationText = {
                type   = "group",
                name   = "Crowd Control Duration Text",
                order  = 3.7,
                hidden = isGlobal,
                args   = {
                    _subcatTracker = makeSubcatTracker("crowdControl"),
                    durationTextHeader = { type = "header", name = "Duration Text", order = 1 },
                    showCrowdControlDuration = {
                        type = "toggle", name = "Show Duration Text", order = 2,
                        get = getAT_, set = setAT,
                        disabled = InCombatLockdown,
                    },
                    crowdControlAutoScale = {
                        type = "toggle", name = "Auto Scale Duration Text", order = 2.5,
                        desc = "When enabled, duration text size scales proportionally with the aura icon size. Use the scale slider to fine-tune. When disabled, a fixed font size is used instead.",
                        hidden = crowdControlDurationHidden,
                        get = getAT_, set = setAT,
                        disabled = function() return InCombatLockdown() or crowdControlDurationHidden() end,
                    },
                    crowdControlTimerScale = {
                        type = "range", name = "Duration Text Scale", order = 3,
                        min = 0.1, max = 3.0, step = 0.1,
                        hidden = function()
                            local c = getATSub("crowdControl") or {}
                            return crowdControlDurationHidden() or c.crowdControlAutoScale ~= true
                        end,
                        get = getAT_, set = setAT,
                        disabled = function() return InCombatLockdown() or crowdControlDurationHidden() end,
                    },
                    crowdControlFontSize = {
                        type = "range", name = "Font Size", order = 3,
                        min = 6, max = 24, step = 1,
                        hidden = function()
                            local c = getATSub("crowdControl") or {}
                            return crowdControlDurationHidden() or c.crowdControlAutoScale == true
                        end,
                        get = getAT_, set = setAT,
                        disabled = function() return InCombatLockdown() or crowdControlDurationHidden() end,
                    },
                    crowdControlFontGroup = {
                        type = "group", name = "Font", inline = true, order = 3.6,
                        hidden = crowdControlDurationHidden,
                        args = {
                            crowdControlDurationFont = {
                                type = "select", name = "Font", order = 1,
                                disabled = InCombatLockdown,
                                values = lsmFontValues,
                                get = getAT_, set = setAT,
                            },
                            crowdControlDurationBorder = {
                                type = "select", name = "Font Border", order = 2,
                                disabled = InCombatLockdown,
                                values = FONT_BORDER_VALUES,
                                get = getAT_, set = setAT,
                            },
                            crowdControlFontColor = {
                                type = "color", name = "Duration Text Color", order = 3, hasAlpha = true,
                                desc = "Color of the crowd control duration timer text.",
                                get = getColor, set = setColor_Threshold,
                                disabled = function() return InCombatLockdown() or crowdControlDurationHidden() end,
                            },
                        },
                    },
                    crowdControlHideDurationAbove1Min = {
                        type = "toggle", name = "Hide Duration Text Above 1 Minute", order = 3.61, width = "full",
                        desc = "When enabled, the duration text is hidden when the remaining time is above 59 seconds.",
                        get = getAT_, set = setAT_Threshold,
                        disabled = function() return InCombatLockdown() or crowdControlDurationHidden() end,
                        hidden = crowdControlDurationHidden,
                    },
                    cooldownSwipeGroup = {
                        type = "group", name = "Cooldown Swipe", inline = true, order = 0.1,
                        args = {
                            showCrowdControlSwipe = {
                                type = "toggle", name = "Show Cooldown Swipe", order = 1,
                                get = function()
                                    local c = getATSub("crowdControl") or {}
                                    return not (c.disableCrowdControlSwipe or false)
                                end,
                                set = function(_, val)
                                    if InCombatLockdown() then return end
                                    setATKey({ [1] = "disableCrowdControlSwipe", n = 1 }, not val)
                                    DispatchRefreshForKey("disableCrowdControlSwipe")
                                    RefreshPreviewForSubcat("crowdControl")
                                end,
                                disabled = InCombatLockdown,
                            },
                            reverseCrowdControlSwipe = {
                                type   = "toggle", name = "Reverse Swipe Direction", order = 2,
                                hidden = function()
                                    local c = getATSub("crowdControl") or {}
                                    return c.disableCrowdControlSwipe or false
                                end,
                                get = getAT_, set = setAT,
                                disabled = InCombatLockdown,
                            },
                            showCrowdControlSpark = {
                                type = "toggle", name = "Show Cooldown Spark", order = 3,
                                get = function()
                                    local c = getATSub("crowdControl") or {}
                                    return not (c.disableCrowdControlSpark or false)
                                end,
                                set = function(_, val)
                                    if InCombatLockdown() then return end
                                    setATKey({ [1] = "disableCrowdControlSpark", n = 1 }, not val)
                                    DispatchRefreshForKey("disableCrowdControlSpark")
                                    RefreshPreviewForSubcat("crowdControl")
                                end,
                                disabled = InCombatLockdown,
                            },
                        },
                    },
                },
            },

            privateAuraDurationText = {
                type   = "group",
                name   = "Private Aura Duration Text",
                order  = 2.5,
                hidden = isGlobal,
                args   = {
                    _subcatTracker = makeSubcatTracker("privateAuras"),
                    durationTextHeader = { type = "header", name = "Duration Text", order = 1 },
                    showPrivateAuraDuration = {
                        type = "toggle", name = "Show Duration Text", order = 2,
                        get = getAT_, set = setAT,
                        disabled = InCombatLockdown,
                    },
                    cooldownSwipeGroup = {
                        type = "group", name = "Cooldown Swipe", inline = true, order = 0.1,
                        args = {
                            showPrivateAuraSwipe = {
                                type = "toggle", name = "Show Cooldown Swipe", order = 1,
                                get = function()
                                    local p = getATSub("privateAuras") or {}
                                    return not (p.disablePrivateAuraSwipe or false)
                                end,
                                set = function(_, val)
                                    if InCombatLockdown() then return end
                                    setATKey({ [1] = "disablePrivateAuraSwipe", n = 1 }, not val)
                                    DispatchRefreshForKey("disablePrivateAuraSwipe")
                                    RefreshPreviewForSubcat("privateAuras")
                                end,
                                disabled = InCombatLockdown,
                            },
                        },
                    },
                },
            },

            -- Stack Text (always-visible subtab)
            stackText = {
                type  = "group",
                name  = "Stack Text",
                order = 5,
                args  = {
                    _subcatTracker = makeSubcatTracker("stackText"),
                    stackHeader = { type = "header", name = "Stack Text", order = 1 },
                    stackDesc   = {
                        type = "description", order = 2, width = "full",
                        name = "Controls the font and position of the stack count text shown on aura icons (buffs, debuffs, and custom container buffs).",
                    },
                    showStackText = {
                        type = "toggle", name = "Show Stack Text", order = 2.2,
                        get = getAT_, set = setAT_Stack,
                        disabled = InCombatLockdown,
                    },
                    stackAutoScale = {
                        type = "toggle", name = "Auto Scale Stack Text", order = 2.4,
                        desc = "When enabled, stack text size scales proportionally with the aura icon size. Use the scale slider to fine-tune. When disabled, a fixed font size is used instead.",
                        hidden = stackTextHidden,
                        get = getAT_, set = setAT_Stack,
                        disabled = function() return InCombatLockdown() or stackTextHidden() end,
                    },
                    stackTimerScale = {
                        type = "range", name = "Stack Text Scale", order = 2.6,
                        min = 0.1, max = 3.0, step = 0.1,
                        hidden = function()
                            local s = getATSub("stackText") or {}
                            return stackTextHidden() or s.stackAutoScale ~= true
                        end,
                        get = getAT_, set = setAT_Stack,
                        disabled = function() return InCombatLockdown() or stackTextHidden() end,
                    },
                    stackFontSpacer = {
                        type = "description", name = "", order = 2.8,
                        hidden = stackTextHidden,
                    },
                    stackFontHeader = {
                        type = "header", name = "Stack Text Font", order = 3,
                        hidden = stackTextHidden,
                    },
                    stackTextSize = {
                        type = "range", name = "Font Size", order = 3.5,
                        min = 6, max = 20, step = 1,
                        hidden = function()
                            local s = getATSub("stackText") or {}
                            return stackTextHidden() or s.stackAutoScale == true
                        end,
                        get = getAT_, set = setAT_StackRefresh,
                        disabled = InCombatLockdown,
                    },
                    stackFontGroup = {
                        type = "group", name = "Stack Text Font", inline = true, order = 3.7,
                        hidden = stackTextHidden,
                        args = {
                            stackTextFont = {
                                type = "select", name = "Font", order = 1,
                                desc = "Choose a font for aura stack count text",
                                disabled = InCombatLockdown,
                                values = lsmFontValues,
                                get = getAT_, set = setAT_StackRefresh,
                            },
                            stackTextBorder = {
                                type = "select", name = "Font Border", order = 2,
                                disabled = InCombatLockdown,
                                values = FONT_BORDER_VALUES,
                                get = getAT_, set = setAT_StackRefresh,
                            },
                        },
                    },
                    stackAnchorHeader = {
                        type = "header", name = "Stack Text Position", order = 4,
                        hidden = stackTextHidden,
                    },
                    stackTextAnchor = {
                        type = "select", name = "Anchor Point", order = 4.1,
                        hidden = stackTextHidden,
                        disabled = InCombatLockdown,
                        values = {
                            TOPLEFT     = "Top Left",     TOP    = "Top",    TOPRIGHT    = "Top Right",
                            LEFT        = "Left",         CENTER = "Center", RIGHT       = "Right",
                            BOTTOMLEFT  = "Bottom Left",  BOTTOM = "Bottom", BOTTOMRIGHT = "Bottom Right",
                        },
                        get = getAT_, set = setAT_StackRefresh,
                    },
                    stackTextX = {
                        type = "range", name = "Horizontal Offset", order = 4.2,
                        min = -20, max = 20, step = 1,
                        hidden = stackTextHidden,
                        get = getAT_, set = setAT_StackRefresh,
                        disabled = InCombatLockdown,
                    },
                    stackTextY = {
                        type = "range", name = "Vertical Offset", order = 4.3,
                        min = -20, max = 20, step = 1,
                        hidden = stackTextHidden,
                        get = getAT_, set = setAT_StackRefresh,
                        disabled = InCombatLockdown,
                    },
                },
            },
        },
    }

    return result
end
