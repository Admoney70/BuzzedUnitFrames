-- ============================================================
-- BuzzardFrames: Options_Borders.lua
-- Builds and returns the "Borders" nav-tab args table.
-- Called from Options.lua: BF:BuildBordersOptions(deps)
-- ============================================================
local BF = _G["BuzzardFrames"]

-- deps is a table of upvalue references passed in from RegisterOptions:
--   deps.self               - the BF addon object
--   deps.NotifyChangeSafe   - local function from RegisterOptions
--   deps.get                - local function from RegisterOptions
--   deps.set                - local function from RegisterOptions
function BF:BuildBordersOptions(deps)
    local self             = deps.self
    local NotifyChangeSafe = deps.NotifyChangeSafe
    local get              = deps.get
    local set              = deps.set

    -- Per-layout section-profile helpers.
    -- Storage: rpDB.profile.borders.* (global pseudo-layout) or
    -- flat.borders.* when layouts.perLayoutToggles.borders is true.
    -- These helpers mirror Options_Tooltips.lua's getTP() pattern:
    -- getSP() returns the section sub-table for the currently-modifying
    -- flat (falling through to the global when the toggle is OFF);
    -- writeSP(key, val) writes into that same sub-table without triggering
    -- the side effects `set` (from deps) would; and getSPKey(key) is a
    -- shorthand for reading a single key.
    --
    -- deps.get / deps.set are already routed through GetSectionProfile --
    -- widgets using plain `get=get` / `set=set` land on the right section
    -- automatically. These local helpers are only needed for:
    --   * `disabled=` predicates that read sibling keys
    --   * custom `set=` handlers that do side effects beyond the plain write
    --   * color widgets whose in-place r,g,b mutation bypasses `set`
    local function getSP()
        return self:GetSectionProfile("borders", self:GetModifyingProfile())
    end
    local function getSPKey(key)
        local sp = getSP()
        return sp and sp[key]
    end
    local function writeSP(key, val)
        if InCombatLockdown() then return end
        local sp = getSP()
        if sp then sp[key] = val end
    end

    -- Refresh setup mode test frame visuals after border settings change.
    local function refreshTestFrameBorders()
        if BF.db.global.raid40TestMode or BF.db.global.raid30TestMode or BF.db.global.raid20TestMode then
            if self.testHeader and self.testHeader.frames then
                local limit = self.testHeader.activeCount or #self.testHeader.frames
                for i = 1, limit do
                    local f = self.testHeader.frames[i]
                    if f and f:IsShown() then self:_ApplyProfileVisualsToTestFrame(f) end
                end
            end
        end
        if BF.db.global.partyTestMode and self.partyTestHeader and self.partyTestHeader.frames then
            for _, f in ipairs(self.partyTestHeader.frames) do
                if f and f:IsShown() then self:_ApplyProfileVisualsToTestFrame(f) end
            end
        end
    end

    return {
        type = "group", name = "Borders & Highlights", order = 6,
        childGroups = "tab",
        args = {
            _sectionTracker = { type="description", name=function() if self._currentSection ~= "borders" then self._currentSection="borders"; if not InCombatLockdown() then NotifyChangeSafe() end end; return "" end, order=0, width="full" },
            borderTab = {
                type = "group", name = "Border", order = 1,
                args = {
                    _subtabTracker = { type="description", order=0, width="full", name=function() if self._currentSection ~= "borders" then self._currentSection="borders"; if not InCombatLockdown() then NotifyChangeSafe() end end; return "" end },
                    borderHeader = { type="header", name="Border", order=1 },
                    enableBorder = {
                        type="toggle", name="Enable Border", order=2,
                        get=get,
                        set=function(info, val)
                            if InCombatLockdown() then return end
                            set(info, val)
                            for f in pairs(self.activeFrames or {}) do self:LayoutFrame(f) end
                            if BF.RefreshPreviewLayout then BF:RefreshPreviewLayout() end
                            refreshTestFrameBorders()
                        end,
                        disabled=InCombatLockdown,
                    },
                    borderColor = {
                        type="color", name="Border Color", order=3, hasAlpha=false,
                        disabled=function() return InCombatLockdown() or not getSPKey("enableBorder") end,
                        get=function() local c = getSPKey("borderColor") or {r=0,g=0,b=0}; return c.r, c.g, c.b end,
                        set=function(_, r, g, b)
                            if InCombatLockdown() then return end
                            writeSP("borderColor", { r=r, g=g, b=b })
                            for f in pairs(self.activeFrames or {}) do self:LayoutFrame(f) end
                            if BF.RefreshPreviewLayout then BF:RefreshPreviewLayout() end
                            refreshTestFrameBorders()
                        end,
                    },
                    borderThickness = {
                        type="range", name="Border Thickness", order=4, min=1, max=5, step=1,
                        disabled=function() return InCombatLockdown() or not getSPKey("enableBorder") end,
                        get=get,
                        set=function(info, val)
                            if InCombatLockdown() then return end
                            set(info, val)
                            for f in pairs(self.activeFrames or {}) do self:LayoutFrame(f) end
                            if BF.RefreshPreviewLayout then BF:RefreshPreviewLayout() end
                            refreshTestFrameBorders()
                        end,
                    },
                    borderOpacity = {
                        type="range", name="Border Opacity", order=5, min=0.1, max=1.0, step=0.05,
                        disabled=function() return InCombatLockdown() or not getSPKey("enableBorder") end,
                        get=get,
                        set=function(info, val)
                            if InCombatLockdown() then return end
                            set(info, val)
                            -- Re-layout all frames so Container:Layout re-applies
                            -- the edge textures with the new opacity (same as borderColor).
                            for f in pairs(self.activeFrames or {}) do self:LayoutFrame(f) end
                            if BF.RefreshPreviewLayout then BF:RefreshPreviewLayout() end
                            refreshTestFrameBorders()
                        end,
                    },
                },
            },
            aggroTab = {
                type = "group", name = "Aggro Highlight", order = 4,
                args = {
                    _subtabTracker = { type="description", order=0, width="full", name=function() if self._currentSection ~= "borders" then self._currentSection="borders"; if not InCombatLockdown() then NotifyChangeSafe() end end; return "" end },
                    aggroEnabled = {
                        type="toggle", name="Enable Aggro Highlight", order=1,
                        get=get,
                        set=function(info, val)
                            if InCombatLockdown() then return end
                            set(info, val)
                            if not val then BF.db.global.testAggroHighlight = false end
                            for f in pairs(self.activeFrames or {}) do self:UpdateThreat(f) end
                        end,
                        disabled=InCombatLockdown,
                    },
                    aggroStyle = {
                        type="select", name="Highlight Style", order=2,
                        values={ border="Border", blizzard="Blizzard Style", corners="Corners", arrowSingle="Arrow (Single)", arrow="Arrow (Double)" },
                        sorting={ "blizzard", "border", "corners", "arrowSingle", "arrow" },
                        disabled=function() return InCombatLockdown() or not getSPKey("aggroEnabled") end,
                        get=get,
                        set=function(info, val)
                            if InCombatLockdown() then return end
                            set(info, val)
                            for f in pairs(self.activeFrames or {}) do
                                self:LayoutFrame(f)
                                self:UpdateThreat(f)
                            end
                        end,
                    },
                    aggroHighlightGroup = {
                        type="group", name="Aggro Highlight", inline=true, order=3,
                        hidden=function() local s = getSPKey("aggroStyle"); return s == "arrow" or s == "arrowSingle" or s == "corners" end,
                        args = {
                            aggroScale = {
                                type="range", name="Aggro Highlight Intensity", order=1,
                                min=0.1, max=1.0, step=0.1,
                                disabled=function() return InCombatLockdown() or not getSPKey("aggroEnabled") end,
                                get=get,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    set(info, val)
                                    for f in pairs(self.activeFrames or {}) do self:UpdateThreat(f) end
                                end,
                            },
                            aggroBorderWidth = {
                                type="range", name="Aggro Border Width", order=2,
                                min=1, max=5, step=1,
                                hidden=function() return getSPKey("aggroStyle") == "blizzard" end,
                                disabled=function()
                                    return InCombatLockdown()
                                        or not getSPKey("aggroEnabled")
                                end,
                                get=get,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    writeSP("aggroBorderWidth", val)
                                    for frame in pairs(self.activeFrames or {}) do self:LayoutFrame(frame) end
                                    for f in pairs(self.activeFrames or {}) do self:UpdateThreat(f) end
                                end,
                            },
                            aggroBorderWidthBlizzard = {
                                type="range", name="Aggro Border Size", order=3,
                                min=2, max=5, step=1,
                                hidden=function() return getSPKey("aggroStyle") ~= "blizzard" end,
                                disabled=function()
                                    return InCombatLockdown()
                                        or not getSPKey("aggroEnabled")
                                end,
                                get=function() return math.max(2, math.min(5, getSPKey("aggroBorderWidth") or 2)) end,
                                set=function(_, val)
                                    if InCombatLockdown() then return end
                                    writeSP("aggroBorderWidth", val)
                                    for frame in pairs(self.activeFrames or {}) do self:LayoutFrame(frame) end
                                    for f in pairs(self.activeFrames or {}) do self:UpdateThreat(f) end
                                end,
                            },
                        },
                    },
                    aggroColorsGroup = {
                        type="group", name="Threat Colors", inline=true, order=5,
                        args = {
                            aggroColor1 = {
                                type="color", name="No Aggro, High Threat", order=1, hasAlpha=false,
                                desc="Does not have aggro, but is high on threat.",
                                disabled=function() return InCombatLockdown() or not getSPKey("aggroEnabled") end,
                                get=function()
                                    local c = getSPKey("aggroColor1") or { r=1, g=0.94, b=0 }
                                    return c.r, c.g, c.b
                                end,
                                set=function(_, r, g, b)
                                    if InCombatLockdown() then return end
                                    writeSP("aggroColor1", { r=r, g=g, b=b })
                                    for f in pairs(self.activeFrames or {}) do self:UpdateThreat(f) end
                                    if BF.RefreshPreviewAggro then BF:RefreshPreviewAggro() end
                                end,
                            },
                            aggroColor2 = {
                                type="color", name="Has Aggro, Low Threat", order=2, hasAlpha=false,
                                desc="Has aggro, but is low on threat.",
                                disabled=function() return InCombatLockdown() or not getSPKey("aggroEnabled") end,
                                get=function()
                                    local c = getSPKey("aggroColor2") or { r=1, g=0.5, b=0 }
                                    return c.r, c.g, c.b
                                end,
                                set=function(_, r, g, b)
                                    if InCombatLockdown() then return end
                                    writeSP("aggroColor2", { r=r, g=g, b=b })
                                    for f in pairs(self.activeFrames or {}) do self:UpdateThreat(f) end
                                    if BF.RefreshPreviewAggro then BF:RefreshPreviewAggro() end
                                end,
                            },
                            aggroColor3 = {
                                type="color", name="Has Aggro, High Threat", order=3, hasAlpha=false,
                                desc="Has aggro, and is high on threat.",
                                disabled=function() return InCombatLockdown() or not getSPKey("aggroEnabled") end,
                                get=function()
                                    local c = getSPKey("aggroColor3") or { r=1, g=0.306, b=0 }
                                    return c.r, c.g, c.b
                                end,
                                set=function(_, r, g, b)
                                    if InCombatLockdown() then return end
                                    writeSP("aggroColor3", { r=r, g=g, b=b })
                                    for f in pairs(self.activeFrames or {}) do self:UpdateThreat(f) end
                                    if BF.RefreshPreviewAggro then BF:RefreshPreviewAggro() end
                                end,
                            },
                        },
                    },
                    cornersOptionsGroup = {
                        type="group", name="Corners", inline=true, order=4,
                        hidden=function() return getSPKey("aggroStyle") ~= "corners" end,
                        args = {
                            aggroCornersScale = {
                                type="select", name="Corner Scale", order=1,
                                values={ sm="Small", md="Medium", lg="Large" },
                                disabled=function() return InCombatLockdown() or not getSPKey("aggroEnabled") end,
                                get=function() return getSPKey("aggroCornersScale") or "lg" end,
                                set=function(_, val)
                                    if InCombatLockdown() then return end
                                    writeSP("aggroCornersScale", val)
                                    for f in pairs(self.activeFrames or {}) do self:UpdateThreat(f) end
                                    if BF.RefreshPreviewAggro then BF:RefreshPreviewAggro() end
                                end,
                            },
                        },
                    },
                    arrowOptionsGroup = {
                        type="group", name="Arrow", inline=true, order=6,
                        hidden=function() local s = getSPKey("aggroStyle"); return s ~= "arrow" and s ~= "arrowSingle" end,
                        args = {
                            aggroArrowDirection = {
                                type="select", name="Arrow Direction", order=1,
                                values={ right="Right", left="Left", up="Up", down="Down" },
                                disabled=function() return InCombatLockdown() or not getSPKey("aggroEnabled") end,
                                get=function() return getSPKey("aggroArrowDirection") or "right" end,
                                set=function(_, val)
                                    if InCombatLockdown() then return end
                                    writeSP("aggroArrowDirection", val)
                                    for f in pairs(self.activeFrames or {}) do self:LayoutFrame(f) end
                                    for f in pairs(self.activeFrames or {}) do self:UpdateThreat(f) end
                                    if BF.RefreshPreviewAggro then BF:RefreshPreviewAggro() end
                                end,
                            },
                            aggroArrowPosition = {
                                type="select", name="Arrow Position", order=2,
                                values={
                                    TOPLEFT="Top Left", TOP="Top", TOPRIGHT="Top Right",
                                    LEFT="Left", CENTER="Center", RIGHT="Right",
                                    BOTTOMLEFT="Bottom Left", BOTTOM="Bottom", BOTTOMRIGHT="Bottom Right",
                                },
                                disabled=function() return InCombatLockdown() or not getSPKey("aggroEnabled") end,
                                get=function() return getSPKey("aggroArrowPosition") or "LEFT" end,
                                set=function(_, val)
                                    if InCombatLockdown() then return end
                                    writeSP("aggroArrowPosition", val)
                                    for f in pairs(self.activeFrames or {}) do self:LayoutFrame(f) end
                                    for f in pairs(self.activeFrames or {}) do self:UpdateThreat(f) end
                                    if BF.RefreshPreviewAggro then BF:RefreshPreviewAggro() end
                                end,
                            },
                            aggroArrowSize = {
                                type="range", name="Arrow Size", order=3,
                                min=8, max=32, step=1,
                                disabled=function() return InCombatLockdown() or not getSPKey("aggroEnabled") end,
                                get=function() return getSPKey("aggroArrowSize") or 16 end,
                                set=function(_, val)
                                    if InCombatLockdown() then return end
                                    writeSP("aggroArrowSize", val)
                                    for f in pairs(self.activeFrames or {}) do self:LayoutFrame(f) end
                                    if BF.RefreshPreviewAggro then BF:RefreshPreviewAggro() end
                                end,
                            },
                            aggroArrowOffsetX = {
                                type="range", name="X Offset", order=4,
                                min=-20, max=20, step=1,
                                disabled=function() return InCombatLockdown() or not getSPKey("aggroEnabled") end,
                                get=function() return getSPKey("aggroArrowOffsetX") or 0 end,
                                set=function(_, val)
                                    if InCombatLockdown() then return end
                                    writeSP("aggroArrowOffsetX", val)
                                    for f in pairs(self.activeFrames or {}) do self:LayoutFrame(f) end
                                    if BF.RefreshPreviewAggro then BF:RefreshPreviewAggro() end
                                end,
                            },
                            aggroArrowOffsetY = {
                                type="range", name="Y Offset", order=5,
                                min=-20, max=20, step=1,
                                disabled=function() return InCombatLockdown() or not getSPKey("aggroEnabled") end,
                                get=function() return getSPKey("aggroArrowOffsetY") or 0 end,
                                set=function(_, val)
                                    if InCombatLockdown() then return end
                                    writeSP("aggroArrowOffsetY", val)
                                    for f in pairs(self.activeFrames or {}) do self:LayoutFrame(f) end
                                    if BF.RefreshPreviewAggro then BF:RefreshPreviewAggro() end
                                end,
                            },
                        },
                    },
                    aggroPreviewHeader = { type="header", name="Preview", order=20 },
                    testAggroHighlight = {
                        -- Test flag lives on BF.db.global (not routed through the
                        -- borders section) -- matches the convention used by every
                        -- other test flag (testAbsorb, simulateDispellableDebuff,
                        -- etc.). Runtime readers in AggroHighlight:Update and
                        -- ApplyPreviewHighlights read BF.db.global.testAggroHighlight
                        -- directly. The old `get=get, set=set` plumbing wrote this
                        -- to the borders section (bp.testAggroHighlight) where
                        -- nothing ever read it -- the toggle did nothing.
                        type="toggle", name="Test Aggro Highlight", order=21,
                        desc="Display the aggro highlight on all frames for preview purposes.",
                        disabled=function() return InCombatLockdown() or not getSPKey("aggroEnabled") end,
                        get=function() return BF.db.global.testAggroHighlight end,
                        set=function(_, val)
                            if InCombatLockdown() then return end
                            BF.db.global.testAggroHighlight = val
                            if BF.RefreshPreviewAggro then BF:RefreshPreviewAggro() end
                        end,
                    },
                    testAggroLevel = {
                        type="select", name="Test Aggro Level", order=22,
                        desc="Which threat level to simulate on the preview frames.",
                        values={ [1]="No Aggro, High Threat", [2]="Has Aggro, Low Threat", [3]="Has Aggro, High Threat" },
                        disabled=function() return InCombatLockdown() or not getSPKey("aggroEnabled") or not BF.db.global.testAggroHighlight end,
                        get=function() return BF.db.global.testAggroLevel or 3 end,
                        set=function(_, val)
                            if InCombatLockdown() then return end
                            BF.db.global.testAggroLevel = val
                            if BF.RefreshPreviewAggro then BF:RefreshPreviewAggro() end
                        end,
                    },
                },
            },
            targetHighlightTab = {
                type = "group", name = "Target Highlight", order = 2,
                args = {
                    _subtabTracker = { type="description", order=0, width="full", name=function() if self._currentSection ~= "borders" then self._currentSection="borders"; if not InCombatLockdown() then NotifyChangeSafe() end end; return "" end },
                    targetHighlightHeader = { type="header", name="Target Highlight", order=1 },
                    targetHighlightNote = { type="description", name="Shows a colored border on the frame of your current target.", order=2 },
                    enableTargetHighlight = {
                        type="toggle", name="Enable Target Highlight", order=3,
                        get=get,
                        set=function(info, val)
                            if InCombatLockdown() then return end
                            writeSP("enableTargetHighlight", val)
                            for f in pairs(self.activeFrames or {}) do self:UpdateTarget(f) end
                        end,
                        disabled=InCombatLockdown,
                    },
                    targetHighlightColor = {
                        type="color", name="Target Highlight Color", order=4, hasAlpha=false,
                        disabled=function() return InCombatLockdown() or not getSPKey("enableTargetHighlight") end,
                        get=function() local c = getSPKey("targetHighlightColor") or {r=1,g=1,b=1}; return c.r, c.g, c.b end,
                        set=function(_, r, g, b)
                            if InCombatLockdown() then return end
                            local c = getSPKey("targetHighlightColor")
                            if c then
                                -- In-place mutation on the section sub-table so any metatable
                                -- fallback remains intact (AceDB defaults re-seed missing
                                -- sub-tables on profile reset, not individual color keys).
                                c.r, c.g, c.b = r, g, b
                            else
                                writeSP("targetHighlightColor", { r=r, g=g, b=b })
                            end
                            for f in pairs(self.activeFrames or {}) do self:UpdateTarget(f) end
                        end,
                    },
                    targetHighlightOpacity = {
                        type="range", name="Target Highlight Opacity", order=5, min=0.1, max=1.0, step=0.05,
                        disabled=function() return InCombatLockdown() or not getSPKey("enableTargetHighlight") end,
                        get=get,
                        set=function(info, val)
                            if InCombatLockdown() then return end
                            writeSP("targetHighlightOpacity", val)
                            for f in pairs(self.activeFrames or {}) do self:UpdateTarget(f) end
                        end,
                    },
                    targetHighlightWidth = {
                        type="range", name="Target Highlight Width", order=6, min=1, max=8, step=1,
                        disabled=function() return InCombatLockdown() or not getSPKey("enableTargetHighlight") end,
                        get=get,
                        set=function(info, val)
                            if InCombatLockdown() then return end
                            writeSP("targetHighlightWidth", val)
                            for frame in pairs(self.activeFrames or {}) do self:LayoutFrame(frame) end
                        end,
                    },
                },
            },
            mouseoverTab = {
                type = "group", name = "Mouseover Highlight", order = 3,
                args = {
                    _subtabTracker = { type="description", order=0, width="full", name=function() if self._currentSection ~= "borders" then self._currentSection="borders"; if not InCombatLockdown() then NotifyChangeSafe() end end; return "" end },
                    mouseoverHeader = { type="header", name="Mouseover Highlight", order=1 },
                    mouseoverNote = { type="description", name="Shows a color overlay on a frame when your mouse is over it.", order=2 },
                    enableMouseoverHighlight = {
                        type="toggle", name="Enable Mouseover Highlight", order=3,
                        get=get,
                        set=function(info, val)
                            if InCombatLockdown() then return end
                            writeSP("enableMouseoverHighlight", val)
                            -- Hide overlay on all frames immediately when disabled
                            if not val then
                                for f in pairs(self.activeFrames or {}) do
                                    if f.mouseoverHighlight then
                                        f.mouseoverHighlight:SetColorTexture(1, 1, 1, 0)
                                    end
                                end
                            end
                        end,
                        disabled=InCombatLockdown,
                    },
                    mouseoverHighlightColor = {
                        type="color", name="Mouseover Highlight Color", order=4, hasAlpha=false,
                        disabled=function() return InCombatLockdown() or not getSPKey("enableMouseoverHighlight") end,
                        get=function() local c = getSPKey("mouseoverHighlightColor") or {r=1,g=1,b=1}; return c.r, c.g, c.b end,
                        set=function(_, r, g, b)
                            if InCombatLockdown() then return end
                            local c = getSPKey("mouseoverHighlightColor")
                            if c then
                                c.r, c.g, c.b = r, g, b
                            else
                                writeSP("mouseoverHighlightColor", { r=r, g=g, b=b })
                            end
                        end,
                    },
                    mouseoverHighlightOpacity = {
                        type="range", name="Mouseover Highlight Opacity", order=5, min=0.05, max=0.5, step=0.05,
                        disabled=function() return InCombatLockdown() or not getSPKey("enableMouseoverHighlight") end,
                        get=get,
                        set=function(info, val)
                            if InCombatLockdown() then return end
                            writeSP("mouseoverHighlightOpacity", val)
                        end,
                    },
                },
            },
            debuffTab = {
                type = "group", name = "Debuff Highlight", order = 5,
                args = {
                    _debuffSectionTracker = {
                        type = "description", order = 0, width = "full",
                        name = function()
                            if self._currentSection ~= "dispelDebuffBorder" then
                                self._currentSection = "dispelDebuffBorder"
                                if not InCombatLockdown() then NotifyChangeSafe() end
                            end
                            return ""
                        end,
                    },
                    goToDispelIndicatorNote = {
                        type="description", order=0.5,
                        name="Debuff Highlight settings have moved to Auras -> Dispellable Debuffs subtab.",
                    },
                    goToDispelIndicator = {
                        type="execute", name="Dispellable Debuffs settings", order=1,
                        desc="Open the Auras -> Dispellable Debuffs tab to configure the dispel indicator and debuff highlight/overlay shown on unit frames.",
                        func=function()
                            local ACD = LibStub("AceConfigDialog-3.0", true)
                            if not ACD then return end
                            if self ~= BF then
                                -- CFG context: navigate to the CFG auras dispel tab
                                ACD:SelectGroup("BuzzardFrames", "customFrames", "auras", "tabDispel")
                            else
                                ACD:SelectGroup("BuzzardFrames", "raidPartyFrames", "auras", "tabDispel")
                            end
                        end,
                    },
                },
            },
        },
    }
end
