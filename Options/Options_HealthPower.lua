-- ============================================================
-- BuzzardFrames: Options_HealthPower.lua
-- Builds and returns the "Health & Power" nav-tab args table.
-- Called from Options.lua: BF:BuildHealthPowerOptions(deps)
--
-- Storage: rpDB.profile.healthPower.* (global pseudo-layout) or
-- flat.healthPower.* when layouts.perLayoutToggles.healthPower is true.
-- ALL widgets read/write through the getIP() helper which routes via
--   BF:GetSectionProfile("healthPower", GetModifyingProfile())
-- so per-layout ON/OFF is transparent to the widget definitions.
--
-- v28 (2026-04-18): Per-layout rollout. Routes every widget through
-- GetSectionProfile("healthPower", ...) (previously many widgets used
-- direct BF.rpDB.profile.healthPower access in their hidden=/disabled=
-- predicates and custom setters). Adds _perLayoutToggle via injectSubTab
-- and the section Copy Settings dropdown.
--
-- HISTORY: Power Bar Colors (useCustomPowerColors, customPowerColors,
-- reset button) used to be a carve-out inside the "Power" tab here,
-- bypassing getIP()/writeIP() because BF.PowerTypeColors is shared with
-- the oUF unit frames and isn't meaningfully per-layout. In v31 they
-- were moved out to the top-level "Colors" nav entry (Options_Colors.lua)
-- so the per-layout plumbing in this file can remain uniform -- every
-- remaining widget here routes cleanly through getIP()/writeIP().
-- ApplyCustomPowerColors in Core_ProfileAPI.lua continues reading from
-- rpDB.profile.healthPower (the global), unchanged.
--
-- Cross-section keys (offlineBackgroundColor, fadeOfflineFrames,
-- deadBackgroundColor, deadBackgroundOpacity, deadColorOORFactor) are
-- owned by the TEXT section -- they route via GetSectionProfile("text",...)
-- and were already correctly routed pre-v28 (see MigrateTextLocation in
-- Core_Migrations.lua).
-- ============================================================
local BF = _G["BuzzardFrames"]

-- deps is a table of upvalue references passed in from RegisterOptions:
--   deps.self                      - the BF addon object
--   deps.NotifyChangeSafe          - local function from RegisterOptions
--   deps.get                       - makeRpGet("healthPower") (routed via GetSectionProfile)
--   deps.set                       - makeRpSet("healthPower") (routed via GetSectionProfile)
--   deps.buildSectionCopyToDropdown- factory for the per-layout Copy Settings dropdown
function BF:BuildHealthPowerOptions(deps)
    local self             = deps.self
    local NotifyChangeSafe = deps.NotifyChangeSafe
    local get              = deps.get
    local set              = deps.set
    local buildSectionCopyToDropdown = deps.buildSectionCopyToDropdown

    -- ── Routing helpers ─────────────────────────────────
    local function getIP()
        return self:GetSectionProfile("healthPower", self:GetModifyingProfile())
    end
    local function getIPKey(info)
        local ip = getIP()
        return ip and ip[info[#info]]
    end
    local function writeIP(info, val)
        local ip = getIP()
        if ip then ip[info[#info]] = val end
    end

    return {
        type        = "group",
        name        = "Health & Power Bars",
        order       = 5,
        childGroups = "tab",
        args        = {
            _sectionTracker = {
                type = "description",
                name = function()
                    if self._currentSection ~= "colors" then
                        self._currentSection = "colors"
                        if not InCombatLockdown() then NotifyChangeSafe() end
                    end
                    return ""
                end,
                order = 0, width = "full",
            },
            healthTab = {
                type = "group", name = "Health Bar", order = 1,
                args = {
                    healthColorGroup = {
                        type="group", name="Health Bar Color", inline=true, order=1,
                        args = {
                            healthColorMode = {
                                type="select", name="Color Mode", order=1, width=1.5,
                                values = {
                                    class    = "Use Class Colors",
                                    gradient = "Use Color Gradient (Health Percent)",
                                    static   = "Use Static Color",
                                },
                                sorting = { "class", "gradient", "static" },
                                get = function()
                                    local ip = getIP()
                                    if not ip or not ip.useCustomHealthColor then return "class" end
                                    if ip.useHealthGradient then return "gradient" end
                                    return "static"
                                end,
                                set = function(_, v)
                                    if InCombatLockdown() then return end
                                    local ip = getIP()
                                    if not ip then return end
                                    if v == "class" then
                                        ip.useCustomHealthColor = false
                                        ip.useHealthGradient = false
                                    elseif v == "gradient" then
                                        ip.useCustomHealthColor = true
                                        ip.useHealthGradient = true
                                    else -- "static"
                                        ip.useCustomHealthColor = true
                                        ip.useHealthGradient = false
                                    end
                                    if BF.RebuildHealthGradientCurves then BF:RebuildHealthGradientCurves() end
                                    if BF.RebindHealthBarColor then BF:RebindHealthBarColor() end
                                    self:RefreshColors()
                                    if BF.RefreshPreviewHealthBar then BF:RefreshPreviewHealthBar() end
                                end,
                                disabled=InCombatLockdown,
                            },
                            healthColor = {
                                type="color", name="Health Color", order=2, hasAlpha=false,
                                hidden=function()
                                    local ip = getIP()
                                    return not ip or not ip.useCustomHealthColor or (ip.useHealthGradient == true)
                                end,
                                disabled=InCombatLockdown,
                                get=function()
                                    local ip = getIP()
                                    local c = (ip and ip.healthColor) or { r=0.24, g=0.78, b=0.24 }
                                    return c.r, c.g, c.b
                                end,
                                set=function(_, r, g, b)
                                    if InCombatLockdown() then return end
                                    local ip = getIP()
                                    if ip then ip.healthColor = { r=r, g=g, b=b } end
                                    self:RefreshColors()
                                    if BF.RefreshPreviewHealthBar then BF:RefreshPreviewHealthBar() end
                                end,
                            },
                            healthBarOpacity = {
                                type="range", name="Health Bar Opacity", order=10,
                                desc="Opacity of the health bar fill. Truly independent of the background — the background is only drawn in the missing-health region and never bleeds through the fill.",
                                min=0, max=1, step=0.05, isPercent=true,
                                disabled=InCombatLockdown,
                                get=function() local ip = getIP(); return (ip and ip.healthBarOpacity) or 1 end,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    writeIP(info, val)
                                    self:RefreshColors()
                                    if BF.RefreshPreviewHealthBar then BF:RefreshPreviewHealthBar() end
                                end,
                            },
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
                    healthBarTextureGroup = {
                        type="group", name="Health Bar Texture", inline=true, order=1.5,
                        args = {
                            useCustomHealthBarTexture = {
                                type="toggle", name="Use Custom Health Texture", order=1,
                                get=getIPKey,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    writeIP(info, val)
                                    -- Texture change needs Layout (SetStatusBarTexture) + color
                                    -- re-eval (GetClassHealthColor depends on hasCustomTexture).
                                    self:RefreshHealthBarLayout()
                                    if BF.RefreshPreviewHealthBar then BF:RefreshPreviewHealthBar() end
                                end,
                                disabled=InCombatLockdown,
                            },
                            healthBarTexture = {
                                type="select", name="Health Bar Texture", order=2,
                                dialogControl="LSM30_Statusbar",
                                desc="Texture for the health bar fill.",
                                hidden=function() local ip = getIP(); return not (ip and ip.useCustomHealthBarTexture) end,
                                disabled=InCombatLockdown,
                                values=function()
                                    local LSM = LibStub("LibSharedMedia-3.0", true)
                                    local vals = {}
                                    if LSM then
                                        for name in pairs(LSM:HashTable("statusbar")) do
                                            vals[name] = name
                                        end
                                    end
                                    return vals
                                end,
                                get=function() local ip = getIP(); return (ip and ip.healthBarTexture) or "Blizzard Raid Bar" end,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    writeIP(info, val)
                                    self:RefreshHealthBarLayout()
                                    if BF.RefreshPreviewHealthBar then BF:RefreshPreviewHealthBar() end
                                end,
                            },
                        },
                    },
                },
            },
            backgroundTab = {
                type = "group", name = "Background", order = 1.5,
                args = {
                    backgroundGroup = {
                        type="group", name="Background Color", inline=true, order=1,
                        args = {
                            useCustomBackgroundColor = {
                                type="toggle", name="Use Custom Background Color", order=1, width="full",
                                get=getIPKey,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    writeIP(info, val)
                                    self:RefreshHealthBarLayout()
                                    if BF.RefreshPreviewHealthBar then BF:RefreshPreviewHealthBar() end
                                end,
                                disabled=InCombatLockdown,
                            },
                            bgColorMode = {
                                type="select", name="Color Mode", order=2, width=1.5,
                                hidden=function() local ip = getIP(); return not (ip and ip.useCustomBackgroundColor) end,
                                values = {
                                    gradient = "Use Color Gradient (Health Percent)",
                                    static   = "Use Static Color",
                                },
                                sorting = { "gradient", "static" },
                                get = function()
                                    local ip = getIP()
                                    if ip and ip.useBgGradient then return "gradient" end
                                    return "static"
                                end,
                                set = function(_, v)
                                    if InCombatLockdown() then return end
                                    local ip = getIP()
                                    if not ip then return end
                                    ip.useBgGradient = (v == "gradient")
                                    if BF.RebuildHealthGradientCurves then BF:RebuildHealthGradientCurves() end
                                    if BF.RebindHealthBarColor then BF:RebindHealthBarColor() end
                                    self:RefreshHealthBarLayout()
                                    if BF.RefreshPreviewHealthBar then BF:RefreshPreviewHealthBar() end
                                end,
                                disabled=InCombatLockdown,
                            },
                            gradientNote = {
                                type="description", order=8, width="full",
                                name="Background gradient colors can be customized in the global Colors section:",
                                hidden=function()
                                    local ip = getIP()
                                    return not (ip and ip.useCustomBackgroundColor) or not ip.useBgGradient
                                end,
                            },
                            openColorsBtn = {
                                type="execute", name="Colors", order=9,
                                hidden=function()
                                    local ip = getIP()
                                    return not (ip and ip.useCustomBackgroundColor) or not ip.useBgGradient
                                end,
                                func = function()
                                    local ACD = LibStub("AceConfigDialog-3.0")
                                    ACD:SelectGroup("BuzzardFrames", "colors")
                                end,
                            },
                            backgroundColor = {
                                type="color", name="Background Color", order=5, hasAlpha=false,
                                hidden=function()
                                    local ip = getIP()
                                    return not (ip and ip.useCustomBackgroundColor) or (ip and ip.useBgGradient)
                                end,
                                disabled=InCombatLockdown,
                                get=function()
                                    local ip = getIP()
                                    local c = (ip and ip.backgroundColor) or { r=0, g=0, b=0 }
                                    return c.r, c.g, c.b
                                end,
                                set=function(_, r, g, b)
                                    if InCombatLockdown() then return end
                                    local ip = getIP()
                                    if ip then ip.backgroundColor = { r=r, g=g, b=b } end
                                    self:RefreshHealthBarLayout()
                                    if BF.RefreshPreviewHealthBar then BF:RefreshPreviewHealthBar() end
                                end,
                            },
                            backgroundAlpha = {
                                type="range", name="Background Opacity", order=6, min=0, max=1, step=0.05, isPercent=true,
                                hidden=function() local ip = getIP(); return not (ip and ip.useCustomBackgroundColor) end,
                                disabled=InCombatLockdown,
                                get=getIPKey,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    writeIP(info, val)
                                    self:RefreshHealthBarLayout()
                                    if BF.RefreshPreviewHealthBar then BF:RefreshPreviewHealthBar() end
                                end,
                            },
                        },
                    },
                },
            },
            statusTab = {
                type = "group", name = "Status", order = 1.75,
                args = {
                    offlineGroup = {
                        type="group", name="Offline Bar Color", inline=true, order=1,
                        args = {
                            useCustomOfflineColor = {
                                type="toggle", name="Use Custom Offline Color", order=1,
                                desc="Replace the health bar color with a custom color for offline units.",
                                get=getIPKey,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    writeIP(info, val)
                                    for f in pairs(self.activeFrames or {}) do
                                        if self.UpdateOffline then self:UpdateOffline(f) end
                                        self:UpdateRange(f)
                                    end
                                end,
                                disabled=InCombatLockdown,
                            },
                            offlineBackgroundColor = {
                                type="color", name="Offline Bar Color", order=2, hasAlpha=false,
                                desc="Color that replaces the health bar for offline units.",
                                hidden=function() local ip = getIP(); return not (ip and ip.useCustomOfflineColor) end,
                                -- Owned by the text section (see MigrateTextLocation). Route through
                                -- GetSectionProfile("text", …) so the text per-layout toggle governs it.
                                get=function()
                                    local tp = self:GetSectionProfile("text", self:GetModifyingProfile())
                                    local c = (tp and tp.offlineBackgroundColor) or { r=0.1, g=0.1, b=0.1 }
                                    return c.r, c.g, c.b
                                end,
                                set=function(_, r, g, b)
                                    if InCombatLockdown() then return end
                                    local tp = self:GetSectionProfile("text", self:GetModifyingProfile())
                                    if tp then tp.offlineBackgroundColor = { r=r, g=g, b=b } end
                                    for f in pairs(self.activeFrames or {}) do
                                        if self.UpdateOffline then self:UpdateOffline(f) end
                                    end
                                end,
                            },
                            fadeOfflineFrames = {
                                type="toggle", name="Fade Offline Frames", order=3,
                                desc="Apply range fading to offline unit frames (uses the Out-of-Range Opacity setting).",
                                -- Owned by the text section. Pre-v25 this used deps.get (db.profile)
                                -- while the setter wrote to rpDB.profile.text -- classic split-location
                                -- bug. Now both routed via GetSectionProfile.
                                get=function()
                                    local tp = self:GetSectionProfile("text", self:GetModifyingProfile())
                                    return tp and tp.fadeOfflineFrames
                                end,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    local tp = self:GetSectionProfile("text", self:GetModifyingProfile())
                                    if tp then tp.fadeOfflineFrames = val end
                                    for f in pairs(self.activeFrames or {}) do
                                        self:UpdateRange(f)
                                    end
                                end,
                                disabled=InCombatLockdown,
                            },
                        },
                    },
                    deadGroup = {
                        type="group", name="Dead Background Color", inline=true, order=2,
                        args = {
                            useCustomDeadColor = {
                                type="toggle", name="Use Custom Dead Color", order=1,
                                get=getIPKey,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    writeIP(info, val)
                                    -- Dead color is applied by StatusOverlay which is covered
                                    -- by RefreshColors. Clear _healthState to force re-eval.
                                    for f in pairs(self.activeFrames or {}) do f._healthState = nil end
                                    self:RefreshColors()
                                end,
                                disabled=InCombatLockdown,
                            },
                            deadBackgroundColor = {
                                type="color", name="Dead Color", order=2, hasAlpha=false,
                                hidden=function() local ip = getIP(); return not (ip and ip.useCustomDeadColor) end,
                                disabled=InCombatLockdown,
                                -- Owned by the text section. Route via GetSectionProfile so the
                                -- text per-layout toggle governs it.
                                get=function()
                                    local tp = self:GetSectionProfile("text", self:GetModifyingProfile())
                                    local c = (tp and tp.deadBackgroundColor) or { r=0.1, g=0.1, b=0.1 }
                                    return c.r, c.g, c.b
                                end,
                                set=function(_, r, g, b)
                                    if InCombatLockdown() then return end
                                    local tp = self:GetSectionProfile("text", self:GetModifyingProfile())
                                    if tp and tp.deadBackgroundColor then
                                        tp.deadBackgroundColor.r, tp.deadBackgroundColor.g, tp.deadBackgroundColor.b = r, g, b
                                    end
                                    for f in pairs(self.activeFrames or {}) do f._healthState = nil end
                                    self:RefreshColors()
                                end,
                            },
                            deadBackgroundOpacity = {
                                type="range", name="Dead Background Color Opacity", order=3, min=0, max=1, step=0.05,
                                hidden=function() local ip = getIP(); return not (ip and ip.useCustomDeadColor) end,
                                disabled=InCombatLockdown,
                                -- Owned by the text section. Pre-v25 get=get (db.profile) split
                                -- from set writing to rpDB.profile.text -- fixed here.
                                get=function()
                                    local tp = self:GetSectionProfile("text", self:GetModifyingProfile())
                                    return (tp and tp.deadBackgroundOpacity) or 0.7
                                end,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    local tp = self:GetSectionProfile("text", self:GetModifyingProfile())
                                    if tp then tp.deadBackgroundOpacity = val end
                                    for f in pairs(self.activeFrames or {}) do f._healthState = nil end
                                    self:RefreshColors()
                                end,
                            },
                        },
                    },
                    hostileGroup = {
                        type="group", name="Hostile Health Bar Color", inline=true, order=3,
                        args = {
                            useCustomHostileColor = {
                                type="toggle", name="Use Custom Hostile Color", order=1,
                                desc="Use a custom health bar color for hostile (enemy) units.",
                                get=getIPKey,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    writeIP(info, val)
                                    self:RefreshColors()
                                end,
                                disabled=InCombatLockdown,
                            },
                            hostileColor = {
                                type="color", name="Hostile Color", order=2, hasAlpha=false,
                                hidden=function() local ip = getIP(); return not (ip and ip.useCustomHostileColor) end,
                                disabled=InCombatLockdown,
                                get=function()
                                    local ip = getIP()
                                    local c = (ip and ip.hostileColor) or { r=0.9, g=0.1, b=0.1 }
                                    return c.r, c.g, c.b
                                end,
                                set=function(_, r, g, b)
                                    if InCombatLockdown() then return end
                                    local ip = getIP()
                                    if ip then
                                        ip.hostileColor = ip.hostileColor or {}
                                        ip.hostileColor.r, ip.hostileColor.g, ip.hostileColor.b = r, g, b
                                    end
                                    self:RefreshColors()
                                end,
                            },
                        },
                    },
                },
            },
            powerTab = {
                type = "group", name = "Power", order = 2,
                args = {
                    powerBarVisibilityGroup = {
                        type="group", name="Show Power Bars", inline=true, order=16,
                        args = {
                            showAllPowerBars = {
                                type="toggle", name="Show All Power Bars", order=1,
                                desc="When enabled, all units show power bars. When disabled, only the selected roles below will show power bars.",
                                get=getIPKey,
                                set=function(info, value)
                                    if InCombatLockdown() then return end
                                    writeIP(info, value)
                                    for frame in pairs(self.activeFrames or {}) do
                                        self:LayoutFrame(frame)
                                        self:UpdatePower(frame)
                                    end
                                    if BF.RefreshPreviewPowerBar then BF:RefreshPreviewPowerBar() end
                                end,
                                disabled=InCombatLockdown,
                            },
                            showPowerBarHealers = {
                                type="toggle", name="Show Healer Power Bars", order=2,
                                get=getIPKey,
                                set=function(info, value)
                                    if InCombatLockdown() then return end
                                    writeIP(info, value)
                                    for frame in pairs(self.activeFrames or {}) do
                                        self:LayoutFrame(frame)
                                        self:UpdatePower(frame)
                                    end
                                    if BF.RefreshPreviewPowerBar then BF:RefreshPreviewPowerBar() end
                                end,
                                disabled=InCombatLockdown,
                                hidden=function() local ip = getIP(); return ip and ip.showAllPowerBars end,
                            },
                            showPowerBarBloodDK = {
                                type="toggle", name="Show Blood DK Power Bars", order=3,
                                get=getIPKey,
                                set=function(info, value)
                                    if InCombatLockdown() then return end
                                    writeIP(info, value)
                                    for frame in pairs(self.activeFrames or {}) do
                                        self:LayoutFrame(frame)
                                        self:UpdatePower(frame)
                                    end
                                    if BF.RefreshPreviewPowerBar then BF:RefreshPreviewPowerBar() end
                                end,
                                disabled=InCombatLockdown,
                                hidden=function() local ip = getIP(); return ip and ip.showAllPowerBars end,
                            },
                        },
                    },
                    powerBarLayoutGroup = {
                        type="group", name="Power Bar Layout", inline=true, order=17,
                        hidden=function()
                            local ip = getIP()
                            if not ip then return true end
                            return not ip.showAllPowerBars and not ip.showPowerBarHealers and not ip.showPowerBarBloodDK
                        end,
                        args = {
                            powerBarHeight = {
                                type="range", name="Power Bar Height", order=1,
                                min=1, max=30, step=1,
                                disabled=InCombatLockdown,
                                get=getIPKey,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    writeIP(info, val)
                                    for frame in pairs(self.activeFrames or {}) do
                                        self:LayoutFrame(frame)
                                        self:UpdatePower(frame)
                                    end
                                    if BF.RefreshPreviewLayout then BF:RefreshPreviewLayout() end
                                end,
                            },
                            aurasAbovePowerBar = {
                                type="toggle", name="Place Auras Above Power Bar", order=3,
                                desc="When enabled, auras will be anchored to the health bar bottom instead of the frame bottom, placing them above the power bar",
                                get=getIPKey,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    writeIP(info, val)
                                    -- Scoped: only re-Layouts the six indicators that
                                    -- actually read aurasAbovePowerBar, instead of the
                                    -- full RefreshAllAuras sweep.
                                    -- See Docs/REFRESH_SCOPING_PHASE2_PLAN.md.
                                    if self.RefreshAurasAbovePowerBarToggle then
                                        self:RefreshAurasAbovePowerBarToggle()
                                    else
                                        self:RefreshAllAuras()
                                    end
                                    if self.RefreshDummyAuras then self:RefreshDummyAuras() end
                                end,
                                disabled=InCombatLockdown,
                            },
                        },
                    },
                    powerBarBackgroundGroup = {
                        type="group", name="Power Bar Background", inline=true, order=20,
                        hidden=function()
                            local ip = getIP()
                            if not ip then return true end
                            return not ip.showAllPowerBars and not ip.showPowerBarHealers and not ip.showPowerBarBloodDK
                        end,
                        args = {
                            useCustomPowerBarBgColor = {
                                type="toggle", name="Use Custom Background Color", order=1,
                                get=getIPKey,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    writeIP(info, val)
                                    for frame in pairs(self.activeFrames or {}) do self:UpdatePower(frame) end
                                    if BF.RefreshPreviewPowerBar then BF:RefreshPreviewPowerBar() end
                                end,
                                disabled=InCombatLockdown,
                            },
                            powerBarBgColor = {
                                type="color", name="Background Color", order=2, hasAlpha=false,
                                desc="Color of the power bar background.",
                                hidden=function() local ip = getIP(); return not (ip and ip.useCustomPowerBarBgColor) end,
                                disabled=InCombatLockdown,
                                get=function()
                                    local ip = getIP()
                                    local c = (ip and ip.powerBarBgColor) or { r=0.08, g=0.08, b=0.08 }
                                    return c.r, c.g, c.b
                                end,
                                set=function(_, r, g, b)
                                    if InCombatLockdown() then return end
                                    local ip = getIP()
                                    if ip then
                                        local c = ip.powerBarBgColor
                                        ip.powerBarBgColor = { r=r, g=g, b=b, a=(c and c.a) or 1.0 }
                                    end
                                    for frame in pairs(self.activeFrames or {}) do
                                        self:UpdatePower(frame)
                                    end
                                    if BF.RefreshPreviewPowerBar then BF:RefreshPreviewPowerBar() end
                                end,
                            },
                            powerBarBgOpacity = {
                                type="range", name="Background Opacity", order=3,
                                min=0, max=1, step=0.05, isPercent=true,
                                disabled=InCombatLockdown,
                                get=getIPKey,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    writeIP(info, val)
                                    for frame in pairs(self.activeFrames or {}) do self:UpdatePower(frame) end
                                    if BF.RefreshPreviewPowerBar then BF:RefreshPreviewPowerBar() end
                                end,
                            },
                        },
                    },
                    powerBarTextureGroup = {
                        type="group", name="Power Bar Texture", inline=true, order=19,
                        hidden=function()
                            local ip = getIP()
                            if not ip then return true end
                            return not ip.showAllPowerBars and not ip.showPowerBarHealers and not ip.showPowerBarBloodDK
                        end,
                        args = {
                            useCustomPowerBarTexture = {
                                type="toggle", name="Use Custom Power Texture", order=1,
                                get=getIPKey,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    writeIP(info, val)
                                    self:RefreshPowerBarLayout()
                                    if BF.RefreshPreviewPowerBar then BF:RefreshPreviewPowerBar() end
                                end,
                                disabled=InCombatLockdown,
                            },
                            powerBarTexture = {
                                type="select", name="Power Bar Texture", order=2,
                                dialogControl="LSM30_Statusbar",
                                desc="Texture for the power bar fill.",
                                hidden=function() local ip = getIP(); return not (ip and ip.useCustomPowerBarTexture) end,
                                disabled=InCombatLockdown,
                                values=function()
                                    local LSM = LibStub("LibSharedMedia-3.0", true)
                                    local vals = {}
                                    if LSM then
                                        for name in pairs(LSM:HashTable("statusbar")) do
                                            vals[name] = name
                                        end
                                    end
                                    return vals
                                end,
                                get=function() local ip = getIP(); return (ip and ip.powerBarTexture) or "Blizzard Raid Bar" end,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    writeIP(info, val)
                                    self:RefreshPowerBarLayout()
                                    if BF.RefreshPreviewPowerBar then BF:RefreshPreviewPowerBar() end
                                end,
                            },
                        },
                    },
                    -- NOTE: Power Bar Colors (useCustomPowerColors, per-type color
                    -- widgets, Reset to Defaults) used to live here as a powerColorsGroup
                    -- carve-out that bypassed the per-layout plumbing. They were moved
                    -- to the top-level Colors nav entry in Options_Colors.lua because
                    -- those settings are shared with the oUF Unit Frames and apply
                    -- globally across all Layouts -- putting them inside a per-layout
                    -- section (where everything around them IS per-layout) was
                    -- misleading UX. See Options_Colors.lua for the implementation.
                },
            },
            rangeTab = {
                type = "group", name = "Out of Range Frames", order = 3,
                args = {
                    rangeHeader = { type="header", name="Out of Range Fading", order=1 },
                    enableRangeFade = { type="toggle", name="Fade Out-of-Range Frames", order=2,
                        get=getIPKey,
                        set=function(info, val)
                            if InCombatLockdown() then return end
                            writeIP(info, val)
                            for frame in pairs(self.activeFrames or {}) do self:UpdateRange(frame) end
                            if BF.RefreshDummyFrames then BF:RefreshDummyFrames() end
                        end,
                        disabled=InCombatLockdown },
                    rangeFadeAlpha = { type="range", name="Out-of-Range Opacity", order=3, min=0.1, max=0.9, step=0.05, isPercent=true,
                        get=getIPKey,
                        set=function(info, val)
                            if InCombatLockdown() then return end
                            writeIP(info, val)
                            for frame in pairs(self.activeFrames or {}) do self:UpdateRange(frame) end
                            if BF.RefreshDummyFrames then BF:RefreshDummyFrames() end
                        end,
                        hidden=function() local ip = getIP(); return not (ip and ip.enableRangeFade) end,
                        disabled=InCombatLockdown },
                    desatHeader = { type="header", name="Out of Range Darkening", order=3.5 },
                    enableRangeDesaturate = { type="toggle", name="Darken Out-of-Range Frames", order=3.6,
                        get=getIPKey,
                        set=function(info, val)
                            if InCombatLockdown() then return end
                            writeIP(info, val)
                            for frame in pairs(self.activeFrames or {}) do self:UpdateRange(frame) end
                            if BF.RefreshDummyFrames then BF:RefreshDummyFrames() end
                        end,
                        disabled=InCombatLockdown },
                    rangeDesaturation = { type="range", name="Out-of-Range Darkening", order=3.7, min=0, max=0.8, step=0.05, isPercent=true,
                        get=getIPKey,
                        set=function(info, val)
                            if InCombatLockdown() then return end
                            writeIP(info, val)
                            for frame in pairs(self.activeFrames or {}) do self:UpdateRange(frame) end
                            if BF.RefreshDummyFrames then BF:RefreshDummyFrames() end
                        end,
                        hidden=function() local ip = getIP(); return not (ip and ip.enableRangeDesaturate) end,
                        disabled=InCombatLockdown },
                    deadColorOORSpacer = { type="description", name="", order=4 },
                    deadColorOORHeader = { type="header", name="Dead Color \226\128\147 Out of Range", order=5 },
                    deadColorOORDesc = {
                        type="description",
                        name="When a dead unit is out of range, the Dead text color is blended toward grey so it's visually distinct. The slider controls how much of the original color is retained (100% = full color, 0% = fully grey).",
                        order=6, width="full",
                    },
                    deadColorOORFactor = {
                        type="range", name="Color Retention", order=7,
                        desc="How much of the Dead color to keep when the unit is out of range. 100% keeps the full color; 0% goes fully grey.",
                        min=0, max=1, step=0.05, isPercent=true,
                        -- Owned by the text section. Route via GetSectionProfile so the
                        -- text per-layout toggle governs it.
                        get=function()
                            local tp = self:GetSectionProfile("text", self:GetModifyingProfile())
                            return (tp and tp.deadColorOORFactor) or 0.5
                        end,
                        set=function(_, val)
                            if InCombatLockdown() then return end
                            local tp = self:GetSectionProfile("text", self:GetModifyingProfile())
                            if tp then tp.deadColorOORFactor = val end
                            BF:RefreshAllStatusColors()
                        end,
                        disabled=InCombatLockdown,
                    },
                    testHeader = { type="header", name="Test", order=8 },
                    testOOR = {
                        type="toggle", name="Test Out of Range", order=9,
                        desc="Simulate out-of-range on the preview frames to see how fade and darkening settings look.",
                        get=function() return BF._previewOOR == true end,
                        set=function(_, val)
                            BF._previewOOR = val or nil
                            if BF.RefreshPreviewStatus then BF:RefreshPreviewStatus() end
                        end,
                    },
                },
            },
        },
    }
end
