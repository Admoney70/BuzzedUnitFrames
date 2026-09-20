-- ============================================================
-- BuzzardFrames: Options_Colors.lua
-- Builds and returns the "Colors" root nav-tab args table.
-- Called from Options.lua: BF:BuildColorsOptions(deps)
--
-- Houses GLOBAL color settings that are shared across all Layouts
-- and across the Raid/Party frames + the oUF Unit Frames. These were
-- previously carve-outs inside per-section tabs (e.g. Power Bar Colors
-- lived under Health & Power Bars -> Power, bypassing the per-layout
-- plumbing) -- moving them to a dedicated root section makes the
-- global nature explicit.
--
-- Storage:
--   * Power Bar Colors -> rpDB.profile.healthPower (historical carve-out
--     from the Health & Power Bars section; kept in place for save-file
--     compatibility -- see Options_HealthPower.lua header HISTORY note).
--   * Class Colors     -> rpDB.profile.colors (dedicated top-level section
--     added alongside the Colors nav entry; mutates BF.classColors which
--     is consumed by BFStatus Health/Name/Death/Flags:GetColor and the
--     oUF health/name color paths).
--
-- Both access paths bypass GetSectionProfile because these settings
-- mutate process-wide state (BF.PowerTypeColors / BF.classColors) that
-- is consumed by indicator + oUF code globally, not per-layout.
-- ============================================================
local BF = _G["BuzzardFrames"]

function BF:BuildColorsOptions(deps)
    local self             = deps.self
    local NotifyChangeSafe = deps.NotifyChangeSafe

    -- Global-only profile accessor. Always targets rpDB.profile.healthPower
    -- regardless of per-layout toggle state -- matches the getGP() helper
    -- that used to live in Options_HealthPower.lua.
    local function getGP()
        return self.rpDB and self.rpDB.profile and self.rpDB.profile.healthPower
    end

    -- Shared post-set cascade, factored out of every per-type color setter.
    -- Mirrors the original 4-step refresh chain verbatim:
    --   1. BF:ApplyCustomPowerColors() -- copies customPowerColors into BF.PowerTypeColors
    --   2. self:UpdatePower(frame)      -- per active raid/party frame
    --   3. BF:_RefreshAllOUFPowerColors()
    --   4. BF.RefreshPreviewPowerBar() if available
    local function refreshPowerColors()
        if BF.ApplyCustomPowerColors then BF:ApplyCustomPowerColors() end
        for frame in pairs(self.activeFrames or {}) do self:UpdatePower(frame) end
        if BF._RefreshAllOUFPowerColors then BF:_RefreshAllOUFPowerColors() end
        if BF.RefreshPreviewPowerBar then BF.RefreshPreviewPowerBar() end
    end

    -- Per-power-type color widget factory. Eliminates the ~16 near-identical
    -- copies of the same widget that existed before the move.
    -- `key` is the BF.PowerTypeColors / customPowerColors key (e.g. "MANA").
    local function powerColorWidget(label, order, key)
        return {
            type="color", name=label, order=order, hasAlpha=true,
            hidden=function() local gp = getGP(); return not (gp and gp.useCustomPowerColors) end,
            disabled=InCombatLockdown,
            get=function()
                local c = BF.PowerTypeColors and BF.PowerTypeColors[key]
                if not c then return 0, 0, 0, 1 end
                return c.r, c.g, c.b, c.a or 1
            end,
            set=function(_, r, g, b, a)
                if InCombatLockdown() then return end
                local gp = getGP()
                if gp then
                    gp.customPowerColors = gp.customPowerColors or {}
                    gp.customPowerColors[key] = { r=r, g=g, b=b, a=a }
                end
                refreshPowerColors()
            end,
        }
    end

    -- ------------------------------------------------------------
    -- Class Colors carve-out
    -- ------------------------------------------------------------
    -- Lives in rpDB.profile.colors (NOT .healthPower) -- new top-level
    -- section added for this feature, declared in Defaults_RaidPartyFrames.lua.
    -- Same carve-out reasoning as power colors: mutates BF.classColors which
    -- is shared across raid/party frames and oUF unit frames globally.

    local function getColorsP()
        return self.rpDB and self.rpDB.profile and self.rpDB.profile.colors
    end

    -- Shared post-set cascade for class-color changes. Mirrors the 4-step
    -- power-color cascade:
    --   1. BF:ApplyCustomClassColors() -- copies customClassColors onto BF.classColors
    --   2. self:UpdateHealth(frame)    -- per active raid/party frame (re-reads class color)
    --   3. BF:_RefreshAllOUFClassColors() -- oUF Health ForceUpdate + name color refresh
    --   4. BF.RefreshPreviewHealthBar() if available
    --   5. BF.RefreshPreviewName()     if available -- class-colored names on
    --                                  preview frames (ApplyPreviewName reads
    --                                  fakeClassColor from BF.classColors).
    --                                  Without this call, preview name text
    --                                  keeps its stale class color after an
    --                                  edit in the Colors root section.
    --
    -- UpdateHealth is the same refresh method used by every health-color
    -- widget in Options_HealthPower.lua (useClassColors, healthColor, etc.)
    -- so the hot-path code is identical to the existing pattern.
    local function refreshClassColors()
        if BF.ApplyCustomClassColors then BF:ApplyCustomClassColors() end
        for frame in pairs(self.activeFrames or {}) do self:UpdateHealth(frame) end
        if BF._RefreshAllOUFClassColors then BF:_RefreshAllOUFClassColors() end
        if BF.RefreshPreviewHealthBar then BF.RefreshPreviewHealthBar() end
        if BF.RefreshPreviewName      then BF:RefreshPreviewName()      end
    end

    -- ------------------------------------------------------------
    -- Health Gradient Colors carve-out
    -- ------------------------------------------------------------
    -- Lives in rpDB.profile.colors (global). The useHealthGradient /
    -- useBgGradient toggles remain per-layout in healthPower; these
    -- groups only hold the color values themselves.

    -- Shared post-set cascade for health gradient color changes.
    -- Rebuilds the C_CurveUtil color curves then refreshes every
    -- frame that consumes them.
    local function refreshHealthGradientColors()
        if BF.RebuildHealthGradientCurves then BF:RebuildHealthGradientCurves() end
        for frame in pairs(self.activeFrames or {}) do self:UpdateHealth(frame) end
        if BF.RefreshHealthBarLayout then BF:RefreshHealthBarLayout() end
        if BF.RefreshPreviewHealthBar then BF:RefreshPreviewHealthBar() end
    end

    -- Factory for health gradient color widgets.
    -- `key` is the rpDB.profile.colors key (e.g. "healthGradientHigh").
    -- `fallback` is the default color table used when the key is nil.
    local function healthGradientColorWidget(label, order, key, fallback)
        return {
            type="color", name=label, order=order, hasAlpha=false,
            disabled=InCombatLockdown,
            get=function()
                local cp = getColorsP()
                local c = (cp and cp[key]) or fallback
                return c.r, c.g, c.b
            end,
            set=function(_, r, g, b)
                if InCombatLockdown() then return end
                local cp = getColorsP()
                if cp then cp[key] = { r=r, g=g, b=b } end
                refreshHealthGradientColors()
            end,
        }
    end

    -- Class color widget factory. Mirrors powerColorWidget exactly.
    -- `className` is the BF.classColors key (e.g. "WARRIOR", "DEATHKNIGHT").
    -- Reads from BF.classColors (live values, already reflecting any custom
    -- overlay) for maximum consistency with what the frames render.
    local function classColorWidget(label, order, className)
        return {
            type="color", name=label, order=order, hasAlpha=false,
            hidden=function() local cp = getColorsP(); return not (cp and cp.useCustomClassColors) end,
            disabled=InCombatLockdown,
            get=function()
                local c = BF.classColors and BF.classColors[className]
                if not c then return 1, 1, 1 end
                return c.r, c.g, c.b
            end,
            set=function(_, r, g, b)
                if InCombatLockdown() then return end
                local cp = getColorsP()
                if cp then
                    cp.customClassColors = cp.customClassColors or {}
                    cp.customClassColors[className] = { r=r, g=g, b=b }
                end
                refreshClassColors()
            end,
        }
    end

    return {
        type        = "group",
        name        = "Colors",
        order       = 6,  -- overridden in Options.lua; kept here for standalone safety
        args        = {
            powerBarColorsGroup = {
                type="group", name="Power Bar Colors", inline=true, order=1,
                args = {
                    sharedNote = {
                        type="description", order=0, width="full",
                        name="|cff11ace9These colors are shared with the Unit Frames power bar. Changes here apply to all Raid/Party and Unit Frame power bars across every Layout.|r",
                    },
                    useCustomPowerColors = {
                        type="toggle", name="Use Custom Power Colors", order=0.5, width="full",
                        desc="Override the default power type colors with custom colors.",
                        disabled=InCombatLockdown,
                        get=function() local gp = getGP(); return gp and gp.useCustomPowerColors == true end,
                        set=function(_, val)
                            if InCombatLockdown() then return end
                            local gp = getGP()
                            if gp then gp.useCustomPowerColors = val end
                            refreshPowerColors()
                        end,
                    },
                    manaColor        = powerColorWidget("Mana",         1,  "MANA"),
                    rageColor        = powerColorWidget("Rage",         2,  "RAGE"),
                    focusColor       = powerColorWidget("Focus",        3,  "FOCUS"),
                    energyColor      = powerColorWidget("Energy",       4,  "ENERGY"),
                    runicPowerColor  = powerColorWidget("Runic Power",  5,  "RUNIC_POWER"),
                    insanityColor    = powerColorWidget("Insanity",     6,  "INSANITY"),
                    maelstromColor   = powerColorWidget("Maelstrom",    7,  "MAELSTROM"),
                    lunarPowerColor  = powerColorWidget("Astral Power", 8,  "LUNAR_POWER"),
                    holyPowerColor   = powerColorWidget("Holy Power",   9,  "HOLY_POWER"),
                    furyColor        = powerColorWidget("Fury",         10, "FURY"),
                    painColor        = powerColorWidget("Pain",         11, "PAIN"),
                    essenceColor     = powerColorWidget("Essence",      12, "ESSENCE"),
                    resetColors = {
                        type="execute", name="Reset to Defaults", order=20,
                        hidden=function() local gp = getGP(); return not (gp and gp.useCustomPowerColors) end,
                        disabled=InCombatLockdown,
                        func=function()
                            if InCombatLockdown() then return end
                            local gp = getGP()
                            if gp then gp.customPowerColors = nil end
                            refreshPowerColors()
                        end,
                    },
                },
            },
            classColorsGroup = {
                type="group", name="Class Colors", inline=true, order=2,
                args = {
                    sharedNote = {
                        type="description", order=0, width="full",
                        name="|cff11ace9These colors are shared with the Unit Frames. Changes here apply to class-colored text and health bars on both the Raid/Party Frames and the Unit Frames across every Layout.|r",
                    },
                    useCustomClassColors = {
                        type="toggle", name="Use Custom Class Colors", order=0.5, width="full",
                        desc="Override the default class colors with custom colors. When disabled, BuzzardFrames uses the standard Blizzard class colors (or whatever an external class-color addon like phanxClassColors has set).",
                        disabled=InCombatLockdown,
                        get=function() local cp = getColorsP(); return cp and cp.useCustomClassColors == true end,
                        set=function(_, val)
                            if InCombatLockdown() then return end
                            local cp = getColorsP()
                            if cp then cp.useCustomClassColors = val end
                            refreshClassColors()
                        end,
                    },
                    -- 13 classes in canonical Blizzard order. classID order
                    -- would be nicer but Blizzard's UI displays them alpha-
                    -- sorted, so we match that for familiarity.
                    deathknightColor = classColorWidget("Death Knight",  1,  "DEATHKNIGHT"),
                    demonhunterColor = classColorWidget("Demon Hunter",  2,  "DEMONHUNTER"),
                    druidColor       = classColorWidget("Druid",         3,  "DRUID"),
                    evokerColor      = classColorWidget("Evoker",        4,  "EVOKER"),
                    hunterColor      = classColorWidget("Hunter",        5,  "HUNTER"),
                    mageColor        = classColorWidget("Mage",          6,  "MAGE"),
                    monkColor        = classColorWidget("Monk",          7,  "MONK"),
                    paladinColor     = classColorWidget("Paladin",       8,  "PALADIN"),
                    priestColor      = classColorWidget("Priest",        9,  "PRIEST"),
                    rogueColor       = classColorWidget("Rogue",         10, "ROGUE"),
                    shamanColor      = classColorWidget("Shaman",        11, "SHAMAN"),
                    warlockColor     = classColorWidget("Warlock",       12, "WARLOCK"),
                    warriorColor     = classColorWidget("Warrior",       13, "WARRIOR"),
                    -- Spacer: forces the Reset button onto its own row below the
                    -- color swatches without making the button itself wide.
                    -- width="full" + empty name = invisible row-break.
                    resetBreak = {
                        type="description", name="", order=19, width="full",
                        hidden=function() local cp = getColorsP(); return not (cp and cp.useCustomClassColors) end,
                    },
                    resetColors = {
                        type="execute", name="Reset to Defaults", order=20,
                        hidden=function() local cp = getColorsP(); return not (cp and cp.useCustomClassColors) end,
                        disabled=InCombatLockdown,
                        func=function()
                            if InCombatLockdown() then return end
                            local cp = getColorsP()
                            if cp then cp.customClassColors = nil end
                            refreshClassColors()
                        end,
                    },
                },
            },
            -- ------------------------------------------------------------
            -- Cast Bar Colors carve-out
            -- ------------------------------------------------------------
            -- Storage lives in ufDB.profile.castBar* (NOT rpDB) because cast
            -- bars are an oUF Unit Frame feature only -- raid/party frames
            -- don't have cast bars. Moved here from Unit Frames -> Global
            -- -> Cast Bar Colors so all global color settings live in one
            -- place. Setters unchanged from the previous location.
            castBarColorsGroup = {
                type="group", name="Cast Bar Colors", inline=true, order=3,
                args = {
                    sharedNote = {
                        type="description", order=0, width="full",
                        name="|cff11ace9These colors are shared by the Unit Frames cast bars and the Incoming Casts module.|r",
                    },
                    castBarColor = {
                        type     = "color",
                        name     = "Cast Color",
                        desc     = "Bar color when the cast can be interrupted. Applies to all unit frame cast bars.",
                        order    = 1,
                        hasAlpha = false,
                        get = function()
                            local c = self.ufDB.profile.castBarColor or { r=1, g=0.84, b=0 }
                            return c.r, c.g, c.b
                        end,
                        set = function(_, r, g, b)
                            if InCombatLockdown() then return end
                            self.ufDB.profile.castBarColor = { r=r, g=g, b=b }
                            BF:_ApplyOUFCastbarColors()
                            if BF.IncomingCasts and BF.IncomingCasts._partyPreviewShown then
                                BF.IncomingCasts:ShowPartyPreview()
                            end
                        end,
                        disabled = InCombatLockdown,
                    },
                    castBarUninterruptibleColor = {
                        type     = "color",
                        name     = "Uninterruptible Color",
                        desc     = "Bar color when the cast cannot be interrupted. Applies to all unit frame cast bars.",
                        order    = 2,
                        hasAlpha = false,
                        get = function()
                            local c = self.ufDB.profile.castBarUninterruptibleColor or { r=0.565, g=0.557, b=0.545 }
                            return c.r, c.g, c.b
                        end,
                        set = function(_, r, g, b)
                            if InCombatLockdown() then return end
                            self.ufDB.profile.castBarUninterruptibleColor = { r=r, g=g, b=b }
                            BF:_ApplyOUFCastbarColors()
                            if BF.IncomingCasts and BF.IncomingCasts._partyPreviewShown then
                                BF.IncomingCasts:ShowPartyPreview()
                            end
                        end,
                        disabled = InCombatLockdown,
                    },
                    castBarBgColor = {
                        type     = "color",
                        name     = "Background Color",
                        desc     = "Cast bar background color. Applies to all unit frame cast bars.",
                        order    = 3,
                        hasAlpha = true,
                        get = function()
                            local c = self.ufDB.profile.castBarBgColor or { r=0, g=0, b=0, a=0.6 }
                            return c.r, c.g, c.b, c.a or 0.6
                        end,
                        set = function(_, r, g, b, a)
                            if InCombatLockdown() then return end
                            self.ufDB.profile.castBarBgColor = { r=r, g=g, b=b, a=a }
                            BF:_ApplyOUFCastbarBgColor()
                            if BF.IncomingCasts and BF.IncomingCasts._partyPreviewShown then
                                BF.IncomingCasts:ShowPartyPreview()
                            end
                        end,
                        disabled = InCombatLockdown,
                    },
                },
            },
            healthGradientColorsGroup = {
                type="group", name="Health Gradient Colors", inline=true, order=4,
                args = {
                    sharedNote = {
                        type="description", order=0, width="full",
                        name="|cff11ace9These colors are shared by the Raid/Party Frames and the Unit Frames.|r",
                    },
                    healthGradientHigh = healthGradientColorWidget("Full Health",  1, "healthGradientHigh", { r=0.0, g=0.8, b=0.0 }),
                    healthGradientMid  = healthGradientColorWidget("Half Health",  2, "healthGradientMid",  { r=0.9, g=0.6, b=0.0 }),
                    healthGradientLow  = healthGradientColorWidget("Low Health",   3, "healthGradientLow",  { r=0.8, g=0.0, b=0.0 }),
                    resetColors = {
                        type="execute", name="Reset to Defaults", order=10,
                        disabled=InCombatLockdown,
                        func=function()
                            if InCombatLockdown() then return end
                            local cp = getColorsP()
                            if cp then
                                cp.healthGradientHigh = nil
                                cp.healthGradientMid  = nil
                                cp.healthGradientLow  = nil
                            end
                            refreshHealthGradientColors()
                        end,
                    },
                },
            },
            bgGradientColorsGroup = {
                type="group", name="Background Health Gradient Colors", inline=true, order=5,
                args = {
                    sharedNote = {
                        type="description", order=0, width="full",
                        name="|cff11ace9These colors are shared by the Raid/Party Frames and the Unit Frames.|r",
                    },
                    bgGradientHigh = healthGradientColorWidget("Full Health",  1, "bgGradientHigh", { r=0.0, g=0.3, b=0.0 }),
                    bgGradientMid  = healthGradientColorWidget("Half Health",  2, "bgGradientMid",  { r=0.3, g=0.2, b=0.0 }),
                    bgGradientLow  = healthGradientColorWidget("Low Health",   3, "bgGradientLow",  { r=0.3, g=0.0, b=0.0 }),
                    resetColors = {
                        type="execute", name="Reset to Defaults", order=10,
                        disabled=InCombatLockdown,
                        func=function()
                            if InCombatLockdown() then return end
                            local cp = getColorsP()
                            if cp then
                                cp.bgGradientHigh = nil
                                cp.bgGradientMid  = nil
                                cp.bgGradientLow  = nil
                            end
                            refreshHealthGradientColors()
                        end,
                    },
                },
            },
        },
    }
end
