-- ============================================================
-- BuzzardFrames: Options_Icons.lua
-- Builds and returns the "Icons" nav-tab args table.
-- Called from Options.lua: BF:BuildIconsOptions(deps)
--
-- Storage: rpDB.profile.icons.* (global pseudo-layout) or flat.icons.*
-- when layouts.perLayoutToggles.icons is true. ALL widgets read/write
-- through the getIP() helper which routes via
--   BF:GetSectionProfile("icons", GetModifyingProfile())
-- so per-layout ON/OFF is transparent to the widget definitions.
--
-- v26 (2026-04-18): fixed three latent data-location bugs:
--   (a) Most toggle/scalar widgets used direct BF.rpDB.profile.icons
--       access and deps.get=deps.set pairs that wrote to self.db.profile.
--       Widgets read/wrote inconsistent locations. Every widget now
--       routes through GetSectionProfile("icons", ...) so per-layout
--       routing is transparent. See Core_Migrations.lua
--       MigrateIconsLocation.
--   (b) Missing-raid-buff keys (8 keys: showMissingRaidBuff,
--       showMissingSymbiotic, showMissingRaidBuffInCombat,
--       missingRaidBuff{Anchor,OffsetX,OffsetY,Size,ShowGlow}) were
--       written to BF.acDB.profile.* by the old widgets but runtime
--       read them from BF.rpDB.profile.icons.* (relocated in v15).
--       UI toggles never took effect. These keys now route through
--       getIP() alongside the rest of the Icons section. v26 migration
--       nils the acDB copies.
--   (c) Status-icon test toggles (testReadyCheck, testPhased,
--       testSummonPending, testResurrectPending, testVehicleIcon) used
--       deps.get/deps.set which read/wrote to self.db.profile, but
--       runtime reads from BF.db.global.* (relocated to global in v14).
--       UI toggles never took effect. These now read/write BF.db.global
--       directly and are reset to false on every reload (Core_DB.lua).
--       v26 migration nils the dead db.profile copies.
--
-- Per-layout note on "Missing Raid Buff Icon" tab: the feature works
-- on party frames too despite its name, so the tab stays visible for
-- both raid and party flats. No visibility gating like Text's "Labels"
-- sub-tab.
-- ============================================================
local BF = _G["BuzzardFrames"]

-- deps is a table of upvalue references passed in from RegisterOptions:
--   deps.self                      - the BF addon object
--   deps.NotifyChangeSafe          - local function from RegisterOptions
--   deps.get                       - makeRpGet("icons") (routed via GetSectionProfile)
--   deps.set                       - makeRpSet("icons") (routed via GetSectionProfile)
--   deps.safeLayout                - local function from RegisterOptions (unused here, kept for future)
--   deps.buildSectionCopyToDropdown- factory for the per-layout Copy Settings dropdown
function BF:BuildIconsOptions(deps)
    local self             = deps.self
    local NotifyChangeSafe = deps.NotifyChangeSafe
    local buildSectionCopyToDropdown = deps.buildSectionCopyToDropdown

    -- ── Routing helpers ─────────────────────────────────
    -- getIP() returns the currently-modifying flat's icons profile
    -- (flat.icons when per-layout is ON, rpDB.profile.icons when OFF).
    -- All reads/writes flow through this one helper.
    local function getIP()
        return self:GetSectionProfile("icons", self:GetModifyingProfile())
    end

    -- Info-based read -- used wherever a widget just needs the value
    -- for the key its info path names.
    local function getIPKey(info)
        local ip = getIP()
        return ip and ip[info[#info]]
    end

    -- Raw write helper used by every setter. Each setter then runs its
    -- specific side effects inline.
    local function writeIP(info, val)
        local ip = getIP()
        if ip then ip[info[#info]] = val end
    end

    -- ── Side-effect helpers ─────────────────────────────
    -- Reposition icons on all active frames without triggering a full RefreshAll.
    -- Safe to call from any option setter that only changes icon position/visibility.
    -- Also refreshes preview frames so per-layout Icons edits (size/position/anchor)
    -- re-run every indicator's :Layout on the preview frames via RefreshPreviewLayout.
    -- Without the preview call, only live frames would reposition and the options
    -- panel preview would stay stale.
    local function layoutFrames()
        for frame in pairs(self.activeFrames or {}) do
            self:LayoutFrame(frame)
        end
        if BF.RefreshPreviewLayout then BF:RefreshPreviewLayout() end
    end

    return {
        type        = "group",
        name        = "Icons",
        order       = 8,
        childGroups = "tab",
        args        = {
            _sectionTracker = {
                type = "description",
                name = function()
                    if self._currentSection ~= "icons" then
                        self._currentSection = "icons"
                        if not InCombatLockdown() then NotifyChangeSafe() end
                    end
                    return ""
                end,
                order = 0, width = "full",
            },

            -- ============================================================
            -- Role Icons sub-tab
            -- ============================================================
            roleIconsTab = {
                type = "group", name = "Role Icons", order = 1,
                args = {
                    showRoleIcons = {
                        type="toggle", name="Show Role Icons", order=2,
                        get=getIPKey,
                        set=function(info, val)
                            if InCombatLockdown() then return end
                            writeIP(info, val)
                            layoutFrames()
                            for f in pairs(self.activeFrames or {}) do self:UpdateRoleIcon(f) end
                            if BF.RefreshPreviewRoleIcon then BF:RefreshPreviewRoleIcon() end
                        end,
                        disabled=InCombatLockdown,
                    },
                    roleIconStyleSizeGroup = {
                        type="group", name="Style & Size", inline=true, order=3,
                        hidden=function() local ip = getIP(); return not (ip and ip.showRoleIcons) end,
                        args = {
                            roleIconStyle = {
                                type="select", name="Role Icon Style", order=1,
                                desc="Choose between modern 10.1.5 icons, classic circular icons, or small atlas icons",
                                values={ MODERN="Modern (10.1.5+)", BLIZZARD="Blizzard Circular (Classic)", TINY="Tiny Atlas Icons" },
                                disabled=InCombatLockdown,
                                get=getIPKey,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    writeIP(info, val)
                                    for f in pairs(self.activeFrames or {}) do self:UpdateRoleIcon(f) end
                                    if BF.RefreshPreviewRoleIcon then BF:RefreshPreviewRoleIcon() end
                                end,
                            },
                            roleIconSize = {
                                type="range", name="Role Icon Size", order=2, min=6, max=24, step=1,
                                disabled=InCombatLockdown,
                                get=getIPKey,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    writeIP(info, val)
                                    layoutFrames()
                                end,
                            },
                        },
                    },
                    roleIconPositionGroup = {
                        type="group", name="Position", inline=true, order=5,
                        hidden=function() local ip = getIP(); return not (ip and ip.showRoleIcons) end,
                        args = {
                            point = {
                                type="select", name="Location", order=1,
                                values={ TOPLEFT="Top Left", TOP="Top", TOPRIGHT="Top Right", LEFT="Left", CENTER="Center", RIGHT="Right", BOTTOMLEFT="Bottom Left", BOTTOM="Bottom", BOTTOMRIGHT="Bottom Right" },
                                disabled=InCombatLockdown,
                                get=function() local ip = getIP(); return ip and ip.roleIconPosition and ip.roleIconPosition.point end,
                                set=function(_, v)
                                    if InCombatLockdown() then return end
                                    local ip = getIP()
                                    if ip and ip.roleIconPosition then ip.roleIconPosition.point = v end
                                    layoutFrames()
                                end,
                            },
                            x = {
                                type="range", name="X Offset", order=2, min=-50, max=50, step=1,
                                disabled=InCombatLockdown,
                                get=function() local ip = getIP(); return ip and ip.roleIconPosition and ip.roleIconPosition.x end,
                                set=function(_, v)
                                    if InCombatLockdown() then return end
                                    local ip = getIP()
                                    if ip and ip.roleIconPosition then ip.roleIconPosition.x = v end
                                    layoutFrames()
                                end,
                            },
                            y = {
                                type="range", name="Y Offset", order=3, min=-50, max=50, step=1,
                                disabled=InCombatLockdown,
                                get=function() local ip = getIP(); return ip and ip.roleIconPosition and ip.roleIconPosition.y end,
                                set=function(_, v)
                                    if InCombatLockdown() then return end
                                    local ip = getIP()
                                    if ip and ip.roleIconPosition then ip.roleIconPosition.y = v end
                                    layoutFrames()
                                end,
                            },
                        },
                    },
                    showPerRoleGroup = {
                        type="group", name="Show Per-Role", inline=true, order=6,
                        hidden=function() local ip = getIP(); return not (ip and ip.showRoleIcons) end,
                        args = {
                            showRoleIconTank = {
                                type="toggle", name="Show Tank Icons", order=1,
                                desc="Show role icon for units assigned as Tank.",
                                disabled=InCombatLockdown,
                                get=getIPKey,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    writeIP(info, val)
                                    for f in pairs(self.activeFrames or {}) do self:UpdateRoleIcon(f) end
                                    if BF.RefreshPreviewRoleIcon then BF:RefreshPreviewRoleIcon() end
                                end,
                            },
                            showRoleIconHealer = {
                                type="toggle", name="Show Healer Icons", order=2,
                                desc="Show role icon for units assigned as Healer.",
                                disabled=InCombatLockdown,
                                get=getIPKey,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    writeIP(info, val)
                                    for f in pairs(self.activeFrames or {}) do self:UpdateRoleIcon(f) end
                                    if BF.RefreshPreviewRoleIcon then BF:RefreshPreviewRoleIcon() end
                                end,
                            },
                            showRoleIconDPS = {
                                type="toggle", name="Show DPS Icons", order=3,
                                desc="Show role icon for units assigned as DPS.",
                                disabled=InCombatLockdown,
                                get=getIPKey,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    writeIP(info, val)
                                    for f in pairs(self.activeFrames or {}) do self:UpdateRoleIcon(f) end
                                    if BF.RefreshPreviewRoleIcon then BF:RefreshPreviewRoleIcon() end
                                end,
                            },
                        },
                    },
                },
            },

            -- ============================================================
            -- Raid Target Markers sub-tab
            -- ============================================================
            raidTargetTab = {
                type = "group", name = "Raid Target Markers", order = 2,
                args = {
                    showRaidTargetIcon = {
                        type="toggle", name="Show Raid Target Icon", order=11,
                        get=getIPKey,
                        set=function(info, val)
                            if InCombatLockdown() then return end
                            writeIP(info, val)
                            for f in pairs(self.activeFrames or {}) do self:UpdateRaidTargetIcon(f) end
                        end,
                        disabled=InCombatLockdown,
                    },
                    raidTargetIconSize = {
                        type="range", name="Raid Target Icon Size", order=12, min=8, max=32, step=1,
                        disabled=function() local ip = getIP(); return InCombatLockdown() or not (ip and ip.showRaidTargetIcon) end,
                        get=getIPKey,
                        set=function(info, val)
                            if InCombatLockdown() then return end
                            writeIP(info, val)
                            layoutFrames()
                        end,
                    },
                    raidTargetIconPositionGroup = {
                        type="group", name="Raid Target Icon Position", inline=true, order=13,
                        disabled=function() local ip = getIP(); return InCombatLockdown() or not (ip and ip.showRaidTargetIcon) end,
                        args = {
                            point = {
                                type="select", name="Location", order=1,
                                values={ TOPLEFT="Top Left", TOP="Top", TOPRIGHT="Top Right", LEFT="Left", CENTER="Center", RIGHT="Right", BOTTOMLEFT="Bottom Left", BOTTOM="Bottom", BOTTOMRIGHT="Bottom Right" },
                                get=function() local ip = getIP(); return ip and ip.raidTargetIconPosition and ip.raidTargetIconPosition.point end,
                                set=function(_, v)
                                    if InCombatLockdown() then return end
                                    local ip = getIP()
                                    if ip and ip.raidTargetIconPosition then ip.raidTargetIconPosition.point = v end
                                    layoutFrames()
                                end,
                            },
                            x = {
                                type="range", name="X Offset", order=2, min=-50, max=50, step=1,
                                get=function() local ip = getIP(); return ip and ip.raidTargetIconPosition and ip.raidTargetIconPosition.x end,
                                set=function(_, v)
                                    if InCombatLockdown() then return end
                                    local ip = getIP()
                                    if ip and ip.raidTargetIconPosition then ip.raidTargetIconPosition.x = v end
                                    layoutFrames()
                                end,
                            },
                            y = {
                                type="range", name="Y Offset", order=3, min=-50, max=50, step=1,
                                get=function() local ip = getIP(); return ip and ip.raidTargetIconPosition and ip.raidTargetIconPosition.y end,
                                set=function(_, v)
                                    if InCombatLockdown() then return end
                                    local ip = getIP()
                                    if ip and ip.raidTargetIconPosition then ip.raidTargetIconPosition.y = v end
                                    layoutFrames()
                                end,
                            },
                        },
                    },
                },
            },

            -- ============================================================
            -- Leader/Assistant sub-tab
            -- ============================================================
            leaderAssistantTab = {
                type = "group", name = "Leader/Assistant", order = 3,
                args = {
                    leaderHeader = { type="header", name="Leader Icon", order=20 },
                    showLeaderIcon = {
                        type="toggle", name="Show Leader Icon", order=21,
                        get=getIPKey,
                        set=function(info, val)
                            if InCombatLockdown() then return end
                            writeIP(info, val)
                            for f in pairs(self.activeFrames or {}) do self:UpdateLeaderIcon(f) end
                        end,
                        disabled=InCombatLockdown,
                    },
                    leaderIconSize = {
                        type="range", name="Leader Icon Size", order=22, min=8, max=24, step=1,
                        disabled=function() local ip = getIP(); return InCombatLockdown() or not (ip and ip.showLeaderIcon) end,
                        get=getIPKey,
                        set=function(info, val)
                            if InCombatLockdown() then return end
                            writeIP(info, val)
                            layoutFrames()
                        end,
                    },
                    leaderIconPositionGroup = {
                        type="group", name="Leader Icon Position", inline=true, order=23,
                        disabled=function() local ip = getIP(); return InCombatLockdown() or not (ip and ip.showLeaderIcon) end,
                        args = {
                            point = {
                                type="select", name="Location", order=1,
                                values={ TOPLEFT="Top Left", TOP="Top", TOPRIGHT="Top Right", LEFT="Left", CENTER="Center", RIGHT="Right", BOTTOMLEFT="Bottom Left", BOTTOM="Bottom", BOTTOMRIGHT="Bottom Right" },
                                get=function() local ip = getIP(); return ip and ip.leaderIconPosition and ip.leaderIconPosition.point end,
                                set=function(_, v)
                                    if InCombatLockdown() then return end
                                    local ip = getIP()
                                    if ip and ip.leaderIconPosition then ip.leaderIconPosition.point = v end
                                    layoutFrames()
                                end,
                            },
                            x = {
                                type="range", name="X Offset", order=2, min=-50, max=50, step=1,
                                get=function() local ip = getIP(); return ip and ip.leaderIconPosition and ip.leaderIconPosition.x end,
                                set=function(_, v)
                                    if InCombatLockdown() then return end
                                    local ip = getIP()
                                    if ip and ip.leaderIconPosition then ip.leaderIconPosition.x = v end
                                    layoutFrames()
                                end,
                            },
                            y = {
                                type="range", name="Y Offset", order=3, min=-50, max=50, step=1,
                                get=function() local ip = getIP(); return ip and ip.leaderIconPosition and ip.leaderIconPosition.y end,
                                set=function(_, v)
                                    if InCombatLockdown() then return end
                                    local ip = getIP()
                                    if ip and ip.leaderIconPosition then ip.leaderIconPosition.y = v end
                                    layoutFrames()
                                end,
                            },
                        },
                    },
                    assistantSpacer = { type="description", name="", order=24.5 },
                    assistantHeader = { type="header", name="Assistant Icon", order=25 },
                    showAssistantIcon = {
                        type="toggle", name="Show Assistant Icon", order=26,
                        get=getIPKey,
                        set=function(info, val)
                            if InCombatLockdown() then return end
                            writeIP(info, val)
                            for f in pairs(self.activeFrames or {}) do self:UpdateLeaderIcon(f) end
                        end,
                        disabled=InCombatLockdown,
                    },
                    assistantIconSize = {
                        type="range", name="Assistant Icon Size", order=27, min=8, max=24, step=1,
                        disabled=function() local ip = getIP(); return InCombatLockdown() or not (ip and ip.showAssistantIcon) end,
                        get=getIPKey,
                        set=function(info, val)
                            if InCombatLockdown() then return end
                            writeIP(info, val)
                            layoutFrames()
                        end,
                    },
                    assistantIconPositionGroup = {
                        type="group", name="Assistant Icon Position", inline=true, order=28,
                        disabled=function() local ip = getIP(); return InCombatLockdown() or not (ip and ip.showAssistantIcon) end,
                        args = {
                            point = {
                                type="select", name="Location", order=1,
                                values={ TOPLEFT="Top Left", TOP="Top", TOPRIGHT="Top Right", LEFT="Left", CENTER="Center", RIGHT="Right", BOTTOMLEFT="Bottom Left", BOTTOM="Bottom", BOTTOMRIGHT="Bottom Right" },
                                get=function() local ip = getIP(); return ip and ip.assistantIconPosition and ip.assistantIconPosition.point end,
                                set=function(_, v)
                                    if InCombatLockdown() then return end
                                    local ip = getIP()
                                    if ip and ip.assistantIconPosition then ip.assistantIconPosition.point = v end
                                    layoutFrames()
                                end,
                            },
                            x = {
                                type="range", name="X Offset", order=2, min=-50, max=50, step=1,
                                get=function() local ip = getIP(); return ip and ip.assistantIconPosition and ip.assistantIconPosition.x end,
                                set=function(_, v)
                                    if InCombatLockdown() then return end
                                    local ip = getIP()
                                    if ip and ip.assistantIconPosition then ip.assistantIconPosition.x = v end
                                    layoutFrames()
                                end,
                            },
                            y = {
                                type="range", name="Y Offset", order=3, min=-50, max=50, step=1,
                                get=function() local ip = getIP(); return ip and ip.assistantIconPosition and ip.assistantIconPosition.y end,
                                set=function(_, v)
                                    if InCombatLockdown() then return end
                                    local ip = getIP()
                                    if ip and ip.assistantIconPosition then ip.assistantIconPosition.y = v end
                                    layoutFrames()
                                end,
                            },
                        },
                    },
                },
            },

            -- ============================================================
            -- Missing Raid Buff Icon sub-tab
            -- Note: this feature works on both party and raid frames.
            -- The "Raid" in the name is historical. Tab stays visible for
            -- party flats when per-layout is ON (no visibility gating).
            -- All 8 keys (showMissingRaidBuff, showMissingSymbiotic,
            -- showMissingRaidBuffInCombat, missingRaidBuffAnchor,
            -- missingRaidBuffOffsetX/Y, missingRaidBuffSize,
            -- missingRaidBuffShowGlow) live in rpDB.icons as of v15
            -- runtime reads; the UI was still writing them to acDB until
            -- v26. Options widgets now route through getIP() alongside
            -- every other Icons-section key.
            -- ============================================================
            missingRaidBuffTab = {
                type = "group", name = "Missing Raid Buff Icon", order = 7,
                args = {
                    showMissingRaidBuff = {
                        type     = "toggle",
                        name     = "Show Missing Raid Buff",
                        desc     = "Show a desaturated raid buff icon on units that are missing your class's raid buff.",
                        order    = 1,
                        disabled = InCombatLockdown,
                        get      = getIPKey,
                        set      = function(info, val)
                            if InCombatLockdown() then return end
                            writeIP(info, val)
                            BF:RefreshAllCustomContainersWithRebuild()
                        end,
                    },
                    showMissingSymbiotic = {
                        type     = "toggle",
                        name     = "Show Missing Symbiotic Relationship (Druid)",
                        desc     = "Show an indicator on the player frame when you have the Symbiotic Relationship talent but are missing the personal buff it grants.",
                        order    = 1.5,
                        disabled = InCombatLockdown,
                        get      = getIPKey,
                        set      = function(info, val)
                            if InCombatLockdown() then return end
                            writeIP(info, val)
                            BF:RefreshAllCustomContainersWithRebuild()
                        end,
                    },
                    showMissingRaidBuffInCombat = {
                        type     = "toggle",
                        name     = "Show in Combat",
                        desc     = "Also show the missing raid buff indicator during combat (e.g. for players who died and were resurrected).",
                        order    = 2,
                        hidden   = function() local ip = getIP(); return not (ip and (ip.showMissingRaidBuff or ip.showMissingSymbiotic)) end,
                        disabled = InCombatLockdown,
                        get      = getIPKey,
                        set      = function(info, val)
                            if InCombatLockdown() then return end
                            writeIP(info, val)
                            BF:RefreshAllCustomContainersWithRebuild()
                        end,
                    },
                    missingRaidBuffSizeGlowGroup = {
                        type   = "group",
                        name   = "Size & Glow",
                        order  = 2.5,
                        inline = true,
                        hidden = function() local ip = getIP(); return not (ip and (ip.showMissingRaidBuff or ip.showMissingSymbiotic)) end,
                        args   = {
                            missingRaidBuffSize = {
                                type     = "range",
                                name     = "Icon Size",
                                desc     = "Size of the missing raid buff icon in pixels.",
                                order    = 1,
                                min = 2, max = 40, step = 1,
                                disabled = InCombatLockdown,
                                get      = function() local ip = getIP(); return (ip and ip.missingRaidBuffSize) or 12 end,
                                set      = function(info, val)
                                    if InCombatLockdown() then return end
                                    writeIP(info, val)
                                    if BF.RefreshMissingRaidBuffOnly then BF:RefreshMissingRaidBuffOnly() else BF:RefreshAllAuras() end
                                end,
                            },
                            missingRaidBuffShowGlow = {
                                type     = "toggle",
                                name     = "Show Glow",
                                desc     = "Show an action button glow effect on the missing raid buff icon.",
                                order    = 2,
                                disabled = InCombatLockdown,
                                get      = getIPKey,
                                set      = function(info, val)
                                    if InCombatLockdown() then return end
                                    writeIP(info, val)
                                    if BF.RefreshMissingRaidBuffOnly then BF:RefreshMissingRaidBuffOnly() else BF:RefreshAllAuras() end
                                end,
                            },
                        },
                    },
                    missingRaidBuffPositionGroup = {
                        type   = "group",
                        name   = "Position",
                        order  = 3,
                        inline = true,
                        hidden = function() local ip = getIP(); return not (ip and (ip.showMissingRaidBuff or ip.showMissingSymbiotic)) end,
                        args   = {
                            missingRaidBuffAnchor = {
                                type     = "select",
                                name     = "Anchor Point",
                                order    = 1,
                                values   = { TOPLEFT="Top Left", TOP="Top", TOPRIGHT="Top Right",
                                             LEFT="Left", CENTER="Center", RIGHT="Right",
                                             BOTTOMLEFT="Bottom Left", BOTTOM="Bottom", BOTTOMRIGHT="Bottom Right" },
                                disabled = InCombatLockdown,
                                get      = function() local ip = getIP(); return (ip and ip.missingRaidBuffAnchor) or "CENTER" end,
                                set      = function(_, val)
                                    if InCombatLockdown() then return end
                                    local ip = getIP()
                                    if ip then ip.missingRaidBuffAnchor = val end
                                    if BF.RefreshMissingRaidBuffOnly then BF:RefreshMissingRaidBuffOnly() else BF:RefreshAllAuras() end
                                end,
                            },
                            missingRaidBuffOffsetX = {
                                type     = "range",
                                name     = "X Offset",
                                order    = 2,
                                min = -60, max = 60, step = 1,
                                disabled = InCombatLockdown,
                                get      = function() local ip = getIP(); return (ip and ip.missingRaidBuffOffsetX) or 0 end,
                                set      = function(_, val)
                                    if InCombatLockdown() then return end
                                    local ip = getIP()
                                    if ip then ip.missingRaidBuffOffsetX = val end
                                    if BF.RefreshMissingRaidBuffOnly then BF:RefreshMissingRaidBuffOnly() else BF:RefreshAllAuras() end
                                end,
                            },
                            missingRaidBuffOffsetY = {
                                type     = "range",
                                name     = "Y Offset",
                                order    = 3,
                                min = -60, max = 60, step = 1,
                                disabled = InCombatLockdown,
                                get      = function() local ip = getIP(); return (ip and ip.missingRaidBuffOffsetY) or 0 end,
                                set      = function(_, val)
                                    if InCombatLockdown() then return end
                                    local ip = getIP()
                                    if ip then ip.missingRaidBuffOffsetY = val end
                                    if BF.RefreshMissingRaidBuffOnly then BF:RefreshMissingRaidBuffOnly() else BF:RefreshAllAuras() end
                                end,
                            },
                        },
                    },
                },
            },

            -- ============================================================
            -- Status Icons sub-tab
            -- ============================================================
            -- Test toggles (testReadyCheck/testPhased/testSummonPending/
            -- testResurrectPending/testVehicleIcon) are GLOBAL debug flags
            -- that live on BF.db.global. They are reset to false on every
            -- reload (Core_DB.lua). Widgets read/write BF.db.global
            -- directly; they do NOT route through getIP() because they
            -- are not part of the per-layout icons profile.
            statusIconsTab = {
                type = "group", name = "Status Icons", order = 6,
                args = {
                    statusHeader = { type="header", name="Status Icons", order=20 },
                    showReadyCheck = {
                        type="toggle", name="Show Ready Check", order=21,
                        get=getIPKey,
                        set=function(info, val)
                            if InCombatLockdown() then return end
                            writeIP(info, val)
                            -- When turning OFF a Show toggle, also clear the
                            -- matching test toggle so a previously-enabled
                            -- test doesn't linger invisibly in the preview.
                            if not val and BF.db.global.testReadyCheck then
                                BF.db.global.testReadyCheck = false
                            end
                            for f in pairs(self.activeFrames or {}) do
                                if self.UpdateReadyCheck then self:UpdateReadyCheck(f) end
                            end
                            if BF.RefreshPreviewStatusIcons then BF:RefreshPreviewStatusIcons() end
                        end,
                        disabled=InCombatLockdown,
                    },
                    showPhased = {
                        type="toggle", name="Show Phased", order=23,
                        desc="Show an icon when a unit is in a different phase.",
                        get=getIPKey,
                        set=function(info, val)
                            if InCombatLockdown() then return end
                            writeIP(info, val)
                            if not val and BF.db.global.testPhased then
                                BF.db.global.testPhased = false
                            end
                            for f in pairs(self.activeFrames or {}) do self:UpdatePhased(f) end
                            if BF.RefreshPreviewStatusIcons then BF:RefreshPreviewStatusIcons() end
                        end,
                        disabled=InCombatLockdown,
                    },
                    showSummonPending = {
                        type="toggle", name="Show Summon Pending", order=24,
                        desc="Show an icon when a unit has a pending summon awaiting acceptance.",
                        get=getIPKey,
                        set=function(info, val)
                            if InCombatLockdown() then return end
                            writeIP(info, val)
                            if not val and BF.db.global.testSummonPending then
                                BF.db.global.testSummonPending = false
                            end
                            for f in pairs(self.activeFrames or {}) do
                                if self.UpdateSummonPending then self:UpdateSummonPending(f) end
                            end
                            if BF.RefreshPreviewStatusIcons then BF:RefreshPreviewStatusIcons() end
                        end,
                        disabled=InCombatLockdown,
                    },
                    showResurrectPending = {
                        type="toggle", name="Show Resurrection Pending", order=25,
                        desc="Show an icon when a unit has an incoming resurrection awaiting acceptance.",
                        get=getIPKey,
                        set=function(info, val)
                            if InCombatLockdown() then return end
                            writeIP(info, val)
                            if not val and BF.db.global.testResurrectPending then
                                BF.db.global.testResurrectPending = false
                            end
                            for f in pairs(self.activeFrames or {}) do
                                if self.UpdateResurrectPending then self:UpdateResurrectPending(f) end
                            end
                            -- ApplyPreviewStatus's dead-status branch reads
                            -- _rp_icons().showResurrectPending to decide whether
                            -- to show rezPendingIcon on the preview frame, so
                            -- toggling this needs a preview status refresh.
                            if BF.RefreshPreviewStatus then BF:RefreshPreviewStatus() end
                            if BF.RefreshPreviewStatusIcons then BF:RefreshPreviewStatusIcons() end
                        end,
                        disabled=InCombatLockdown,
                    },
                    showVehicleIcon = {
                        type="toggle", name="Show Vehicle Icon", order=26,
                        desc="Show an icon when a unit is in a vehicle.",
                        get=getIPKey,
                        set=function(info, val)
                            if InCombatLockdown() then return end
                            writeIP(info, val)
                            if not val and BF.db.global.testVehicleIcon then
                                BF.db.global.testVehicleIcon = false
                            end
                            for f in pairs(self.activeFrames or {}) do self:UpdateVehicle(f) end
                            if BF.RefreshPreviewStatusIcons then BF:RefreshPreviewStatusIcons() end
                        end,
                        disabled=InCombatLockdown,
                    },
                    statusIconPositionSpacer = { type="description", name="", order=29 },
                    statusIconPositionGroup = {
                        type="group", name="Status Icon Position", inline=true, order=30,
                        args = {
                            size = {
                                type="range", name="Size", order=1, min=8, max=40, step=1,
                                get=function() local ip = getIP(); return (ip and ip.statusIconSize) or 24 end,
                                set=function(info, v)
                                    if InCombatLockdown() then return end
                                    local ip = getIP()
                                    if ip then ip.statusIconSize = v end
                                    layoutFrames()
                                end,
                            },
                            point = {
                                type="select", name="Location", order=2,
                                values={ TOPLEFT="Top Left", TOP="Top", TOPRIGHT="Top Right", LEFT="Left", CENTER="Center", RIGHT="Right", BOTTOMLEFT="Bottom Left", BOTTOM="Bottom", BOTTOMRIGHT="Bottom Right" },
                                get=function() local ip = getIP(); return ip and ip.statusIconPosition and ip.statusIconPosition.point end,
                                set=function(_, v)
                                    if InCombatLockdown() then return end
                                    local ip = getIP()
                                    if ip and ip.statusIconPosition then ip.statusIconPosition.point = v end
                                    layoutFrames()
                                end,
                            },
                            x = {
                                type="range", name="X Offset", order=3, min=-50, max=50, step=1,
                                get=function() local ip = getIP(); return ip and ip.statusIconPosition and ip.statusIconPosition.x end,
                                set=function(_, v)
                                    if InCombatLockdown() then return end
                                    local ip = getIP()
                                    if ip and ip.statusIconPosition then ip.statusIconPosition.x = v end
                                    layoutFrames()
                                end,
                            },
                            y = {
                                type="range", name="Y Offset", order=4, min=-50, max=50, step=1,
                                get=function() local ip = getIP(); return ip and ip.statusIconPosition and ip.statusIconPosition.y end,
                                set=function(_, v)
                                    if InCombatLockdown() then return end
                                    local ip = getIP()
                                    if ip and ip.statusIconPosition then ip.statusIconPosition.y = v end
                                    layoutFrames()
                                end,
                            },
                        },
                    },
                    customizeIconsGroup = {
                        type="group", name="Customize Icons", inline=true, order=35,
                        args = {
                            resurrectPendingIconStyle = {
                                type="select", name="Resurrection Pending Icon", order=1,
                                values={ blizzard="Blizzard", buzzard="Buzzard" },
                                sorting={ "blizzard", "buzzard" },
                                get=function() local ip = getIP(); return (ip and ip.resurrectPendingIconStyle) or "blizzard" end,
                                set=function(_, val)
                                    if InCombatLockdown() then return end
                                    local ip = getIP()
                                    if ip then ip.resurrectPendingIconStyle = val end
                                    for f in pairs(self.activeFrames or {}) do
                                        self:LayoutFrame(f)
                                    end
                                    if BF.RefreshPreviewStatusIcons then BF:RefreshPreviewStatusIcons() end
                                end,
                                disabled=function() return InCombatLockdown() or not (getIP() and getIP().showResurrectPending) end,
                            },
                        },
                    },
                    testStatusIconsHeader = { type="header", name="Test Status Icons", order=40 },
                    -- Test toggles: GLOBAL debug flags (BF.db.global.*).
                    -- Runtime reads from db.global (Indicators/StatusIcons.lua);
                    -- reset to false on every reload (Core_DB.lua).
                    testReadyCheck = {
                        type="toggle", name="Test Ready Check", order=41,
                        get=function() return BF.db.global.testReadyCheck end,
                        set=function(_, val)
                            if InCombatLockdown() then return end
                            BF.db.global.testReadyCheck = val
                            for f in pairs(self.activeFrames or {}) do
                                if self.UpdateReadyCheck then self:UpdateReadyCheck(f) end
                            end
                            if BF.RefreshPreviewStatusIcons then BF:RefreshPreviewStatusIcons() end
                        end,
                        disabled=InCombatLockdown,
                        hidden=function() local ip = getIP(); return not (ip and ip.showReadyCheck) end,
                    },
                    testPhased = {
                        type="toggle", name="Test Phased", order=43,
                        get=function() return BF.db.global.testPhased end,
                        set=function(_, val)
                            if InCombatLockdown() then return end
                            BF.db.global.testPhased = val
                            for f in pairs(self.activeFrames or {}) do
                                if self.UpdatePhased then self:UpdatePhased(f) end
                            end
                            if BF.RefreshPreviewStatusIcons then BF:RefreshPreviewStatusIcons() end
                        end,
                        disabled=InCombatLockdown,
                        hidden=function() local ip = getIP(); return not (ip and ip.showPhased) end,
                    },
                    testSummonPending = {
                        type="toggle", name="Test Summon Pending", order=44,
                        get=function() return BF.db.global.testSummonPending end,
                        set=function(_, val)
                            if InCombatLockdown() then return end
                            BF.db.global.testSummonPending = val
                            for f in pairs(self.activeFrames or {}) do
                                if self.UpdateSummonPending then self:UpdateSummonPending(f) end
                            end
                            if BF.RefreshPreviewStatusIcons then BF:RefreshPreviewStatusIcons() end
                        end,
                        disabled=InCombatLockdown,
                        hidden=function() local ip = getIP(); return not (ip and ip.showSummonPending) end,
                    },
                    testResurrectPending = {
                        type="toggle", name="Test Resurrection Pending", order=45,
                        get=function() return BF.db.global.testResurrectPending end,
                        set=function(_, val)
                            if InCombatLockdown() then return end
                            BF.db.global.testResurrectPending = val
                            for f in pairs(self.activeFrames or {}) do
                                if self.UpdateResurrectPending then self:UpdateResurrectPending(f) end
                            end
                            if BF.RefreshPreviewStatusIcons then BF:RefreshPreviewStatusIcons() end
                        end,
                        disabled=InCombatLockdown,
                        hidden=function() local ip = getIP(); return not (ip and ip.showResurrectPending) end,
                    },
                    testVehicleIcon = {
                        type="toggle", name="Test Vehicle Icon", order=46,
                        get=function() return BF.db.global.testVehicleIcon end,
                        set=function(_, val)
                            if InCombatLockdown() then return end
                            BF.db.global.testVehicleIcon = val
                            for f in pairs(self.activeFrames or {}) do
                                if self.UpdateVehicle then self:UpdateVehicle(f) end
                            end
                            if BF.RefreshPreviewStatusIcons then BF:RefreshPreviewStatusIcons() end
                        end,
                        disabled=InCombatLockdown,
                        hidden=function() local ip = getIP(); return not (ip and ip.showVehicleIcon) end,
                    },
                },
            },
        },
    }
end

