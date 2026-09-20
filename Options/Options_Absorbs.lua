-- ============================================================
-- BuzzardFrames: Options_Absorbs.lua
-- Builds and returns the "Absorbs & Heal Prediction" nav-tab args table.
-- Called from Options.lua: BF:BuildAbsorbsOptions(deps)
--
-- Storage: rpDB.profile.absorbs.* (global pseudo-layout) or flat.absorbs.*
-- when layouts.perLayoutToggles.absorbs is true. ALL widgets read/write
-- through the getIP() helper which routes via
--   BF:GetSectionProfile("absorbs", GetModifyingProfile())
-- so per-layout ON/OFF is transparent to the widget definitions.
--
-- v27 (2026-04-18): Per-layout rollout. Routes every widget through
-- GetSectionProfile("absorbs", ...) (previously many widgets used direct
-- BF.rpDB.profile.absorbs access in their hidden=/disabled= predicates
-- and custom setters). Adds _perLayoutToggle via injectSubTab and the
-- section Copy Settings dropdown.
--
-- Test flags (testAbsorb, testAbsorbSize, testHealPrediction,
-- testHealAbsorb, testReducedMaxHealth) are GLOBAL debug flags on
-- BF.db.global. They do NOT route through getIP() because they are not
-- part of the per-layout absorbs profile. Core_DB.lua resets them to
-- false on every reload.
-- ============================================================
local BF = _G["BuzzardFrames"]

-- deps is a table of upvalue references passed in from RegisterOptions:
--   deps.self                      - the BF addon object
--   deps.NotifyChangeSafe          - local function from RegisterOptions
--   deps.get                       - makeRpGet("absorbs") (routed via GetSectionProfile)
--   deps.set                       - makeRpSet("absorbs") (routed via GetSectionProfile)
--   deps.buildSectionCopyToDropdown- factory for the per-layout Copy Settings dropdown
function BF:BuildAbsorbsOptions(deps)
    local self             = deps.self
    local NotifyChangeSafe = deps.NotifyChangeSafe
    local buildSectionCopyToDropdown = deps.buildSectionCopyToDropdown

    -- ── Routing helpers ─────────────────────────────────
    -- getIP() returns the currently-modifying flat's absorbs profile
    -- (flat.absorbs when per-layout is ON, rpDB.profile.absorbs when OFF).
    -- All reads/writes flow through this one helper.
    local function getIP()
        return self:GetSectionProfile("absorbs", self:GetModifyingProfile())
    end
    local function getIPKey(info)
        local ip = getIP()
        return ip and ip[info[#info]]
    end
    local function writeIP(info, val)
        local ip = getIP()
        if ip then ip[info[#info]] = val end
    end

    -- ── Side-effect helpers ─────────────────────────────
    -- Re-layout on all active frames (positional/geometry changes) and
    -- refresh the options-panel preview so per-layout Absorbs edits
    -- re-run every indicator's :Layout on the preview frames.
    local function layoutFrames()
        for frame in pairs(self.activeFrames or {}) do
            self:LayoutFrame(frame)
        end
        if BF.RefreshPreviewLayout then BF:RefreshPreviewLayout() end
    end

    -- ── Master-gate predicate ───────────────────────────
    -- showAbsorbsMissingHealth is the master for the entire Absorbs tab.
    -- When the master is off, the Absorbs tab shows ONLY the master toggle
    -- itself (plus its section header). Every other widget on the absorbTab
    -- uses absorbsOff() in its hidden= predicate. Reduced Max Health, Heal
    -- Prediction, and Heal Absorbs tabs are independent and NOT gated.
    local function absorbsOff()
        local ip = getIP()
        return ip and ip.showAbsorbsMissingHealth == false
    end

    return {
        type = "group", name = "Absorbs & Heal Prediction", order = 7,
        childGroups = "tab",
        args = {
            _sectionTracker = {
                type = "description",
                name = function()
                    if self._currentSection ~= "absorbs" then
                        self._currentSection = "absorbs"
                        if not InCombatLockdown() then NotifyChangeSafe() end
                    end
                    return ""
                end,
                order = 0, width = "full",
            },
            healPredictionTab = {
                type = "group", name = "Heal Prediction", order = 3,
                args = {
                    healPredictionHeader = { type="header", name="Heal Prediction", order=10 },
                    showHealPrediction = {
                        type="toggle", name="Show Heal Prediction", order=11,
                        desc="Show incoming heal prediction on health bars",
                        get=getIPKey,
                        set=function(info, val)
                            if InCombatLockdown() then return end
                            writeIP(info, val)
                            -- When disabling, clear the matching test flag so a
                            -- previously-enabled test doesn't linger invisibly.
                            if not val and BF.db.global.testHealPrediction then
                                BF.db.global.testHealPrediction = false
                            end
                            self:RefreshAllHealPrediction()
                            if BF.RefreshPreviewHealPrediction then BF:RefreshPreviewHealPrediction() end
                        end,
                        disabled=InCombatLockdown,
                    },
                    healPredictionAnchor = {
                        type="select", name="Heal Prediction Anchor", order=12,
                        desc="Position where heal prediction bar anchors.\n\n|cffffffffLeft|r: Overlays the health bar from the left edge, showing predicted health as a fill. Incoming heals are clamped to max health.\n\n|cffffffffRight (Blizzard Style)|r: Extends from the right edge of the current health fill into the missing health area.",
                        values={ ["LEFT"]="Left", ["RIGHT"]="Right (Blizzard Style)" },
                        get=getIPKey,
                        set=function(info, val)
                            if InCombatLockdown() then return end
                            writeIP(info, val)
                            -- RefreshAllHealPrediction clears each frame's
                            -- _healPredAnchor cache before the per-frame update
                            -- so the bar is re-parented and re-anchored.
                            self:RefreshAllHealPrediction()
                            if BF.RefreshPreviewHealPrediction then BF:RefreshPreviewHealPrediction() end
                        end,
                        disabled=function() local ip = getIP(); return InCombatLockdown() or not (ip and ip.showHealPrediction) end,
                    },
                    healPredictionColor = {
                        type="color", name="Heal Prediction Color", order=13,
                        desc="Color and opacity of the heal prediction bar",
                        hasAlpha=true,
                        hidden=function() local ip = getIP(); return not (ip and ip.showHealPrediction) end,
                        get=function()
                            local ip = getIP()
                            local c = (ip and ip.healPredictionColor) or { r=0, g=0.7, b=0, a=0.6 }
                            return c.r, c.g, c.b, c.a
                        end,
                        set=function(_, r, g, b, a)
                            if InCombatLockdown() then return end
                            local ip = getIP()
                            if ip then ip.healPredictionColor = { r=r, g=g, b=b, a=a } end
                            self:RefreshAllHealPrediction()
                            if BF.RefreshPreviewHealPrediction then BF:RefreshPreviewHealPrediction() end
                        end,
                        disabled=InCombatLockdown,
                    },
                    healPredTextureHeader = { type="header", name="Heal Prediction Texture", order=14,
                        hidden=function() local ip = getIP(); return not (ip and ip.showHealPrediction) end,
                    },
                    useCustomHealPredictionTexture = {
                        type="toggle", name="Use Custom Texture", order=15,
                        hidden=function() local ip = getIP(); return not (ip and ip.showHealPrediction) end,
                        get=getIPKey,
                        set=function(info, val)
                            if InCombatLockdown() then return end
                            writeIP(info, val)
                            self:RefreshAllHealPrediction()
                            if BF.RefreshPreviewHealPrediction then BF:RefreshPreviewHealPrediction() end
                        end,
                        disabled=InCombatLockdown,
                    },
                    healPredictionTexture = {
                        type="select", name="Heal Prediction Texture", order=16,
                        dialogControl="LSM30_Statusbar",
                        desc="Statusbar fill texture for the heal prediction bar.",
                        hidden=function()
                            local ip = getIP()
                            if not ip then return true end
                            return not ip.showHealPrediction or not ip.useCustomHealPredictionTexture
                        end,
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
                        get=function()
                            local ip = getIP()
                            return (ip and ip.healPredictionTexture) or "Solid"
                        end,
                        set=function(info, val)
                            if InCombatLockdown() then return end
                            writeIP(info, val)
                            self:RefreshAllHealPrediction()
                            if BF.RefreshPreviewHealPrediction then BF:RefreshPreviewHealPrediction() end
                        end,
                        disabled=InCombatLockdown,
                    },
                    testHealPredHeader = { type="header", name="Test", order=20,
                        hidden=function() local ip = getIP(); return not (ip and ip.showHealPrediction) end,
                    },
                    testHealPrediction = {
                        type="toggle", name="Test Heal Prediction", order=21,
                        desc="Simulate a 10% incoming heal on preview frames for testing. Disable when done.",
                        -- Global debug flag: read/write BF.db.global directly.
                        get=function() return BF.db.global.testHealPrediction end,
                        set=function(_, val)
                            if InCombatLockdown() then return end
                            BF.db.global.testHealPrediction = val
                            if BF.RefreshPreviewHealPrediction then BF:RefreshPreviewHealPrediction() end
                        end,
                        -- hidden= matches the Icons v26 pattern for test toggles:
                        -- drop from the UI entirely when the parent show toggle is
                        -- off, rather than greying out with disabled=.
                        hidden=function() local ip = getIP(); return not (ip and ip.showHealPrediction) end,
                        disabled=InCombatLockdown,
                    },
                },
            },
            healAbsorbTab = {
                type = "group", name = "Heal Absorbs", order = 2,
                args = {
                    healAbsorbHeader = { type="header", name="Heal Absorb", order=15 },
                    showHealAbsorb = {
                        type="toggle", name="Show Heal Absorb", order=16,
                        desc="Show heal absorption effects on frames",
                        disabled=InCombatLockdown,
                        get=getIPKey,
                        set=function(info, val)
                            if InCombatLockdown() then return end
                            writeIP(info, val)
                            if not val and BF.db.global.testHealAbsorb then
                                BF.db.global.testHealAbsorb = false
                            end
                            self:RefreshAllHealAbsorbs()
                            if BF.RefreshPreviewHealAbsorb then BF:RefreshPreviewHealAbsorb() end
                        end,
                    },
                    healAbsorbStyle = {
                        type="select", name="Heal Absorb Style", order=17,
                        desc="How to display heal absorb effects.\n\n|cffffffffOverlay|r: Base fill and right shadow. Use the Color option to tint the base fill.\n\n|cffffffffOverlay (Blizzard Style)|r: Base fill, plus symbols overlay, and right shadow. Use the Color option to tint the base fill.\n\n|cffffffffBar|r: A thin bar anchored to the top of the health bar, fills left-to-right proportional to heal absorb vs max HP.\n\n|cffffffffBar (Blizzard Style)|r: Same sizing and position as Bar, but uses Blizzard's absorb textures with plus symbols overlay.",
                        values={ ["Overlay"]="Overlay", ["OverlayBlizzard"]="Overlay (Blizzard Style)", ["Bar"]="Bar", ["BarBlizzard"]="Bar (Blizzard Style)" },
                        get=getIPKey,
                        set=function(info, val)
                            if InCombatLockdown() then return end
                            writeIP(info, val)
                            self:RefreshAllHealAbsorbs()
                            if BF.RefreshPreviewHealAbsorb then BF:RefreshPreviewHealAbsorb() end
                        end,
                        disabled=function() local ip = getIP(); return InCombatLockdown() or not (ip and ip.showHealAbsorb) end,
                    },
                    healAbsorbColor = {
                        type="color", name="Color", order=17.5,
                        desc="Color and opacity of the heal absorb effect.\n\n|cffffffffOverlay / Overlay (Blizzard Style)|r: Tints the base fill texture.\n|cffffffffBar|r: Sets the bar color.",
                        hasAlpha=true,
                        get=function()
                            local ip = getIP()
                            local c = (ip and ip.healAbsorbColor) or { r=1, g=0, b=0, a=0.5 }
                            return c.r, c.g, c.b, c.a
                        end,
                        set=function(_, r, g, b, a)
                            if InCombatLockdown() then return end
                            local ip = getIP()
                            if ip then ip.healAbsorbColor = { r=r, g=g, b=b, a=a } end
                            self:RefreshAllHealAbsorbs()
                            if BF.RefreshPreviewHealAbsorb then BF:RefreshPreviewHealAbsorb() end
                        end,
                        disabled=function() local ip = getIP(); return InCombatLockdown() or not (ip and ip.showHealAbsorb) end,
                    },
                    healAbsorbBarHeight = {
                        type="range", name="Bar Height", order=18,
                        desc="Height of the heal absorb bar in pixels",
                        min=1, max=100, step=1,
                        get=getIPKey,
                        set=function(info, val)
                            if InCombatLockdown() then return end
                            writeIP(info, val)
                            self:RefreshAllHealAbsorbs()
                            if BF.RefreshPreviewHealAbsorb then BF:RefreshPreviewHealAbsorb() end
                        end,
                        hidden=function() local ip = getIP(); return not (ip and (ip.healAbsorbStyle == "Bar" or ip.healAbsorbStyle == "BarBlizzard")) end,
                        disabled=function() local ip = getIP(); return InCombatLockdown() or not (ip and ip.showHealAbsorb) end,
                    },
                    testHealAbsorbHeader = { type="header", name="Test", order=18.5,
                        hidden=function() local ip = getIP(); return not (ip and ip.showHealAbsorb) end,
                    },
                    testHealAbsorb = {
                        type="toggle", name="Test Heal Absorb (50%)", order=19,
                        desc="Simulate a 50% heal absorb on preview frames for testing. Disable when done.",
                        get=function() return BF.db.global.testHealAbsorb end,
                        set=function(_, val)
                            if InCombatLockdown() then return end
                            BF.db.global.testHealAbsorb = val
                            if BF.RefreshPreviewHealAbsorb then BF:RefreshPreviewHealAbsorb() end
                        end,
                        hidden=function() local ip = getIP(); return not (ip and ip.showHealAbsorb) end,
                        disabled=InCombatLockdown,
                    },
                },
            },
            absorbTab = {
                type = "group", name = "Absorbs", order = 1,
                args = {
                    absorbMissingHeader = { type="header", name="Absorbs (Missing Health)", order=18 },
                    showAbsorbsMissingHealth = {
                        type="toggle", name="Show Absorbs (Missing Health)", order=19,
                        desc="Show damage absorb shields in the missing health gap",
                        get=function() local ip = getIP(); return ip and ip.showAbsorbsMissingHealth ~= false end,
                        set=function(info, val)
                            if InCombatLockdown() then return end
                            writeIP(info, val)
                            self:RefreshAllAbsorbs()
                            if BF.RefreshPreviewAbsorbOverlay then BF:RefreshPreviewAbsorbOverlay() end
                        end,
                        disabled=InCombatLockdown,
                    },
                    overshieldHeader = { type="header", name="Overshield (Absorbs Over Max Health)", order=20,
                        hidden=absorbsOff,
                    },
                    showOvershield = {
                        type="toggle", name="Show Overshield", order=21,
                        desc="Show absorb shields that exceed max health",
                        hidden=absorbsOff,
                        get=getIPKey,
                        set=function(info, val)
                            if InCombatLockdown() then return end
                            writeIP(info, val)
                            self:RefreshAllAbsorbs()
                            if BF.RefreshPreviewAbsorbOverlay then BF:RefreshPreviewAbsorbOverlay() end
                        end,
                        disabled=InCombatLockdown,
                    },
                    overshieldStyle = {
                        type="select", name="Overshield Style", order=22,
                        desc="How to display absorbs exceeding max health",
                        values={ ["Overlay"]="Overlay", ["Glow"]="Glow" },
                        hidden=absorbsOff,
                        get=getIPKey,
                        set=function(info, val)
                            if InCombatLockdown() then return end
                            writeIP(info, val)
                            if self.InvalidateAbsorbTextureCaches then self:InvalidateAbsorbTextureCaches() end
                            self:RefreshAllAbsorbs()
                            if BF.RefreshPreviewAbsorbOverlay then BF:RefreshPreviewAbsorbOverlay() end
                        end,
                        disabled=function() return InCombatLockdown() or not BF:IsOvershieldActive(getIP()) end,
                    },
                    overshieldAnchor = {
                        type="select", name="Overshield Anchor", order=23,
                        desc="Position where the overshield anchors on the health bar",
                        values={ ["LEFT"]="Left", ["RIGHT"]="Right (Blizzard Style)" },
                        get=getIPKey,
                        set=function(info, val)
                            if InCombatLockdown() then return end
                            writeIP(info, val)
                            self:RefreshAllAbsorbs()
                            if BF.RefreshPreviewAbsorbOverlay then BF:RefreshPreviewAbsorbOverlay() end
                        end,
                        hidden=function()
                            if absorbsOff() then return true end
                            local ip = getIP(); return ip and ip.overshieldStyle == "Glow"
                        end,
                        disabled=function() return InCombatLockdown() or not BF:IsOvershieldActive(getIP()) end,
                    },
                    absorbColorsHeader = { type="header", name="Absorb Colors", order=25,
                        hidden=absorbsOff,
                    },
                    absorbColorGroup = {
                        type="group", name="Missing Health Absorb Colors", inline=true, order=26,
                        hidden=function()
                            local ip = getIP()
                            if not ip then return true end
                            return ip.showAbsorbsMissingHealth == false
                                or (ip.overshieldAnchor == "LEFT" and BF:IsOvershieldActive(ip) and ip.overshieldStyle ~= "Glow")
                        end,
                        args = {
                    useCustomAbsorbColor = {
                        type="toggle", name="Use Custom Absorb Color", order=1,
                        disabled=InCombatLockdown,
                        get=getIPKey,
                        set=function(info, val)
                            if InCombatLockdown() then return end
                            writeIP(info, val)
                            self:RefreshAllAbsorbs()
                            if BF.RefreshPreviewAbsorbOverlay then BF:RefreshPreviewAbsorbOverlay() end
                        end,
                    },
                    absorbBaseColor = {
                        type="color", name="Absorb Color", order=27,
                        desc="Color and opacity of the missing health absorb base texture",
                        hasAlpha=true,
                        hidden=function()
                            local ip = getIP()
                            if not ip then return true end
                            if not ip.useCustomAbsorbColor then return true end
                            return ip.showAbsorbsMissingHealth == false
                                or (ip.overshieldAnchor == "LEFT" and BF:IsOvershieldActive(ip) and ip.overshieldStyle ~= "Glow")
                        end,
                        get=function()
                            local ip = getIP()
                            local c = (ip and ip.absorbBaseColor) or { r=0.941, g=0.941, b=0.937, a=1.0 }
                            return c.r, c.g, c.b, c.a
                        end,
                        set=function(_, r, g, b, a)
                            if InCombatLockdown() then return end
                            local ip = getIP()
                            if ip then ip.absorbBaseColor = { r=r, g=g, b=b, a=a } end
                            self:RefreshAllAbsorbs()
                            if BF.RefreshPreviewAbsorbOverlay then BF:RefreshPreviewAbsorbOverlay() end
                        end,
                        disabled=InCombatLockdown,
                    },
                    absorbOverlayColor = {
                        type="color", name="Absorb Overlay Color", order=3,
                        desc="Color and opacity of the missing health absorb overlay texture",
                        hasAlpha=true,
                        hidden=function()
                            local ip = getIP()
                            if not ip then return true end
                            return not ip.useCustomAbsorbColor or ip.useCustomAbsorbBarTexture
                        end,
                        get=function()
                            local ip = getIP()
                            local c = (ip and ip.absorbOverlayColor) or { r=1, g=1, b=1, a=0.66 }
                            return c.r, c.g, c.b, c.a
                        end,
                        set=function(_, r, g, b, a)
                            if InCombatLockdown() then return end
                            local ip = getIP()
                            if ip then ip.absorbOverlayColor = { r=r, g=g, b=b, a=a } end
                            self:RefreshAllAbsorbs()
                            if BF.RefreshPreviewAbsorbOverlay then BF:RefreshPreviewAbsorbOverlay() end
                        end,
                        disabled=InCombatLockdown,
                    },
                        },
                    },
                    overshieldColorGroup = {
                        type="group", name="Overshield Absorb Colors", inline=true, order=27,
                        hidden=function()
                            if absorbsOff() then return true end
                            local ip = getIP(); return ip and ip.overshieldStyle == "Glow"
                        end,
                        args = {
                    useCustomOvershieldColor = {
                        type="toggle", name="Use Custom Overshield Color", order=1,
                        disabled=function() return InCombatLockdown() or not BF:IsOvershieldActive(getIP()) end,
                        get=getIPKey,
                        set=function(info, val)
                            if InCombatLockdown() then return end
                            writeIP(info, val)
                            self:RefreshAllAbsorbs()
                            if BF.RefreshPreviewAbsorbOverlay then BF:RefreshPreviewAbsorbOverlay() end
                        end,
                    },
                    overshieldBaseColor = {
                        type="color", name="Overshield Color", order=2,
                        desc="Color and opacity of the overshield absorb base texture",
                        hasAlpha=true,
                        hidden=function() local ip = getIP(); return not (ip and ip.useCustomOvershieldColor) end,
                        get=function()
                            local ip = getIP()
                            local c = (ip and ip.overshieldBaseColor) or { r=0.937, g=0.941, b=0.855, a=0.36 }
                            return c.r, c.g, c.b, c.a
                        end,
                        set=function(_, r, g, b, a)
                            if InCombatLockdown() then return end
                            local ip = getIP()
                            if ip then ip.overshieldBaseColor = { r=r, g=g, b=b, a=a } end
                            self:RefreshAllAbsorbs()
                            if BF.RefreshPreviewAbsorbOverlay then BF:RefreshPreviewAbsorbOverlay() end
                        end,
                        disabled=InCombatLockdown,
                    },
                    overshieldOverlayColor = {
                        type="color", name="Overshield Overlay Color", order=3,
                        desc="Color and opacity of the overshield absorb overlay texture",
                        hasAlpha=true,
                        hidden=function()
                            local ip = getIP()
                            if not ip then return true end
                            return not ip.useCustomOvershieldColor or ip.useCustomOvershieldBarTexture
                        end,
                        get=function()
                            local ip = getIP()
                            local c = (ip and ip.overshieldOverlayColor) or { r=1, g=1, b=1, a=0.66 }
                            return c.r, c.g, c.b, c.a
                        end,
                        set=function(_, r, g, b, a)
                            if InCombatLockdown() then return end
                            local ip = getIP()
                            if ip then ip.overshieldOverlayColor = { r=r, g=g, b=b, a=a } end
                            self:RefreshAllAbsorbs()
                            if BF.RefreshPreviewAbsorbOverlay then BF:RefreshPreviewAbsorbOverlay() end
                        end,
                        disabled=InCombatLockdown,
                    },
                        },
                    },
                    absorbTexturesHeader = { type="header", name="Absorb Textures", order=28,
                        hidden=absorbsOff,
                    },
                    absorbTextureGroup = {
                        type="group", name="Missing Health Absorb Textures", inline=true, order=28.5,
                        hidden=function()
                            local ip = getIP()
                            if not ip then return true end
                            return ip.showAbsorbsMissingHealth == false
                                or (ip.overshieldAnchor == "LEFT" and BF:IsOvershieldActive(ip) and ip.overshieldStyle ~= "Glow")
                        end,
                        args = {
                    useCustomAbsorbBarTexture = {
                        type="toggle", name="Use Custom Absorb Texture", order=1,
                        disabled=InCombatLockdown,
                        get=getIPKey,
                        set=function(info, val)
                            if InCombatLockdown() then return end
                            writeIP(info, val)
                            if self.InvalidateAbsorbTextureCaches then self:InvalidateAbsorbTextureCaches() end
                            self:RefreshAllAbsorbs()
                            if BF.RefreshPreviewAbsorbOverlay then BF:RefreshPreviewAbsorbOverlay() end
                        end,
                    },
                    absorbBarTexture = {
                        type="select", name="Absorb Texture", order=2,
                        dialogControl="LSM30_Statusbar",
                        desc="Statusbar fill texture for the missing health absorb bar.",
                        hidden=function() local ip = getIP(); return not (ip and ip.useCustomAbsorbBarTexture) end,
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
                        get=function() local ip = getIP(); return (ip and ip.absorbBarTexture) or "Solid" end,
                        set=function(info, val)
                            if InCombatLockdown() then return end
                            writeIP(info, val)
                            if self.InvalidateAbsorbTextureCaches then self:InvalidateAbsorbTextureCaches() end
                            self:RefreshAllAbsorbs()
                            if BF.RefreshPreviewAbsorbOverlay then BF:RefreshPreviewAbsorbOverlay() end
                        end,
                    },
                        },
                    },
                    overshieldTextureGroup = {
                        type="group", name="Overshield Textures", inline=true, order=29,
                        hidden=function()
                            if absorbsOff() then return true end
                            local ip = getIP(); return ip and ip.overshieldStyle == "Glow"
                        end,
                        args = {
                    useCustomOvershieldBarTexture = {
                        type="toggle", name="Use Custom Overshield Texture", order=1,
                        disabled=function() return InCombatLockdown() or not BF:IsOvershieldActive(getIP()) end,
                        get=getIPKey,
                        set=function(info, val)
                            if InCombatLockdown() then return end
                            writeIP(info, val)
                            if self.InvalidateAbsorbTextureCaches then self:InvalidateAbsorbTextureCaches() end
                            self:RefreshAllAbsorbs()
                            if BF.RefreshPreviewAbsorbOverlay then BF:RefreshPreviewAbsorbOverlay() end
                        end,
                    },
                    overshieldBarTexture = {
                        type="select", name="Overshield Texture", order=2,
                        dialogControl="LSM30_Statusbar",
                        desc="Statusbar fill texture for the overshield absorb bar.",
                        hidden=function() local ip = getIP(); return not (ip and ip.useCustomOvershieldBarTexture) end,
                        disabled=function() return InCombatLockdown() or not BF:IsOvershieldActive(getIP()) end,
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
                        get=function() local ip = getIP(); return (ip and ip.overshieldBarTexture) or "Solid" end,
                        set=function(info, val)
                            if InCombatLockdown() then return end
                            writeIP(info, val)
                            if self.InvalidateAbsorbTextureCaches then self:InvalidateAbsorbTextureCaches() end
                            self:RefreshAllAbsorbs()
                            if BF.RefreshPreviewAbsorbOverlay then BF:RefreshPreviewAbsorbOverlay() end
                        end,
                    },
                        },
                    },
                    testAbsorbHeader = { type="header", name="Test", order=40,
                        hidden=absorbsOff,
                    },
                    testAbsorb = {
                        type="toggle", name="Test Absorb", order=41,
                        desc="Simulate a damage absorb on preview frames for testing. Disable when done.",
                        hidden=absorbsOff,
                        get=function() return BF.db.global.testAbsorb end,
                        set=function(_, val)
                            if InCombatLockdown() then return end
                            BF.db.global.testAbsorb = val
                            if BF.RefreshPreviewAbsorbOverlay then BF:RefreshPreviewAbsorbOverlay() end
                        end,
                        disabled=InCombatLockdown,
                    },
                    testAbsorbSize = {
                        type="select", name="Absorb Size", order=42,
                        hidden=function() return absorbsOff() or not BF.db.global.testAbsorb end,
                        values={
                            small   = "Small Absorb (10%)",
                            medium  = "Medium Absorb (40%)",
                            large   = "Large Absorb (80%)",
                            massive = "Massive Absorb (120%)",
                        },
                        sorting = { "small", "medium", "large", "massive" },
                        get=function() return BF.db.global.testAbsorbSize or "medium" end,
                        set=function(_, val)
                            if InCombatLockdown() then return end
                            BF.db.global.testAbsorbSize = val
                            if BF.RefreshPreviewAbsorbOverlay then BF:RefreshPreviewAbsorbOverlay() end
                        end,
                        disabled=InCombatLockdown,
                    },
                },
            },

            -- ── Tab 4: Temp Reduced Max Health ─────────────────────────────
            reducedMaxHealth = {
                type = "group", name = "Temp Reduced Max Health", order = 4,
                args = {
                    reducedMaxHeader = { type = "header", name = "Temporary Reduced Max Health", order = 1 },
                    reducedMaxDesc = {
                        type = "description", order = 1.5, width = "full",
                        name = "Some boss abilities temporarily reduce a unit's maximum health. When active, a grey bar fills from the right side of the health bar to indicate the unavailable portion. This mirrors the default Blizzard raid frame behavior.",
                    },
                    showReducedMaxHealth = {
                        type = "toggle", name = "Show Reduced Max Health Bar", order = 2,
                        desc = "Show a grey overlay on the health bar when a unit's maximum health is temporarily reduced.",
                        get = function() local ip = getIP(); return ip and ip.showReducedMaxHealth ~= false end,
                        set = function(info, val)
                            if InCombatLockdown() then return end
                            writeIP(info, val)
                            if not val and BF.db.global.testReducedMaxHealth then
                                BF.db.global.testReducedMaxHealth = false
                            end
                            self:RefreshAllReducedMaxHealth()
                            if BF.RefreshPreviewReducedMaxHealth then BF:RefreshPreviewReducedMaxHealth() end
                        end,
                        disabled = InCombatLockdown,
                    },
                    reducedMaxBarTextureHeader = { type = "header", name = "Reduced Max Health Bar Texture", order = 2.5,
                        hidden = function() local ip = getIP(); return ip and ip.showReducedMaxHealth == false end,
                    },
                    useCustomReducedMaxTexture = {
                        type = "toggle", name = "Use Custom Texture", order = 2.6,
                        hidden = function() local ip = getIP(); return ip and ip.showReducedMaxHealth == false end,
                        get = getIPKey,
                        set = function(info, val)
                            if InCombatLockdown() then return end
                            writeIP(info, val)
                            self:RefreshAllReducedMaxHealth()
                            if BF.RefreshPreviewReducedMaxHealth then BF:RefreshPreviewReducedMaxHealth() end
                        end,
                        disabled = InCombatLockdown,
                    },
                    reducedMaxHealthTexture = {
                        type = "select", name = "Bar Texture", order = 2.7,
                        dialogControl = "LSM30_Statusbar",
                        desc = "Statusbar fill texture for the reduced max health bar.",
                        hidden = function()
                            local ip = getIP()
                            if not ip then return true end
                            return ip.showReducedMaxHealth == false or not ip.useCustomReducedMaxTexture
                        end,
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
                        get = function() local ip = getIP(); return (ip and ip.reducedMaxHealthTexture) or "Solid" end,
                        set = function(info, val)
                            if InCombatLockdown() then return end
                            writeIP(info, val)
                            self:RefreshAllReducedMaxHealth()
                            if BF.RefreshPreviewReducedMaxHealth then BF:RefreshPreviewReducedMaxHealth() end
                        end,
                        disabled = InCombatLockdown,
                    },
                    reducedMaxHealthColor = {
                        type = "color", name = "Bar Color", order = 2.8, hasAlpha = true,
                        desc = "Color of the reduced max health overlay bar.",
                        hidden = function()
                            local ip = getIP()
                            if not ip then return true end
                            return ip.showReducedMaxHealth == false or not ip.useCustomReducedMaxTexture
                        end,
                        get = function()
                            local ip = getIP()
                            local c = (ip and ip.reducedMaxHealthColor) or { r = 0.3, g = 0.3, b = 0.3, a = 0.8 }
                            return c.r, c.g, c.b, c.a or 0.8
                        end,
                        set = function(_, r, g, b, a)
                            if InCombatLockdown() then return end
                            local ip = getIP()
                            if ip then ip.reducedMaxHealthColor = { r = r, g = g, b = b, a = a } end
                            self:RefreshAllReducedMaxHealth()
                            if BF.RefreshPreviewReducedMaxHealth then BF:RefreshPreviewReducedMaxHealth() end
                        end,
                        disabled = InCombatLockdown,
                    },
                    reducedMaxTextHeader = { type = "header", name = "Reduced Max Health % Text", order = 4,
                        hidden = function() local ip = getIP(); return ip and ip.showReducedMaxHealth == false end,
                    },
                    showReducedMaxHealthText = {
                        type = "toggle", name = "Show Reduced Max Health % Text", order = 5,
                        desc = "Show a separate text element displaying the remaining max health percentage when temporarily reduced.",
                        hidden = function() local ip = getIP(); return ip and ip.showReducedMaxHealth == false end,
                        get = function() local ip = getIP(); return ip and ip.showReducedMaxHealthText == true end,
                        set = function(info, val)
                            if InCombatLockdown() then return end
                            writeIP(info, val)
                            layoutFrames()
                            for frame in pairs(self.activeFrames or {}) do
                                frame:UpdateIndicators()
                            end
                        end,
                        disabled = InCombatLockdown,
                    },
                    reducedMaxHealthTextColor = {
                        type = "color", name = "Text Color", order = 5.04, hasAlpha = false,
                        hidden = function()
                            local ip = getIP()
                            if not ip then return true end
                            return ip.showReducedMaxHealth == false or not ip.showReducedMaxHealthText
                        end,
                        get = function()
                            local ip = getIP()
                            local c = (ip and ip.reducedMaxHealthTextColor) or { r = 1, g = 0.8, b = 0.2 }
                            return c.r, c.g, c.b
                        end,
                        set = function(_, r, g, b)
                            if InCombatLockdown() then return end
                            local ip = getIP()
                            if ip then ip.reducedMaxHealthTextColor = { r = r, g = g, b = b } end
                            layoutFrames()
                            for frame in pairs(self.activeFrames or {}) do
                                frame:UpdateIndicators()
                            end
                        end,
                        disabled = InCombatLockdown,
                    },
                    appendReducedMaxGroup = {
                        type = "group", name = "Append", inline = true, order = 5.05,
                        hidden = function()
                            local ip = getIP()
                            if not ip then return true end
                            return ip.showReducedMaxHealth == false or not ip.showReducedMaxHealthText
                        end,
                        args = {
                            appendReducedMaxText = {
                                type = "toggle", name = "Append Text", order = 1,
                                desc = "Append the reduced max health percentage to an existing text element instead of showing it separately.",
                                get = function() local ip = getIP(); return ip and ip.appendReducedMaxText == true end,
                                set = function(info, val)
                                    if InCombatLockdown() then return end
                                    writeIP(info, val)
                                    layoutFrames()
                                    for frame in pairs(self.activeFrames or {}) do
                                        frame:UpdateIndicators()
                                    end
                                end,
                                disabled = InCombatLockdown,
                            },
                            appendReducedMaxTarget = {
                                type = "select", name = "Append To", order = 2,
                                desc = "Choose which text element to append the reduced max health percentage to.",
                                hidden = function() local ip = getIP(); return not (ip and ip.appendReducedMaxText) end,
                                values = {
                                    ["health"] = "Health Text",
                                    ["name"] = "Name",
                                },
                                get = function() local ip = getIP(); return (ip and ip.appendReducedMaxTarget) or "health" end,
                                set = function(info, val)
                                    if InCombatLockdown() then return end
                                    writeIP(info, val)
                                    layoutFrames()
                                    for frame in pairs(self.activeFrames or {}) do
                                        frame:UpdateIndicators()
                                    end
                                end,
                                disabled = InCombatLockdown,
                            },
                        },
                    },
                    reducedMaxHealthTextPositionGroup = {
                        type = "group", name = "Position", inline = true, order = 5.1,
                        hidden = function()
                            local ip = getIP()
                            if not ip then return true end
                            return ip.showReducedMaxHealth == false or not ip.showReducedMaxHealthText or ip.appendReducedMaxText
                        end,
                        args = {
                            reducedMaxHealthTextPosition = {
                                type = "select", name = "Anchor", order = 1,
                                values = {
                                    TOPLEFT = "Top Left", TOP = "Top", TOPRIGHT = "Top Right",
                                    LEFT = "Left", CENTER = "Center", RIGHT = "Right",
                                    BOTTOMLEFT = "Bottom Left", BOTTOM = "Bottom", BOTTOMRIGHT = "Bottom Right",
                                },
                                get = function() local ip = getIP(); return (ip and ip.reducedMaxHealthTextPosition) or "BOTTOMRIGHT" end,
                                set = function(info, val)
                                    if InCombatLockdown() then return end
                                    writeIP(info, val)
                                    layoutFrames()
                                end,
                                disabled = InCombatLockdown,
                            },
                            reducedMaxHealthTextX = {
                                type = "range", name = "X Offset", order = 2,
                                min = -20, max = 20, step = 1,
                                get = function() local ip = getIP(); return (ip and ip.reducedMaxHealthTextX) or -2 end,
                                set = function(info, val)
                                    if InCombatLockdown() then return end
                                    writeIP(info, val)
                                    layoutFrames()
                                end,
                                disabled = InCombatLockdown,
                            },
                            reducedMaxHealthTextY = {
                                type = "range", name = "Y Offset", order = 3,
                                min = -20, max = 20, step = 1,
                                get = function() local ip = getIP(); return (ip and ip.reducedMaxHealthTextY) or 2 end,
                                set = function(info, val)
                                    if InCombatLockdown() then return end
                                    writeIP(info, val)
                                    layoutFrames()
                                end,
                                disabled = InCombatLockdown,
                            },
                        },
                    },

                    reducedMaxHealthFontSize = {
                        type = "range", name = "Font Size", order = 5.5,
                        min = 6, max = 24, step = 1,
                        hidden = function()
                            local ip = getIP()
                            if not ip then return true end
                            return ip.showReducedMaxHealth == false or not ip.showReducedMaxHealthText or ip.appendReducedMaxText
                        end,
                        get = function() local ip = getIP(); return (ip and ip.reducedMaxHealthFontSize) or 9 end,
                        set = function(info, val)
                            if InCombatLockdown() then return end
                            writeIP(info, val)
                            layoutFrames()
                        end,
                        disabled = InCombatLockdown,
                    },
                    reducedMaxHealthFontBorder = {
                        type = "select", name = "Font Border", order = 5.6,
                        hidden = function()
                            local ip = getIP()
                            if not ip then return true end
                            return ip.showReducedMaxHealth == false or not ip.showReducedMaxHealthText or ip.appendReducedMaxText
                        end,
                        values = {
                            [""] = "None",
                            ["OUTLINE"] = "Outline",
                            ["THICKOUTLINE"] = "Thick Outline",
                        },
                        get = function() local ip = getIP(); return (ip and ip.reducedMaxHealthFontBorder) or "" end,
                        set = function(info, val)
                            if InCombatLockdown() then return end
                            writeIP(info, val)
                            layoutFrames()
                        end,
                        disabled = InCombatLockdown,
                    },
                    testHeader = { type = "header", name = "Test", order = 10,
                        hidden = function() local ip = getIP(); return ip and ip.showReducedMaxHealth == false end,
                    },
                    testReducedMaxHealth = {
                        type = "toggle", name = "Test Reduced Max Health (50%)", order = 11,
                        desc = "Simulate a 50% max health reduction on preview frames for testing.",
                        hidden = function() local ip = getIP(); return ip and ip.showReducedMaxHealth == false end,
                        get = function() return BF.db.global.testReducedMaxHealth == true end,
                        set = function(_, val)
                            if InCombatLockdown() then return end
                            BF.db.global.testReducedMaxHealth = val
                            if BF.RefreshPreviewReducedMaxHealth then BF:RefreshPreviewReducedMaxHealth() end
                        end,
                        disabled = InCombatLockdown,
                    },
                },
            },

        },
    }
end
