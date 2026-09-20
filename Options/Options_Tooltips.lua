-- ============================================================
-- BuzzardFrames: Options_Tooltips.lua
-- Builds and returns the "Tooltips" nav-tab args table.
-- Called from Options.lua: BF:BuildTooltipsOptions(deps)
--
-- Storage: rpDB.profile.tooltips.* (global pseudo-layout) or
-- flat.tooltips.* when layouts.perLayoutToggles.tooltips is true. ALL
-- tooltip widgets read/write through the same getTP() / setTP() helpers
-- which route through BF:GetSectionProfile("tooltips", modifyingFlat).
-- When the toggle is OFF, GetSectionProfile returns the global; when
-- ON, it returns flat.tooltips so per-layout edits land on the right
-- flat.
--
-- v24: unified every widget onto a single routed setter. Pre-v24 the
-- aura-tooltip show toggles used getTooltip_global / setTooltip_global
-- which wrote to self.db.profile (the CORE profile, not rpDB), and the
-- suppressPrivateAuraTooltip widget wrote to the flat root. Both are
-- now in rpDB.profile.tooltips and follow the standard routing.
-- ============================================================
local BF = _G["BuzzardFrames"]

-- deps is a table of upvalue references passed in from RegisterOptions:
--   deps.self                      - the BF addon object
--   deps.NotifyChangeSafe          - local function from RegisterOptions
--   deps.get                       - makeRpGet("tooltips") (routed via GetSectionProfile)
--   deps.set                       - makeRpSet("tooltips") (routed via GetSectionProfile)
--   deps.getAurasProfile_shared    - local function from RegisterOptions (unused here, kept for future)
--   deps.buildSectionCopyToDropdown- factory for the per-layout Copy Settings dropdown
function BF:BuildTooltipsOptions(deps)
    local self                    = deps.self
    local NotifyChangeSafe        = deps.NotifyChangeSafe
    local get                     = deps.get
    local set                     = deps.set
    local buildSectionCopyToDropdown = deps.buildSectionCopyToDropdown

    -- Read path: always the currently-modifying flat. When the per-layout
    -- toggle is OFF, GetSectionProfile ignores the flat argument and
    -- returns the global rpDB.profile.tooltips. When ON, it returns
    -- flat.tooltips so the user sees and edits the per-flat copy.
    local function getTP()
        return self:GetSectionProfile("tooltips", self:GetModifyingProfile())
    end

    -- Unified tooltip setter. Routes through getTP() (same as get/set
    -- from deps), then runs the side effects every tooltip change needs:
    --   * RefreshAllAuras    -- re-runs ApplyAuraTooltips on every frame
    --                          so OnEnter/OnLeave hooks pick up the new
    --                          show / position / combat-gate settings.
    --   * RefreshPreviewDummyAuras -- refreshes the preview panel dummies.
    --
    -- Widgets that need additional side effects (NotifyChangeSafe for
    -- AceConfig rebuild on position changes) layer those on top via
    -- their own set= that calls setTP + extra.
    -- Unit-tooltip keys feed Indicators/Tooltip.lua (the unit-frame
    -- tooltip indicator), NOT ApplyAuraTooltips. The Tooltip indicator
    -- reads tooltip settings live in OnEnter via GetSectionProfileForFrame,
    -- so no aura refresh is needed when one of these changes.
    local UNIT_TOOLTIP_KEYS = {
        showUnitTooltip          = true,
        showUnitTooltipInCombat  = true,
        unitTooltipPosition      = true,
    }

    local function setTP(info, val)
        if InCombatLockdown() then return end
        local key = info[#info]
        local tp = getTP()
        if tp then tp[key] = val end

        -- Mark flat caches dirty so UpdateAuraSizeCache picks up the
        -- new value. writeAurasValue in Options.lua already does this
        -- for the auras section; tooltip writes don't go through any
        -- shared helper so we invalidate here directly. Per-layout ON
        -- needs the modifying flat; OFF needs every flat that falls
        -- through to the global.
        if self:IsPerLayoutSection("tooltips") then
            BF:InvalidateFlatAuraCache(self:GetModifyingProfile())
        else
            BF:InvalidateGlobalSectionFlatCaches("tooltips")
        end
        self:InvalidateRaidProfileCache()

        -- Scoped refresh: most tooltip keys feed ApplyAuraTooltips (a
        -- single-pass per-frame call). suppressPrivateAuraTooltip is
        -- read by IconIndicator:Layout, so it needs the private aura
        -- scoped refresh. Unit-tooltip keys don't touch aura icons at
        -- all; the Tooltip indicator reads them live in OnEnter.
        if key == "suppressPrivateAuraTooltip" and self.RefreshPrivateAurasOnly then
            self:RefreshPrivateAurasOnly()
        elseif UNIT_TOOLTIP_KEYS[key] then
            -- No-op: the unit-tooltip indicator picks up the new value
            -- on the next OnEnter without an aura-system refresh.
        elseif self.RefreshTooltipsOnly then
            self:RefreshTooltipsOnly()
        else
            self:RefreshAllAuras()
        end
        if self.RefreshPreviewDummyAuras then self:RefreshPreviewDummyAuras() end
    end

    -- Position-select setter: setTP + NotifyChangeSafe. Anchor / offset
    -- changes need AceConfig to rebuild so `hidden` predicates on
    -- dependent widgets re-evaluate.
    local function setTPPosition(info, val)
        setTP(info, val)
        if not InCombatLockdown() then NotifyChangeSafe() end
    end

    return {
        type  = "group",
        name  = "Tooltips",
        order = 10,
        args  = {
            _sectionTracker = {
                type = "description",
                name = function()
                    if self._currentSection ~= "tooltips" then
                        self._currentSection = "tooltips"
                        if not InCombatLockdown() then NotifyChangeSafe() end
                    end
                    return ""
                end,
                order = 0, width = "full",
            },

            -- Unit Tooltip
            unitTooltipHeader = { type = "header", name = "Raid/Party Frame Unit Tooltips", order = 1 },
            showUnitTooltip = {
                type     = "toggle",
                name     = "Show Unit Tooltip",
                order    = 2,
                get      = get,
                set      = setTP,
                disabled = InCombatLockdown,
            },
            showUnitTooltipInCombat = {
                type     = "toggle",
                name     = "Show in Combat",
                order    = 3,
                get      = get,
                set      = setTP,
                hidden   = function() local tp = getTP(); return not (tp and tp.showUnitTooltip) end,
                disabled = InCombatLockdown,
            },
            unitTooltipPosition = {
                type     = "select",
                name     = "Tooltip Position",
                order    = 4,
                values   = { default = "Default", icon = "Cursor - Bottom Right", iconTR = "Cursor - Top Right", frame = "Below Frame" },
                get      = get,
                set      = setTPPosition,
                hidden   = function() local tp = getTP(); return not (tp and tp.showUnitTooltip) end,
                disabled = InCombatLockdown,
            },

            -- Buff Tooltips
            buffTooltipHeader = { type = "header", name = "Buff Tooltips", order = 10 },
            showBuffTooltip = {
                type     = "toggle",
                name     = "Show Buff Tooltips",
                order    = 11,
                get      = get,
                set      = setTP,
                disabled = InCombatLockdown,
            },
            showBuffTooltipInCombat = {
                type     = "toggle",
                name     = "Show in Combat",
                order    = 12,
                get      = get,
                set      = setTP,
                hidden   = function() local tp = getTP(); return not (tp and tp.showBuffTooltip) end,
                disabled = InCombatLockdown,
            },
            buffTooltipPosition = {
                type     = "select",
                name     = "Tooltip Position",
                order    = 13,
                values   = { default = "Default", icon = "Cursor - Bottom Right", iconTR = "Cursor - Top Right", frame = "Below Frame" },
                get      = get,
                set      = setTPPosition,
                hidden   = function() local tp = getTP(); return not (tp and tp.showBuffTooltip) end,
                disabled = InCombatLockdown,
            },

            -- Debuff Tooltips
            debuffTooltipHeader = { type = "header", name = "Debuff Tooltips", order = 20 },
            showDebuffTooltip = {
                type     = "toggle",
                name     = "Show Debuff Tooltips",
                order    = 21,
                get      = get,
                set      = setTP,
                disabled = InCombatLockdown,
            },
            showDebuffTooltipInCombat = {
                type     = "toggle",
                name     = "Show in Combat",
                order    = 22,
                get      = get,
                set      = setTP,
                hidden   = function() local tp = getTP(); return not (tp and tp.showDebuffTooltip) end,
                disabled = InCombatLockdown,
            },
            debuffTooltipPosition = {
                type     = "select",
                name     = "Tooltip Position",
                order    = 23,
                values   = { default = "Default", icon = "Cursor - Bottom Right", iconTR = "Cursor - Top Right", frame = "Below Frame" },
                get      = get,
                set      = setTPPosition,
                hidden   = function() local tp = getTP(); return not (tp and tp.showDebuffTooltip) end,
                disabled = InCombatLockdown,
            },

            -- Big Defensive Icon Tooltips
            bigDefTooltipHeader = { type = "header", name = "Big Defensive Icon Tooltips", order = 30 },
            showBigDefTooltip = {
                type     = "toggle",
                name     = "Show Big Defensive Icon Tooltips",
                order    = 31,
                get      = get,
                set      = setTP,
                disabled = InCombatLockdown,
            },
            showBigDefTooltipInCombat = {
                type     = "toggle",
                name     = "Show in Combat",
                order    = 32,
                get      = get,
                set      = setTP,
                hidden   = function() local tp = getTP(); return not (tp and tp.showBigDefTooltip) end,
                disabled = InCombatLockdown,
            },
            bigDefTooltipPosition = {
                type     = "select",
                name     = "Tooltip Position",
                order    = 33,
                values   = { default = "Default", icon = "Cursor - Bottom Right", iconTR = "Cursor - Top Right", frame = "Below Frame" },
                get      = get,
                set      = setTPPosition,
                hidden   = function() local tp = getTP(); return not (tp and tp.showBigDefTooltip) end,
                disabled = InCombatLockdown,
            },

            -- Important Buff Icon Tooltips
            importantTooltipHeader = { type = "header", name = "Important Buff Icon Tooltips", order = 34 },
            showImportantTooltip = {
                type     = "toggle",
                name     = "Show Important Buff Icon Tooltips",
                order    = 34.1,
                get      = get,
                set      = setTP,
                disabled = InCombatLockdown,
            },
            showImportantTooltipInCombat = {
                type     = "toggle",
                name     = "Show in Combat",
                order    = 34.2,
                get      = get,
                set      = setTP,
                hidden   = function() local tp = getTP(); return not (tp and tp.showImportantTooltip) end,
                disabled = InCombatLockdown,
            },
            importantTooltipPosition = {
                type     = "select",
                name     = "Tooltip Position",
                order    = 34.3,
                values   = { default = "Default", icon = "Cursor - Bottom Right", iconTR = "Cursor - Top Right", frame = "Below Frame" },
                get      = get,
                set      = setTPPosition,
                hidden   = function() local tp = getTP(); return not (tp and tp.showImportantTooltip) end,
                disabled = InCombatLockdown,
            },

            -- Crowd Control Tooltips
            crowdControlTooltipHeader = { type = "header", name = "Crowd Control Tooltips", order = 35 },
            showCrowdControlTooltip = {
                type     = "toggle",
                name     = "Show Crowd Control Tooltips",
                order    = 36,
                get      = get,
                set      = setTP,
                disabled = InCombatLockdown,
            },
            showCrowdControlTooltipInCombat = {
                type     = "toggle",
                name     = "Show in Combat",
                order    = 37,
                get      = get,
                set      = setTP,
                hidden   = function() local tp = getTP(); return not (tp and tp.showCrowdControlTooltip) end,
                disabled = InCombatLockdown,
            },
            crowdControlTooltipPosition = {
                type     = "select",
                name     = "Tooltip Position",
                order    = 38,
                values   = { default = "Default", icon = "Cursor - Bottom Right", iconTR = "Cursor - Top Right", frame = "Below Frame" },
                get      = get,
                set      = setTPPosition,
                hidden   = function() local tp = getTP(); return not (tp and tp.showCrowdControlTooltip) end,
                disabled = InCombatLockdown,
            },

            -- Private Auras Tooltips
            -- Storage is `suppressPrivateAuraTooltip` (true = suppress/hide).
            -- UI is inverted: "Show Private Aura Tooltips" toggle ON = NOT suppress.
            -- The inversion is cosmetic; the underlying routing is identical to
            -- every other tooltip widget (getTP / setTP).
            privateAurasHeader = { type = "header", name = "Private Auras", order = 40 },
            suppressPrivateAuraTooltip = {
                type     = "toggle",
                name     = "Show Private Aura Tooltips",
                desc     = "Show the tooltip when mousing over a private aura icon.",
                order    = 41,
                get      = function() local tp = getTP(); return not (tp and tp.suppressPrivateAuraTooltip) end,
                set      = function(info, val)
                    -- info[#info] == "suppressPrivateAuraTooltip"; setTP writes
                    -- (not val) so the "Show" UI inverts to the "suppress" storage.
                    setTP(info, not val)
                end,
                disabled = InCombatLockdown,
            },
        },
    }
end
