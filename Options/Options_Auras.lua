-- ============================================================
-- BuzzardFrames: Options_Auras.lua
-- Builds and returns the "Auras" nav-tab args table.
-- Called from Options.lua: BF:BuildAurasOptions(deps)
--
-- v27 Step 16 (sub-category-aware routing):
-- Every widget in this file uses the shared getAuras_shared /
-- setAuras_shared / setAurasBigDef_shared helpers from Options.lua,
-- which route reads and writes through BF.AURAS_SUBCATEGORY_OF -> the
-- correct flat.auras.<subcat> sub-table (per-layout ON) or
-- rpDB.profile.auras.<subcat> sub-table (per-layout OFF). Widgets do
-- not know about sub-categories directly.
--
-- Predicates and inline reads that index a specific key use the
-- getAurasProfile("<subcat>").<key> form so the same routing applies
-- (e.g. `getAurasProfile("buffs").showBuffs == false`). Custom setters
-- that perform targeted refreshes (dispel indicator, showBuffs/showDebuffs/
-- showPrivateAuras) call setAuras(info, val) first for the routed write
-- then layer their targeted refresh on top.
--
-- Copy Settings is handled centrally: injectSubTab("auras", ..., "auras")
-- auto-injects a subtab-aware "Copy <subtab> settings to" dropdown at the
-- top of the Auras tab (buildAurasSectionSubcatAwareCopyToDropdown in
-- Options.lua), which copies only the currently-visible subtab's
-- sub-category. Per-subtab _subcatTracker description widgets below
-- mutate BF._currentAurasSubcat when their subtab renders so the
-- auto-injected dropdown knows what to copy.
-- ============================================================
local BF = _G["BuzzardFrames"]

-- deps is a table of upvalue references passed in from RegisterOptions:
--   deps.self                           - the BF addon object
--   deps.NotifyChangeSafe               - local function from RegisterOptions
--   deps.getAurasProfile_shared         - local function from RegisterOptions
--                                         (sub-category-aware: pass nil for flat root,
--                                         or a subcat string for the sub-category view)
--   deps.getAuras_shared                - local function from RegisterOptions
--                                         (auto-routes via AURAS_SUBCATEGORY_OF)
--   deps.setAuras_shared                - local function from RegisterOptions
--                                         (auto-routes via AURAS_SUBCATEGORY_OF)
--   deps.setAurasBigDef_shared          - local function from RegisterOptions
--                                         (same routing; different refresh path)
--   deps.aurasDisabled_shared           - local function from RegisterOptions
function BF:BuildAurasOptions(deps)
    local self                = deps.self
    local NotifyChangeSafe    = deps.NotifyChangeSafe
    local getAurasProfile     = deps.getAurasProfile_shared
    local getAuras            = deps.getAuras_shared
    local setAuras            = deps.setAuras_shared
    local setAurasPrivate     = deps.setAurasPrivate_shared
    local setAurasBigDef      = deps.setAurasBigDef_shared
    local aurasDisabled       = deps.aurasDisabled_shared

    local function buffsHidden()
        local sp = getAurasProfile("buffs")
        return sp and sp.showBuffs == false
    end
    local function debuffsHidden()
        local sp = getAurasProfile("debuffs")
        return sp and sp.showDebuffs == false
    end
    local function privateHidden()
        local sp = getAurasProfile("privateAuras")
        return sp and sp.showPrivateAuras == false
    end
    local function bigDefHidden()
        local sp = getAurasProfile("bigDef")
        return not (sp and sp.showBigDef)
    end
    local function crowdControlHidden()
        local sp = getAurasProfile("crowdControl")
        return not (sp and sp.showCrowdControl)
    end

    -- Per-subtab tracker: a description widget whose `name` callback fires
    -- on every render of its containing group. We piggyback the render
    -- callback to update BF._currentAurasSubcat so the auto-injected
    -- subtab-aware Copy dropdown at the top of the Auras tab knows which
    -- sub-category to copy. Mirror of the existing _sectionTracker pattern
    -- elsewhere in this file (self._currentSection = "auras").
    -- order = -100 puts it above every content widget so it fires early in
    -- the render pass.
    local function makeSubcatTracker(subcat)
        return {
            type  = "description",
            name  = function()
                BF._currentAurasSubcat = subcat
                -- Subtab just rendered — schedule a deferred recolor so
                -- freshly-pooled Slider/Dropdown widgets get white labels.
                if BF.ScheduleWidgetLabelRecolor then
                    BF:ScheduleWidgetLabelRecolor()
                end
                return ""
            end,
            order = -100,
            width = "full",
        }
    end

    -- ── Tab: Buffs ────────────────────────────────────────────
    local tabBuffs = {
        type  = "group",
        name  = "Buffs",
        order = 1,
        args  = {
            _subcatTracker = makeSubcatTracker("buffs"),
            buffsNote = {
                type  = "description",
                order = 0.3,
                name  = "For advanced customization of individual buffs for Healer specs, see Aura Customizations section.",
            },
            showBuffs = {
                type  = "toggle", name = "Show Buffs", order = 0.6,
                get   = getAuras,
                set   = setAuras,
            },
            buffSize = {
                type = "range", name = "Buff Size", order = 1,
                min = 2, max = 50, step = 1,
                disabled = InCombatLockdown, hidden = buffsHidden, get = getAuras, set = setAuras,
            },
            maxBuffs = {
                type = "range", name = "Max Buffs", order = 2,
                desc = "Maximum number of buff icons to show.",
                min = 1, max = 8, step = 1,
                disabled = InCombatLockdown, hidden = buffsHidden,
                get = getAuras,
                set = setAuras,
            },
            buffPositionGroup = {
                type = "group", name = "Position", order = 21, inline = true, hidden = buffsHidden,
                args = {
                    buffAnchorPoint = {
                        type = "select", name = "Anchor Point", order = 1,
                        values = { TOPLEFT="Top Left", TOP="Top", TOPRIGHT="Top Right",
                                   LEFT="Left", CENTER="Center", RIGHT="Right",
                                   BOTTOMLEFT="Bottom Left", BOTTOM="Bottom", BOTTOMRIGHT="Bottom Right" },
                        disabled = InCombatLockdown, hidden = buffsHidden, get = getAuras, set = setAuras,
                    },
                    buffOffsetX = {
                        type = "range", name = "X Offset", order = 2,
                        min = -60, max = 60, step = 1,
                        disabled = InCombatLockdown, hidden = buffsHidden, get = getAuras, set = setAuras,
                    },
                    buffOffsetY = {
                        type = "range", name = "Y Offset", order = 3,
                        min = -60, max = 60, step = 1,
                        disabled = InCombatLockdown, hidden = buffsHidden, get = getAuras, set = setAuras,
                    },
                },
            },
            buffGrowDirection = {
                type = "select", name = "Grow Direction", order = 23,
                desc = "Direction auras expand when more than one row/column is needed.",
                values = { LEFT="Left", RIGHT="Right", UP="Up", DOWN="Down" },
                disabled = InCombatLockdown, hidden = buffsHidden, get = getAuras, set = setAuras,
            },
            buffsPerRow = {
                type = "range", name = "Buffs Per Row", order = 25,
                min = 1, max = 8, step = 1,
                disabled = InCombatLockdown, hidden = buffsHidden, get = getAuras, set = setAuras,
            },
            buffSpacingGroup = {
                type = "group", name = "Buff Spacing", order = 31, inline = true, hidden = buffsHidden,
                args = {
                    buffSpacing = {
                        type = "range", name = "Icon Spacing", order = 1,
                        desc = "Gap in pixels between icons within a row.",
                        min = 0, max = 10, step = 1,
                        disabled = InCombatLockdown, hidden = buffsHidden, get = getAuras, set = setAuras,
                    },
                    buffRowSpacing = {
                        type = "range", name = "Row Spacing", order = 2,
                        desc = "Gap in pixels between rows.",
                        min = 0, max = 10, step = 1,
                        disabled = InCombatLockdown, hidden = buffsHidden, get = getAuras, set = setAuras,
                    },
                },
            },
        },
    }

    -- ── Tab: Debuffs ──────────────────────────────────────────
    local tabDebuffs = {
        type  = "group",
        name  = "Debuffs",
        order = 2,
        args  = {
            _subcatTracker = makeSubcatTracker("debuffs"),
            debuffsNote = {
                type  = "description",
                order = 0.3,
                name  = "These settings control the size and position of most debuffs in dungeons and PvP. Please note that many raid and dungeon boss debuffs are Private Auras, which are configured on a separate subtab.",
            },
            showDebuffs = {
                type  = "toggle", name = "Show Debuffs", order = 0.6,
                get   = getAuras,
                set   = setAuras,
            },
            debuffSize = {
                type = "range", name = "Debuff Size", order = 1,
                min = 2, max = 50, step = 1,
                disabled = InCombatLockdown, hidden = debuffsHidden, get = getAuras, set = setAuras,
            },
            maxDebuffs = {
                type = "range", name = "Max Debuffs", order = 2,
                desc = "Maximum number of debuff icons to show.",
                min = 1, max = 8, step = 1,
                disabled = InCombatLockdown, hidden = debuffsHidden,
                get = getAuras,
                set = setAuras,
            },
            debuffPositionGroup = {
                type = "group", name = "Position", order = 21, inline = true, hidden = debuffsHidden,
                args = {
                    debuffAnchorPoint = {
                        type = "select", name = "Anchor Point", order = 1,
                        values = { TOPLEFT="Top Left", TOP="Top", TOPRIGHT="Top Right",
                                   LEFT="Left", CENTER="Center", RIGHT="Right",
                                   BOTTOMLEFT="Bottom Left", BOTTOM="Bottom", BOTTOMRIGHT="Bottom Right" },
                        disabled = InCombatLockdown, hidden = debuffsHidden, get = getAuras, set = setAuras,
                    },
                    debuffOffsetX = {
                        type = "range", name = "X Offset", order = 2,
                        min = -60, max = 60, step = 1,
                        disabled = InCombatLockdown, hidden = debuffsHidden, get = getAuras, set = setAuras,
                    },
                    debuffOffsetY = {
                        type = "range", name = "Y Offset", order = 3,
                        min = -60, max = 60, step = 1,
                        disabled = InCombatLockdown, hidden = debuffsHidden, get = getAuras, set = setAuras,
                    },
                },
            },
            debuffGrowDirection = {
                type = "select", name = "Grow Direction", order = 23,
                desc = "Direction auras expand when more than one row/column is needed.",
                values = { LEFT="Left", RIGHT="Right", UP="Up", DOWN="Down" },
                disabled = InCombatLockdown, hidden = debuffsHidden, get = getAuras, set = setAuras,
            },
            debuffsPerRow = {
                type = "range", name = "Debuffs Per Row", order = 25,
                min = 1, max = 8, step = 1,
                disabled = InCombatLockdown, hidden = debuffsHidden, get = getAuras, set = setAuras,
            },
            debuffSpacingGroup = {
                type = "group", name = "Debuff Spacing", order = 31, inline = true, hidden = debuffsHidden,
                args = {
                    debuffSpacing = {
                        type = "range", name = "Icon Spacing", order = 1,
                        desc = "Gap in pixels between icons within a row.",
                        min = 0, max = 10, step = 1,
                        disabled = InCombatLockdown, hidden = debuffsHidden, get = getAuras, set = setAuras,
                    },
                    debuffRowSpacing = {
                        type = "range", name = "Row Spacing", order = 2,
                        desc = "Gap in pixels between rows.",
                        min = 0, max = 10, step = 1,
                        disabled = InCombatLockdown, hidden = debuffsHidden, get = getAuras, set = setAuras,
                    },
                },
            },
            debuffSortingHeader = {
                type = "header", name = "Sorting & Filtering", order = 32, hidden = debuffsHidden,
            },
            debuffShowMode = {
                type = "select", name = "Debuffs to Show", order = 33, width = 1.2,
                values = {
                    all             = "All",
                    dispellableByMe = "Dispellable By Me",
                    allDispellable  = "All Dispellable",
                    blizzardRaid    = "Blizzard Raid Filter",
                    blizzardRaidPlusDispellable = "Blizzard Raid Filter + All Dispellable",
                },
                sorting = { "all", "dispellableByMe", "allDispellable", "blizzardRaid", "blizzardRaidPlusDispellable" },
                disabled = InCombatLockdown, hidden = debuffsHidden, get = getAuras, set = setAuras,
            },
            debuffSortRule = {
                type = "select", name = "Sort By", order = 34, width = 1.2,
                values = {
                    [0] = "Unsorted",
                    [1] = "Blizzard Default (Aura Instance Id)",
                    [4] = "Expiration (Soonest First)",
                },
                disabled = InCombatLockdown, hidden = debuffsHidden, get = getAuras, set = setAuras,
            },
        },
    }

    -- ── Tab: Private Auras ────────────────────────────────────
    local tabPrivate = {
        type  = "group",
        name  = "Private Auras",
        order = 3,
        args  = {
            _subcatTracker = makeSubcatTracker("privateAuras"),
            privateAurasNote = {
                type  = "description",
                order = 0.5,
                name  = "Private Auras are special debuffs that are applied by raid and dungeon bosses. They are protected by Blizzard and can't be customized much beyond their size and position.",
            },
            showPrivateAuras = {
                type  = "toggle", name = "Show Private Auras", order = 1,
                get   = getAuras,
                -- Private-aura-only path: setAurasPrivate writes the value
                -- (sub-category-routed) and runs BF:RefreshAllPrivateAuras,
                -- which is the icon-path-only equivalent of Grid2's
                -- RefreshIndicator(ind, "Layout"). NO regular-aura work
                -- (RefreshAllAuras / stack text / standard indicators).
                set   = setAurasPrivate,
            },
            privateAuraSize = {
                type = "range", name = "Private Aura Size", order = 2,
                min = 2, max = 50, step = 1,
                disabled = InCombatLockdown, hidden = privateHidden, get = getAuras, set = setAurasPrivate,
            },
            maxPrivateAuras = {
                type = "range", name = "Max Private Auras", order = 3,
                min = 1, max = 5, step = 1,
                disabled = InCombatLockdown, hidden = privateHidden, get = getAuras, set = setAurasPrivate,
            },
            privatePositionGroup = {
                type = "group", name = "Position", order = 21, inline = true, hidden = privateHidden,
                args = {
                    privateAuraAnchorPoint = {
                        type   = "select", name = "Anchor Point", order = 1,
                        values = { TOPLEFT="Top Left", TOP="Top", TOPRIGHT="Top Right",
                                   LEFT="Left", CENTER="Center", RIGHT="Right",
                                   BOTTOMLEFT="Bottom Left", BOTTOM="Bottom", BOTTOMRIGHT="Bottom Right" },
                        disabled = InCombatLockdown, hidden = privateHidden, get = getAuras, set = setAurasPrivate,
                    },
                    privateAuraOffsetX = {
                        type = "range", name = "X Offset", order = 2,
                        min = -60, max = 60, step = 1,
                        disabled = InCombatLockdown, hidden = privateHidden, get = getAuras, set = setAurasPrivate,
                    },
                    privateAuraOffsetY = {
                        type = "range", name = "Y Offset", order = 3,
                        min = -60, max = 60, step = 1,
                        disabled = InCombatLockdown, hidden = privateHidden, get = getAuras, set = setAurasPrivate,
                    },
                },
            },
            privateGrowHeader = { type = "header", name = "Grow Direction", order = 22 , hidden = privateHidden },
            privateAuraGrowDirection = {
                type = "select", name = "Grow Direction", order = 23,
                desc = "Direction additional private auras expand from the anchor point.",
                values = { LEFT="Left", RIGHT="Right", UP="Up", DOWN="Down" },
                disabled = InCombatLockdown, hidden = privateHidden, get = getAuras, set = setAurasPrivate,
            },
            privateAuraIconSpacing = {
                type = "range", name = "Icon Spacing", order = 24,
                desc = "Pixel gap between adjacent private aura icons.",
                min = 0, max = 20, step = 1,
                disabled = InCombatLockdown, hidden = privateHidden, get = getAuras, set = setAurasPrivate,
            },

            -- Icon Border Scale: moved from Preview → Special Options →
            -- "Private Aura Icon Border". Relocated from self.db.profile
            -- (core DB) to self.rpDB.profile (rpDB namespace) in the §18.1
            -- storage-namespace migration — the widget lives in the
            -- Raid/Party Frames section so storage belongs in rpDB per the
            -- naming convention. Global across layouts (NOT per-layout):
            -- this is a Blizzard-bug-workaround scale, not a styling choice.
            -- Changes invalidate per-frame geometry cache and re-register anchors.
            privateAuraBorderScaleSpacer = { type = "description", hidden = privateHidden, name = "", order = 10000 },
            privateAuraBorderScaleHeader = { type = "header", name = "Icon Border Scale", order = 10001, hidden = privateHidden },
            privateAuraBorderScale = {
                type = "range", name = "Icon Border Scale", order = 10002,
                desc = "Scale the private aura icon border. 1.0 = default. Changes re-register all anchors.",
                min = 0.5, max = 5.0, step = 0.1,
                hidden = privateHidden, disabled = InCombatLockdown,
                get = function() return self.rpDB.profile.privateAuraBorderScale or 1.0 end,
                set = function(_, val)
                    self.rpDB.profile.privateAuraBorderScale = val
                    if not InCombatLockdown() and self.activeFrames then
                        for frame in pairs(self.activeFrames) do
                            if frame and frame.unit then
                                frame.SF_PrivateAuraUnit      = nil
                                self:UpdatePrivateAuraAnchor(frame)
                            end
                        end
                    end
                end,
            },

            -- Swap Positions toggles -----------------------------------------
            -- REMOVED: the swap feature has been deleted entirely. The widgets
            -- below used to write into auras.privateAuras.pvpSwapDebuffsPrivate*
            -- via setAuras, which the (now-removed) swap block in
            -- AuraConfig.lua read at runtime. Both have been commented out so
            -- nothing in this file emits those keys, and the entries have
            -- been removed from BF.AURAS_SUBCATEGORY_OF in Core_ProfileAPI.lua
            -- so even an accidental re-add wouldn't route anywhere.
            -- Saved DB values are nilled by MigrateRemovePvpSwap (Core_Migrations.lua).
            --[==[
            privateAurasSwapHeader = {
                type = "header", name = "Swap Positions", order = 10050,
                hidden = function() return true end,
            },
            pvpSwapDebuffsPrivateBattleground = {
                type  = "toggle",
                name  = "Swap Debuff & Private Aura Positions in Battlegrounds",
                desc  = "When in a battleground, swap the anchor/size/offsets/grow direction between the debuff and private aura containers. Applies to raid frames only.",
                order = 10051,
                width = "full",
                disabled = InCombatLockdown,
                hidden = function() return true end,
                get = getAuras,
                set = setAuras,
            },
            pvpSwapDebuffsPrivateParty = {
                type  = "toggle",
                name  = "Swap Debuff & Private Aura Positions in Party",
                desc  = "In party (non-raid) context, swap the anchor/size/offsets/grow direction between the debuff and private aura containers. Applies to party frames only.",
                order = 10052,
                width = "full",
                disabled = InCombatLockdown,
                hidden = function() return true end,
                get = getAuras,
                set = setAuras,
            },
            ]==]
        },
    }

    -- ── Tab: Big Defensive Icon ───────────────────────────────
    local tabBigDef = {
        type  = "group",
        name  = "Big Defensive",
        order = 4,
        args  = {
            _subcatTracker = makeSubcatTracker("bigDef"),
            showBigDef = {
                type = "toggle", name = "Show Big Defensive Icon", order = 1,
                desc = "Show a single large icon for BIG_DEFENSIVE auras (major defensive cooldowns)",
                disabled = InCombatLockdown, get = getAuras, set = setAurasBigDef,
            },
            bigDefSize = {
                type = "range", name = "Icon Size", order = 2,
                min = 2, max = 60, step = 1,
                disabled = InCombatLockdown, hidden = bigDefHidden, get = getAuras, set = setAurasBigDef,
            },
            bigDefMaxCount = {
                type = "range", name = "Max Defensives", order = 3,
                desc = "Maximum number of Big Defensive icons to show at once.",
                min = 1, max = 5, step = 1,
                disabled = InCombatLockdown, hidden = bigDefHidden,
                get = getAuras,
                set = setAurasBigDef,
            },
            bigDefShowGlow = {
                type = "toggle", name = "Show Glow", order = 4,
                desc = "Show an action button glow effect on the Big Defensive icon when active.",
                disabled = InCombatLockdown, hidden = bigDefHidden, get = getAuras, set = setAurasBigDef,
            },
            bigDefPositionGroup = {
                type = "group", name = "Position", order = 21, inline = true, hidden = bigDefHidden,
                args = {
                    bigDefAnchor = {
                        type   = "select", name = "Anchor Point", order = 1,
                        values = { TOPLEFT="Top Left", TOP="Top", TOPRIGHT="Top Right",
                                   LEFT="Left", CENTER="Center", RIGHT="Right",
                                   BOTTOMLEFT="Bottom Left", BOTTOM="Bottom", BOTTOMRIGHT="Bottom Right" },
                        disabled = InCombatLockdown, get = getAuras, set = setAurasBigDef,
                    },
                    bigDefOffsetX = {
                        type = "range", name = "X Offset", order = 2,
                        min = -60, max = 60, step = 1,
                        disabled = InCombatLockdown, get = getAuras, set = setAurasBigDef,
                    },
                    bigDefOffsetY = {
                        type = "range", name = "Y Offset", order = 3,
                        min = -60, max = 60, step = 1,
                        disabled = InCombatLockdown, get = getAuras, set = setAurasBigDef,
                    },
                },
            },
            bigDefGrowDirection = {
                type = "select", name = "Grow Direction", order = 23,
                desc = "Direction icons expand when more than one is shown.",
                values = { LEFT="Left", RIGHT="Right", UP="Up", DOWN="Down" },
                hidden = function()
                    if bigDefHidden() then return true end
                    local sp = getAurasProfile("bigDef")
                    return (sp and sp.bigDefMaxCount or 1) <= 1
                end,
                disabled = InCombatLockdown,
                get = getAuras, set = setAurasBigDef,
            },
            bigDefIconsPerRow = {
                type = "range", name = "Icons Per Row", order = 24,
                min = 1, max = 5, step = 1,
                hidden = function()
                    if bigDefHidden() then return true end
                    local sp = getAurasProfile("bigDef")
                    return (sp and sp.bigDefMaxCount or 1) <= 1
                end,
                disabled = InCombatLockdown,
                get = getAuras, set = setAurasBigDef,
            },
            bigDefSpacingGroup = {
                type = "group", name = "Spacing", order = 26, inline = true,
                hidden = function()
                    if bigDefHidden() then return true end
                    local sp = getAurasProfile("bigDef")
                    return (sp and sp.bigDefMaxCount or 1) <= 1
                end,
                args = {
                    bigDefSpacing = {
                        type = "range", name = "Icon Spacing", order = 1,
                        desc = "Gap in pixels between icons.",
                        min = 0, max = 10, step = 1,
                        disabled = InCombatLockdown,
                        get = getAuras, set = setAurasBigDef,
                    },
                    bigDefRowSpacing = {
                        type = "range", name = "Row Spacing", order = 2,
                        desc = "Gap in pixels between rows.",
                        min = 0, max = 10, step = 1,
                        disabled = InCombatLockdown,
                        get = getAuras, set = setAurasBigDef,
                    },
                },
            },

        },
    }

    -- ── Tab: Important Buffs ───────────────────────────────
    local function importantHidden()
        local sp = getAurasProfile("important")
        return not (sp and sp.showImportant)
    end
    local tabImportant = {
        type  = "group",
        name  = "Important",
        order = 5,
        args  = {
            _subcatTracker = makeSubcatTracker("important"),
            importantNote = {
                type  = "description",
                order = 0.5,
                name  = "Important buffs are mainly offensive cooldowns like combustion or avenging wrath.",
            },
            showImportant = {
                type = "toggle", name = "Show Important Buffs", order = 1,
                desc = "Show a separate icon display for Blizzard's IMPORTANT auras. This includes some major defensive cooldowns and significant buffs that Blizzard's other filters miss, but may also include some offensive abilities.",
                disabled = InCombatLockdown, get = getAuras, set = setAurasBigDef,
            },
            importantSize = {
                type = "range", name = "Icon Size", order = 2,
                min = 2, max = 60, step = 1,
                disabled = InCombatLockdown, hidden = importantHidden, get = getAuras, set = setAurasBigDef,
            },
            importantMaxCount = {
                type = "range", name = "Max Icons", order = 3,
                desc = "Maximum number of Important icons to show at once.",
                min = 1, max = 5, step = 1,
                disabled = InCombatLockdown, hidden = importantHidden,
                get = getAuras,
                set = setAurasBigDef,
            },
            importantShowGlow = {
                type = "toggle", name = "Show Glow", order = 4,
                desc = "Show an action button glow effect on Important icons when active.",
                disabled = InCombatLockdown, hidden = importantHidden, get = getAuras, set = setAurasBigDef,
            },
            importantPositionGroup = {
                type = "group", name = "Position", order = 21, inline = true, hidden = importantHidden,
                args = {
                    importantAnchor = {
                        type   = "select", name = "Anchor Point", order = 1,
                        values = { TOPLEFT="Top Left", TOP="Top", TOPRIGHT="Top Right",
                                   LEFT="Left", CENTER="Center", RIGHT="Right",
                                   BOTTOMLEFT="Bottom Left", BOTTOM="Bottom", BOTTOMRIGHT="Bottom Right" },
                        disabled = InCombatLockdown, hidden = importantHidden, get = getAuras, set = setAurasBigDef,
                    },
                    importantOffsetX = {
                        type = "range", name = "X Offset", order = 2,
                        min = -60, max = 60, step = 1,
                        disabled = InCombatLockdown, hidden = importantHidden, get = getAuras, set = setAurasBigDef,
                    },
                    importantOffsetY = {
                        type = "range", name = "Y Offset", order = 3,
                        min = -60, max = 60, step = 1,
                        disabled = InCombatLockdown, hidden = importantHidden, get = getAuras, set = setAurasBigDef,
                    },
                },
            },
            importantGrowDirection = {
                type = "select", name = "Grow Direction", order = 23,
                desc = "Direction icons expand when more than one is shown.",
                values = { LEFT="Left", RIGHT="Right", UP="Up", DOWN="Down" },
                hidden = function()
                    if importantHidden() then return true end
                    local sp = getAurasProfile("important")
                    return (sp and sp.importantMaxCount or 1) <= 1
                end,
                disabled = InCombatLockdown, get = getAuras, set = setAurasBigDef,
            },
            importantIconsPerRow = {
                type = "range", name = "Icons Per Row", order = 24,
                min = 1, max = 5, step = 1,
                hidden = function()
                    if importantHidden() then return true end
                    local sp = getAurasProfile("important")
                    return (sp and sp.importantMaxCount or 1) <= 1
                end,
                disabled = InCombatLockdown, get = getAuras, set = setAurasBigDef,
            },
            importantSpacingGroup = {
                type = "group", name = "Spacing", order = 26, inline = true,
                hidden = function()
                    if importantHidden() then return true end
                    local sp = getAurasProfile("important")
                    return (sp and sp.importantMaxCount or 1) <= 1
                end,
                args = {
                    importantSpacing = {
                        type = "range", name = "Icon Spacing", order = 1,
                        desc = "Gap in pixels between icons.",
                        min = 0, max = 10, step = 1,
                        disabled = InCombatLockdown, hidden = importantHidden, get = getAuras, set = setAurasBigDef,
                    },
                    importantRowSpacing = {
                        type = "range", name = "Row Spacing", order = 2,
                        desc = "Gap in pixels between rows.",
                        min = 0, max = 10, step = 1,
                        disabled = InCombatLockdown, hidden = importantHidden, get = getAuras, set = setAurasBigDef,
                    },
                },
            },
        },
    }

    -- ── Tab: Crowd Control Icon ──────────────────────────────
    local tabCrowdControl = {
        type   = "group",
        name   = "Crowd Control",
        order  = 6,
        args   = {
            _subcatTracker = makeSubcatTracker("crowdControl"),
            showCrowdControl = {
                type = "toggle", name = "Show Crowd Control Icon", order = 1,
                desc = "Show a single large icon for HARMFUL|CROWD_CONTROL auras",
                disabled = InCombatLockdown, get = getAuras, set = setAurasBigDef,
            },
            crowdControlSize = {
                type = "range", name = "Icon Size", order = 2,
                min = 2, max = 60, step = 1,
                disabled = InCombatLockdown, hidden = crowdControlHidden, get = getAuras, set = setAurasBigDef,
            },
            crowdControlMaxIcons = {
                type = "range", name = "Max CC Icons", order = 2.5,
                min = 1, max = 5, step = 1,
                disabled = InCombatLockdown, hidden = crowdControlHidden,
                get = getAuras, set = setAurasBigDef,
            },
            crowdControlShowGlow = {
                type = "toggle", name = "Show Glow", order = 3,
                desc = "Show an action button glow effect on the Crowd Control icon when active.",
                disabled = InCombatLockdown, hidden = crowdControlHidden, get = getAuras, set = setAurasBigDef,
            },
            crowdControlPositionGroup = {
                type = "group", name = "Position", order = 21, inline = true, hidden = crowdControlHidden,
                args = {
                    crowdControlAnchor = {
                        type   = "select", name = "Anchor Point", order = 1,
                        values = { TOPLEFT="Top Left", TOP="Top", TOPRIGHT="Top Right",
                                   LEFT="Left", CENTER="Center", RIGHT="Right",
                                   BOTTOMLEFT="Bottom Left", BOTTOM="Bottom", BOTTOMRIGHT="Bottom Right" },
                        disabled = InCombatLockdown, get = getAuras, set = setAurasBigDef,
                    },
                    crowdControlOffsetX = {
                        type = "range", name = "X Offset", order = 2,
                        min = -60, max = 60, step = 1,
                        disabled = InCombatLockdown, get = getAuras, set = setAurasBigDef,
                    },
                    crowdControlOffsetY = {
                        type = "range", name = "Y Offset", order = 3,
                        min = -60, max = 60, step = 1,
                        disabled = InCombatLockdown, get = getAuras, set = setAurasBigDef,
                    },
                },
            },
            crowdControlGrowDirection = {
                type = "select", name = "Grow Direction", order = 23,
                desc = "Direction icons expand when more than one is shown.",
                values = { LEFT="Left", RIGHT="Right", UP="Up", DOWN="Down" },
                hidden = function()
                    if crowdControlHidden() then return true end
                    local sp = getAurasProfile("crowdControl")
                    return (sp and sp.crowdControlMaxIcons or 1) <= 1
                end,
                disabled = InCombatLockdown, get = getAuras, set = setAurasBigDef,
            },
            crowdControlIconsPerRow = {
                type = "range", name = "Icons Per Row", order = 24,
                min = 1, max = 5, step = 1,
                hidden = function()
                    if crowdControlHidden() then return true end
                    local sp = getAurasProfile("crowdControl")
                    return (sp and sp.crowdControlMaxIcons or 1) <= 1
                end,
                disabled = InCombatLockdown, get = getAuras, set = setAurasBigDef,
            },
            crowdControlSpacingGroup = {
                type = "group", name = "Spacing", order = 26, inline = true,
                hidden = function()
                    if crowdControlHidden() then return true end
                    local sp = getAurasProfile("crowdControl")
                    return (sp and sp.crowdControlMaxIcons or 1) <= 1
                end,
                args = {
                    crowdControlSpacing = {
                        type = "range", name = "Icon Spacing", order = 1,
                        desc = "Gap in pixels between icons.",
                        min = 0, max = 10, step = 1,
                        disabled = InCombatLockdown, get = getAuras, set = setAurasBigDef,
                    },
                    crowdControlRowSpacing = {
                        type = "range", name = "Row Spacing", order = 2,
                        desc = "Gap in pixels between rows.",
                        min = 0, max = 10, step = 1,
                        disabled = InCombatLockdown, get = getAuras, set = setAurasBigDef,
                    },
                },
            },
        },
    }

    -- ── Tab: Dispel Indicator ─────────────────────────────────
    -- v35 follow-up: when the master Dispel Indicator/Overlay Mode dropdown
    -- is set to "blizzard", every addon-side dispellable-debuff feature
    -- (indicator, border, overlay) hides from the UI AND has its runtime
    -- toggle forced off via the AuraCache hoist in AuraConfig.lua
    -- UpdateAuraSizeCache. This is a single chokepoint that keeps
    -- DebuffHighlight:Update from doing any work on those features.
    --
    -- v36: the storage key under auras.dispelIndicator was renamed from
    -- boolean showBlizzardDispelIndicator to string dispelIndicatorOverlayMode
    -- ("blizzard" / "custom"). The predicates below read the string value.
    local function dispelHidden()
        local sp = getAurasProfile("dispelIndicator")
        if not sp then return true end
        if sp.dispelIndicatorOverlayMode == "blizzard" then return true end
        return not sp.showDispelIndicator
    end
    local function overlayHidden()
        local sp = getAurasProfile("dispelIndicator")
        if not sp then return true end
        if sp.dispelIndicatorOverlayMode == "blizzard" then return true end
        return not sp.enableDebuffOverlay
    end
    -- v36: Debuff Border is now also suppressed in blizzard mode. Previously
    -- the border was treated as "independent" and stayed live regardless of
    -- the master dropdown, but that kept DebuffHighlight:Update running per
    -- unit per UNIT_AURA in dispellable mode just to paint a border that the
    -- Blizzard container already effectively covers via its overlay. Hiding
    -- the section and forcing enableDebuffBorder false in the AuraCache
    -- eliminates that work. The section header, note, toggle, mode, width,
    -- and only-if-ready widgets all route through this predicate.
    local function borderHidden()
        local sp = getAurasProfile("dispelIndicator")
        if not sp then return true end
        if sp.dispelIndicatorOverlayMode == "blizzard" then return true end
        return false
    end
    local tabDispel = {
        type  = "group",
        name  = "Dispellable Debuffs",
        order = 2.5,
        args  = {
            _subcatTracker = makeSubcatTracker("dispelIndicator"),

            -- ── Blizzard Dispel Indicator ────────────────────────────────
            -- Master dropdown for Blizzard's native dispel icons + overlay,
            -- rendered by the isContainer=true private-aura anchor in
            -- PrivateAuras.lua SetupDispelOverlay. When set to "blizzard",
            -- both the dispel-type icons (up to dispelIndicatorMaxIcons) and
            -- the gradient dispel overlay are drawn; when "custom", neither
            -- is drawn and the anchor/attribute writes are skipped.
            --
            -- v36: the storage was converted from a boolean toggle
            -- (showBlizzardDispelIndicator) to a two-option select
            -- (dispelIndicatorOverlayMode) so future values beyond these two
            -- can slot in without another migration. The widget key must
            -- match the map entry in BF.AURAS_SUBCATEGORY_OF so
            -- getAuras/setAuras route to auras.dispelIndicator automatically.
            blizzardHeader = { type="header", name="Blizzard Dispel Indicator", order=10, hidden=function()
                local sp = getAurasProfile("dispelIndicator")
                return not (sp and sp.dispelIndicatorOverlayMode == "blizzard")
            end },
            blizzardNote = {
                type  = "description",
                order = 10.5,
                hidden = function()
                    local sp = getAurasProfile("dispelIndicator")
                    return not (sp and sp.dispelIndicatorOverlayMode == "blizzard")
                end,
                name  = "The Blizzard Dispel Indicator/Overlay uses Blizzard's native private aura container system to render the same dispellable debuff indicator icons and overlay that the default Blizzard frames use. It can't be customized much but it supports dispellable private auras (e.g. the dispels on Heroic and Mythic Chimaerus).",
            },
            customHeader = { type="header", name="Custom Dispel Highlighting", order=10, hidden=function()
                local sp = getAurasProfile("dispelIndicator")
                return not (sp and sp.dispelIndicatorOverlayMode == "custom")
            end },
            customNote = {
                type  = "description",
                order = 10.5,
                hidden = function()
                    local sp = getAurasProfile("dispelIndicator")
                    return not (sp and sp.dispelIndicatorOverlayMode == "custom")
                end,
                name  = "Custom mode allows many more customization possibilities. You can optionally enable the Blizzard native overlay below to cover dispellable private auras that the custom system cannot detect.",
            },
            dispelIndicatorOverlayMode = {
                type="select", name="Dispel Indicator/Overlay Mode", order=11,
                width="double",
                desc="Choose between Blizzard's native dispel indicator icons and colored dispel overlay (rendered by Blizzard's private aura container system), or the addon's fully customizable custom indicator and overlay.",
                values={ blizzard="Blizzard native", custom="Custom" },
                disabled=aurasDisabled,
                get=getAuras,
                -- setAuras routes dispelIndicator-subcat keys to
                -- BF:RefreshDispelOnly, which already runs
                -- RefreshAllPrivateAuraDispelOverlays AND per-frame
                -- Update on dispelDebuffIndicator/Border/Overlay.
                -- The previous explicit calls here are now redundant.
                set=setAuras,
            },
            blizzardDispelOverlayMode = {
                -- Integer value (1 or 2) passed to Blizzard's container as
                -- the `dispel-indicator-option` attribute.
                -- 1 = Dispellable By Me, 2 = All Dispellable.
                type="select", name="Overlay Mode", order=12,
                values={ [2]="All Dispellable", [1]="Dispellable By Me" },
                hidden=function()
                    local sp = getAurasProfile("dispelIndicator")
                    return not (sp and sp.dispelIndicatorOverlayMode == "blizzard")
                end,
                disabled=aurasDisabled,
                get=getAuras,
                set=setAuras,
            },
            dispelIndicatorMaxIcons = {
                type="range", name="Max Indicator Icons", order=12.5,
                desc="Maximum number of dispel-type indicator icons to show.",
                min=1, max=3, step=1,
                hidden=function()
                    local sp = getAurasProfile("dispelIndicator")
                    return not (sp and sp.dispelIndicatorOverlayMode == "blizzard")
                end,
                disabled=aurasDisabled,
                get=getAuras,
                set=setAuras,
            },
            blizzardDispelOverlayOpacity = {
                type="range", name="Overlay Opacity", order=13,
                desc="Alpha of the Blizzard dispel overlay. 1 = fully opaque, 0 = invisible.",
                min=0, max=1, step=0.05, isPercent=true,
                hidden=function()
                    local sp = getAurasProfile("dispelIndicator")
                    return not (sp and sp.dispelIndicatorOverlayMode == "blizzard")
                end,
                disabled=aurasDisabled,
                get=getAuras,
                set=setAuras,
            },
            -- ── Dispellable Private Aura Indicator & Overlay (Custom mode) ──
            -- When in Custom mode, users can optionally enable the Blizzard
            -- native overlay just for dispellable private auras.  This
            -- implicitly activates the "private auras only" visibility
            -- behaviour (hide overlay when a non-private dispellable debuff
            -- exists) so the custom system handles normal debuffs.
            privateAuraDispelHeader = { type="header", name="Dispellable Private Aura Indicator & Overlay", order=20, hidden=function()
                local sp = getAurasProfile("dispelIndicator")
                return not (sp and sp.dispelIndicatorOverlayMode == "custom")
            end },
            showBlizzardPrivateAuraDispel = {
                type="toggle", name="Show Blizzard Native Overlay and Icon for Dispellable Private Auras", order=21,
                width="full",
                desc="Enables Blizzard's native private aura container overlay for dispellable private auras (e.g. Heroic/Mythic Chimaerus). No overlay or indicator will show for dispellable Private Auras if this is disabled.",
                hidden=function()
                    local sp = getAurasProfile("dispelIndicator")
                    return not (sp and sp.dispelIndicatorOverlayMode == "custom")
                end,
                disabled=aurasDisabled,
                get=getAuras,
                set=setAuras,
            },
            privateAuraDispelSettings = {
                type="group", name="", order=22, inline=true,
                hidden=function()
                    local sp = getAurasProfile("dispelIndicator")
                    return not (sp and sp.dispelIndicatorOverlayMode == "custom" and sp.showBlizzardPrivateAuraDispel)
                end,
                args = {
                    blizzardDispelOverlayMode = {
                        type="select", name="Overlay Mode", order=1,
                        values={ [2]="All Dispellable", [1]="Dispellable By Me" },
                        disabled=aurasDisabled,
                        get=getAuras,
                        set=setAuras,
                    },
                    blizzardDispelOverlayOpacity = {
                        type="range", name="Overlay Opacity", order=2,
                        desc="Alpha of the Blizzard dispel overlay. 1 = fully opaque, 0 = invisible.",
                        min=0, max=1, step=0.05, isPercent=true,
                        disabled=aurasDisabled,
                        get=getAuras,
                        set=setAuras,
                    },
                    dispelIndicatorMaxIcons = {
                        type="range", name="Max Indicator Icons", order=3,
                        desc="Maximum number of dispel-type indicator icons to show.",
                        min=1, max=3, step=1,
                        disabled=aurasDisabled,
                        get=getAuras,
                        set=setAuras,
                    },
                },
            },

            dispelHeader = { type="header", name="Dispellable Debuff Indicator", order=30, hidden=function()
                local sp = getAurasProfile("dispelIndicator")
                if not sp then return true end
                return sp.dispelIndicatorOverlayMode == "blizzard"
            end },
            showDispelIndicator = {
                type="toggle", name="Show Dispellable Debuff Indicator", order=31,
                width="full",
                desc="Shows a colored indicator in the corner of the frame when the unit has a debuff you can dispel",
                hidden=function()
                    local sp = getAurasProfile("dispelIndicator")
                    if not sp then return true end
                    return sp.dispelIndicatorOverlayMode == "blizzard"
                end,
                get=getAuras, set=setAuras, disabled=aurasDisabled,
            },
            dispelIndicatorStyle = {
                type="select", name="Indicator Style", order=32,
                desc="Choose between a colored square or a dispel type icon",
                values={ square="Colored Square", icon="Dispel Type Icon" },
                hidden=dispelHidden,
                disabled=aurasDisabled,
                get=getAuras,
                set=function(info, val)
                    -- setAuras routes dispelIndicator-subcat keys to
                    -- BF:RefreshDispelOnly, which already runs the
                    -- private-aura dispel overlay refresh + per-frame
                    -- Update on the three dispel indicators.
                    -- The dispel-highlight sweep below is separate and
                    -- still needed (RefreshDispelOnly doesn't touch it).
                    setAuras(info, val)
                    if not InCombatLockdown() then
                        for _, frame in pairs(BF.activeFrames) do
                            BF:UpdateDebuffHighlight(frame)
                        end
                    end
                end,
            },
            dispelIndicatorMode = {
                type="select", name="Indicator Mode", order=32.5,
                values={ dispellable="Dispellable by Me", allDispellable="All Dispellable" },
                hidden=dispelHidden,
                disabled=aurasDisabled,
                get=getAuras,
                set=function(info, val)
                    setAuras(info, val)
                    for _, frame in pairs(BF.activeFrames) do
                        BF:UpdateDebuffHighlight(frame)
                    end
                end,
            },
            dispelIndicatorOnlyIfReady = {
                type="toggle", name="Only Show if Dispel Available",
                desc="When enabled, the dispel indicator only shows when your dispel spell is off cooldown. The GCD is not counted as a cooldown.",
                order=33,
                hidden=dispelHidden,
                disabled=aurasDisabled,
                get=getAuras,
                set=function(info, val)
                    setAuras(info, val)
                    if BF.UpdateDispelCooldownTracking then BF:UpdateDispelCooldownTracking() end
                    for _, frame in pairs(BF.activeFrames) do
                        BF:UpdateDebuffHighlight(frame)
                    end
                end,
            },
            dispelIndicatorSize = {
                type="range", name="Indicator Size", order=34,
                desc="Size of the dispel indicator in pixels",
                min=2, max=20, step=1,
                hidden=dispelHidden,
                disabled=aurasDisabled,
                get=getAuras,
                set=function(info, val)
                    setAuras(info, val)
                    local ind = BF:GetIndicatorByName("dispelDebuffIndicator")
                    if ind and not InCombatLockdown() then ind:LayoutAllFrames() end
                end,
            },
            dispelPositionGroup = {
                type = "group", name = "Position", order = 35, inline = true,
                hidden=dispelHidden,
                args = {
                    dispelIndicatorPosition = {
                        type="select", name="Position", order=1,
                        desc="Corner to show the dispel indicator",
                        values={ TOPLEFT="Top Left", TOP="Top", TOPRIGHT="Top Right", BOTTOMLEFT="Bottom Left", BOTTOM="Bottom", BOTTOMRIGHT="Bottom Right" },
                        disabled=aurasDisabled,
                        get=getAuras,
                        set=function(info, val)
                            setAuras(info, val)
                            local ind = BF:GetIndicatorByName("dispelDebuffIndicator")
                            if ind and not InCombatLockdown() then ind:LayoutAllFrames() end
                        end,
                    },
                    dispelIndicatorOffsetX = {
                        type = "range", name = "X Offset", order = 2,
                        min = -60, max = 60, step = 1,
                        disabled = InCombatLockdown,
                        get = getAuras,
                        set = function(info, val)
                            setAuras(info, val)
                            local ind = BF:GetIndicatorByName("dispelDebuffIndicator")
                            if ind and not InCombatLockdown() then ind:LayoutAllFrames() end
                        end,
                    },
                    dispelIndicatorOffsetY = {
                        type = "range", name = "Y Offset", order = 3,
                        min = -60, max = 60, step = 1,
                        disabled = InCombatLockdown,
                        get = getAuras,
                        set = function(info, val)
                            setAuras(info, val)
                            local ind = BF:GetIndicatorByName("dispelDebuffIndicator")
                            if ind and not InCombatLockdown() then ind:LayoutAllFrames() end
                        end,
                    },
                },
            },

            -- ── Debuff Border (migrated from Borders → Debuff Highlight in v35) ──
            -- The 11 keys below and the blizzardDispelOverlayMode key used to
            -- live in rpDB.profile.borders. They were relocated into
            -- auras.dispelIndicator so all dispel-related settings live in one
            -- sub-category and follow the per-layout auras toggle. Widget
            -- behaviour (labels, ordering, hidden predicates, custom setters)
            -- mirrors the original Options_Borders.lua debuffTab implementation.
            --
            -- v36: this section is also hidden via borderHidden() when the
            -- master Dispel Indicator/Overlay Mode dropdown is set to
            -- "blizzard", matching the behaviour of the Dispel Indicator and
            -- Debuff Color Overlay sections above. The runtime path is gated
            -- by the same blizzardDispelActive branch in AuraConfig.lua's
            -- AuraCache hoist (AuraCache.enableDebuffBorder forced to false).
            debuffBorderHeader = { type="header", name="Debuff Border", order=50, hidden=borderHidden },
            debuffBorderNote = {
                type="description", order=51, hidden=borderHidden,
                name="Shows a colored border on the frame when a player is affected by debuffs (dispellable or all). *Cannot be shown for Private Auras.",
            },
            enableDebuffBorder = {
                type="toggle", name="Enable Debuff Border", order=52,
                hidden=borderHidden,
                disabled=aurasDisabled,
                get=getAuras,
                set=function(info, val)
                    setAuras(info, val)
                    if InCombatLockdown() then return end
                    for f in pairs(BF.activeFrames or {}) do BF:UpdateDebuffHighlight(f) end
                    if BF.RefreshPreviewDummyAuras then BF:RefreshPreviewDummyAuras() end
                end,
            },
            debuffBorderMode = {
                type="select", name="Highlight Mode", order=53,
                values={ dispellable="Dispellable by Me", allDispellable="All Dispellable", all="All Debuffs" },
                hidden=borderHidden,
                disabled=function()
                    if aurasDisabled() then return true end
                    local sp = getAurasProfile("dispelIndicator")
                    return not (sp and sp.enableDebuffBorder)
                end,
                get=getAuras,
                set=function(info, val)
                    setAuras(info, val)
                    if InCombatLockdown() then return end
                    for f in pairs(BF.activeFrames or {}) do BF:UpdateDebuffHighlight(f) end
                end,
            },
            debuffBorderWidth = {
                type="range", name="Border Width", order=54, min=1, max=5, step=1,
                hidden=borderHidden,
                disabled=function()
                    if aurasDisabled() then return true end
                    local sp = getAurasProfile("dispelIndicator")
                    return not (sp and sp.enableDebuffBorder)
                end,
                get=getAuras,
                set=function(info, val)
                    setAuras(info, val)
                    if InCombatLockdown() then return end
                    for f in pairs(BF.activeFrames or {}) do BF:LayoutFrame(f) end
                    for f in pairs(BF.activeFrames or {}) do BF:UpdateDebuffHighlight(f) end
                    -- Preview: DebuffHighlight:Layout reads the new width via
                    -- GetSectionProfileForFrame, so a layout refresh is enough.
                    if BF.RefreshPreviewLayout then BF:RefreshPreviewLayout() end
                end,
            },
            dispelBorderOnlyIfReady = {
                type="toggle", name="Only Show if Dispel Available",
                desc="When enabled, the debuff border only shows when your dispel spell is off cooldown. The GCD is not counted as a cooldown.",
                order=55,
                hidden=borderHidden,
                disabled=function()
                    if aurasDisabled() then return true end
                    local sp = getAurasProfile("dispelIndicator")
                    return not (sp and sp.enableDebuffBorder)
                end,
                get=getAuras,
                set=function(info, val)
                    setAuras(info, val)
                    if InCombatLockdown() then return end
                    if BF.UpdateDispelCooldownTracking then BF:UpdateDispelCooldownTracking() end
                    for f in pairs(BF.activeFrames or {}) do BF:UpdateDebuffHighlight(f) end
                end,
            },

            -- ── Debuff Color Overlay ─────────────────────────────────────
            debuffOverlayHeader = { type="header", name="Debuff Color Overlay", order=40, hidden=borderHidden },
            debuffOverlayNote = {
                type="description", order=41, hidden=borderHidden,
                name="Shows a semi-transparent color overlay on the frame when a player has a dispellable debuff, fading from the debuff color at the top to transparent at the bottom. Similar to Blizzard's built-in raid frame overlay.",
            },
            enableDebuffOverlay = {
                type="toggle", name="Enable Debuff Overlay", order=42,
                hidden=borderHidden,
                disabled=aurasDisabled,
                get=getAuras,
                set=function(info, val)
                    -- setAuras dispatches to RefreshDispelOnly for the
                    -- enableDebuffOverlay key (dispelIndicator subcat),
                    -- which already runs RefreshAllPrivateAuraDispelOverlays
                    -- and RefreshPreviewDummyAuras. The dispel-highlight
                    -- sweep below is separate work.
                    setAuras(info, val)
                    if InCombatLockdown() then return end
                    for f in pairs(BF.activeFrames or {}) do BF:UpdateDebuffHighlight(f) end
                end,
            },
            debuffOverlayStyle_REMOVED = {
                -- v35 follow-up: widget removed. The select only offered
                -- custom|blizzard, and the Blizzard path is now driven by
                -- the unified dispelIndicatorOverlayMode dropdown (v36
                -- rename of showBlizzardDispelIndicator) in the Blizzard
                -- Dispel Indicator section above. This stub is never
                -- rendered (hidden always-true, type=description) and exists
                -- only to keep this position in the args table stable for
                -- any external code reading widget ordering.
                type = "description", name = "", order = 42.5, hidden = function() return true end,
            },
            debuffOverlayMode = {
                -- v35 follow-up: simplified to the custom-style branch only.
                -- Pre-simplification the widget dual-wrote to debuffOverlayMode
                -- (string) or blizzardDispelOverlayMode (int) depending on
                -- the removed debuffOverlayStyle select. Now only the custom
                -- path remains — a plain string-valued select routed through
                -- the standard getAuras/setAuras helpers. The Blizzard
                -- counterpart lives at blizzardDispelOverlayMode in the
                -- Blizzard Dispel Indicator section above and is written
                -- by its own widget there.
                type="select", name="Overlay Mode", order=43,
                values={ dispellable="Dispellable by Me", allDispellable="All Dispellable", all="All Debuffs" },
                hidden=overlayHidden,
                disabled=function()
                    if aurasDisabled() then return true end
                    local sp = getAurasProfile("dispelIndicator")
                    return not (sp and sp.enableDebuffOverlay)
                end,
                get=getAuras,
                set=function(info, val)
                    setAuras(info, val)
                    if InCombatLockdown() then return end
                    for f in pairs(BF.activeFrames or {}) do BF:UpdateDebuffHighlight(f) end
                end,
            },
            debuffOverlayAlpha = {
                type="range", name="Overlay Opacity", order=44, min=0.1, max=1.0, step=0.05,
                disabled=function()
                    if aurasDisabled() then return true end
                    local sp = getAurasProfile("dispelIndicator")
                    return not (sp and sp.enableDebuffOverlay)
                end,
                hidden=overlayHidden,
                get=getAuras,
                set=function(info, val)
                    setAuras(info, val)
                    if InCombatLockdown() then return end
                    for f in pairs(BF.activeFrames or {}) do BF:UpdateDebuffHighlight(f) end
                    -- Preview: ApplyPreviewHighlights reads debuffOverlayAlpha
                    -- per-flat and re-applies SetAlpha. Granular refresh.
                    if BF.RefreshPreviewHighlights then BF:RefreshPreviewHighlights() end
                end,
            },
            debuffOverlayHeight = {
                type="range", name="Overlay Height", order=45, min=0.1, max=1.0, step=0.05,
                disabled=function()
                    if aurasDisabled() then return true end
                    local sp = getAurasProfile("dispelIndicator")
                    return not (sp and sp.enableDebuffOverlay)
                end,
                hidden=overlayHidden,
                get=getAuras,
                set=function(info, val)
                    setAuras(info, val)
                    if InCombatLockdown() then return end
                    for f in pairs(BF.activeFrames or {}) do BF:UpdateDebuffHighlight(f) end
                    -- Preview: ApplyPreviewHighlights reads debuffOverlayHeight
                    -- per-flat and re-applies SetHeight. Granular refresh.
                    if BF.RefreshPreviewHighlights then BF:RefreshPreviewHighlights() end
                end,
            },
            dispelOverlayOnlyIfReady = {
                type="toggle", name="Only Show if Dispel Available",
                desc="When enabled, the debuff overlay only shows when your dispel spell is off cooldown. The GCD is not counted as a cooldown.",
                order=46,
                disabled=function()
                    if aurasDisabled() then return true end
                    local sp = getAurasProfile("dispelIndicator")
                    return not (sp and sp.enableDebuffOverlay)
                end,
                hidden=overlayHidden,
                get=getAuras,
                set=function(info, val)
                    setAuras(info, val)
                    if InCombatLockdown() then return end
                    if BF.UpdateDispelCooldownTracking then BF:UpdateDispelCooldownTracking() end
                    for f in pairs(BF.activeFrames or {}) do BF:UpdateDebuffHighlight(f) end
                end,
            },
            debuffOverlayFillOnly = {
                type="toggle", name="Health Fill Only", order=47,
                desc="When enabled, the overlay only covers the filled portion of the health bar instead of the entire bar width.",
                disabled=function()
                    if aurasDisabled() then return true end
                    local sp = getAurasProfile("dispelIndicator")
                    return not (sp and sp.enableDebuffOverlay)
                end,
                hidden=overlayHidden,
                get=getAuras,
                set=function(info, val)
                    setAuras(info, val)
                    if InCombatLockdown() then return end
                    for f in pairs(BF.activeFrames or {}) do BF:UpdateDebuffHighlight(f) end
                end,
            },
        },
    }

    return {
        type        = "group",
        name        = "Auras",
        order       = 2,
        childGroups = "tab",
        args        = {
            _sectionTracker = {
                type = "description",
                name = function()
                    if self._currentSection ~= "auras" then
                        self._currentSection = "auras"
                        if not InCombatLockdown() then NotifyChangeSafe() end
                    end
                    return ""
                end,
                order = 0, width = "full",
            },
            showPreviewAuras = {
                type  = "toggle",
                name  = "Show Auras on Preview Frames",
                desc  = "Show dummy auras on the preview frames to the left of this panel, using each group type's aura settings.",
                order = -2,
                width = "normal",
                hidden = function() return self.db.global.showPreview == false end,
                get   = function() return self.db.global.showPreviewAuras ~= false end,
                set   = function(_, val)
                    self.db.global.showPreviewAuras = val
                    if BF.RefreshPreviewDummyAuras then BF:RefreshPreviewDummyAuras() end
                end,
            },
            simulateDispellableDebuff = {
                type  = "toggle",
                name  = "Preview Dispellable Debuff",
                desc  = "When enabled, the preview frames simulate having a dispellable debuff so dispel indicators, debuff borders and debuff overlays are shown (if their respective settings are enabled). When disabled, these are hidden unless their mode is set to 'All Debuffs'.",
                order = -1.9,
                width = "normal",
                hidden = function() return self.db.global.showPreview == false or not self.db.global.showPreviewAuras end,
                get   = function() return self.db.global.simulateDispellableDebuff ~= false end,
                set   = function(_, val)
                    self.db.global.simulateDispellableDebuff = val
                    if BF.RefreshPreviewDummyAuras then BF:RefreshPreviewDummyAuras() end
                end,
            },
            tabBuffs        = tabBuffs,
            tabDebuffs      = tabDebuffs,
            tabPrivate      = tabPrivate,
            tabBigDef       = tabBigDef,
            tabImportant    = tabImportant,
            tabCrowdControl = tabCrowdControl,
            tabDispel       = tabDispel,
        },
    }
end
