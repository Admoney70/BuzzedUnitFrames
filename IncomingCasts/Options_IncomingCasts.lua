-- ============================================================
-- BuzzardFrames: Options_IncomingCasts.lua
-- Builds and returns the "Incoming Casts" nav-tab args table.
-- Called from Options.lua: BF:BuildIncomingCastsOptions(deps)
-- ============================================================
local BF = _G["BuzzardFrames"]

function BF:BuildIncomingCastsOptions(deps)
    local self             = deps.self
    local NotifyChangeSafe = deps.NotifyChangeSafe
    local get              = deps.get
    local set              = deps.set

    -- Helper: get/set for the incomingCasts namespace profile
    local function icGet(info)
        local ic = BF.icDB and BF.icDB.profile
        return ic and ic[info[#info]]
    end
    local function icSet(info, val)
        if not BF.icDB then return end
        BF.icDB.profile[info[#info]] = val
    end

    local function setAndRefresh(info, val)
        if InCombatLockdown() then return end
        icSet(info, val)
        if BF.IncomingCasts then
            BF.IncomingCasts:OnSettingChanged()
            BF.IncomingCasts:Refresh()
            if BF.IncomingCasts._playerAnchor and BF.IncomingCasts._playerAnchor._handle
               and BF.IncomingCasts._playerAnchor._handle:IsShown() then
                BF.IncomingCasts:ShowPlayerMover()
            end
            if BF.IncomingCasts._partyPreviewShown then
                BF.IncomingCasts:ShowPartyPreview()
            end
        end
    end

    local function setAndReposition(info, val)
        if InCombatLockdown() then return end
        icSet(info, val)
        if BF.IncomingCasts then
            BF.IncomingCasts:Refresh()
            if BF.IncomingCasts._playerAnchor and BF.IncomingCasts._playerAnchor._handle
               and BF.IncomingCasts._playerAnchor._handle:IsShown() then
                BF.IncomingCasts:ShowPlayerMover()
            end
            if BF.IncomingCasts._partyPreviewShown then
                BF.IncomingCasts:ShowPartyPreview()
            end
        end
    end

    local function isDisabled()
        local ic = BF.icDB and BF.icDB.profile
        return not (ic and ic.incomingCastsEnabled)
    end

    -- ── Shared display settings (used in both subtabs) ──────────────────
    local function makeDisplayArgs(order)
        return {
            incomingCastsDisplayType = {
                type = "select", name = "Display Type", order = order,
                desc = "How to display incoming casts.\n\n|cffffffffCast Bar|r: A progress bar showing the cast name and icon.\n\n|cffffffffIcon|r: A spell icon with a cooldown sweep.",
                values = { castbar = "Cast Bar", icon = "Icon" },
                get = icGet, set = setAndRefresh,
                disabled = InCombatLockdown,
            },
            incomingCastsShowTimer = {
                type = "toggle", name = "Show Timer Text", order = order + 1,
                desc = "Show remaining cast time on the cast bar or icon.",
                get = icGet, set = setAndRefresh,
                disabled = InCombatLockdown,
            },
            castBarGroup = {
                type = "group", name = "Cast Bar Settings", inline = true, order = order + 10,
                hidden = function()
                    local ic = BF.icDB and BF.icDB.profile
                    return not ic or ic.incomingCastsDisplayType ~= "castbar"
                end,
                args = {
                    incomingCastsBarWidth = {
                        type = "range", name = "Bar Width", order = 1,
                        min = 30, max = 200, step = 1,
                        get = icGet, set = setAndReposition, disabled = InCombatLockdown,
                    },
                    incomingCastsBarHeight = {
                        type = "range", name = "Bar Height", order = 2,
                        min = 6, max = 40, step = 1,
                        get = icGet, set = setAndReposition, disabled = InCombatLockdown,
                    },
                },
            },
            iconGroup = {
                type = "group", name = "Icon Settings", inline = true, order = order + 11,
                hidden = function()
                    local ic = BF.icDB and BF.icDB.profile
                    return not ic or ic.incomingCastsDisplayType ~= "icon"
                end,
                args = {
                    incomingCastsIconSize = {
                        type = "range", name = "Icon Size", order = 1,
                        min = 10, max = 50, step = 1,
                        get = icGet, set = setAndReposition, disabled = InCombatLockdown,
                    },
                },
            },
            timerTextGroup = {
                type = "group", name = "Timer Text", inline = true, order = order + 12,
                hidden = function()
                    local ic = BF.icDB and BF.icDB.profile
                    if not ic then return true end
                    if ic.incomingCastsDisplayType ~= "icon" then return true end
                    if not ic.incomingCastsShowTimer then return true end
                    return false
                end,
                args = {
                    incomingCastsIconAutoScale = {
                        type = "toggle", name = "Auto Scale Timer Text", order = 1,
                        desc = "When enabled, timer text size scales proportionally with the icon size. Use the scale slider to fine-tune. When disabled, a fixed font size is used instead.",
                        get = icGet, set = setAndReposition, disabled = InCombatLockdown,
                    },
                    incomingCastsIconTimerScale = {
                        type = "range", name = "Timer Text Scale", order = 2,
                        desc = "Scale of the timer text displayed on the icon.",
                        min = 0.1, max = 3.0, step = 0.1,
                        hidden = function()
                            local ic = BF.icDB and BF.icDB.profile
                            return not ic or not ic.incomingCastsIconAutoScale
                        end,
                        get = icGet, set = setAndReposition, disabled = InCombatLockdown,
                    },
                    incomingCastsIconTimerFontSize = {
                        type = "range", name = "Timer Font Size", order = 3,
                        desc = "Font size of the timer text displayed on the icon.",
                        min = 6, max = 24, step = 1,
                        hidden = function()
                            local ic = BF.icDB and BF.icDB.profile
                            return not ic or ic.incomingCastsIconAutoScale
                        end,
                        get = icGet, set = setAndReposition, disabled = InCombatLockdown,
                    },
                    incomingCastsIconTimerFont = {
                        type = "select", name = "Timer Font", order = 4,
                        desc = "Font of the timer text displayed on the icon.",
                        values = function()
                            local LSM = LibStub("LibSharedMedia-3.0", true)
                            local vals = { DEFAULT = "Game Default" }
                            if LSM then for n, p in pairs(LSM:HashTable("font")) do vals[p] = n end end
                            return vals
                        end,
                        get = function() return (BF.icDB and BF.icDB.profile and BF.icDB.profile.incomingCastsIconTimerFont) or "DEFAULT" end,
                        set = setAndReposition, disabled = InCombatLockdown,
                    },
                    incomingCastsIconTimerFontBorder = {
                        type = "select", name = "Timer Font Border", order = 5,
                        desc = "Border style of the timer text displayed on the icon.",
                        values = {
                            [""] = "None", ["OUTLINE"] = "Outline", ["THICKOUTLINE"] = "Thick Outline",
                            ["MONOCHROME"] = "Monochrome", ["OUTLINE, MONOCHROME"] = "Outline + Monochrome",
                            ["THICKOUTLINE, MONOCHROME"] = "Thick Outline + Monochrome",
                        },
                        get = icGet, set = setAndReposition, disabled = InCombatLockdown,
                    },
                },
            },
        }
    end

    -- ── Sub-tab 1: Incoming Casts Frame ─────────────────────────────────
    local icFrameTab = {
        type = "group", name = "Incoming Casts Frame", order = 1,
        hidden = isDisabled,
        args = (function()
            local posArgs = {}
            posArgs._posTracker = {
                type = "description", name = function()
                    if posArgs.incomingCastsPlayerAnchorX then BF:ClampPositionSlider({ option = posArgs.incomingCastsPlayerAnchorX }, "x") end
                    if posArgs.incomingCastsPlayerAnchorY then BF:ClampPositionSlider({ option = posArgs.incomingCastsPlayerAnchorY }, "y") end
                    return ""
                end,
                order = 0, width = "full",
            }
            posArgs.desc = {
                type = "description", order = 1, width = "full",
                name = "A detached frame that shows incoming enemy casts targeting you. Unlock frames to drag it into position, or use the X/Y sliders below.",
            }
            posArgs.incomingCastsShowOnPlayerFrame = {
                type = "toggle", name = "Enable Incoming Casts Frame", order = 2,
                desc = "Display incoming casts on a detached frame.",
                width = "full",
                get = icGet,
                set = function(info, val)
                    if InCombatLockdown() then return end
                    icSet(info, val)
                    if BF.IncomingCasts then BF.IncomingCasts:Refresh() end
                end,
                disabled = InCombatLockdown,
            }
            -- Position sliders
            posArgs.positionHeader = { type = "header", name = "Position", order = 10,
                hidden = function()
                    local ic = BF.icDB and BF.icDB.profile
                    return not ic or not ic.incomingCastsShowOnPlayerFrame
                end,
            }
            posArgs.incomingCastsPlayerAnchorX = {
                type = "range", name = "X Position", order = 11,
                desc = "Horizontal position of the incoming cast display.",
                softMin = -1024, softMax = 1024, step = 1,
                get = function(info)
                    BF:ClampPositionSlider(info, "x")
                    local ic = BF.icDB and BF.icDB.profile
                    return ic and ic.incomingCastsPlayerAnchorX or 0
                end,
                set = function(info, val)
                    if InCombatLockdown() then return end
                    icSet(info, val)
                    if BF.IncomingCasts then
                        BF.IncomingCasts:UpdatePlayerAnchorPosition()
                        BF.IncomingCasts:Refresh()
                    end
                    -- Mirror the SetUFAnchor pattern: when Setup Mode is on,
                    -- refresh UF test frames so the icPlayerFrame test overlay
                    -- tracks the slider edit.
                    if BF.db and BF.db.global and BF.db.global.setupModeActive
                       and BF.ShowUFTestFrames then
                        BF:ShowUFTestFrames()
                    end
                end,
                hidden = function()
                    local ic = BF.icDB and BF.icDB.profile
                    return not ic or not ic.incomingCastsShowOnPlayerFrame
                end,
                disabled = InCombatLockdown,
            }
            posArgs.incomingCastsPlayerAnchorY = {
                type = "range", name = "Y Position", order = 12,
                desc = "Vertical position of the incoming cast display.",
                softMin = -1024, softMax = 1024, step = 1,
                get = function(info)
                    BF:ClampPositionSlider(info, "y")
                    local ic = BF.icDB and BF.icDB.profile
                    return ic and ic.incomingCastsPlayerAnchorY or -200
                end,
                set = function(info, val)
                    if InCombatLockdown() then return end
                    icSet(info, val)
                    if BF.IncomingCasts then
                        BF.IncomingCasts:UpdatePlayerAnchorPosition()
                        BF.IncomingCasts:Refresh()
                    end
                    if BF.db and BF.db.global and BF.db.global.setupModeActive
                       and BF.ShowUFTestFrames then
                        BF:ShowUFTestFrames()
                    end
                end,
                hidden = function()
                    local ic = BF.icDB and BF.icDB.profile
                    return not ic or not ic.incomingCastsShowOnPlayerFrame
                end,
                disabled = InCombatLockdown,
            }
            posArgs.incomingCastsPlayerGrowDirection = {
                type = "select", name = "Grow Direction", order = 13,
                desc = "Direction in which multiple incoming casts stack.",
                values = { DOWN = "Down", UP = "Up", LEFT = "Left", RIGHT = "Right" },
                get = icGet, set = setAndReposition,
                hidden = function()
                    local ic = BF.icDB and BF.icDB.profile
                    return not ic or not ic.incomingCastsShowOnPlayerFrame
                end,
                disabled = InCombatLockdown,
            }
            posArgs.incomingCastsPlayerSpacing = {
                type = "range", name = "Spacing", order = 14,
                desc = "Space between multiple incoming cast frames in pixels.",
                min = 0, max = 20, step = 1,
                get = icGet, set = setAndReposition,
                hidden = function()
                    local ic = BF.icDB and BF.icDB.profile
                    return not ic or not ic.incomingCastsShowOnPlayerFrame
                end,
                disabled = InCombatLockdown,
            }
            -- Display settings
            posArgs.displayHeader = { type = "header", name = "Display", order = 20,
                hidden = function()
                    local ic = BF.icDB and BF.icDB.profile
                    return not ic or not ic.incomingCastsShowOnPlayerFrame
                end,
            }
            local display = makeDisplayArgs(21)
            for k, v in pairs(display) do
                local origHidden = v.hidden
                v.hidden = function()
                    local ic = BF.icDB and BF.icDB.profile
                    if not ic or not ic.incomingCastsShowOnPlayerFrame then return true end
                    return origHidden and origHidden()
                end
                posArgs[k] = v
            end
            return posArgs
        end)(),
    }

    -- ── Sub-tab 2: Player Party Frame Anchor ────────────────────────────
    local partyTab = {
        type = "group", name = "Party Player Frame", order = 2,
        hidden = isDisabled,
        args = {
            desc = {
                type = "description", order = 1, width = "full",
                name = "Show incoming enemy casts anchored to your frame within the party frames.",
            },
            incomingCastsShowOnPartyFrame = {
                type = "toggle", name = "Show on Player Party Frame", order = 2,
                desc = "Display incoming casts on your frame within the party frames.",
                width = "full",
                get = icGet,
                set = function(info, val)
                    if InCombatLockdown() then return end
                    icSet(info, val)
                    if BF.IncomingCasts then BF.IncomingCasts:Refresh() end
                end,
                disabled = InCombatLockdown,
            },
            -- Position settings
            positionHeader = { type = "header", name = "Position", order = 10,
                hidden = function()
                    local ic = BF.icDB and BF.icDB.profile
                    return not ic or not ic.incomingCastsShowOnPartyFrame
                end,
            },
            incomingCastsAnchorPoint = {
                type = "select", name = "Anchor Position", order = 12,
                desc = "Where to anchor the incoming cast display relative to the party frame.",
                values = {
                    AUTO        = "Auto (based on party orientation)",
                    TOP         = "Top",
                    BOTTOM      = "Bottom",
                    LEFT        = "Left",
                    RIGHT       = "Right",
                    TOPLEFT     = "Top Left",
                    TOPRIGHT    = "Top Right",
                    BOTTOMLEFT  = "Bottom Left",
                    BOTTOMRIGHT = "Bottom Right",
                },
                get = icGet, set = setAndReposition,
                hidden = function()
                    local ic = BF.icDB and BF.icDB.profile
                    return not ic or not ic.incomingCastsShowOnPartyFrame
                end,
                disabled = InCombatLockdown,
            },
            incomingCastsGrowDirection = {
                type = "select", name = "Grow Direction", order = 13,
                desc = "Direction in which multiple incoming casts stack.",
                values = {
                    AUTO  = "Auto (based on party orientation)",
                    DOWN  = "Down",
                    UP    = "Up",
                    LEFT  = "Left",
                    RIGHT = "Right",
                },
                get = icGet, set = setAndReposition,
                hidden = function()
                    local ic = BF.icDB and BF.icDB.profile
                    return not ic or not ic.incomingCastsShowOnPartyFrame
                end,
                disabled = InCombatLockdown,
            },
            incomingCastsSpacing = {
                type = "range", name = "Spacing", order = 14,
                desc = "Space between multiple incoming cast frames in pixels.",
                min = 0, max = 20, step = 1,
                get = icGet, set = setAndReposition,
                hidden = function()
                    local ic = BF.icDB and BF.icDB.profile
                    return not ic or not ic.incomingCastsShowOnPartyFrame
                end,
                disabled = InCombatLockdown,
            },
            incomingCastsOffsetX = {
                type = "range", name = "X Offset", order = 15,
                desc = "Horizontal offset from the anchor point.",
                min = -50, max = 50, step = 1,
                get = icGet, set = setAndReposition,
                hidden = function()
                    local ic = BF.icDB and BF.icDB.profile
                    return not ic or not ic.incomingCastsShowOnPartyFrame
                end,
                disabled = InCombatLockdown,
            },
            incomingCastsOffsetY = {
                type = "range", name = "Y Offset", order = 16,
                desc = "Vertical offset from the anchor point.",
                min = -50, max = 50, step = 1,
                get = icGet, set = setAndReposition,
                hidden = function()
                    local ic = BF.icDB and BF.icDB.profile
                    return not ic or not ic.incomingCastsShowOnPartyFrame
                end,
                disabled = InCombatLockdown,
            },
            -- Display settings
            displayHeader = { type = "header", name = "Display", order = 20,
                hidden = function()
                    local ic = BF.icDB and BF.icDB.profile
                    return not ic or not ic.incomingCastsShowOnPartyFrame
                end,
            },
        },
    }
    -- Add shared display settings to party tab
    local partyDisplay = makeDisplayArgs(21)
    for k, v in pairs(partyDisplay) do
        local origHidden = v.hidden
        v.hidden = function()
            local ic = BF.icDB and BF.icDB.profile
            if not ic or not ic.incomingCastsShowOnPartyFrame then return true end
            return origHidden and origHidden()
        end
        partyTab.args[k] = v
    end
    -- Preview section at the bottom
    partyTab.args.previewHeader = { type = "header", name = "Preview", order = 40,
        hidden = function()
            local ic = BF.icDB and BF.icDB.profile
            return not ic or not ic.incomingCastsShowOnPartyFrame
        end,
    }
    partyTab.args.testPosition = {
        type = "toggle", name = "Test Position", order = 41,
        desc = "Show preview cast bars on the party preview frame.",
        get = function() return BF.IncomingCasts and BF.IncomingCasts._partyPreviewShown or false end,
        set = function(_, val)
            if not BF.IncomingCasts then return end
            if val then
                BF.IncomingCasts:ShowPartyPreview()
            else
                BF.IncomingCasts:HidePartyPreview()
            end
        end,
        hidden = function()
            local ic = BF.icDB and BF.icDB.profile
            return not ic or not ic.incomingCastsShowOnPartyFrame
        end,
    }

    -- ── Root table ──────────────────────────────────────────────────────
    return {
        type = "group", name = "Incoming Casts",
        args = {
            desc = {
                type = "description", order = 1, width = "full",
                name = "Show incoming enemy casts targeting you. Tracks nameplate enemies and displays cast bars or icons.",
            },
            incomingCastsEnabled = {
                type = "toggle", name = "Enable Incoming Casts", order = 2,
                desc = "Track and display enemy casts targeting you.",
                width = "full",
                get = icGet,
                set = function(info, val)
                    if InCombatLockdown() then return end
                    icSet(info, val)
                    if BF.IncomingCasts then
                        BF.IncomingCasts:OnSettingChanged()
                    end
                end,
                disabled = InCombatLockdown,
            },
            icFrameTab = icFrameTab,
            partyTab   = partyTab,
        },
    }
end
