-- ============================================================
-- BuzzardFrames: Options_Frames.lua
-- Builds and returns the "Frames" nav-tab args table.
-- Called from Options.lua: BF:BuildFramesOptions(deps)
-- ============================================================
local BF = _G["BuzzardFrames"]

-- deps is a table of upvalue references passed in from RegisterOptions:
--   deps.self               - the BF addon object
--   deps.ensureLayout       - local function from RegisterOptions
--   deps.NotifyChangeSafe   - local function from RegisterOptions
--   deps.buildCopyToDropdown- local function from RegisterOptions
--   deps.safeLayout         - local function from RegisterOptions
function BF:BuildFramesOptions(deps)
    local self             = deps.self
    local ensureLayout     = deps.ensureLayout
    local NotifyChangeSafe = deps.NotifyChangeSafe
    local buildCopyToDropdown = deps.buildCopyToDropdown
    local safeLayout       = deps.safeLayout

    -- Resolve the currently-modifying flat. _modifyingFlat is set by the
    -- chrome "Modifying Layout" dropdown (see Core_AceConfigDialog.lua).
    -- Falls back to flat_party so the Frames nav tab always has a sane
    -- source to edit.
    local function getFramesProfile()
        local lpp = self.rpDB.profile.layouts
        local fl  = lpp.flatLayouts or {}
        local mf  = self._modifyingFlat
        local flat = (mf and fl[mf]) or fl.flat_party
        ensureLayout(flat)
        return flat
    end

    -- isParty/isRaid must be derived from the SAME flat that
    -- getFramesProfile() returns, otherwise the hidden= predicates
    -- disagree with the data source. Specifically, when _modifyingFlat
    -- is nil (fresh panel open, no selection yet) getFramesProfile()
    -- falls back to flat_party, but a naive modifyingFlat() lookup
    -- would return nil — making isParty() false and exposing the raid
    -- group1-8 toggles against a party flat that has no showGroup.
    local isParty = function()
        local f = getFramesProfile()
        return (f and f.type == "party") or false
    end
    local isRaid = function() return not isParty() end

    local function framesGet(info)
        return getFramesProfile()[info[#info]]
    end
    local function framesSet(info, val)
        if InCombatLockdown() then return end
        getFramesProfile()[info[#info]] = val
        self:InvalidateRaidProfileCache()
        -- Only touch live frames when editing the active layout+group type.
        -- If modifying a different layout/group, only update setup frames.
        if not self:ActiveMatchesModifying() then
            if self.UpdateSetupFrames then self:UpdateSetupFrames() end
            if self.RefreshDummyAuras then self:RefreshDummyAuras() end
        else
            self:RefreshAll()
        end
        -- Refresh incoming casts preview if it's showing (party grow direction
        -- affects the Auto anchor/grow direction of incoming casts).
        if BF.IncomingCasts and BF.IncomingCasts._partyPreviewShown then
            BF.IncomingCasts:ShowPartyPreview()
        end
    end
    local function framesSetResize(info, val)
        if InCombatLockdown() then return end
        getFramesProfile()[info[#info]] = val
        self:InvalidateRaidProfileCache()
        -- Light path: update setup frames immediately so the user sees
        -- feedback while dragging. Cheap (small frame count).
        if self.ResizeTestFramesInPlace then self:ResizeTestFramesInPlace() end
        if self.UpdateSetupFrames then self:UpdateSetupFrames() end
        -- Heavy path: debounce the full live-frame resize + aura rebuild
        -- so it only fires once after the user stops dragging the slider.
        if self._framesResizeTimer then self._framesResizeTimer:Cancel() end
        self._framesResizeTimer = C_Timer.NewTimer(0.3, function()
            self._framesResizeTimer = nil
            if InCombatLockdown() then return end
            if not self:ActiveMatchesModifying() then
                if self.UpdateSetupFrames then self:UpdateSetupFrames() end
                if self.RefreshDummyAuras then self:RefreshDummyAuras() end
            else
                if self.ResizeAllFrames then self:ResizeAllFrames() end
                if self.RefreshPetHeaders then self:RefreshPetHeaders() end
                if self.UpdateSetupFrames then self:UpdateSetupFrames() end
                if self.RefreshDummyAuras then self:RefreshDummyAuras() end
            end
            if BF.RefreshPreviewLayout then
                -- The `groupType` parameter is gone under the flat model. The
                -- preview pane now walks the full active-flat set on every
                -- refresh.
                BF:RefreshPreviewLayout()
            end
        end)
    end
    local function framesSetSpacing(info, val)
        if InCombatLockdown() then return end
        getFramesProfile()[info[#info]] = val
        self:InvalidateRaidProfileCache()
        -- Debounce: slider fires on every tick; batch the heavy layout
        -- work into a single call after the user stops dragging.
        if self._framesSpacingTimer then self._framesSpacingTimer:Cancel() end
        self._framesSpacingTimer = C_Timer.NewTimer(0.15, function()
            self._framesSpacingTimer = nil
            if InCombatLockdown() then return end
            self:InvalidateRaidProfileCache()
            if self._contextIsRaid then
                self._resolvedProfile = self:GetRaidProfile()
            else
                self._resolvedProfile = self:GetActivePartyProfile()
            end
            self:PlaceHeaders()
            self:UpdateHeaders()
            if self:ActiveMatchesModifying() then
                self:ResizeAllFrames()
            end
            if self.UpdateSetupFrames then self:UpdateSetupFrames() end
        end)
    end
    -- (Removed: framesSetReload. Was a local helper that special-cased
    -- hideBlizzardRaid/hideBlizzardParty for live-hiding but was never
    -- wired to any widget in this file. The real Hide Blizzard toggles
    -- live in Options.lua under raidPartyFrames and go through their
    -- own inline setters.)
    -- showGroup is guaranteed present via the metatable __index template
    -- wired by BF:WireFlatDefaults (Core_FlatDefaults.lua). A raid-typed
    -- flat that has never been customized will resolve showGroup through
    -- the template; a flat with user edits keeps its rawkey. No lazy-init
    -- workaround is needed.
    local function framesGetGroup(info)
        local i = tonumber(info[#info]:match("%d+"))
        return getFramesProfile().showGroup[i]
    end
    local function framesSetGroup(info, val)
        if InCombatLockdown() then return end
        local i = tonumber(info[#info]:match("%d+"))
        local flat = getFramesProfile()
        -- Copy-on-write: flat.showGroup reads fall through the __index
        -- metatable to the per-flat template (see Core_FlatDefaults.lua).
        -- Without this copy, `flat.showGroup[i] = val` mutates the template
        -- table, which is freshly regenerated on every WireFlatDefaults call
        -- (login, profile change). Copy the template's table into a raw-
        -- key on the flat so the user's edits live on the flat itself and
        -- AceDB persists them to SavedVariables.
        if rawget(flat, "showGroup") == nil then
            local src = flat.showGroup  -- reads through __index
            local copy = {}
            if type(src) == "table" then
                for k, v in pairs(src) do copy[k] = v end
            end
            rawset(flat, "showGroup", copy)
        end
        flat.showGroup[i] = val
        self:InvalidateRaidProfileCache()
        -- When setup mode is active, always refresh the test frames so the
        -- new group visibility flows into _ReconfigureTestFrames (which reads
        -- showGroup to build visibleGroupIndices). UpdateSetupFrames also
        -- re-calls CreateTestResizeHandle on the new corner frame after
        -- hiding groups shifts which frame is last-visible; without this,
        -- the handle stays anchored to a now-hidden frame and disappears.
        --
        -- This branch mirrors framesSet's pattern: the ActiveMatchesModifying
        -- check only controls whether we also rebuild live secure frames
        -- (via safeLayout -> RefreshAll -> ApplyProfile). Setup frames must
        -- update in either case when setup mode is open.
        if self.db.global.setupModeActive and self.UpdateSetupFrames then
            self:UpdateSetupFrames()
        end
        -- Live frame rebuild path. When setup mode is active and matches the
        -- modifying flat, RefreshAll falls through to ApplyProfile and does
        -- the real-frame work. When setup mode is active but doesn't match,
        -- RefreshAll's setupActive-and-not-ActiveMatchesModifying branch also
        -- calls UpdateSetupFrames (harmless second call -- idempotent) and
        -- returns without touching real frames. When setup mode is off,
        -- RefreshAll -> ApplyProfile updates live frames directly.
        safeLayout()
    end

    local function framesDisabled()
        if InCombatLockdown() then return true end
        -- No tier-specific disabling under the flat model. A raid-typed
        -- flat is used for whichever raid slots the user assigns it to;
        -- there are no per-tier enable toggles inside a single flat.
        return false
    end

    local args = {}

    args._sectionTracker = {
        type = "description",
        name = function()
            if self._currentSection ~= "frames" then
                self._currentSection = "frames"
                if not InCombatLockdown() then NotifyChangeSafe() end
            end
            local halfW = BF:GetPositionHalfW()
            local halfH = BF:GetPositionHalfH()
            local posArgs = args.positionGroup and args.positionGroup.args
            if posArgs then
                if posArgs.anchorX then posArgs.anchorX.softMin = -halfW; posArgs.anchorX.softMax = halfW end
                if posArgs.anchorY then posArgs.anchorY.softMin = -halfH; posArgs.anchorY.softMax = halfH end
            end
            return ""
        end,
        order = 0, width = "full",
    }

    -- Info blurb mirroring the sky-blue per-Layout toggle color used elsewhere
    -- (|cff87ceeb). Frames is always per-flat by design (every flat owns its
    -- own position/size/spacing); there is no per-Layout toggle here.
    args._perLayoutInfo = {
        type     = "description",
        name     = "|cff87ceebPer-Layout configuration is always enabled for this section.|r",
        fontSize = "medium",
        order    = 0.5,
        width    = "full",
    }

    -- ── Frame Position (Grid2: Horizontal/Vertical Position sliders) ──
    -- Shared setter for anchorX/anchorY sliders.
    local function framesSetPosition(info, val)
        if InCombatLockdown() then return end
        local key = info[#info]   -- "anchorX" or "anchorY"
        local prof = getFramesProfile()
        prof[key] = val
        self:InvalidateRaidProfileCache()
        if self.UpdateAnchorPosition then self:UpdateAnchorPosition() end
    end
    args.positionGroup = {
        type = "group", name = "Frame Position", inline = true, order = 15,
        args = {
            anchorX = {
                type = "range", name = "X Position", order = 1,
                desc = "Adjust the horizontal position of the frame anchor.",
                softMin = -1024, softMax = 1024, step = 1,
                disabled = framesDisabled,
                get = function(info)
                    BF:ClampPositionSlider(info, "x")
                    return getFramesProfile().anchorX or -200
                end,
                set = framesSetPosition,
            },
            anchorY = {
                type = "range", name = "Y Position", order = 2,
                desc = "Adjust the vertical position of the frame anchor.",
                softMin = -1024, softMax = 1024, step = 1,
                disabled = framesDisabled,
                get = function(info)
                    BF:ClampPositionSlider(info, "y")
                    return getFramesProfile().anchorY or 100
                end,
                set = framesSetPosition,
            },
        },
    }

    -- ── Frame Size ────────────────────────────────────────────
    args.sizeGroup = {
        type = "group", name = "Frame Size", inline = true, order = 21,
        args = {
            frameWidth = {
                type = "range", name = "Frame Width", order = 1,
                min = 20, max = 150, step = 1,
                disabled = framesDisabled, get = framesGet, set = framesSetResize,
            },
            frameHeight = {
                type = "range", name = "Frame Height", order = 2,
                min = 20, max = 150, step = 1,
                disabled = framesDisabled, get = framesGet, set = framesSetResize,
            },
        },
    }

    -- ── Frame Spacing ─────────────────────────────────────────
    -- Party uses single frameSpacing; raid uses H+V
    args.spacingGroup = {
        type = "group", name = "Frame Spacing", inline = true, order = 24,
        args = {
            frameSpacing = {
                type = "range", name = "Frame Spacing", order = 1,
                min = 0, max = 10, step = 1,
                hidden   = function() return isRaid() end,
                disabled = framesDisabled, get = framesGet, set = framesSetSpacing,
            },
            frameSpacingH = {
                type = "range", name = "Frame Spacing (Horizontal)", order = 2,
                min = 0, max = 20, step = 1,
                hidden   = function() return isParty() end,
                disabled = framesDisabled, get = framesGet, set = framesSetSpacing,
            },
            frameSpacingV = {
                type = "range", name = "Frame Spacing (Vertical)", order = 3,
                min = 0, max = 20, step = 1,
                hidden   = function() return isParty() end,
                disabled = framesDisabled, get = framesGet, set = framesSetSpacing,
            },
        },
    }

    -- ── Frame Scale ───────────────────────────────────────────
    args.scaleGroup = {
        type = "group", name = "Frame Scale", inline = true, order = 27,
        args = {
            enableFrameScale = {
                type = "toggle", name = "Scale Frames", order = 1,
                desc = "Enable custom frame scaling. When unchecked, scale is reset to 1.0 and Apply Scale to Indicators is reset to enabled.",
                disabled = framesDisabled,
                get = framesGet,
                set = function(info, val)
                    if InCombatLockdown() then return end
                    local prof = getFramesProfile()
                    prof.enableFrameScale = val
                    if not val then
                        -- Revert scale settings to defaults
                        prof.frameScale      = 1.0
                        prof.scaleIndicators = true
                    end
                    self:InvalidateRaidProfileCache()
                    if self:ActiveMatchesModifying() then
                        if self.ResizeAllFrames then self:ResizeAllFrames() end
                        if self.RefreshPetHeaders then self:RefreshPetHeaders() end
                    end
                    if self.UpdateSetupFrames then self:UpdateSetupFrames() end
                    if self.RefreshDummyAuras then self:RefreshDummyAuras() end
                end,
            },
            frameScale = {
                type = "range", name = "Frame Scale", order = 2,
                desc = "Scale multiplier for all unit frames (does not affect frame width/height values)",
                min = 0.5, max = 3.0, step = 0.05,
                isPercent = false,
                hidden = function() return not getFramesProfile().enableFrameScale end,
                disabled = function()
                    if framesDisabled() then return true end
                    return not getFramesProfile().enableFrameScale
                end,
                get = framesGet, set = framesSetResize,
            },
            scaleIndicators = {
                type = "toggle", name = "Apply Scale to Indicators", order = 3,
                desc = "When enabled, frame scale also scales auras, icons, text, and borders. When disabled, only the frame body is scaled and indicators stay at their configured sizes.",
                hidden = function() return not getFramesProfile().enableFrameScale end,
                disabled = function()
                    if framesDisabled() then return true end
                    return not getFramesProfile().enableFrameScale
                end,
                get = framesGet, set = framesSetResize,
            },
        },
    }

    -- Party Layout widgets (Hide Self, Grow Direction, Role Order) moved to
    -- the "Frames - Sorting" top-level nav tab. See Options_Frames_Sorting.lua.
    -- The Show Raid Groups toggles (group1-8) remain below because they're
    -- per-flat visibility settings, not sorting semantics.

    -- Raid-only: show groups toggles
    local raidGroupsArgs = {}
    for i = 1, 8 do
        raidGroupsArgs["group" .. i] = {
            type = "toggle", name = "Group " .. i, order = i,
            disabled = framesDisabled,
            get = framesGetGroup, set = framesSetGroup,
        }
    end
    args.raidGroupsGroup = {
        type = "group", name = "Show Raid Groups", inline = true, order = 38,
        hidden = function() return isParty() end,
        args = raidGroupsArgs,
    }

    args.copySettingsTo = buildCopyToDropdown(getFramesProfile, nil, "Frames")
    -- order 0.6 puts the dropdown at the top of the tab, matching the
    -- per-layout Copy Settings dropdowns on the Sorting/Text/Icons/Tooltips
    -- tabs which also sit at order 0.6. The Frames tab has no per-layout
    -- toggle because Frames is always per-flat by design, so the dropdown
    -- sits alone on its row.
    args.copySettingsTo.order = 0.6
    args.copySettingsTo.width = "normal"

    -- ── Pets ─────────────────────────────────────────────────
    args.petsHeader = { type = "header", name = "Pets", order = 60 }
    args.showPetFrames = {
        type = "toggle", name = "Show Pet Frames", order = 61,
        desc = "Show a detached frame group for player pets. Unlock frames to drag it into position.",
        width = "normal",
        disabled = framesDisabled,
        get = framesGet,
        set = function(info, val)
            if InCombatLockdown() then return end
            local flat = getFramesProfile()
            flat[info[#info]] = val
            -- Seed pet grow direction from the main layout when first enabled
            if val and not flat.petGrowDirection then
                local sp2 = self:GetSectionProfile("sorting", flat)
                if flat.type == "party" then
                    local dir = (sp2 and sp2.growDirection) or "RIGHT"
                    if dir == "HORIZONTAL" then dir = "RIGHT" end
                    if dir == "VERTICAL" then dir = "DOWN" end
                    flat.petGrowDirection = dir
                else
                    flat.petGrowDirection = (sp2 and sp2.raidGrowDirection) or "DOWN"
                    flat.petSecondaryGrowDirection = sp2 and sp2.raidSecondaryGrowDirection
                end
            end
            self:InvalidateRaidProfileCache()
            if self:ActiveMatchesModifying() then
                self:TogglePetFrames()
            end
        end,
    }
    args.petShowSolo = {
        type = "toggle", name = "Show when Solo", order = 61.5,
        desc = "Spawn the pet frame when you are not in a group. Requires the layout to be rendering while solo (e.g. this Party layout selected for the solo slot).",
        width = "normal",
        -- Hidden for raid flats (pet frames only spawn for party layouts when
        -- solo), and hidden when Show Pet Frames is off for the current flat
        -- since Show when Solo is meaningless with no pet frame to spawn.
        hidden = function()
            if not isParty() then return true end
            return not getFramesProfile().showPetFrames
        end,
        disabled = function()
            if framesDisabled() then return true end
            return not getFramesProfile().showPetFrames
        end,
        get = framesGet,
        set = function(info, val)
            if InCombatLockdown() then return end
            getFramesProfile()[info[#info]] = val
            self:InvalidateRaidProfileCache()
            if self:ActiveMatchesModifying() then
                self:RefreshPetHeaders()
            end
        end,
    }
    args.petPositionGroup = {
        type = "group", name = "Pet Frame Position", inline = true, order = 62,
        hidden = function() return not getFramesProfile().showPetFrames end,
        args = {
            petFrameAnchorX = {
                type = "range", name = "X Position", order = 1,
                desc = "Horizontal position of the pet frames.",
                softMin = -1024, softMax = 1024, step = 1,
                disabled = framesDisabled,
                get = function(info)
                    BF:ClampPositionSlider(info, "x")
                    return getFramesProfile().petFrameAnchorX or 0
                end,
                set = function(info, val)
                    if InCombatLockdown() then return end
                    getFramesProfile().petFrameAnchorX = val
                    self:InvalidateRaidProfileCache()
                    -- Move the live pet header if it exists
                    if self:ActiveMatchesModifying() then
                        for _, header in ipairs(self.groupsUsed or {}) do
                            if header.isPetFrame then
                                self:SaveDetachedHeaderPosition(header)
                                -- Write the new position directly into saved positions
                                -- then restore so the header moves immediately.
                                local cfgp = self.cfgDB.profile
                                if cfgp.customFrameGroupPositions then
                                    cfgp.customFrameGroupPositions[header.headerPosKey] = nil
                                end
                                local flat = getFramesProfile()
                                header:ClearAllPoints()
                                header:SetPoint("CENTER", UIParent, "CENTER",
                                    flat.petFrameAnchorX or 0,
                                    flat.petFrameAnchorY or -300)
                                self:SaveDetachedHeaderPosition(header)
                            end
                        end
                    end
                end,
            },
            petFrameAnchorY = {
                type = "range", name = "Y Position", order = 2,
                desc = "Vertical position of the pet frames.",
                softMin = -1024, softMax = 1024, step = 1,
                disabled = framesDisabled,
                get = function(info)
                    BF:ClampPositionSlider(info, "y")
                    return getFramesProfile().petFrameAnchorY or -300
                end,
                set = function(info, val)
                    if InCombatLockdown() then return end
                    getFramesProfile().petFrameAnchorY = val
                    self:InvalidateRaidProfileCache()
                    if self:ActiveMatchesModifying() then
                        for _, header in ipairs(self.groupsUsed or {}) do
                            if header.isPetFrame then
                                local cfgp = self.cfgDB.profile
                                if cfgp.customFrameGroupPositions then
                                    cfgp.customFrameGroupPositions[header.headerPosKey] = nil
                                end
                                local flat = getFramesProfile()
                                header:ClearAllPoints()
                                header:SetPoint("CENTER", UIParent, "CENTER",
                                    flat.petFrameAnchorX or 0,
                                    flat.petFrameAnchorY or -300)
                                self:SaveDetachedHeaderPosition(header)
                            end
                        end
                    end
                end,
            },
            petFrameWidth = {
                type = "range", name = "Frame Width", order = 3,
                min = 20, max = 150, step = 1,
                disabled = framesDisabled,
                get = framesGet,
                set = function(info, val)
                    if InCombatLockdown() then return end
                    getFramesProfile()[info[#info]] = val
                    self:InvalidateRaidProfileCache()
                    if self:ActiveMatchesModifying() then
                        for _, header in ipairs(self.groupsUsed or {}) do
                            if header.isPetFrame then
                                self:UpdateFramesSizeForHeader(header)
                                self:ForceFramesCreation(header)
                                header:Update()
                            end
                        end
                    end
                    if self.UpdatePetTestFrames then self:UpdatePetTestFrames() end
                end,
            },
            petFrameHeight = {
                type = "range", name = "Frame Height", order = 4,
                min = 10, max = 100, step = 1,
                disabled = framesDisabled,
                get = framesGet,
                set = function(info, val)
                    if InCombatLockdown() then return end
                    getFramesProfile()[info[#info]] = val
                    self:InvalidateRaidProfileCache()
                    if self:ActiveMatchesModifying() then
                        for _, header in ipairs(self.groupsUsed or {}) do
                            if header.isPetFrame then
                                self:UpdateFramesSizeForHeader(header)
                                self:ForceFramesCreation(header)
                                header:Update()
                            end
                        end
                    end
                    if self.UpdatePetTestFrames then self:UpdatePetTestFrames() end
                end,
            },
            petFrameSpacing = {
                type = "range", name = "Frame Spacing", order = 5,
                min = 0, max = 20, step = 1,
                disabled = framesDisabled,
                get = framesGet,
                set = function(info, val)
                    if InCombatLockdown() then return end
                    getFramesProfile()[info[#info]] = val
                    self:InvalidateRaidProfileCache()
                    if self:ActiveMatchesModifying() then
                        self:RefreshPetHeaders()
                    end
                    if self.UpdatePetTestFrames then self:UpdatePetTestFrames() end
                end,
            },
            petGrowDirection = {
                type = "select", name = "Grow Direction", order = 6,
                desc = "Direction pet frames grow from the anchor.",
                values = {
                    DOWN  = "Down",
                    UP    = "Up",
                    RIGHT = "Right",
                    LEFT  = "Left",
                },
                sorting = { "DOWN", "UP", "RIGHT", "LEFT" },
                disabled = framesDisabled,
                get = function()
                    local dir = getFramesProfile().petGrowDirection
                    if dir == "RIGHT" or dir == "UP" or dir == "LEFT" then return dir end
                    return "DOWN"
                end,
                set = function(info, val)
                    if InCombatLockdown() then return end
                    local flat = getFramesProfile()
                    flat.petGrowDirection = val
                    flat.petSecondaryGrowDirection = nil
                    self:InvalidateRaidProfileCache()
                    if self:ActiveMatchesModifying() then
                        self:RefreshPetHeaders()
                    end
                    if self.UpdatePetTestFrames then self:UpdatePetTestFrames() end
                end,
            },
            petSecondaryGrowDirection = {
                type = "select", name = "Secondary Grow Direction", order = 7,
                desc = "Direction groups/columns extend perpendicular to the primary grow direction.",
                hidden = function() return isParty() end,
                values = function()
                    local dir = getFramesProfile().petGrowDirection or "DOWN"
                    if dir == "RIGHT" or dir == "LEFT" then
                        return { DOWN = "Down", UP = "Up" }
                    else
                        return { RIGHT = "Right", LEFT = "Left" }
                    end
                end,
                sorting = function()
                    local dir = getFramesProfile().petGrowDirection or "DOWN"
                    if dir == "RIGHT" or dir == "LEFT" then
                        return { "DOWN", "UP" }
                    else
                        return { "RIGHT", "LEFT" }
                    end
                end,
                get = function()
                    local flat = getFramesProfile()
                    local sec = flat.petSecondaryGrowDirection
                    if sec then return sec end
                    local dir = flat.petGrowDirection or "DOWN"
                    if dir == "RIGHT" or dir == "LEFT" then return "DOWN" end
                    return "RIGHT"
                end,
                set = function(_, val)
                    if InCombatLockdown() then return end
                    local flat = getFramesProfile()
                    local dir = flat.petGrowDirection or "DOWN"
                    local isDefault = (dir == "RIGHT" or dir == "LEFT") and val == "DOWN"
                                   or (dir == "DOWN" or dir == "UP") and val == "RIGHT"
                    flat.petSecondaryGrowDirection = (not isDefault) and val or nil
                    self:InvalidateRaidProfileCache()
                    if self:ActiveMatchesModifying() then
                        self:RefreshPetHeaders()
                    end
                    if self.UpdatePetTestFrames then self:UpdatePetTestFrames() end
                end,
                disabled = framesDisabled,
            },
        },
    }

    return {
        type  = "group",
        name  = "Frames - Size & Position",
        order = 1,
        args  = args,
    }
end
