-- ============================================================
-- BuzzardFrames: Options_Frames_Sorting.lua
-- Builds and returns the "Frames - Sorting" nav-tab args table.
-- Called from Options.lua: BF:BuildFramesSortingOptions(deps)
--
-- These settings were previously housed in the "Raid Layout" subtab
-- under "Layouts" (and the Party Layout widgets on the Frames tab).
-- They now live at the top level of the nav tree, between "Frames"
-- and "Auras" (order = 1.5).
--
-- Storage: rpDB.profile.sorting.* (global pseudo-layout) or
-- flat.sorting.* when layouts.perLayoutToggles.sorting is true. All
-- get/set handlers route through BF:GetSectionProfile("sorting", flat)
-- so the routing is transparent to the widget definitions.
--
-- Section visibility:
--   Per-layout toggle OFF (global):
--     Both Party Layout and Raid Layout sections show, because the
--     global settings affect every flat regardless of type.
--   Per-layout toggle ON:
--     Only the section matching the modifying flat's type shows.
--     Editing a party flat hides the Raid Layout section, and vice
--     versa -- keys in the hidden section aren't reachable for that
--     flat type anyway.
-- ============================================================
local BF = _G["BuzzardFrames"]

-- deps is a table of upvalue references passed in from RegisterOptions:
--   deps.self                      - the BF addon object
--   deps.buildSectionCopyToDropdown- factory for the Copy Settings dropdown
function BF:BuildFramesSortingOptions(deps)
    local self = deps.self
    local buildSectionCopyToDropdown = deps.buildSectionCopyToDropdown

    -- Read path: always the currently-modifying flat. When the per-layout
    -- toggle is OFF, GetSectionProfile ignores the flat argument and
    -- returns the global rpDB.profile.sorting. When ON, it returns
    -- flat.sorting so the user sees and edits the per-flat copy.
    local function getSP()
        local flat = self:GetModifyingProfile()
        return self:GetSectionProfile("sorting", flat)
    end

    -- Section visibility helpers. Both return false (show) when the
    -- per-layout toggle is OFF, so the global view shows every widget.
    -- When ON, they hide the section that does not match the modifying
    -- flat's type.
    local function hidePartySection()
        if not self:IsPerLayoutSection("sorting") then return false end
        local flat = self:GetModifyingProfile()
        return flat and flat.type == "raid" or false
    end
    local function hideRaidSection()
        if not self:IsPerLayoutSection("sorting") then return false end
        local flat = self:GetModifyingProfile()
        return flat and flat.type == "party" or false
    end

    -- Return the anchor frame whose geometry should be read for position
    -- calculations. In setup mode the test anchor is the one sized to
    -- match the displayed layout; the real anchor may have a stale size.
    local function getVisibleAnchor()
        if self.db and self.db.global and self.db.global.setupModeActive
           and self.testAnchorFrame then
            return self.testAnchorFrame
        end
        return self.anchorFrame
    end

    -- FrameSort override checks.
    -- Context-aware: true when FrameSort is actively overriding right now.
    -- Used by disabled= on controls (can't change settings while overridden).
    local function isFrameSortOverridingParty()
        return self.IsFrameSortOverridingParty and self:IsFrameSortOverridingParty() or false
    end

    local function isFrameSortOverridingRaid()
        return self.IsFrameSortOverridingRaid and self:IsFrameSortOverridingRaid() or false
    end

    -- Settings-based: true when FrameSort has ANY relevant area enabled,
    -- regardless of current context. Used by the red warning note so it
    -- shows even when the user is in a different context (e.g. show the
    -- raid warning while solo, if FrameSort Raid is enabled).
    local function isFrameSortEnabledForParty()
        return self.IsFrameSortEnabledForParty and self:IsFrameSortEnabledForParty() or false
    end

    local function isFrameSortEnabledForRaid()
        return self.IsFrameSortEnabledForRaid and self:IsFrameSortEnabledForRaid() or false
    end

    local function partyDisabledByFrameSort()
        return InCombatLockdown() or isFrameSortOverridingParty()
    end

    local function raidDisabledByFrameSort()
        return InCombatLockdown() or isFrameSortOverridingRaid()
    end

    return {
        type  = "group",
        name  = "Frames - Sorting",
        order = 1.5,
        args  = {
            partyHeader = { type="header", name="Party Layout", order=1, hidden=hidePartySection },
            partyFrameSortNote = {
                type="description", order=1.01,
                name=function()
                    local areas = self.GetFrameSortEnabledPartyAreas and self:GetFrameSortEnabledPartyAreas()
                    local areaStr = areas and table.concat(areas, ", ") or ""
                    return "|cffff4444FrameSort is managing sort order for: " .. areaStr .. ". The sorting settings below will not apply in those contexts. Due to a FrameSort limitation, players joining the group while in combat will not be visible until combat ends.|r"
                end,
                hidden=function() return hidePartySection() or not isFrameSortEnabledForParty() end,
                fontSize="medium",
            },
            partySortingGroup = {
                type="group", name="Party Sorting", inline=true, order=1.1,
                hidden=hidePartySection,
                args = {
                    groupOrderingMode = {
                        type="select", name="Role Order", order=1,
                        desc="Order in which roles appear in the party layout.",
                        values={
                            TANK_HEALER_DPS = "Tank / Healer / DPS",
                            HEALER_TANK_DPS = "Healer / Tank / DPS",
                            HEALER_DPS_TANK = "Healer / DPS / Tank",
                            TANK_DPS_HEALER = "Tank / DPS / Healer",
                            DPS_TANK_HEALER = "DPS / Tank / Healer",
                            DPS_HEALER_TANK = "DPS / Healer / Tank",
                        },
                        sorting={ "TANK_HEALER_DPS", "HEALER_TANK_DPS", "HEALER_DPS_TANK",
                                  "TANK_DPS_HEALER", "DPS_TANK_HEALER", "DPS_HEALER_TANK" },
                        get=function() local sp = getSP(); return sp and sp.groupOrderingMode or "TANK_HEALER_DPS" end,
                        set=function(_, val)
                            if InCombatLockdown() then return end
                            local sp = getSP(); if not sp then return end
                            sp.groupOrderingMode = val
                            self:ReloadLayout(true)
                            if self.UpdateSetupFrames then self:UpdateSetupFrames() end
                        end,
                        disabled=partyDisabledByFrameSort,
                    },
                    hideSelf = {
                        type="toggle", name="Hide Self", order=2,
                        desc="Hide your own frame from the party layout.",
                        get=function() local sp = getSP(); return sp and sp.hideSelf end,
                        set=function(_, val)
                            if InCombatLockdown() then return end
                            local sp = getSP(); if not sp then return end
                            sp.hideSelf = val and true or false
                            self:ReloadLayout(true)
                            if self.UpdateSetupFrames then self:UpdateSetupFrames() end
                        end,
                        disabled=partyDisabledByFrameSort,
                    },
                },
            },
            partyGrowDirectionGroup = {
                type="group", name="Party Grow Direction", inline=true, order=1.2,
                hidden=hidePartySection,
                args = {
                    partyGrowDirection = {
                        type="select", name="Grow Direction", order=1,
                        desc="Which direction party frames grow from the anchor point.",
                        values={
                            RIGHT = "Right (horizontal)",
                            LEFT  = "Left (horizontal)",
                            DOWN  = "Down (vertical)",
                            UP    = "Up (vertical)",
                        },
                        sorting={ "RIGHT", "LEFT", "DOWN", "UP" },
                        get=function() local sp = getSP(); return sp and sp.growDirection or "RIGHT" end,
                        set=function(_, val)
                            if InCombatLockdown() then return end
                            local sp = getSP(); if not sp then return end
                            sp.growDirection = val
                            local flat = self:GetModifyingProfile()
                            if flat and flat.type == "party" then
                                local newLA = self:DeriveGroupAnchor(val, nil)
                                local af = getVisibleAnchor()
                                if af and af:GetLeft() then
                                    local ux, uy = UIParent:GetCenter()
                                    local newX = newLA:find("LEFT") and af:GetLeft() or af:GetRight()
                                    local newY = newLA:find("TOP") and af:GetTop() or af:GetBottom()
                                    if newX and newY and ux and uy then
                                        local nx = math.floor(newX - ux + 0.5)
                                        local ny = math.floor(newY - uy + 0.5)
                                        flat.anchorX = nx
                                        flat.anchorY = ny
                                    end
                                end
                                flat.partyLayoutAnchor = newLA
                            end
                            self:ReloadLayout(true)
                            if self.UpdateAnchorPosition then self:UpdateAnchorPosition() end
                            if self.UpdateSetupFrames then self:UpdateSetupFrames() end
                        end,
                        disabled=partyDisabledByFrameSort,
                    },
                    -- Layout Anchor is auto-derived from Grow Direction; hidden from UI.
                    partyLayoutAnchor = {
                        type="select", name="Layout Anchor", order=2,
                        desc="Which corner of the layout rectangle stays fixed on screen. When you change Grow Direction, frames rearrange within the same bounding box because this corner stays pinned.",
                        values={
                            TOPLEFT     = "Top Left",
                            TOPRIGHT    = "Top Right",
                            BOTTOMLEFT  = "Bottom Left",
                            BOTTOMRIGHT = "Bottom Right",
                        },
                        sorting={ "TOPLEFT", "TOPRIGHT", "BOTTOMLEFT", "BOTTOMRIGHT" },
                        get=function()
                            local flat = self:GetModifyingProfile()
                            return (flat and flat.partyLayoutAnchor) or "TOPLEFT"
                        end,
                        set=function(_, val)
                            if InCombatLockdown() then return end
                            local flat = self:GetModifyingProfile()
                            if not flat or flat.type ~= "party" then return end
                            local af = getVisibleAnchor()
                            if af and af:GetLeft() then
                                local ux, uy = UIParent:GetCenter()
                                local newX = val:find("LEFT") and af:GetLeft() or af:GetRight()
                                local newY = val:find("TOP") and af:GetTop() or af:GetBottom()
                                if newX and newY and ux and uy then
                                    local nx = math.floor(newX - ux + 0.5)
                                    local ny = math.floor(newY - uy + 0.5)
                                    flat.anchorX = nx
                                    flat.anchorY = ny
                                end
                            end
                            flat.partyLayoutAnchor = val
                            self:ReloadLayout(true)
                            if self.UpdateAnchorPosition then self:UpdateAnchorPosition() end
                            if self.UpdateSetupFrames then self:UpdateSetupFrames() end
                        end,
                        hidden=true,
                        disabled=InCombatLockdown,
                    },
                },
            },

            raidLayoutHeader = { type="header", name="Raid Layout", order=9.8, hidden=hideRaidSection },
            raidFrameSortNote = {
                type="description", order=9.9,
                name="|cffff4444FrameSort is managing sort order for Raid. The sorting settings below are being overridden. Strict Group Layout cannot be used when FrameSort is enabled. Due to a FrameSort limitation, players joining the group while in combat will not be visible until combat ends.|r",
                hidden=function() return hideRaidSection() or not isFrameSortEnabledForRaid() end,
                fontSize="medium",
            },
            raidSortingGroup = {
                type="group", name="Raid Sorting", inline=true, order=10,
                hidden=hideRaidSection,
                args = {
                    sortingMode = {
                        type="select", name="Sorting Mode", order=1,
                        desc="How to organize raid frames. Group keeps players in their assigned raid groups. Role groups by tank/healer/dps.",
                        values={ GROUP="By Group (1-8)", ROLE="By Role (Tank/Healer/DPS)" },
                        get=function() local sp = getSP(); return sp and sp.sortingMode end,
                        set=function(_, val)
                            if InCombatLockdown() then return end
                            local sp = getSP(); if not sp then return end
                            sp.sortingMode = val
                            self:ReloadLayout(true)
                            if self.UpdateSetupFrames then self:UpdateSetupFrames() end
                        end,
                        disabled=raidDisabledByFrameSort,
                    },
                    strictGroupLayout = {
                        type="toggle", name="Strict Group Layout", order=3,
                        desc="Each raid group always occupies its own column, even if the group isn't full. Only applies when sorting by Group.",
                        get=function() local sp = getSP(); return sp and sp.strictGroupLayout end,
                        set=function(_, val)
                            if InCombatLockdown() then return end
                            local sp = getSP(); if not sp then return end
                            sp.strictGroupLayout = val
                            self:ReloadLayout(true)
                            if self.UpdateSetupFrames then self:UpdateSetupFrames() end
                        end,
                        hidden=function()
                            local sp = getSP()
                            return sp and sp.sortingMode ~= "GROUP"
                        end,
                        disabled=raidDisabledByFrameSort,
                    },
                    strictGroupSortBy = {
                        type="select", name="Sort Within Groups", order=4,
                        desc="How to sort units within each raid group column when using strict group layout.",
                        values={ INDEX="Index", NAME="Name", ASSIGNEDROLE="Role", CLASS="Class" },
                        sorting={ "INDEX", "NAME", "ASSIGNEDROLE", "CLASS" },
                        get=function() local sp = getSP(); return (sp and sp.strictGroupSortBy) or "INDEX" end,
                        set=function(_, val)
                            if InCombatLockdown() then return end
                            local sp = getSP(); if not sp then return end
                            sp.strictGroupSortBy = (val ~= "INDEX") and val or nil
                            self:UpdatePartyFrames()
                        end,
                        hidden=function()
                            local sp = getSP()
                            return (sp and sp.sortingMode ~= "GROUP") or not (sp and sp.strictGroupLayout)
                        end,
                        disabled=raidDisabledByFrameSort,
                    },
                },
            },
            raidLayoutGroup = {
                type="group", name="Raid Grow Direction", inline=true, order=13,
                hidden=hideRaidSection,
                args = {
                    raidGrowDirection = {
                        type="select", name="Grow Direction", order=1,
                        desc="Which direction frames grow from the anchor point.",
                        values={
                            DOWN  = "Down (vertical)",
                            UP    = "Up (vertical)",
                            RIGHT = "Right (horizontal)",
                            LEFT  = "Left (horizontal)",
                        },
                        sorting={ "DOWN", "UP", "RIGHT", "LEFT" },
                        get=function()
                            local sp = getSP()
                            local dir = sp and sp.raidGrowDirection
                            if dir == "RIGHT" or dir == "UP" or dir == "LEFT" then return dir end
                            return "DOWN"
                        end,
                        set=function(_, val)
                            if InCombatLockdown() then return end
                            local sp = getSP(); if not sp then return end
                            -- Only reset secondary when orientation changes
                            -- (vertical↔horizontal). DOWN↔UP and RIGHT↔LEFT
                            -- stay on the same axis so the secondary is still valid.
                            local oldDir = sp.raidGrowDirection or "DOWN"
                            local oldH = (oldDir == "RIGHT" or oldDir == "LEFT")
                            local newH = (val == "RIGHT" or val == "LEFT")
                            if oldH ~= newH then
                                -- Reset to the default for the new axis.
                                -- Store explicitly rather than nil — with
                                -- per-layout ON, nil would expose the global's
                                -- stale value via __index fallback.
                                local defaultSec = newH and "DOWN" or "RIGHT"
                                sp.raidSecondaryGrowDirection = defaultSec
                            end
                            sp.raidGrowDirection = val
                            -- Auto-update raidLayoutAnchor to match the new grow direction
                            -- and recalculate anchorX/anchorY so frames don't shift.
                            -- Guard: only touch anchorX/Y and raidLayoutAnchor on raid flats.
                            -- When per-layout is OFF the modifying flat may be party-typed;
                            -- writing raid anchor coords onto a party flat would corrupt it.
                            local flat = self:GetModifyingProfile()
                            if flat and flat.type == "raid" then
                                local newLA = self:DeriveGroupAnchor(val, sp.raidSecondaryGrowDirection)
                                local af = getVisibleAnchor()
                                if af and af:GetLeft() then
                                    local ux, uy = UIParent:GetCenter()
                                    local newX = newLA:find("LEFT") and af:GetLeft() or af:GetRight()
                                    local newY = newLA:find("TOP") and af:GetTop() or af:GetBottom()
                                    if newX and newY and ux and uy then
                                        local nx = math.floor(newX - ux + 0.5)
                                        local ny = math.floor(newY - uy + 0.5)
                                        flat.anchorX = nx
                                        flat.anchorY = ny
                                    end
                                end
                                flat.raidLayoutAnchor = newLA
                            end
                            self:ReloadLayout(true)
                            if self.UpdateAnchorPosition then self:UpdateAnchorPosition() end
                            if self.UpdateSetupFrames then self:UpdateSetupFrames() end
                        end,
                        disabled=raidDisabledByFrameSort,
                    },
                    raidSecondaryGrowDirection = {
                        type="select", name="Secondary Grow Direction", order=1.5,
                        desc="Which direction groups/columns extend perpendicular to the primary grow direction.",
                        values=function()
                            local sp = getSP()
                            local dir = sp and sp.raidGrowDirection
                            if dir == "RIGHT" or dir == "LEFT" then
                                return { DOWN = "Down", UP = "Up" }
                            else
                                return { RIGHT = "Right", LEFT = "Left" }
                            end
                        end,
                        sorting=function()
                            local sp = getSP()
                            local dir = sp and sp.raidGrowDirection
                            if dir == "RIGHT" or dir == "LEFT" then
                                return { "DOWN", "UP" }
                            else
                                return { "RIGHT", "LEFT" }
                            end
                        end,
                        get=function()
                            local sp = getSP()
                            -- Use rawget to bypass the __index fallback to the
                            -- global sorting table. When per-layout is ON the
                            -- per-flat table inherits from the global via
                            -- __index; a nil rawkey would expose a stale global
                            -- value, causing the dropdown to show the wrong
                            -- selection (or blank if the global value doesn't
                            -- match the current primary axis).
                            local sec = sp and rawget(sp, "raidSecondaryGrowDirection")
                            if sec then return sec end
                            local dir = sp and sp.raidGrowDirection
                            if dir == "RIGHT" or dir == "LEFT" then return "DOWN" end
                            return "RIGHT"
                        end,
                        set=function(_, val)
                            if InCombatLockdown() then return end
                            local sp = getSP(); if not sp then return end
                            -- Always store the value explicitly rather than
                            -- nilling out defaults. With per-layout ON the
                            -- per-flat table has an __index fallback to the
                            -- global; rawset(sp, key, nil) would just expose
                            -- the global's (possibly stale) value.
                            sp.raidSecondaryGrowDirection = val
                            -- Auto-update raidLayoutAnchor to match the new grow direction
                            -- and recalculate anchorX/anchorY so frames don't shift.
                            -- Guard: only on raid flats (see raidGrowDirection setter).
                            local dir = sp.raidGrowDirection or "DOWN"
                            local flat = self:GetModifyingProfile()
                            if flat and flat.type == "raid" then
                                local newLA = self:DeriveGroupAnchor(dir, sp.raidSecondaryGrowDirection)
                                local af = getVisibleAnchor()
                                if af and af:GetLeft() then
                                    local ux, uy = UIParent:GetCenter()
                                    local newX = newLA:find("LEFT") and af:GetLeft() or af:GetRight()
                                    local newY = newLA:find("TOP") and af:GetTop() or af:GetBottom()
                                    if newX and newY and ux and uy then
                                        local nx = math.floor(newX - ux + 0.5)
                                        local ny = math.floor(newY - uy + 0.5)
                                        flat.anchorX = nx
                                        flat.anchorY = ny
                                    end
                                end
                                flat.raidLayoutAnchor = newLA
                            end
                            self:ReloadLayout(true)
                            if self.UpdateAnchorPosition then self:UpdateAnchorPosition() end
                            if self.UpdateSetupFrames then self:UpdateSetupFrames() end
                        end,
                        disabled=raidDisabledByFrameSort,
                    },
                    -- Layout Anchor is auto-derived from Grow Direction; hidden from UI.
                    layoutAnchor = {
                        type="select", name="Layout Anchor", order=1.8,
                        desc="Which corner of the layout rectangle stays fixed on screen. When you change Grow Direction, frames rearrange within the same bounding box because this corner stays pinned.",
                        values={
                            TOPLEFT     = "Top Left",
                            TOPRIGHT    = "Top Right",
                            BOTTOMLEFT  = "Bottom Left",
                            BOTTOMRIGHT = "Bottom Right",
                        },
                        sorting={ "TOPLEFT", "TOPRIGHT", "BOTTOMLEFT", "BOTTOMRIGHT" },
                        get=function()
                            local flat = self:GetModifyingProfile()
                            return (flat and flat.raidLayoutAnchor) or "TOPLEFT"
                        end,
                        set=function(_, val)
                            if InCombatLockdown() then return end
                            local flat = self:GetModifyingProfile()
                            if not flat or flat.type ~= "raid" then return end
                            -- Recalculate anchorX/anchorY so frames don't visually shift
                            -- (Grid2 SavePosition pattern).
                            local af = getVisibleAnchor()
                            if af and af:GetLeft() then
                                local ux, uy = UIParent:GetCenter()
                                local newX = val:find("LEFT") and af:GetLeft() or af:GetRight()
                                local newY = val:find("TOP") and af:GetTop() or af:GetBottom()
                                if newX and newY and ux and uy then
                                    local nx = math.floor(newX - ux + 0.5)
                                    local ny = math.floor(newY - uy + 0.5)
                                    flat.anchorX = nx
                                    flat.anchorY = ny
                                end
                            end
                            flat.raidLayoutAnchor = val
                            self:ReloadLayout(true)
                            if self.UpdateAnchorPosition then self:UpdateAnchorPosition() end
                            if self.UpdateSetupFrames then self:UpdateSetupFrames() end
                        end,
                        hidden=true,
                        disabled=raidDisabledByFrameSort,
                    },
                    unitsPerColumn = {
                        type="range", order=2,
                        name=function()
                            local sp = getSP()
                            local dir = sp and sp.raidGrowDirection
                            return (dir == "RIGHT" or dir == "LEFT") and "Units per Row" or "Units per Column"
                        end,
                        desc="How many units stack per column (vertical) or per row (horizontal).",
                        min=1, max=40, step=1,
                        get=function() local sp = getSP(); return sp and sp.unitsPerColumn end,
                        set=function(_, val)
                            if InCombatLockdown() then return end
                            local sp = getSP(); if not sp then return end
                            sp.unitsPerColumn = val
                            self:ReloadLayout(true)
                            if self.UpdateSetupFrames then self:UpdateSetupFrames() end
                        end,
                        hidden=function()
                            local sp = getSP()
                            return sp and sp.sortingMode == "GROUP" and sp.strictGroupLayout
                        end,
                        disabled=function()
                            if raidDisabledByFrameSort() then return true end
                            local sp = getSP()
                            return sp and sp.sortingMode == "GROUP"
                        end,
                    },
                },
            },
        },
    }
end
