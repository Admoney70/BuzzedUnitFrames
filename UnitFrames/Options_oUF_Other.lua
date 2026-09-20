-- ============================================================
-- BuzzardFrames: Options_UnitFrames.lua
-- Builds and returns the "Player & Target" nav-tab args table.
-- Called from UnitFrames_Shared.lua hook after RegisterOptions.
-- ============================================================
local BF = _G["BuzzardFrames"]

function BF:BuildPTFOptionsTable()
    local function get(info)
        return self.ufDB.profile[info[#info]]
    end

    local function set(info, val)
        if InCombatLockdown() then return end
        self.ufDB.profile[info[#info]] = val
        -- Profile value saved; caller's set callback handles any live update.
    end
    local function setColor(info, r, g, b)
        if InCombatLockdown() then return end
        local key = info[#info]
        self.ufDB.profile[key] = self.ufDB.profile[key] or {}
        self.ufDB.profile[key].r = r
        self.ufDB.profile[key].g = g
        self.ufDB.profile[key].b = b
    end
    local function getColor(info)
        local c = self.ufDB.profile[info[#info]] or { r=0.24, g=0.78, b=0.24 }
        return c.r, c.g, c.b
    end
    local function getColorA(info)
        local c = self.ufDB.profile[info[#info]] or { r=0.08, g=0.08, b=0.08, a=1 }
        return c.r, c.g, c.b, c.a or 1
    end
    local function setColorA(info, r, g, b, a)
        if InCombatLockdown() then return end
        local key = info[#info]
        self.ufDB.profile[key] = self.ufDB.profile[key] or {}
        self.ufDB.profile[key].r = r
        self.ufDB.profile[key].g = g
        self.ufDB.profile[key].b = b
        self.ufDB.profile[key].a = a
    end

    -- Reload prompt helper - used for options that require a UI reload to take effect.
    local function promptReload()
        C_Timer.After(0, function() StaticPopup_Show("BUZZARDFRAMES_RELOAD_UI") end)
    end

    -- Live layout + update helpers for oUF frames.
    local function relayoutPlayer()
        if BF.oufPlayer then BF:ApplyOUFPlayerLayout() end
    end
    local function updatePlayer()
        if BF.oufPlayer then BF.oufPlayer:UpdateAllElements("Manual") end
    end
    local function relayoutTarget()
        if BF.oufTarget then BF:ApplyOUFTargetLayout() end
    end
    local function updateTarget()
        if BF.oufTarget then BF.oufTarget:UpdateAllElements("Manual") end
    end
    local function relayoutFocus()       if BF.oufFocus        then BF:ApplyOUFFocusLayout()        end end
    local function relayoutPet()         if BF.oufPet          then BF:ApplyOUFPetLayout()          end end
    local function relayoutTot()         if BF.oufTargetOfTarget then BF:ApplyOUFTargetOfTargetLayout() end end
    local function relayoutFocusTarget() if BF.oufFocusTarget  then BF:ApplyOUFFocusTargetLayout()  end end
    local function relayoutBoss()        if BF.oufBoss         then BF:ApplyOUFBossFrameLayout()   end end

    local function relayoutBoth()
        relayoutPlayer()
        relayoutTarget()
    end
    local function updateBoth()
        updatePlayer()
        updateTarget()
    end
    -- Relayout/update every active unit frame -- used by Global tab settings.
    local function relayoutAll()
        relayoutPlayer()
        relayoutTarget()
        relayoutFocus()
        relayoutPet()
        relayoutTot()
        relayoutFocusTarget()
        relayoutBoss()
        if BF.RefreshOUFFonts then BF:RefreshOUFFonts() end
    end
    local function updateAll()
        updatePlayer()
        updateTarget()
        if BF.oufFocus        then BF.oufFocus:UpdateAllElements("Manual")        end
        if BF.oufPet          then BF.oufPet:UpdateAllElements("Manual")          end
        if BF.oufTargetOfTarget then BF.oufTargetOfTarget:UpdateAllElements("Manual") end
        if BF.oufFocusTarget  then BF.oufFocusTarget:UpdateAllElements("Manual")  end
        if BF.oufBoss then
            for i = 1, 5 do
                local f = BF.oufBoss[i]
                if f then f:UpdateAllElements("Manual") end
            end
        end
    end

    -- Helper: get/set routed into the per-unit sub-table
    local function ufGet(unit, key)
        local uf = self.ufDB.profile[unit] or {}
        return uf[key]
    end
    local function ufSet(unit, key, val)
        if InCombatLockdown() then return end
        self.ufDB.profile[unit] = self.ufDB.profile[unit] or {}
        self.ufDB.profile[unit][key] = val
    end

    -- Shared point-values table for all anchor selects
    local anchorValues = {
        LEFT="Left", CENTER="Center", RIGHT="Right",
        TOPLEFT="Top Left", TOP="Top", TOPRIGHT="Top Right",
        BOTTOMLEFT="Bottom Left", BOTTOM="Bottom", BOTTOMRIGHT="Bottom Right",
    }

    -- Build a 3-key inline position group (point, x, y) for a given sub-key
    local function makePosGroup(unit, name, posKey, defaultPoint, defaultX, order, relayout, update)
        return {
            type="group", name=name, order=order, inline=true,
            args = {
                point = {
                    type="select", name="Position", order=1,
                    values = anchorValues,
                    get = function()
                        local uf = self.ufDB.profile[unit] or {}
                        return (uf[posKey] or {}).point or defaultPoint
                    end,
                    set = function(_, v)
                        ufSet(unit, posKey, self.ufDB.profile[unit][posKey] or {})
                        self.ufDB.profile[unit][posKey].point = v
                        if relayout then relayout() end
                    end,
                },
                x = {
                    type="range", name="X Offset", order=2,
                    min=-200, max=200, step=1, softMin=-50, softMax=50,
                    get = function()
                        local uf = self.ufDB.profile[unit] or {}
                        return (uf[posKey] or {}).x or defaultX
                    end,
                    set = function(_, v)
                        ufSet(unit, posKey, self.ufDB.profile[unit][posKey] or {})
                        self.ufDB.profile[unit][posKey].x = v
                        if relayout then relayout() end
                    end,
                },
                y = {
                    type="range", name="Y Offset", order=3,
                    min=-200, max=200, step=1, softMin=-50, softMax=50,
                    get = function()
                        local uf = self.ufDB.profile[unit] or {}
                        return (uf[posKey] or {}).y or 0
                    end,
                    set = function(_, v)
                        ufSet(unit, posKey, self.ufDB.profile[unit][posKey] or {})
                        self.ufDB.profile[unit][posKey].y = v
                        if relayout then relayout() end
                    end,
                },
            },
        }
    end


    -- Player/Target/Global option tables are built in Options_oUF_Player_Target.lua.
    local makeFrameOpts, bluzzPlayerOpts, bluzzTargetOpts, globalOpts = BF:_BuildPlayerTargetOpts({
        self           = self,
        ufGet          = ufGet,
        ufSet          = ufSet,
        promptReload   = promptReload,
        relayoutPlayer = relayoutPlayer,
        updatePlayer   = updatePlayer,
        relayoutTarget = relayoutTarget,
        updateTarget   = updateTarget,
        relayoutAll    = relayoutAll,
        updateAll      = updateAll,
        makePosGroup   = makePosGroup,
    })


    -- ============================================================
    -- PET FRAME TAB
    -- ============================================================
    local relayoutPet = function() if BF.oufPet then BF:ApplyOUFPetLayout() end end
    local updatePet   = function() if BF.oufPet then BF.oufPet:UpdateAllElements("Manual") end end

    local _petBase = makeFrameOpts(
        "pet", "Pet Frame", 5,
        "showPetFrame",
        function() return BF.oufPet end,
        relayoutPet, updatePet, "Pet Frame")

    local function petFrameDisabled() return not self.ufDB.profile.showPetFrame end
    _petBase.args.nameTab.hidden   = petFrameDisabled
    _petBase.args.healthTab.hidden = petFrameDisabled
    _petBase.args.powerTab.hidden  = petFrameDisabled

    -- Pet health: per-frame color controls moved to Colors > Health Bars subtab
    local petHealthArgs = _petBase.args.healthTab.args
    petHealthArgs.useClassColor      = nil
    petHealthArgs.hdrColor           = nil
    petHealthArgs.healthColor        = nil
    petHealthArgs.petMatchPlayerColor = nil

    -- Pet name: per-frame controls moved to Colors > Names subtab
    local petNameArgs = _petBase.args.nameTab.args
    petNameArgs.hdrNameColor          = nil
    petNameArgs.useClassColorName     = nil
    petNameArgs.nameColor             = nil
    petNameArgs.petMatchPlayerNameColor = nil

    local petOpts = _petBase

    -- ============================================================
    -- FOCUS FRAME TAB
    -- Reuses the same makeFrameOpts factory as player/target, then
    -- applies target-style post-hoc overrides for hostility colors
    -- and adds the auras sub-tab.
    -- ============================================================
    local relayoutFocus = function() if BF.oufFocus then BF:ApplyOUFFocusLayout() end end
    local updateFocus   = function() if BF.oufFocus then BF.oufFocus:UpdateAllElements("Manual") end end

    local _focusBase = makeFrameOpts(
        "focus", "Focus Frame", 4,
        "showFocusFrame",
        function() return BF.oufFocus end,
        relayoutFocus, updateFocus, "Focus Frame")

    -- ── Focus: name colors are now in Global > Name Bar Colors ─────────────
    local fNameArgs = _focusBase.args.nameTab.args
    fNameArgs.hdrNameColor      = nil
    fNameArgs.useClassColorName = nil
    fNameArgs.nameColor         = nil

    -- ── Focus: health colors are now in Global > Health Bar Colors ──────────
    local fHealthArgs = _focusBase.args.healthTab.args
    fHealthArgs.hdrColor     = nil
    fHealthArgs.useClassColor = nil
    fHealthArgs.healthColor  = nil

    -- ── Focus: Auras sub-tab (mirrors target auras, keyed with "focus" prefix) -
    local function fufGet(key, default)
        local pf = BF.ufDB.profile.focus or {}
        local v = pf[key]
        if v == nil then return default end
        return v
    end
    local function fufSet(key, val)
        if InCombatLockdown() then return end
        BF.ufDB.profile.focus = BF.ufDB.profile.focus or {}
        BF.ufDB.profile.focus[key] = val
        relayoutFocus()
    end

    local function focusFrameDisabled() return not self.ufDB.profile.showFocusFrame end
    _focusBase.args.nameTab.hidden   = focusFrameDisabled
    _focusBase.args.healthTab.hidden = focusFrameDisabled
    _focusBase.args.powerTab.hidden  = focusFrameDisabled

    _focusBase.args.aurasTab = {
        type  = "group",
        name  = "Auras",
        order = 4,
        args  = {
            hdrDebuffs = { type="header", name="Debuffs", order=10 },
            focusShowDebuffs = {
                type="toggle", name="Show Debuffs", order=11, width="full",
                get = function() return fufGet("focusShowDebuffs", true) end,
                set = function(_, v) fufSet("focusShowDebuffs", v) end,
            },
            focusDebuffSize = {
                type="range", name="Icon Size", order=12, min=10, max=36, step=1,
                get = function() return fufGet("focusDebuffSize", 18) end,
                set = function(_, v) fufSet("focusDebuffSize", v) end,
                disabled = InCombatLockdown,
                hidden   = function() return not fufGet("focusShowDebuffs", true) end,
            },
            focusDebuffsPerRow = {
                type="range", name="Per Row", order=13, min=1, max=32, step=1,
                get = function() return fufGet("focusDebuffsPerRow", 8) end,
                set = function(_, v) fufSet("focusDebuffsPerRow", v) end,
                disabled = InCombatLockdown,
                hidden   = function() return not fufGet("focusShowDebuffs", true) end,
            },
            focusMaxDebuffs = {
                type="range", name="Max Icons", order=14, min=1, max=40, step=1,
                get = function() return fufGet("focusMaxDebuffs", 32) end,
                set = function(_, v) fufSet("focusMaxDebuffs", v) end,
                disabled = InCombatLockdown,
                hidden   = function() return not fufGet("focusShowDebuffs", true) end,
            },
            focusDebuffSpacing = {
                type="range", name="Spacing", order=15, min=0, max=10, step=1,
                get = function() return fufGet("focusDebuffSpacing", 2) end,
                set = function(_, v) fufSet("focusDebuffSpacing", v) end,
                disabled = InCombatLockdown,
                hidden   = function() return not fufGet("focusShowDebuffs", true) end,
            },
            focusDebuffOffsetX = {
                type="range", name="X Offset", order=16,
                min=-200, max=200, step=1, softMin=-50, softMax=50,
                get = function() return fufGet("focusDebuffOffsetX", 0) end,
                set = function(_, v) fufSet("focusDebuffOffsetX", v) end,
                disabled = InCombatLockdown,
                hidden   = function() return not fufGet("focusShowDebuffs", true) end,
            },
            focusDebuffOffsetY = {
                type="range", name="Y Offset", order=17,
                min=-200, max=200, step=1, softMin=-50, softMax=50,
                get = function() return fufGet("focusDebuffOffsetY", 0) end,
                set = function(_, v) fufSet("focusDebuffOffsetY", v) end,
                disabled = InCombatLockdown,
                hidden   = function() return not fufGet("focusShowDebuffs", true) end,
            },
            hdrBuffs = { type="header", name="Buffs", order=30 },
            focusShowBuffs = {
                type="toggle", name="Show Buffs", order=31, width="full",
                get = function() return fufGet("focusShowBuffs", true) end,
                set = function(_, v) fufSet("focusShowBuffs", v) end,
            },
            focusBuffSize = {
                type="range", name="Icon Size", order=32, min=10, max=36, step=1,
                get = function() return fufGet("focusBuffSize", 18) end,
                set = function(_, v) fufSet("focusBuffSize", v) end,
                disabled = InCombatLockdown,
                hidden   = function() return not fufGet("focusShowBuffs", true) end,
            },
            focusBuffsPerRow = {
                type="range", name="Per Row", order=33, min=1, max=32, step=1,
                get = function() return fufGet("focusBuffsPerRow", 8) end,
                set = function(_, v) fufSet("focusBuffsPerRow", v) end,
                disabled = InCombatLockdown,
                hidden   = function() return not fufGet("focusShowBuffs", true) end,
            },
            focusMaxBuffs = {
                type="range", name="Max Icons", order=34, min=1, max=32, step=1,
                get = function() return fufGet("focusMaxBuffs", 32) end,
                set = function(_, v) fufSet("focusMaxBuffs", v) end,
                disabled = InCombatLockdown,
                hidden   = function() return not fufGet("focusShowBuffs", true) end,
            },
            focusBuffSpacing = {
                type="range", name="Spacing", order=35, min=0, max=10, step=1,
                get = function() return fufGet("focusBuffSpacing", 2) end,
                set = function(_, v) fufSet("focusBuffSpacing", v) end,
                disabled = InCombatLockdown,
                hidden   = function() return not fufGet("focusShowBuffs", true) end,
            },
            focusBuffOffsetX = {
                type="range", name="X Offset", order=36,
                min=-200, max=200, step=1, softMin=-50, softMax=50,
                get = function() return fufGet("focusBuffOffsetX", 0) end,
                set = function(_, v) fufSet("focusBuffOffsetX", v) end,
                disabled = InCombatLockdown,
                hidden   = function() return not fufGet("focusShowBuffs", true) end,
            },
            focusBuffOffsetY = {
                type="range", name="Y Offset", order=37,
                min=-200, max=200, step=1, softMin=-50, softMax=50,
                get = function() return fufGet("focusBuffOffsetY", 0) end,
                set = function(_, v) fufSet("focusBuffOffsetY", v) end,
                disabled = InCombatLockdown,
                hidden   = function() return not fufGet("focusShowBuffs", true) end,
            },
        },
    }

    -- ── Focus: Cast Bar sub-tab (exact mirror of target cast bar) ──────────────
    local function fcbShown()    return self.ufDB.profile.focusShowCastBar ~= false end
    local function fcbDetached() return fcbShown() and self.ufDB.profile.focusCastBarDetached == true end
    local function fcbAttached() return fcbShown() and not self.ufDB.profile.focusCastBarDetached end

    _focusBase.args.castBarTab = {
        type  = "group",
        name  = "Cast Bar",
        order = 5,
        args  = {
            -- ── Master toggle ───────────────────────────────────────────────
            focusShowCastBar = {
                type  = "toggle",
                name  = "Show Cast Bar",
                order = 1,
                width = "full",
                get   = function() return self.ufDB.profile.focusShowCastBar ~= false end,
                set   = function(_, v)
                    if InCombatLockdown() then return end
                    self.ufDB.profile.focusShowCastBar = v
                    relayoutFocus()
                end,
                disabled = InCombatLockdown,
            },
            -- ── Placement ───────────────────────────────────────────────────
            hdrPlacement = {
                type = "header", name = "Placement", order = 10,
                hidden = function() return not fcbShown() end,
            },
            focusCastBarDetached = {
                type  = "toggle",
                name  = "Detach from Focus Frame",
                desc  = "When detached, the cast bar can be positioned independently. Unlock frames to drag it.",
                order = 11,
                width = "full",
                get   = function() return self.ufDB.profile.focusCastBarDetached == true end,
                set   = function(_, v)
                    if InCombatLockdown() then return end
                    self.ufDB.profile.focusCastBarDetached = v
                    relayoutFocus()
                end,
                disabled = InCombatLockdown,
                hidden   = function() return not fcbShown() end,
            },
            focusCastBarPosition = {
                type   = "select",
                name   = "Cast Bar Position",
                desc   = "Where the cast bar is anchored when attached to the focus frame.",
                order  = 12,
                values = { below = "Below", above = "Above" },
                get    = function() return self.ufDB.profile.focusCastBarPosition or "below" end,
                set    = function(_, v)
                    if InCombatLockdown() then return end
                    self.ufDB.profile.focusCastBarPosition = v
                    relayoutFocus()
                end,
                disabled = InCombatLockdown,
                hidden   = function() return not fcbAttached() end,
            },
            focusCastBarGap = {
                type  = "range",
                name  = "Y Offset",
                order = 13,
                min=-50, max=50, step=1,
                get   = function() return self.ufDB.profile.focusCastBarGap or 0 end,
                set   = function(_, v)
                    if InCombatLockdown() then return end
                    self.ufDB.profile.focusCastBarGap = v
                    relayoutFocus()
                end,
                disabled = InCombatLockdown,
                hidden   = function() return not fcbAttached() end,
            },
            focusCastBarAvoidAuras = {
                type  = "toggle",
                name  = "Avoid Auras",
                desc  = "Automatically push the cast bar down (or up) to clear any aura icons that are currently visible, based on the live row count.",
                order = 14,
                width = "full",
                get   = function() return self.ufDB.profile.focusCastBarAvoidAuras ~= false end,
                set   = function(_, v)
                    if InCombatLockdown() then return end
                    self.ufDB.profile.focusCastBarAvoidAuras = v
                    relayoutFocus()
                end,
                disabled = InCombatLockdown,
                hidden   = function() return not fcbAttached() end,
            },
            -- ── Size ────────────────────────────────────────────────────────
            hdrSize = {
                type = "header", name = "Size", order = 20,
                hidden = function() return not fcbShown() end,
            },
            focusCastBarHeight = {
                type  = "range",
                name  = "Bar Height",
                order = 21,
                min=4, max=30, step=1,
                get   = function() return self.ufDB.profile.focusCastBarHeight or 14 end,
                set   = function(_, v)
                    if InCombatLockdown() then return end
                    self.ufDB.profile.focusCastBarHeight = v
                    relayoutFocus()
                end,
                disabled = InCombatLockdown,
                hidden   = function() return not fcbShown() end,
            },
            focusCastBarWidth = {
                type  = "range",
                name  = "Bar Width",
                order = 22,
                min=40, max=600, step=1,
                get   = function() return self.ufDB.profile.focusCastBarWidth or 156 end,
                set   = function(_, v)
                    if InCombatLockdown() then return end
                    self.ufDB.profile.focusCastBarWidth = v
                    relayoutFocus()
                end,
                disabled = InCombatLockdown,
                hidden   = function() return not fcbDetached() end,
            },
            focusCastBarFontSize = {
                type  = "range",
                name  = "Font Size",
                order = 23,
                min=6, max=16, step=1,
                get   = function() return ufGet("focus", "castBarFontSize") or 8 end,
                set   = function(_, v)
                    ufSet("focus", "castBarFontSize", v)
                    relayoutFocus()
                end,
                disabled = InCombatLockdown,
                hidden   = function() return not fcbShown() end,
            },
            -- ── Border ──────────────────────────────────────────────────────
            hdrBorder = {
                type = "header", name = "Border", order = 40,
                hidden = function() return not fcbShown() end,
            },
            focusCastBarBorderEnabled = {
                type  = "toggle",
                name  = "Enable Border",
                order = 41,
                get   = function() return self.ufDB.profile.focusCastBarBorderEnabled == true end,
                set   = function(_, v)
                    if InCombatLockdown() then return end
                    self.ufDB.profile.focusCastBarBorderEnabled = v
                    BF:_ApplyOUFCastbarBorder(BF.oufFocus)
                end,
                disabled = InCombatLockdown,
                hidden   = function() return not fcbShown() end,
            },
            focusCastBarBorderThickness = {
                type  = "range",
                name  = "Thickness",
                order = 42,
                min=1, max=6, step=1,
                get   = function() return self.ufDB.profile.focusCastBarBorderThickness or 1 end,
                set   = function(_, v)
                    if InCombatLockdown() then return end
                    self.ufDB.profile.focusCastBarBorderThickness = v
                    BF:_ApplyOUFCastbarBorder(BF.oufFocus)
                end,
                disabled = InCombatLockdown,
                hidden   = function()
                    return not fcbShown()
                        or not (self.ufDB.profile.focusCastBarBorderEnabled == true)
                end,
            },
            focusCastBarBorderColor = {
                type     = "color",
                name     = "Color",
                order    = 43,
                hasAlpha = true,
                get = function()
                    local c = self.ufDB.profile.focusCastBarBorderColor or { r=0, g=0, b=0, a=1 }
                    return c.r, c.g, c.b, c.a or 1
                end,
                set = function(_, r, g, b, a)
                    if InCombatLockdown() then return end
                    self.ufDB.profile.focusCastBarBorderColor = { r=r, g=g, b=b, a=a }
                    BF:_ApplyOUFCastbarBorder(BF.oufFocus)
                end,
                disabled = InCombatLockdown,
                hidden   = function()
                    return not fcbShown()
                        or not (self.ufDB.profile.focusCastBarBorderEnabled == true)
                end,
            },
            -- ── Icon ────────────────────────────────────────────────────────
            hdrIcon = {
                type = "header", name = "Spell Icon", order = 50,
                hidden = function() return not fcbShown() end,
            },
            focusCastBarShowIcon = {
                type  = "toggle",
                name  = "Show Spell Icon",
                order = 51,
                get   = function() return self.ufDB.profile.focusCastBarShowIcon ~= false end,
                set   = function(_, v)
                    if InCombatLockdown() then return end
                    self.ufDB.profile.focusCastBarShowIcon = v
                    BF:_ApplyOUFCastbarIcon(BF.oufFocus)
                end,
                disabled = InCombatLockdown,
                hidden   = function() return not fcbShown() end,
            },
            focusCastBarIconSide = {
                type   = "select",
                name   = "Icon Side",
                order  = 52,
                values = { left = "Left", right = "Right" },
                get    = function() return self.ufDB.profile.focusCastBarIconSide or "left" end,
                set    = function(_, v)
                    if InCombatLockdown() then return end
                    self.ufDB.profile.focusCastBarIconSide = v
                    relayoutFocus()
                end,
                disabled = InCombatLockdown,
                hidden   = function() return not fcbShown() or not (self.ufDB.profile.focusCastBarShowIcon ~= false) end,
            },
            focusCastBarIconSize = {
                type  = "range",
                name  = "Icon Size",
                order = 53,
                min=10, max=48, step=1,
                get   = function() return self.ufDB.profile.focusCastBarIconSize or 20 end,
                set   = function(_, v)
                    if InCombatLockdown() then return end
                    self.ufDB.profile.focusCastBarIconSize = v
                    relayoutFocus()
                end,
                disabled = InCombatLockdown,
                hidden   = function() return not fcbShown() or not (self.ufDB.profile.focusCastBarShowIcon ~= false) end,
            },
            focusCastBarIconGap = {
                type  = "range",
                name  = "Gap",
                desc  = "Distance in pixels between the cast bar and the spell icon.",
                order = 54,
                min=0, max=20, step=1,
                get   = function() return self.ufDB.profile.focusCastBarIconGap or 2 end,
                set   = function(_, v)
                    if InCombatLockdown() then return end
                    self.ufDB.profile.focusCastBarIconGap = v
                    relayoutFocus()
                end,
                disabled = InCombatLockdown,
                hidden   = function() return not fcbShown() or not (self.ufDB.profile.focusCastBarShowIcon ~= false) end,
            },
        },
    }

    _focusBase.args.aurasTab.hidden    = focusFrameDisabled
    _focusBase.args.castBarTab.hidden  = focusFrameDisabled

    local bluzzFocusOpts = _focusBase

    -- ============================================================
    -- TARGET OF TARGET FRAME TAB
    -- Reuses the same makeFrameOpts factory as target/focus, then
    -- applies target-style post-hoc overrides for hostility colors
    -- and adds the auras sub-tab.
    -- ============================================================
    local relayoutTot = function() if BF.oufTargetOfTarget then BF:ApplyOUFTargetOfTargetLayout() end end
    local updateTot   = function() if BF.oufTargetOfTarget then BF.oufTargetOfTarget:UpdateAllElements("Manual") end end

    local _totBase = makeFrameOpts(
        "targettarget", "Target of Target", 6,
        "showTargetOfTargetFrame",
        function() return BF.oufTargetOfTarget end,
        relayoutTot, updateTot, "Target of Target Frame")

    -- ── ToT: name colors are now in Global > Name Bar Colors ───────────────
    local totNameArgs = _totBase.args.nameTab.args
    totNameArgs.hdrNameColor      = nil
    totNameArgs.useClassColorName = nil
    totNameArgs.nameColor         = nil

    -- ── ToT: health colors are now in Global > Health Bar Colors ────────────
    local totHealthArgs = _totBase.args.healthTab.args
    totHealthArgs.hdrColor     = nil
    totHealthArgs.useClassColor = nil
    totHealthArgs.healthColor  = nil

    local function totFrameDisabled() return not self.ufDB.profile.showTargetOfTargetFrame end
    _totBase.args.nameTab.hidden   = totFrameDisabled
    _totBase.args.healthTab.hidden = totFrameDisabled
    _totBase.args.powerTab.hidden  = totFrameDisabled

    local bluzzTotOpts = _totBase

    -- ============================================================
    -- FOCUS TARGET FRAME TAB
    -- ============================================================
    local relayoutFocusTarget2 = function() if BF.oufFocusTarget then BF:ApplyOUFFocusTargetLayout() end end
    local updateFocusTarget    = function() if BF.oufFocusTarget then BF.oufFocusTarget:UpdateAllElements("Manual") end end

    local _ftBase = makeFrameOpts(
        "focustarget", "Focus Target", 7,
        "showFocusTargetFrame",
        function() return BF.oufFocusTarget end,
        relayoutFocusTarget2, updateFocusTarget, "Focus Target Frame")

    -- ── FocusTarget: name colors are now in Global > Name Bar Colors ────────
    local ftNameArgs = _ftBase.args.nameTab.args
    ftNameArgs.hdrNameColor      = nil
    ftNameArgs.useClassColorName = nil
    ftNameArgs.nameColor         = nil

    -- ── FocusTarget: health colors are now in Global > Health Bar Colors ─────
    local ftHealthArgs = _ftBase.args.healthTab.args
    ftHealthArgs.hdrColor     = nil
    ftHealthArgs.useClassColor = nil
    ftHealthArgs.healthColor  = nil

    local function ftFrameDisabled() return not self.ufDB.profile.showFocusTargetFrame end
    _ftBase.args.nameTab.hidden   = ftFrameDisabled
    _ftBase.args.healthTab.hidden = ftFrameDisabled
    _ftBase.args.powerTab.hidden  = ftFrameDisabled

    local bluzzFocusTargetOpts = _ftBase

    -- ============================================================
    -- BOSS FRAMES
    -- ============================================================
    local updateBoss = function()
        if BF.oufBoss then
            for i = 1, 5 do
                local f = BF.oufBoss[i]
                if f then f:UpdateAllElements("Manual") end
            end
        end
    end

    local _bossBase = makeFrameOpts(
        "boss", "Boss Frames", 8,
        "showBossFrames",
        function() return BF.oufBoss and BF.oufBoss[1] end,
        relayoutBoss, updateBoss, "Boss Frames")

    -- Boss: name colors are now in Global > Name Bar Colors.
    local bNameArgs = _bossBase.args.nameTab.args
    bNameArgs.hdrNameColor      = nil
    bNameArgs.useClassColorName = nil
    bNameArgs.nameColor         = nil

    -- Boss: health colors are now in Global > Health Bar Colors.
    local bHealthArgs = _bossBase.args.healthTab.args
    bHealthArgs.hdrColor     = nil
    bHealthArgs.useClassColor = nil
    bHealthArgs.healthColor  = nil

    -- Boss: hidden-when-disabled
    local function bossFrameDisabled() return not self.ufDB.profile.showBossFrames end
    _bossBase.args.nameTab.hidden   = bossFrameDisabled
    _bossBase.args.healthTab.hidden = bossFrameDisabled
    _bossBase.args.powerTab.hidden  = bossFrameDisabled

    -- Boss: Auras sub-tab (same pattern as Focus)
    local function bufGet(key, default)
        local pf = BF.ufDB.profile.boss or {}
        local v = pf[key]
        if v == nil then return default end
        return v
    end
    local function bufSet(key, val)
        if InCombatLockdown() then return end
        BF.ufDB.profile.boss = BF.ufDB.profile.boss or {}
        BF.ufDB.profile.boss[key] = val
        relayoutBoss()
    end

    _bossBase.args.aurasTab = {
        type  = "group",
        name  = "Auras",
        order = 5,
        hidden = bossFrameDisabled,
        args  = {
            hdrDebuffs = { type="header", name="Debuffs", order=10 },
            bossShowDebuffs = {
                type="toggle", name="Show Debuffs", order=11, width="full",
                get = function() return bufGet("bossShowDebuffs", true) end,
                set = function(_, v) bufSet("bossShowDebuffs", v) end,
            },
            bossDebuffSize = {
                type="range", name="Icon Size", order=12, min=10, max=36, step=1,
                get = function() return bufGet("bossDebuffSize", 18) end,
                set = function(_, v) bufSet("bossDebuffSize", v) end,
                disabled = InCombatLockdown,
                hidden   = function() return not bufGet("bossShowDebuffs", true) end,
            },
            bossDebuffsPerRow = {
                type="range", name="Per Row", order=13, min=1, max=32, step=1,
                get = function() return bufGet("bossDebuffsPerRow", 8) end,
                set = function(_, v) bufSet("bossDebuffsPerRow", v) end,
                disabled = InCombatLockdown,
                hidden   = function() return not bufGet("bossShowDebuffs", true) end,
            },
            bossMaxDebuffs = {
                type="range", name="Max Icons", order=14, min=1, max=40, step=1,
                get = function() return bufGet("bossMaxDebuffs", 32) end,
                set = function(_, v) bufSet("bossMaxDebuffs", v) end,
                disabled = InCombatLockdown,
                hidden   = function() return not bufGet("bossShowDebuffs", true) end,
            },
            bossDebuffSpacing = {
                type="range", name="Spacing", order=15, min=0, max=10, step=1,
                get = function() return bufGet("bossDebuffSpacing", 2) end,
                set = function(_, v) bufSet("bossDebuffSpacing", v) end,
                disabled = InCombatLockdown,
                hidden   = function() return not bufGet("bossShowDebuffs", true) end,
            },
            bossDebuffOffsetX = {
                type="range", name="X Offset", order=16,
                min=-200, max=200, step=1, softMin=-50, softMax=50,
                get = function() return bufGet("bossDebuffOffsetX", 0) end,
                set = function(_, v) bufSet("bossDebuffOffsetX", v) end,
                disabled = InCombatLockdown,
                hidden   = function() return not bufGet("bossShowDebuffs", true) end,
            },
            bossDebuffOffsetY = {
                type="range", name="Y Offset", order=17,
                min=-200, max=200, step=1, softMin=-50, softMax=50,
                get = function() return bufGet("bossDebuffOffsetY", 0) end,
                set = function(_, v) bufSet("bossDebuffOffsetY", v) end,
                disabled = InCombatLockdown,
                hidden   = function() return not bufGet("bossShowDebuffs", true) end,
            },
            hdrBuffs = { type="header", name="Buffs", order=30 },
            bossShowBuffs = {
                type="toggle", name="Show Buffs", order=31, width="full",
                get = function() return bufGet("bossShowBuffs", true) end,
                set = function(_, v) bufSet("bossShowBuffs", v) end,
            },
            bossBuffSize = {
                type="range", name="Icon Size", order=32, min=10, max=36, step=1,
                get = function() return bufGet("bossBuffSize", 18) end,
                set = function(_, v) bufSet("bossBuffSize", v) end,
                disabled = InCombatLockdown,
                hidden   = function() return not bufGet("bossShowBuffs", true) end,
            },
            bossBuffsPerRow = {
                type="range", name="Per Row", order=33, min=1, max=32, step=1,
                get = function() return bufGet("bossBuffsPerRow", 8) end,
                set = function(_, v) bufSet("bossBuffsPerRow", v) end,
                disabled = InCombatLockdown,
                hidden   = function() return not bufGet("bossShowBuffs", true) end,
            },
            bossMaxBuffs = {
                type="range", name="Max Icons", order=34, min=1, max=32, step=1,
                get = function() return bufGet("bossMaxBuffs", 32) end,
                set = function(_, v) bufSet("bossMaxBuffs", v) end,
                disabled = InCombatLockdown,
                hidden   = function() return not bufGet("bossShowBuffs", true) end,
            },
            bossBuffSpacing = {
                type="range", name="Spacing", order=35, min=0, max=10, step=1,
                get = function() return bufGet("bossBuffSpacing", 2) end,
                set = function(_, v) bufSet("bossBuffSpacing", v) end,
                disabled = InCombatLockdown,
                hidden   = function() return not bufGet("bossShowBuffs", true) end,
            },
            bossBuffOffsetX = {
                type="range", name="X Offset", order=36,
                min=-200, max=200, step=1, softMin=-50, softMax=50,
                get = function() return bufGet("bossBuffOffsetX", 0) end,
                set = function(_, v) bufSet("bossBuffOffsetX", v) end,
                disabled = InCombatLockdown,
                hidden   = function() return not bufGet("bossShowBuffs", true) end,
            },
            bossBuffOffsetY = {
                type="range", name="Y Offset", order=37,
                min=-200, max=200, step=1, softMin=-50, softMax=50,
                get = function() return bufGet("bossBuffOffsetY", 0) end,
                set = function(_, v) bufSet("bossBuffOffsetY", v) end,
                disabled = InCombatLockdown,
                hidden   = function() return not bufGet("bossShowBuffs", true) end,
            },
        },
    }

    -- Boss: Spacing and Grow Direction in Size & Position tab
    local bossSizeArgs = _bossBase.args.sizeTab.args
    bossSizeArgs.bossGrowDirection = {
        type="select", name="Grow Direction", order=7,
        desc="Direction in which boss frames 2-5 stack relative to boss frame 1.",
        values = { DOWN="Down", UP="Up", LEFT="Left", RIGHT="Right" },
        get  = function() return self.ufDB.profile.bossGrowDirection or "DOWN" end,
        set  = function(_, v)
            if InCombatLockdown() then return end
            self.ufDB.profile.bossGrowDirection = v
            relayoutBoss()
        end,
        disabled = InCombatLockdown,
        hidden = bossFrameDisabled,
    }
    bossSizeArgs.hdrSpacing = { type="header", name="Frame Spacing", order=30, hidden=bossFrameDisabled }
    bossSizeArgs.bossFrameSpacing = {
        type="range", name="Spacing Between Frames", order=31,
        desc="Gap between boss frames. Increase to leave room for aura icons.",
        min=0, max=80, step=1,
        get  = function() return self.ufDB.profile.bossFrameSpacing or 4 end,
        set  = function(_, v)
            if InCombatLockdown() then return end
            self.ufDB.profile.bossFrameSpacing = v
            relayoutBoss()
        end,
        disabled = InCombatLockdown,
        hidden = bossFrameDisabled,
    }


    -- ── Boss: Cast Bar sub-tab ────────────────────────────────────────────
    local function bossCbShown() return self.ufDB.profile.bossShowCastBar ~= false end
    local function applyBossCastbars()
        if not BF.oufBoss then return end
        for i = 1, 5 do
            local bf = BF.oufBoss[i]
            if bf then
                BF:_ApplyOUFCastbarColors(bf)
                BF:_ApplyOUFCastbarBgColor(bf)
                BF:_ApplyOUFCastbarBorder(bf)
                BF:_ApplyOUFCastbarIcon(bf)
            end
        end
    end

    _bossBase.args.castBarTab = {
        type  = "group",
        name  = "Cast Bar",
        order = 5,
        args  = {
            bossShowCastBar = {
                type  = "toggle",
                name  = "Show Cast Bar",
                order = 1,
                width = "full",
                get   = function() return self.ufDB.profile.bossShowCastBar ~= false end,
                set   = function(_, v)
                    if InCombatLockdown() then return end
                    self.ufDB.profile.bossShowCastBar = v
                    relayoutBoss()
                end,
                disabled = InCombatLockdown,
            },
            hdrPlacement = {
                type = "header", name = "Placement", order = 10,
                hidden = function() return not bossCbShown() end,
            },
            bossCastBarPosition = {
                type   = "select",
                name   = "Cast Bar Position",
                desc   = "Where the cast bar is anchored relative to the boss frame.",
                order  = 12,
                values = { below = "Below", above = "Above" },
                get    = function() return self.ufDB.profile.bossCastBarPosition or "below" end,
                set    = function(_, v)
                    if InCombatLockdown() then return end
                    self.ufDB.profile.bossCastBarPosition = v
                    relayoutBoss()
                end,
                disabled = InCombatLockdown,
                hidden   = function() return not bossCbShown() end,
            },
            bossCastBarGap = {
                type  = "range",
                name  = "Y Offset",
                order = 13,
                min=-50, max=50, step=1,
                get   = function() return self.ufDB.profile.bossCastBarGap or 0 end,
                set   = function(_, v)
                    if InCombatLockdown() then return end
                    self.ufDB.profile.bossCastBarGap = v
                    relayoutBoss()
                end,
                disabled = InCombatLockdown,
                hidden   = function() return not bossCbShown() end,
            },
            hdrSize = {
                type = "header", name = "Size", order = 20,
                hidden = function() return not bossCbShown() end,
            },
            bossCastBarHeight = {
                type  = "range",
                name  = "Bar Height",
                order = 21,
                min=4, max=30, step=1,
                get   = function() return self.ufDB.profile.bossCastBarHeight or 14 end,
                set   = function(_, v)
                    if InCombatLockdown() then return end
                    self.ufDB.profile.bossCastBarHeight = v
                    relayoutBoss()
                end,
                disabled = InCombatLockdown,
                hidden   = function() return not bossCbShown() end,
            },
            bossCastBarFontSize = {
                type  = "range",
                name  = "Font Size",
                order = 23,
                min=6, max=16, step=1,
                get   = function() return self.ufDB.profile.bossCastBarFontSize or 10 end,
                set   = function(_, v)
                    if InCombatLockdown() then return end
                    self.ufDB.profile.bossCastBarFontSize = v
                    relayoutBoss()
                end,
                disabled = InCombatLockdown,
                hidden   = function() return not bossCbShown() end,
            },
            hdrBorder = {
                type = "header", name = "Border", order = 40,
                hidden = function() return not bossCbShown() end,
            },
            bossCastBarBorderEnabled = {
                type  = "toggle",
                name  = "Enable Border",
                order = 41,
                get   = function() return self.ufDB.profile.bossCastBarBorderEnabled == true end,
                set   = function(_, v)
                    if InCombatLockdown() then return end
                    self.ufDB.profile.bossCastBarBorderEnabled = v
                    applyBossCastbars()
                end,
                disabled = InCombatLockdown,
                hidden   = function() return not bossCbShown() end,
            },
            bossCastBarBorderThickness = {
                type  = "range",
                name  = "Thickness",
                order = 42,
                min=1, max=6, step=1,
                get   = function() return self.ufDB.profile.bossCastBarBorderThickness or 1 end,
                set   = function(_, v)
                    if InCombatLockdown() then return end
                    self.ufDB.profile.bossCastBarBorderThickness = v
                    applyBossCastbars()
                end,
                disabled = InCombatLockdown,
                hidden   = function()
                    return not bossCbShown()
                        or not (self.ufDB.profile.bossCastBarBorderEnabled == true)
                end,
            },
            bossCastBarBorderColor = {
                type     = "color",
                name     = "Color",
                order    = 43,
                hasAlpha = true,
                get = function()
                    local c = self.ufDB.profile.bossCastBarBorderColor or { r=0, g=0, b=0, a=1 }
                    return c.r, c.g, c.b, c.a or 1
                end,
                set = function(_, r, g, b, a)
                    if InCombatLockdown() then return end
                    self.ufDB.profile.bossCastBarBorderColor = { r=r, g=g, b=b, a=a }
                    applyBossCastbars()
                end,
                disabled = InCombatLockdown,
                hidden   = function()
                    return not bossCbShown()
                        or not (self.ufDB.profile.bossCastBarBorderEnabled == true)
                end,
            },
            hdrIcon = {
                type = "header", name = "Spell Icon", order = 50,
                hidden = function() return not bossCbShown() end,
            },
            bossCastBarShowIcon = {
                type  = "toggle",
                name  = "Show Spell Icon",
                order = 51,
                get   = function() return self.ufDB.profile.bossCastBarShowIcon ~= false end,
                set   = function(_, v)
                    if InCombatLockdown() then return end
                    self.ufDB.profile.bossCastBarShowIcon = v
                    applyBossCastbars()
                end,
                disabled = InCombatLockdown,
                hidden   = function() return not bossCbShown() end,
            },
            bossCastBarIconSide = {
                type   = "select",
                name   = "Icon Side",
                order  = 52,
                values = { left = "Left", right = "Right" },
                get    = function() return self.ufDB.profile.bossCastBarIconSide or "left" end,
                set    = function(_, v)
                    if InCombatLockdown() then return end
                    self.ufDB.profile.bossCastBarIconSide = v
                    relayoutBoss()
                end,
                disabled = InCombatLockdown,
                hidden   = function() return not bossCbShown() or not (self.ufDB.profile.bossCastBarShowIcon ~= false) end,
            },
            bossCastBarIconSize = {
                type  = "range",
                name  = "Icon Size",
                order = 53,
                min=10, max=48, step=1,
                get   = function() return self.ufDB.profile.bossCastBarIconSize or 16 end,
                set   = function(_, v)
                    if InCombatLockdown() then return end
                    self.ufDB.profile.bossCastBarIconSize = v
                    relayoutBoss()
                end,
                disabled = InCombatLockdown,
                hidden   = function() return not bossCbShown() or not (self.ufDB.profile.bossCastBarShowIcon ~= false) end,
            },
            bossCastBarIconGap = {
                type  = "range",
                name  = "Gap",
                desc  = "Distance in pixels between the cast bar and the spell icon.",
                order = 54,
                min=0, max=20, step=1,
                get   = function() return self.ufDB.profile.bossCastBarIconGap or 2 end,
                set   = function(_, v)
                    if InCombatLockdown() then return end
                    self.ufDB.profile.bossCastBarIconGap = v
                    relayoutBoss()
                end,
                disabled = InCombatLockdown,
                hidden   = function() return not bossCbShown() or not (self.ufDB.profile.bossCastBarShowIcon ~= false) end,
            },
        },
    }
    _bossBase.args.castBarTab.hidden = bossFrameDisabled

    local bluzzBossOpts = _bossBase

    -- ============================================================
    -- TAB ASSEMBLY
    -- ============================================================

    local ptfArgs = {
        ptfEnabled = {
            type     = "toggle",
            name     = "Enable Unit Frames",
            desc     = "Master switch for all Player & Target frame functionality. Requires a UI reload to take effect.",
            order    = -10,
            width    = "full",
            get      = get,
            set      = set,  -- replaced below
            disabled = InCombatLockdown,
        },
        hideBlizzardGroup = {
            type   = "group",
            name   = "Hide Blizzard Frames",
            order  = -9,
            inline = true,
            args   = {
                hideBlizzardPlayerFrame = {
                    type  = "toggle",
                    name  = "Player",
                    desc  = "Hides Blizzard's player unit frame (health bar, power bar, portrait).",
                    order = 1,
                    get   = get,
                    set   = function(info, val)
                        if InCombatLockdown() then return end
                        self.ufDB.profile[info[#info]] = val
                        promptReload()
                    end,
                    disabled = InCombatLockdown,
                },
                hideBlizzardTargetFrame = {
                    type  = "toggle",
                    name  = "Target",
                    desc  = "Hides Blizzard's target unit frame.",
                    order = 2,
                    get   = get,
                    set   = function(info, val)
                        if InCombatLockdown() then return end
                        self.ufDB.profile[info[#info]] = val
                        promptReload()
                    end,
                    disabled = InCombatLockdown,
                },
                hideBlizzardFocusFrame = {
                    type  = "toggle",
                    name  = "Focus",
                    desc  = "Hides Blizzard's focus unit frame.",
                    order = 3,
                    get   = get,
                    set   = function(info, val)
                        if InCombatLockdown() then return end
                        self.ufDB.profile[info[#info]] = val
                        promptReload()
                    end,
                    disabled = InCombatLockdown,
                },
                hideBlizzardPetFrame = {
                    type  = "toggle",
                    name  = "Pet",
                    desc  = "Hides Blizzard's pet unit frame.",
                    order = 4,
                    get   = get,
                    set   = function(info, val)
                        if InCombatLockdown() then return end
                        self.ufDB.profile[info[#info]] = val
                        promptReload()
                    end,
                    disabled = InCombatLockdown,
                },
                hideBlizzardTargetOfTargetFrame = {
                    type  = "toggle",
                    name  = "Target of Target",
                    desc  = "Hides Blizzard's target of target unit frame.",
                    order = 5,
                    get   = get,
                    set   = function(info, val)
                        if InCombatLockdown() then return end
                        self.ufDB.profile[info[#info]] = val
                        promptReload()
                    end,
                    disabled = InCombatLockdown,
                },
                hideBlizzardBossFrames = {
                    type  = "toggle",
                    name  = "Boss Frames",
                    desc  = "Hides Blizzard's boss unit frames.",
                    order = 6,
                    get   = get,
                    set   = function(info, val)
                        if InCombatLockdown() then return end
                        self.ufDB.profile[info[#info]] = val
                        promptReload()
                    end,
                    disabled = InCombatLockdown,
                },
            },
        },
        -- Note: there is no Blizzard focus-target frame to hide, so no
        -- hideBlizzardFocusTargetFrame checkbox is needed.
        globalTab = globalOpts,
    }

    local function syncPTFTabs()
        local enabled = self.ufDB.profile.ptfEnabled
        if not enabled then
            ptfArgs.playerTab         = nil
            ptfArgs.targetTab         = nil
            ptfArgs.petTab            = nil
            ptfArgs.focusTab          = nil
            ptfArgs.totTab            = nil
            ptfArgs.focusTargetTab    = nil
            ptfArgs.bossTab           = nil
            ptfArgs.ufLayoutsTab      = nil
        else
            ptfArgs.playerTab         = bluzzPlayerOpts
            ptfArgs.targetTab         = bluzzTargetOpts
            ptfArgs.petTab            = petOpts
            ptfArgs.focusTab          = bluzzFocusOpts
            ptfArgs.totTab            = bluzzTotOpts
            ptfArgs.focusTargetTab    = bluzzFocusTargetOpts
            ptfArgs.bossTab           = bluzzBossOpts
            ptfArgs.ufLayoutsTab      = self:BuildUFLayoutsOptions({ self = self, NotifyChangeSafe = function() local ACR = LibStub("AceConfigRegistry-3.0", true); if ACR then ACR:NotifyChange("BuzzardFrames") end end })
        end
        local ACR = LibStub("AceConfigRegistry-3.0", true)
        if ACR then ACR:NotifyChange("BuzzardFrames") end
    end

    ptfArgs.ptfEnabled.set = function(info, val)
        if InCombatLockdown() then return end
        self.ufDB.profile.ptfEnabled = val
        -- When enabling unit frames for the first time, auto-tick all
        -- "Hide Blizzard" checkboxes so the built-in frames are hidden.
        -- The user can individually untick them afterwards if needed.
        if val then
            self.ufDB.profile.hideBlizzardPlayerFrame = true
            self.ufDB.profile.hideBlizzardTargetFrame = true
            self.ufDB.profile.hideBlizzardFocusFrame  = true
            self.ufDB.profile.hideBlizzardPetFrame    = true
            -- hideBlizzardTargetOfTargetFrame is NOT auto-ticked because
            -- the Target of Target frame is disabled by default.
            self.ufDB.profile.showBossFrames              = true
            self.ufDB.profile.hideBlizzardBossFrames      = true
        else
            -- Mirror of the enable branch: when disabling unit frames,
            -- auto-untick every "Hide Blizzard" checkbox so Blizzard's
            -- default frames come back after the required UI reload.
            -- hideBlizzardTargetOfTargetFrame IS cleared here (unlike
            -- the enable branch) so any user-set value is fully reset.
            self.ufDB.profile.hideBlizzardPlayerFrame         = false
            self.ufDB.profile.hideBlizzardTargetFrame         = false
            self.ufDB.profile.hideBlizzardFocusFrame          = false
            self.ufDB.profile.hideBlizzardPetFrame            = false
            self.ufDB.profile.hideBlizzardTargetOfTargetFrame = false
            self.ufDB.profile.showBossFrames                  = false
            self.ufDB.profile.hideBlizzardBossFrames          = false
        end
        syncPTFTabs()
        promptReload()
    end

    syncPTFTabs()

    return {
        type        = "group",
        name        = "Player & Target",
        order       = 12,
        childGroups = "tab",
        disabled    = InCombatLockdown,
        args        = ptfArgs,
    }
end
