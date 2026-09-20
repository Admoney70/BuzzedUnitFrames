-- ============================================================
-- BuzzardFrames: Options_Text.lua
-- Builds and returns the "Text" nav-tab args table.
-- Called from Options.lua: BF:BuildTextOptions(deps)
--
-- Storage: rpDB.profile.text.* (global pseudo-layout) or flat.text.*
-- when layouts.perLayoutToggles.text is true. ALL widgets read/write
-- through the getT() helper which routes via
--   BF:GetSectionProfile("text", GetModifyingProfile())
-- so per-layout ON/OFF is transparent to the widget definitions.
--
-- v25 (2026-04-18): fixed two latent data-location bugs:
--   (a) Most toggle/scalar widgets used deps.get which reads from
--       self.db.profile (the CORE profile), while their custom setters
--       wrote to self.rpDB.profile.text. Toggling a widget wrote to the
--       right place but the UI showed a stale read from db.profile.
--       See Core_Migrations.lua MigrateTextLocation for the relocation.
--   (b) Font-name keys (nameFont, healthFont, statusFont,
--       groupLabelFont, vehicleFont) were written by setFont() to
--       self.db.profile[key] but runtime read them from
--       self.rpDB.profile.text[key]. Selecting a font in the UI never
--       took effect at runtime. Also fixed by the v25 migration.
--
-- Section visibility:
--   Per-layout toggle OFF (global):  every sub-tab visible; settings are
--                                    shared across all Layouts.
--   Per-layout toggle ON:
--     Modifying a raid flat:  every sub-tab visible.
--     Modifying a party flat: Labels (raid groups) sub-tab is hidden
--                             because raid groups don't exist for party.
--   Same pattern as Options_Frames_Sorting.lua.
-- ============================================================
local BF = _G["BuzzardFrames"]

-- deps is a table of upvalue references passed in from RegisterOptions:
--   deps.self                      - the BF addon object
--   deps.NotifyChangeSafe          - local function from RegisterOptions
--   deps.get                       - makeRpGet("text") (routed via GetSectionProfile)
--   deps.set                       - makeRpSet("text") (routed via GetSectionProfile)
--   deps.safeLayout                - local function from RegisterOptions (unused here, kept for future)
--   deps.buildSectionCopyToDropdown- factory for the per-layout Copy Settings dropdown
function BF:BuildTextOptions(deps)
    local self             = deps.self
    local NotifyChangeSafe = deps.NotifyChangeSafe
    local buildSectionCopyToDropdown = deps.buildSectionCopyToDropdown

    -- ── Routing helpers ───────────────────────────────────────────
    -- getT() returns the currently-modifying flat's text profile
    -- (flat.text when per-layout is ON, rpDB.profile.text when OFF).
    -- All reads/writes flow through this one helper.
    local function getT()
        return self:GetSectionProfile("text", self:GetModifyingProfile())
    end

    -- Info-based read -- replaces the old deps.get (which read from
    -- self.db.profile, the wrong table). Used wherever a widget just
    -- needs the value for the key its info path names.
    local function getTKey(info)
        local tp = getT()
        return tp and tp[info[#info]]
    end

    -- Raw write helper used by every setter. Each setter then runs its
    -- specific side effects inline (RefreshAllNames, UpdateHealth,
    -- layoutFrames, etc.) rather than being shoehorned into a single
    -- variant factory -- the side-effect surface is too varied for that
    -- to be a clean abstraction.
    local function writeT(info, val)
        local tp = getT()
        if tp then tp[info[#info]] = val end
    end

    -- ── Side-effect helpers (unchanged pre-v25 behaviour) ─────────

    -- Update icon/text positions on all active frames without a full RefreshAll.
    local function layoutFrames()
        for frame in pairs(self.activeFrames or {}) do
            self:LayoutFrame(frame)
        end
        if BF.RefreshPreviewLayout then BF:RefreshPreviewLayout() end
    end

    -- Update only the name font without triggering a full LayoutFrame (avoids flashing).
    -- IMPORTANT: reads must come from the ACTIVE flat, not the modifying one.
    -- This function applies the result to every frame in self.activeFrames --
    -- if it read from getT() (the modifying flat), editing raid30's name
    -- font while the game context is party would visually push raid30's
    -- font onto the live party frames. The underlying writes already landed
    -- correctly on flat_raid30.text via setFont/writeT; this function just
    -- needs to reflect the change visually on whatever frames are actually
    -- rendering right now. Mirrors NameText:Layout's context resolution.
    local function refreshNameFont()
        local isRaid = BF._contextIsRaid ~= nil and BF._contextIsRaid
                       or (IsInRaid() and not BF.openWorldPartyOverride)
        local activeFlat = isRaid and self:GetRaidProfile() or self:GetActivePartyProfile()
        local tp = self:GetSectionProfile("text", activeFlat)
        if not tp then return end
        for frame in pairs(self.activeFrames or {}) do
            if frame.nameText then
                local origFont  = frame.nameText.SF_defaultFont  or "Fonts\\FRIZQT__.TTF"
                local origSize  = frame.nameText.SF_defaultSize  or 10
                local origFlags = frame.nameText.SF_defaultFlags or ""
                local fontPath, fontSize, fontFlags
                if tp.adjustNameFont then
                    fontPath  = self:ResolveFontPath(tp.nameFont)
                    fontSize  = tp.nameFontSize
                    fontFlags = tp.nameFontBorder or ""
                else
                    fontPath  = origFont
                    fontSize  = origSize
                    fontFlags = origFlags
                end
                -- Switch to a different font briefly then back, forcing WoW to
                -- flush the render state and pick up the new JustifyH every time.
                local altFont = (fontPath == origFont)
                    and "Fonts\\FRIZQT__.TTF"
                    or origFont
                frame.nameText:SetFont(altFont, fontSize, fontFlags)
                frame.nameText:SetFont(fontPath, fontSize, fontFlags)
                frame._nameFontPath  = fontPath
                frame._nameFontSize  = fontSize
                frame._nameFontFlags = fontFlags
                local np = tp.namePosition
                local anchorPoint = (np and np.point) or "CENTER"
                if anchorPoint:find("LEFT") then frame.nameText:SetJustifyH("LEFT")
                elseif anchorPoint:find("RIGHT") then frame.nameText:SetJustifyH("RIGHT")
                else frame.nameText:SetJustifyH("CENTER") end
            end
        end
        if BF.RefreshPreviewLayout then BF:RefreshPreviewLayout() end
    end

    -- Font dropdowns use LSM display name as both key and stored value.
    -- This avoids all path-matching issues across different OS path separators.
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

    -- Font get/set now routed through getT() so the selected font actually
    -- reaches the runtime (pre-v25 these wrote to self.db.profile which no
    -- reader ever consulted -- see header comment above).
    local function getFont(key)
        local tp = getT()
        local v = tp and tp[key]
        -- If blank, nil, or a raw file path (legacy), fall back to PT Sans Narrow name.
        if not v or v == "DEFAULT" or v == "" or (type(v) == "string" and v:find("[\\/]")) then
            return "PT Sans Narrow"
        end
        return v
    end
    local function setFont(key, val)
        if InCombatLockdown() then return end
        local tp = getT()
        if tp then tp[key] = val end
    end

    -- ── Labels sub-tab visibility ─────────────────────────────────
    -- Raid Group Labels only apply to raid flats. When per-layout is ON
    -- and the user is modifying a party flat, hide the whole sub-tab.
    -- When per-layout is OFF the sub-tab stays visible (global editing).
    local function hideLabelsForParty()
        if not self:IsPerLayoutSection("text") then return false end
        local flat = self:GetModifyingProfile()
        return flat and flat.type == "party" or false
    end

    return {
        type        = "group",
        name        = "Text",
        order       = 3.5,
        childGroups = "tab",
        args        = {
            _sectionTracker = {
                type = "description",
                name = function()
                    if self._currentSection ~= "text" then
                        self._currentSection = "text"
                        if not InCombatLockdown() then NotifyChangeSafe() end
                    end
                    return ""
                end,
                order = 0, width = "full",
            },

            -- ============================================================
            -- Names sub-tab
            -- ============================================================
            names = {
                type = "group", name = "Names", order = 1,
                args = {
                    nameHeader = { type="header", name="Name Text", order=1 },

                    -- ── Name Font group ──
                    nameFontGroup = {
                        type="group", name="Name Font", inline=true, order=4,
                        args = {
                            adjustNameFont = {
                                type="toggle", name="Adjust Name Font", order=1,
                                desc="Enable custom font, border style, and size for name text",
                                get=getTKey,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    writeT(info, val)
                                    layoutFrames()
                                end,
                                disabled=InCombatLockdown,
                            },
                            nameFont = {
                                type="select", name="Font", order=2, desc="Choose a font for unit names",
                                dialogControl="LSM30_Font",
                                hidden=function() local tp = getT(); return not (tp and tp.adjustNameFont) end,
                                values=buildFontVals,
                                get=function() return getFont("nameFont") end,
                                set=function(_, val) setFont("nameFont", val); refreshNameFont() end,
                                disabled=InCombatLockdown,
                            },
                            nameFontBorder = {
                                type="select", name="Font Border", order=3, desc="Choose an outline/border style for name text",
                                hidden=function() local tp = getT(); return not (tp and tp.adjustNameFont) end,
                                values={
                                    [""] = "None (Default)", ["OUTLINE"] = "Outline", ["THICKOUTLINE"] = "Thick Outline",
                                    ["MONOCHROME"] = "Monochrome", ["OUTLINE, MONOCHROME"] = "Outline + Monochrome",
                                    ["THICKOUTLINE, MONOCHROME"] = "Thick Outline + Monochrome",
                                },
                                get=getTKey,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    writeT(info, val)
                                    refreshNameFont()
                                end,
                                disabled=InCombatLockdown,
                            },
                            nameFontSize = {
                                type="range", name="Font Size", order=4,
                                hidden=function() local tp = getT(); return not (tp and tp.adjustNameFont) end,
                                min=6, max=30, step=1,
                                get=getTKey,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    writeT(info, val)
                                    refreshNameFont()
                                end,
                                disabled=InCombatLockdown,
                            },
                        },
                    },

                    -- ── Name Colors group ──
                    nameColorsGroup = {
                        type="group", name="Name Colors", inline=true, order=4.5,
                        args = {
                            adjustNameColors = {
                                type="toggle", name="Adjust Name Colors", order=1,
                                get=getTKey,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    writeT(info, val)
                                    self:RefreshAllNames()
                                end,
                                disabled=InCombatLockdown,
                            },
                            classColorNames = {
                                type="toggle", name="Class Color Names", order=2,
                                hidden=function() local tp = getT(); return not (tp and tp.adjustNameColors) end,
                                get=getTKey,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    writeT(info, val)
                                    self:RefreshAllNames()
                                end,
                                disabled=InCombatLockdown,
                            },
                            nameColor = {
                                type="color", name="Name Color", order=3, hasAlpha=false,
                                desc="Default name color. Overridden by Class Color Names when enabled.",
                                hidden=function()
                                    local tp = getT()
                                    return not (tp and tp.adjustNameColors) or (tp and tp.classColorNames)
                                end,
                                get=function()
                                    local tp = getT()
                                    local c = (tp and tp.nameColor) or { r=1, g=1, b=1 }
                                    return c.r, c.g, c.b
                                end,
                                set=function(_, r, g, b)
                                    if InCombatLockdown() then return end
                                    local tp = getT()
                                    if tp then tp.nameColor = { r=r, g=g, b=b } end
                                    self:RefreshAllNames()
                                    if BF.RefreshPreviewName then BF:RefreshPreviewName() end
                                end,
                                disabled=InCombatLockdown,
                            },
                        },
                    },

                    -- ── Name Position group ──
                    namePosition = {
                        type="group", name="Name Position", inline=true, order=3,
                        args = {
                            point = {
                                type="select", name="Location", order=1,
                                values={ TOPLEFT="Top Left", TOP="Top", TOPRIGHT="Top Right", LEFT="Left", CENTER="Center", RIGHT="Right", BOTTOMLEFT="Bottom Left", BOTTOM="Bottom", BOTTOMRIGHT="Bottom Right" },
                                get=function() local tp = getT(); return tp and tp.namePosition and tp.namePosition.point end,
                                set=function(_, v)
                                    if InCombatLockdown() then return end
                                    local tp = getT()
                                    if tp and tp.namePosition then tp.namePosition.point = v end
                                    layoutFrames(); refreshNameFont()
                                end,
                            },
                            x = {
                                type="range", name="X Offset", order=2, min=-50, max=50, step=1,
                                get=function() local tp = getT(); return tp and tp.namePosition and tp.namePosition.x end,
                                set=function(_, v)
                                    if InCombatLockdown() then return end
                                    local tp = getT()
                                    if tp and tp.namePosition then tp.namePosition.x = v end
                                    layoutFrames()
                                end,
                                disabled=InCombatLockdown,
                            },
                            y = {
                                type="range", name="Y Offset", order=3, min=-50, max=50, step=1,
                                get=function() local tp = getT(); return tp and tp.namePosition and tp.namePosition.y end,
                                set=function(_, v)
                                    if InCombatLockdown() then return end
                                    local tp = getT()
                                    if tp and tp.namePosition then tp.namePosition.y = v end
                                    layoutFrames()
                                end,
                                disabled=InCombatLockdown,
                            },
                        },
                    },

                    -- ── Abbreviate names group ──
                    abbreviateNamesGroup = {
                        type="group", name="Abbreviate Names", inline=true, order=5.5,
                        args = {
                            abbreviateNames = {
                                type="toggle", name="Abbreviate Long Names", order=1,
                                get=getTKey,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    writeT(info, val)
                                    self:RefreshAllNames()
                                end,
                                disabled=InCombatLockdown,
                            },
                            maxNameChars = {
                                type="range", name="Max Name Length", order=2,
                                hidden=function() local tp = getT(); return not (tp and tp.abbreviateNames) end,
                                disabled=InCombatLockdown,
                                min=3, max=20, step=1,
                                get=getTKey,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    writeT(info, val)
                                    self:RefreshAllNames()
                                end,
                            },
                        },
                    },

                    -- ── Capitalize names group ──
                    capitalizeNamesGroup = {
                        type="group", name="Capitalize Names", inline=true, order=5.3,
                        args = {
                            capitalizeNames = {
                                type="toggle", name="Capitalize Names", order=1,
                                desc="Convert unit names to uppercase.",
                                get=getTKey,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    writeT(info, val)
                                    self:RefreshAllNames()
                                end,
                                disabled=InCombatLockdown,
                            },
                        },
                    },

                    -- ── Cyrillic ──
                    cyrillicSpacer = { type="description", name="", order=5.4 },
                    cyrillicHeader = { type="header", name="Cyrillic Names", order=5.5 },
                    transliterateCyrillicNames = {
                        type="toggle", name="Transliterate Cyrillic Names", order=5.6,
                        desc="Convert Cyrillic characters in unit names to Latin equivalents (e.g. \"Привет\" → \"Privet\"). When disabled, Cyrillic names use a fallback font that supports the Cyrillic alphabet.",
                        get=getTKey,
                        set=function(info, val)
                            if InCombatLockdown() then return end
                            writeT(info, val)
                            self:RefreshAllNames()
                            if BF.RefreshPreviewName then BF:RefreshPreviewName() end
                        end,
                        disabled=InCombatLockdown,
                        width="full",
                    },
                    testCyrillicNames = {
                        type="toggle", name="Test Cyrillic Names", order=5.7,
                        desc="Replace all unit names with a Cyrillic test string (\"Привет\") so you can verify font fallback and transliteration visually.",
                        hidden=function() return not BF.db.profile.enableExperimentalOptions end,
                        -- testCyrillicNames is a GLOBAL debug flag, not a text-section key --
                        -- it lives on BF.db.global and is shared across profiles/layouts.
                        get=function() return BF.db.global.testCyrillicNames end,
                        set=function(_, val)
                            if InCombatLockdown() then return end
                            BF.db.global.testCyrillicNames = val
                            self:RefreshAllNames()
                            if BF.RefreshPreviewName then BF:RefreshPreviewName() end
                        end,
                        disabled=InCombatLockdown,
                        width="full",
                    },
                },
            },

            -- ============================================================
            -- Health Text sub-tab
            -- ============================================================
            healthText = {
                type = "group", name = "Health Text", order = 2,
                args = {
                    healthTextHeader = { type="header", name="Health Text", order=1 },
                    showHealthText = {
                        type="toggle", name="Show Health Text", order=2,
                        get=getTKey,
                        set=function(info, val)
                            if InCombatLockdown() then return end
                            writeT(info, val)
                            for frame in pairs(self.activeFrames or {}) do self:UpdateHealth(frame) end
                        end,
                        disabled=InCombatLockdown,
                    },
                    healthTextFormat = {
                        type="select", name="Health Text Format", order=3,
                        hidden=function() local tp = getT(); return not (tp and tp.showHealthText) end,
                        values={ deficit="Deficit", percent="Percent", current="Current" },
                        get=getTKey,
                        set=function(info, val)
                            if InCombatLockdown() then return end
                            writeT(info, val)
                            for frame in pairs(self.activeFrames or {}) do self:UpdateHealth(frame) end
                        end,
                        disabled=InCombatLockdown,
                    },
                    healthTextPosition = {
                        type="group", name="Health Text Position", inline=true, order=4,
                        hidden=function() local tp = getT(); return not (tp and tp.showHealthText) end,
                        args = {
                            pos = {
                                type="select", name="Location", order=1,
                                values={ TOPLEFT="Top Left", TOP="Top", TOPRIGHT="Top Right", LEFT="Left", CENTER="Center", RIGHT="Right", BOTTOMLEFT="Bottom Left", BOTTOM="Bottom", BOTTOMRIGHT="Bottom Right" },
                                get=function() local tp = getT(); return tp and tp.healthTextPosition end,
                                set=function(_, val)
                                    if InCombatLockdown() then return end
                                    local tp = getT(); if tp then tp.healthTextPosition = val end
                                    layoutFrames()
                                end,
                                disabled=function() local tp = getT(); return InCombatLockdown() or not (tp and tp.showHealthText) end,
                            },
                            x = {
                                type="range", name="X Offset", order=2, min=-50, max=50, step=1,
                                get=function() local tp = getT(); return (tp and tp.healthTextX) or 0 end,
                                set=function(_, val)
                                    if InCombatLockdown() then return end
                                    local tp = getT(); if tp then tp.healthTextX = val end
                                    layoutFrames()
                                end,
                                disabled=function() local tp = getT(); return InCombatLockdown() or not (tp and tp.showHealthText) end,
                            },
                            y = {
                                type="range", name="Y Offset", order=3, min=-50, max=50, step=1,
                                get=function() local tp = getT(); return (tp and tp.healthTextY) or 0 end,
                                set=function(_, val)
                                    if InCombatLockdown() then return end
                                    local tp = getT(); if tp then tp.healthTextY = val end
                                    layoutFrames()
                                end,
                                disabled=function() local tp = getT(); return InCombatLockdown() or not (tp and tp.showHealthText) end,
                            },
                        },
                    },
                    healthFontGroup = {
                        type="group", name="Health Text Font", inline=true, order=5,
                        hidden=function() local tp = getT(); return not (tp and tp.showHealthText) end,
                        args = {
                            adjustHealthFont = {
                                type="toggle", name="Adjust Health Font", order=1,
                                desc="Enable custom font, border style, and size for health text",
                                get=getTKey,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    writeT(info, val)
                                    layoutFrames()
                                end,
                                disabled=InCombatLockdown,
                            },
                            healthFont = {
                                type="select", name="Font", order=2, desc="Choose a font for health text",
                                dialogControl="LSM30_Font",
                                hidden=function() local tp = getT(); return not (tp and tp.adjustHealthFont) end,
                                values=buildFontVals,
                                get=function() return getFont("healthFont") end,
                                set=function(_, val) setFont("healthFont", val); layoutFrames() end,
                                disabled=InCombatLockdown,
                            },
                            healthFontBorder = {
                                type="select", name="Font Border", order=3, desc="Choose an outline/border style for health text",
                                hidden=function() local tp = getT(); return not (tp and tp.adjustHealthFont) end,
                                values={
                                    [""] = "None (Default)", ["OUTLINE"] = "Outline", ["THICKOUTLINE"] = "Thick Outline",
                                    ["MONOCHROME"] = "Monochrome", ["OUTLINE, MONOCHROME"] = "Outline + Monochrome",
                                    ["THICKOUTLINE, MONOCHROME"] = "Thick Outline + Monochrome",
                                },
                                get=getTKey,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    writeT(info, val)
                                    layoutFrames()
                                end,
                                disabled=InCombatLockdown,
                            },
                            healthFontSize = {
                                type="range", name="Font Size", order=4,
                                hidden=function() local tp = getT(); return not (tp and tp.adjustHealthFont) end,
                                min=6, max=30, step=1,
                                get=getTKey,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    writeT(info, val)
                                    layoutFrames()
                                end,
                                disabled=InCombatLockdown,
                            },
                        },
                    },
                    healthTextColorGroup = {
                        type="group", name="Health Text Color", inline=true, order=7,
                        hidden=function() local tp = getT(); return not (tp and tp.showHealthText) end,
                        args = {
                            adjustHealthTextColor = {
                                type="toggle", name="Adjust Health Text Color", order=1,
                                get=getTKey,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    writeT(info, val)
                                    layoutFrames()
                                    if BF.RefreshPreviewHealthText then BF:RefreshPreviewHealthText() end
                                end,
                                disabled=InCombatLockdown,
                            },
                            classColorHealthText = {
                                type="toggle", name="Use Class Colors", order=2,
                                hidden=function() local tp = getT(); return not (tp and tp.adjustHealthTextColor) end,
                                get=getTKey,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    writeT(info, val)
                                    for frame in pairs(self.activeFrames or {}) do self:UpdateHealth(frame) end
                                    if BF.RefreshPreviewHealthText then BF:RefreshPreviewHealthText() end
                                end,
                                disabled=InCombatLockdown,
                            },
                            healthTextColor = {
                                type="color", name="Health Text Color", order=3, hasAlpha=false,
                                hidden=function()
                                    local tp = getT()
                                    return not (tp and tp.adjustHealthTextColor) or (tp and tp.classColorHealthText)
                                end,
                                get=function()
                                    local tp = getT()
                                    local c = (tp and tp.healthTextColor) or { r=0.5, g=0.5, b=0.5 }
                                    return c.r, c.g, c.b
                                end,
                                set=function(_, r, g, b)
                                    if InCombatLockdown() then return end
                                    local tp = getT()
                                    if tp then tp.healthTextColor = { r=r, g=g, b=b } end
                                    layoutFrames()
                                    if BF.RefreshPreviewHealthText then BF:RefreshPreviewHealthText() end
                                end,
                                disabled=InCombatLockdown,
                            },
                        },
                    },
                },
            },

            -- ============================================================
            -- Status Text sub-tab
            -- ============================================================
            statusText = {
                type = "group", name = "Status Text", order = 2.5,
                args = {
                    statusTextHeader = { type="header", name="Status Text", order=1 },
                    statusTextDesc = { type="description", name="Status Labels = Dead, Ghost, Offline, AFK", order=1.5, width="full" },
                    statusTextPosition = {
                        type="group", name="Status Text Position", inline=true, order=2,
                        args = {
                            pos = {
                                type="select", name="Location", order=1,
                                hidden=function() local tp = getT(); return tp and tp.appendStatusTextToNames end,
                                values={ TOPLEFT="Top Left", TOP="Top", TOPRIGHT="Top Right", LEFT="Left", CENTER="Center", RIGHT="Right", BOTTOMLEFT="Bottom Left", BOTTOM="Bottom", BOTTOMRIGHT="Bottom Right" },
                                get=function() local tp = getT(); return (tp and tp.statusTextPosition) or "CENTER" end,
                                set=function(_, val)
                                    if InCombatLockdown() then return end
                                    local tp = getT(); if tp then tp.statusTextPosition = val end
                                    layoutFrames()
                                end,
                                disabled=InCombatLockdown,
                            },
                            x = {
                                type="range", name="X Offset", order=2, min=-50, max=50, step=1,
                                hidden=function() local tp = getT(); return tp and tp.appendStatusTextToNames end,
                                get=function() local tp = getT(); return (tp and tp.statusTextX) or 0 end,
                                set=function(_, val)
                                    if InCombatLockdown() then return end
                                    local tp = getT(); if tp then tp.statusTextX = val end
                                    layoutFrames()
                                end,
                                disabled=InCombatLockdown,
                            },
                            y = {
                                type="range", name="Y Offset", order=3, min=-50, max=50, step=1,
                                hidden=function() local tp = getT(); return tp and tp.appendStatusTextToNames end,
                                get=function() local tp = getT(); return (tp and tp.statusTextY) or 0 end,
                                set=function(_, val)
                                    if InCombatLockdown() then return end
                                    local tp = getT(); if tp then tp.statusTextY = val end
                                    layoutFrames()
                                end,
                                disabled=InCombatLockdown,
                            },
                            appendStatusTextToNames = {
                                type="toggle", name="Append Status Text to Names", order=4,
                                desc="When enabled, status labels (Dead, Offline) are appended directly to the unit name instead of being shown as a separate overlay text.",
                                get=getTKey,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    writeT(info, val)
                                    layoutFrames()
                                    BF:RefreshAllStatusColors()
                                end,
                                disabled=InCombatLockdown,
                            },
                            statusAppendSeparator = {
                                type="select", name="Combined Layout", order=5,
                                desc="How the status label is combined with the unit name.",
                                hidden=function() local tp = getT(); return not (tp and tp.appendStatusTextToNames) end,
                                disabled=InCombatLockdown,
                                values=function()
                                    local tp = getT()
                                    local before = tp and tp.statusBeforeName
                                    if before then
                                        return {
                                            PAREN            = "(Status) Name",
                                            PAREN_NOSPACE    = "(Status)Name",
                                            BRACKET          = "[Status] Name",
                                            BRACKET_NOSPACE  = "[Status]Name",
                                            NAME_DASH_STATUS = "Status - Name",
                                            NAME_NODASH      = "Status-Name",
                                            NAME_COMMA       = "Status, Name",
                                            NAME_COMMA_NOSPACE = "Status,Name",
                                        }
                                    else
                                        return {
                                            PAREN            = "Name (Status)",
                                            PAREN_NOSPACE    = "Name(Status)",
                                            BRACKET          = "Name [Status]",
                                            BRACKET_NOSPACE  = "Name[Status]",
                                            NAME_DASH_STATUS = "Name - Status",
                                            NAME_NODASH      = "Name-Status",
                                            NAME_COMMA       = "Name, Status",
                                            NAME_COMMA_NOSPACE = "Name,Status",
                                        }
                                    end
                                end,
                                get=function() local tp = getT(); return (tp and tp.statusAppendSeparator) or "PAREN" end,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    writeT(info, val)
                                    BF:RefreshAllStatusColors()
                                end,
                            },
                            statusBeforeName = {
                                type="toggle", name="Status Before Name", order=6,
                                desc="Show the status label before the unit name instead of after.",
                                hidden=function() local tp = getT(); return not (tp and tp.appendStatusTextToNames) end,
                                disabled=InCombatLockdown,
                                get=getTKey,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    writeT(info, val)
                                    BF:RefreshAllStatusColors()
                                end,
                            },
                        },
                    },
                    statusAbbreviateNamesGroup = {
                        type="group", name="Abbreviate Names when appending Status Text", inline=true, order=2.5,
                        hidden=function() local tp = getT(); return not (tp and tp.appendStatusTextToNames) end,
                        args = {
                            abbreviateStatusNames = {
                                type="toggle", name="Abbreviate Names", order=1,
                                desc="When enabled, unit names are abbreviated to the max length when a status label (Dead, Offline, AFK) is appended to them.",
                                get=getTKey,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    writeT(info, val)
                                    BF:RefreshAllStatusColors()
                                end,
                                disabled=InCombatLockdown,
                            },
                            maxStatusNameChars = {
                                type="range", name="Max Length", order=2,
                                hidden=function() local tp = getT(); return not (tp and tp.abbreviateStatusNames) end,
                                disabled=InCombatLockdown,
                                min=3, max=20, step=1,
                                get=getTKey,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    writeT(info, val)
                                    BF:RefreshAllStatusColors()
                                end,
                            },
                        },
                    },
                    statusFontGroup = {
                        type="group", name="Status Text Font", inline=true, order=3,
                        hidden=function() local tp = getT(); return tp and tp.appendStatusTextToNames end,
                        args = {
                            adjustStatusFont = {
                                type="toggle", name="Adjust Status Font", order=1,
                                desc="Enable custom font, border style, and size for status text",
                                get=getTKey,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    writeT(info, val)
                                    layoutFrames()
                                end,
                                disabled=InCombatLockdown,
                            },
                            statusFont = {
                                type="select", name="Font", order=2, desc="Choose a font for status text",
                                dialogControl="LSM30_Font",
                                hidden=function() local tp = getT(); return not (tp and tp.adjustStatusFont) end,
                                values=buildFontVals,
                                get=function() return getFont("statusFont") end,
                                set=function(_, val) setFont("statusFont", val); layoutFrames() end,
                                disabled=InCombatLockdown,
                            },
                            statusFontBorder = {
                                type="select", name="Font Border", order=3,
                                desc="Choose an outline/border style for status text. Note: the outline is automatically removed for out-of-range dead units regardless of this setting.",
                                hidden=function() local tp = getT(); return not (tp and tp.adjustStatusFont) end,
                                values={
                                    [""] = "None", ["OUTLINE"] = "Outline", ["THICKOUTLINE"] = "Thick Outline",
                                    ["MONOCHROME"] = "Monochrome", ["OUTLINE, MONOCHROME"] = "Outline + Monochrome",
                                    ["THICKOUTLINE, MONOCHROME"] = "Thick Outline + Monochrome",
                                },
                                get=getTKey,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    writeT(info, val)
                                    layoutFrames()
                                end,
                                disabled=InCombatLockdown,
                            },
                            statusFontSize = {
                                type="range", name="Font Size", order=4, min=6, max=30, step=1,
                                hidden=function() local tp = getT(); return not (tp and tp.adjustStatusFont) end,
                                get=getTKey,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    writeT(info, val)
                                    layoutFrames()
                                end,
                                disabled=InCombatLockdown,
                            },
                        },
                    },
                    capitalizeStatusGroup = {
                        type="group", name="Additional Options", inline=true, order=4.5,
                        args = {
                            capitalizeStatusText = {
                                type="toggle", name="Capitalize Status Text", order=1,
                                desc="Convert status labels (Dead, Offline, AFK) to uppercase.",
                                get=getTKey,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    writeT(info, val)
                                    BF:RefreshAllStatusColors()
                                end,
                                disabled=InCombatLockdown,
                            },
                            applyStatusColorsToNames = {
                                type="toggle", name="Apply Status Colors to Names", order=2,
                                desc="When enabled, the name text color is changed to the status color (Dead, Offline, AFK) even when status text is not shown as a separate overlay.",
                                hidden=function() local tp = getT(); return tp and tp.appendStatusTextToNames end,
                                get=getTKey,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    writeT(info, val)
                                    BF:RefreshAllStatusColors()
                                end,
                                disabled=InCombatLockdown,
                            },
                        },
                    },
                    statusColorSpacer = { type="description", name="", order=5 },
                    statusColorHeader = { type="header", name="Status Text Colors", order=5.1 },
                    deadColorGroup = {
                        type="group", name="Dead Status Text", inline=true, order=5.2,
                        args = {
                            showDeadStatus = {
                                type="toggle", name="Show Dead Text", order=1,
                                get=getTKey,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    writeT(info, val)
                                    for f in pairs(self.activeFrames or {}) do f._healthState = nil end
                                    BF:RefreshAllStatusColors()
                                end,
                                disabled=InCombatLockdown,
                            },
                            showFeignDeath = {
                                type="toggle", name="Show Feign Death", order=1.3,
                                desc="Show status text when a unit is using Feign Death. When disabled, feigning units appear as if they are alive.",
                                get=getTKey,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    writeT(info, val)
                                    for f in pairs(self.activeFrames or {}) do f._healthState = nil end
                                    BF:RefreshAllStatusColors()
                                    if BF.RefreshPreviewStatus then BF:RefreshPreviewStatus() end
                                end,
                                disabled=InCombatLockdown,
                            },
                            abbreviateFeignDeath = {
                                type="toggle", name="Abbreviate Feign Death", order=1.6,
                                desc='Shorten "Feign Death" to "Feign".',
                                hidden=function() local tp = getT(); return not (tp and tp.showFeignDeath) end,
                                get=getTKey,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    writeT(info, val)
                                    for f in pairs(self.activeFrames or {}) do f._healthState = nil end
                                    BF:RefreshAllStatusColors()
                                end,
                                disabled=InCombatLockdown,
                            },
                            deadColorUseClassColor = {
                                type="toggle", name="Use Class Color", order=2,
                                desc="Use the unit's class color for dead status text instead of a fixed color.",
                                hidden=function()
                                    local tp = getT()
                                    return (tp and tp.showDeadStatus == false) and not (tp and tp.appendStatusTextToNames) and not (tp and tp.applyStatusColorsToNames)
                                end,
                                get=getTKey,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    writeT(info, val)
                                    BF:RefreshAllStatusColors()
                                end,
                                disabled=InCombatLockdown,
                            },
                            deadColor = {
                                type="color", name="Dead Color", order=3, hasAlpha=false,
                                desc="Color of the 'Dead' (or 'Feign') text on dead frames.",
                                hidden=function()
                                    local tp = getT()
                                    return ((tp and tp.showDeadStatus == false) and not (tp and tp.appendStatusTextToNames) and not (tp and tp.applyStatusColorsToNames))
                                           or (tp and tp.deadColorUseClassColor)
                                end,
                                get=function()
                                    local tp = getT()
                                    local c = (tp and tp.deadColor) or { r=0.8, g=0.1, b=0.1 }
                                    return c.r, c.g, c.b
                                end,
                                set=function(_, r, g, b)
                                    if InCombatLockdown() then return end
                                    local tp = getT()
                                    if tp and tp.deadColor then
                                        tp.deadColor.r, tp.deadColor.g, tp.deadColor.b = r, g, b
                                    end
                                    BF:RefreshAllStatusColors()
                                end,
                                disabled=InCombatLockdown,
                            },
                        },
                    },
                    offlineColorGroup = {
                        type="group", name="Offline Status Text", inline=true, order=7,
                        args = {
                            showOfflineStatus = {
                                type="toggle", name="Show Offline Text", order=1,
                                get=getTKey,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    writeT(info, val)
                                    BF:RefreshAllStatusColors()
                                end,
                                disabled=InCombatLockdown,
                            },
                            abbreviateOffline = {
                                type="toggle", name="Abbreviate Offline", order=2,
                                desc='Abbreviate "Offline" to "Off".',
                                hidden=function() local tp = getT(); return tp and tp.showOfflineStatus == false end,
                                disabled=InCombatLockdown,
                                get=getTKey,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    writeT(info, val)
                                    BF:RefreshAllStatusColors()
                                end,
                            },
                            offlineColorUseClassColor = {
                                type="toggle", name="Use Class Color", order=3,
                                desc="Use the unit's class color for offline status text instead of a fixed color.",
                                hidden=function()
                                    local tp = getT()
                                    return (tp and tp.showOfflineStatus == false) and not (tp and tp.appendStatusTextToNames) and not (tp and tp.applyStatusColorsToNames)
                                end,
                                get=getTKey,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    writeT(info, val)
                                    BF:RefreshAllStatusColors()
                                end,
                                disabled=InCombatLockdown,
                            },
                            offlineColor = {
                                type="color", name="Offline Color", order=4, hasAlpha=false,
                                desc="Color of the 'Offline' text on disconnected frames.",
                                hidden=function()
                                    local tp = getT()
                                    return ((tp and tp.showOfflineStatus == false) and not (tp and tp.appendStatusTextToNames) and not (tp and tp.applyStatusColorsToNames))
                                           or (tp and tp.offlineColorUseClassColor)
                                end,
                                get=function()
                                    local tp = getT()
                                    local c = (tp and tp.offlineColor) or { r=0.5, g=0.5, b=0.5 }
                                    return c.r, c.g, c.b
                                end,
                                set=function(_, r, g, b)
                                    if InCombatLockdown() then return end
                                    local tp = getT()
                                    if tp and tp.offlineColor then
                                        tp.offlineColor.r, tp.offlineColor.g, tp.offlineColor.b = r, g, b
                                    end
                                    BF:RefreshAllStatusColors()
                                end,
                                disabled=InCombatLockdown,
                            },
                            fadeOfflineNameText = {
                                type="toggle", name="Fade Text", order=5,
                                desc="Fade the name and offline status text of offline units using the range fade alpha, and apply the out-of-range color retention to them. Has no effect if Fade Offline Frames (Health & Power Bars tab) is also enabled, since the whole frame is already faded.",
                                get=getTKey,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    writeT(info, val)
                                    BF:RefreshAllStatusColors()
                                end,
                                disabled=InCombatLockdown,
                            },
                        },
                    },
                    afkColorGroup = {
                        type="group", name="AFK Status", inline=true, order=7.5,
                        args = {
                            showAFKStatus = {
                                type="toggle", name="Show AFK Text", order=1,
                                desc="Show 'AFK' on frames for players who are Away From Keyboard.",
                                get=getTKey,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    writeT(info, val)
                                    BF:RefreshAllStatusColors()
                                end,
                                disabled=InCombatLockdown,
                            },
                            afkColorUseClassColor = {
                                type="toggle", name="Use Class Color", order=2,
                                desc="Use the unit's class color for AFK status text instead of a fixed color.",
                                hidden=function()
                                    local tp = getT()
                                    return not (tp and tp.showAFKStatus) and not (tp and tp.appendStatusTextToNames) and not (tp and tp.applyStatusColorsToNames)
                                end,
                                get=getTKey,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    writeT(info, val)
                                    BF:RefreshAllStatusColors()
                                end,
                                disabled=InCombatLockdown,
                            },
                            afkColor = {
                                type="color", name="AFK Color", order=3, hasAlpha=false,
                                desc="Color of the 'AFK' text on frames.",
                                hidden=function()
                                    local tp = getT()
                                    return (not (tp and tp.showAFKStatus) and not (tp and tp.appendStatusTextToNames) and not (tp and tp.applyStatusColorsToNames))
                                           or (tp and tp.afkColorUseClassColor)
                                end,
                                get=function()
                                    local tp = getT()
                                    local c = (tp and tp.afkColor) or { r=0.8, g=0.6, b=0 }
                                    return c.r, c.g, c.b
                                end,
                                set=function(_, r, g, b)
                                    if InCombatLockdown() then return end
                                    local tp = getT()
                                    if tp then tp.afkColor = { r=r, g=g, b=b } end
                                    BF:RefreshAllStatusColors()
                                end,
                                disabled=InCombatLockdown,
                            },
                        },
                    },
                },
            },

            -- ============================================================
            -- Labels sub-tab (Raid Group Labels -- raid-only)
            -- Hidden when per-layout ON + modifying party flat.
            -- ============================================================
            labels = {
                type = "group", name = "Raid Group Labels", order = 3,
                hidden = hideLabelsForParty,
                args = {
                    groupLabelsHeader = { type="header", name="Raid Group Labels", order=1 },
                    showGroupLabels = {
                        type="toggle", name="Show Group Labels",
                        desc="Display a label above each raid group column (e.g. \"Group 1\", \"Group 2\"). Only visible when sorting by Group.",
                        order=2,
                        get=getTKey,
                        set=function(info, val)
                            if InCombatLockdown() then return end
                            writeT(info, val)
                            self:UpdateGroupLabels()
                        end,
                        disabled=function()
                            local sp = self:GetSectionProfile("sorting", self:GetModifyingProfile())
                            return InCombatLockdown() or not (sp and sp.strictGroupLayout)
                        end,
                    },
                    showGroupLabelsNote = {
                        type="description",
                        name=function()
                            local sp = self:GetSectionProfile("sorting", self:GetModifyingProfile())
                            if not (sp and sp.strictGroupLayout) then
                                return "|cffff8800Requires Strict Group Layout to be enabled (Frames - Sorting tab).|r"
                            end
                            return ""
                        end,
                        hidden=function() local tp = getT(); return not (tp and tp.showGroupLabels) end,
                        order=2.5, width="full",
                    },
                    groupLabelColor = {
                        type="color", name="Label Color", order=2.6, hasAlpha=false,
                        hidden=function() local tp = getT(); return not (tp and tp.showGroupLabels) end,
                        get=function()
                            local tp = getT()
                            local c = (tp and tp.groupLabelColor) or { r=1, g=1, b=1 }
                            return c.r, c.g, c.b
                        end,
                        set=function(_, r, g, b)
                            if InCombatLockdown() then return end
                            local tp = getT()
                            if tp and tp.groupLabelColor then
                                tp.groupLabelColor.r, tp.groupLabelColor.g, tp.groupLabelColor.b = r, g, b
                            end
                            self:UpdateGroupLabels()
                        end,
                        disabled=function()
                            local sp = self:GetSectionProfile("sorting", self:GetModifyingProfile())
                            return InCombatLockdown() or not (sp and sp.strictGroupLayout)
                        end,
                    },
                    groupLabelYOffset = {
                        type="range", name="Offset", order=2.55,
                        desc="Gap between the label and the nearest frame edge. Positive values push the label further away from the frames.",
                        hidden=function() local tp = getT(); return not (tp and tp.showGroupLabels) end,
                        min=-20, max=20, step=1,
                        get=getTKey,
                        set=function(info, val)
                            if InCombatLockdown() then return end
                            writeT(info, val)
                            self:UpdateGroupLabels()
                        end,
                        disabled=function()
                            local sp = self:GetSectionProfile("sorting", self:GetModifyingProfile())
                            return InCombatLockdown() or not (sp and sp.strictGroupLayout)
                        end,
                    },
                    groupLabelNumberOnly = {
                        type="toggle", name="Show Number Only", order=2.65,
                        desc="Display only the group number (e.g. \"1\") instead of the full label (e.g. \"Group 1\").",
                        hidden=function() local tp = getT(); return not (tp and tp.showGroupLabels) end,
                        get=getTKey,
                        set=function(info, val)
                            if InCombatLockdown() then return end
                            writeT(info, val)
                            self:UpdateGroupLabels()
                        end,
                        disabled=function()
                            local sp = self:GetSectionProfile("sorting", self:GetModifyingProfile())
                            return InCombatLockdown() or not (sp and sp.strictGroupLayout)
                        end,
                    },
                    groupLabelFontGroup = {
                        type="group", name="Label Font", inline=true, order=3.7,
                        hidden=function()
                            local tp = getT()
                            local sp = self:GetSectionProfile("sorting", self:GetModifyingProfile())
                            return not (tp and tp.showGroupLabels) or not (sp and sp.strictGroupLayout)
                        end,
                        args = {
                            adjustGroupLabelFont = {
                                type="toggle", name="Adjust Label Font", order=1,
                                desc="Enable custom font and border style for raid group labels",
                                get=getTKey,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    writeT(info, val)
                                    self:UpdateGroupLabels()
                                end,
                                disabled=InCombatLockdown,
                            },
                            groupLabelFont = {
                                type="select", name="Font", order=2, desc="Choose a font for raid group labels",
                                dialogControl="LSM30_Font",
                                hidden=function() local tp = getT(); return not (tp and tp.adjustGroupLabelFont) end,
                                disabled=InCombatLockdown,
                                values=buildFontVals,
                                get=function() return getFont("groupLabelFont") end,
                                set=function(_, val) setFont("groupLabelFont", val); self:UpdateGroupLabels() end,
                            },
                            groupLabelFontBorder = {
                                type="select", name="Font Border", order=3, desc="Choose an outline/border style for raid group labels",
                                hidden=function() local tp = getT(); return not (tp and tp.adjustGroupLabelFont) end,
                                disabled=InCombatLockdown,
                                values={
                                    [""] = "None (Default)", ["OUTLINE"] = "Outline", ["THICKOUTLINE"] = "Thick Outline",
                                    ["MONOCHROME"] = "Monochrome", ["OUTLINE, MONOCHROME"] = "Outline + Monochrome",
                                    ["THICKOUTLINE, MONOCHROME"] = "Thick Outline + Monochrome",
                                },
                                get=getTKey,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    writeT(info, val)
                                    self:UpdateGroupLabels()
                                end,
                            },
                            groupLabelFontSize = {
                                type="range", name="Font Size", order=4, min=6, max=30, step=1,
                                hidden=function() local tp = getT(); return not (tp and tp.adjustGroupLabelFont) end,
                                disabled=InCombatLockdown,
                                get=getTKey,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    writeT(info, val)
                                    self:UpdateGroupLabels()
                                end,
                            },
                        },
                    },
                },
            },

            -- ============================================================
            -- Vehicle sub-tab
            -- ============================================================
            vehicle = {
                type = "group", name = "Vehicle", order = 4,
                args = {
                    vehicleNameHeader = { type="header", name="Vehicle Name Text", order=1 },
                    showVehicleName = {
                        type="toggle", name="Show Vehicle Name", order=2,
                        desc="Show the vehicle name on the frame when a unit is in a vehicle. Replaces the unit name while active.",
                        get=getTKey,
                        set=function(info, val)
                            if InCombatLockdown() then return end
                            writeT(info, val)
                            for f in pairs(self.activeFrames or {}) do
                                if self.UpdateVehicle then self:UpdateVehicle(f) end
                            end
                        end,
                        disabled=InCombatLockdown,
                    },
                    abbreviateVehicleNamesGroup = {
                        type="group", name="Abbreviate Vehicle Names", inline=true, order=6,
                        hidden=function() local tp = getT(); return not (tp and tp.showVehicleName) end,
                        args = {
                            abbreviateVehicleNames = {
                                type="toggle", name="Abbreviate Long Vehicle Names", order=1,
                                get=getTKey,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    writeT(info, val)
                                    for f in pairs(self.activeFrames or {}) do
                                        if self.UpdateVehicle then self:UpdateVehicle(f) end
                                    end
                                end,
                                disabled=InCombatLockdown,
                            },
                            maxVehicleNameChars = {
                                type="range", name="Max Vehicle Name Length", order=2, min=3, max=20, step=1,
                                hidden=function() local tp = getT(); return not (tp and tp.abbreviateVehicleNames) end,
                                disabled=InCombatLockdown,
                                get=getTKey,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    writeT(info, val)
                                end,
                            },
                        },
                    },
                    vehicleFontGroup = {
                        type="group", name="Vehicle Name Font", inline=true, order=5.5,
                        hidden=function() local tp = getT(); return not (tp and tp.showVehicleName) end,
                        args = {
                            adjustVehicleFont = {
                                type="toggle", name="Adjust Vehicle Font", order=1,
                                desc="Enable custom font, border style, and size for vehicle name text",
                                get=getTKey,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    writeT(info, val)
                                    layoutFrames()
                                end,
                                disabled=InCombatLockdown,
                            },
                            vehicleFont = {
                                type="select", name="Font", order=2, desc="Choose a font for vehicle name text",
                                dialogControl="LSM30_Font",
                                hidden=function() local tp = getT(); return not (tp and tp.adjustVehicleFont) end,
                                disabled=InCombatLockdown,
                                values=buildFontVals,
                                get=function() return getFont("vehicleFont") end,
                                set=function(_, val) setFont("vehicleFont", val); layoutFrames() end,
                            },
                            vehicleFontBorder = {
                                type="select", name="Font Border", order=3, desc="Choose an outline/border style for vehicle name text",
                                hidden=function() local tp = getT(); return not (tp and tp.adjustVehicleFont) end,
                                disabled=InCombatLockdown,
                                values={
                                    [""] = "None (Default)", ["OUTLINE"] = "Outline", ["THICKOUTLINE"] = "Thick Outline",
                                    ["MONOCHROME"] = "Monochrome", ["OUTLINE, MONOCHROME"] = "Outline + Monochrome",
                                    ["THICKOUTLINE, MONOCHROME"] = "Thick Outline + Monochrome",
                                },
                                get=getTKey,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    writeT(info, val)
                                    layoutFrames()
                                end,
                            },
                            vehicleFontSize = {
                                type="range", name="Font Size", order=4, min=6, max=30, step=1,
                                hidden=function() local tp = getT(); return not (tp and tp.adjustVehicleFont) end,
                                disabled=InCombatLockdown,
                                get=getTKey,
                                set=function(info, val)
                                    if InCombatLockdown() then return end
                                    writeT(info, val)
                                    layoutFrames()
                                end,
                            },
                        },
                    },
                    vehicleNamePosition = {
                        type="group", name="Vehicle Name Position", inline=true, order=3,
                        hidden=function() local tp = getT(); return not (tp and tp.showVehicleName) end,
                        args = {
                            point = {
                                type="select", name="Location", order=1,
                                values={ TOPLEFT="Top Left", TOP="Top", TOPRIGHT="Top Right", LEFT="Left", CENTER="Center", RIGHT="Right", BOTTOMLEFT="Bottom Left", BOTTOM="Bottom", BOTTOMRIGHT="Bottom Right" },
                                get=function() local tp = getT(); return tp and tp.vehicleNamePosition and tp.vehicleNamePosition.point end,
                                set=function(_, v)
                                    if InCombatLockdown() then return end
                                    local tp = getT()
                                    if tp and tp.vehicleNamePosition then tp.vehicleNamePosition.point = v end
                                    layoutFrames()
                                end,
                                disabled=function() local tp = getT(); return InCombatLockdown() or not (tp and tp.showVehicleName) end,
                            },
                            x = {
                                type="range", name="X Offset", order=2, min=-50, max=50, step=1,
                                get=function() local tp = getT(); return tp and tp.vehicleNamePosition and tp.vehicleNamePosition.x end,
                                set=function(_, v)
                                    if InCombatLockdown() then return end
                                    local tp = getT()
                                    if tp and tp.vehicleNamePosition then tp.vehicleNamePosition.x = v end
                                    layoutFrames()
                                end,
                                disabled=function() local tp = getT(); return InCombatLockdown() or not (tp and tp.showVehicleName) end,
                            },
                            y = {
                                type="range", name="Y Offset", order=3, min=-50, max=50, step=1,
                                get=function() local tp = getT(); return tp and tp.vehicleNamePosition and tp.vehicleNamePosition.y end,
                                set=function(_, v)
                                    if InCombatLockdown() then return end
                                    local tp = getT()
                                    if tp and tp.vehicleNamePosition then tp.vehicleNamePosition.y = v end
                                    layoutFrames()
                                end,
                                disabled=function() local tp = getT(); return InCombatLockdown() or not (tp and tp.showVehicleName) end,
                            },
                        },
                    },
                },
            },
        },
    }
end
