-- ============================================================
-- BuzzardFrames: Options_oUF_Player_Target.lua
-- Builds the makeFrameOpts factory, Player/Target/Global option
-- tables. Returns them to BuildPTFOptionsTable in Other.lua.
-- ============================================================
local BF = _G["BuzzardFrames"]

function BF:_BuildPlayerTargetOpts(deps)
    local self            = deps.self
    local ufGet           = deps.ufGet
    local ufSet           = deps.ufSet
    local promptReload    = deps.promptReload
    local relayoutPlayer  = deps.relayoutPlayer
    local updatePlayer    = deps.updatePlayer
    local relayoutTarget  = deps.relayoutTarget
    local updateTarget    = deps.updateTarget
    local relayoutAll     = deps.relayoutAll
    local updateAll       = deps.updateAll
    local get             = deps.get
    local makePosGroup    = deps.makePosGroup

    -- Shared tooltip descriptions for classification color pickers.
    -- Used by both Health Bar Colors and Name Bar Colors tabs.
    local DESC_FRIENDLY    = "NPCs with a friendly reaction."
    local DESC_NEUTRAL     = "NPCs with a neutral (yellow) reaction. In combat, they get classified as an enemy type instead."
    local DESC_REGULAR     = "All other hostile NPCs that don't match a more specific classification."
    local DESC_BOSS        = "World bosses, level ?? enemies, and enemies 2+ levels above you."
    local DESC_LIEUTENANT  = "Enemies 1 level above you, or flagged as lieutenants."
    local DESC_CASTER      = "Enemies with mana, plus Paladin and Mage class NPCs."
    local DESC_TRIVIAL     = "Trivial and minus (grey) enemies."

    -- Factory that builds a full Player or Target options tab.
    local function makeFrameOpts(unit, tabName, tabOrder, enableKey, oufFrame, relayout, update, labelName)
        labelName = labelName or tabName
        local function isDisabled() return not self.ufDB.profile[enableKey] end

        -- ── Sub-tab 1: Size & Position ────────────────────────────────────────
        local sizeArgs = {}
        sizeArgs.enableToggle = {
            type     = "toggle",
            name     = "Enable " .. labelName,
            order    = 1,
            width    = "full",
            get      = function() return self.ufDB.profile[enableKey] end,
            set      = function(_, val)
                if InCombatLockdown() then return end
                self.ufDB.profile[enableKey] = val
                promptReload()
            end,
            disabled = InCombatLockdown,
        }
        sizeArgs._posTracker = {
            type = "description", name = function()
                if sizeArgs.ufAnchorX then BF:ClampPositionSlider({ option = sizeArgs.ufAnchorX }, "x") end
                if sizeArgs.ufAnchorY then BF:ClampPositionSlider({ option = sizeArgs.ufAnchorY }, "y") end
                return ""
            end,
            order = 3, width = "full", hidden = isDisabled,
        }
        sizeArgs.hdrPosition = { type="header", name="Position", order=4, hidden=isDisabled }
        sizeArgs.ufAnchorX = {
            type="range", name="X Position", order=5,
            desc="Horizontal position of the frame anchor.",
            softMin=-1024, softMax=1024, step=1,
            get = function(info)
                BF:ClampPositionSlider(info, "x")
                local halfW = BF:GetPositionHalfW()
                local x = BF:GetUFAnchor(unit)
                x = x or (ufGet(unit, "anchorX") or 0)
                return math.floor(x - halfW + 0.5)
            end,
            set = function(_, v)
                if InCombatLockdown() then return end
                v = math.floor(v + 0.5)
                local halfW = BF:GetPositionHalfW()
                local storeX = v + halfW
                local _, curY = BF:GetUFAnchor(unit)
                BF:SetUFAnchor(unit, storeX, curY or (ufGet(unit, "anchorY") or 0))
                relayout()
            end,
            disabled = InCombatLockdown, hidden = isDisabled,
        }
        sizeArgs.ufAnchorY = {
            type="range", name="Y Position", order=6,
            desc="Vertical position of the frame anchor.",
            softMin=-1024, softMax=1024, step=1,
            get = function(info)
                BF:ClampPositionSlider(info, "y")
                local halfH = BF:GetPositionHalfH()
                local _, y = BF:GetUFAnchor(unit)
                y = y or (ufGet(unit, "anchorY") or 0)
                return math.floor(y - halfH + 0.5)
            end,
            set = function(_, v)
                if InCombatLockdown() then return end
                v = math.floor(v + 0.5)
                local halfH = BF:GetPositionHalfH()
                local storeY = v + halfH
                local curX = BF:GetUFAnchor(unit)
                BF:SetUFAnchor(unit, curX or (ufGet(unit, "anchorX") or 0), storeY)
                relayout()
            end,
            disabled = InCombatLockdown, hidden = isDisabled,
        }
        sizeArgs.hdrSize = { type="header", name="Size", order=10, hidden=isDisabled }
        sizeArgs.frameWidth = {
            type="range", name="Width", order=11,
            min=80, max=400, step=1,
            get      = function() return ufGet(unit, "frameWidth") or 156 end,
            set      = function(_, v) ufSet(unit, "frameWidth", v); relayout() end,
            disabled = InCombatLockdown, hidden = isDisabled,
        }
        sizeArgs.frameScale = {
            type="range", name="Scale", order=12,
            min=0.5, max=2.0, step=0.05,
            get      = function() return ufGet(unit, "frameScale") or 1.0 end,
            set      = function(_, v) ufSet(unit, "frameScale", v); relayout() end,
            disabled = InCombatLockdown, hidden = isDisabled,
        }
        sizeArgs.iconScale = {
            type="range", name="Icon Scale", order=13,
            min=0.5, max=2.0, step=0.05,
            get      = function() return ufGet(unit, "iconScale") or 1.0 end,
            set      = function(_, v) ufSet(unit, "iconScale", v); relayout() end,
            disabled = InCombatLockdown, hidden = isDisabled,
        }
        sizeArgs.frameAlpha = {
            type="range", name="Alpha", order=14,
            min=0.1, max=1.0, step=0.05,
            get      = function() return ufGet(unit, "frameAlpha") or 1.0 end,
            set      = function(_, v)
                ufSet(unit, "frameAlpha", v)
                if oufFrame() then oufFrame():SetAlpha(v) end
            end,
            disabled = InCombatLockdown, hidden = isDisabled,
        }
        sizeArgs.hdrBars = { type="header", name="Bar Heights", order=20, hidden=isDisabled }
        sizeArgs.nameBarHeight = {
            type="range", name="Name Bar Height", order=21,
            min=8, max=30, step=1,
            get      = function() return ufGet(unit, "nameBarHeight") or 13 end,
            set      = function(_, v) ufSet(unit, "nameBarHeight", v); relayout() end,
            disabled = InCombatLockdown, hidden = isDisabled,
        }
        sizeArgs.healthBarHeight = {
            type="range", name="Health Bar Height", order=22,
            min=8, max=50, step=1,
            get      = function() return ufGet(unit, "healthBarHeight") or 22 end,
            set      = function(_, v) ufSet(unit, "healthBarHeight", v); relayout() end,
            disabled = InCombatLockdown, hidden = isDisabled,
        }
        sizeArgs.powerBarHeight = {
            type="range", name="Power Bar Height", order=23,
            min=4, max=20, step=1,
            get      = function() return ufGet(unit, "powerBarHeight") or 10 end,
            set      = function(_, v) ufSet(unit, "powerBarHeight", v); relayout() end,
            disabled = InCombatLockdown, hidden = isDisabled,
        }
        local sizeTab = {
            type  = "group",
            name  = "Size & Position",
            order = 1,
            args  = sizeArgs,
        }

        -- ── Sub-tab 2: Health Bar ─────────────────────────────────────────────
        local healthTab = {
            type  = "group",
            name  = "Health Bar",
            order = 2,
            args  = {
                hdrText = { type="header", name="Text", order=10 },
                showHealthPct = {
                    type="toggle", name="Show Health Percent", order=11,
                    get = function() return ufGet(unit, "showHealthPct") ~= false end,
                    set = function(_, v) ufSet(unit, "showHealthPct", v); update() end,
                },
                showHealthVal = {
                    type="toggle", name="Show Health Value", order=12,
                    get = function() return ufGet(unit, "showHealthVal") ~= false end,
                    set = function(_, v) ufSet(unit, "showHealthVal", v); update() end,
                },
                healthFontSize = {
                    type="range", name="Font Size", order=13,
                    min=6, max=16, step=1,
                    get      = function() return ufGet(unit, "healthFontSize") or 8 end,
                    set      = function(_, v) ufSet(unit, "healthFontSize", v); relayout(); update() end,
                    disabled = InCombatLockdown,
                },
                healthPctPosGroup = makePosGroup(
                    unit, "Percent Position", "healthPctPos", "LEFT",  3,   14, relayout, update),
                healthValPosGroup = makePosGroup(
                    unit, "Value Position",   "healthValPos", "RIGHT", -10, 15, relayout, update),
                hdrColor = { type="header", name="Color", order=20,
                    hidden = function() return unit ~= "player" end,
                },
                useClassColor = {
                    type="toggle", name="Use Class Color", order=21,
                    get = function() return ufGet(unit, "useClassColor") end,
                    set = function(_, v)
                        ufSet(unit, "useClassColor", v)
                        local f = oufFrame()
                        if f and f.Health and f.unit then
                            local r, g, b = BF:_GetOUFHealthColor(f.unit, v, unit)
                            f.Health:SetStatusBarColor(r, g, b)
                        end
                    end,
                    hidden = function() return unit ~= "player" end,
                },
                healthColor = {
                    type="color", name="Health Color", order=22, hasAlpha=false,
                    get = function()
                        local c = ufGet(unit, "healthColor") or { r=0.24, g=0.78, b=0.24 }
                        return c.r, c.g, c.b
                    end,
                    set = function(_, r, g, b)
                        ufSet(unit, "healthColor", { r=r, g=g, b=b })
                        local f = oufFrame()
                        if f and f.Health and f.unit then
                            local nr, ng, nb = BF:_GetOUFHealthColor(f.unit, ufGet(unit, "useClassColor"), unit)
                            f.Health:SetStatusBarColor(nr, ng, nb)
                        end
                    end,
                    disabled = InCombatLockdown,
                    hidden   = function() return unit ~= "player" or ufGet(unit, "useClassColor") == true end,
                },
            },
        }

        -- ── Sub-tab 2b: Name Bar ─────────────────────────────────────────────
        local nameTab = {
            type  = "group",
            name  = "Name Bar",
            order = 2,
            args  = {
                hdrName = { type="header", name="Name Text", order=10 },
                showName = {
                    type="toggle", name="Show Name", order=11,
                    get = function() return ufGet(unit, "showName") ~= false end,
                    set = function(_, v)
                        ufSet(unit, "showName", v)
                        relayout()
                    end,
                },
                nameFontSize = {
                    type="range", name="Font Size", order=12,
                    min=6, max=20, step=1,
                    get      = function() return ufGet(unit, "nameFontSize") or 11 end,
                    set      = function(_, v) ufSet(unit, "nameFontSize", v); relayout() end,
                    disabled = InCombatLockdown,
                    hidden   = function() return ufGet(unit, "showName") == false end,
                },
                nameOffsetX = {
                    type="range", name="X Offset", order=13,
                    min=-200, max=200, step=1, softMin=-50, softMax=50,
                    get      = function()
                        local isPlayer = (unit == "player")
                        return ufGet(unit, "nameOffsetX") or (isPlayer and 21 or -21)
                    end,
                    set      = function(_, v) ufSet(unit, "nameOffsetX", v); relayout() end,
                    disabled = InCombatLockdown,
                    hidden   = function() return ufGet(unit, "showName") == false end,
                },
                nameOffsetY = {
                    type="range", name="Y Offset", order=14,
                    min=-50, max=50, step=1,
                    get      = function() return ufGet(unit, "nameOffsetY") or -2 end,
                    set      = function(_, v) ufSet(unit, "nameOffsetY", v); relayout() end,
                    disabled = InCombatLockdown,
                    hidden   = function() return ufGet(unit, "showName") == false end,
                },
                hdrLevel = { type="header", name="Level Text", order=20 },
                showLevel = {
                    type="toggle", name="Show Level", order=21,
                    get = function() return ufGet(unit, "showLevel") ~= false end,
                    set = function(_, v)
                        ufSet(unit, "showLevel", v)
                        relayout()
                    end,
                },
                levelFontSize = {
                    type="range", name="Font Size", order=22,
                    min=6, max=20, step=1,
                    get      = function() return ufGet(unit, "levelFontSize") or 10 end,
                    set      = function(_, v) ufSet(unit, "levelFontSize", v); relayout() end,
                    disabled = InCombatLockdown,
                    hidden   = function() return ufGet(unit, "showLevel") == false end,
                },
                levelOffsetX = {
                    type="range", name="X Offset", order=23,
                    min=-200, max=200, step=1, softMin=-50, softMax=50,
                    get      = function()
                        local isPlayer = (unit == "player")
                        return ufGet(unit, "levelOffsetX") or (isPlayer and -4 or 4)
                    end,
                    set      = function(_, v) ufSet(unit, "levelOffsetX", v); relayout() end,
                    disabled = InCombatLockdown,
                    hidden   = function() return ufGet(unit, "showLevel") == false end,
                },
                levelOffsetY = {
                    type="range", name="Y Offset", order=24,
                    min=-50, max=50, step=1,
                    get      = function() return ufGet(unit, "levelOffsetY") or -2 end,
                    set      = function(_, v) ufSet(unit, "levelOffsetY", v); relayout() end,
                    disabled = InCombatLockdown,
                    hidden   = function() return ufGet(unit, "showLevel") == false end,
                },
                hdrNameColor = { type="header", name="Name Color", order=15,
                    hidden = function() return unit ~= "player" and unit ~= "pet" end,
                },
                useClassColorName = {
                    type="toggle", name="Use Class Color", order=16,
                    get = function() return ufGet(unit, "useClassColorName") end,
                    set = function(_, v)
                        ufSet(unit, "useClassColorName", v)
                        relayout(); update()
                    end,
                    hidden = function() return unit ~= "player" and unit ~= "pet" end,
                },
                nameColor = {
                    type="color", name="Name Color", order=17, hasAlpha=false,
                    get = function()
                        local c = ufGet(unit, "nameColor") or { r=1, g=1, b=1 }
                        return c.r, c.g, c.b
                    end,
                    set = function(_, r, g, b)
                        ufSet(unit, "nameColor", { r=r, g=g, b=b })
                        relayout(); update()
                    end,
                    disabled = InCombatLockdown,
                    hidden   = function() return (unit ~= "player" and unit ~= "pet") or ufGet(unit, "useClassColorName") == true end,
                },
                hdrLevelColor = { type="header", name="Level Color", order=25 },
                levelColor = {
                    type="color", name="Level Color", order=26, hasAlpha=false,
                    get = function()
                        local c = ufGet(unit, "levelColor") or { r=1, g=0.82, b=0 }
                        return c.r, c.g, c.b
                    end,
                    set = function(_, r, g, b)
                        ufSet(unit, "levelColor", { r=r, g=g, b=b })
                        relayout(); update()
                    end,
                    disabled = InCombatLockdown,
                    hidden   = function() return ufGet(unit, "showLevel") == false end,
                },
            },
        }

        -- ── Sub-tab 3: Power Bar ──────────────────────────────────────────────
        local powerTab = {
            type  = "group",
            name  = "Power Bar",
            order = 3,
            args  = {
                hdrText = { type="header", name="Text", order=10 },
                showPowerPct = {
                    type="toggle", name="Show Power Percent", order=11,
                    get = function() return ufGet(unit, "showPowerPct") ~= false end,
                    set = function(_, v) ufSet(unit, "showPowerPct", v); update() end,
                },
                showPowerVal = {
                    type="toggle", name="Show Power Value", order=12,
                    get = function() return ufGet(unit, "showPowerVal") ~= false end,
                    set = function(_, v) ufSet(unit, "showPowerVal", v); update() end,
                },
                powerFontSize = {
                    type="range", name="Font Size", order=13,
                    min=6, max=16, step=1,
                    get      = function() return ufGet(unit, "powerFontSize") or 7 end,
                    set      = function(_, v) ufSet(unit, "powerFontSize", v); relayout(); update() end,
                    disabled = InCombatLockdown,
                },
                powerPctPosGroup = makePosGroup(
                    unit, "Percent Position", "powerPctPos", "LEFT",  3,   14, relayout, update),
                powerValPosGroup = makePosGroup(
                    unit, "Value Position",   "powerValPos", "RIGHT", -10, 15, relayout, update),
                hdrPowerBarDetach = {
                    type="header", name="Detach", order=40,
                    hidden = function() return isDisabled() or unit ~= "player" end,
                },
                oufPowerBarDetached = {
                    type="toggle", name="Detach Power Bar", order=41,
                    desc="When detached, the power bar can be positioned independently. Unlock frames to drag it.",
                    width="full",
                    get  = function() return BF:GetUFDetachState("playerPowerBar") end,
                    set  = function(_, v)
                        if InCombatLockdown() then return end
                        BF:SetUFDetachState("playerPowerBar", v)
                        relayout()
                    end,
                    disabled = InCombatLockdown,
                    hidden = function() return isDisabled() or unit ~= "player" end,
                },
                oufPowerBarWidth = {
                    type="range", name="Detached Width", order=42,
                    min=40, max=600, step=1,
                    get  = function() return self.ufDB.profile.oufPowerBarWidth or (ufGet(unit, "frameWidth") or 156) end,
                    set  = function(_, v)
                        if InCombatLockdown() then return end
                        self.ufDB.profile.oufPowerBarWidth = v
                        relayout()
                    end,
                    disabled = InCombatLockdown,
                    hidden = function() return isDisabled() or unit ~= "player" or self.ufDB.profile.oufPowerBarDetached ~= true end,
                },
                oufPowerBarHeight = {
                    type="range", name="Detached Height", order=43,
                    min=4, max=30, step=1,
                    get  = function() return self.ufDB.profile.oufPowerBarHeight or (ufGet(unit, "powerBarHeight") or 10) end,
                    set  = function(_, v)
                        if InCombatLockdown() then return end
                        self.ufDB.profile.oufPowerBarHeight = v
                        relayout()
                    end,
                    disabled = InCombatLockdown,
                    hidden = function() return isDisabled() or unit ~= "player" or self.ufDB.profile.oufPowerBarDetached ~= true end,
                },
            },
        }

        -- Fix orders so tabs appear in the right sequence
        sizeTab.order   = 1
        nameTab.order   = 2
        healthTab.order = 3
        powerTab.order  = 4
        -- aurasTab injected at order 8, resourceTab at order 6, astralPowerTab at order 7 (player only)

        -- Non-size sub-tabs are hidden when the frame is disabled so the
        -- user only sees "Size & Position" (which holds the enable toggle).
        nameTab.hidden   = isDisabled
        healthTab.hidden = isDisabled
        powerTab.hidden  = isDisabled

        return {
            type        = "group",
            name        = tabName,
            order       = tabOrder,
            childGroups = "tab",
            args        = {
                sizeTab   = sizeTab,
                nameTab   = nameTab,
                healthTab = healthTab,
                powerTab  = powerTab,
            },
        }
    end

    local bluzzPlayerOpts = makeFrameOpts(
        "player", "Player Frame", 1,
        "showPlayerFrame",
        function() return BF.oufPlayer end,
        relayoutPlayer, updatePlayer)

    local function playerFrameDisabled()
        return not self.ufDB.profile.showPlayerFrame
    end
    -- healthTab/powerTab/nameTab already have hidden=isDisabled from makeFrameOpts;
    -- re-assert with the named helper so the reference is consistent.
    bluzzPlayerOpts.args.nameTab.hidden   = playerFrameDisabled
    bluzzPlayerOpts.args.healthTab.hidden = playerFrameDisabled
    bluzzPlayerOpts.args.powerTab.hidden  = playerFrameDisabled

    -- ── Player sub-tab: Alt Power Bar ─────────────────────────────────────
    do
        local function altLayout()
            if BF.ApplyOUFAltPowerBarLayout then BF:ApplyOUFAltPowerBarLayout() end
        end
        local function altUpdate()
            if BF.UpdateOUFAltPowerBar then BF:UpdateOUFAltPowerBar() end
        end
        local function altLayoutUpdate()
            altLayout(); altUpdate()
        end

        bluzzPlayerOpts.args.altPowerTab = {
            type  = "group",
            name  = "Alt Power Bar",
            order = 5,
            hidden = playerFrameDisabled,
            args  = {
                -- ── Enable ────────────────────────────────────────────────
                showAltPowerBar = {
                    type = "toggle", name = "Enable Alt Power Bar", order = 1,
                    desc = "Show a secondary power bar when in a shapeshift form.",
                    width = "full",
                    get  = function() return self.ufDB.profile.showAltPowerBar ~= false end,
                    set  = function(_, v)
                        self.ufDB.profile.showAltPowerBar = v
                        altLayoutUpdate()
                        if BF.oufPlayer then BF:ApplyOUFPlayerLayout() end
                    end,
                },
                -- ── Druid Forms ────────────────────────────────────────────
                hdrDruidForms = { type = "header", name = "Druid Specializations", order = 10,
                    hidden = function() return not self.ufDB.profile.showAltPowerBar end,
                },
                druidFormsDesc = {
                    type = "description", order = 11, width = "full",
                    name = "Enable/disable the alt power (mana) bar per Druid specialization.",
                    hidden = function() return not self.ufDB.profile.showAltPowerBar end,
                },
                druidRestoration = {
                    type = "toggle", name = "Restoration", order = 12,
                    get  = function() return (self.ufDB.profile.altPowerBarDruidSpecs or {}).restoration ~= false end,
                    set  = function(_, v)
                        self.ufDB.profile.altPowerBarDruidSpecs = self.ufDB.profile.altPowerBarDruidSpecs or {}
                        self.ufDB.profile.altPowerBarDruidSpecs.restoration = v
                        altLayoutUpdate()
                    end,
                    hidden = function() return not self.ufDB.profile.showAltPowerBar end,
                },
                druidGuardian = {
                    type = "toggle", name = "Guardian", order = 13,
                    get  = function() return (self.ufDB.profile.altPowerBarDruidSpecs or {}).guardian == true end,
                    set  = function(_, v)
                        self.ufDB.profile.altPowerBarDruidSpecs = self.ufDB.profile.altPowerBarDruidSpecs or {}
                        self.ufDB.profile.altPowerBarDruidSpecs.guardian = v
                        altLayoutUpdate()
                    end,
                    hidden = function() return not self.ufDB.profile.showAltPowerBar end,
                },
                druidBalance = {
                    type = "toggle", name = "Balance", order = 14,
                    get  = function() return (self.ufDB.profile.altPowerBarDruidSpecs or {}).balance ~= false end,
                    set  = function(_, v)
                        self.ufDB.profile.altPowerBarDruidSpecs = self.ufDB.profile.altPowerBarDruidSpecs or {}
                        self.ufDB.profile.altPowerBarDruidSpecs.balance = v
                        altLayoutUpdate()
                        if BF.oufPlayer then BF:ApplyOUFPlayerLayout() end
                    end,
                    hidden = function() return not self.ufDB.profile.showAltPowerBar end,
                },
                druidFeral = {
                    type = "toggle", name = "Feral", order = 15,
                    get  = function() return (self.ufDB.profile.altPowerBarDruidSpecs or {}).feral == true end,
                    set  = function(_, v)
                        self.ufDB.profile.altPowerBarDruidSpecs = self.ufDB.profile.altPowerBarDruidSpecs or {}
                        self.ufDB.profile.altPowerBarDruidSpecs.feral = v
                        altLayoutUpdate()
                    end,
                    hidden = function() return not self.ufDB.profile.showAltPowerBar end,
                },
                -- ── Placement ──────────────────────────────────────────────
                hdrPlacement = { type = "header", name = "Placement", order = 20,
                    hidden = function() return not self.ufDB.profile.showAltPowerBar end,
                },
                altPowerBarDetached = {
                    type = "toggle", name = "Detach", order = 21,
                    desc = "When detached, the bar can be positioned independently. Unlock frames to drag it.",
                    get  = function() return self.ufDB.profile.altPowerBarDetached or false end,
                    set  = function(_, v)
                        if InCombatLockdown() then return end
                        self.ufDB.profile.altPowerBarDetached = v
                        altLayout()
                        if BF.oufPlayer then BF:ApplyOUFPlayerLayout() end
                    end,
                    hidden = function() return not self.ufDB.profile.showAltPowerBar end,
                },
                -- ── Size ──────────────────────────────────────────────────
                hdrSize = { type = "header", name = "Size", order = 30,
                    hidden = function() return not self.ufDB.profile.showAltPowerBar end,
                },
                altPowerBarHeight = {
                    type = "range", name = "Height", order = 31,
                    min = 1, max = 20, step = 1,
                    get  = function() return self.ufDB.profile.altPowerBarHeight or 3 end,
                    set  = function(_, v)
                        self.ufDB.profile.altPowerBarHeight = v
                        altLayout()
                        if BF.oufPlayer then BF:ApplyOUFPlayerLayout() end
                    end,
                    hidden = function() return not self.ufDB.profile.showAltPowerBar end,
                    disabled = InCombatLockdown,
                },
                oufAltPowerBarWidth = {
                    type = "range", name = "Width", order = 32,
                    min = 30, max = 300, step = 1,
                    get  = function() return self.ufDB.profile.oufAltPowerBarWidth or 156 end,
                    set  = function(_, v)
                        self.ufDB.profile.oufAltPowerBarWidth = v
                        altLayout()
                    end,
                    hidden = function() return not self.ufDB.profile.showAltPowerBar or not self.ufDB.profile.altPowerBarDetached end,
                    disabled = InCombatLockdown,
                },
                -- ── Text ──────────────────────────────────────────────────
                hdrText = { type = "header", name = "Text", order = 40,
                    hidden = function() return not self.ufDB.profile.showAltPowerBar end,
                },
                altPowerShowPct = {
                    type = "toggle", name = "Show Percent", order = 41,
                    get  = function() return self.ufDB.profile.altPowerShowPct ~= false end,
                    set  = function(_, v) self.ufDB.profile.altPowerShowPct = v; altUpdate() end,
                    hidden = function() return not self.ufDB.profile.showAltPowerBar end,
                },
                altPowerShowVal = {
                    type = "toggle", name = "Show Value", order = 42,
                    get  = function() return self.ufDB.profile.altPowerShowVal == true end,
                    set  = function(_, v) self.ufDB.profile.altPowerShowVal = v; altUpdate() end,
                    hidden = function() return not self.ufDB.profile.showAltPowerBar end,
                },
                altPowerFontSize = {
                    type = "range", name = "Font Size", order = 43,
                    min = 6, max = 16, step = 1,
                    get  = function() return self.ufDB.profile.altPowerFontSize or 7 end,
                    set  = function(_, v) self.ufDB.profile.altPowerFontSize = v; altLayout() end,
                    hidden = function() return not self.ufDB.profile.showAltPowerBar end,
                    disabled = InCombatLockdown,
                },
                altPowerPctPosGroup = {
                    type = "group", name = "Percent Position", inline = true, order = 44,
                    hidden = function() return not self.ufDB.profile.showAltPowerBar or not self.ufDB.profile.altPowerShowPct end,
                    args = {
                        point = {
                            type = "select", name = "Anchor", order = 1,
                            values = { LEFT = "Left", CENTER = "Center", RIGHT = "Right" },
                            get = function() return (self.ufDB.profile.altPowerPctPos or {}).point or "RIGHT" end,
                            set = function(_, v)
                                if not self.ufDB.profile.altPowerPctPos then self.ufDB.profile.altPowerPctPos = {} end
                                self.ufDB.profile.altPowerPctPos.point = v
                                altLayout()
                            end,
                        },
                        x = {
                            type = "range", name = "X Offset", order = 2,
                            min = -20, max = 20, step = 1,
                            get = function() return (self.ufDB.profile.altPowerPctPos or {}).x or -3 end,
                            set = function(_, v)
                                if not self.ufDB.profile.altPowerPctPos then self.ufDB.profile.altPowerPctPos = {} end
                                self.ufDB.profile.altPowerPctPos.x = v
                                altLayout()
                            end,
                        },
                        y = {
                            type = "range", name = "Y Offset", order = 3,
                            min = -10, max = 10, step = 1,
                            get = function() return (self.ufDB.profile.altPowerPctPos or {}).y or 0 end,
                            set = function(_, v)
                                if not self.ufDB.profile.altPowerPctPos then self.ufDB.profile.altPowerPctPos = {} end
                                self.ufDB.profile.altPowerPctPos.y = v
                                altLayout()
                            end,
                        },
                    },
                },
                altPowerValPosGroup = {
                    type = "group", name = "Value Position", inline = true, order = 45,
                    hidden = function() return not self.ufDB.profile.showAltPowerBar or not self.ufDB.profile.altPowerShowVal end,
                    args = {
                        point = {
                            type = "select", name = "Anchor", order = 1,
                            values = { LEFT = "Left", CENTER = "Center", RIGHT = "Right" },
                            get = function() return (self.ufDB.profile.altPowerValPos or {}).point or "LEFT" end,
                            set = function(_, v)
                                if not self.ufDB.profile.altPowerValPos then self.ufDB.profile.altPowerValPos = {} end
                                self.ufDB.profile.altPowerValPos.point = v
                                altLayout()
                            end,
                        },
                        x = {
                            type = "range", name = "X Offset", order = 2,
                            min = -20, max = 20, step = 1,
                            get = function() return (self.ufDB.profile.altPowerValPos or {}).x or 3 end,
                            set = function(_, v)
                                if not self.ufDB.profile.altPowerValPos then self.ufDB.profile.altPowerValPos = {} end
                                self.ufDB.profile.altPowerValPos.x = v
                                altLayout()
                            end,
                        },
                        y = {
                            type = "range", name = "Y Offset", order = 3,
                            min = -10, max = 10, step = 1,
                            get = function() return (self.ufDB.profile.altPowerValPos or {}).y or 0 end,
                            set = function(_, v)
                                if not self.ufDB.profile.altPowerValPos then self.ufDB.profile.altPowerValPos = {} end
                                self.ufDB.profile.altPowerValPos.y = v
                                altLayout()
                            end,
                        },
                    },
                },
            },
        }
    end

    -- ── Player nameTab: move Level Color into Level Text section, add Raid Group ──
    do
        local pNameArgs = bluzzPlayerOpts.args.nameTab.args
        -- Remove the standalone "Level Color" header for the player frame;
        -- the level color picker (order 26) stays inside the Level Text section.
        pNameArgs.hdrLevelColor = nil
        -- Add "Hide at Max Level" toggle for the player frame
        pNameArgs.hideLevelAtMax = {
            type="toggle", name="Hide at Max Level", order=21.5,
            desc="Hide the level text when the player is at maximum level.",
            get = function() return ufGet("player", "hideLevelAtMax") == true end,
            set = function(_, v)
                ufSet("player", "hideLevelAtMax", v)
                relayoutPlayer()
            end,
            hidden = function() return ufGet("player", "showLevel") == false end,
        }
        -- Add Raid Group Text section in its place
        pNameArgs.hdrRaidGroup = { type="header", name="Raid Group Text", order=40 }
        pNameArgs.showRaidGroup = {
            type="toggle", name="Show Raid Group", order=41,
            desc="Show a raid group indicator on the player frame name bar. Only visible when in a raid group.",
            get = function() return ufGet("player", "showRaidGroup") == true end,
            set = function(_, v)
                ufSet("player", "showRaidGroup", v)
                relayoutPlayer()
            end,
        }
        pNameArgs.raidGroupNumberOnly = {
            type="toggle", name="Number Only", order=42,
            desc="Show just the group number [X] instead of [Group X].",
            get = function() return ufGet("player", "raidGroupNumberOnly") == true end,
            set = function(_, v)
                ufSet("player", "raidGroupNumberOnly", v)
                relayoutPlayer()
            end,
            hidden = function() return ufGet("player", "showRaidGroup") ~= true end,
        }
        pNameArgs.raidGroupFontSize = {
            type="range", name="Font Size", order=43,
            min=6, max=20, step=1,
            get      = function() return ufGet("player", "raidGroupFontSize") or 11 end,
            set      = function(_, v) ufSet("player", "raidGroupFontSize", v); relayoutPlayer() end,
            disabled = InCombatLockdown,
            hidden   = function() return ufGet("player", "showRaidGroup") ~= true end,
        }
        pNameArgs.raidGroupOffsetX = {
            type="range", name="X Offset", order=44,
            min=-200, max=200, step=1, softMin=-50, softMax=50,
            get      = function() return ufGet("player", "raidGroupOffsetX") or 0 end,
            set      = function(_, v) ufSet("player", "raidGroupOffsetX", v); relayoutPlayer() end,
            disabled = InCombatLockdown,
            hidden   = function() return ufGet("player", "showRaidGroup") ~= true end,
        }
        pNameArgs.raidGroupOffsetY = {
            type="range", name="Y Offset", order=45,
            min=-50, max=50, step=1,
            get      = function() return ufGet("player", "raidGroupOffsetY") or 0 end,
            set      = function(_, v) ufSet("player", "raidGroupOffsetY", v); relayoutPlayer() end,
            disabled = InCombatLockdown,
            hidden   = function() return ufGet("player", "showRaidGroup") ~= true end,
        }
        pNameArgs.raidGroupColor = {
            type="color", name="Color", order=46, hasAlpha=false,
            get = function()
                local c = ufGet("player", "raidGroupColor") or { r=1, g=1, b=1 }
                return c.r, c.g, c.b
            end,
            set = function(_, r, g, b)
                ufSet("player", "raidGroupColor", { r=r, g=g, b=b })
                relayoutPlayer()
            end,
            disabled = InCombatLockdown,
            hidden   = function() return ufGet("player", "showRaidGroup") ~= true end,
        }
    end

    -- Helper: if the pet has "Match Player Color" on, push the current player
    -- health color through to the pet bar immediately. Called whenever anything
    -- that affects the player health color changes.
    local function refreshPetMatchColor()
        local petPf = BF.ufDB.profile.pet or {}
        if petPf.petMatchPlayerColor == false then return end
        local f = BF.oufPet
        if f and f.Health and f.unit then
            local r, g, b = BF:_GetOUFHealthColor(f.unit, nil, "pet")
            f.Health:SetStatusBarColor(r, g, b)
        end
    end

    -- ── Player-specific health color overrides ──────────────────────────
    -- Remove per-player color controls from the per-frame Health Bar tab;
    -- they are handled by the Global > Health Bar Colors dropdown (or the
    -- "Separate Configuration for Player Frame" override).
    local playerHealthArgs = bluzzPlayerOpts.args.healthTab.args
    playerHealthArgs.hdrColor     = nil
    playerHealthArgs.useClassColor = nil
    playerHealthArgs.healthColor  = nil

    -- ── Player-specific name color overrides ───────────────────────────
    -- Remove per-player name color controls from the per-frame Name Bar tab;
    -- they are handled by the Global > Colors > Names dropdown (or the
    -- "Separate Configuration for Player Frame" override).
    local playerNameArgs = bluzzPlayerOpts.args.nameTab.args
    playerNameArgs.hdrNameColor      = nil
    playerNameArgs.useClassColorName = nil
    playerNameArgs.nameColor         = nil

    local _targetBase = makeFrameOpts(
        "target", "Target Frame", 2,
        "showTargetFrame",
        function() return BF.oufTarget end,
        relayoutTarget, updateTarget, "Target Frame")

    -- ── Target: Auras sub-tab ─────────────────────────────────────────────
    -- All aura options read/write into profile.target[key] and call
    -- relayoutTarget(), which calls ApplyOUFTargetLayout → ForceUpdate on
    -- the oUF Buffs/Debuffs elements.
    local function tufGet(key, default)
        local pf = BF.ufDB.profile.target or {}
        local v = pf[key]
        if v == nil then return default end
        return v
    end
    local function tufSet(key, val)
        if InCombatLockdown() then return end
        BF.ufDB.profile.target = BF.ufDB.profile.target or {}
        BF.ufDB.profile.target[key] = val
        relayoutTarget()
    end

    local bluzzTargetAuras = {
        type  = "group",
        name  = "Auras",
        order = 4,
        args  = {
            hdrDebuffs = { type="header", name="Debuffs", order=10 },
            targetShowDebuffs = {
                type="toggle", name="Show Debuffs", order=11, width="full",
                get = function() return tufGet("targetShowDebuffs", true) end,
                set = function(_, v) tufSet("targetShowDebuffs", v) end,
            },
            targetNameplateDebuffsOnly = {
                type="toggle", name="Nameplate Debuffs Only", order=11.5, width="full",
                desc="When enabled, only show debuffs that would appear on nameplates (same filter Blizzard uses for enemy nameplates).",
                get = function() return tufGet("targetNameplateDebuffsOnly", false) end,
                set = function(_, v) tufSet("targetNameplateDebuffsOnly", v) end,
                hidden = function() return not tufGet("targetShowDebuffs", true) end,
            },
            targetDebuffSize = {
                type="range", name="Icon Size", order=12,
                min=10, max=36, step=1,
                get = function() return tufGet("targetDebuffSize", 18) end,
                set = function(_, v) tufSet("targetDebuffSize", v) end,
                disabled = InCombatLockdown,
                hidden   = function() return not tufGet("targetShowDebuffs", true) end,
            },
            targetDebuffsPerRow = {
                type="range", name="Per Row", order=13,
                min=1, max=32, step=1,
                get = function() return tufGet("targetDebuffsPerRow", 8) end,
                set = function(_, v) tufSet("targetDebuffsPerRow", v) end,
                disabled = InCombatLockdown,
                hidden   = function() return not tufGet("targetShowDebuffs", true) end,
            },
            targetMaxDebuffs = {
                type="range", name="Max Icons", order=14,
                min=1, max=40, step=1,
                get = function() return tufGet("targetMaxDebuffs", 32) end,
                set = function(_, v) tufSet("targetMaxDebuffs", v) end,
                disabled = InCombatLockdown,
                hidden   = function() return not tufGet("targetShowDebuffs", true) end,
            },
            targetDebuffSpacing = {
                type="range", name="Spacing", order=15,
                min=0, max=10, step=1,
                get = function() return tufGet("targetDebuffSpacing", 2) end,
                set = function(_, v) tufSet("targetDebuffSpacing", v) end,
                disabled = InCombatLockdown,
                hidden   = function() return not tufGet("targetShowDebuffs", true) end,
            },
            targetDebuffOffsetX = {
                type="range", name="X Offset", order=16,
                min=-200, max=200, step=1, softMin=-50, softMax=50,
                get = function() return tufGet("targetDebuffOffsetX", 0) end,
                set = function(_, v) tufSet("targetDebuffOffsetX", v) end,
                disabled = InCombatLockdown,
                hidden   = function() return not tufGet("targetShowDebuffs", true) end,
            },
            targetDebuffOffsetY = {
                type="range", name="Y Offset", order=17,
                min=-200, max=200, step=1, softMin=-50, softMax=50,
                get = function() return tufGet("targetDebuffOffsetY", 0) end,
                set = function(_, v) tufSet("targetDebuffOffsetY", v) end,
                disabled = InCombatLockdown,
                hidden   = function() return not tufGet("targetShowDebuffs", true) end,
            },
            hdrBuffs = { type="header", name="Buffs", order=30 },
            targetShowBuffs = {
                type="toggle", name="Show Buffs", order=31, width="full",
                get = function() return tufGet("targetShowBuffs", true) end,
                set = function(_, v) tufSet("targetShowBuffs", v) end,
            },
            targetBuffSize = {
                type="range", name="Icon Size", order=32,
                min=10, max=36, step=1,
                get = function() return tufGet("targetBuffSize", 18) end,
                set = function(_, v) tufSet("targetBuffSize", v) end,
                disabled = InCombatLockdown,
                hidden   = function() return not tufGet("targetShowBuffs", true) end,
            },
            targetBuffsPerRow = {
                type="range", name="Per Row", order=33,
                min=1, max=32, step=1,
                get = function() return tufGet("targetBuffsPerRow", 8) end,
                set = function(_, v) tufSet("targetBuffsPerRow", v) end,
                disabled = InCombatLockdown,
                hidden   = function() return not tufGet("targetShowBuffs", true) end,
            },
            targetMaxBuffs = {
                type="range", name="Max Icons", order=34,
                min=1, max=32, step=1,
                get = function() return tufGet("targetMaxBuffs", 32) end,
                set = function(_, v) tufSet("targetMaxBuffs", v) end,
                disabled = InCombatLockdown,
                hidden   = function() return not tufGet("targetShowBuffs", true) end,
            },
            targetBuffSpacing = {
                type="range", name="Spacing", order=35,
                min=0, max=10, step=1,
                get = function() return tufGet("targetBuffSpacing", 2) end,
                set = function(_, v) tufSet("targetBuffSpacing", v) end,
                disabled = InCombatLockdown,
                hidden   = function() return not tufGet("targetShowBuffs", true) end,
            },
            targetBuffOffsetX = {
                type="range", name="X Offset", order=36,
                min=-200, max=200, step=1, softMin=-50, softMax=50,
                get = function() return tufGet("targetBuffOffsetX", 0) end,
                set = function(_, v) tufSet("targetBuffOffsetX", v) end,
                disabled = InCombatLockdown,
                hidden   = function() return not tufGet("targetShowBuffs", true) end,
            },
            targetBuffOffsetY = {
                type="range", name="Y Offset", order=37,
                min=-200, max=200, step=1, softMin=-50, softMax=50,
                get = function() return tufGet("targetBuffOffsetY", 0) end,
                set = function(_, v) tufSet("targetBuffOffsetY", v) end,
                disabled = InCombatLockdown,
                hidden   = function() return not tufGet("targetShowBuffs", true) end,
            },
        },
    }

    -- ── Target-specific name color overrides ──────────────────────────────
    -- Name colors are now in Global > Name Bar Colors.
    -- Remove the per-target name color controls from the Name Bar tab.
    local tNameArgs = _targetBase.args.nameTab.args
    tNameArgs.hdrNameColor        = nil
    tNameArgs.useClassColorName   = nil
    tNameArgs.nameColor           = nil

    -- ── Target-specific health color overrides ─────────────────────────────
    -- Health colors are now in Global > Health Bar Colors.
    -- Remove the per-target color controls from the Health Bar tab.
    local tHealthArgs = _targetBase.args.healthTab.args
    tHealthArgs.hdrColor     = nil
    tHealthArgs.useClassColor = nil
    tHealthArgs.healthColor  = nil

    local function targetFrameDisabled() return not self.ufDB.profile.showTargetFrame end
    bluzzTargetAuras.hidden = targetFrameDisabled
    _targetBase.args.aurasTab = bluzzTargetAuras

    -- ── Target: Cast Bar sub-tab ──────────────────────────────────────────
    local function cbShown() return self.ufDB.profile.targetShowCastBar ~= false end
    local function cbDetached()
        return cbShown() and self.ufDB.profile.targetCastBarDetached == true
    end
    local function cbAttached()
        return cbShown() and not self.ufDB.profile.targetCastBarDetached
    end
    local function cbLayout() relayoutTarget() end

    _targetBase.args.castBarTab = {
        type  = "group",
        name  = "Cast Bar",
        order = 5,
        args  = {
            -- ── Master toggle ───────────────────────────────────────────────
            targetShowCastBar = {
                type  = "toggle",
                name  = "Show Cast Bar",
                order = 1,
                width = "full",
                get   = function() return self.ufDB.profile.targetShowCastBar ~= false end,
                set   = function(_, v)
                    if InCombatLockdown() then return end
                    self.ufDB.profile.targetShowCastBar = v
                    relayoutTarget()
                end,
                disabled = InCombatLockdown,
            },
            -- ── Placement ───────────────────────────────────────────────────
            hdrPlacement = {
                type = "header", name = "Placement", order = 10,
                hidden = function() return not cbShown() end,
            },
            targetCastBarDetached = {
                type  = "toggle",
                name  = "Detach from Target Frame",
                desc  = "When detached, the cast bar can be positioned independently. Unlock frames to drag it.",
                order = 11,
                width = "full",
                get   = function() return self.ufDB.profile.targetCastBarDetached == true end,
                set   = function(_, v)
                    if InCombatLockdown() then return end
                    self.ufDB.profile.targetCastBarDetached = v
                    relayoutTarget()
                end,
                disabled = InCombatLockdown,
                hidden   = function() return not cbShown() end,
            },
            targetCastBarPosition = {
                type   = "select",
                name   = "Cast Bar Position",
                desc   = "Where the cast bar is anchored when attached to the target frame.",
                order  = 12,
                values = { below = "Below", above = "Above" },
                get    = function() return self.ufDB.profile.targetCastBarPosition or "below" end,
                set    = function(_, v)
                    if InCombatLockdown() then return end
                    self.ufDB.profile.targetCastBarPosition = v
                    relayoutTarget()
                end,
                disabled = InCombatLockdown,
                hidden   = function() return not cbAttached() end,
            },
            targetCastBarGap = {
                type  = "range",
                name  = "Y Offset",
                order = 13,
                min=-50, max=50, step=1,
                get   = function() return self.ufDB.profile.targetCastBarGap or 0 end,
                set   = function(_, v)
                    if InCombatLockdown() then return end
                    self.ufDB.profile.targetCastBarGap = v
                    relayoutTarget()
                end,
                disabled = InCombatLockdown,
                hidden   = function() return not cbAttached() end,
            },
            targetCastBarAvoidAuras = {
                type  = "toggle",
                name  = "Avoid Auras",
                desc  = "Automatically push the cast bar down (or up) to clear any aura icons that are currently visible, based on the live row count.",
                order = 14,
                width = "full",
                get   = function() return self.ufDB.profile.targetCastBarAvoidAuras ~= false end,
                set   = function(_, v)
                    if InCombatLockdown() then return end
                    self.ufDB.profile.targetCastBarAvoidAuras = v
                    relayoutTarget()
                end,
                disabled = InCombatLockdown,
                hidden   = function() return not cbAttached() end,
            },
            -- ── Size ────────────────────────────────────────────────────────
            hdrSize = {
                type = "header", name = "Size", order = 20,
                hidden = function() return not cbShown() end,
            },
            targetCastBarHeight = {
                type  = "range",
                name  = "Bar Height",
                order = 21,
                min=4, max=30, step=1,
                get   = function() return self.ufDB.profile.targetCastBarHeight or 14 end,
                set   = function(_, v)
                    if InCombatLockdown() then return end
                    self.ufDB.profile.targetCastBarHeight = v
                    relayoutTarget()
                end,
                disabled = InCombatLockdown,
                hidden   = function() return not cbShown() end,
            },
            targetCastBarWidth = {
                type  = "range",
                name  = "Bar Width",
                order = 22,
                min=40, max=600, step=1,
                get   = function() return self.ufDB.profile.targetCastBarWidth or 156 end,
                set   = function(_, v)
                    if InCombatLockdown() then return end
                    self.ufDB.profile.targetCastBarWidth = v
                    relayoutTarget()
                end,
                disabled = InCombatLockdown,
                hidden   = function() return not cbDetached() end,
            },
            castBarFontSize = {
                type  = "range",
                name  = "Font Size",
                order = 23,
                min=6, max=16, step=1,
                get   = function() return ufGet("target", "castBarFontSize") or 8 end,
                set   = function(_, v)
                    ufSet("target", "castBarFontSize", v)
                    relayoutTarget()
                end,
                disabled = InCombatLockdown,
                hidden   = function() return not cbShown() end,
            },
            -- ── Border ──────────────────────────────────────────────────────
            hdrBorder = {
                type = "header", name = "Border", order = 40,
                hidden = function() return not cbShown() end,
            },
            targetCastBarBorderEnabled = {
                type  = "toggle",
                name  = "Enable Border",
                order = 41,
                get   = function() return self.ufDB.profile.targetCastBarBorderEnabled == true end,
                set   = function(_, v)
                    if InCombatLockdown() then return end
                    self.ufDB.profile.targetCastBarBorderEnabled = v
                    BF:_ApplyOUFCastbarBorder()
                end,
                disabled = InCombatLockdown,
                hidden   = function() return not cbShown() end,
            },
            targetCastBarBorderThickness = {
                type  = "range",
                name  = "Thickness",
                order = 42,
                min=1, max=6, step=1,
                get   = function() return self.ufDB.profile.targetCastBarBorderThickness or 1 end,
                set   = function(_, v)
                    if InCombatLockdown() then return end
                    self.ufDB.profile.targetCastBarBorderThickness = v
                    BF:_ApplyOUFCastbarBorder()
                end,
                disabled = InCombatLockdown,
                hidden   = function()
                    return not cbShown()
                        or not (self.ufDB.profile.targetCastBarBorderEnabled == true)
                end,
            },
            targetCastBarBorderColor = {
                type     = "color",
                name     = "Color",
                order    = 43,
                hasAlpha = true,
                get = function()
                    local c = self.ufDB.profile.targetCastBarBorderColor or { r=0, g=0, b=0, a=1 }
                    return c.r, c.g, c.b, c.a or 1
                end,
                set = function(_, r, g, b, a)
                    if InCombatLockdown() then return end
                    self.ufDB.profile.targetCastBarBorderColor = { r=r, g=g, b=b, a=a }
                    BF:_ApplyOUFCastbarBorder()
                end,
                disabled = InCombatLockdown,
                hidden   = function()
                    return not cbShown()
                        or not (self.ufDB.profile.targetCastBarBorderEnabled == true)
                end,
            },
            -- ── Icon ────────────────────────────────────────────────────────
            hdrIcon = {
                type = "header", name = "Spell Icon", order = 50,
                hidden = function() return not cbShown() end,
            },
            targetCastBarShowIcon = {
                type  = "toggle",
                name  = "Show Spell Icon",
                order = 51,
                get   = function() return self.ufDB.profile.targetCastBarShowIcon ~= false end,
                set   = function(_, v)
                    if InCombatLockdown() then return end
                    self.ufDB.profile.targetCastBarShowIcon = v
                    BF:_ApplyOUFCastbarIcon(BF.oufTarget)
                end,
                disabled = InCombatLockdown,
                hidden   = function() return not cbShown() end,
            },
            targetCastBarIconSide = {
                type   = "select",
                name   = "Icon Side",
                order  = 52,
                values = { left = "Left", right = "Right" },
                get    = function() return self.ufDB.profile.targetCastBarIconSide or "left" end,
                set    = function(_, v)
                    if InCombatLockdown() then return end
                    self.ufDB.profile.targetCastBarIconSide = v
                    relayoutTarget()
                end,
                disabled = InCombatLockdown,
                hidden   = function() return not cbShown() or not (self.ufDB.profile.targetCastBarShowIcon ~= false) end,
            },
            targetCastBarIconSize = {
                type  = "range",
                name  = "Icon Size",
                order = 53,
                min=10, max=48, step=1,
                get   = function() return self.ufDB.profile.targetCastBarIconSize or 20 end,
                set   = function(_, v)
                    if InCombatLockdown() then return end
                    self.ufDB.profile.targetCastBarIconSize = v
                    relayoutTarget()
                end,
                disabled = InCombatLockdown,
                hidden   = function() return not cbShown() or not (self.ufDB.profile.targetCastBarShowIcon ~= false) end,
            },
            targetCastBarIconGap = {
                type  = "range",
                name  = "Gap",
                desc  = "Distance in pixels between the cast bar and the spell icon.",
                order = 54,
                min=0, max=20, step=1,
                get   = function() return self.ufDB.profile.targetCastBarIconGap or 2 end,
                set   = function(_, v)
                    if InCombatLockdown() then return end
                    self.ufDB.profile.targetCastBarIconGap = v
                    relayoutTarget()
                end,
                disabled = InCombatLockdown,
                hidden   = function() return not cbShown() or not (self.ufDB.profile.targetCastBarShowIcon ~= false) end,
            },
        },
    }

    _targetBase.args.castBarTab.hidden = targetFrameDisabled

    local bluzzTargetOpts = _targetBase

    -- ── Resource Bar sub-tab (injected into Player Frame tab) ─────────────────
    local function rbGet(key, default)
        local v = self.ufDB.profile[key]
        if v == nil then return default end
        return v
    end
    local function rbLayout()
        BF:ApplyOUFResourceBarLayout()
    end
    local function rbUpdate()
        local host = BF.oufPlayer or BF._classPowerHost
        if host and host.ClassPower and host.ClassPower.__isEnabled then
            BF:UpdateOUFResourceBar(
                host.ClassPower.__cur,
                host.ClassPower.__max,
                host.ClassPower.__powerType)
        end
    end
    local function rbEnabled()
        return self.ufDB.profile.oufResourceBarEnabled == true
    end
    local function rbDetached()
        if not rbEnabled() then return false end
        -- When the player frame is disabled, the bar is always treated as detached.
        if playerFrameDisabled() then return true end
        return BF:GetUFDetachState("playerResourceBar")
    end

    bluzzPlayerOpts.args.aurasTab = {
        type  = "group",
        name  = "Auras",
        order = 7,
        args  = {
            hdrDebuffs = { type="header", name="Debuffs", order=10 },
            playerShowDebuffs = {
                type="toggle", name="Show Debuffs", order=11, width="full",
                get = function() return ufGet("player", "playerShowDebuffs") == true end,
                set = function(_, v) ufSet("player", "playerShowDebuffs", v); relayoutPlayer() end,
            },
            playerDebuffSize = {
                type="range", name="Icon Size", order=12,
                min=10, max=36, step=1,
                get = function() return ufGet("player", "playerDebuffSize") or 18 end,
                set = function(_, v) ufSet("player", "playerDebuffSize", v); relayoutPlayer() end,
                disabled = InCombatLockdown,
                hidden   = function() return not ufGet("player", "playerShowDebuffs") end,
            },
            playerDebuffsPerRow = {
                type="range", name="Per Row", order=13,
                min=1, max=32, step=1,
                get = function() return ufGet("player", "playerDebuffsPerRow") or 8 end,
                set = function(_, v) ufSet("player", "playerDebuffsPerRow", v); relayoutPlayer() end,
                disabled = InCombatLockdown,
                hidden   = function() return not ufGet("player", "playerShowDebuffs") end,
            },
            playerMaxDebuffs = {
                type="range", name="Max Icons", order=14,
                min=1, max=40, step=1,
                get = function() return ufGet("player", "playerMaxDebuffs") or 32 end,
                set = function(_, v) ufSet("player", "playerMaxDebuffs", v); relayoutPlayer() end,
                disabled = InCombatLockdown,
                hidden   = function() return not ufGet("player", "playerShowDebuffs") end,
            },
            playerDebuffSpacing = {
                type="range", name="Spacing", order=15,
                min=0, max=10, step=1,
                get = function() return ufGet("player", "playerDebuffSpacing") or 2 end,
                set = function(_, v) ufSet("player", "playerDebuffSpacing", v); relayoutPlayer() end,
                disabled = InCombatLockdown,
                hidden   = function() return not ufGet("player", "playerShowDebuffs") end,
            },
            playerDebuffOffsetX = {
                type="range", name="X Offset", order=16,
                min=-200, max=200, step=1, softMin=-50, softMax=50,
                get = function() return ufGet("player", "playerDebuffOffsetX") or 0 end,
                set = function(_, v) ufSet("player", "playerDebuffOffsetX", v); relayoutPlayer() end,
                disabled = InCombatLockdown,
                hidden   = function() return not ufGet("player", "playerShowDebuffs") end,
            },
            playerDebuffOffsetY = {
                type="range", name="Y Offset", order=17,
                min=-200, max=200, step=1, softMin=-50, softMax=50,
                get = function() return ufGet("player", "playerDebuffOffsetY") or 0 end,
                set = function(_, v) ufSet("player", "playerDebuffOffsetY", v); relayoutPlayer() end,
                disabled = InCombatLockdown,
                hidden   = function() return not ufGet("player", "playerShowDebuffs") end,
            },
            hdrBuffs = { type="header", name="Buffs", order=30 },
            playerShowBuffs = {
                type="toggle", name="Show Buffs", order=31, width="full",
                get = function() return ufGet("player", "playerShowBuffs") == true end,
                set = function(_, v) ufSet("player", "playerShowBuffs", v); relayoutPlayer() end,
            },
            playerBuffSize = {
                type="range", name="Icon Size", order=32,
                min=10, max=36, step=1,
                get = function() return ufGet("player", "playerBuffSize") or 18 end,
                set = function(_, v) ufSet("player", "playerBuffSize", v); relayoutPlayer() end,
                disabled = InCombatLockdown,
                hidden   = function() return not ufGet("player", "playerShowBuffs") end,
            },
            playerBuffsPerRow = {
                type="range", name="Per Row", order=33,
                min=1, max=32, step=1,
                get = function() return ufGet("player", "playerBuffsPerRow") or 8 end,
                set = function(_, v) ufSet("player", "playerBuffsPerRow", v); relayoutPlayer() end,
                disabled = InCombatLockdown,
                hidden   = function() return not ufGet("player", "playerShowBuffs") end,
            },
            playerMaxBuffs = {
                type="range", name="Max Icons", order=34,
                min=1, max=32, step=1,
                get = function() return ufGet("player", "playerMaxBuffs") or 32 end,
                set = function(_, v) ufSet("player", "playerMaxBuffs", v); relayoutPlayer() end,
                disabled = InCombatLockdown,
                hidden   = function() return not ufGet("player", "playerShowBuffs") end,
            },
            playerBuffSpacing = {
                type="range", name="Spacing", order=35,
                min=0, max=10, step=1,
                get = function() return ufGet("player", "playerBuffSpacing") or 2 end,
                set = function(_, v) ufSet("player", "playerBuffSpacing", v); relayoutPlayer() end,
                disabled = InCombatLockdown,
                hidden   = function() return not ufGet("player", "playerShowBuffs") end,
            },
            playerBuffOffsetX = {
                type="range", name="X Offset", order=36,
                min=-200, max=200, step=1, softMin=-50, softMax=50,
                get = function() return ufGet("player", "playerBuffOffsetX") or 0 end,
                set = function(_, v) ufSet("player", "playerBuffOffsetX", v); relayoutPlayer() end,
                disabled = InCombatLockdown,
                hidden   = function() return not ufGet("player", "playerShowBuffs") end,
            },
            playerBuffOffsetY = {
                type="range", name="Y Offset", order=37,
                min=-200, max=200, step=1, softMin=-50, softMax=50,
                get = function() return ufGet("player", "playerBuffOffsetY") or 0 end,
                set = function(_, v) ufSet("player", "playerBuffOffsetY", v); relayoutPlayer() end,
                disabled = InCombatLockdown,
                hidden   = function() return not ufGet("player", "playerShowBuffs") end,
            },
        },
    }

    bluzzPlayerOpts.args.resourceTab = {
        type  = "group",
        name  = "Resource Bar",
        order = 6,  -- after Auras (5)
        args  = {
            oufResourceBarEnabled = {
                type  = "toggle",
                name  = "Enable Resource Bar",
                desc  = "Show a resource bar (Holy Power, Combo Points, Rage, etc.) below the player power bar. Can be enabled independently of the Player Frame.",
                order = 1,
                width = "full",
                get   = function() return rbEnabled() end,
                set   = function(_, v)
                    if InCombatLockdown() then return end
                    self.ufDB.profile.oufResourceBarEnabled = v
                    rbLayout()
                end,
                disabled = InCombatLockdown,
            },
            hdrAttach = { type="header", name="Placement", order=10,
                -- Hidden entirely when player frame is disabled (bar is implicitly detached)
                hidden = function() return not rbEnabled() or playerFrameDisabled() end },
            oufResourceBarDetached = {
                type  = "toggle",
                name  = "Detach from Player Frame",
                desc  = "When detached, the resource bar can be positioned independently. Unlock frames to drag it.",
                order = 11,
                width = "full",
                -- When the player frame is disabled the bar is always treated as detached.
                get   = function()
                    if playerFrameDisabled() then return true end
                    return BF:GetUFDetachState("playerResourceBar")
                end,
                set   = function(_, v)
                    if InCombatLockdown() then return end
                    BF:SetUFDetachState("playerResourceBar", v)
                    rbLayout()
                end,
                disabled = InCombatLockdown,
                hidden   = function() return not rbEnabled() or playerFrameDisabled() end,
            },
            oufResourceBarGap = {
                type  = "range",
                name  = "Gap Below Power Bar",
                order = 12,
                min=0, max=10, step=1,
                get   = function() return rbGet("oufResourceBarGap", 2) end,
                set   = function(_, v)
                    if InCombatLockdown() then return end
                    self.ufDB.profile.oufResourceBarGap = v
                    rbLayout()
                end,
                disabled = InCombatLockdown,
                hidden   = function() return not rbEnabled() or rbDetached() or playerFrameDisabled() end,
            },
            hdrSize = { type="header", name="Size", order=20,
                hidden = function() return not rbEnabled() end },
            oufResourceBarHeight = {
                type  = "range",
                name  = "Bar Height",
                order = 21,
                min=4, max=20, step=1,
                get   = function() return rbGet("oufResourceBarHeight", 10) end,
                set   = function(_, v)
                    if InCombatLockdown() then return end
                    self.ufDB.profile.oufResourceBarHeight = v
                    rbLayout()
                end,
                disabled = InCombatLockdown,
                hidden   = function() return not rbEnabled() end,
            },
            oufResourceBarWidth = {
                type  = "range",
                name  = "Bar Width",
                order = 22,
                min=40, max=600, step=1,
                get   = function() return rbGet("oufResourceBarWidth", 156) end,
                set   = function(_, v)
                    if InCombatLockdown() then return end
                    self.ufDB.profile.oufResourceBarWidth = v
                    rbLayout()
                end,
                disabled = InCombatLockdown,
                hidden   = function() return not rbDetached() end,
            },
            oufResourceBarPipGap = {
                type  = "range",
                name  = "Pip Spacing",
                order = 23,
                min=0, max=8, step=1,
                get   = function() return rbGet("oufResourceBarPipGap", 2) end,
                set   = function(_, v)
                    if InCombatLockdown() then return end
                    self.ufDB.profile.oufResourceBarPipGap = v
                    rbLayout()
                end,
                disabled = InCombatLockdown,
                hidden   = function() return not rbEnabled() end,
            },
            hdrColor = { type="header", name="Color", order=30,
                hidden = function() return not rbEnabled() end },
            oufResourceBarUseTypeColor = {
                type  = "toggle",
                name  = "Use Resource Type Color",
                order = 31,
                get   = function() return self.ufDB.profile.oufResourceBarUseTypeColor ~= false end,
                set   = function(_, v)
                    if InCombatLockdown() then return end
                    self.ufDB.profile.oufResourceBarUseTypeColor = v
                    rbUpdate()
                end,
                disabled = InCombatLockdown,
                hidden   = function() return not rbEnabled() end,
            },
            oufResourceBarColor = {
                type  = "color",
                name  = "Custom Color",
                order = 32,
                hasAlpha = false,
                get = function()
                    local c = self.ufDB.profile.oufResourceBarColor or { r=1.0, g=0.61, b=0.04 }
                    return c.r, c.g, c.b
                end,
                set = function(_, r, g, b)
                    if InCombatLockdown() then return end
                    self.ufDB.profile.oufResourceBarColor = { r=r, g=g, b=b }
                    rbUpdate()
                end,
                disabled = InCombatLockdown,
                hidden   = function()
                    return not rbEnabled()
                        or self.ufDB.profile.oufResourceBarUseTypeColor ~= false
                end,
            },
            oufResourceBarBgColor = {
                type  = "color",
                name  = "Background Color",
                order = 33,
                hasAlpha = true,
                get = function()
                    local c = self.ufDB.profile.oufResourceBarBgColor or { r=0.08, g=0.08, b=0.08, a=1 }
                    return c.r, c.g, c.b, c.a or 1
                end,
                set = function(_, r, g, b, a)
                    if InCombatLockdown() then return end
                    self.ufDB.profile.oufResourceBarBgColor = { r=r, g=g, b=b, a=a }
                    rbLayout()
                end,
                disabled = InCombatLockdown,
                hidden   = function() return not rbEnabled() end,
            },
            hdrBorder = { type="header", name="Border", order=45,
                hidden = function() return not rbEnabled() end },
            oufResourceBarBorderEnabled = {
                type  = "toggle",
                name  = "Enable Border",
                order = 46,
                width = "normal",
                get   = function() return self.ufDB.profile.oufResourceBarBorderEnabled == true end,
                set   = function(_, v)
                    if InCombatLockdown() then return end
                    self.ufDB.profile.oufResourceBarBorderEnabled = v
                    BF:_ApplyOUFResourceBarBorder()
                end,
                disabled = InCombatLockdown,
                hidden   = function() return not rbEnabled() end,
            },
            oufResourceBarBorderThickness = {
                type  = "range",
                name  = "Thickness",
                order = 47,
                min=1, max=6, step=1,
                width = "normal",
                get   = function() return rbGet("oufResourceBarBorderThickness", 1) end,
                set   = function(_, v)
                    if InCombatLockdown() then return end
                    self.ufDB.profile.oufResourceBarBorderThickness = v
                    BF:_ApplyOUFResourceBarBorder()
                end,
                disabled = InCombatLockdown,
                hidden   = function() return not rbEnabled() or not (self.ufDB.profile.oufResourceBarBorderEnabled == true) end,
            },
            oufResourceBarBorderColor = {
                type  = "color",
                name  = "Color",
                order = 48,
                hasAlpha = true,
                get = function()
                    local c = self.ufDB.profile.oufResourceBarBorderColor or { r=0, g=0, b=0, a=1 }
                    return c.r, c.g, c.b, c.a or 1
                end,
                set = function(_, r, g, b, a)
                    if InCombatLockdown() then return end
                    self.ufDB.profile.oufResourceBarBorderColor = { r=r, g=g, b=b, a=a }
                    BF:_ApplyOUFResourceBarBorder()
                end,
                disabled = InCombatLockdown,
                hidden   = function() return not rbEnabled() or not (self.ufDB.profile.oufResourceBarBorderEnabled == true) end,
            },
            hdrPipBorder = { type="header", name="Pip Border", order=49,
                hidden = function() return not rbEnabled() end },
            oufResourceBarPipBorderEnabled = {
                type  = "toggle",
                name  = "Enable Pip Border",
                order = 50,
                width = "normal",
                get   = function() return self.ufDB.profile.oufResourceBarPipBorderEnabled == true end,
                set   = function(_, v)
                    if InCombatLockdown() then return end
                    self.ufDB.profile.oufResourceBarPipBorderEnabled = v
                    BF:_ApplyOUFResourceBarBorder()
                end,
                disabled = InCombatLockdown,
                hidden   = function() return not rbEnabled() end,
            },
            oufResourceBarPipBorderThickness = {
                type  = "range",
                name  = "Thickness",
                order = 51,
                min=1, max=6, step=1,
                width = "normal",
                get   = function() return rbGet("oufResourceBarPipBorderThickness", 1) end,
                set   = function(_, v)
                    if InCombatLockdown() then return end
                    self.ufDB.profile.oufResourceBarPipBorderThickness = v
                    BF:_ApplyOUFResourceBarBorder()
                end,
                disabled = InCombatLockdown,
                hidden   = function() return not rbEnabled() or not (self.ufDB.profile.oufResourceBarPipBorderEnabled == true) end,
            },
            oufResourceBarPipBorderColor = {
                type  = "color",
                name  = "Color",
                order = 52,
                hasAlpha = true,
                get = function()
                    local c = self.ufDB.profile.oufResourceBarPipBorderColor or { r=0, g=0, b=0, a=1 }
                    return c.r, c.g, c.b, c.a or 1
                end,
                set = function(_, r, g, b, a)
                    if InCombatLockdown() then return end
                    self.ufDB.profile.oufResourceBarPipBorderColor = { r=r, g=g, b=b, a=a }
                    BF:_ApplyOUFResourceBarBorder()
                end,
                disabled = InCombatLockdown,
                hidden   = function() return not rbEnabled() or not (self.ufDB.profile.oufResourceBarPipBorderEnabled == true) end,
            },
            hdrEmpty = { type="header", name="Empty Pips", order=60,
                hidden = function() return not rbEnabled() end },
            oufResourceBarShowEmpty = {
                type  = "toggle",
                name  = "Show Empty Pips",
                order = 61,
                get   = function() return self.ufDB.profile.oufResourceBarShowEmpty ~= false end,
                set   = function(_, v)
                    if InCombatLockdown() then return end
                    self.ufDB.profile.oufResourceBarShowEmpty = v
                    rbUpdate()
                end,
                disabled = InCombatLockdown,
                hidden   = function() return not rbEnabled() end,
            },
            oufResourceBarEmptyDim = {
                type  = "range",
                name  = "Empty Pip Brightness",
                order = 62,
                min=0.0, max=0.5, step=0.05,
                get   = function() return rbGet("oufResourceBarEmptyDim", 0.2) end,
                set   = function(_, v)
                    if InCombatLockdown() then return end
                    self.ufDB.profile.oufResourceBarEmptyDim = v
                    rbUpdate()
                end,
                disabled = InCombatLockdown,
                hidden   = function()
                    return not rbEnabled()
                        or self.ufDB.profile.oufResourceBarShowEmpty == false
                end,
            },
        },
    }

    -- ============================================================
    -- GLOBAL TAB
    -- ============================================================

    -- Relayout all active unit frames (used by global aura options).
    -- ToT is excluded: it has no aura elements.
    local function relayoutAllUnitFrames()
        if BF.oufPlayer then BF:ApplyOUFPlayerLayout() end
        if BF.oufTarget then BF:ApplyOUFTargetLayout() end
        if BF.oufFocus  then BF:ApplyOUFFocusLayout() end
        if BF.RefreshOUFFonts then BF:RefreshOUFFonts() end
    end

    -- Font picker helpers (same pattern as Options_Text.lua).
    local function buildFontVals()
        local LSM = LibStub("LibSharedMedia-3.0", true)
        local vals = { ["PT Sans Narrow"] = "PT Sans Narrow" }
        if LSM then
            for name in pairs(LSM:HashTable("font")) do
                vals[name] = name
            end
        end
        return vals
    end
    local function getFont(key)
        local v = self.ufDB.profile[key]
        if not v or v == "DEFAULT" or v == "" or v:find("[\\/]") then
            return "PT Sans Narrow"
        end
        return v
    end
    local function setFont(key, val)
        if InCombatLockdown() then return end
        self.ufDB.profile[key] = val
    end

    local globalOpts = {
        type        = "group",
        name        = "Global",
        order       = 0,
        childGroups = "tab",
        hidden      = function() return not self.ufDB.profile.ptfEnabled end,
        args  = {
            classIconTab = {
                type  = "group",
                name  = "Class Icon",
                order = 1,
                args  = {
                    showClassIcon = {
                        type  = "toggle",
                        name  = "Show Class Icon",
                        desc  = "Show the class icon slot on all unit frames.",
                        order = 1,
                        get   = function() return self.ufDB.profile.playerShowClassIcon end,
                        set   = function(_, val)
                            if InCombatLockdown() then return end
                            self.ufDB.profile.playerShowClassIcon = val
                            self.ufDB.profile.targetShowClassIcon = val
                            relayoutAll() updateAll()
                        end,
                        disabled = InCombatLockdown,
                    },
                    iconStyle = {
                        type   = "select",
                        name   = "Icon Style",
                        desc   = "Class Icon: shows the class icon for players, portrait for NPCs.\nPortrait: always shows the unit portrait.",
                        order  = 2,
                        values = { classicon = "Class Icon", portrait = "Portrait", model = "Model" },
                        get    = function(info) return self.ufDB.profile[info[#info]] end,
                        set    = function(info, val)
                            if InCombatLockdown() then return end
                            self.ufDB.profile[info[#info]] = val
                            relayoutAll() updateAll()
                        end,
                        disabled = InCombatLockdown,
                        hidden   = function() return not self.ufDB.profile.playerShowClassIcon end,
                    },
                    iconShape = {
                        type   = "select",
                        name   = "Icon Shape",
                        order  = 3,
                        values = { circular = "Circular", square = "Square" },
                        get    = function(info) return self.ufDB.profile[info[#info]] end,
                        set    = function(info, val)
                            if InCombatLockdown() then return end
                            self.ufDB.profile[info[#info]] = val
                            relayoutAll() updateAll()
                        end,
                        disabled = InCombatLockdown,
                        hidden   = function()
                            return not self.ufDB.profile.playerShowClassIcon
                                or self.ufDB.profile.iconStyle == "model"
                        end,
                    },
                    iconSize = {
                        type  = "range",
                        name  = "Icon Size",
                        order = 4,
                        min=20, max=80, step=1,
                        get   = function() return self.ufDB.profile.iconSize or 51 end,
                        set   = function(_, val)
                            if InCombatLockdown() then return end
                            self.ufDB.profile.iconSize = val
                            relayoutAll() updateAll()
                        end,
                        disabled = InCombatLockdown,
                        hidden   = function() return not self.ufDB.profile.playerShowClassIcon end,
                    },
                    hdrIconPos = { type="header", name="Icon Position", order=10,
                        hidden = function() return not self.ufDB.profile.playerShowClassIcon end,
                    },
                    iconOffsetX = {
                        type     = "range",
                        name     = "X Offset",
                        desc     = "Moves all icons horizontally.",
                        order    = 11,
                        min = -100, max = 100, step = 1, softMin = -30, softMax = 30,
                        get = get,
                        set = function(info, val)
                            if InCombatLockdown() then return end
                            self.ufDB.profile[info[#info]] = val
                            relayoutAll()
                        end,
                        disabled = InCombatLockdown,
                        hidden   = function() return not self.ufDB.profile.playerShowClassIcon end,
                    },
                    iconOffsetY = {
                        type     = "range",
                        name     = "Y Offset",
                        desc     = "Moves all icons vertically by the same amount.",
                        order    = 12,
                        min = -100, max = 100, step = 1, softMin = -30, softMax = 30,
                        get = get,
                        set = function(info, val)
                            if InCombatLockdown() then return end
                            self.ufDB.profile[info[#info]] = val
                            relayoutAll()
                        end,
                        disabled = InCombatLockdown,
                        hidden   = function() return not self.ufDB.profile.playerShowClassIcon end,
                    },
                    iconLocation = {
                        type   = "select",
                        name   = "Location",
                        desc   = "Where the icon sits relative to the bar frame edge.\nOuter: fully outside the bars (default).\nCenter: icon centre sits on the edge.\nInner: fully inside the bars.",
                        order  = 13,
                        values = { outer = "Outer", center = "Center", inner = "Inner" },
                        get    = function(info) return self.ufDB.profile[info[#info]] end,
                        set    = function(info, val)
                            if InCombatLockdown() then return end
                            self.ufDB.profile[info[#info]] = val
                            relayoutAll()
                        end,
                        disabled = InCombatLockdown,
                        hidden   = function() return not self.ufDB.profile.playerShowClassIcon end,
                    },
                    hdrIconBorder = { type="header", name="Icon Border", order=20,
                        hidden = function() return not self.ufDB.profile.playerShowClassIcon end,
                    },
                    classIconBorderEnabled = {
                        type  = "toggle",
                        name  = "Enable Icon Border",
                        order = 21,
                        get   = function(info)
                            return self.ufDB.profile[info[#info]] ~= false
                        end,
                        set   = function(info, val)
                            if InCombatLockdown() then return end
                            self.ufDB.profile[info[#info]] = val
                            relayoutAll() updateAll()
                        end,
                        disabled = InCombatLockdown,
                        hidden   = function() return not self.ufDB.profile.playerShowClassIcon end,
                    },
                    classIconBorderThickness = {
                        type  = "range",
                        name  = "Border Thickness",
                        order = 22,
                        min=1, max=10, step=1,
                        get   = function() return self.ufDB.profile.classIconBorderThickness or 2 end,
                        set   = function(info, val)
                            if InCombatLockdown() then return end
                            self.ufDB.profile[info[#info]] = val
                            relayoutAll() updateAll()
                        end,
                        disabled = InCombatLockdown,
                        hidden = function()
                            return not self.ufDB.profile.playerShowClassIcon
                                or not self.ufDB.profile.classIconBorderEnabled
                        end,
                    },
                    classIconBorderUseHealthColor = {
                        type  = "toggle",
                        name  = "Use Health Bar Colors",
                        desc  = "Match the icon border color to the unit's health bar color. Updates automatically when the target changes.",
                        order = 23,
                        get   = function() return self.ufDB.profile.classIconBorderUseHealthColor end,
                        set   = function(_, val)
                            if InCombatLockdown() then return end
                            self.ufDB.profile.classIconBorderUseHealthColor = val
                            relayoutAll() updateAll()
                        end,
                        disabled = InCombatLockdown,
                        hidden = function()
                            return not self.ufDB.profile.playerShowClassIcon
                                or not self.ufDB.profile.classIconBorderEnabled
                        end,
                    },
                    classIconBorderColor = {
                        type     = "color",
                        name     = "Border Color",
                        order    = 24,
                        hasAlpha = false,
                        get = function()
                            local c = self.ufDB.profile.classIconBorderColor or { r=0, g=0, b=0 }
                            return c.r, c.g, c.b
                        end,
                        set = function(_, r, g, b)
                            if InCombatLockdown() then return end
                            local c = self.ufDB.profile.classIconBorderColor or {}
                            c.r, c.g, c.b = r, g, b
                            self.ufDB.profile.classIconBorderColor = c
                            relayoutAll()
                        end,
                        disabled = InCombatLockdown,
                        hidden = function()
                            return not self.ufDB.profile.playerShowClassIcon
                                or not self.ufDB.profile.classIconBorderEnabled
                                or self.ufDB.profile.classIconBorderUseHealthColor
                        end,
                    },
                    -- ── Elite Dragon Border ────────────────────────────────────
                    hdrDragon = { type="header", name="Elite Dragon Border", order=30,
                        hidden = function()
                            return not self.ufDB.profile.playerShowClassIcon
                                or (self.ufDB.profile.iconStyle or "classicon") == "model"
                                or (self.ufDB.profile.iconShape or "circular") ~= "circular"
                        end,
                    },
                    showEliteDragonBorder = {
                        type  = "toggle",
                        name  = "Show Elite Dragon Border",
                        desc  = "Display the gold or silver dragon border around the portrait icon for elite, rare-elite, and worldboss enemies.",
                        order = 31,
                        width = "full",
                        get   = function() return self.ufDB.profile.showEliteDragonBorder ~= false end,
                        set   = function(_, val)
                            if InCombatLockdown() then return end
                            self.ufDB.profile.showEliteDragonBorder = val
                            relayoutAll(); updateAll()
                        end,
                        disabled = InCombatLockdown,
                        hidden = function()
                            return not self.ufDB.profile.playerShowClassIcon
                                or (self.ufDB.profile.iconStyle or "classicon") == "model"
                                or (self.ufDB.profile.iconShape or "circular") ~= "circular"
                        end,
                    },
                    -- ── Click Bindings ────────────────────────────────────────
                    hdrClickBindings = {
                        type="header", name="Click Bindings", order=40,
                        hidden = function() return not self.ufDB.profile.playerShowClassIcon end,
                    },
                    clickBindingsDesc = {
                        type  = "description",
                        name  = "Use the toggles below to disable custom left- and right-click bindings on the Unit Frame Icons (the rest of the Unit Frame will still respect the custom bindings).\n\nThis feature can be useful if you rebind mouse buttons to spells, but still want easy access to target units and open the unit menu without needing a modifier key.\n\n*Only works with Clique, not Blizzard click-casting.",
                        order = 41,
                        fontSize = "medium",
                        hidden = function() return not self.ufDB.profile.playerShowClassIcon end,
                    },
                    iconIgnoreClickBinds = {
                        type  = "toggle",
                        name  = "Icon ignores custom left- and right-click binds",
                        desc  = "When enabled, left-clicking the icon will always target the unit and right-clicking will always open the unit menu, ignoring any Clique bindings.",
                        order = 42,
                        width = "full",
                        get   = function() return self.ufDB.profile.iconIgnoreClickBinds end,
                        set   = function(_, val)
                            if InCombatLockdown() then return end
                            self.ufDB.profile.iconIgnoreClickBinds = val
                            relayoutAll()
                        end,
                        disabled = InCombatLockdown,
                        hidden = function() return not self.ufDB.profile.playerShowClassIcon end,
                    },
                },
            },
            -- ── Icons sub-tab ─────────────────────────────────────────────────────
            iconsTab = {
                type  = "group",
                name  = "Raid Target Marker",
                order = 8,
                args  = {
                    hdrRaidTarget = { type="header", name="Raid Target Marker", order=10 },
                    oufShowRaidTarget = {
                        type  = "toggle",
                        name  = "Show Raid Target Marker",
                        desc  = "Show the raid target marker icon (skull, cross, star, etc.) on all unit frames.",
                        order = 11,
                        width = "full",
                        get   = function() return self.ufDB.profile.oufShowRaidTarget ~= false end,
                        set   = function(_, v)
                            if InCombatLockdown() then return end
                            self.ufDB.profile.oufShowRaidTarget = v
                            relayoutAll()
                        end,
                        disabled = InCombatLockdown,
                    },
                    oufRaidTargetSize = {
                        type  = "range",
                        name  = "Size",
                        order = 12,
                        min=10, max=48, step=1,
                        get   = function() return self.ufDB.profile.oufRaidTargetSize or 20 end,
                        set   = function(_, v)
                            if InCombatLockdown() then return end
                            self.ufDB.profile.oufRaidTargetSize = v
                            relayoutAll()
                        end,
                        disabled = InCombatLockdown,
                        hidden   = function() return not (self.ufDB.profile.oufShowRaidTarget ~= false) end,
                    },
                    hdrRaidTargetPos = {
                        type   = "header",
                        name   = "Icon Position",
                        order  = 20,
                        hidden = function() return not (self.ufDB.profile.oufShowRaidTarget ~= false) end,
                    },
                    oufRaidTargetOffsetX = {
                        type  = "range",
                        name  = "X Offset",
                        desc  = "Moves the raid target marker horizontally.",
                        order = 21,
                        min = -100, max = 100, step = 1, softMin = -30, softMax = 30,
                        get   = function() return self.ufDB.profile.oufRaidTargetOffsetX or 0 end,
                        set   = function(_, v)
                            if InCombatLockdown() then return end
                            self.ufDB.profile.oufRaidTargetOffsetX = v
                            relayoutAll()
                        end,
                        disabled = InCombatLockdown,
                        hidden   = function() return not (self.ufDB.profile.oufShowRaidTarget ~= false) end,
                    },
                    oufRaidTargetOffsetY = {
                        type  = "range",
                        name  = "Y Offset",
                        desc  = "Moves the raid target marker vertically.",
                        order = 22,
                        min = -100, max = 100, step = 1, softMin = -30, softMax = 30,
                        get   = function() return self.ufDB.profile.oufRaidTargetOffsetY or 0 end,
                        set   = function(_, v)
                            if InCombatLockdown() then return end
                            self.ufDB.profile.oufRaidTargetOffsetY = v
                            relayoutAll()
                        end,
                        disabled = InCombatLockdown,
                        hidden   = function() return not (self.ufDB.profile.oufShowRaidTarget ~= false) end,
                    },
                    oufRaidTargetLocation = {
                        type   = "select",
                        name   = "Location",
                        desc   = "Where the marker sits relative to the bar frame.\nCenter: marker centre sits at the frame centre (default).\nOuter: marker sits outside the frame bounds.\nInner: marker sits fully inside the frame bounds.",
                        order  = 23,
                        values = { center = "Center", outer = "Outer", inner = "Inner" },
                        get    = function() return self.ufDB.profile.oufRaidTargetLocation or "center" end,
                        set    = function(_, v)
                            if InCombatLockdown() then return end
                            self.ufDB.profile.oufRaidTargetLocation = v
                            relayoutAll()
                        end,
                        disabled = InCombatLockdown,
                        hidden   = function() return not (self.ufDB.profile.oufShowRaidTarget ~= false) end,
                    },
                },
            },
            -- ── Auras sub-tab ─────────────────────────────────────────────────────
            aurasTab = {
                type  = "group",
                name  = "Auras",
                order = 3,
                args  = {
                    hdrDuration = { type="header", name="Duration Text", order=10 },
                    auraShowDuration = {
                        type  = "toggle",
                        name  = "Show Duration Text",
                        desc  = "Show the countdown timer on aura icons on all unit frames. Disabled by default.",
                        order = 11,
                        get   = function() return self.ufDB.profile.auraShowDuration == true end,
                        set   = function(_, v)
                            if InCombatLockdown() then return end
                            self.ufDB.profile.auraShowDuration = v
                            relayoutAllUnitFrames()
                        end,
                        disabled = InCombatLockdown,
                    },
                    auraFontSize = {
                        type  = "range",
                        name  = "Font Size",
                        desc  = "Size of the duration text on aura icons on all unit frames.",
                        order = 12,
                        min=6, max=20, step=1,
                        get   = function() return self.ufDB.profile.auraFontSize or 9 end,
                        set   = function(_, v)
                            if InCombatLockdown() then return end
                            self.ufDB.profile.auraFontSize = v
                            relayoutAllUnitFrames()
                        end,
                        disabled = function() return not self.ufDB.profile.auraShowDuration end,
                        hidden   = function() return not self.ufDB.profile.auraShowDuration end,
                    },
                    hdrSwipe = { type="header", name="Cooldown", order=30 },
                    cooldownSwipeGroup = {
                        type = "group", name = "Cooldown Swipe", inline = true, order = 31,
                        args = {
                            auraShowSwipe = {
                                type  = "toggle",
                                name  = "Show Cooldown Swipe",
                                desc  = "Show the cooldown swipe animation on aura icons on all unit frames.",
                                order = 1,
                                get   = function() return self.ufDB.profile.auraShowSwipe ~= false end,
                                set   = function(_, v)
                                    if InCombatLockdown() then return end
                                    self.ufDB.profile.auraShowSwipe = v
                                    relayoutAllUnitFrames()
                                end,
                                disabled = InCombatLockdown,
                            },
                            auraReverseSwipe = {
                                type  = "toggle",
                                name  = "Reverse Cooldown Swipe",
                                desc  = "Reverse the direction of the cooldown swipe on aura icons on all unit frames.",
                                order = 2,
                                get   = function() return self.ufDB.profile.auraReverseSwipe == true end,
                                set   = function(_, v)
                                    if InCombatLockdown() then return end
                                    self.ufDB.profile.auraReverseSwipe = v
                                    relayoutAllUnitFrames()
                                end,
                                disabled = InCombatLockdown,
                                hidden   = function() return self.ufDB.profile.auraShowSwipe == false end,
                            },
                            auraShowSpark = {
                                type  = "toggle",
                                name  = "Show Cooldown Spark",
                                desc  = "Show the spark at the edge of the cooldown swipe on aura icons on all unit frames.",
                                order = 3,
                                get   = function() return self.ufDB.profile.auraShowSpark ~= false end,
                                set   = function(_, v)
                                    if InCombatLockdown() then return end
                                    self.ufDB.profile.auraShowSpark = v
                                    relayoutAllUnitFrames()
                                end,
                                disabled = InCombatLockdown,
                            },
                        },
                    },
                    hdrBorders = { type="header", name="Borders", order=40 },
                    oufAuraUseBlizzardBorders = {
                        type  = "toggle",
                        name  = "Use Blizzard-style Borders",
                        desc  = "When enabled, aura icons use the rounded Blizzard debuff border. When disabled, aura icons use flat solid borders matching the raid/party frame style.",
                        order = 41,
                        width = "full",
                        get   = function() return self.ufDB.profile.oufAuraUseBlizzardBorders ~= false end,
                        set   = function(_, v)
                            if InCombatLockdown() then return end
                            self.ufDB.profile.oufAuraUseBlizzardBorders = v
                            local useFlatBorders = not v
                            local frames = {}
                            if BF.oufPlayer then frames[#frames+1] = BF.oufPlayer end
                            if BF.oufTarget then frames[#frames+1] = BF.oufTarget end
                            if BF.oufFocus  then frames[#frames+1] = BF.oufFocus  end
                            if BF.oufBoss then
                                for i = 1, 5 do
                                    if BF.oufBoss[i] then frames[#frames+1] = BF.oufBoss[i] end
                                end
                            end
                            for _, f in ipairs(frames) do
                                BF:_ResetOUFAuraElement(f.Buffs, useFlatBorders)
                                BF:_ResetOUFAuraElement(f.Debuffs, useFlatBorders)
                            end
                        end,
                        disabled = InCombatLockdown,
                    },
                },
            },
            -- ── Fonts sub-tab ──────────────────────────────────────────────────────
            fontsTab = {
                type  = "group",
                name  = "Fonts",
                order = 3.5,
                args  = {
                    oufAdjustFonts = {
                        type  = "toggle",
                        name  = "Adjust Unit Frames Font",
                        desc  = "Enable custom font settings for unit frame text. When disabled, the standard game font is used.",
                        order = 1,
                        width = "full",
                        get   = function() return self.ufDB.profile.oufAdjustFonts ~= false end,
                        set   = function(_, val)
                            if InCombatLockdown() then return end
                            self.ufDB.profile.oufAdjustFonts = val
                            relayoutAllUnitFrames()
                        end,
                        disabled = InCombatLockdown,
                    },
                    oufGlobalFont = {
                        type   = "select",
                        name   = "Unit Frames Font",
                        desc   = "Font applied to all text on unit frames. Per-element overrides below take priority when enabled.",
                        order  = 2,
                        width  = "double",
                        dialogControl = "LSM30_Font",
                        values = buildFontVals,
                        hidden = function() return not self.ufDB.profile.oufAdjustFonts end,
                        get    = function() return getFont("oufGlobalFont") end,
                        set    = function(_, val)
                            setFont("oufGlobalFont", val)
                            if BF.RefreshOUFFonts then BF:RefreshOUFFonts() end
                        end,
                        disabled = InCombatLockdown,
                    },
                    oufSeparateFonts = {
                        type  = "toggle",
                        name  = "Configure Separate Fonts Per Element",
                        desc  = "When enabled, allows setting a different font for each text element.",
                        order = 3,
                        width = "full",
                        hidden = function() return not self.ufDB.profile.oufAdjustFonts end,
                        get   = function() return self.ufDB.profile.oufSeparateFonts == true end,
                        set   = function(_, val)
                            if InCombatLockdown() then return end
                            self.ufDB.profile.oufSeparateFonts = val
                            if BF.RefreshOUFFonts then BF:RefreshOUFFonts() end
                        end,
                        disabled = InCombatLockdown,
                    },
                    -- ── Names ──────────────────────────────────────────────
                    namesHeader = { type = "header", name = "Names", order = 10,
                        hidden = function() return not self.ufDB.profile.oufAdjustFonts or not self.ufDB.profile.oufSeparateFonts end,
                    },
                    oufNameFont = {
                        type   = "select",
                        name   = "Name Font",
                        desc   = "Font for unit name text.",
                        order  = 11,
                        width  = "double",
                        dialogControl = "LSM30_Font",
                        values = buildFontVals,
                        hidden = function() return not self.ufDB.profile.oufAdjustFonts or not self.ufDB.profile.oufSeparateFonts end,
                        get    = function() return getFont("oufNameFont") end,
                        set    = function(_, val)
                            setFont("oufNameFont", val)
                            if BF.RefreshOUFFonts then BF:RefreshOUFFonts() end
                        end,
                        disabled = InCombatLockdown,
                    },
                    oufLevelFont = {
                        type   = "select",
                        name   = "Level Font",
                        desc   = "Font for unit level text.",
                        order  = 12,
                        width  = "double",
                        dialogControl = "LSM30_Font",
                        values = buildFontVals,
                        hidden = function() return not self.ufDB.profile.oufAdjustFonts or not self.ufDB.profile.oufSeparateFonts end,
                        get    = function() return getFont("oufLevelFont") end,
                        set    = function(_, val)
                            setFont("oufLevelFont", val)
                            if BF.RefreshOUFFonts then BF:RefreshOUFFonts() end
                        end,
                        disabled = InCombatLockdown,
                    },
                    -- ── Health ─────────────────────────────────────────────
                    healthHeader = { type = "header", name = "Health", order = 20,
                        hidden = function() return not self.ufDB.profile.oufAdjustFonts or not self.ufDB.profile.oufSeparateFonts end,
                    },
                    oufHealthPctFont = {
                        type   = "select",
                        name   = "Health Percent Font",
                        order  = 21,
                        width  = "double",
                        dialogControl = "LSM30_Font",
                        values = buildFontVals,
                        hidden = function() return not self.ufDB.profile.oufAdjustFonts or not self.ufDB.profile.oufSeparateFonts end,
                        get    = function() return getFont("oufHealthPctFont") end,
                        set    = function(_, val)
                            setFont("oufHealthPctFont", val)
                            if BF.RefreshOUFFonts then BF:RefreshOUFFonts() end
                        end,
                        disabled = InCombatLockdown,
                    },
                    oufHealthValFont = {
                        type   = "select",
                        name   = "Health Value Font",
                        order  = 22,
                        width  = "double",
                        dialogControl = "LSM30_Font",
                        values = buildFontVals,
                        hidden = function() return not self.ufDB.profile.oufAdjustFonts or not self.ufDB.profile.oufSeparateFonts end,
                        get    = function() return getFont("oufHealthValFont") end,
                        set    = function(_, val)
                            setFont("oufHealthValFont", val)
                            if BF.RefreshOUFFonts then BF:RefreshOUFFonts() end
                        end,
                        disabled = InCombatLockdown,
                    },
                    -- ── Power ──────────────────────────────────────────────
                    powerHeader = { type = "header", name = "Power", order = 30,
                        hidden = function() return not self.ufDB.profile.oufAdjustFonts or not self.ufDB.profile.oufSeparateFonts end,
                    },
                    oufPowerPctFont = {
                        type   = "select",
                        name   = "Power Percent Font",
                        order  = 31,
                        width  = "double",
                        dialogControl = "LSM30_Font",
                        values = buildFontVals,
                        hidden = function() return not self.ufDB.profile.oufAdjustFonts or not self.ufDB.profile.oufSeparateFonts end,
                        get    = function() return getFont("oufPowerPctFont") end,
                        set    = function(_, val)
                            setFont("oufPowerPctFont", val)
                            if BF.RefreshOUFFonts then BF:RefreshOUFFonts() end
                        end,
                        disabled = InCombatLockdown,
                    },
                    oufPowerValFont = {
                        type   = "select",
                        name   = "Power Value Font",
                        order  = 32,
                        width  = "double",
                        dialogControl = "LSM30_Font",
                        values = buildFontVals,
                        hidden = function() return not self.ufDB.profile.oufAdjustFonts or not self.ufDB.profile.oufSeparateFonts end,
                        get    = function() return getFont("oufPowerValFont") end,
                        set    = function(_, val)
                            setFont("oufPowerValFont", val)
                            if BF.RefreshOUFFonts then BF:RefreshOUFFonts() end
                        end,
                        disabled = InCombatLockdown,
                    },
                    -- ── Alt Power ──────────────────────────────────────────
                    altPowerHeader = { type = "header", name = "Alt Power", order = 40,
                        hidden = function() return not self.ufDB.profile.oufAdjustFonts or not self.ufDB.profile.oufSeparateFonts end,
                    },
                    oufAltPowerPctFont = {
                        type   = "select",
                        name   = "Alt Power Percent Font",
                        order  = 41,
                        width  = "double",
                        dialogControl = "LSM30_Font",
                        values = buildFontVals,
                        hidden = function() return not self.ufDB.profile.oufAdjustFonts or not self.ufDB.profile.oufSeparateFonts end,
                        get    = function() return getFont("oufAltPowerPctFont") end,
                        set    = function(_, val)
                            setFont("oufAltPowerPctFont", val)
                            if BF.RefreshOUFFonts then BF:RefreshOUFFonts() end
                        end,
                        disabled = InCombatLockdown,
                    },
                    oufAltPowerValFont = {
                        type   = "select",
                        name   = "Alt Power Value Font",
                        order  = 42,
                        width  = "double",
                        dialogControl = "LSM30_Font",
                        values = buildFontVals,
                        hidden = function() return not self.ufDB.profile.oufAdjustFonts or not self.ufDB.profile.oufSeparateFonts end,
                        get    = function() return getFont("oufAltPowerValFont") end,
                        set    = function(_, val)
                            setFont("oufAltPowerValFont", val)
                            if BF.RefreshOUFFonts then BF:RefreshOUFFonts() end
                        end,
                        disabled = InCombatLockdown,
                    },
                },
            },
            -- ── Borders sub-tab ────────────────────────────────────────────────────
            bordersTab = {
                type  = "group",
                name  = "Borders",
                order = 2,
                args  = {
                    hdrName = { type="header", name="Name Bar", order=10 },
                    nameBorderEnabled = {
                        type  = "toggle",
                        name  = "Enable Border",
                        order = 11,
                        width = "full",
                        get   = function() return self.ufDB.profile.nameBorderEnabled == true end,
                        set   = function(_, v)
                            if InCombatLockdown() then return end
                            self.ufDB.profile.nameBorderEnabled = v
                            relayoutAll()
                        end,
                        disabled = InCombatLockdown,
                    },
                    nameBorderThickness = {
                        type  = "range",
                        name  = "Thickness",
                        order = 12,
                        min=1, max=6, step=1,
                        get   = function() return self.ufDB.profile.nameBorderThickness or 1 end,
                        set   = function(_, v)
                            if InCombatLockdown() then return end
                            self.ufDB.profile.nameBorderThickness = v
                            relayoutAll()
                        end,
                        disabled = InCombatLockdown,
                        hidden   = function() return not self.ufDB.profile.nameBorderEnabled end,
                    },
                    nameBorderColor = {
                        type     = "color",
                        name     = "Color",
                        order    = 13,
                        hasAlpha = true,
                        get = function()
                            local c = self.ufDB.profile.nameBorderColor or { r=0, g=0, b=0, a=1 }
                            return c.r, c.g, c.b, c.a or 1
                        end,
                        set = function(_, r, g, b, a)
                            if InCombatLockdown() then return end
                            self.ufDB.profile.nameBorderColor = { r=r, g=g, b=b, a=a }
                            relayoutAll()
                        end,
                        disabled = InCombatLockdown,
                        hidden   = function() return not self.ufDB.profile.nameBorderEnabled end,
                    },
                    hdrHealth = { type="header", name="Health Bar", order=20 },
                    healthBorderEnabled = {
                        type  = "toggle",
                        name  = "Enable Border",
                        order = 21,
                        width = "full",
                        get   = function() return self.ufDB.profile.healthBorderEnabled == true end,
                        set   = function(_, v)
                            if InCombatLockdown() then return end
                            self.ufDB.profile.healthBorderEnabled = v
                            relayoutAll()
                        end,
                        disabled = InCombatLockdown,
                    },
                    healthBorderThickness = {
                        type  = "range",
                        name  = "Thickness",
                        order = 22,
                        min=1, max=6, step=1,
                        get   = function() return self.ufDB.profile.healthBorderThickness or 1 end,
                        set   = function(_, v)
                            if InCombatLockdown() then return end
                            self.ufDB.profile.healthBorderThickness = v
                            relayoutAll()
                        end,
                        disabled = InCombatLockdown,
                        hidden   = function() return not self.ufDB.profile.healthBorderEnabled end,
                    },
                    healthBorderColor = {
                        type     = "color",
                        name     = "Color",
                        order    = 23,
                        hasAlpha = true,
                        get = function()
                            local c = self.ufDB.profile.healthBorderColor or { r=0, g=0, b=0, a=1 }
                            return c.r, c.g, c.b, c.a or 1
                        end,
                        set = function(_, r, g, b, a)
                            if InCombatLockdown() then return end
                            self.ufDB.profile.healthBorderColor = { r=r, g=g, b=b, a=a }
                            relayoutAll()
                        end,
                        disabled = InCombatLockdown,
                        hidden   = function() return not self.ufDB.profile.healthBorderEnabled end,
                    },
                    hdrPower = { type="header", name="Power Bar", order=30 },
                    powerBorderEnabled = {
                        type  = "toggle",
                        name  = "Enable Border",
                        order = 31,
                        width = "full",
                        get   = function() return self.ufDB.profile.powerBorderEnabled == true end,
                        set   = function(_, v)
                            if InCombatLockdown() then return end
                            self.ufDB.profile.powerBorderEnabled = v
                            relayoutAll()
                        end,
                        disabled = InCombatLockdown,
                    },
                    powerBorderThickness = {
                        type  = "range",
                        name  = "Thickness",
                        order = 32,
                        min=1, max=6, step=1,
                        get   = function() return self.ufDB.profile.powerBorderThickness or 1 end,
                        set   = function(_, v)
                            if InCombatLockdown() then return end
                            self.ufDB.profile.powerBorderThickness = v
                            relayoutAll()
                        end,
                        disabled = InCombatLockdown,
                        hidden   = function() return not self.ufDB.profile.powerBorderEnabled end,
                    },
                    powerBorderColor = {
                        type     = "color",
                        name     = "Color",
                        order    = 33,
                        hasAlpha = true,
                        get = function()
                            local c = self.ufDB.profile.powerBorderColor or { r=0, g=0, b=0, a=1 }
                            return c.r, c.g, c.b, c.a or 1
                        end,
                        set = function(_, r, g, b, a)
                            if InCombatLockdown() then return end
                            self.ufDB.profile.powerBorderColor = { r=r, g=g, b=b, a=a }
                            relayoutAll()
                        end,
                        disabled = InCombatLockdown,
                        hidden   = function() return not self.ufDB.profile.powerBorderEnabled end,
                    },
                },
            },
            -- NOTE: The "Power Bar Colors" subtab that used to live here has been
            -- removed. The authoritative Power Bar Colors UI lives at top-level
            -- Colors nav -> Power Bar Colors (Options_Colors.lua) and writes to
            -- rpDB.profile.healthPower.customPowerColors, which is what
            -- BF:ApplyCustomPowerColors actually reads. The deleted subtab wrote
            -- to ufDB.profile.customPowerColors -- a location nothing reads, so
            -- its removal doesn't regress any working behaviour.
            colorsTab = {
                type  = "group",
                name  = "Colors",
                order = 4,
                childGroups = "tab",
                args  = {
                    -- ── Sub-tab 1: Health Bars ────────────────────────────────
                    healthBarsSubTab = {
                        type  = "group",
                        name  = "Health Bars",
                        order = 1,
                        args  = {
                            -- ── Separate Player Frame toggle ──────────────────────────
                            separatePlayerFrameColor = {
                                type="toggle", name="Separate Configuration for Player Frame", order=0, width="full",
                                desc="When enabled, the player frame uses its own color mode instead of the Player Health Bar Colors setting.",
                                get = function() return self.ufDB.profile.separatePlayerFrameColor end,
                                set = function(_, v)
                                    self.ufDB.profile.separatePlayerFrameColor = v
                                    if BF.RebuildHealthGradientCurves then BF:RebuildHealthGradientCurves() end
                                    updateAll()
                                end,
                            },
                            -- ── Player Frame Health Bar Color (per-frame override) ────
                            playerFrameColorsGroup = {
                                type="group", name="Player Frame Health Bar Color", inline=true, order=1,
                                hidden = function() return not self.ufDB.profile.separatePlayerFrameColor end,
                                args = {
                                    playerFrameHealthColorMode = {
                                        type="select", name="Color Mode", order=1, width=1.5,
                                        values = {
                                            class    = "Use Class Colors",
                                            gradient = "Use Color Gradient (Health Percent)",
                                            static   = "Use Static Color",
                                        },
                                        sorting = { "class", "gradient", "static" },
                                        get = function() return self.ufDB.profile.playerFrameHealthColorMode or "class" end,
                                        set = function(_, v)
                                            self.ufDB.profile.playerFrameHealthColorMode = v
                                            if BF.RebuildHealthGradientCurves then BF:RebuildHealthGradientCurves() end
                                            local f = BF.oufPlayer
                                            if f and f.Health and f.unit then
                                                local r, g, b = BF:_GetOUFHealthColor(f.unit, nil, "player")
                                                f.Health:SetStatusBarColor(r, g, b)
                                            end
                                            refreshPetMatchColor()
                                        end,
                                    },
                                    healthColorGroup = {
                                        type="group", name="Health Color", inline=true, order=2,
                                        hidden = function() return (self.ufDB.profile.playerFrameHealthColorMode or "class") ~= "static" end,
                                        args = {
                                            playerFrameHealthColor = {
                                                type="color", name="Health Color", order=1, hasAlpha=false,
                                                desc="Static health bar color for the player frame.",
                                                get = function()
                                                    local c = self.ufDB.profile.playerFrameHealthColor or { r=0.24, g=0.78, b=0.24 }
                                                    return c.r, c.g, c.b
                                                end,
                                                set = function(_, r, g, b)
                                                    self.ufDB.profile.playerFrameHealthColor = { r=r, g=g, b=b }
                                                    local f = BF.oufPlayer
                                                    if f and f.Health and f.unit then
                                                        local nr, ng, nb = BF:_GetOUFHealthColor(f.unit, nil, "player")
                                                        f.Health:SetStatusBarColor(nr, ng, nb)
                                                    end
                                                    refreshPetMatchColor()
                                                end,
                                                disabled = InCombatLockdown,
                                            },
                                        },
                                    },
                                },
                            },
                            -- ── Player Health Bar Colors ──────────────────────────────
                            playerColorsGroup = {
                                type="group", name="Player Health Bar Colors", inline=true, order=2,
                                args = {
                                    globalPlayerHealthColorMode = {
                                        type="select", name="Color Mode", order=1, width=1.5,
                                        values = {
                                            class    = "Use Class Colors",
                                            gradient = "Use Color Gradient (Health Percent)",
                                            static   = "Use Static Color",
                                        },
                                        sorting = { "class", "gradient", "static" },
                                        get = function() return self.ufDB.profile.globalPlayerHealthColorMode or "class" end,
                                        set = function(_, v)
                                            self.ufDB.profile.globalPlayerHealthColorMode = v
                                            if BF.RebuildHealthGradientCurves then BF:RebuildHealthGradientCurves() end
                                            updateAll()
                                        end,
                                    },
                                    healthColorGroup = {
                                        type="group", name="Health Color", inline=true, order=2,
                                        hidden = function() return (self.ufDB.profile.globalPlayerHealthColorMode or "class") ~= "static" end,
                                        args = {
                                            globalHealthColor = {
                                                type="color", name="Health Color", order=1, hasAlpha=false,
                                                desc="Static health bar color for player targets.",
                                                get = function()
                                                    local c = self.ufDB.profile.globalHealthColor or { r=0.24, g=0.78, b=0.24 }
                                                    return c.r, c.g, c.b
                                                end,
                                                set = function(_, r, g, b)
                                                    self.ufDB.profile.globalHealthColor = { r=r, g=g, b=b }
                                                    updateAll()
                                                end,
                                                disabled = InCombatLockdown,
                                            },
                                        },
                                    },
                                },
                            },
                            -- ── NPC Health Bar Colors ─────────────────────────────────
                            npcColorsGroup = {
                                type="group", name="NPC Health Bar Colors", inline=true, order=3,
                                args = {
                                    globalNpcHealthColorMode = {
                                        type="select", name="Color Mode", order=1, width=1.5,
                                        values = {
                                            classification = "Color by Classification",
                                            hostility      = "Color by Hostility",
                                            gradient       = "Use Color Gradient (Health Percent)",
                                            static         = "Use Static Color",
                                        },
                                        sorting = { "classification", "hostility", "gradient", "static" },
                                        get = function() return self.ufDB.profile.globalNpcHealthColorMode or "classification" end,
                                        set = function(_, v)
                                            self.ufDB.profile.globalNpcHealthColorMode = v
                                            if BF.RebuildHealthGradientCurves then BF:RebuildHealthGradientCurves() end
                                            updateAll()
                                        end,
                                    },
                                    classificationColorsGroup = {
                                        type="group", name="Classification Colors", inline=true, order=2,
                                        hidden = function() return (self.ufDB.profile.globalNpcHealthColorMode or "classification") ~= "classification" end,
                                        args = {
                                            globalNpcFriendlyColor = {
                                                type="color", name="Friendly", order=1, hasAlpha=false,
                                                desc=DESC_FRIENDLY,
                                                get = function()
                                                    local c = self.ufDB.profile.globalNpcFriendlyColor or { r=0.00, g=0.65, b=0.00 }
                                                    return c.r, c.g, c.b
                                                end,
                                                set = function(_, r, g, b)
                                                    self.ufDB.profile.globalNpcFriendlyColor = { r=r, g=g, b=b }
                                                    updateAll()
                                                end,
                                                disabled = InCombatLockdown,
                                            },
                                            globalNpcNeutralColor = {
                                                type="color", name="Neutral", order=2, hasAlpha=false,
                                                desc=DESC_NEUTRAL,
                                                get = function()
                                                    local c = self.ufDB.profile.globalNpcNeutralColor or { r=0.90, g=0.70, b=0.00 }
                                                    return c.r, c.g, c.b
                                                end,
                                                set = function(_, r, g, b)
                                                    self.ufDB.profile.globalNpcNeutralColor = { r=r, g=g, b=b }
                                                    updateAll()
                                                end,
                                                disabled = InCombatLockdown,
                                            },
                                            globalNpcRegularColor = {
                                                type="color", name="Regular", order=3, hasAlpha=false,
                                                desc=DESC_REGULAR,
                                                get = function()
                                                    local c = self.ufDB.profile.globalNpcRegularColor or { r=0.745, g=0.188, b=0.114 }
                                                    return c.r, c.g, c.b
                                                end,
                                                set = function(_, r, g, b)
                                                    self.ufDB.profile.globalNpcRegularColor = { r=r, g=g, b=b }
                                                    updateAll()
                                                end,
                                                disabled = InCombatLockdown,
                                            },
                                            globalNpcBossColor = {
                                                type="color", name="Boss", order=4, hasAlpha=false,
                                                desc=DESC_BOSS,
                                                get = function()
                                                    local c = self.ufDB.profile.globalNpcBossColor or { r=1.00, g=0.00, b=1.00 }
                                                    return c.r, c.g, c.b
                                                end,
                                                set = function(_, r, g, b)
                                                    self.ufDB.profile.globalNpcBossColor = { r=r, g=g, b=b }
                                                    updateAll()
                                                end,
                                                disabled = InCombatLockdown,
                                            },
                                            globalNpcLieutenantColor = {
                                                type="color", name="Lieutenant", order=5, hasAlpha=false,
                                                desc=DESC_LIEUTENANT,
                                                get = function()
                                                    local c = self.ufDB.profile.globalNpcLieutenantColor or { r=0.576, g=0.439, b=0.859 }
                                                    return c.r, c.g, c.b
                                                end,
                                                set = function(_, r, g, b)
                                                    self.ufDB.profile.globalNpcLieutenantColor = { r=r, g=g, b=b }
                                                    updateAll()
                                                end,
                                                disabled = InCombatLockdown,
                                            },
                                            globalNpcCasterColor = {
                                                type="color", name="Caster", order=6, hasAlpha=false,
                                                desc=DESC_CASTER,
                                                get = function()
                                                    local c = self.ufDB.profile.globalNpcCasterColor or { r=0.00, g=0.820, b=1.00 }
                                                    return c.r, c.g, c.b
                                                end,
                                                set = function(_, r, g, b)
                                                    self.ufDB.profile.globalNpcCasterColor = { r=r, g=g, b=b }
                                                    updateAll()
                                                end,
                                                disabled = InCombatLockdown,
                                            },
                                            globalNpcTrivialColor = {
                                                type="color", name="Trivial", order=7, hasAlpha=false,
                                                desc=DESC_TRIVIAL,
                                                get = function()
                                                    local c = self.ufDB.profile.globalNpcTrivialColor or { r=0.592, g=0.612, b=0.592 }
                                                    return c.r, c.g, c.b
                                                end,
                                                set = function(_, r, g, b)
                                                    self.ufDB.profile.globalNpcTrivialColor = { r=r, g=g, b=b }
                                                    updateAll()
                                                end,
                                                disabled = InCombatLockdown,
                                            },
                                        },
                                    },
                                    hostilityColorsGroup = {
                                        type="group", name="Hostility Colors", inline=true, order=3,
                                        hidden = function() return (self.ufDB.profile.globalNpcHealthColorMode or "classification") ~= "hostility" end,
                                        args = {
                                            hostileColor = {
                                                type="color", name="Hostile", order=1, hasAlpha=false,
                                                desc="Health bar color for hostile NPCs.",
                                                get = function()
                                                    local c = self.ufDB.profile.globalNpcRegularColor or { r=0.745, g=0.188, b=0.114 }
                                                    return c.r, c.g, c.b
                                                end,
                                                set = function(_, r, g, b)
                                                    self.ufDB.profile.globalNpcRegularColor = { r=r, g=g, b=b }
                                                    updateAll()
                                                end,
                                                disabled = InCombatLockdown,
                                            },
                                            neutralColor = {
                                                type="color", name="Neutral", order=2, hasAlpha=false,
                                                desc="Health bar color for neutral NPCs.",
                                                get = function()
                                                    local c = self.ufDB.profile.globalNpcNeutralColor or { r=0.90, g=0.70, b=0.00 }
                                                    return c.r, c.g, c.b
                                                end,
                                                set = function(_, r, g, b)
                                                    self.ufDB.profile.globalNpcNeutralColor = { r=r, g=g, b=b }
                                                    updateAll()
                                                end,
                                                disabled = InCombatLockdown,
                                            },
                                            friendlyColor = {
                                                type="color", name="Friendly", order=3, hasAlpha=false,
                                                desc="Health bar color for friendly NPCs.",
                                                get = function()
                                                    local c = self.ufDB.profile.globalNpcFriendlyColor or { r=0.00, g=0.65, b=0.00 }
                                                    return c.r, c.g, c.b
                                                end,
                                                set = function(_, r, g, b)
                                                    self.ufDB.profile.globalNpcFriendlyColor = { r=r, g=g, b=b }
                                                    updateAll()
                                                end,
                                                disabled = InCombatLockdown,
                                            },
                                        },
                                    },
                                    npcHealthColorGroup = {
                                        type="group", name="Health Color", inline=true, order=4,
                                        hidden = function() return (self.ufDB.profile.globalNpcHealthColorMode or "classification") ~= "static" end,
                                        args = {
                                            globalNpcHealthColor = {
                                                type="color", name="NPC Health Color", order=1, hasAlpha=false,
                                                desc="Static health bar color for all NPCs.",
                                                get = function()
                                                    local c = self.ufDB.profile.globalNpcHealthColor or { r=0.24, g=0.78, b=0.24 }
                                                    return c.r, c.g, c.b
                                                end,
                                                set = function(_, r, g, b)
                                                    self.ufDB.profile.globalNpcHealthColor = { r=r, g=g, b=b }
                                                    updateAll()
                                                end,
                                                disabled = InCombatLockdown,
                                            },
                                        },
                                    },
                                },
                            },
                            -- ── Pet Frame Health Bar Color ────────────────────────
                            petHealthColorsGroup = {
                                type="group", name="Pet Frame Health Bar Color", inline=true, order=3.5,
                                hidden = function() return not self.ufDB.profile.showPetFrame end,
                                args = {
                                    petMatchPlayerColor = {
                                        type="toggle", name="Match Player Color", order=1, width="full",
                                        desc="Use the same health bar color as the player frame.",
                                        get = function() return ufGet("pet", "petMatchPlayerColor") ~= false end,
                                        set = function(_, v)
                                            ufSet("pet", "petMatchPlayerColor", v)
                                            relayoutAll(); updateAll()
                                        end,
                                        disabled = InCombatLockdown,
                                    },
                                    healthColor = {
                                        type="color", name="Health Bar Color", order=2, hasAlpha=false,
                                        desc="Custom health bar color for the pet frame.",
                                        get = function()
                                            local c = ufGet("pet", "healthColor") or { r=0.24, g=0.78, b=0.24 }
                                            return c.r, c.g, c.b
                                        end,
                                        set = function(_, r, g, b)
                                            ufSet("pet", "healthColor", { r=r, g=g, b=b })
                                            relayoutAll(); updateAll()
                                        end,
                                        disabled = InCombatLockdown,
                                        hidden   = function() return ufGet("pet", "petMatchPlayerColor") ~= false end,
                                    },
                                },
                            },
                            -- ── Health Bar Opacity ───────────────────────────────
                            oufHealthBarOpacity = {
                                type="range", name="Health Bar Opacity", order=4,
                                min=0, max=1, step=0.05, isPercent=true,
                                desc="Opacity of the health bar fill.",
                                get = function() return self.ufDB.profile.oufHealthBarOpacity or 1 end,
                                set = function(_, v)
                                    self.ufDB.profile.oufHealthBarOpacity = v
                                    relayoutAll(); updateAll()
                                end,
                                disabled = InCombatLockdown,
                            },
                            -- ── Colors section link ──────────────────────────────
                            colorsNote = {
                                type="description", order=90, width="full",
                                name="Class Colors and Health Gradient Colors can be customized in the global Colors section:",
                            },
                            openColorsBtn = {
                                type="execute", name="Colors", order=91,
                                func = function()
                                    local ACD = LibStub("AceConfigDialog-3.0")
                                    ACD:SelectGroup("BuzzardFrames", "colors")
                                end,
                            },
                        },
                    },
                    -- ── Sub-tab 2: Background ─────────────────────────────────
                    backgroundSubTab = {
                        type  = "group",
                        name  = "Background",
                        order = 2,
                        args  = {
                            oufUseCustomBackgroundColor = {
                                type="toggle", name="Use Custom Background Color", order=1, width="full",
                                desc="Override the default dark health bar background.",
                                get = function() return self.ufDB.profile.oufUseCustomBackgroundColor end,
                                set = function(_, v)
                                    self.ufDB.profile.oufUseCustomBackgroundColor = v
                                    if BF.RebuildHealthGradientCurves then BF:RebuildHealthGradientCurves() end
                                    relayoutAll(); updateAll()
                                end,
                            },
                            oufBackgroundColorMode = {
                                type="select", name="Color Mode", order=2, width=1.5,
                                hidden = function() return not self.ufDB.profile.oufUseCustomBackgroundColor end,
                                values = {
                                    gradient = "Use Color Gradient (Health Percent)",
                                    static   = "Use Static Color",
                                },
                                sorting = { "gradient", "static" },
                                get = function() return self.ufDB.profile.oufBackgroundColorMode or "static" end,
                                set = function(_, v)
                                    self.ufDB.profile.oufBackgroundColorMode = v
                                    if BF.RebuildHealthGradientCurves then BF:RebuildHealthGradientCurves() end
                                    relayoutAll(); updateAll()
                                end,
                            },
                            gradientNote = {
                                type="description", order=8, width="full",
                                name="Background gradient colors can be customized in the global Colors section:",
                                hidden = function()
                                    return not self.ufDB.profile.oufUseCustomBackgroundColor
                                        or (self.ufDB.profile.oufBackgroundColorMode or "static") ~= "gradient"
                                end,
                            },
                            openColorsBtn = {
                                type="execute", name="Colors", order=9,
                                hidden = function()
                                    return not self.ufDB.profile.oufUseCustomBackgroundColor
                                        or (self.ufDB.profile.oufBackgroundColorMode or "static") ~= "gradient"
                                end,
                                func = function()
                                    local ACD = LibStub("AceConfigDialog-3.0")
                                    ACD:SelectGroup("BuzzardFrames", "colors")
                                end,
                            },
                            oufBackgroundColor = {
                                type="color", name="Background Color", order=5, hasAlpha=false,
                                desc="Static background color for health bars.",
                                hidden = function()
                                    return not self.ufDB.profile.oufUseCustomBackgroundColor
                                        or (self.ufDB.profile.oufBackgroundColorMode or "static") ~= "static"
                                end,
                                get = function()
                                    local c = self.ufDB.profile.oufBackgroundColor or { r=0.08, g=0.08, b=0.08 }
                                    return c.r, c.g, c.b
                                end,
                                set = function(_, r, g, b)
                                    self.ufDB.profile.oufBackgroundColor = { r=r, g=g, b=b }
                                    relayoutAll(); updateAll()
                                end,
                                disabled = InCombatLockdown,
                            },
                            oufBackgroundAlpha = {
                                type="range", name="Background Opacity", order=6,
                                min=0, max=1, step=0.05, isPercent=true,
                                hidden = function() return not self.ufDB.profile.oufUseCustomBackgroundColor end,
                                desc="Opacity of the health bar background.",
                                get = function() return self.ufDB.profile.oufBackgroundAlpha or 0.6 end,
                                set = function(_, v)
                                    self.ufDB.profile.oufBackgroundAlpha = v
                                    relayoutAll(); updateAll()
                                end,
                                disabled = InCombatLockdown,
                            },
                        },
                    },
                    -- ── Sub-tab 3: Names ──────────────────────────────────────
                    namesSubTab = {
                        type  = "group",
                        name  = "Names",
                        order = 3,
                        args  = {
                            -- ── Separate Player Frame toggle ──────────────────────────
                            separatePlayerFrameNameColor = {
                                type="toggle", name="Separate Configuration for Player Frame", order=0, width="full",
                                desc="When enabled, the player frame uses its own name color mode instead of the Player Name Colors setting.",
                                get = function() return self.ufDB.profile.separatePlayerFrameNameColor end,
                                set = function(_, v)
                                    self.ufDB.profile.separatePlayerFrameNameColor = v
                                    relayoutAll(); updateAll()
                                end,
                            },
                            -- ── Player Frame Name Color (per-frame override) ────
                            playerFrameNameColorsGroup = {
                                type="group", name="Player Frame Name Color", inline=true, order=1,
                                hidden = function() return not self.ufDB.profile.separatePlayerFrameNameColor end,
                                args = {
                                    playerFrameNameColorMode = {
                                        type="select", name="Color Mode", order=1, width=1.5,
                                        values = {
                                            class  = "Use Class Colors",
                                            static = "Use Static Color",
                                        },
                                        sorting = { "class", "static" },
                                        get = function() return self.ufDB.profile.playerFrameNameColorMode or "class" end,
                                        set = function(_, v)
                                            self.ufDB.profile.playerFrameNameColorMode = v
                                            local f = BF.oufPlayer
                                            if f and f.unit then relayoutAll(); updateAll() end
                                        end,
                                    },
                                    nameColorGroup = {
                                        type="group", name="Name Color", inline=true, order=2,
                                        hidden = function() return (self.ufDB.profile.playerFrameNameColorMode or "class") ~= "static" end,
                                        args = {
                                            playerFrameNameColor = {
                                                type="color", name="Name Color", order=1, hasAlpha=false,
                                                desc="Static name text color for the player frame.",
                                                get = function()
                                                    local c = self.ufDB.profile.playerFrameNameColor or { r=1, g=1, b=1 }
                                                    return c.r, c.g, c.b
                                                end,
                                                set = function(_, r, g, b)
                                                    self.ufDB.profile.playerFrameNameColor = { r=r, g=g, b=b }
                                                    relayoutAll(); updateAll()
                                                end,
                                                disabled = InCombatLockdown,
                                            },
                                        },
                                    },
                                },
                            },
                            -- ── Player Name Colors ───────────────────────────────
                            playerNameColorsGroup = {
                                type="group", name="Player Name Colors", inline=true, order=2,
                                args = {
                                    globalPlayerNameColorMode = {
                                        type="select", name="Color Mode", order=1, width=1.5,
                                        values = {
                                            class  = "Use Class Colors",
                                            static = "Use Static Color",
                                        },
                                        sorting = { "class", "static" },
                                        get = function() return self.ufDB.profile.globalPlayerNameColorMode or "class" end,
                                        set = function(_, v)
                                            self.ufDB.profile.globalPlayerNameColorMode = v
                                            relayoutAll(); updateAll()
                                        end,
                                    },
                                    nameColorGroup = {
                                        type="group", name="Name Color", inline=true, order=2,
                                        hidden = function() return (self.ufDB.profile.globalPlayerNameColorMode or "class") ~= "static" end,
                                        args = {
                                            globalNameColor = {
                                                type="color", name="Name Color", order=1, hasAlpha=false,
                                                desc="Static name text color for player targets.",
                                                get = function()
                                                    local c = self.ufDB.profile.globalNameColor or { r=1, g=1, b=1 }
                                                    return c.r, c.g, c.b
                                                end,
                                                set = function(_, r, g, b)
                                                    self.ufDB.profile.globalNameColor = { r=r, g=g, b=b }
                                                    relayoutAll(); updateAll()
                                                end,
                                                disabled = InCombatLockdown,
                                            },
                                        },
                                    },
                                },
                            },
                            -- ── NPC Name Colors ─────────────────────────────────
                            npcNameColorsGroup = {
                                type="group", name="NPC Name Colors", inline=true, order=3,
                                args = {
                                    globalNpcNameColorMode = {
                                        type="select", name="Color Mode", order=1, width=1.5,
                                        values = {
                                            classification = "Color by Classification",
                                            hostility      = "Color by Hostility",
                                            static         = "Use Static Color",
                                        },
                                        sorting = { "classification", "hostility", "static" },
                                        get = function() return self.ufDB.profile.globalNpcNameColorMode or "classification" end,
                                        set = function(_, v)
                                            self.ufDB.profile.globalNpcNameColorMode = v
                                            relayoutAll(); updateAll()
                                        end,
                                    },
                                    classificationColorsGroup = {
                                        type="group", name="Classification Colors", inline=true, order=2,
                                        hidden = function() return (self.ufDB.profile.globalNpcNameColorMode or "classification") ~= "classification" end,
                                        args = {
                                            globalNpcFriendlyColor = {
                                                type="color", name="Friendly", order=1, hasAlpha=false,
                                                desc=DESC_FRIENDLY,
                                                get = function()
                                                    local c = self.ufDB.profile.globalNpcFriendlyColor or { r=0.00, g=0.65, b=0.00 }
                                                    return c.r, c.g, c.b
                                                end,
                                                set = function(_, r, g, b)
                                                    self.ufDB.profile.globalNpcFriendlyColor = { r=r, g=g, b=b }
                                                    relayoutAll(); updateAll()
                                                end,
                                                disabled = InCombatLockdown,
                                            },
                                            globalNpcNeutralColor = {
                                                type="color", name="Neutral", order=2, hasAlpha=false,
                                                desc=DESC_NEUTRAL,
                                                get = function()
                                                    local c = self.ufDB.profile.globalNpcNeutralColor or { r=0.90, g=0.70, b=0.00 }
                                                    return c.r, c.g, c.b
                                                end,
                                                set = function(_, r, g, b)
                                                    self.ufDB.profile.globalNpcNeutralColor = { r=r, g=g, b=b }
                                                    relayoutAll(); updateAll()
                                                end,
                                                disabled = InCombatLockdown,
                                            },
                                            globalNpcRegularColor = {
                                                type="color", name="Regular", order=3, hasAlpha=false,
                                                desc=DESC_REGULAR,
                                                get = function()
                                                    local c = self.ufDB.profile.globalNpcRegularColor or { r=0.745, g=0.188, b=0.114 }
                                                    return c.r, c.g, c.b
                                                end,
                                                set = function(_, r, g, b)
                                                    self.ufDB.profile.globalNpcRegularColor = { r=r, g=g, b=b }
                                                    relayoutAll(); updateAll()
                                                end,
                                                disabled = InCombatLockdown,
                                            },
                                            globalNpcBossColor = {
                                                type="color", name="Boss", order=4, hasAlpha=false,
                                                desc=DESC_BOSS,
                                                get = function()
                                                    local c = self.ufDB.profile.globalNpcBossColor or { r=1.00, g=0.00, b=1.00 }
                                                    return c.r, c.g, c.b
                                                end,
                                                set = function(_, r, g, b)
                                                    self.ufDB.profile.globalNpcBossColor = { r=r, g=g, b=b }
                                                    relayoutAll(); updateAll()
                                                end,
                                                disabled = InCombatLockdown,
                                            },
                                            globalNpcLieutenantColor = {
                                                type="color", name="Lieutenant", order=5, hasAlpha=false,
                                                desc=DESC_LIEUTENANT,
                                                get = function()
                                                    local c = self.ufDB.profile.globalNpcLieutenantColor or { r=0.576, g=0.439, b=0.859 }
                                                    return c.r, c.g, c.b
                                                end,
                                                set = function(_, r, g, b)
                                                    self.ufDB.profile.globalNpcLieutenantColor = { r=r, g=g, b=b }
                                                    relayoutAll(); updateAll()
                                                end,
                                                disabled = InCombatLockdown,
                                            },
                                            globalNpcCasterColor = {
                                                type="color", name="Caster", order=6, hasAlpha=false,
                                                desc=DESC_CASTER,
                                                get = function()
                                                    local c = self.ufDB.profile.globalNpcCasterColor or { r=0.00, g=0.820, b=1.00 }
                                                    return c.r, c.g, c.b
                                                end,
                                                set = function(_, r, g, b)
                                                    self.ufDB.profile.globalNpcCasterColor = { r=r, g=g, b=b }
                                                    relayoutAll(); updateAll()
                                                end,
                                                disabled = InCombatLockdown,
                                            },
                                            globalNpcTrivialColor = {
                                                type="color", name="Trivial", order=7, hasAlpha=false,
                                                desc=DESC_TRIVIAL,
                                                get = function()
                                                    local c = self.ufDB.profile.globalNpcTrivialColor or { r=0.592, g=0.612, b=0.592 }
                                                    return c.r, c.g, c.b
                                                end,
                                                set = function(_, r, g, b)
                                                    self.ufDB.profile.globalNpcTrivialColor = { r=r, g=g, b=b }
                                                    relayoutAll(); updateAll()
                                                end,
                                                disabled = InCombatLockdown,
                                            },
                                        },
                                    },
                                    hostilityColorsGroup = {
                                        type="group", name="Hostility Colors", inline=true, order=3,
                                        hidden = function() return (self.ufDB.profile.globalNpcNameColorMode or "classification") ~= "hostility" end,
                                        args = {
                                            hostileColor = {
                                                type="color", name="Hostile", order=1, hasAlpha=false,
                                                desc="Name color for hostile NPCs.",
                                                get = function()
                                                    local c = self.ufDB.profile.globalNpcRegularColor or { r=0.745, g=0.188, b=0.114 }
                                                    return c.r, c.g, c.b
                                                end,
                                                set = function(_, r, g, b)
                                                    self.ufDB.profile.globalNpcRegularColor = { r=r, g=g, b=b }
                                                    relayoutAll(); updateAll()
                                                end,
                                                disabled = InCombatLockdown,
                                            },
                                            neutralColor = {
                                                type="color", name="Neutral", order=2, hasAlpha=false,
                                                desc="Name color for neutral NPCs.",
                                                get = function()
                                                    local c = self.ufDB.profile.globalNpcNeutralColor or { r=0.90, g=0.70, b=0.00 }
                                                    return c.r, c.g, c.b
                                                end,
                                                set = function(_, r, g, b)
                                                    self.ufDB.profile.globalNpcNeutralColor = { r=r, g=g, b=b }
                                                    relayoutAll(); updateAll()
                                                end,
                                                disabled = InCombatLockdown,
                                            },
                                            friendlyColor = {
                                                type="color", name="Friendly", order=3, hasAlpha=false,
                                                desc="Name color for friendly NPCs.",
                                                get = function()
                                                    local c = self.ufDB.profile.globalNpcFriendlyColor or { r=0.00, g=0.65, b=0.00 }
                                                    return c.r, c.g, c.b
                                                end,
                                                set = function(_, r, g, b)
                                                    self.ufDB.profile.globalNpcFriendlyColor = { r=r, g=g, b=b }
                                                    relayoutAll(); updateAll()
                                                end,
                                                disabled = InCombatLockdown,
                                            },
                                        },
                                    },
                                    npcNameColorGroup = {
                                        type="group", name="Name Color", inline=true, order=4,
                                        hidden = function() return (self.ufDB.profile.globalNpcNameColorMode or "classification") ~= "static" end,
                                        args = {
                                            globalNpcNameColor = {
                                                type="color", name="NPC Name Color", order=1, hasAlpha=false,
                                                desc="Static name text color for all NPCs.",
                                                get = function()
                                                    local c = self.ufDB.profile.globalNpcNameColor or { r=1, g=1, b=1 }
                                                    return c.r, c.g, c.b
                                                end,
                                                set = function(_, r, g, b)
                                                    self.ufDB.profile.globalNpcNameColor = { r=r, g=g, b=b }
                                                    relayoutAll(); updateAll()
                                                end,
                                                disabled = InCombatLockdown,
                                            },
                                        },
                                    },
                                },
                            },
                            -- ── Pet Frame Name Color ─────────────────────────────
                            petNameColorsGroup = {
                                type="group", name="Pet Frame Name Color", inline=true, order=4,
                                hidden = function() return not self.ufDB.profile.showPetFrame end,
                                args = {
                                    petMatchPlayerNameColor = {
                                        type="toggle", name="Match Player Color", order=1, width="full",
                                        desc="Use the same name color as the player frame.",
                                        get = function() return ufGet("pet", "petMatchPlayerNameColor") ~= false end,
                                        set = function(_, v)
                                            ufSet("pet", "petMatchPlayerNameColor", v)
                                            relayoutAll(); updateAll()
                                        end,
                                        disabled = InCombatLockdown,
                                    },
                                    nameColor = {
                                        type="color", name="Name Color", order=2, hasAlpha=false,
                                        desc="Custom name text color for the pet frame.",
                                        get = function()
                                            local c = ufGet("pet", "nameColor") or { r=1, g=1, b=1 }
                                            return c.r, c.g, c.b
                                        end,
                                        set = function(_, r, g, b)
                                            ufSet("pet", "nameColor", { r=r, g=g, b=b })
                                            relayoutAll(); updateAll()
                                        end,
                                        disabled = InCombatLockdown,
                                        hidden   = function() return ufGet("pet", "petMatchPlayerNameColor") ~= false end,
                                    },
                                },
                            },
                        },
                    },
                    -- ── Power Bars sub-tab ────────────────────────────────────
                    powerBarsSubTab = {
                        type  = "group",
                        name  = "Power Bars",
                        order = 4,
                        args  = {
                            colorsNote = {
                                type="description", order=1, width="full",
                                name="Power Colors can be customized in the global Colors section:",
                            },
                            openColorsBtn = {
                                type="execute", name="Colors", order=2,
                                func = function()
                                    local ACD = LibStub("AceConfigDialog-3.0")
                                    ACD:SelectGroup("BuzzardFrames", "colors")
                                end,
                            },
                        },
                    },
                },
            },
            -- ── Textures tab ─────────────────────────────────────────────
            texturesTab = {
                type  = "group",
                name  = "Textures",
                order = 5,
                args  = {
                    healthBarTextureGroup = {
                        type="group", name="Health Bar Texture", inline=true, order=1,
                        args = {
                            oufUseCustomHealthBarTexture = {
                                type="toggle", name="Use Custom Health Texture", order=1,
                                get = function() return self.ufDB.profile.oufUseCustomHealthBarTexture end,
                                set = function(_, val)
                                    if InCombatLockdown() then return end
                                    self.ufDB.profile.oufUseCustomHealthBarTexture = val
                                    relayoutAll()
                                end,
                                disabled = InCombatLockdown,
                            },
                            oufHealthBarTexture = {
                                type="select", name="Health Bar Texture", order=2,
                                dialogControl="LSM30_Statusbar",
                                desc="Texture for the health bar fill.",
                                hidden = function() return not self.ufDB.profile.oufUseCustomHealthBarTexture end,
                                disabled = InCombatLockdown,
                                values = function()
                                    local LSM = LibStub("LibSharedMedia-3.0", true)
                                    local vals = {}
                                    if LSM then
                                        for name in pairs(LSM:HashTable("statusbar")) do
                                            vals[name] = name
                                        end
                                    end
                                    return vals
                                end,
                                get = function() return self.ufDB.profile.oufHealthBarTexture or "Blizzard Raid Bar" end,
                                set = function(_, val)
                                    if InCombatLockdown() then return end
                                    self.ufDB.profile.oufHealthBarTexture = val
                                    relayoutAll()
                                end,
                            },
                        },
                    },
                    -- ── Power Bar Texture ──────────────────────────────────
                    powerBarTextureGroup = {
                        type="group", name="Power Bar Texture", inline=true, order=2,
                        args = {
                            oufUseCustomPowerBarTexture = {
                                type="toggle", name="Use Custom Power Texture", order=1,
                                get = function() return self.ufDB.profile.oufUseCustomPowerBarTexture end,
                                set = function(_, val)
                                    if InCombatLockdown() then return end
                                    self.ufDB.profile.oufUseCustomPowerBarTexture = val
                                    relayoutAll()
                                end,
                                disabled = InCombatLockdown,
                            },
                            oufPowerBarTexture = {
                                type="select", name="Power Bar Texture", order=2,
                                dialogControl="LSM30_Statusbar",
                                desc="Texture for the power bar fill.",
                                hidden = function() return not self.ufDB.profile.oufUseCustomPowerBarTexture end,
                                disabled = InCombatLockdown,
                                values = function()
                                    local LSM = LibStub("LibSharedMedia-3.0", true)
                                    local vals = {}
                                    if LSM then
                                        for name in pairs(LSM:HashTable("statusbar")) do
                                            vals[name] = name
                                        end
                                    end
                                    return vals
                                end,
                                get = function() return self.ufDB.profile.oufPowerBarTexture or "Blizzard Raid Bar" end,
                                set = function(_, val)
                                    if InCombatLockdown() then return end
                                    self.ufDB.profile.oufPowerBarTexture = val
                                    relayoutAll()
                                end,
                            },
                        },
                    },
                },
            },
            -- NOTE: Cast Bar Colors moved to the root Colors nav tab
            -- (Options_Colors.lua -> castBarColorsGroup) so all global
            -- color settings live in one place. Storage keys unchanged
            -- (ufDB.profile.castBarColor / castBarUninterruptibleColor /
            -- castBarBgColor); setters still call BF:_ApplyOUFCastbarColors
            -- and BF:_ApplyOUFCastbarBgColor.
            -- ── Tooltips sub-tab ──────────────────────────────────────
            -- Gates consumed in oUF_Shared.lua BluzzardStyle:
            --   * self:HookScript("OnEnter", ...) -> dbp.showUnitTooltip
            --   * iconFrame OnEnter             -> dbp.showUnitTooltip
            --   * both also check dbp.showUnitTooltipInCombat when
            --     InCombatLockdown() is true.
            -- Defaults live in UnitFrames/Defaults_UnitFrames.lua
            -- (showUnitTooltip = true, showUnitTooltipInCombat = true).
            -- No relayout needed on change: the HookScripts read these
            -- keys live from BF.ufDB.profile on every mouseover.
            tooltipsTab = {
                type  = "group",
                name  = "Tooltips",
                order = 9,
                args  = {
                    -- NOTE: Do NOT set width="full" on these toggles.
                    -- AceGUI anchors the `desc` tooltip to the widget's
                    -- right edge; on a full-width widget that ends up far
                    -- to the right of the options panel, away from where
                    -- the cursor is hovering. Matches the pattern used by
                    -- the raid/party Tooltips section (Options_Tooltips.lua).
                    showUnitTooltip = {
                        type  = "toggle",
                        name  = "Show Unit Tooltips",
                        desc  = "Enable tooltip when mousing over unit frames.",
                        order = 1,
                        get   = function() return self.ufDB.profile.showUnitTooltip ~= false end,
                        set   = function(_, v)
                            if InCombatLockdown() then return end
                            self.ufDB.profile.showUnitTooltip = v
                        end,
                        disabled = InCombatLockdown,
                    },
                    showUnitTooltipInCombat = {
                        type  = "toggle",
                        name  = "Show In Combat",
                        desc  = "Enable unit frame tooltips when in combat.",
                        order = 2,
                        get   = function() return self.ufDB.profile.showUnitTooltipInCombat ~= false end,
                        set   = function(_, v)
                            if InCombatLockdown() then return end
                            self.ufDB.profile.showUnitTooltipInCombat = v
                        end,
                        disabled = InCombatLockdown,
                        -- Gated by Show Unit Tooltips: no point tuning
                        -- combat behaviour when the whole feature is off.
                        hidden   = function() return self.ufDB.profile.showUnitTooltip == false end,
                    },
                },
            },
        },
    }
    -- Hide non-Size sub-tabs for player when player frame is disabled.
    bluzzPlayerOpts.args.aurasTab.hidden    = playerFrameDisabled
    bluzzPlayerOpts.args.resourceTab.hidden = playerFrameDisabled



    -- ── Icons sub-tab (Player Frame only) ─────────────────────────────────────
    bluzzPlayerOpts.args.playerIconsTab = {
        type  = "group",
        name  = "Combat Indicator",
        order = 8,
        hidden = playerFrameDisabled,
        args = {
            hdrCombat = { type="header", name="Combat Indicator", order=1 },
            oufShowCombatIndicator = {
                type  = "toggle",
                name  = "Show Combat Indicator",
                desc  = "Show a combat icon in the center of the player health bar when in combat.",
                order = 2,
                width = "full",
                get   = function() return self.ufDB.profile.oufShowCombatIndicator ~= false end,
                set   = function(_, v)
                    if InCombatLockdown() then return end
                    self.ufDB.profile.oufShowCombatIndicator = v
                    relayoutPlayer()
                end,
                disabled = InCombatLockdown,
            },
            oufCombatIndicatorSize = {
                type  = "range",
                name  = "Size",
                order = 3,
                min = 6, max = 40, step = 1,
                get   = function() return self.ufDB.profile.oufCombatIndicatorSize or 18 end,
                set   = function(_, v)
                    if InCombatLockdown() then return end
                    self.ufDB.profile.oufCombatIndicatorSize = v
                    relayoutPlayer()
                end,
                disabled = InCombatLockdown,
                hidden   = function() return not self.ufDB.profile.oufShowCombatIndicator end,
            },
        },
    }

    return makeFrameOpts, bluzzPlayerOpts, bluzzTargetOpts, globalOpts
end
